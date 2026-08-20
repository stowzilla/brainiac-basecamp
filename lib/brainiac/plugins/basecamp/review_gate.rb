# frozen_string_literal: true

require "open3"

module Brainiac
  module Plugins
    module Basecamp
      # Review gate system for epic tasks.
      #
      # After an implementation agent completes a task PR, gate agents are
      # dispatched IN PARALLEL to review it. All gates must approve before
      # the PR auto-merges into the epic branch.
      #
      # Gate agents are triggered by:
      #   - :agent_completed on the task (initial review)
      #   - :pr_synchronized (re-review after fixes)
      #
      # Gate agents do NOT get assigned the Fizzy card — they review the PR
      # directly on GitHub using their bot app identities.
      #
      # Configuration in ~/.brainiac/basecamp.json:
      #   "review_gates": [
      #     { "agent": "GLaDOS", "role": "testing" },
      #     { "agent": "Threepio", "role": "code_quality" }
      #   ]
      #
      # All gates run in parallel by default. For sequential gates, add "order": N
      # (lower order runs first, same order runs in parallel).
      #
      # Gates can also be triggered by a Fizzy card tag "review-gates" for non-epic PRs.
      module ReviewGate
        BRAINIAC_DIR = ENV.fetch("BRAINIAC_DIR", File.join(Dir.home, ".brainiac"))

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

          # Check if all gates have approved for a task.
          #
          # @param task [Hash] Task state from epic
          # @return [Boolean]
          def all_gates_passed?(task)
            return true unless enabled?

            approvals = task["gate_approvals"] || []
            required_agents = gates.map { |g| g["agent"].downcase }
            approved_agents = approvals.map { |a| a["agent"].downcase }

            required_agents.all? { |agent| approved_agents.include?(agent) }
          end

          # Record a gate approval.
          #
          # @param task [Hash] Task state (mutated in place)
          # @param agent [String] Agent that approved
          # @param role [String] Gate role
          def record_approval(task, agent:, role:)
            task["gate_approvals"] ||= []
            # Don't duplicate
            return if task["gate_approvals"].any? { |a| a["agent"].downcase == agent.downcase }

            task["gate_approvals"] << {
              "agent" => agent,
              "role" => role,
              "approved_at" => Time.now.iso8601
            }
          end

          # Reset gate approvals (when changes are requested and code is updated).
          #
          # @param task [Hash] Task state (mutated in place)
          def reset_approvals(task)
            task["gate_approvals"] = []
          end

          # Dispatch all gate agents to review a PR in parallel.
          # Uses brainiac-github's app client to post review requests as each bot.
          #
          # @param epic [Hash] Epic state
          # @param task [Hash] Task state
          # @param pr_number [Integer, String] PR number
          # @param repo_name [String] e.g. "stowzilla/brainiac-basecamp"
          # @param repo_path [String] Local repo path
          # @return [Array<String>] Agent names dispatched
          def dispatch_gates(epic:, task:, pr_number:, repo_name:, repo_path:)
            dispatched = []

            gates.each do |gate|
              agent_name = gate["agent"]
              role = gate["role"] || "review"

              LOG.info "[Basecamp:ReviewGate] Dispatching #{agent_name} (#{role}) to review PR ##{pr_number}" if defined?(LOG)

              # Dispatch the gate agent via brainiac-github's PR review mechanism.
              # The agent gets the PR diff and reviews it using their bot identity.
              Thread.new do
                dispatch_agent_for_review(
                  agent_name: agent_name,
                  role: role,
                  pr_number: pr_number,
                  repo_name: repo_name,
                  repo_path: repo_path,
                  card_number: task["fizzy_card"],
                  epic: epic
                )
              rescue StandardError => e
                LOG.error "[Basecamp:ReviewGate] Failed to dispatch #{agent_name}: #{e.message}" if defined?(LOG)
              end

              dispatched << agent_name
            end

            # Update task state
            task["status"] = "in_review"
            task["gates_dispatched_at"] = Time.now.iso8601
            task["gate_approvals"] ||= []

            dispatched
          end

          # Build the summary comment for Fizzy after all gates pass and merge completes.
          #
          # @param task [Hash] Task state
          # @param pr_url [String] PR URL
          # @return [String] HTML comment for Fizzy
          def build_gate_summary_comment(task, pr_url:)
            approvals = task["gate_approvals"] || []
            lines = []
            lines << "<p>✅ <strong>All review gates passed</strong> — merged into epic branch.</p>"
            lines << "<p><a href=\"#{pr_url}\">PR Link</a></p>"
            lines << "<ul>"
            approvals.each do |approval|
              lines << "<li>#{approval['agent']} (#{approval['role']}): approved</li>"
            end
            lines << "</ul>"
            lines.join("\n")
          end

          # Check if a Fizzy card has the review-gates tag (for non-epic PRs).
          #
          # @param tags [Array] Fizzy card tags
          # @return [Boolean]
          def tag_triggered?(tags)
            tag_names = tags.map { |t| t.is_a?(Hash) ? t["name"] : t.to_s }.map(&:downcase)
            tag_names.include?("review-gates") || tag_names.include?("qa")
          end

          private

          # Dispatch a single gate agent to review a PR.
          # This creates a review prompt and runs the agent in the repo directory.
          def dispatch_agent_for_review(agent_name:, role:, pr_number:, repo_name:, repo_path:, card_number:, epic:)
            # Build a review-specific prompt for the gate agent
            prompt = build_gate_review_prompt(
              agent_name: agent_name,
              role: role,
              pr_number: pr_number,
              repo_name: repo_name,
              card_number: card_number,
              epic_title: epic["title"]
            )

            # Resolve the agent's GitHub token for their bot identity
            agent_env = resolve_agent_github_env(agent_name, repo_name)

            # Run the agent
            if defined?(run_agent)
              run_agent(prompt,
                        project_config: resolve_project_config(repo_path),
                        chdir: repo_path,
                        log_name: "gate-#{role}-#{card_number}",
                        agent_name: agent_name,
                        source: :github,
                        card_number: card_number,
                        env: agent_env)
            else
              LOG.warn "[Basecamp:ReviewGate] run_agent not available — gate dispatch skipped" if defined?(LOG)
            end
          end

          # Build the prompt for a gate review agent.
          def build_gate_review_prompt(agent_name:, role:, pr_number:, repo_name:, card_number:, epic_title:)
            <<~PROMPT
              You are reviewing PR ##{pr_number} on #{repo_name} as part of epic: "#{epic_title}".
              Your role: **#{role}**

              This is a review gate — the epic cannot proceed until you approve.

              Review the PR changes with `gh pr diff #{pr_number}` and `gh pr view #{pr_number}`.

              Based on your role (#{role}):
              #{role_instructions(role)}

              After your review:
              - If the code meets your standards: `gh pr review #{pr_number} --approve --body "your summary"`
              - If changes are needed: `gh pr review #{pr_number} --request-changes --body "what needs fixing"`

              Be thorough but pragmatic. This is Fizzy card ##{card_number}.
              Do NOT open new PRs or modify code — you are a reviewer only.
            PROMPT
          end

          # Role-specific review instructions.
          def role_instructions(role)
            case role.downcase
            when "testing", "tests", "qa"
              "- Verify tests exist for new functionality\n- Check test coverage\n- Run the test suite if possible\n- Flag missing edge cases"
            when "code_quality", "quality"
              "- Check code style and conventions\n- Look for code smells, duplication, complexity\n- Verify naming and structure\n- Ensure documentation for public interfaces"
            when "security"
              "- Check for security vulnerabilities\n- Verify input validation\n- Check for secrets/credentials in code\n- Review auth/authz changes"
            when "architecture"
              "- Verify design patterns are followed\n- Check for proper separation of concerns\n- Review API design\n- Flag any architectural concerns"
            else
              "- Review the changes thoroughly\n- Check for correctness and best practices"
            end
          end

          # Resolve a project config from repo path.
          def resolve_project_config(repo_path)
            projects_file = File.join(BRAINIAC_DIR, "projects.json")
            return {} unless File.exist?(projects_file)

            projects = JSON.parse(File.read(projects_file))
            projects.find { |_key, config| config["repo_path"] == repo_path }&.last || {}
          rescue StandardError
            {}
          end

          # Resolve GitHub env for an agent (GH_TOKEN from their app identity).
          def resolve_agent_github_env(agent_name, repo_name)
            # Try to use brainiac-github's AppClient if available
            if defined?(Brainiac::Plugins::Github::AppClient)
              repo_owner = repo_name.split("/").first
              token = Brainiac::Plugins::Github::AppClient.installation_token_for(agent_name, repo_owner: repo_owner)
              return { "GH_TOKEN" => token } if token
            end
            {}
          rescue StandardError
            {}
          end
        end
      end
    end
  end
end
