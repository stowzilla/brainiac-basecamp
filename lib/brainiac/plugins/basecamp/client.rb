# frozen_string_literal: true

require "json"
require "open3"

module Brainiac
  module Plugins
    module Basecamp
      # Wrapper around the `basecamp` CLI binary.
      # Shells out with --json for structured responses.
      module Client
        class << self
          # Run a basecamp CLI command and return parsed JSON.
          #
          # @param args [Array<String>] CLI arguments
          # @param profile [String, nil] Named profile to use
          # @return [Hash] Parsed JSON response
          # @raise [ClientError] If the command fails
          def run(*args, profile: nil)
            cmd = ["basecamp"]
            profile ||= Config.current["basecamp_profile"]
            cmd += ["--profile", profile] if profile
            cmd += args.flatten

            LOG.debug "[Basecamp:Client] Running: #{cmd.join(' ')}" if defined?(LOG) && LOG.debug?

            stdout, stderr, status = Open3.capture3(*cmd)

            unless status.success?
              error_body = parse_json_safe(stdout) || parse_json_safe(stderr)
              error_msg = error_body&.dig("error") || stderr.strip.split("\n").first || "Unknown error"
              raise ClientError.new(error_msg, exit_code: status.exitstatus, response: error_body)
            end

            result = parse_json_safe(stdout)
            unless result
              raise ClientError.new("Failed to parse JSON response", exit_code: 0, response: nil)
            end

            result
          end

          # Run a basecamp CLI command, returning nil on failure instead of raising.
          #
          # @param args [Array<String>] CLI arguments
          # @param profile [String, nil] Named profile to use
          # @return [Hash, nil] Parsed JSON response or nil
          def run_safe(*args, profile: nil)
            run(*args, profile: profile)
          rescue ClientError => e
            LOG.warn "[Basecamp:Client] Command failed: #{e.message}" if defined?(LOG)
            nil
          end

          # Get a todo by ID with subtasks info.
          #
          # @param todo_id [String, Integer] Todo ID
          # @param project [String, Integer] Basecamp project/bucket ID
          # @return [Hash, nil]
          def get_todo(todo_id, project:)
            run("todos", "show", todo_id.to_s, "--in", project.to_s, "--json")
          end

          # List subtasks (steps) for a todo.
          #
          # @param todo_id [String, Integer] Parent todo ID
          # @param project [String, Integer] Basecamp project/bucket ID
          # @return [Hash, nil]
          def get_subtasks(todo_id, project:)
            # Basecamp models todo subtasks as Kanban::Step records
            # Use the recordings list filtered by type and parent
            run("recordings", "list", "--in", project.to_s, "--type", "Kanban::Step",
                "--all", "--json")
          end

          # Complete a subtask.
          #
          # @param step_id [String, Integer] Step/subtask ID
          # @param project [String, Integer] Basecamp project/bucket ID
          # @return [Hash, nil]
          def complete_subtask(step_id, project:)
            # Use raw API to complete a step
            run("api", "put",
                "/buckets/#{project}/card_tables/steps/#{step_id}/completions.json",
                "--data", '{"completion":"on"}', "--json")
          end

          # Add a comment to a recording (todo, card, message, etc.)
          #
          # @param recording_id [String, Integer] The recording to comment on
          # @param content [String] Comment content (Markdown)
          # @param project [String, Integer] Basecamp project/bucket ID
          # @return [Hash, nil]
          def add_comment(recording_id, content, project:)
            run("comments", "create", recording_id.to_s, content, "--in", project.to_s, "--json")
          end

          # Complete a todo.
          #
          # @param todo_id [String, Integer] Todo ID
          # @return [Hash, nil]
          def complete_todo(todo_id)
            run("todos", "complete", todo_id.to_s, "--json")
          end

          # List projects.
          #
          # @return [Hash]
          def list_projects
            run("projects", "list", "--json")
          end

          # Parse a Basecamp URL to extract IDs.
          #
          # @param url [String] Basecamp URL
          # @return [Hash, nil]
          def parse_url(url)
            run("url", "parse", url, "--json")
          end

          # Check auth status.
          #
          # @return [Hash, nil]
          def auth_status
            run_safe("auth", "status", "--json")
          end

          private

          def parse_json_safe(str)
            return nil if str.nil? || str.strip.empty?

            JSON.parse(str)
          rescue JSON::ParserError
            nil
          end
        end
      end

      # Error class for CLI failures.
      class ClientError < StandardError
        attr_reader :exit_code, :response

        def initialize(message, exit_code: nil, response: nil)
          @exit_code = exit_code
          @response = response
          super(message)
        end
      end
    end
  end
end
