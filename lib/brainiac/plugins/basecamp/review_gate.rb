# frozen_string_literal: true

module Brainiac
  module Plugins
    module Basecamp
      # Review gate system for epic tasks.
      #
      # Before a task is considered "complete" and dependents unblock,
      # it must pass through configured review gates. Each gate is an
      # agent that reviews the PR. All gates must approve before proceeding.
      #
      # Configuration in ~/.brainiac/basecamp.json:
      #   "review_gates": [
      #     { "agent": "Threepio", "role": "code_quality" },
      #     { "agent": "SecurityBot", "role": "security" }
      #   ]
      #
      # Flow:
      #   1. Agent completes task → PR opened against epic branch
      #   2. Orchestrator dispatches first gate agent to review the PR
      #   3. Gate agent approves → next gate dispatched (or task marked complete)
      #   4. Gate agent requests changes → original agent re-dispatched
      #   5. All gates pass → auto-merge → advance epic
      module ReviewGate
        class << self
          # Get the configured review gates.
          #
          # @return [Array<Hash>] Gate configs [{agent:, role:}]
          def gates
            Config.current["review_gates"] || []
          end

          # Check if review gates are configured.
          #
          # @return [Boolean]
          def enabled?
            gates.any?
          end

          # Get the current gate index for a task.
          # Returns nil if all gates have passed.
          #
          # @param task [Hash] Task state from epic
          # @return [Integer, nil] Index of the next gate to pass, or nil if all passed
          def current_gate_index(task)
            approvals = task["gate_approvals"] || []
            total_gates = gates.size

            return nil if total_gates.zero?
            return nil if approvals.size >= total_gates

            approvals.size
          end

          # Get the next gate agent that needs to review.
          #
          # @param task [Hash] Task state
          # @return [Hash, nil] Gate config {agent:, role:} or nil if all passed
          def next_gate(task)
            idx = current_gate_index(task)
            return nil unless idx

            gates[idx]
          end

          # Check if all gates have been passed for a task.
          #
          # @param task [Hash] Task state
          # @return [Boolean]
          def all_gates_passed?(task)
            return true unless enabled?

            approvals = task["gate_approvals"] || []
            approvals.size >= gates.size
          end

          # Record a gate approval.
          #
          # @param task [Hash] Task state (mutated in place)
          # @param agent [String] Agent that approved
          # @param role [String] Gate role
          def record_approval(task, agent:, role:)
            task["gate_approvals"] ||= []
            task["gate_approvals"] << {
              "agent" => agent,
              "role" => role,
              "approved_at" => Time.now.iso8601
            }
          end

          # Reset gate approvals (e.g., when changes are requested and code is updated).
          #
          # @param task [Hash] Task state (mutated in place)
          def reset_approvals(task)
            task["gate_approvals"] = []
          end

          # Dispatch the next gate agent to review a PR.
          #
          # @param epic [Hash] Epic state
          # @param task [Hash] Task state
          # @param pr_number [Integer, String, nil] PR number (if known)
          # @return [Boolean] Whether dispatch succeeded
          def dispatch_review(epic, task, pr_number: nil)
            gate = next_gate(task)
            return false unless gate

            agent_name = gate["agent"]
            card_number = task["fizzy_card"]
            role = gate["role"] || "review"

            LOG.info "[Basecamp:ReviewGate] Dispatching #{agent_name} (#{role}) to review card ##{card_number}" if defined?(LOG)

            # Mark the task as awaiting this gate
            task["status"] = "in_review"
            task["current_gate"] = { "agent" => agent_name, "role" => role, "dispatched_at" => Time.now.iso8601 }

            # Assign the Fizzy card to the review agent.
            # The review agent will see the PR and review it.
            # When brainiac-github detects the review approval, we advance.
            fizzy_user_id = resolve_review_agent_fizzy_id(agent_name)
            if fizzy_user_id
              Open3.capture3("fizzy", "card", "assign", card_number.to_s, "--user", fizzy_user_id)
              LOG.info "[Basecamp:ReviewGate] Assigned card ##{card_number} to #{agent_name} for #{role} review" if defined?(LOG)
            else
              LOG.warn "[Basecamp:ReviewGate] Could not resolve Fizzy user ID for #{agent_name}" if defined?(LOG)
            end

            # Post a comment on the Basecamp todo
            if task["todo_id"]
              Client.run_safe(
                "comments", "create", task["todo_id"].to_s,
                "👀 Review gate: **#{agent_name}** (#{role}) dispatched to review",
                "--in", epic["basecamp_project_id"], "--json"
              )
            end

            true
          end

          private

          # Resolve a review agent's Fizzy user ID.
          def resolve_review_agent_fizzy_id(agent_name)
            fizzy_config_file = File.join(
              ENV.fetch("BRAINIAC_DIR", File.join(Dir.home, ".brainiac")),
              "fizzy.json"
            )
            return nil unless File.exist?(fizzy_config_file)

            config = JSON.parse(File.read(fizzy_config_file))
            users = config["authorized_users"] || []

            # Match by display_name from agents.json
            agents_file = File.join(ENV.fetch("BRAINIAC_DIR", File.join(Dir.home, ".brainiac")), "agents.json")
            if File.exist?(agents_file)
              agents = JSON.parse(File.read(agents_file))
              agent_config = agents[agent_name.downcase]
              display_name = agent_config&.dig("display_name") || agent_name
            else
              display_name = agent_name
            end

            user = users.find { |u| u["name"].downcase == display_name.downcase }
            user&.dig("id")
          rescue StandardError
            nil
          end
        end
      end
    end
  end
end
