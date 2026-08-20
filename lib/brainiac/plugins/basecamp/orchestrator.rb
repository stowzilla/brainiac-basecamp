# frozen_string_literal: true

require "json"
require "time"

module Brainiac
  module Plugins
    module Basecamp
      # Manages active epic execution state.
      # State is persisted to ~/.brainiac/basecamp_epics.json.
      module Orchestrator
        BRAINIAC_DIR = ENV.fetch("BRAINIAC_DIR", File.join(Dir.home, ".brainiac"))
        EPICS_FILE = File.join(BRAINIAC_DIR, "basecamp_epics.json")

        class << self
          # Start orchestrating an epic.
          # Called when a todo assignment webhook is received for a bot account.
          #
          # @param todo_id [String, Integer] Basecamp todo ID
          # @param project_id [String, Integer] Basecamp project/bucket ID
          # @param agent [String] Agent name to orchestrate
          # @param title [String] Epic title
          # @return [Hash] The created epic run state
          def start_epic(todo_id:, project_id:, agent:, title:)
            epic = {
              "id" => "epic-#{todo_id}",
              "basecamp_todo_id" => todo_id.to_s,
              "basecamp_project_id" => project_id.to_s,
              "agent" => agent,
              "title" => title,
              "status" => "active",
              "started_at" => Time.now.iso8601,
              "updated_at" => Time.now.iso8601,
              "tasks" => [],
              "history" => []
            }

            save_epic(epic)
            log_event(epic, "started", "Epic orchestration started by #{agent}")

            LOG.info "[Basecamp:Orchestrator] Started epic '#{title}' (todo #{todo_id}) with agent #{agent}" if defined?(LOG)

            # Initial task resolution
            resolve_and_dispatch(epic)

            epic
          end

          # Called when an agent completes a Fizzy card session.
          # Checks if the card is part of an active epic and advances the orchestration.
          #
          # @param card_number [Integer, String] Fizzy card number that was completed
          # @return [Boolean] Whether this card was part of an epic
          def on_card_completed(card_number)
            card_number = card_number.to_i
            epic = find_epic_for_card(card_number)
            return false unless epic

            LOG.info "[Basecamp:Orchestrator] Card ##{card_number} completed, advancing epic '#{epic['title']}'" if defined?(LOG)

            # Mark the task as complete in our state
            task = epic["tasks"].find { |t| t["fizzy_card"] == card_number }
            if task
              task["status"] = "complete"
              task["completed_at"] = Time.now.iso8601
              epic["updated_at"] = Time.now.iso8601
              log_event(epic, "task_completed", "Card ##{card_number} completed")
            end

            # Mark the corresponding Basecamp subtask as complete
            mark_subtask_complete(epic, card_number)

            # Check if epic is fully done
            if epic["tasks"].all? { |t| t["status"] == "complete" }
              complete_epic(epic)
            else
              # Dispatch next unblocked tasks
              resolve_and_dispatch(epic)
            end

            save_epic(epic)
            true
          end

          # Find an active epic that contains a given Fizzy card.
          #
          # @param card_number [Integer] Fizzy card number
          # @return [Hash, nil] Epic state or nil
          def find_epic_for_card(card_number)
            load_epics.find do |epic|
              epic["status"] == "active" &&
                epic["tasks"].any? { |t| t["fizzy_card"] == card_number.to_i }
            end
          end

          # Get all active epics.
          #
          # @return [Array<Hash>]
          def active_epics
            load_epics.select { |e| e["status"] == "active" }
          end

          # Get all epics (active and completed).
          #
          # @return [Array<Hash>]
          def all_epics
            load_epics
          end

          # Get a specific epic by ID.
          #
          # @param epic_id [String] Epic ID
          # @return [Hash, nil]
          def find_epic(epic_id)
            load_epics.find { |e| e["id"] == epic_id }
          end

          private

          # Resolve current subtask state from Basecamp and dispatch unblocked cards.
          def resolve_and_dispatch(epic)
            # Fetch subtasks from Basecamp
            subtasks = fetch_subtasks(epic)
            return unless subtasks

            # Parse into structured tasks
            tasks = Epic.parse_subtasks(subtasks)

            # Update epic state with current task info
            epic["tasks"] = tasks.map do |task|
              existing = epic["tasks"].find { |t| t["fizzy_card"] == task.fizzy_card }
              {
                "step_id" => task.step_id,
                "fizzy_card" => task.fizzy_card,
                "title" => task.title,
                "depends_on" => task.depends_on,
                "status" => task.completed ? "complete" : (existing&.dig("status") || "pending"),
                "completed_at" => task.completed ? (existing&.dig("completed_at") || Time.now.iso8601) : nil
              }
            end

            # Find unblocked tasks that aren't already in-flight
            unblocked = Epic.unblocked_tasks(tasks)
            in_flight = epic["tasks"].select { |t| t["status"] == "in_flight" }.map { |t| t["fizzy_card"] }

            ready_to_dispatch = unblocked.reject { |t| in_flight.include?(t.fizzy_card) }

            ready_to_dispatch.each do |task|
              dispatch_card(epic, task)
            end
          end

          # Dispatch a Fizzy card to the appropriate agent.
          # This assigns the card in Fizzy, which triggers the normal Fizzy webhook flow.
          def dispatch_card(epic, task)
            card_number = task.fizzy_card
            agent = epic["agent"]

            LOG.info "[Basecamp:Orchestrator] Dispatching Fizzy card ##{card_number} to #{agent}" if defined?(LOG)

            # Mark as in-flight in our state
            epic_task = epic["tasks"].find { |t| t["fizzy_card"] == card_number }
            epic_task["status"] = "in_flight" if epic_task
            epic["updated_at"] = Time.now.iso8601

            log_event(epic, "dispatched", "Card ##{card_number} dispatched to #{agent}")

            # Assign the card in Fizzy via CLI
            # The Fizzy webhook will handle actual agent dispatch
            assign_fizzy_card(card_number, agent)
          end

          # Assign a Fizzy card to an agent.
          # This triggers the normal Fizzy assignment webhook flow.
          def assign_fizzy_card(card_number, agent)
            # Look up the agent's Fizzy name from the registry
            agent_config = load_agent_registry[agent.downcase]
            fizzy_name = agent_config&.dig("fizzy_name") || agent

            # Use Fizzy CLI to assign the card
            system("fizzy", "card", "assign", card_number.to_s, "--to", fizzy_name,
                   out: File::NULL, err: File::NULL)
          rescue StandardError => e
            LOG.error "[Basecamp:Orchestrator] Failed to assign Fizzy card ##{card_number}: #{e.message}" if defined?(LOG)
          end

          # Mark a Basecamp subtask as complete.
          def mark_subtask_complete(epic, card_number)
            task = epic["tasks"].find { |t| t["fizzy_card"] == card_number.to_i }
            return unless task && task["step_id"]

            Client.complete_subtask(task["step_id"], project: epic["basecamp_project_id"])
          rescue ClientError => e
            LOG.warn "[Basecamp:Orchestrator] Failed to complete subtask for card ##{card_number}: #{e.message}" if defined?(LOG)
          end

          # Complete the entire epic.
          def complete_epic(epic)
            epic["status"] = "complete"
            epic["completed_at"] = Time.now.iso8601
            epic["updated_at"] = Time.now.iso8601
            log_event(epic, "completed", "All tasks complete — epic finished!")

            LOG.info "[Basecamp:Orchestrator] Epic '#{epic['title']}' completed!" if defined?(LOG)

            # Complete the parent todo in Basecamp
            Client.complete_todo(epic["basecamp_todo_id"])

            # Post a summary comment
            summary = build_completion_summary(epic)
            Client.add_comment(epic["basecamp_todo_id"], summary, project: epic["basecamp_project_id"])

            # Emit notification for Discord
            if defined?(Brainiac) && Brainiac.respond_to?(:emit)
              Brainiac.emit(:notify,
                            event: :epic_completed,
                            channel: :discord,
                            message: "🎉 Epic completed: **#{epic['title']}** (#{epic['tasks'].size} tasks)",
                            agent: epic["agent"])
            end
          rescue ClientError => e
            LOG.warn "[Basecamp:Orchestrator] Failed to finalize epic in Basecamp: #{e.message}" if defined?(LOG)
          end

          # Fetch subtasks for an epic's todo from Basecamp.
          def fetch_subtasks(epic)
            # First try to get the todo with steps
            result = Client.run_safe(
              "api", "get",
              "/buckets/#{epic['basecamp_project_id']}/card_tables/cards/#{epic['basecamp_todo_id']}/steps.json",
              "--json"
            )

            # The result may be in data array
            if result.is_a?(Hash) && result["data"]
              result["data"]
            elsif result.is_a?(Array)
              result
            else
              # Fallback: get recordings of type Step filtered by parent
              all_steps = Client.run_safe(
                "recordings", "list",
                "--in", epic["basecamp_project_id"],
                "--type", "Kanban::Step", "--all", "--json"
              )

              return nil unless all_steps

              data = all_steps.is_a?(Hash) ? (all_steps["data"] || []) : all_steps
              data.select { |s| s.dig("parent", "id").to_s == epic["basecamp_todo_id"] }
            end
          rescue ClientError => e
            LOG.error "[Basecamp:Orchestrator] Failed to fetch subtasks: #{e.message}" if defined?(LOG)
            nil
          end

          # Build a completion summary for the epic comment.
          def build_completion_summary(epic)
            tasks = epic["tasks"]
            duration = if epic["started_at"] && epic["completed_at"]
                         started = Time.parse(epic["started_at"])
                         completed = Time.parse(epic["completed_at"])
                         hours = ((completed - started) / 3600).round(1)
                         hours > 24 ? "#{(hours / 24).round(1)} days" : "#{hours} hours"
                       end

            lines = ["## Epic Complete ✅", ""]
            lines << "**Duration:** #{duration}" if duration
            lines << "**Tasks:** #{tasks.size} completed"
            lines << ""
            tasks.each do |task|
              lines << "- [x] #{task['title']} (Fizzy ##{task['fizzy_card']})"
            end
            lines.join("\n")
          end

          # Log an event to the epic's history.
          def log_event(epic, event_type, message)
            epic["history"] ||= []
            epic["history"] << {
              "event" => event_type,
              "message" => message,
              "at" => Time.now.iso8601
            }
          end

          # Load all epics from disk.
          def load_epics
            return [] unless File.exist?(EPICS_FILE)

            data = JSON.parse(File.read(EPICS_FILE))
            data["epics"] || []
          rescue JSON::ParserError
            []
          end

          # Save an epic to disk (upsert by ID).
          def save_epic(epic)
            all = load_epics
            idx = all.index { |e| e["id"] == epic["id"] }
            if idx
              all[idx] = epic
            else
              all << epic
            end

            File.write(EPICS_FILE, JSON.pretty_generate({ "epics" => all, "updated_at" => Time.now.iso8601 }))
          end

          # Load agent registry from ~/.brainiac/agents.json.
          def load_agent_registry
            agents_file = File.join(BRAINIAC_DIR, "agents.json")
            return {} unless File.exist?(agents_file)

            JSON.parse(File.read(agents_file))
          rescue JSON::ParserError
            {}
          end
        end
      end
    end
  end
end
