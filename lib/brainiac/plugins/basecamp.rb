# frozen_string_literal: true

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
              # Check if PR is already merged
              if pr_number && project_key
                projects_file = File.join(ENV.fetch("BRAINIAC_DIR", File.join(Dir.home, ".brainiac")), "projects.json")
                projects = File.exist?(projects_file) ? JSON.parse(File.read(projects_file)) : {}
                github_repo = projects.dig(project_key, "github_repo")

                if github_repo
                  pr_state, = Open3.capture2("gh", "pr", "view", pr_number.to_s, "--repo", github_repo, "--json", "state", "-q", ".state")
                  if pr_state.strip == "MERGED"
                    LOG.info "[Basecamp:HealthCheck] PR ##{pr_number} merged but task ##{card_number} stuck in final_decision — healing" if defined?(LOG)
                    Orchestrator.on_card_completed(card_number)
                    healed_any = true
                  end
                end
              end

            when "in_flight"
              # Check if impl agent is assigned when changes were requested
              if task["changes_requested_by"]&.any?
                impl_agent = epic["agent"]
                card_json, = Open3.capture2("fizzy", "card", "show", card_number.to_s, "--json")
                card_data = JSON.parse(card_json) rescue {}
                assignees = card_data.dig("data", "assignees") || []
                assignee_names = assignees.map { |a| a["name"]&.downcase }

                unless assignee_names.include?(impl_agent.downcase)
                  LOG.info "[Basecamp:HealthCheck] Task ##{card_number} in_flight with changes_requested but #{impl_agent} not assigned — healing" if defined?(LOG)
                  fizzy_user_id = Orchestrator.send(:resolve_fizzy_user_id, impl_agent)
                  if fizzy_user_id
                    Open3.capture3("fizzy", "card", "assign", card_number.to_s, "--user", fizzy_user_id)
                    healed_any = true
                  end
                end
              end

            when "in_review"
              # Check if all gates have actually approved (webhook might have missed)
              if pr_number && project_key && ReviewGate.enabled?
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
                  elsif (task["gate_approvals"] || []).empty? && !(task["changes_requested_by"]&.any?)
                    # No gate responses at all — gates may never have been dispatched or agents crashed
                    gates_dispatched_at = task["gates_dispatched_at"]
                    should_redispatch = gates_dispatched_at.nil? || (Time.now - Time.parse(gates_dispatched_at)) > 300

                    if should_redispatch && github_repo
                      LOG.info "[Basecamp:HealthCheck] No gate responses for ##{card_number} — re-dispatching review gates" if defined?(LOG)
                      ReviewGate.dispatch_gates(
                        epic: epic,
                        task: task,
                        pr_number: pr_number,
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
          end

          # If we healed anything, check if we can dispatch more tasks
          if healed_any
            Orchestrator.send(:dispatch_unblocked_tasks, epic)
            Orchestrator.send(:save_epic, epic)
          end
        end

        private

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
            # Gates requested changes — check if impl agent is assigned
            impl_agent = epic["agent"]
            LOG.info "[Basecamp] Resume: ##{card_number} has changes requested, checking assignment" if defined?(LOG)

            # Check current assignees via Fizzy CLI
            card_json, = Open3.capture2("fizzy", "card", "show", card_number.to_s, "--json")
            card_data = JSON.parse(card_json) rescue {}
            assignees = card_data.dig("data", "assignees") || []
            assignee_names = assignees.map { |a| a["name"]&.downcase }

            if assignee_names.include?(impl_agent.downcase)
              LOG.info "[Basecamp] Resume: ##{card_number} already assigned to #{impl_agent} — waiting for fixes" if defined?(LOG)
            else
              # Re-assign to trigger dispatch
              LOG.info "[Basecamp] Resume: ##{card_number} not assigned to #{impl_agent} — re-assigning" if defined?(LOG)
              fizzy_user_id = Orchestrator.send(:resolve_fizzy_user_id, impl_agent)
              if fizzy_user_id
                Open3.capture3("fizzy", "card", "assign", card_number.to_s, "--user", fizzy_user_id)
              end
            end
          else
            # No changes requested yet — check if gates need (re-)dispatching
            approvals = task["gate_approvals"]&.size || 0
            gates_dispatched_at = task["gates_dispatched_at"]

            # Re-dispatch gates if:
            # 1. Gates were never dispatched (missed webhook), OR
            # 2. Gates were dispatched but no responses received after a reasonable window
            should_redispatch = if gates_dispatched_at.nil?
                                  true
                                elsif approvals.zero?
                                  # If dispatched more than 5 minutes ago with no responses, re-dispatch
                                  elapsed = Time.now - Time.parse(gates_dispatched_at)
                                  elapsed > 300
                                else
                                  false
                                end

            if should_redispatch && ReviewGate.enabled?
              github_repo = projects.dig(project_key, "github_repo")
              if github_repo
                LOG.info "[Basecamp] Resume: ##{card_number} has #{approvals} approvals — re-dispatching review gates" if defined?(LOG)
                ReviewGate.dispatch_gates(
                  epic: epic,
                  task: task,
                  pr_number: pr_number,
                  repo_name: github_repo,
                  repo_path: repo_path
                )
                Hooks.send(:save_epic_state, epic)
              else
                LOG.warn "[Basecamp] Resume: ##{card_number} — cannot re-dispatch gates, no github_repo for #{project_key}" if defined?(LOG)
              end
            else
              LOG.info "[Basecamp] Resume: ##{card_number} has #{approvals} approvals, waiting for more reviews" if defined?(LOG)
            end
          end
        end

        def resume_final_decision_task(epic, task)
          card_number = task["fizzy_card"]
          LOG.info "[Basecamp] Resume: checking final_decision task ##{card_number}, awaiting=#{task['awaiting_final_decision']}" if defined?(LOG)

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
