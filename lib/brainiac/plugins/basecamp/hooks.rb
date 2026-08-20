# frozen_string_literal: true

require "open3"

module Brainiac
  module Plugins
    module Basecamp
      # Registers lifecycle hooks with the core event system.
      #
      # Hooks:
      #   :agent_completed — advances epic or dispatches review gates
      #   :pr_merged — marks task as truly complete (on_pr_merge mode)
      #   :pr_review_received — tracks gate approvals / change requests
      #   :pr_synchronized — re-triggers gates after fixes are pushed
      #   :build_brain_context — injects epic context into agent prompts
      #   :resolve_base_branch — returns epic branch as worktree base
      #   :resolve_pr_target — returns epic branch as PR target
      module Hooks
        class << self
          def register_all!
            register_agent_completed
            register_pr_merged
            register_pr_review_received
            register_pr_synchronized
            register_build_brain_context
            register_resolve_base_branch
            register_resolve_pr_target
          end

          private

          # When an implementation agent completes a Fizzy card task:
          # - on_complete: advance immediately
          # - on_pr_merge: wait for manual PR merge
          # - epic_branch: dispatch review gates (parallel), then auto-merge when all approve
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
                Orchestrator.on_card_completed(card_number)
              when "on_pr_merge"
                mark_in_review(epic, card_number)
              when "epic_branch"
                task = epic["tasks"].find { |t| t["fizzy_card"] == card_number.to_i }
                next unless task

                if ReviewGate.enabled?
                  # Dispatch review gates in parallel after a delay (wait for PR to be created)
                  task["status"] = "in_review"
                  epic["updated_at"] = Time.now.iso8601
                  save_epic_state(epic)

                  Thread.new do
                    sleep 20 # Wait for agent to push + open PR
                    dispatch_review_gates(epic, task, ctx)
                  rescue StandardError => e
                    LOG.error "[Basecamp:Hooks] Review gate dispatch failed: #{e.message}\n#{e.backtrace.first(3).join("\n")}" if defined?(LOG)
                  end
                else
                  # No gates configured — auto-merge directly
                  Thread.new do
                    sleep 10
                    auto_merge_and_advance(epic, card_number, ctx)
                  rescue StandardError => e
                    LOG.error "[Basecamp:Hooks] Auto-merge failed: #{e.message}" if defined?(LOG)
                  end
                end
              end
            end
          end

          # When a PR is merged (on_pr_merge mode only).
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

          # When a PR review is submitted (from brainiac-github).
          # Tracks gate approvals — when all gates approve, auto-merge and advance.
          def register_pr_review_received
            Brainiac.on(:pr_review_received) do |ctx|
              card_number = ctx[:card_number]
              next unless card_number

              epic = Orchestrator.find_epic_for_card(card_number)
              next unless epic
              next unless epic["review_gate"] == "epic_branch" && ReviewGate.enabled?

              task = epic["tasks"].find { |t| t["fizzy_card"] == card_number.to_i }
              next unless task && task["status"] == "in_review"

              # Determine which agent submitted the review
              reviewer = ctx[:reviewer] || ctx[:agent_name]

              # Match reviewer to a configured gate
              gate = ReviewGate.gates.find { |g| g["agent"].downcase == reviewer&.downcase }

              # Also check if the reviewer matches a gate agent's display name
              unless gate
                agents_file = File.join(ENV.fetch("BRAINIAC_DIR", File.join(Dir.home, ".brainiac")), "agents.json")
                if File.exist?(agents_file)
                  agents = JSON.parse(File.read(agents_file))
                  gate = ReviewGate.gates.find do |g|
                    agent_entry = agents[g["agent"].downcase]
                    display = agent_entry&.dig("display_name") || g["agent"]
                    display.downcase == reviewer&.downcase
                  end
                end
              end

              next unless gate # Not a gate agent's review — ignore

              agent_name = gate["agent"]
              role = gate["role"] || "review"

              LOG.info "[Basecamp:Hooks] Gate review from #{agent_name} (#{role}) on card ##{card_number}" if defined?(LOG)

              # The review state comes from the GitHub review
              # brainiac-github dispatches the agent on "changes_requested" reviews,
              # so if we're here after agent_completed, the agent approved (otherwise
              # the implementation agent would have been re-dispatched already).
              # Record the approval.
              ReviewGate.record_approval(task, agent: agent_name, role: role)
              epic["updated_at"] = Time.now.iso8601

              if ReviewGate.all_gates_passed?(task)
                LOG.info "[Basecamp:Hooks] All review gates passed for card ##{card_number} — merging into epic branch" if defined?(LOG)
                save_epic_state(epic)

                Thread.new do
                  # Post Fizzy comment with gate summary
                  post_gate_summary(epic, task)
                  # Auto-merge and advance
                  auto_merge_and_advance(epic, card_number, ctx)
                rescue StandardError => e
                  LOG.error "[Basecamp:Hooks] Post-gate merge failed: #{e.message}" if defined?(LOG)
                end
              else
                approvals = task["gate_approvals"] || []
                remaining = ReviewGate.gates.size - approvals.size
                LOG.info "[Basecamp:Hooks] #{approvals.size}/#{ReviewGate.gates.size} gates passed, #{remaining} remaining" if defined?(LOG)
                save_epic_state(epic)
              end
            end
          end

          # When a PR is updated (new commits pushed) — re-trigger gates if in review.
          # This handles the "Galen fixes → pushes → gates re-review" flow.
          def register_pr_synchronized
            Brainiac.on(:pr_synchronized) do |ctx|
              card_number = ctx[:card_number]
              next unless card_number

              epic = Orchestrator.find_epic_for_card(card_number)
              next unless epic
              next unless epic["review_gate"] == "epic_branch" && ReviewGate.enabled?

              task = epic["tasks"].find { |t| t["fizzy_card"] == card_number.to_i }
              # Only re-trigger if the task is in_flight (fixes pushed) and had prior reviews
              next unless task && task["status"] == "in_flight" && task["gate_approvals"]&.any?

              LOG.info "[Basecamp:Hooks] PR updated for card ##{card_number} — re-triggering review gates" if defined?(LOG)

              # Reset approvals and re-dispatch gates
              ReviewGate.reset_approvals(task)
              task["status"] = "in_review"
              epic["updated_at"] = Time.now.iso8601
              save_epic_state(epic)

              Thread.new do
                dispatch_review_gates(epic, task, ctx)
              rescue StandardError => e
                LOG.error "[Basecamp:Hooks] Gate re-dispatch failed: #{e.message}" if defined?(LOG)
              end
            end
          end

          # Inject epic context into agent prompts.
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
                context_lines << "Dependencies (all satisfied): #{deps.map { |d| "##{d}" }.join(', ')}" if deps.any?

                review_gate = epic["review_gate"] || Config.review_gate
                if review_gate == "epic_branch"
                  epic_branches = epic["epic_branches"] || {}
                  branch = epic_branches[current_task["project"]] || epic_branches.values.first
                  context_lines << "" << "**Epic branch mode:** Your PR should target `#{branch}` (not main)." if branch

                  if ReviewGate.enabled?
                    gate_names = ReviewGate.gates.map { |g| "#{g['agent']} (#{g['role']})" }.join(", ")
                    context_lines << "**Review gates:** #{gate_names} will review your PR after you open it."
                  end
                end

                remaining = tasks.select { |t| t["status"] == "pending" }
                if remaining.any?
                  context_lines << "" << "Upcoming tasks:"
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

          # Dispatch all review gate agents in parallel for a task.
          def dispatch_review_gates(epic, task, ctx)
            card_number = task["fizzy_card"]
            project_key = task["project"] || Config.brainiac_project_for(epic["basecamp_project_id"])

            # Resolve repo info
            projects_file = File.join(ENV.fetch("BRAINIAC_DIR", File.join(Dir.home, ".brainiac")), "projects.json")
            projects = File.exist?(projects_file) ? JSON.parse(File.read(projects_file)) : {}
            project_config = projects[project_key] || {}
            repo_path = project_config["repo_path"]
            github_repo = project_config["github_repo"]

            unless repo_path && github_repo
              LOG.warn "[Basecamp:Hooks] Cannot dispatch gates — missing repo_path or github_repo for #{project_key}" if defined?(LOG)
              return
            end

            # Find the PR number for this card's branch
            branch = ctx[:branch] || "fizzy-#{card_number}-*"
            pr_number = find_pr_number(repo_path: repo_path, branch: branch)

            unless pr_number
              LOG.warn "[Basecamp:Hooks] No PR found for card ##{card_number} — gates cannot be dispatched" if defined?(LOG)
              # Retry once after delay
              sleep 30
              pr_number = find_pr_number(repo_path: repo_path, branch: branch)
              unless pr_number
                LOG.error "[Basecamp:Hooks] Still no PR for card ##{card_number} after retry" if defined?(LOG)
                return
              end
            end

            task["pr_number"] = pr_number
            task["pr_repo"] = github_repo

            ReviewGate.dispatch_gates(
              epic: epic,
              task: task,
              pr_number: pr_number,
              repo_name: github_repo,
              repo_path: repo_path
            )

            save_epic_state(epic)
          end

          # Post a summary comment on the Fizzy card after all gates pass.
          def post_gate_summary(epic, task)
            card_number = task["fizzy_card"]
            pr_number = task["pr_number"]
            pr_repo = task["pr_repo"]
            pr_url = "https://github.com/#{pr_repo}/pull/#{pr_number}" if pr_repo && pr_number

            comment_html = ReviewGate.build_gate_summary_comment(task, pr_url: pr_url || "")

            # Post via Fizzy CLI as the implementation agent
            agent_name = epic["agent"]
            fizzy_env = resolve_fizzy_env(agent_name)

            Open3.capture3(
              "fizzy", "comment", "create",
              "--card", card_number.to_s,
              "--body", comment_html,
              **({ env: fizzy_env } if fizzy_env)
            )
          rescue StandardError => e
            LOG.warn "[Basecamp:Hooks] Failed to post gate summary on card ##{card_number}: #{e.message}" if defined?(LOG)
          end

          def mark_in_review(epic, card_number)
            task = epic["tasks"].find { |t| t["fizzy_card"] == card_number.to_i }
            return unless task

            task["status"] = "in_review"
            task["review_started_at"] = Time.now.iso8601
            epic["updated_at"] = Time.now.iso8601
            save_epic_state(epic)
          end

          def auto_merge_and_advance(epic, card_number, ctx)
            task = epic["tasks"].find { |t| t["fizzy_card"] == card_number.to_i }
            return unless task

            project_key = task["project"] || Config.brainiac_project_for(epic["basecamp_project_id"])
            epic_branches = epic["epic_branches"] || {}
            epic_branch = epic_branches[project_key] || epic_branches.values.first
            return unless epic_branch

            projects_file = File.join(ENV.fetch("BRAINIAC_DIR", File.join(Dir.home, ".brainiac")), "projects.json")
            projects = File.exist?(projects_file) ? JSON.parse(File.read(projects_file)) : {}
            repo_path = projects.dig(project_key, "repo_path")
            return unless repo_path

            branch_name = ctx[:branch]

            # If we don't have the exact branch name, try to find it
            unless branch_name
              stdout, _, status = Open3.capture3("gh", "pr", "list", "--head", "fizzy-#{card_number}",
                                                  "--json", "headRefName", "--jq", ".[0].headRefName",
                                                  chdir: repo_path)
              branch_name = stdout.strip if status.success? && !stdout.strip.empty?
            end

            merged = EpicBranch.merge_task_into_epic(
              repo_path: repo_path,
              branch_name: branch_name || "fizzy-#{card_number}",
              epic_branch: epic_branch
            )

            if merged
              LOG.info "[Basecamp:Hooks] Merged card ##{card_number} into #{epic_branch} — advancing epic" if defined?(LOG)
              Orchestrator.on_card_completed(card_number)
            else
              sleep 30
              merged = EpicBranch.merge_task_into_epic(
                repo_path: repo_path,
                branch_name: branch_name || "fizzy-#{card_number}",
                epic_branch: epic_branch
              )
              if merged
                Orchestrator.on_card_completed(card_number)
              else
                LOG.warn "[Basecamp:Hooks] Could not merge card ##{card_number} — manual intervention needed" if defined?(LOG)
                task["status"] = "merge_failed"
                save_epic_state(epic)
              end
            end
          end

          # Find a PR number by branch name pattern.
          def find_pr_number(repo_path:, branch:)
            # Try exact match first
            stdout, _, status = Open3.capture3(
              "gh", "pr", "list", "--head", branch, "--json", "number", "--jq", ".[0].number",
              chdir: repo_path
            )
            return stdout.strip.to_i if status.success? && !stdout.strip.empty?

            # Try pattern match (fizzy-NNNN-*)
            if branch.include?("*")
              card_num = branch.match(/fizzy-(\d+)/)[1] rescue nil
              if card_num
                stdout, _, status = Open3.capture3(
                  "gh", "pr", "list", "--json", "number,headRefName",
                  "--jq", ".[] | select(.headRefName | startswith(\"fizzy-#{card_num}\")) | .number",
                  chdir: repo_path
                )
                return stdout.strip.to_i if status.success? && !stdout.strip.empty?
              end
            end

            nil
          end

          # Resolve Fizzy env for an agent (FIZZY_TOKEN).
          def resolve_fizzy_env(agent_name)
            agents_file = File.join(ENV.fetch("BRAINIAC_DIR", File.join(Dir.home, ".brainiac")), "agents.json")
            return nil unless File.exist?(agents_file)

            agents = JSON.parse(File.read(agents_file))
            agent = agents[agent_name.downcase]
            return nil unless agent

            env = agent.dig("env") || {}
            env.empty? ? nil : env
          rescue StandardError
            nil
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
