# frozen_string_literal: true

module Brainiac
  module Plugins
    module Basecamp
      # Registers lifecycle hooks with the core event system.
      module Hooks
        class << self
          def register_all!
            register_agent_completed
          end

          private

          # When an agent session completes, check if the card is part of an active epic.
          # If so, advance the epic orchestration (mark task complete, dispatch next).
          def register_agent_completed
            Brainiac.on(:agent_completed) do |ctx|
              # Only care about Fizzy card completions that succeeded
              next unless ctx[:source] == :fizzy
              next unless ctx[:exit_status]&.zero? && !ctx[:signaled]

              card_number = ctx[:card_number]
              next unless card_number

              # Check if this card is part of an active epic
              Orchestrator.on_card_completed(card_number)
            end
          end
        end
      end
    end
  end
end
