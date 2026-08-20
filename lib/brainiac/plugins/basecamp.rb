# frozen_string_literal: true

require_relative "basecamp/version"
require_relative "basecamp/metadata"
require_relative "basecamp/config"
require_relative "basecamp/client"
require_relative "basecamp/epic"
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

          # Log active epics on startup
          active = Orchestrator.active_epics
          if active.any?
            LOG.info "[Basecamp] #{active.size} active epic(s) in progress"
            active.each { |e| LOG.info "[Basecamp]   - #{e['title']} (#{e['tasks']&.count { |t| t['status'] == 'complete' }}/#{e['tasks']&.size} complete)" }
          end

          LOG.info "[Basecamp] Plugin registered (webhook: /basecamp, review_gate: #{Config.review_gate})"
        end

        private

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
