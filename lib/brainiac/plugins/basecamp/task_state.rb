# frozen_string_literal: true

require "time"

module Brainiac
  module Plugins
    module Basecamp
      # The single authority for an epic task's lifecycle. Task hashes remain
      # serializable so existing persisted epics continue to work unchanged.
      module TaskState
        class InvalidTransition < StandardError; end

        STATES = %w[pending in_flight in_review final_decision complete merge_failed].freeze
        TRANSITIONS = {
          dispatch: { "pending" => "in_flight" },
          submit_for_review: { "pending" => "in_review", "in_flight" => "in_review" },
          request_changes: { "in_review" => "in_flight" },
          approve: { "in_review" => "final_decision" },
          complete: {
            "pending" => "complete",
            "in_flight" => "complete",
            "in_review" => "complete",
            "final_decision" => "complete"
          },
          merge_failed: { "final_decision" => "merge_failed" },
          retry_merge: { "merge_failed" => "final_decision" }
        }.freeze

        class << self
          def state(task)
            (task["status"] || "pending").to_s
          end

          def in?(task, *states)
            states.flatten.map(&:to_s).include?(state(task))
          end

          def transition!(task, event, triggered_by:, at: Time.now, guard: true)
            event = event.to_sym
            from_state = state(task)
            transitions = TRANSITIONS.fetch(event, {})
            return task if transitions.value?(from_state)

            to_state = transitions[from_state]

            unless to_state
              raise InvalidTransition, "cannot #{event} task from #{from_state}"
            end
            raise InvalidTransition, "guard failed for #{event} from #{from_state}" unless guard

            migrate!(task, at: at)
            timestamp = at.iso8601
            task["status"] = to_state
            task["transitions"] ||= []
            task["transitions"] << {
              "from_state" => from_state,
              "to_state" => to_state,
              "triggered_by" => triggered_by.to_s,
              "timestamp" => timestamp
            }
            task
          end

          # Adds a history entry for state created before this state machine
          # existed, without changing its current status.
          def migrate!(task, triggered_by: "state_machine_migration", at: Time.now)
            return task if task.key?("transitions")

            current = state(task)
            raise InvalidTransition, "unknown task state #{current}" unless STATES.include?(current)

            task["transitions"] = [{
              "from_state" => nil,
              "to_state" => current,
              "triggered_by" => triggered_by,
              "timestamp" => at.iso8601
            }]
            task
          end
        end
      end
    end
  end
end
