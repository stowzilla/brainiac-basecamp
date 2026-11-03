# frozen_string_literal: true

require "json"
require "open3"

module Brainiac
  module Plugins
    module Basecamp
      # Provisions a Basecamp person for a new brainiac agent (`brainiac agent
      # create` / `brainiac agent setup`): finds or invites the agent by email,
      # grants it access to every mapped project, and adds a bot_accounts entry.
      module AgentSetup
        class << self
          def run(agent_key, entry)
            display_name = entry["display_name"] || agent_key.capitalize
            config = load_config
            return unless config

            if (config["bot_accounts"] || {}).any? { |_name, bot| bot["default_agent"] == display_name }
              puts "  [Basecamp] ✓ #{display_name} already has a bot account (skipping)"
              return
            end

            project_ids = (config["project_mappings"] || {}).values.filter_map { |m| m["basecamp_project_id"]&.to_s }.uniq
            person_id = find_person(display_name) || invite(display_name, entry["email"], project_ids.first)
            return unless person_id

            project_ids.each { |pid| basecamp("people", "add", person_id, "--project", pid) }

            config["bot_accounts"] ||= {}
            config["bot_accounts"][agent_key] = { "person_id" => person_id, "default_agent" => display_name }
            File.write(config_file, JSON.pretty_generate(config))
            puts "  [Basecamp] ✓ #{display_name} (person #{person_id}) added to #{project_ids.size} project(s) and bot_accounts"
          end

          private

          def find_person(display_name)
            people = basecamp_json("people", "list", "--all") || []
            person = people.find { |p| p["name"]&.casecmp?(display_name) }
            person && person["id"].to_s
          end

          # Inviting someone new into a project creates the person and emails them.
          def invite(display_name, email, project_id)
            return nil unless $stdin.tty?

            unless email && project_id
              puts "  [Basecamp] Skipping — #{email ? 'no mapped projects' : 'no email (pass --email)'} to invite #{display_name}"
              return nil
            end

            print "  [Basecamp] Invite #{display_name} <#{email}> to Basecamp? [Y/n]: "
            return nil if $stdin.gets.to_s.strip.downcase.start_with?("n")

            body = { create: [{ name: display_name, email_address: email }] }.to_json
            result = basecamp_json("api", "put", "projects/#{project_id}/people/users.json", "-d", body)
            person = (result&.dig("granted") || []).find { |p| p["name"]&.casecmp?(display_name) }
            unless person
              puts "  [Basecamp] ⚠ Invite failed — invite #{email} by hand, then: brainiac agent setup #{display_name.downcase}"
              return nil
            end

            puts "  [Basecamp] ✓ Invited #{email} (accept from that inbox so the account is active)"
            person["id"].to_s
          end

          def basecamp_json(*)
            output = basecamp(*, "--quiet")
            output && JSON.parse(output)
          rescue JSON::ParserError
            nil
          end

          def basecamp(*)
            output, status = Open3.capture2("basecamp", *, err: File::NULL)
            status.success? ? output : nil
          rescue Errno::ENOENT
            nil
          end

          def config_file
            File.join(ENV.fetch("BRAINIAC_DIR", File.join(Dir.home, ".brainiac")), "basecamp.json")
          end

          def load_config
            File.exist?(config_file) ? JSON.parse(File.read(config_file)) : nil
          end
        end
      end
    end
  end
end
