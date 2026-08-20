# frozen_string_literal: true

# Lightweight metadata — loaded by `brainiac help` without the full plugin runtime.

require_relative "version"

module Brainiac
  module Plugins
    module Basecamp
      def self.configured?
        config_file = File.join(ENV.fetch("BRAINIAC_DIR", File.join(Dir.home, ".brainiac")), "basecamp.json")
        File.exist?(config_file)
      end

      def self.help_text
        "    brainiac basecamp <command>     Manage Basecamp epic orchestration"
      end
    end
  end
end
