# frozen_string_literal: true

require "json"

module Brainiac
  module Plugins
    module Basecamp
      module Cli
        BRAINIAC_DIR = ENV.fetch("BRAINIAC_DIR", File.join(Dir.home, ".brainiac"))
        CONFIG_FILE = File.join(BRAINIAC_DIR, "basecamp.json")

        class << self
          def run(args)
            command = args.shift

            case command
            when "setup"
              cmd_setup
            when "config"
              cmd_config
            when "status"
              cmd_status
            when "epics"
              cmd_epics(args)
            when "link"
              cmd_link(args)
            when "bot"
              cmd_bot(args)
            when "projects"
              cmd_projects(args)
            else
              print_help
            end
          end

          private

          def cmd_setup
            puts "Basecamp Plugin Setup"
            puts "====================="
            puts ""

            # Check if basecamp CLI is installed
            unless system("which basecamp > /dev/null 2>&1")
              puts "❌ basecamp CLI not found. Install it first:"
              puts "   curl -fsSL https://basecamp.com/install-cli | bash"
              return
            end
            puts "✓ basecamp CLI found"

            # Check auth status
            auth_output = `basecamp auth status --json 2>/dev/null`
            if $?.success? && !auth_output.empty?
              puts "✓ Authenticated with Basecamp"
            else
              puts "❌ Not authenticated. Run: basecamp auth login"
              return
            end

            # Create config if it doesn't exist
            unless File.exist?(CONFIG_FILE)
              default_config = {
                "bot_accounts" => {},
                "project_mappings" => {},
                "epic_prefix" => "Epic:",
                "subtask_card_pattern" => '#(\d+)',
                "subtask_depends_pattern" => '\[depends:([\d,]+)\]'
              }
              File.write(CONFIG_FILE, JSON.pretty_generate(default_config))
              puts "✓ Created #{CONFIG_FILE}"
            else
              puts "✓ Config exists at #{CONFIG_FILE}"
            end

            puts ""
            puts "Next steps:"
            puts "  1. Add bot accounts:     brainiac basecamp bot add <name> <person-id> <agent>"
            puts "  2. Map projects:         brainiac basecamp projects map <brainiac-key> <basecamp-id>"
            puts "  3. Set up webhooks:      basecamp webhooks create \"https://your-ngrok/basecamp\" --types \"Todo,Todolist\" --in <project>"
            puts "  4. Install the plugin:   brainiac install basecamp --path #{File.expand_path('..', __dir__).gsub('/brainiac/plugins', '')}"
            puts "  5. Restart brainiac:     brainiac restart"
          end

          def cmd_config
            if File.exist?(CONFIG_FILE)
              config = JSON.parse(File.read(CONFIG_FILE))
              puts JSON.pretty_generate(config)
            else
              puts "No config found at #{CONFIG_FILE}"
              puts "Run: brainiac basecamp setup"
            end
          end

          def cmd_status
            puts "Basecamp Plugin Status"
            puts "======================"
            puts ""

            # Check CLI
            if system("which basecamp > /dev/null 2>&1")
              puts "  CLI:    ✓ installed"
            else
              puts "  CLI:    ✗ not found"
              return
            end

            # Check auth
            auth_output = `basecamp auth status --json 2>/dev/null`
            if $?.success?
              puts "  Auth:   ✓ authenticated"
            else
              puts "  Auth:   ✗ not authenticated"
            end

            # Check config
            if File.exist?(CONFIG_FILE)
              config = JSON.parse(File.read(CONFIG_FILE))
              puts "  Config: ✓ #{CONFIG_FILE}"
              puts "  Bots:   #{config['bot_accounts']&.size || 0} configured"
              puts "  Maps:   #{config['project_mappings']&.size || 0} project mappings"
            else
              puts "  Config: ✗ not configured"
            end

            # Check active epics
            epics_file = File.join(BRAINIAC_DIR, "basecamp_epics.json")
            if File.exist?(epics_file)
              epics = JSON.parse(File.read(epics_file))
              active = (epics["epics"] || []).count { |e| e["status"] == "active" }
              total = (epics["epics"] || []).size
              puts "  Epics:  #{active} active, #{total} total"
            else
              puts "  Epics:  none"
            end
          end

          def cmd_epics(args)
            epics_file = File.join(BRAINIAC_DIR, "basecamp_epics.json")
            unless File.exist?(epics_file)
              puts "No epics found."
              return
            end

            data = JSON.parse(File.read(epics_file))
            epics = data["epics"] || []

            if args.first == "--all"
              display_epics = epics
            else
              display_epics = epics.select { |e| e["status"] == "active" }
            end

            if display_epics.empty?
              puts "No #{args.first == '--all' ? '' : 'active '}epics."
              return
            end

            display_epics.each do |epic|
              tasks = epic["tasks"] || []
              complete = tasks.count { |t| t["status"] == "complete" }
              in_flight = tasks.count { |t| t["status"] == "in_flight" }
              total = tasks.size

              status_icon = epic["status"] == "active" ? "🚀" : "✅"
              puts "#{status_icon} #{epic['title']}"
              puts "   Agent: #{epic['agent']} | Tasks: #{complete}/#{total} complete, #{in_flight} in-flight"
              puts "   Started: #{epic['started_at']}"
              puts ""
            end
          end

          def cmd_link(args)
            fizzy_card = args.shift
            basecamp_url = args.shift

            unless fizzy_card && basecamp_url
              puts "Usage: brainiac basecamp link <fizzy-card-number> <basecamp-todo-url>"
              return
            end

            puts "TODO: Link Fizzy card ##{fizzy_card} to #{basecamp_url}"
            puts "(This will be used for manual linking outside of epic orchestration)"
          end

          def cmd_bot(args)
            action = args.shift

            case action
            when "add"
              name = args.shift
              person_id = args.shift
              agent = args.shift

              unless name && person_id && agent
                puts "Usage: brainiac basecamp bot add <name> <basecamp-person-id> <default-agent>"
                puts ""
                puts "Example:"
                puts "  brainiac basecamp bot add andy-server 12345 Galen"
                return
              end

              config = load_config
              config["bot_accounts"] ||= {}
              config["bot_accounts"][name] = {
                "person_id" => person_id,
                "default_agent" => agent
              }
              save_config(config)
              puts "✓ Added bot account '#{name}' (person_id: #{person_id}, agent: #{agent})"

            when "list"
              config = load_config
              bots = config["bot_accounts"] || {}
              if bots.empty?
                puts "No bot accounts configured."
              else
                bots.each do |name, account|
                  puts "  #{name}: person_id=#{account['person_id']}, agent=#{account['default_agent']}"
                end
              end

            when "remove"
              name = args.shift
              unless name
                puts "Usage: brainiac basecamp bot remove <name>"
                return
              end
              config = load_config
              if config["bot_accounts"]&.delete(name)
                save_config(config)
                puts "✓ Removed bot account '#{name}'"
              else
                puts "Bot account '#{name}' not found"
              end

            else
              puts "Usage: brainiac basecamp bot <add|list|remove>"
            end
          end

          def cmd_projects(args)
            action = args.shift

            case action
            when "map"
              brainiac_key = args.shift
              basecamp_id = args.shift

              unless brainiac_key && basecamp_id
                puts "Usage: brainiac basecamp projects map <brainiac-project-key> <basecamp-project-id>"
                puts ""
                puts "Example:"
                puts "  brainiac basecamp projects map marketplace 12345"
                return
              end

              config = load_config
              config["project_mappings"] ||= {}
              config["project_mappings"][brainiac_key] = {
                "basecamp_project_id" => basecamp_id
              }
              save_config(config)
              puts "✓ Mapped '#{brainiac_key}' → Basecamp project #{basecamp_id}"

            when "list"
              config = load_config
              mappings = config["project_mappings"] || {}
              if mappings.empty?
                puts "No project mappings configured."
              else
                mappings.each do |key, mapping|
                  puts "  #{key} → Basecamp project #{mapping['basecamp_project_id']}"
                end
              end

            when "unmap"
              key = args.shift
              unless key
                puts "Usage: brainiac basecamp projects unmap <brainiac-project-key>"
                return
              end
              config = load_config
              if config["project_mappings"]&.delete(key)
                save_config(config)
                puts "✓ Removed mapping for '#{key}'"
              else
                puts "Mapping for '#{key}' not found"
              end

            else
              puts "Usage: brainiac basecamp projects <map|list|unmap>"
            end
          end

          def print_help
            puts <<~HELP
              Usage: brainiac basecamp <command>

              Commands:
                setup                                   Interactive setup guide
                config                                  Show current config
                status                                  Check plugin status
                epics [--all]                           List active epics (--all for completed too)
                link <card> <url>                       Link a Fizzy card to a Basecamp todo
                bot add <name> <person-id> <agent>      Add a bot account mapping
                bot list                                List bot accounts
                bot remove <name>                       Remove a bot account
                projects map <key> <basecamp-id>        Map a Brainiac project to Basecamp
                projects list                           List project mappings
                projects unmap <key>                    Remove a project mapping

              Config file: ~/.brainiac/basecamp.json
              Epics state: ~/.brainiac/basecamp_epics.json
            HELP
          end

          def load_config
            if File.exist?(CONFIG_FILE)
              JSON.parse(File.read(CONFIG_FILE))
            else
              {}
            end
          end

          def save_config(config)
            File.write(CONFIG_FILE, JSON.pretty_generate(config))
          end
        end
      end

      def self.cli(args)
        Cli.run(args)
      end

      def self.completions
        %w[setup config status epics link bot projects]
      end
    end
  end
end
