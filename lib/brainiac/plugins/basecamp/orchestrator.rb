# frozen_string_literal: true

require "json"
require "time"

module Brainiac
  module Plugins
    module Basecamp
      # Manages active epic execution state.
      #
      # An epic = a Basecamp todolist where each todo is linked to a Fizzy card.
      # The orchestrator drives execution: reads the todolist, builds the dep graph,
      # assigns unblocked Fizzy cards, and advances state as cards complete.
      #
      # State is persisted to ~/.brainiac/basecamp_epics.json.
      module Orchestrator
        BRAINIAC_DIR = ENV.fetch("BRAINIAC_DIR", File.join(Dir.home, ".brainiac"))
        EPICS_FILE = File.join(BRAINIAC_DIR, "basecamp_epics.json")

        class << self
          # Start orchestrating an epic from a todolist.
          #
          # @param todolist_id [String, Integer] Basecamp todolist ID
          # @param project_id [String, Integer] Basecamp project/bucket ID
          # @param agent [String] Agent name to orchestrate
          # @param title [String] Epic/todolist title
          # @return [Hash] The created epic run state
          def start_epic(todolist_id:, project_id:, agent:, title:)
            review_gate = Config.review_gate

            epic = {
              "id" => "epic-#{todolist_id}",
              "basecamp_todolist_id" => todolist_id.to_s,
              "basecamp_project_id" => project_id.to_s,
              "agent" => agent,
              "title" => title,
              "status" => "active",
              "review_gate" => review_gate,
              "started_at" => Time.now.iso8601,
              "updated_at" => Time.now.iso8601,
              "tasks" => [],
              "epic_branches" => {},
              "history" => []
            }

            save_epic(epic)
            log_event(epic, "started", "Epic orchestration started by #{agent} (review_gate: #{review_gate})")

            LOG.info "[Basecamp:Orchestrator] Started epic '#{title}' (todolist #{todolist_id}) " \
                     "with agent #{agent}, review_gate: #{review_gate}" if defined?(LOG)

            # Create epic branches BEFORE dispatching (so resolve_pr_target hook works)
            if review_gate == "epic_branch"
              create_epic_branches_for(epic)
            end

            # Initial task resolution — read the todolist and dispatch unblocked work
            resolve_and_dispatch(epic)

            save_epic(epic)
            epic
          end

          # Start an epic from a single "trigger" todo that contains the todolist context.
          # This is the webhook entry point — a todo is assigned to the bot account,
          # and its parent todolist becomes the epic.
          #
          # @param todo_id [String, Integer] The trigger todo ID
          # @param todolist_id [String, Integer] Parent todolist ID
          # @param project_id [String, Integer] Basecamp project/bucket ID
          # @param agent [String] Agent name
          # @param title [String] Todolist title
          # @return [Hash] The created epic run state
          def start_epic_from_todo(todo_id:, todolist_id:, project_id:, agent:, title:)
            # Check if this epic is already running
            existing = find_epic_by_todolist(todolist_id)
            if existing && existing["status"] == "active"
              LOG.info "[Basecamp:Orchestrator] Epic for todolist #{todolist_id} already active, skipping" if defined?(LOG)
              return existing
            end

            start_epic(todolist_id: todolist_id, project_id: project_id, agent: agent, title: title)
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

            # Mark the corresponding Basecamp todo as complete
            mark_todo_complete(epic, card_number)

            # Post a status comment on the Basecamp todo
            post_completion_comment(epic, card_number)

            # Check if epic is fully done
            if epic["tasks"].all? { |t| t["status"] == "complete" }
              complete_epic(epic)
            else
              # Re-read todolist (it may have changed) and dispatch next unblocked tasks
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

          # Find an epic by its todolist ID.
          #
          # @param todolist_id [String, Integer] Basecamp todolist ID
          # @return [Hash, nil]
          def find_epic_by_todolist(todolist_id)
            load_epics.find { |e| e["basecamp_todolist_id"] == todolist_id.to_s }
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

          # Resolve current todolist state from Basecamp and dispatch unblocked cards.
          def resolve_and_dispatch(epic)
            todos = fetch_todos(epic)
            return unless todos

            # Parse into structured tasks
            tasks = Epic.parse_todos(todos)

            # Update epic state with current task info, preserving in-flight status
            epic["tasks"] = tasks.map do |task|
              existing = epic["tasks"].find { |t| t["fizzy_card"] == task.fizzy_card }
              status = if task.completed
                         "complete"
                       elsif existing&.dig("status") == "in_flight"
                         "in_flight"
                       else
                         "pending"
                       end

              # Resolve project key for this task (from existing state, or from epic's project mapping)
              project_key = existing&.dig("project") || Config.brainiac_project_for(epic["basecamp_project_id"])

              {
                "todo_id" => task.todo_id,
                "fizzy_card" => task.fizzy_card,
                "title" => task.title,
                "depends_on" => task.depends_on,
                "status" => status,
                "project" => project_key,
                "completed_at" => task.completed ? (existing&.dig("completed_at") || Time.now.iso8601) : nil,
                "assignees" => task.assignees,
                "due_on" => task.due_on
              }
            end

            # Find unblocked tasks that aren't already in-flight or complete
            unblocked = Epic.unblocked_tasks(tasks)
            in_flight_cards = epic["tasks"].select { |t| t["status"] == "in_flight" }.map { |t| t["fizzy_card"] }
            complete_cards = epic["tasks"].select { |t| t["status"] == "complete" }.map { |t| t["fizzy_card"] }

            ready_to_dispatch = unblocked.reject { |t| in_flight_cards.include?(t.fizzy_card) || complete_cards.include?(t.fizzy_card) }

            ready_to_dispatch.each do |task|
              dispatch_card(epic, task)
            end

            # Log summary
            LOG.info "[Basecamp:Orchestrator] Epic '#{epic['title']}': " \
                     "#{epic['tasks'].count { |t| t['status'] == 'complete' }}/#{epic['tasks'].size} complete, " \
                     "#{ready_to_dispatch.size} dispatched, " \
                     "#{epic['tasks'].count { |t| t['status'] == 'in_flight' }} in-flight" if defined?(LOG)
          end

          # Dispatch a Fizzy card to the appropriate agent.
          def dispatch_card(epic, task)
            card_number = task.fizzy_card
            agent = epic["agent"]

            LOG.info "[Basecamp:Orchestrator] Dispatching Fizzy card ##{card_number} to #{agent}" if defined?(LOG)

            # Mark as in-flight in our state
            epic_task = epic["tasks"].find { |t| t["fizzy_card"] == card_number }
            if epic_task
              epic_task["status"] = "in_flight"
              epic_task["dispatched_at"] = Time.now.iso8601
            end
            epic["updated_at"] = Time.now.iso8601

            log_event(epic, "dispatched", "Card ##{card_number} dispatched to #{agent}")

            # Assign the card in Fizzy via CLI — this triggers the normal Fizzy webhook flow
            assign_fizzy_card(card_number, agent)

            # Post a comment on the Basecamp todo
            if epic_task && epic_task["todo_id"]
              Client.run_safe(
                "comments", "create", epic_task["todo_id"].to_s,
                "🚀 Dispatched to **#{agent}** via Brainiac",
                "--in", epic["basecamp_project_id"], "--json",
                profile: agent.downcase
              )
            end
          end

          # Assign a Fizzy card to an agent via Fizzy CLI.
          def assign_fizzy_card(card_number, agent)
            agent_config = load_agent_registry[agent.downcase]
            fizzy_name = agent_config&.dig("fizzy_name") || agent

            # Resolve the Fizzy user ID from the agent's display name
            fizzy_user_id = resolve_fizzy_user_id(fizzy_name)
            unless fizzy_user_id
              LOG.error "[Basecamp:Orchestrator] Could not resolve Fizzy user ID for '#{fizzy_name}'" if defined?(LOG)
              return
            end

            stdout, stderr, status = Open3.capture3("fizzy", "card", "assign", card_number.to_s, "--user", fizzy_user_id)

            if status.success?
              LOG.info "[Basecamp:Orchestrator] Assigned Fizzy ##{card_number} to #{fizzy_name} (#{fizzy_user_id})" if defined?(LOG)
            else
              LOG.error "[Basecamp:Orchestrator] Failed to assign Fizzy ##{card_number}: #{stderr.strip}" if defined?(LOG)
            end
          rescue Errno::ENOENT => e
            LOG.error "[Basecamp:Orchestrator] fizzy CLI not found: #{e.message}" if defined?(LOG)
          end

          # Resolve a Fizzy user ID from their display name.
          # Reads from ~/.brainiac/fizzy.json authorized_users list.
          def resolve_fizzy_user_id(name)
            @fizzy_users ||= begin
              fizzy_config_file = File.join(BRAINIAC_DIR, "fizzy.json")
              return {} unless File.exist?(fizzy_config_file)

              config = JSON.parse(File.read(fizzy_config_file))
              users = config["authorized_users"] || []
              users.each_with_object({}) { |u, h| h[u["name"].downcase] = u["id"] }
            rescue StandardError
              {}
            end

            @fizzy_users[name.downcase]
          end

          # Mark a Basecamp todo as complete.
          def mark_todo_complete(epic, card_number)
            task = epic["tasks"].find { |t| t["fizzy_card"] == card_number.to_i }
            return unless task && task["todo_id"]

            Client.run_safe("todos", "complete", task["todo_id"].to_s, "--json",
                           profile: epic["agent"]&.downcase)
          end

          # Post a completion comment on the Basecamp todo.
          def post_completion_comment(epic, card_number)
            task = epic["tasks"].find { |t| t["fizzy_card"] == card_number.to_i }
            return unless task && task["todo_id"]

            Client.run_safe(
              "comments", "create", task["todo_id"].to_s,
              "✅ Fizzy card ##{card_number} completed",
              "--in", epic["basecamp_project_id"], "--json",
              profile: epic["agent"]&.downcase
            )
          end

          # Complete the entire epic.
          def complete_epic(epic)
            epic["status"] = "complete"
            epic["completed_at"] = Time.now.iso8601
            epic["updated_at"] = Time.now.iso8601
            log_event(epic, "completed", "All tasks complete — epic finished!")

            LOG.info "[Basecamp:Orchestrator] Epic '#{epic['title']}' completed!" if defined?(LOG)

            # If epic_branch mode, open final PRs to main
            if epic["review_gate"] == "epic_branch" && epic["epic_branches"]&.any?
              open_final_prs(epic)
            end

            # Post a summary message in Basecamp
            summary = build_completion_summary(epic)
            Client.run_safe(
              "messages", "create", "Epic Complete: #{epic['title']}", summary,
              "--in", epic["basecamp_project_id"], "--json",
              profile: epic["agent"]&.downcase
            )

            # Emit notification for Discord
            if defined?(Brainiac) && Brainiac.respond_to?(:emit)
              Brainiac.emit(:notify,
                            event: :epic_completed,
                            channel: :discord,
                            message: "🎉 Epic completed: **#{epic['title']}** (#{epic['tasks'].size} tasks)",
                            agent: epic["agent"])
            end
          end

          # Fetch todos from the epic's todolist.
          def fetch_todos(epic)
            result = Client.run_safe(
              "todos", "list", "--in", epic["basecamp_project_id"],
              "--list", epic["basecamp_todolist_id"], "--json"
            )

            return nil unless result

            # Handle both envelope format and raw array
            if result.is_a?(Hash)
              result["data"] || []
            elsif result.is_a?(Array)
              result
            else
              nil
            end
          end

          # Build a completion summary for the epic.
          def build_completion_summary(epic)
            tasks = epic["tasks"]
            duration = if epic["started_at"] && epic["completed_at"]
                         started = Time.parse(epic["started_at"])
                         completed = Time.parse(epic["completed_at"])
                         hours = ((completed - started) / 3600).round(1)
                         hours > 24 ? "#{(hours / 24).round(1)} days" : "#{hours} hours"
                       end

            lines = []
            lines << "All #{tasks.size} tasks completed#{duration ? " in #{duration}" : ''}."
            lines << ""
            tasks.each do |task|
              lines << "- ✅ #{task['title']} (Fizzy ##{task['fizzy_card']})"
            end
            lines << ""
            lines << "Orchestrated by #{epic['agent']} via brainiac-basecamp."
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

          # Create epic branches for all projects involved in this epic.
          def create_epic_branches_for(epic)
            project_repos = resolve_project_repos(epic)
            return if project_repos.empty?

            epic["epic_branches"] = EpicBranch.create_epic_branches(epic, project_repos)
            log_event(epic, "branches_created", "Epic branches: #{epic['epic_branches'].values.uniq.join(', ')}")
          rescue StandardError => e
            LOG.error "[Basecamp:Orchestrator] Failed to create epic branches: #{e.message}" if defined?(LOG)
          end

          # Open final PRs from epic branches to main.
          def open_final_prs(epic)
            project_repos = resolve_project_repos(epic)
            return if project_repos.empty?

            prs = EpicBranch.open_final_prs(epic, project_repos, epic["epic_branches"])
            epic["final_prs"] = prs
            log_event(epic, "final_prs_opened", "Opened #{prs.size} final PR(s): #{prs.map { |p| p[:url] }.join(', ')}")

            # Notify about final PRs
            if prs.any? && defined?(Brainiac) && Brainiac.respond_to?(:emit)
              pr_list = prs.map { |p| "#{p[:project]}: #{p[:url]}" }.join("\n")
              Brainiac.emit(:notify,
                            event: :epic_prs_ready,
                            channel: :discord,
                            message: "📋 Epic **#{epic['title']}** — final PRs ready for review:\n#{pr_list}",
                            agent: epic["agent"])
            end
          rescue StandardError => e
            LOG.error "[Basecamp:Orchestrator] Failed to open final PRs: #{e.message}" if defined?(LOG)
          end

          # Resolve project_key => repo_path for all projects in the epic's tasks.
          def resolve_project_repos(epic)
            projects_file = File.join(BRAINIAC_DIR, "projects.json")
            return {} unless File.exist?(projects_file)

            all_projects = JSON.parse(File.read(projects_file))
            project_keys = (epic["tasks"] || []).map { |t| t["project"] }.compact.uniq

            # If no per-task project is set, use the brainiac project mapped to this basecamp project
            if project_keys.empty?
              mapped = Config.brainiac_project_for(epic["basecamp_project_id"])
              project_keys = [mapped] if mapped
            end

            project_keys.each_with_object({}) do |key, hash|
              repo = all_projects.dig(key, "repo_path")
              hash[key] = repo if repo
            end
          rescue JSON::ParserError
            {}
          end
        end
      end
    end
  end
end
