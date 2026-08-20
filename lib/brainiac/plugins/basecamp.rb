# frozen_string_literal: true

require_relative "basecamp/version"
require_relative "basecamp/metadata"
require_relative "basecamp/config"
require_relative "basecamp/client"
require_relative "basecamp/epic"
require_relative "basecamp/orchestrator"
require_relative "basecamp/webhook"
require_relative "basecamp/hooks"
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

          # Set up routes
          setup_routes(app)

          LOG.info "[Basecamp] Plugin registered (webhook: /basecamp)"
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

            # Verify webhook (if secret configured)
            # Basecamp doesn't use HMAC signatures like Fizzy/GitHub —
            # it relies on the HTTPS endpoint being secret.
            # We can optionally verify the X-Request-Id header exists.

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
              bot_accounts: config["bot_accounts"].keys,
              project_mappings: config["project_mappings"].keys,
              active_epics: Orchestrator.active_epics.size
            }.to_json
          end

          # List epics
          app.get "/api/basecamp/epics" do
            content_type :json
            epics = params["status"] == "all" ? Orchestrator.all_epics : Orchestrator.active_epics
            { epics: epics }.to_json
          end

          # Get specific epic
          app.get "/api/basecamp/epics/:id" do
            content_type :json
            epic = Orchestrator.find_epic(params["id"])
            halt 404, { error: "Epic not found" }.to_json unless epic

            # Include dependency graph
            tasks = epic["tasks"].map do |t|
              Epic::Task.new(
                step_id: t["step_id"],
                title: t["title"],
                fizzy_card: t["fizzy_card"],
                depends_on: t["depends_on"] || [],
                status: t["status"]&.to_sym || :pending,
                completed: t["status"] == "complete"
              )
            end

            epic.merge("dependency_graph" => Epic.dependency_graph(tasks)).to_json
          end
        end
      end
    end
  end
end
