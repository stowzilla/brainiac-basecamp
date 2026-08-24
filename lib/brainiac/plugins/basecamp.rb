# frozen_string_literal: true

require "open3"
require_relative "basecamp/version"
require_relative "basecamp/metadata"
require_relative "basecamp/config"
require_relative "basecamp/client"
require_relative "basecamp/epic"
require_relative "basecamp/epic_branch"
require_relative "basecamp/review_gate"
require_relative "basecamp/orchestrator"
require_relative "basecamp/webhook"
require_relative "basecamp/hooks"
require_relative "basecamp/prompts"
require_relative "basecamp/cli"

module Brainiac
  module Plugins
    module Basecamp
      # Maximum seconds to wait for a dispatched agent/gate to respond before
      # considering it stale and re-dispatching. Used across resume, health-check,
      # and dispatch_missing_gates.
      STALE_DISPATCH_TIMEOUT = 300 # 5 minutes

      # Maximum number of times a gate will be re-dispatched for the same review
      # cycle before giving up (prevents infinite re-dispatch loops).
      MAX_GATE_REDISPATCH_RETRIES = 3

      class << self
        # Called by Brainiac plugin system during server startup.
        #
        # @param app [Sinatra::Application] The running Brainiac server
        def register(app)
          Config.load!

          # Register lifecycle hooks
          Hooks.register_all!

          # Register channel prompt (for when agents need Basecamp awareness)
          Brainiac.register_channel_prompt(:basecamp, Prompts::CHANNEL)

          # Set up routes
          setup_routes(app)

          # Log active epics on startup and resume them
          active = Orchestrator.active_epics
          if active.any?
            LOG.info "[Basecamp] #{active.size} active epic(s) in progress"
            active.each { |e| LOG.info "[Basecamp]   - #{e['title']} (#{e['tasks']&.count { |t| t['status'] == 'complete' }}/#{e['tasks']&.size} complete)" }

            # Resume active epics in background after server is ready
            Thread.new do
              sleep 10 # Wait for server to fully start
              resume_active_epics(active)
            rescue StandardError => e
              LOG.error "[Basecamp] Error resuming epics: #{e.message}" if defined?(LOG)
            end
          end

          # Start background health check thread for active epics
          start_epic_health_monitor

          LOG.info "[Basecamp] Plugin registered (webhook: /basecamp, review_gate: #{Config.review_gate})"
        end

        # Background thread that periodically checks for stuck epic states and auto-heals.
        # Runs every 90 seconds to catch:
        # - final_decision tasks where PR is already merged
        # - in_flight tasks where impl agent isn't assigned
        # - in_review tasks where all gates have actually approved (webhook missed)
        def start_epic_health_monitor
          @health_monitor_thread = Thread.new do
            loop do
              sleep 90  # Check every 90 seconds

              begin
                active_epics = Orchestrator.active_epics
                next if active_epics.empty?

                active_epics.each do |epic|
                  health_check_epic(epic)
                end
              rescue StandardError => e
                LOG.error "[Basecamp:HealthCheck] Error: #{e.message}" if defined?(LOG)
              end
            end
          end
          @health_monitor_thread.abort_on_exception = false
        end

        # Check an epic for stuck states and auto-heal
        def health_check_epic(epic)
          healed_any = false

          epic["tasks"]&.each do |task|
            card_number = task["fizzy_card"]
            status = task["status"]
            pr_number = task["pr_number"]
            project_key = task["project"]

            case status
            when "final_decision"
              # Check if PR is already merged — resolve pr_number first if missing/zero
              effective_pr = pr_number
              if (effective_pr.nil? || effective_pr.zero?) && project_key
                resolved = resolve_pr_for_task(task)
                if resolved
                  task["pr_number"] = resolved[:number]
                  task["pr_repo"] = resolved[:repo] if resolved[:repo]
                  effective_pr = resolved[:number]
                  LOG.info "[Basecamp:HealthCheck] Resolved PR ##{effective_pr} for card ##{card_number}" if defined?(LOG)
                end
              end

              if effective_pr&.positive? && project_key
                projects_file = File.join(ENV.fetch("BRAINIAC_DIR", File.join(Dir.home, ".brainiac")), "projects.json")
                projects = File.exist?(projects_file) ? JSON.parse(File.read(projects_file)) : {}
                github_repo = projects.dig(project_key, "github_repo")

                if github_repo
                  pr_state, = Open3.capture2("gh", "pr", "view", effective_pr.to_s, "--repo", github_repo, "--json", "state", "-q", ".state")
                  if pr_state.strip == "MERGED"
                    LOG.info "[Basecamp:HealthCheck] PR ##{effective_pr} merged but task ##{card_number} stuck in final_decision — healing" if defined?(LOG)
                    Orchestrator.on_card_completed(card_number)
                    healed_any = true
                  end
                end
              end

            when "in_flight"
              # Check if impl agent session is likely dead after a restart.
              # Instead of just checking Fizzy assignment (stale artifact), use
              # dispatched_at as a liveness signal — if dispatched too long ago
              # without completion, assume the session died and re-dispatch.
              dispatched_at = task["dispatched_at"]
              if dispatched_at
                elapsed = Time.now - Time.parse(dispatched_at)
                # If task has been in_flight for longer than the stale timeout
                # AND no agent is actively running (we can't check PID, so use elapsed time)
                if elapsed > STALE_DISPATCH_TIMEOUT
                  impl_agent = epic["agent"]
                  LOG.info "[Basecamp:HealthCheck] Task ##{card_number} in_flight for #{elapsed.round}s — re-dispatching #{impl_agent}" if defined?(LOG)

                  # Spawn the agent directly — safe_assign_card won't work if already assigned
                  task["dispatched_at"] = Time.now.iso8601
                  Hooks.send(:dispatch_impl_directly, epic, task)
                  healed_any = true
                end
              elsif task["changes_requested_by"]&.any?
                # No dispatched_at recorded but changes were requested — legacy state.
                # Always re-dispatch in this case.
                impl_agent = epic["agent"]
                LOG.info "[Basecamp:HealthCheck] Task ##{card_number} in_flight with changes_requested but no dispatched_at — re-dispatching #{impl_agent}" if defined?(LOG)

                # Spawn the agent directly — safe_assign_card won't work if already assigned
                task["dispatched_at"] = Time.now.iso8601
                Hooks.send(:dispatch_impl_directly, epic, task)
                healed_any = true
              end

            when "in_review"
              # Check if all gates have actually approved (webhook might have missed)
              # Resolve pr_number if missing/zero (same pattern as final_decision)
              effective_pr = pr_number
              if (effective_pr.nil? || effective_pr.zero?) && project_key
                resolved = resolve_pr_for_task(task)
                if resolved
                  task["pr_number"] = resolved[:number]
                  task["pr_repo"] = resolved[:repo] if resolved[:repo]
                  effective_pr = resolved[:number]
                  LOG.info "[Basecamp:HealthCheck] Resolved PR ##{effective_pr} for in_review card ##{card_number}" if defined?(LOG)
                end
              end

              if effective_pr&.positive? && project_key && ReviewGate.enabled?
                projects_file = File.join(ENV.fetch("BRAINIAC_DIR", File.join(Dir.home, ".brainiac")), "projects.json")
                projects = File.exist?(projects_file) ? JSON.parse(File.read(projects_file)) : {}
                repo_path = projects.dig(project_key, "repo_path")
                github_repo = projects.dig(project_key, "github_repo")

                if repo_path
                  # Sync from GitHub to catch any missed approvals
                  ReviewGate.sync_from_github(task, repo_path: repo_path)

                  if ReviewGate.all_gates_passed?(task)
                    # All approved — advance to final_decision
                    LOG.info "[Basecamp:HealthCheck] All gates passed for ##{card_number} but still in_review — healing" if defined?(LOG)
                    task["status"] = "final_decision"
                    task["awaiting_final_decision"] = true
                    Hooks.send(:save_epic_state, epic)
                    Hooks.send(:dispatch_final_decision, epic, task, {})
                    healed_any = true
                  elsif task["changes_requested_by"]&.any? && pr_has_newer_commits_than_reviews?(task, repo_path: repo_path)
                    # Changes were requested but the impl agent has already pushed fixes.
                    # The pr_synchronized hook missed this (pr_number was 0, or status wasn't in_flight).
                    # Reset approvals and re-dispatch gates to review the new code.
                    LOG.info "[Basecamp:HealthCheck] PR has commits newer than last changes_requested review for ##{card_number} — re-dispatching gates" if defined?(LOG)
                    ReviewGate.reset_approvals(task)
                    task["changes_requested_by"] = []
                    task["gates_dispatched_at"] = Time.now.iso8601
                    Hooks.send(:save_epic_state, epic)

                    Thread.new do
                      ReviewGate.dispatch_gates(
                        epic: epic,
                        task: task,
                        pr_number: effective_pr,
                        repo_name: github_repo,
                        repo_path: repo_path
                      )
                    rescue StandardError => e
                      LOG.error "[Basecamp:HealthCheck] Gate re-dispatch failed for ##{card_number}: #{e.message}" if defined?(LOG)
                    end
                    healed_any = true
                  elsif Hooks.send(:all_gates_responded?, task) && task["changes_requested_by"]&.any?
                    # All gates responded but some requested changes — need to dispatch impl agent
                    impl_agent = epic["agent"]
                    card_json, = Open3.capture2("fizzy", "card", "show", card_number.to_s, "--json")
                    card_data = JSON.parse(card_json) rescue {}
                    assignees = card_data.dig("data", "assignees") || []
                    assignee_names = assignees.map { |a| a["name"]&.downcase }

                    LOG.info "[Basecamp:HealthCheck] All gates responded for ##{card_number} with changes_requested — transitioning to in_flight" if defined?(LOG)
                    task["status"] = "in_flight"
                    Hooks.send(:save_epic_state, epic)

                    unless assignee_names.include?(impl_agent.downcase)
                      LOG.info "[Basecamp:HealthCheck] Re-assigning ##{card_number} to #{impl_agent}" if defined?(LOG)
                      fizzy_user_id = Orchestrator.send(:resolve_fizzy_user_id, impl_agent)
                      if fizzy_user_id
                        Open3.capture3("fizzy", "card", "assign", card_number.to_s, "--user", fizzy_user_id)
                      end
                    end
                    healed_any = true
                  elsif (task["gate_approvals"] || []).empty? && !task["changes_requested_by"]&.any?
                    # No gate responses at all — gates may never have been dispatched or agents crashed
                    gates_dispatched_at = task["gates_dispatched_at"]
                    should_redispatch = gates_dispatched_at.nil? || (Time.now - Time.parse(gates_dispatched_at)) > STALE_DISPATCH_TIMEOUT

                    if should_redispatch && github_repo
                      LOG.info "[Basecamp:HealthCheck] No gate responses for ##{card_number} — re-dispatching review gates" if defined?(LOG)
                      ReviewGate.dispatch_gates(
                        epic: epic,
                        task: task,
                        pr_number: effective_pr,
                        repo_name: github_repo,
                        repo_path: repo_path
                      )
                      Hooks.send(:save_epic_state, epic)
                      healed_any = true
                    end
                  else
                    # Partial responses — some gates responded but others haven't
                    gates_dispatched_at = task["gates_dispatched_at"]
                    if gates_dispatched_at && (Time.now - Time.parse(gates_dispatched_at)) > STALE_DISPATCH_TIMEOUT
                      responded_count = (task["gate_approvals"]&.size || 0) + (task["changes_requested_by"]&.size || 0)
                      total_gates = ReviewGate.gates.size
                      if responded_count.positive? && responded_count < total_gates && github_repo
                        LOG.info "[Basecamp:HealthCheck] Partial gate response for ##{card_number} (#{responded_count}/#{total_gates}) — re-dispatching missing gates" if defined?(LOG)
                        ReviewGate.dispatch_missing_gates(
                          epic: epic,
                          task: task,
                          pr_number: effective_pr,
                          repo_name: github_repo,
                          repo_path: repo_path
                        )
                        Hooks.send(:save_epic_state, epic)
                        healed_any = true
                      end
                    end
                  end
                end
              end

            when "complete"
              # Sanity check: verify the PR is actually merged before accepting "complete" status.
              # Catches race conditions where rapid review cycles cause premature task completion.
              next unless project_key

              effective_pr = pr_number
              if effective_pr.nil? || effective_pr.zero?
                resolved = resolve_pr_for_task(task)
                if resolved
                  task["pr_number"] = resolved[:number]
                  task["pr_repo"] = resolved[:repo] if resolved[:repo]
                  effective_pr = resolved[:number]
                end
              end

              # If we can't find a PR, we can't verify — skip (might be a no-code task)
              next unless effective_pr&.positive?

              projects_file = File.join(ENV.fetch("BRAINIAC_DIR", File.join(Dir.home, ".brainiac")), "projects.json")
              projects = File.exist?(projects_file) ? JSON.parse(File.read(projects_file)) : {}
              github_repo = projects.dig(project_key, "github_repo")
              repo_path = projects.dig(project_key, "repo_path")
              next unless github_repo

              pr_state, = Open3.capture2("gh", "pr", "view", effective_pr.to_s, "--repo", github_repo, "--json", "state", "-q", ".state")
              pr_state = pr_state.strip

              if pr_state == "OPEN"
                # PR is NOT merged — task was prematurely marked complete.
                # Revert to in_review and re-dispatch gates to review current state.
                LOG.info "[Basecamp:HealthCheck] Task ##{card_number} marked complete but PR ##{effective_pr} is still OPEN — reverting to in_review" if defined?(LOG)

                task["status"] = "in_review"
                task.delete("completed_at")
                task["gate_approvals"] = []
                task["changes_requested_by"] = []
                task["gates_dispatched_at"] = Time.now.iso8601
                Hooks.send(:save_epic_state, epic)

                # Uncheck the Basecamp todo (it was incorrectly checked)
                Orchestrator.send(:uncheck_todo, epic, card_number) if Orchestrator.respond_to?(:uncheck_todo, true)

                # Re-dispatch review gates
                if ReviewGate.enabled? && repo_path
                  Thread.new do
                    ReviewGate.dispatch_gates(
                      epic: epic,
                      task: task,
                      pr_number: effective_pr,
                      repo_name: github_repo,
                      repo_path: repo_path
                    )
                  rescue StandardError => e
                    LOG.error "[Basecamp:HealthCheck] Gate dispatch failed for ##{card_number}: #{e.message}" if defined?(LOG)
                  end
                end
                healed_any = true
              end
            end
          end

          # If we healed anything, check if we can dispatch more tasks
          if healed_any
            Orchestrator.send(:dispatch_unblocked_tasks, epic)
            Orchestrator.send(:save_epic, epic)
          end
        end

        private

        # Check if a PR has commits newer than the most recent changes_requested review.
        # This detects when the impl agent pushed fixes but gates weren't re-triggered.
        #
        # @param task [Hash] Task state with pr_number
        # @param repo_path [String] Local repo path for gh CLI
        # @return [Boolean] true if PR has commits after the last changes_requested review
        def pr_has_newer_commits_than_reviews?(task, repo_path:)
          pr_number = task["pr_number"]
          return false unless pr_number&.positive?

          # Get the last changes_requested review timestamp and the latest commit timestamp
          stdout, _, status = Open3.capture3(
            "gh", "pr", "view", pr_number.to_s,
            "--json", "reviews,commits",
            "--jq", "[(.reviews | map(select(.state == \"CHANGES_REQUESTED\")) | sort_by(.submittedAt) | last | .submittedAt), (.commits | last | .committedDate)] | @tsv",
            chdir: repo_path
          )
          return false unless status.success? && !stdout.strip.empty?

          last_changes_at, last_commit_at = stdout.strip.split("\t")
          return false if last_changes_at.nil? || last_changes_at.empty? || last_commit_at.nil? || last_commit_at.empty?

          # Compare timestamps — if the latest commit is newer than the last changes_requested review,
          # the impl agent has pushed fixes that haven't been reviewed yet.
          Time.parse(last_commit_at) > Time.parse(last_changes_at)
        rescue StandardError => e
          LOG.warn "[Basecamp:HealthCheck] Error checking PR commits vs reviews: #{e.message}" if defined?(LOG)
          false
        end

        # Resume active epics on server startup.
        # For each epic, checks task states and takes appropriate action.
        def resume_active_epics(epics)
          epics.each do |epic|
            LOG.info "[Basecamp] Resuming epic: #{epic['title']}" if defined?(LOG)

            # Check if all tasks are complete — finalize the epic
            if epic["tasks"]&.all? { |t| t["status"] == "complete" }
              LOG.info "[Basecamp] Resume: all tasks complete — finalizing epic" if defined?(LOG)

              # Mark each Basecamp todo as complete (in case they weren't marked during normal flow)
              epic["tasks"].each do |task|
                Orchestrator.send(:mark_todo_complete, epic, task["fizzy_card"])
              end

              Orchestrator.send(:complete_epic, epic)
              Orchestrator.send(:save_epic, epic)
              next
            end

            epic["tasks"]&.each do |task|
              card_number = task["fizzy_card"]
              status = task["status"]
              LOG.info "[Basecamp] Resume: task ##{card_number} status=#{status}" if defined?(LOG)

              case status
              when "in_review", "in_flight"
                # Sync gate state from GitHub and decide next action
                resume_in_review_task(epic, task)
              when "final_decision"
                # Final decision was pending — check if we can merge
                resume_final_decision_task(epic, task)
              when "pending"
                # Check if dependencies are met and dispatch
                # (This is handled by dispatch_unblocked_tasks normally)
                next
              end
            end

            # Dispatch any unblocked tasks
            Orchestrator.send(:dispatch_unblocked_tasks, epic)
          end
        end

        def resume_in_review_task(epic, task)
          card_number = task["fizzy_card"]
          pr_number = task["pr_number"]

          unless pr_number
            LOG.info "[Basecamp] Task ##{card_number} has no PR yet — skipping resume" if defined?(LOG)
            return
          end

          # Get project config for repo path
          project_key = task["project"]
          projects_file = File.join(ENV.fetch("BRAINIAC_DIR", File.join(Dir.home, ".brainiac")), "projects.json")
          projects = File.exist?(projects_file) ? JSON.parse(File.read(projects_file)) : {}
          repo_path = projects.dig(project_key, "repo_path")

          unless repo_path
            LOG.warn "[Basecamp] No repo_path for project #{project_key}" if defined?(LOG)
            return
          end

          # Sync gate approvals from GitHub
          sync_result = ReviewGate.sync_from_github(task, repo_path: repo_path)
          if sync_result[:synced]
            changes = sync_result[:changes] || {}
            if changes[:approvals_added]&.any?
              LOG.info "[Basecamp] Resume: synced approvals for ##{card_number}: #{changes[:approvals_added].join(', ')}" if defined?(LOG)
            end
          end

          # Check if all gates have approved
          if ReviewGate.all_gates_passed?(task)
            LOG.info "[Basecamp] Resume: all gates passed for ##{card_number} — dispatching final decision" if defined?(LOG)
            task["status"] = "final_decision"
            task["awaiting_final_decision"] = true
            Hooks.send(:save_epic_state, epic)
            Hooks.send(:dispatch_final_decision, epic, task, {})
          elsif task["changes_requested_by"]&.any?
            # Gates requested changes — after a restart, no agent session is running even if assigned.
            # Always re-dispatch the impl agent to address the feedback.
            impl_agent = epic["agent"]
            LOG.info "[Basecamp] Resume: ##{card_number} has changes requested — re-dispatching #{impl_agent}" if defined?(LOG)

            # Transition to in_flight so the agent gets the right context
            task["status"] = "in_flight"
            task["dispatched_at"] = Time.now.iso8601
            Hooks.send(:save_epic_state, epic)

            # Spawn the agent directly — safe_assign_card won't work if already assigned
            Hooks.send(:dispatch_impl_directly, epic, task)
          else
            # No changes requested yet — check if gates need (re-)dispatching
            approvals = task["gate_approvals"]&.size || 0
            gates_dispatched_at = task["gates_dispatched_at"]

            # Calculate how many gates have responded (approved or requested changes)
            responded_count = approvals + (task["changes_requested_by"]&.size || 0)
            total_gates = ReviewGate.gates.size

            # Re-dispatch gates if:
            # 1. Gates were never dispatched (missed webhook), OR
            # 2. Gates were dispatched but no responses received after 5 minutes, OR
            # 3. Some gates responded but others didn't after 5 minutes (partial response)
            should_redispatch = if gates_dispatched_at.nil?
                                  true
                                else
                                  elapsed = Time.now - Time.parse(gates_dispatched_at)
                                  elapsed > STALE_DISPATCH_TIMEOUT && responded_count < total_gates
                                end

            if should_redispatch && ReviewGate.enabled?
              github_repo = projects.dig(project_key, "github_repo")
              if github_repo
                if responded_count.zero?
                  # No responses at all — dispatch all gates
                  LOG.info "[Basecamp] Resume: ##{card_number} has 0/#{total_gates} gate responses — re-dispatching all review gates" if defined?(LOG)
                  ReviewGate.dispatch_gates(
                    epic: epic,
                    task: task,
                    pr_number: pr_number,
                    repo_name: github_repo,
                    repo_path: repo_path
                  )
                else
                  # Partial responses — dispatch only the missing gates
                  LOG.info "[Basecamp] Resume: ##{card_number} has #{responded_count}/#{total_gates} gate responses — re-dispatching missing gates" if defined?(LOG)
                  ReviewGate.dispatch_missing_gates(
                    epic: epic,
                    task: task,
                    pr_number: pr_number,
                    repo_name: github_repo,
                    repo_path: repo_path
                  )
                end
                Hooks.send(:save_epic_state, epic)
              else
                LOG.warn "[Basecamp] Resume: ##{card_number} — cannot re-dispatch gates, no github_repo for #{project_key}" if defined?(LOG)
              end
            else
              LOG.info "[Basecamp] Resume: ##{card_number} has #{responded_count}/#{total_gates} gate responses, waiting for more reviews" if defined?(LOG)
            end
          end
        end

        def resume_final_decision_task(epic, task)
          card_number = task["fizzy_card"]
          LOG.info "[Basecamp] Resume: checking final_decision task ##{card_number}, awaiting=#{task['awaiting_final_decision']}" if defined?(LOG)

          # First, resolve PR number if missing or zero (branch creation may have failed)
          pr_number = task["pr_number"]
          if (pr_number.nil? || pr_number.zero?) && task["project"]
            resolved_pr = resolve_pr_for_task(task)
            if resolved_pr
              task["pr_number"] = resolved_pr[:number]
              task["pr_repo"] = resolved_pr[:repo] if resolved_pr[:repo]
              pr_number = resolved_pr[:number]
              LOG.info "[Basecamp] Resume: resolved PR ##{pr_number} for card ##{card_number}" if defined?(LOG)
            end
          end

          # Check if PR is already merged (handles manual merges, webhook misses, agent merges to wrong branch)
          if pr_number&.positive?
            project_key = task["project"]
            projects_file = File.join(ENV.fetch("BRAINIAC_DIR", File.join(Dir.home, ".brainiac")), "projects.json")
            projects = File.exist?(projects_file) ? JSON.parse(File.read(projects_file)) : {}
            github_repo = projects.dig(project_key, "github_repo")

            if github_repo
              pr_state, = Open3.capture2("gh", "pr", "view", pr_number.to_s, "--repo", github_repo, "--json", "state", "-q", ".state")
              if pr_state.strip == "MERGED"
                LOG.info "[Basecamp] Resume: PR ##{pr_number} already merged — marking card ##{card_number} complete" if defined?(LOG)
                Orchestrator.on_card_completed(card_number)
                return
              end
            end
          end

          # If awaiting_final_decision is set, re-dispatch
          # Also handle the case where it's nil but gates are all approved (stale state)
          if task["awaiting_final_decision"] || ReviewGate.all_gates_passed?(task)
            LOG.info "[Basecamp] Resume: dispatching final decision for ##{card_number}" if defined?(LOG)
            task["awaiting_final_decision"] = true
            Hooks.send(:save_epic_state, epic)
            Hooks.send(:dispatch_final_decision, epic, task, {})
          else
            LOG.info "[Basecamp] Resume: final_decision task ##{card_number} not ready (awaiting=#{task['awaiting_final_decision']}, gates_passed=#{ReviewGate.all_gates_passed?(task)})" if defined?(LOG)
          end
        end

        # Resolve a PR number for a task by searching GitHub for matching branch patterns.
        # Used when pr_number is 0 or nil (e.g., branch creation failed so PR was never tracked).
        def resolve_pr_for_task(task)
          card_number = task["fizzy_card"]
          project_key = task["project"]
          return nil unless project_key

          projects_file = File.join(ENV.fetch("BRAINIAC_DIR", File.join(Dir.home, ".brainiac")), "projects.json")
          projects = File.exist?(projects_file) ? JSON.parse(File.read(projects_file)) : {}
          repo_path = projects.dig(project_key, "repo_path")
          github_repo = projects.dig(project_key, "github_repo")
          return nil unless repo_path

          # Search for PR by fizzy-NNNN branch pattern (any state)
          stdout, _, status = Open3.capture3(
            "gh", "pr", "list", "--state", "all",
            "--json", "number,headRefName,state",
            "--jq", ".[] | select(.headRefName | startswith(\"fizzy-#{card_number}\")) | [.number, .state] | @tsv",
            chdir: repo_path
          )
          return nil unless status.success? && !stdout.strip.empty?

          # Take the first match
          number, _state = stdout.strip.split("\n").first.split("\t")
          return nil unless number

          { number: number.to_i, repo: github_repo }
        rescue StandardError => e
          LOG.warn "[Basecamp] Error resolving PR for card ##{card_number}: #{e.message}" if defined?(LOG)
          nil
        end

        def setup_routes(app)
          setup_webhook_route(app)
          setup_api_routes(app)
        end

        def setup_webhook_route(app)
          app.post "/basecamp" do
            content_type :json
            request.body.rewind
            payload_body = request.body.read

            begin
              payload = JSON.parse(payload_body)
            rescue JSON::ParserError => e
              LOG.error "[Basecamp] Invalid JSON: #{e.message}"
              halt 400, { error: "Invalid JSON" }.to_json
            end

            status_code, body = Webhook.handle(payload)
            halt status_code, body
          rescue StandardError => e
            LOG.error "[Basecamp] Unhandled error: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
            halt 500, { error: e.message }.to_json
          end
        end

        def setup_api_routes(app)
          # Status endpoint
          app.get "/api/basecamp" do
            content_type :json
            config = Config.current
            {
              enabled: true,
              review_gate: config["review_gate"],
              bot_accounts: config["bot_accounts"].keys,
              project_mappings: config["project_mappings"].keys,
              active_epics: Orchestrator.active_epics.size,
              total_epics: Orchestrator.all_epics.size
            }.to_json
          end

          # List epics
          app.get "/api/basecamp/epics" do
            content_type :json
            epics = params["status"] == "all" ? Orchestrator.all_epics : Orchestrator.active_epics
            { epics: epics }.to_json
          end

          # Get specific epic with dependency graph
          app.get "/api/basecamp/epics/:id" do
            content_type :json
            epic = Orchestrator.find_epic(params["id"])
            halt 404, { error: "Epic not found" }.to_json unless epic

            # Build dependency graph from current state
            tasks = (epic["tasks"] || []).map do |t|
              Epic::Task.new(
                todo_id: t["todo_id"],
                title: t["title"],
                fizzy_card: t["fizzy_card"],
                depends_on: t["depends_on"] || [],
                status: t["status"]&.to_sym || :pending,
                completed: t["status"] == "complete"
              )
            end

            epic.merge("dependency_graph" => Epic.dependency_graph(tasks)).to_json
          end

          # Manually trigger an epic (for testing or when webhooks aren't set up)
          app.post "/api/basecamp/epics" do
            content_type :json
            request.body.rewind

            begin
              payload = JSON.parse(request.body.read)
            rescue JSON::ParserError
              halt 400, { error: "Invalid JSON" }.to_json
            end

            todolist_id = payload["todolist_id"]
            project_id = payload["project_id"]
            agent = payload["agent"]
            title = payload["title"]

            halt 400, { error: "Missing required fields: todolist_id, project_id, agent, title" }.to_json unless todolist_id && project_id && agent && title

            Thread.new do
              Orchestrator.start_epic(
                todolist_id: todolist_id,
                project_id: project_id,
                agent: agent,
                title: title
              )
            rescue StandardError => e
              LOG.error "[Basecamp:API] Epic start failed: #{e.message}" if defined?(LOG)
            end

            { status: "starting", todolist_id: todolist_id, agent: agent }.to_json
          end

          # Pause/resume an epic
          app.post "/api/basecamp/epics/:id/pause" do
            content_type :json
            epic = Orchestrator.find_epic(params["id"])
            halt 404, { error: "Epic not found" }.to_json unless epic

            epic["status"] = "paused"
            epic["paused_at"] = Time.now.iso8601
            epic["updated_at"] = Time.now.iso8601

            # Save via the epics file
            save_epic_via_api(epic)
            { status: "paused", epic_id: epic["id"] }.to_json
          end

          app.post "/api/basecamp/epics/:id/resume" do
            content_type :json
            epic = Orchestrator.find_epic(params["id"])
            halt 404, { error: "Epic not found" }.to_json unless epic

            epic["status"] = "active"
            epic["resumed_at"] = Time.now.iso8601
            epic["updated_at"] = Time.now.iso8601

            save_epic_via_api(epic)

            # Re-trigger dispatch
            Thread.new { Orchestrator.send(:resolve_and_dispatch, epic) }

            { status: "resumed", epic_id: epic["id"] }.to_json
          end
        end

        def save_epic_via_api(epic)
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
          all[idx] = epic if idx

          File.write(epics_file, JSON.pretty_generate({ "epics" => all, "updated_at" => Time.now.iso8601 }))
        end
      end
    end
  end
end
