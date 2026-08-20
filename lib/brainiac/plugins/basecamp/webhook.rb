# frozen_string_literal: true

require "json"

module Brainiac
  module Plugins
    module Basecamp
      # Handles inbound Basecamp webhooks.
      #
      # Webhook types we care about:
      #   - todo_assignment_changed: A todo was assigned/unassigned
      #   - todo_completed: A todo was marked complete
      #   - todolist_created: A new todolist appeared (potential epic)
      #
      # The trigger for epic orchestration:
      #   When a todo inside a todolist (with "Epic:" prefix) is assigned to a bot account,
      #   OR when any todo in an epic's todolist is assigned to the bot.
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
            when "todolist_created"
              handle_todolist_created(payload, recording)
            when "comment_created"
              handle_comment(payload, recording)
            else
              LOG.debug "[Basecamp:Webhook] Ignoring event kind: #{kind}" if defined?(LOG) && LOG.debug?
              [200, { status: "ignored", kind: kind }.to_json]
            end
          end

          private

          # Handle todo assignment changes.
          #
          # Strategy: When a todo is assigned to a bot account, check if its parent
          # todolist is an epic (has the configured prefix). If so, start orchestration
          # on the entire todolist.
          def handle_todo_assignment(payload, recording, details)
            added_person_ids = details["added_person_ids"] || []
            title = recording["title"] || ""
            todo_id = recording["id"]
            project_id = recording.dig("bucket", "id")
            parent = recording["parent"] || {}
            parent_type = parent["type"]
            parent_title = parent["title"] || ""
            parent_id = parent["id"]

            # Check if any added person is a bot account
            added_person_ids.each do |person_id|
              bot_account = Config.bot_account_for_person(person_id)
              next unless bot_account

              agent = bot_account["default_agent"]
              LOG.info "[Basecamp:Webhook] Todo '#{title}' assigned to bot (agent: #{agent})" if defined?(LOG)

              # Check if the parent todolist is an epic
              epic_title = nil
              todolist_id = nil

              if parent_type == "Todolist"
                todolist_id = parent_id
                epic_title = parent_title
              end

              # If the todo itself has the epic prefix, it might be a standalone trigger
              # But for Option C, we expect the TODOLIST to have the prefix
              if todolist_id && epic_title&.start_with?(Config.epic_prefix)
                Thread.new do
                  Orchestrator.start_epic_from_todo(
                    todo_id: todo_id,
                    todolist_id: todolist_id,
                    project_id: project_id,
                    agent: agent,
                    title: epic_title
                  )
                rescue StandardError => e
                  LOG.error "[Basecamp:Webhook] Epic start failed: #{e.message}\n#{e.backtrace.first(5).join("\n")}" if defined?(LOG)
                end

                return [200, { status: "epic_started", todolist_id: todolist_id, agent: agent }.to_json]
              end

              # Also support: todo title itself starts with Epic: (single-todo trigger)
              if title.start_with?(Config.epic_prefix)
                LOG.info "[Basecamp:Webhook] Standalone epic todo detected — not a todolist. Ignoring." if defined?(LOG)
                return [200, { status: "ignored", reason: "standalone_epic_todo_not_supported" }.to_json]
              end

              LOG.info "[Basecamp:Webhook] Todo assigned to bot but parent '#{parent_title}' is not an epic" if defined?(LOG)
              return [200, { status: "ignored", reason: "parent_not_epic" }.to_json]
            end

            [200, { status: "ignored", reason: "no_bot_account_matched" }.to_json]
          end

          # Handle todo completed events.
          # If the todo is part of an active epic but was completed externally (not by the orchestrator),
          # we should still advance the epic state.
          def handle_todo_completed(_payload, recording)
            todo_id = recording["id"]
            title = recording["title"] || ""

            # Check if this todo is part of an active epic
            active = Orchestrator.active_epics
            active.each do |epic|
              task = epic["tasks"].find { |t| t["todo_id"].to_s == todo_id.to_s }
              next unless task
              next if task["status"] == "complete" # Already handled

              # Extract the fizzy card from the task
              fizzy_card = task["fizzy_card"]
              if fizzy_card
                LOG.info "[Basecamp:Webhook] Todo '#{title}' completed externally, advancing epic" if defined?(LOG)
                Thread.new { Orchestrator.on_card_completed(fizzy_card) }
              end

              return [200, { status: "epic_advanced", epic_id: epic["id"] }.to_json]
            end

            [200, { status: "noted" }.to_json]
          end

          # Handle new todolist creation.
          # If it has the epic prefix, we could optionally auto-detect it.
          # For now, just log it — orchestration starts on assignment.
          def handle_todolist_created(_payload, recording)
            title = recording["title"] || ""

            if title.start_with?(Config.epic_prefix)
              LOG.info "[Basecamp:Webhook] New epic todolist detected: '#{title}' — waiting for assignment to start" if defined?(LOG)
            end

            [200, { status: "noted" }.to_json]
          end

          # Handle comments on todos that are part of an epic.
          # Could be used for @bot commands within Basecamp comments.
          def handle_comment(_payload, recording)
            # Future: detect @bot commands in comments
            # e.g., "@Galen pause", "@Galen skip", "@Galen reassign to Sherlock"
            [200, { status: "noted" }.to_json]
          end
        end
      end
    end
  end
end
