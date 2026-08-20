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
      #   :resolve_base_branch — returns epic branch as worktree base
      #   :resolve_pr_target — returns epic branch as PR target
      module Hooks
        class << self
          def register_all!
            register_agent_completed
            register_pr_merged
            register_build_brain_context
            register_resolve_base_branch
            register_resolve_pr_target
          end

          private

          # When an agent session completes on a Fizzy card, check if it's part of an epic.
          def register_agent_completed
            Brainiac.on(:agent_completed) do |ctx|
              next unless ctx[:source] == :fizzy
              next unless ctx[:exit_status]&.zero? && !ctx[:signaled]

              card_number = ctx[:card_number]
              next unless card_number

              epic = Orchestrator.find_epic_for_card(card_number)
              next unless epic

              review_gate = epic["review_gate"] || Config.review_gate

              case review_gate
              when "on_complete"
                # Advance immediately
                Orchestrator.on_card_completed(card_number)
              when "on_pr_merge"
                # Wait for PR merge — just mark as in_review
                mark_in_review(epic, card_number)
              when "epic_branch"
                # Auto-merge the task PR into the epic branch, then advance
                Thread.new do
                  sleep 10 # Give the PR a moment to be created by the agent
                  auto_merge_and_advance(epic, card_number, ctx)
                rescue StandardError => e
                  LOG.error "[Basecamp:Hooks] Auto-merge failed: #{e.message}" if defined?(LOG)
                end
              end
            end
          end

          # When a PR is merged (manual review gate mode)
          def register_pr_merged
            Brainiac.on(:pr_merged) do |ctx|
              card_number = ctx[:card_number]
              next unless card_number

              epic = Orchestrator.find_epic_for_card(card_number)
              next unless epic

              review_gate = epic["review_gate"] || Config.review_gate
              if review_gate == "on_pr_merge"
                LOG.info "[Basecamp:Hooks] PR merged for card ##{card_number} — advancing epic" if defined?(LOG)
                Orchestrator.on_card_completed(card_number)
              end
            end
          end

          # Inject epic context into agent prompts
          def register_build_brain_context
            Brainiac.on(:build_brain_context) do |ctx|
              card_number = ctx[:card_number]
              next unless card_number

              epic = Orchestrator.find_epic_for_card(card_number)
              next unless epic

              tasks = epic["tasks"] || []
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
                  context_lines << "Dependencies (all satisfied): #{deps.map { |d| "##{d}" }.join(', ')}"
                end

                # Note about epic branch if applicable
                review_gate = epic["review_gate"] || Config.review_gate
                if review_gate == "epic_branch"
                  epic_branches = epic["epic_branches"] || {}
                  branch = epic_branches[current_task["project"]] || epic_branches.values.first
                  if branch
                    context_lines << ""
                    context_lines << "**Epic branch mode:** Your PR should target `#{branch}` (not main)."
                  end
                end

                remaining = tasks.select { |t| t["status"] == "pending" }
                if remaining.any?
                  context_lines << ""
                  context_lines << "Upcoming tasks:"
                  remaining.first(3).each { |t| context_lines << "  - #{t['title']} (Fizzy ##{t['fizzy_card']})" }
                end
              end

              context_lines.join("\n")
            end
          end

          # Return the epic branch as the worktree base for cards in an active epic.
          def register_resolve_base_branch
            Brainiac.on(:resolve_base_branch) do |ctx|
              card_number = ctx[:card_number]
              next unless card_number

              branch = EpicBranch.epic_branch_for_card(card_number)
              next unless branch

              # Return the remote ref so the worktree branches from latest epic branch state
              "origin/#{branch}"
            end
          end

          # Return the epic branch as the PR target for cards in an active epic.
          def register_resolve_pr_target
            Brainiac.on(:resolve_pr_target) do |ctx|
              card_number = ctx[:card_number]
              next unless card_number

              EpicBranch.epic_branch_for_card(card_number)
            end
          end

          # --- Private helpers ---

          def mark_in_review(epic, card_number)
            task = epic["tasks"].find { |t| t["fizzy_card"] == card_number.to_i }
            return unless task

            task["status"] = "in_review"
            task["review_started_at"] = Time.now.iso8601
            epic["updated_at"] = Time.now.iso8601
            save_epic_state(epic)

            LOG.info "[Basecamp:Hooks] Card ##{card_number} in review — waiting for PR merge" if defined?(LOG)
          end

          def auto_merge_and_advance(epic, card_number, ctx)
            task = epic["tasks"].find { |t| t["fizzy_card"] == card_number.to_i }
            return unless task

            project_key = task["project"]
            epic_branches = epic["epic_branches"] || {}
            epic_branch = epic_branches[project_key]
            return unless epic_branch

            # Find the repo path for this project
            projects_file = File.join(ENV.fetch("BRAINIAC_DIR", File.join(Dir.home, ".brainiac")), "projects.json")
            projects = File.exist?(projects_file) ? JSON.parse(File.read(projects_file)) : {}
            repo_path = projects.dig(project_key, "repo_path")
            return unless repo_path

            # Get the branch name from the work item
            branch_name = ctx[:branch] || "fizzy-#{card_number}-*"

            # Try to merge the PR
            merged = EpicBranch.merge_task_into_epic(
              repo_path: repo_path,
              branch_name: branch_name,
              epic_branch: epic_branch
            )

            if merged
              LOG.info "[Basecamp:Hooks] Auto-merged card ##{card_number} into #{epic_branch}, advancing" if defined?(LOG)
              Orchestrator.on_card_completed(card_number)
            else
              # Retry after a delay (PR might not be created yet)
              sleep 30
              merged = EpicBranch.merge_task_into_epic(
                repo_path: repo_path,
                branch_name: branch_name,
                epic_branch: epic_branch
              )
              if merged
                Orchestrator.on_card_completed(card_number)
              else
                LOG.warn "[Basecamp:Hooks] Could not auto-merge card ##{card_number} — manual intervention needed" if defined?(LOG)
                mark_in_review(epic, card_number)
              end
            end
          end

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
