# frozen_string_literal: true

module Brainiac
  module Plugins
    module Basecamp
      # Registers lifecycle hooks with the core event system.
      #
      # Hooks:
      #   :agent_completed — advances epic when a Fizzy card session finishes
      #   :pr_merged — marks a task as truly complete (post-review)
      #   :build_brain_context — injects epic context into agent prompts
      module Hooks
        class << self
          def register_all!
            register_agent_completed
            register_pr_merged
            register_build_brain_context
          end

          private

          # When an agent session completes on a Fizzy card, check if it's part of an epic.
          # If so, advance the orchestration (mark task complete, dispatch next).
          #
          # Note: This fires after the card moves to needs_review. The orchestrator
          # can be configured to wait for PR merge (review gate) or advance immediately.
          def register_agent_completed
            Brainiac.on(:agent_completed) do |ctx|
              next unless ctx[:source] == :fizzy
              next unless ctx[:exit_status]&.zero? && !ctx[:signaled]

              card_number = ctx[:card_number]
              next unless card_number

              epic = Orchestrator.find_epic_for_card(card_number)
              next unless epic

              config = Config.current
              review_gate = config["review_gate"] || "on_complete"

              case review_gate
              when "on_complete"
                # Advance immediately when agent finishes (card goes to needs_review)
                Orchestrator.on_card_completed(card_number)
              when "on_pr_merge"
                # Don't advance yet — wait for the PR to be merged
                # Just update the task status to "in_review"
                task = epic["tasks"].find { |t| t["fizzy_card"] == card_number.to_i }
                if task
                  task["status"] = "in_review"
                  task["review_started_at"] = Time.now.iso8601
                  epic["updated_at"] = Time.now.iso8601
                  # Save via orchestrator's internal method
                  save_epic_state(epic)

                  LOG.info "[Basecamp:Hooks] Card ##{card_number} in review — waiting for PR merge to advance epic" if defined?(LOG)

                  # Post status on Basecamp todo
                  Client.run_safe(
                    "comments", "create", task["todo_id"].to_s,
                    "👀 Code complete — awaiting review. PR will trigger next step on merge.",
                    "--in", epic["basecamp_project_id"], "--json"
                  )
                end
              end
            end
          end

          # When a PR is merged, check if the associated card is part of an epic.
          # If review_gate is "on_pr_merge", THIS is when we advance the epic.
          def register_pr_merged
            Brainiac.on(:pr_merged) do |ctx|
              card_number = ctx[:card_number]
              next unless card_number

              epic = Orchestrator.find_epic_for_card(card_number)
              next unless epic

              config = Config.current
              review_gate = config["review_gate"] || "on_complete"

              if review_gate == "on_pr_merge"
                LOG.info "[Basecamp:Hooks] PR merged for card ##{card_number} — advancing epic" if defined?(LOG)
                Orchestrator.on_card_completed(card_number)
              end
            end
          end

          # When building brain context for an agent session, inject epic context
          # if the card being worked is part of an active epic.
          def register_build_brain_context
            Brainiac.on(:build_brain_context) do |ctx|
              card_number = ctx[:card_number]
              next unless card_number

              epic = Orchestrator.find_epic_for_card(card_number)
              next unless epic

              # Build context about this epic for the agent
              tasks = epic["tasks"]
              current_task = tasks.find { |t| t["fizzy_card"] == card_number.to_i }
              complete_count = tasks.count { |t| t["status"] == "complete" }

              context_lines = [
                "## Epic Context",
                "This card is part of epic: **#{epic['title']}**",
                "Progress: #{complete_count}/#{tasks.size} tasks complete",
                ""
              ]

              if current_task
                deps = current_task["depends_on"] || []
                if deps.any?
                  context_lines << "Dependencies (all complete): #{deps.map { |d| "##{d}" }.join(', ')}"
                end

                # Show what comes next
                remaining = tasks.select { |t| t["status"] == "pending" }
                if remaining.any?
                  context_lines << ""
                  context_lines << "Upcoming tasks:"
                  remaining.first(3).each do |t|
                    context_lines << "  - #{t['title']} (Fizzy ##{t['fizzy_card']})"
                  end
                end
              end

              context_lines.join("\n")
            end
          end

          # Helper to save epic state (wraps the private orchestrator method).
          def save_epic_state(epic)
            epics_file = File.join(
              ENV.fetch("BRAINIAC_DIR", File.join(Dir.home, ".brainiac")),
              "basecamp_epics.json"
            )

            all = if File.exist?(epics_file)
                    data = JSON.parse(File.read(epics_file))
                    data["epics"] || []
                  else
                    []
                  end

            idx = all.index { |e| e["id"] == epic["id"] }
            if idx
              all[idx] = epic
            else
              all << epic
            end

            File.write(epics_file, JSON.pretty_generate({ "epics" => all, "updated_at" => Time.now.iso8601 }))
          rescue StandardError => e
            LOG.error "[Basecamp:Hooks] Failed to save epic state: #{e.message}" if defined?(LOG)
          end
        end
      end
    end
  end
end
