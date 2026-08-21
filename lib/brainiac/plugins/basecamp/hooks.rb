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

                # Only dispatch gates for fresh tasks, not ones already in review/final_decision/complete
                current_status = task["status"]
                if %w[in_review final_decision complete].include?(current_status)
                  LOG.info "[Basecamp:Hooks] Skipping gate dispatch for card ##{card_number} — already #{current_status}" if defined?(LOG)
                  next
                end

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

          # When a PR is merged.
          # - For on_pr_merge mode: listens to :pr_merged (main branch only)
          # - For epic_branch mode: listens to :pr_merged_to_branch (any branch)
          def register_pr_merged
            # Legacy hook for on_pr_merge mode (merged to main)
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

            # New hook for epic_branch mode (merged to any branch, including epic branches)
            Brainiac.on(:pr_merged_to_branch) do |ctx|
              card_number = ctx[:card_number]
              next unless card_number

              epic = Orchestrator.find_epic_for_card(card_number)
              next unless epic

              review_gate = epic["review_gate"] || Config.review_gate
              next unless review_gate == "epic_branch"

              base_branch = ctx[:base_branch]
              epic_branches = epic["epic_branches"]&.values || []

              if epic_branches.include?(base_branch)
                LOG.info "[Basecamp:Hooks] PR merged to epic branch #{base_branch} for card ##{card_number} — advancing" if defined?(LOG)
                Orchestrator.on_card_completed(card_number)
              end
            end
          end

          # When a PR review is submitted (from brainiac-github).
          # Tracks gate approvals — when all gates approve, auto-merge and advance.
          # For changes_requested, we batch/debounce to wait for all gates before dispatching fixes.
          def register_pr_review_received
            Brainiac.on(:pr_review_received) do |ctx|
              card_number = ctx[:card_number]
              next unless card_number

              epic = Orchestrator.find_epic_for_card(card_number)
              next unless epic
              next unless epic["review_gate"] == "epic_branch" && ReviewGate.enabled?

              task = epic["tasks"].find { |t| t["fizzy_card"] == card_number.to_i }
              # Accept reviews during in_review OR in_flight (when addressing changes)
              next unless task && %w[in_review in_flight].include?(task["status"])

              review_state = ctx[:review_state]
              reviewer = ctx[:reviewer] || ctx[:agent_name]

              LOG.info "[Basecamp:Hooks] PR review received: #{reviewer} (#{review_state}) on card ##{card_number}" if defined?(LOG)

              # Match reviewer to a configured gate agent
              # GitHub bot logins are like "threepio-brainiac" or "glados-brainiac[bot]"
              gate = match_reviewer_to_gate(reviewer)

              unless gate
                # Not a gate agent — check if it's the implementation agent's final approval
                impl_agent = epic["agent"]
                is_impl_agent = match_reviewer_to_agent?(reviewer, impl_agent)

                if is_impl_agent && task["awaiting_final_decision"] && review_state == "approved"
                  # Implementation agent approved after reviewing gate feedback — proceed to merge
                  LOG.info "[Basecamp:Hooks] Final decision: #{impl_agent} approved — merging card ##{card_number}" if defined?(LOG)
                  task.delete("awaiting_final_decision")
                  save_epic_state(epic)

                  Thread.new do
                    post_gate_summary(epic, task)
                    auto_merge_and_advance(epic, card_number, ctx)
                  rescue StandardError => e
                    LOG.error "[Basecamp:Hooks] Post-final-decision merge failed: #{e.message}" if defined?(LOG)
                  end
                end

                next # Not a gate agent and not a final decision — skip
              end

              agent_name = gate["agent"]
              role = gate["role"] || "review"

              # Only record approval for APPROVED reviews
              if review_state == "approved"
                LOG.info "[Basecamp:Hooks] Gate APPROVED: #{agent_name} (#{role}) on card ##{card_number}" if defined?(LOG)
                ReviewGate.record_approval(task, agent: agent_name, role: role)
                # Clear this gate from changes_requested if it was there
                task["changes_requested_by"]&.delete(agent_name)
                epic["updated_at"] = Time.now.iso8601

                if ReviewGate.all_gates_passed?(task)
                  LOG.info "[Basecamp:Hooks] All review gates passed for card ##{card_number} — dispatching final decision" if defined?(LOG)
                  save_epic_state(epic)

                  Thread.new do
                    dispatch_final_decision(epic, task, ctx)
                  rescue StandardError => e
                    LOG.error "[Basecamp:Hooks] Final decision dispatch failed: #{e.message}" if defined?(LOG)
                  end
                else
                  approvals = task["gate_approvals"] || []
                  remaining = ReviewGate.gates.size - approvals.size
                  LOG.info "[Basecamp:Hooks] #{approvals.size}/#{ReviewGate.gates.size} gates passed, #{remaining} remaining" if defined?(LOG)
                  save_epic_state(epic)
                end
              elsif review_state == "changes_requested"
                LOG.info "[Basecamp:Hooks] Gate CHANGES_REQUESTED: #{agent_name} (#{role}) on card ##{card_number}" if defined?(LOG)

                # Track which gates requested changes
                task["changes_requested_by"] ||= []
                task["changes_requested_by"] << agent_name unless task["changes_requested_by"].include?(agent_name)

                # Check if all gates have now responded (either approved or requested changes)
                all_responded = all_gates_responded?(task)

                if all_responded
                  # All gates have reviewed — dispatch implementation agent to address ALL feedback
                  LOG.info "[Basecamp:Hooks] All gates responded for card ##{card_number} — dispatching fixes" if defined?(LOG)
                  task["status"] = "in_flight"
                  save_epic_state(epic)
                  # brainiac-github will dispatch the impl agent since this is changes_requested
                else
                  # Wait for remaining gates to respond
                  responded = (task["gate_approvals"]&.size || 0) + (task["changes_requested_by"]&.size || 0)
                  remaining = ReviewGate.gates.size - responded
                  LOG.info "[Basecamp:Hooks] #{responded}/#{ReviewGate.gates.size} gates responded, waiting for #{remaining} more" if defined?(LOG)
                  save_epic_state(epic)

                  # Start a debounce timer if this is the first changes_requested
                  # In case some gates never respond, we'll dispatch after 60 seconds
                  unless task["changes_debounce_started"]
                    task["changes_debounce_started"] = true
                    save_epic_state(epic)
                    Thread.new do
                      sleep 60
                      # Reload epic state using public API
                      epic_reloaded = Orchestrator.find_epic_for_card(card_number)
                      next unless epic_reloaded

                      task_reloaded = epic_reloaded["tasks"]&.find { |t| t["fizzy_card"] == card_number.to_i }
                      if task_reloaded && task_reloaded["status"] == "in_review" && task_reloaded["changes_requested_by"]&.any?
                        LOG.info "[Basecamp:Hooks] Debounce timeout for card ##{card_number} — forcing dispatch" if defined?(LOG)
                        task_reloaded["status"] = "in_flight"
                        task_reloaded.delete("changes_debounce_started")
                        save_epic_state(epic_reloaded)
                        # Re-assign card to trigger dispatch
                        fizzy_user_id = Orchestrator.send(:resolve_fizzy_user_id, epic_reloaded["agent"])
                        Open3.capture3("fizzy", "card", "assign", card_number.to_s, "--user", fizzy_user_id) if fizzy_user_id
                      end
                    rescue StandardError => e
                      LOG.error "[Basecamp:Hooks] Debounce dispatch failed: #{e.message}" if defined?(LOG)
                    end
                  end
                end
              end
            end
          end

          # Check if all configured gates have responded (either approved or requested changes)
          def all_gates_responded?(task)
            approvals = (task["gate_approvals"] || []).map { |a| a["agent"].downcase }
            changes = (task["changes_requested_by"] || []).map(&:downcase)
            responded = approvals + changes

            required = ReviewGate.gates.map { |g| g["agent"].downcase }
            required.all? { |agent| responded.include?(agent) }
          end

          # Match a GitHub reviewer login to a configured gate agent.
          # Handles patterns like "threepio-brainiac", "glados-brainiac[bot]"
          def match_reviewer_to_gate(reviewer)
            return nil unless reviewer

            normalized = reviewer.to_s.downcase.delete_suffix("[bot]")

            ReviewGate.gates.find do |gate|
              agent = gate["agent"].to_s.downcase
              # Direct match
              next true if normalized == agent
              # GitHub bot pattern: "agent-brainiac"
              next true if normalized == "#{agent}-brainiac"
              # Check against display_name from registry
              agents_file = File.join(ENV.fetch("BRAINIAC_DIR", File.join(Dir.home, ".brainiac")), "agents.json")
              if File.exist?(agents_file)
                agents = JSON.parse(File.read(agents_file))
                agent_entry = agents[agent]
                display = agent_entry&.dig("display_name")&.to_s&.downcase
                next true if display && (normalized == display || normalized == "#{display}-brainiac")
              end
              false
            end
          rescue StandardError
            nil
          end

          # Check if a reviewer matches a specific agent name
          def match_reviewer_to_agent?(reviewer, agent_name)
            return false unless reviewer && agent_name

            normalized = reviewer.to_s.downcase.delete_suffix("[bot]")
            agent = agent_name.to_s.downcase

            return true if normalized == agent
            return true if normalized == "#{agent}-brainiac"

            # Check display_name
            agents_file = File.join(ENV.fetch("BRAINIAC_DIR", File.join(Dir.home, ".brainiac")), "agents.json")
            if File.exist?(agents_file)
              agents = JSON.parse(File.read(agents_file))
              agent_entry = agents[agent]
              display = agent_entry&.dig("display_name")&.to_s&.downcase
              return true if display && (normalized == display || normalized == "#{display}-brainiac")
            end

            false
          rescue StandardError
            false
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

                  # Final decision mode — agent reads gate feedback and decides
                  if current_task["awaiting_final_decision"]
                    pr_number = current_task["pr_number"]
                    approvals = current_task["gate_approvals"] || []
                    gate_agents = approvals.map { |a| a["agent"] }.join(", ")

                    context_lines << ""
                    context_lines << "## ⚡ FINAL DECISION REQUIRED — APPROVE TO MERGE"
                    context_lines << ""
                    context_lines << "All review gates have approved (#{gate_agents}). Your job now:"
                    context_lines << ""
                    context_lines << "1. Read their feedback: `gh pr view #{pr_number} --comments`"
                    context_lines << "2. If fixes needed → make them, commit, push"
                    context_lines << "3. When ready → **approve the PR to trigger merge**:"
                    context_lines << "   ```"
                    context_lines << "   gh pr review #{pr_number} --approve --body \"LGTM — merging to epic branch\""
                    context_lines << "   ```"
                    context_lines << ""
                    context_lines << "**CRITICAL:** You must run `gh pr review --approve` to merge. A Fizzy comment is NOT enough."
                    context_lines << "Your approval triggers auto-merge into the epic branch."
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

            # Self-healing: sync gate approvals from GitHub before dispatching
            # This handles the case where gates already reviewed but our state is stale
            sync_result = ReviewGate.sync_from_github(task, repo_path: repo_path)
            if sync_result[:synced] && sync_result[:changes]
              changes = sync_result[:changes]
              if changes[:approvals_added]&.any?
                LOG.info "[Basecamp:Hooks] Self-healed: recorded approvals from #{changes[:approvals_added].join(', ')}" if defined?(LOG)
              end
            end

            # Check if all gates have already approved (self-healed state)
            if ReviewGate.all_gates_passed?(task)
              LOG.info "[Basecamp:Hooks] All gates already approved for card ##{card_number} — dispatching final decision" if defined?(LOG)
              save_epic_state(epic)
              dispatch_final_decision(epic, task, ctx)
              return
            end

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

          # Dispatch the implementation agent to read gate feedback and make a final decision.
          # The agent reads all review comments, then either:
          # - Makes fixes and pushes (triggers re-review cycle)
          # - Approves the PR (triggers the merge)
          #
          # This spawns the agent directly via run_agent (not Fizzy assignment) to avoid
          # confusing unassign/reassign activity in the Fizzy feed.
          def dispatch_final_decision(epic, task, _ctx)
            card_number = task["fizzy_card"]
            agent_name = epic["agent"]
            pr_number = task["pr_number"]
            project_key = task["project"]

            LOG.info "[Basecamp:Hooks] Dispatching #{agent_name} for final decision on card ##{card_number}" if defined?(LOG)

            # Mark task as awaiting final decision
            task["awaiting_final_decision"] = true
            task["status"] = "final_decision"
            epic["updated_at"] = Time.now.iso8601
            save_epic_state(epic)

            # Reset the agent-to-agent dispatch depth for this card
            card_internal_id = lookup_card_internal_id(card_number)
            if card_internal_id
              LOG.info "[Basecamp:Hooks] Resetting dispatch depth for card #{card_internal_id}" if defined?(LOG)
              if defined?(record_human_comment)
                record_human_comment(card_internal_id)
              elsif Object.respond_to?(:record_human_comment, true)
                Object.send(:record_human_comment, card_internal_id)
              end
            end

            # Get project config and repo path
            projects_file = File.join(ENV.fetch("BRAINIAC_DIR", File.join(Dir.home, ".brainiac")), "projects.json")
            projects = File.exist?(projects_file) ? JSON.parse(File.read(projects_file)) : {}
            project_config = projects[project_key]
            repo_path = project_config&.dig("repo_path")

            unless repo_path
              LOG.error "[Basecamp:Hooks] No repo_path for project #{project_key} — cannot dispatch final decision" if defined?(LOG)
              return
            end

            # Find the worktree for this card
            work_items_file = File.join(ENV.fetch("BRAINIAC_DIR", File.join(Dir.home, ".brainiac")), "work_items.json")
            worktree_path = repo_path  # Default to main repo
            if File.exist?(work_items_file)
              work_items = JSON.parse(File.read(work_items_file))
              work_item = work_items.values.find { |wi| wi.dig("sources", "fizzy", "card_number") == card_number }
              worktree_path = work_item["worktree"] if work_item&.dig("worktree")
            end

            # Build prompt for final decision
            gate_approvals = task["gate_approvals"] || []
            gate_agents = gate_approvals.map { |a| a["agent"] }.join(", ")

            prompt = <<~PROMPT
              ## Final Decision Required — Fizzy Card ##{card_number}

              All review gates have approved (#{gate_agents}). Your job:

              1. Read their feedback: `gh pr view #{pr_number} --comments`
              2. If fixes needed → make them, commit, push
              3. When ready → **merge the PR directly**:
                 ```
                 gh pr merge #{pr_number} --squash --delete-branch
                 ```

              Note: You cannot self-approve PRs you authored. Merge directly since gates have approved.

              After merging, update the Fizzy card with a brief status comment.
            PROMPT

            # Resolve GitHub App token so agent's `gh` commands run as their bot identity
            github_repo = project_config&.dig("github_repo")
            agent_env = github_repo ? ReviewGate.send(:resolve_agent_github_env, agent_name, github_repo) : {}

            # Spawn the agent directly (like gate agents do)
            pid = nil
            log_file = nil
            card_key = "final-decision-#{card_number}"

            begin
              pid, log_file = method(:run_agent).call(
                prompt,
                project_config: project_config,
                chdir: worktree_path,
                log_name: "final-decision-#{card_number}",
                agent_name: agent_name,
                source: :basecamp,
                card_number: card_number,
                env: agent_env
              )
            rescue NameError
              if Object.respond_to?(:run_agent, true)
                pid, log_file = Object.send(:run_agent,
                  prompt,
                  project_config: project_config,
                  chdir: worktree_path,
                  log_name: "final-decision-#{card_number}",
                  agent_name: agent_name,
                  source: :basecamp,
                  card_number: card_number,
                  env: agent_env)
              else
                LOG.warn "[Basecamp:Hooks] run_agent not available — final decision dispatch skipped" if defined?(LOG)
                return
              end
            end

            # Register session for waybar visibility
            if pid
              if defined?(register_session)
                register_session(card_key, pid, log_file: log_file, agent_name: agent_name)
              elsif Object.respond_to?(:register_session, true)
                Object.send(:register_session, card_key, pid, log_file: log_file, agent_name: agent_name)
              end
              LOG.info "[Basecamp:Hooks] Spawned #{agent_name} (pid #{pid}) for final decision on card ##{card_number}" if defined?(LOG)
            end
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

          # Look up the Fizzy internal ID for a card number from work_items.
          def lookup_card_internal_id(card_number)
            work_items_file = File.join(
              ENV.fetch("BRAINIAC_DIR", File.join(Dir.home, ".brainiac")),
              "work_items.json"
            )
            return nil unless File.exist?(work_items_file)

            work_items = JSON.parse(File.read(work_items_file))
            work_items.each do |_id, item|
              fizzy_card = item.dig("sources", "fizzy", "card_number") || item["card_number"]
              if fizzy_card.to_i == card_number.to_i
                return item.dig("sources", "fizzy", "card_internal_id") || item["card_internal_id"]
              end
            end
            nil
          rescue StandardError
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
