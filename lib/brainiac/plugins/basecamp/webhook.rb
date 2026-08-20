# frozen_string_literal: true

require "json"

module Brainiac
  module Plugins
    module Basecamp
      # Handles inbound Basecamp webhooks.
      module Webhook
        class << self
          # Process a webhook payload from Basecamp.
          #
          # @param payload [Hash] Parsed JSON webhook payload
          # @return [Array(Integer, String)] HTTP status code and response body
          def handle(payload)
            kind = payload["kind"]
            recording = payload["recording"] || {}
            details = payload["details"] || {}

            LOG.info "[Basecamp:Webhook] Received event: #{kind}" if defined?(LOG)

            case kind
            when "todo_assignment_changed"
              handle_todo_assignment(payload, recording, details)
            when "todo_completed"
              handle_todo_completed(payload, recording)
            when "kanban_step_assignment_changed"
              handle_step_assignment(payload, recording, details)
            else
              LOG.debug "[Basecamp:Webhook] Ignoring event kind: #{kind}" if defined?(LOG) && LOG.debug?
              [200, { status: "ignored", kind: kind }.to_json]
            end
          end

          private

          # Handle todo assignment changes.
          # If a todo with the epic prefix is assigned to a bot account, start orchestration.
          def handle_todo_assignment(payload, recording, details)
            added_person_ids = details["added_person_ids"] || []
            title = recording["title"] || ""
            todo_id = recording["id"]
            project_id = recording.dig("bucket", "id")

            # Check if any added person is a bot account
            added_person_ids.each do |person_id|
              bot_account = Config.bot_account_for_person(person_id)
              next unless bot_account

              agent = bot_account["default_agent"]
              LOG.info "[Basecamp:Webhook] Todo '#{title}' assigned to bot account (agent: #{agent})" if defined?(LOG)

              # Check if this is an epic (has the epic prefix)
              if title.start_with?(Config.epic_prefix)
                Thread.new do
                  Orchestrator.start_epic(
                    todo_id: todo_id,
                    project_id: project_id,
                    agent: agent,
                    title: title
                  )
                rescue StandardError => e
                  LOG.error "[Basecamp:Webhook] Epic start failed: #{e.message}\n#{e.backtrace.first(5).join("\n")}" if defined?(LOG)
                end

                return [200, { status: "epic_started", todo_id: todo_id, agent: agent }.to_json]
              else
                # Regular todo assigned to bot — could dispatch single card work
                LOG.info "[Basecamp:Webhook] Non-epic todo assigned to bot — ignoring for now" if defined?(LOG)
                return [200, { status: "ignored", reason: "not_an_epic" }.to_json]
              end
            end

            [200, { status: "ignored", reason: "no_bot_account_matched" }.to_json]
          end

          # Handle todo completed events.
          # If it's an epic todo being completed externally, mark our state accordingly.
          def handle_todo_completed(_payload, recording)
            todo_id = recording["id"].to_s

            epic = Orchestrator.all_epics.find { |e| e["basecamp_todo_id"] == todo_id }
            if epic && epic["status"] == "active"
              LOG.info "[Basecamp:Webhook] Epic todo #{todo_id} completed externally" if defined?(LOG)
              # Could mark epic as complete if done from Basecamp UI
            end

            [200, { status: "noted" }.to_json]
          end

          # Handle subtask (step) assignment changes.
          # Currently informational — the orchestrator drives assignment, not this hook.
          def handle_step_assignment(_payload, recording, details)
            LOG.debug "[Basecamp:Webhook] Step assignment changed: #{recording['title']}" if defined?(LOG) && LOG.debug?
            [200, { status: "noted" }.to_json]
          end
        end
      end
    end
  end
end
