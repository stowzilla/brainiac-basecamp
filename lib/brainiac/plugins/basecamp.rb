# frozen_string_literal: true

require "open3"
require_relative "basecamp/version"
require_relative "basecamp/metadata"
require_relative "basecamp/config"
require_relative "basecamp/client"
require_relative "basecamp/epic"
require_relative "basecamp/task_state"
require_relative "basecamp/epic_branch"
require_relative "basecamp/epic_memory"
require_relative "basecamp/session_registry"
require_relative "basecamp/review_gate"
require_relative "basecamp/comment_responder"
require_relative "basecamp/orchestrator"
require_relative "basecamp/webhook"
require_relative "basecamp/hooks"
require_relative "basecamp/prompts"
require_relative "basecamp/cli"

module Brainiac
  module Plugins
    module Basecamp
      # Maximum seconds to wait for a dispatched agent/gate to respond before
      # considering it stale and re-dispatching. Used across resume and health-check.
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

          # Clear all sessions on startup — PIDs from prior runs are untrustworthy
          SessionRegistry.clear_all!
          SessionRegistry.install_global_registration_hook!

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

            # Reconcile active epics in background after server is ready. The
            # session registry was cleared above, so this treats all inherited
            # agent sessions as dead and safely starts fresh work where needed.
            Thread.new do
              sleep 10 # Wait for server to fully start
              reconcile_active_epics(active, triggered_by: "startup_recovery")
            rescue StandardError => e
              LOG.error "[Basecamp:Recovery] Startup reconciliation failed: #{e.message}" if defined?(LOG)
            end
          end

          # Start the periodic recovery loop for active epics.
          start_epic_health_monitor

          LOG.info "[Basecamp] Plugin registered (webhook: /basecamp, review_gate: #{Config.review_gate})"
        end

        # Background thread that periodically runs the same reconciliation used
        # after startup. Recovery owns liveness reaping and state repair; normal
        # hooks own the immediate event path.
        def start_epic_health_monitor
          @health_monitor_thread = Thread.new do
            loop do
              sleep 90  # Check every 90 seconds

              begin
                reconcile_active_epics(Orchestrator.active_epics, triggered_by: "periodic_recovery")
              rescue StandardError => e
                LOG.error "[Basecamp:Recovery] Periodic reconciliation failed: #{e.message}" if defined?(LOG)
              end
            end
          end
          @health_monitor_thread.abort_on_exception = false
        end

        # The sole restart/periodic reconciliation entry point. It deliberately
        # uses the exact transitions and gate-state operations used by hooks.
        def reconcile_active_epics(epics = Orchestrator.active_epics, triggered_by: "recovery")
          SessionRegistry.reap_dead!
          SessionRegistry.sweep!
          epics.each { |epic| reconcile_epic(epic, triggered_by: triggered_by) }
        end

        def reconcile_epic(epic, triggered_by: "recovery")
          tasks = epic["tasks"] || []
          tasks.each { |task| TaskState.migrate!(task, triggered_by: triggered_by) }

          if tasks.any? && tasks.all? { |task| TaskState.in?(task, :complete) }
            tasks.each { |task| Orchestrator.send(:mark_todo_complete, epic, task["fizzy_card"]) }
            Orchestrator.send(:complete_epic, epic)
            Orchestrator.send(:save_epic, epic)
            return true
          end

          # Reconcile every task in this pass. `Enumerable#any?` would stop at
          # the first repaired task and defer later repairs to the next sweep.
          changed = tasks.map do |task|
            reconcile_task(epic, task, triggered_by: triggered_by)
          end.any?

          # Always attempt to dispatch unblocked tasks during recovery. Even if no
          # individual task changed state, there may be pending tasks whose
          # dependencies are satisfied that were never dispatched (e.g., after a
          # cancellation was reversed or an epic was healed manually).
          has_pending = tasks.any? { |t| TaskState.in?(t, :pending) }
          if changed || has_pending
            Orchestrator.send(:dispatch_unblocked_tasks, epic)
            Orchestrator.send(:save_epic, epic)
          end
          changed || has_pending
        end

        private

        def reconcile_task(epic, task, triggered_by:)
          case TaskState.state(task)
          when "in_flight"
            reconcile_in_flight_task(epic, task)
          when "in_review"
            reconcile_in_review_task(epic, task, triggered_by: triggered_by)
          when "final_decision"
            reconcile_final_decision_task(epic, task)
          else
            false
          end
        end

        def reconcile_in_flight_task(epic, task)
          card_number = task["fizzy_card"]
          # Best-effort liveness check, not atomic: the PID could exit between
          # this check and the re-dispatch below. That's acceptable — if a race
          # occurs, the next periodic recovery sweep (90s) will catch it.
          return false if SessionRegistry.alive?("implementation-#{card_number}")
          return false unless stale_dispatch?(task)

          LOG.info "[Basecamp:Recovery] Re-dispatching implementation for ##{card_number}; no live session" if defined?(LOG)
          task["dispatched_at"] = Time.now.iso8601
          Hooks.send(:dispatch_impl_directly, epic, task)
          true
        end

        def reconcile_in_review_task(epic, task, triggered_by:)
          card_number = task["fizzy_card"]
          pr_number = task["pr_number"]
          project_key = task["project"]
          return false unless pr_number && project_key && ReviewGate.enabled?

          projects = projects_config
          repo_path = projects.dig(project_key, "repo_path")
          github_repo = projects.dig(project_key, "github_repo")
          return false unless repo_path

          ReviewGate.sync_from_github(task, repo_path: repo_path)
          if ReviewGate.all_gates_passed?(task)
            LOG.info "[Basecamp:Recovery] All gates passed for ##{card_number}; dispatching final decision" if defined?(LOG)
            TaskState.transition!(task, :approve, triggered_by: triggered_by, guard: ReviewGate.all_gates_passed?(task))
            task["awaiting_final_decision"] = true
            Hooks.send(:dispatch_final_decision, epic, task, {})
            return true
          end

          if ReviewGate.all_gates_responded?(task) && ReviewGate.changes_requested?(task)
            return recover_changes_requested_task(epic, task, triggered_by: triggered_by)
          end
          return false unless github_repo

          dispatched = ReviewGate.redispatch_stale_gates(
            epic: epic, task: task, pr_number: pr_number,
            repo_name: github_repo, repo_path: repo_path
          )
          dispatched.any?
        end

        def recover_changes_requested_task(epic, task, triggered_by:)
          card_number = task["fizzy_card"]
          # Guard: only recover if changes are actually still requested. The caller
          # checks this too, but this makes the method safe to call standalone
          # (e.g., if gate approvals arrive between the caller's check and here).
          return false unless ReviewGate.changes_requested?(task)
          return false if SessionRegistry.alive?("implementation-#{card_number}")

          TaskState.transition!(task, :request_changes, triggered_by: triggered_by)
          task["dispatched_at"] = Time.now.iso8601
          Hooks.send(:dispatch_impl_directly, epic, task)
          true
        end

        def reconcile_final_decision_task(epic, task)
          pr_number = task["pr_number"]
          project_key = task["project"]
          return false unless pr_number && project_key

          projects = projects_config
          github_repo = projects.dig(project_key, "github_repo")
          if github_repo
            pr_state, = Open3.capture2("gh", "pr", "view", pr_number.to_s, "--repo", github_repo, "--json", "state", "-q", ".state")
            if pr_state.strip == "MERGED"
              Orchestrator.on_card_completed(task["fizzy_card"])
              return true
            end
          end

          card_number = task["fizzy_card"]
          return false if SessionRegistry.alive?("final-decision-#{card_number}")
          return false unless task["awaiting_final_decision"] || ReviewGate.all_gates_passed?(task)

          task["awaiting_final_decision"] = true
          Hooks.send(:dispatch_final_decision, epic, task, {})
          true
        end

        def stale_dispatch?(task)
          dispatched_at = task["dispatched_at"]
          return true unless dispatched_at

          Time.now - Time.parse(dispatched_at) > STALE_DISPATCH_TIMEOUT
        rescue ArgumentError
          true
        end

        def projects_config
          projects_file = File.join(ENV.fetch("BRAINIAC_DIR", File.join(Dir.home, ".brainiac")), "projects.json")
          File.exist?(projects_file) ? JSON.parse(File.read(projects_file)) : {}
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
              total_epics: Orchestrator.all_epics.size,
              sessions: SessionRegistry.status
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
