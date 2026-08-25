# frozen_string_literal: true

require "json"

module Brainiac
  module Plugins
    module Basecamp
      # Configuration loader for brainiac-basecamp.
      #
      # Config file: ~/.brainiac/basecamp.json
      module Config
        BRAINIAC_DIR = ENV.fetch("BRAINIAC_DIR", File.join(Dir.home, ".brainiac"))
        CONFIG_FILE = File.join(BRAINIAC_DIR, "basecamp.json")

        # Default config structure.
        DEFAULT_CONFIG = {
          "bot_accounts" => {},
          "project_mappings" => {},
          "epic_prefix" => "Epic:",
          "fizzy_account_id" => nil,
          "review_gate" => "on_complete",
          "review_gates" => [],
          "deploy" => {
            "enabled" => false,
            "trigger" => "manual",
            "default_env" => nil,
            "project_envs" => {},
            "command" => "belt deploy {env} --auto"
          },
          "notifications" => {
            "epic_started" => true,
            "task_dispatched" => true,
            "task_completed" => true,
            "epic_completed" => true
          }
        }.freeze

        class << self
          # Load and cache config. Reloads if file has changed since last read.
          #
          # @return [Hash]
          def current
            return @config if @config && @config_mtime == config_mtime

            load!
            @config
          end

          # Force reload config from disk.
          def load!
            if File.exist?(CONFIG_FILE)
              raw = JSON.parse(File.read(CONFIG_FILE))
              @config = DEFAULT_CONFIG.merge(raw)
            else
              @config = DEFAULT_CONFIG.dup
            end
            @config_mtime = config_mtime
          rescue JSON::ParserError => e
            LOG.error "[Basecamp] Config parse error: #{e.message}" if defined?(LOG)
            @config = DEFAULT_CONFIG.dup
          end

          # Get bot account config for a given Basecamp person ID.
          #
          # @param person_id [String, Integer] Basecamp person ID
          # @return [Hash, nil] Bot account config or nil
          def bot_account_for_person(person_id)
            current["bot_accounts"].find do |_key, account|
              account["person_id"].to_s == person_id.to_s
            end&.then { |key, account| account.merge("key" => key) }
          end

          # Get the Basecamp project ID for a Brainiac project key.
          #
          # @param brainiac_project [String] Brainiac project key
          # @return [String, nil] Basecamp project ID
          def basecamp_project_for(brainiac_project)
            mapping = current["project_mappings"][brainiac_project]
            mapping&.dig("basecamp_project_id")
          end

          # Get the Brainiac project key for a Basecamp project/bucket ID.
          #
          # @param basecamp_project_id [String, Integer] Basecamp bucket ID
          # @return [String, nil] Brainiac project key
          def brainiac_project_for(basecamp_project_id)
            current["project_mappings"].find do |_key, mapping|
              mapping["basecamp_project_id"].to_s == basecamp_project_id.to_s
            end&.first
          end

          # The prefix used to identify epic todolists (e.g. "Epic: My Feature")
          #
          # @return [String]
          def epic_prefix
            current["epic_prefix"] || "Epic:"
          end

          # The Fizzy account ID (for building card URLs like app.fizzy.do/<id>/cards/N).
          #
          # @return [String, nil]
          def fizzy_account_id
            current["fizzy_account_id"]
          end

          # Review gate mode: "on_complete" (advance immediately) or "on_pr_merge" (wait for merge).
          #
          # @return [String]
          def review_gate
            current["review_gate"] || "on_complete"
          end

          # Deploy configuration.
          #
          # @return [Hash]
          def deploy
            current["deploy"] || DEFAULT_CONFIG["deploy"]
          end

          private

          def config_mtime
            File.exist?(CONFIG_FILE) ? File.mtime(CONFIG_FILE) : nil
          end
        end
      end
    end
  end
end
