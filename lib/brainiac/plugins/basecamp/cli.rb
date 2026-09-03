# frozen_string_literal: true

require "json"
require "open3"
require_relative "config"
require_relative "epic"

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
            when "deploy"
              cmd_deploy(args)
            when "link"
              cmd_link(args)
            when "bot"
              cmd_bot(args)
            when "projects"
              cmd_projects(args)
            when "set"
              cmd_set(args)
            when "reset"
              cmd_reset(args)
            when "scrap"
              cmd_scrap(args)
            when "webhook", "webhooks"
              cmd_webhook(args)
            else
              print_help
            end
          end

          # The canonical set of webhook event types this plugin needs.
          # Add new types here as features are added — webhook sync will pick them up.
          REQUIRED_WEBHOOK_TYPES = %w[Todo Todolist Comment].freeze

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
                "fizzy_account_id" => nil,
                "review_gate" => "on_complete",
                "notifications" => {
                  "epic_started" => true,
                  "task_dispatched" => true,
                  "task_completed" => true,
                  "epic_completed" => true
                }
              }
              File.write(CONFIG_FILE, JSON.pretty_generate(default_config))
              puts "✓ Created #{CONFIG_FILE}"
            else
              puts "✓ Config exists at #{CONFIG_FILE}"
            end

            puts ""
            puts "Next steps:"
            puts "  1. Set Fizzy account ID:  brainiac basecamp set fizzy-account-id <your-fizzy-account-id>"
            puts "  2. Add bot accounts:     brainiac basecamp bot add <name> <person-id> <agent>"
            puts "  3. Map projects:         brainiac basecamp projects map <brainiac-key> <basecamp-id>"
            puts "  4. Set review gate:      brainiac basecamp set review-gate <on_complete|on_pr_merge>"
            puts "  5. Set up webhooks:      basecamp webhooks create \"https://your-ngrok/basecamp\" " \
                 "--types \"Todo,Todolist,Comment\" --in <project>"
            puts "  6. Restart brainiac:     brainiac restart"
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

            if args.include?("--all")
              display_epics = epics
            else
              display_epics = epics.select { |e| e["status"] == "active" }
            end

            if display_epics.empty?
              puts "No #{args.include?('--all') ? '' : 'active '}epics."
              return
            end

            display_epics.each do |epic|
              tasks = epic["tasks"] || []
              complete = tasks.count { |t| t["status"] == "complete" }
              in_flight = tasks.count { |t| t["status"] == "in_flight" }
              total = tasks.size

              status_icon = epic["status"] == "active" ? "🚀" : "✅"

              # Show deploy env if configured
              deploy_env = Basecamp::Epic.extract_deploy_env(epic["title"], epic["description"])
              deploy_display = deploy_env ? " [deploy:#{deploy_env}]" : ""

              puts "#{status_icon} #{epic['title']}#{deploy_display}"
              puts "   Todolist: #{epic['basecamp_todolist_id']} | Agent: #{epic['agent']}"
              puts "   Tasks: #{complete}/#{total} complete, #{in_flight} in-flight"
              puts "   Started: #{epic['started_at']}"

              # Show last deploy if present
              if epic["last_deploy"]
                ld = epic["last_deploy"]
                deploy_status = ld["status"] == "success" ? "✅" : "❌"
                puts "   Last deploy: #{deploy_status} #{ld['env']} @ #{ld['at']}"
              end

              # Show per-task detail if verbose or few tasks
              if args.include?("--verbose") || args.include?("-v")
                tasks.each do |t|
                  icon = case t["status"]
                         when "complete" then "✅"
                         when "in_flight" then "🚀"
                         when "in_review" then "👀"
                         when "final_decision" then "⚡"
                         else "⬜"
                         end
                  puts "     #{icon} ##{t['fizzy_card']} — #{t['title']} [#{t['status']}]"
                end
              end
              puts ""
            end
          end

          def cmd_deploy(args)
            epic_id = args.shift
            env_override = args.shift

            unless epic_id
              puts "Usage: brainiac basecamp deploy <epic-id> [env]"
              puts ""
              puts "Deploy an epic's worktree to the specified environment."
              puts ""
              puts "Arguments:"
              puts "  <epic-id>    Basecamp todolist ID for the epic"
              puts "  [env]        Environment to deploy to (overrides epic's [deploy:env])"
              puts ""
              puts "Environment resolution (in order):"
              puts "  1. Explicit env argument"
              puts "  2. [deploy:env] in epic title"
              puts "  3. deploy:env in epic description"
              puts "  4. deploy.default_env in config"
              puts ""
              puts "Active epics:"
              list_epics_for_deploy
              return
            end

            # Load epic
            epics = load_epics
            epic = epics.find { |e| e["basecamp_todolist_id"] == epic_id.to_s }

            unless epic
              puts "❌ No epic found with todolist ID #{epic_id}"
              puts ""
              puts "Active epics:"
              list_epics_for_deploy
              return
            end

            # Resolve deploy environment
            deploy_env = resolve_deploy_env(epic, env_override)

            unless deploy_env
              puts "❌ No deploy environment specified."
              puts ""
              puts "Either:"
              puts "  1. Pass env as argument: brainiac basecamp deploy #{epic_id} dev02"
              puts "  2. Add [deploy:env] to epic title: \"Epic: My Feature [deploy:dev02]\""
              puts "  3. Add deploy:env to epic description"
              puts "  4. Set deploy.project_envs.<project> in ~/.brainiac/basecamp.json"
              puts "  5. Set deploy.default_env in ~/.brainiac/basecamp.json"
              return
            end

            # Find worktree
            worktree_path = find_epic_worktree(epic)

            unless worktree_path
              puts "❌ No worktree found for epic '#{epic['title']}'"
              puts "   Epic branch mode may not be enabled, or no tasks have been dispatched."
              return
            end

            puts "🚀 Deploying epic '#{epic['title']}'"
            puts "   Environment: #{deploy_env}"
            puts "   Worktree: #{worktree_path}"
            puts ""

            # Pull latest changes before deploying
            puts "Pulling latest changes..."
            pull_output, pull_status = Open3.capture2e("git", "pull", "--ff-only", chdir: worktree_path)
            if pull_status.success?
              if pull_output.include?("Already up to date")
                puts "Already up to date."
              else
                puts pull_output.lines.first(5).join
              end
            else
              puts "⚠️  Git pull failed (continuing anyway):"
              puts pull_output.lines.first(3).join
            end
            puts ""

            # Run deploy
            success = run_deploy(worktree_path, deploy_env)

            puts ""

            if success
              puts "✅ Deploy completed successfully"

              # Update epic state
              epic["last_deploy"] = {
                "env" => deploy_env,
                "at" => Time.now.iso8601,
                "status" => "success"
              }
            else
              puts "❌ Deploy failed"

              epic["last_deploy"] = {
                "env" => deploy_env,
                "at" => Time.now.iso8601,
                "status" => "failed"
              }
            end

            save_epics(epics)

            # Change into the worktree directory
            puts ""
            puts "Entering worktree..."
            Dir.chdir(worktree_path)
            exec ENV.fetch("SHELL", "/bin/bash")
          end

          def cmd_scrap(args)
            todolist_id = args.shift

            dry_run = args.delete("--dry-run") || args.delete("-n")
            confirmed = args.delete("--confirm") || args.delete("-y")
            keep_cards = args.delete("--keep-cards")

            unless todolist_id
              puts "Usage: brainiac basecamp scrap <todolist-id> [options]"
              puts ""
              puts "Scrap an epic — full teardown of all related resources."
              puts ""
              puts "Options:"
              puts "  --confirm, -y       Skip confirmation prompt"
              puts "  --dry-run, -n       Show what would happen without doing it"
              puts "  --keep-cards        Don't close the Fizzy cards (keep them for re-planning)"
              puts ""
              puts "This will:"
              puts "  1. Close all Fizzy cards in the epic (unless --keep-cards)"
              puts "  2. Close any open PRs targeting the epic branch"
              puts "  3. Delete the epic branch from all repos"
              puts "  4. Mark all Basecamp todos complete with a 🗑️ comment"
              puts "  5. Clean up epic memory files"
              puts "  6. Remove the epic from state"
              puts ""
              puts "Active epics:"
              scrappable_statuses = %w[active cancelled]
              load_epics.select { |e| scrappable_statuses.include?(e["status"]) }.each do |e|
                puts "  #{e['basecamp_todolist_id']} — #{e['title']} [#{e['status']}]"
              end
              return
            end

            epics = load_epics
            epic = epics.find { |e| e["basecamp_todolist_id"] == todolist_id.to_s }

            unless epic
              puts "❌ No epic found with todolist ID #{todolist_id}"
              puts ""
              puts "Known epics:"
              epics.each do |e|
                puts "  #{e['basecamp_todolist_id']} — #{e['title']} [#{e['status']}]"
              end
              return
            end

            tasks = epic["tasks"] || []
            epic_branches = epic["epic_branches"] || {}
            card_numbers = tasks.filter_map { |t| t["fizzy_card"] }

            # Preview what we're about to do
            puts dry_run ? "🔍 DRY RUN — nothing will be changed" : "🗑️  Scrapping epic: #{epic['title']}"
            puts ""
            puts "Epic:     #{epic['title']}"
            puts "Status:   #{epic['status']}"
            puts "Todolist: #{epic['basecamp_todolist_id']}"
            puts "Tasks:    #{tasks.size}"
            puts ""

            actions = []

            # 1. Fizzy cards to close
            unless keep_cards
              if card_numbers.any?
                actions << { type: :close_cards, cards: card_numbers }
                puts "  📋 Close #{card_numbers.size} Fizzy card(s): #{card_numbers.map { |c| "##{c}" }.join(', ')}"
              end
            else
              puts "  📋 Keep Fizzy cards (--keep-cards)"
            end

            # 2. Close open PRs and delete epic branches
            if epic_branches.any?
              epic_branches.each do |project_key, branch_name|
                actions << { type: :close_prs_and_delete_branch, project: project_key, branch: branch_name }
                puts "  🌿 Delete branch '#{branch_name}' in #{project_key} (close open PRs first)"
              end
            end

            # 3. Mark Basecamp todos complete
            todo_ids = tasks.filter_map { |t| t["todo_id"] }
            if todo_ids.any?
              actions << { type: :complete_todos, todo_ids: todo_ids, project_id: epic["basecamp_project_id"] }
              puts "  ✓  Mark #{todo_ids.size} Basecamp todo(s) complete"
            end

            # 4. Clean up epic memory
            actions << { type: :cleanup_memory, todolist_id: todolist_id }
            puts "  🧹 Clean up epic memory"

            # 5. Remove from state
            actions << { type: :remove_from_state, epic_id: epic["id"] }
            puts "  💾 Remove epic from state file"

            puts ""

            if dry_run
              puts "No changes made. Remove --dry-run to execute."
              return
            end

            # Confirm unless --confirm passed
            unless confirmed
              print "Proceed? [y/N] "
              answer = $stdin.gets&.strip&.downcase
              unless %w[y yes].include?(answer)
                puts "Aborted."
                return
              end
            end

            puts ""
            puts "Scrapping..."

            errors = []

            actions.each do |action|
              case action[:type]
              when :close_cards
                action[:cards].each do |card_number|
                  result = scrap_close_fizzy_card(card_number)
                  if result
                    puts "  ✓ Closed Fizzy card ##{card_number}"
                  else
                    errors << "Failed to close Fizzy card ##{card_number}"
                    puts "  ✗ Failed to close Fizzy card ##{card_number}"
                  end
                end

              when :close_prs_and_delete_branch
                project_key = action[:project]
                branch_name = action[:branch]
                repo_path = resolve_repo_path(project_key)

                if repo_path
                  # Close any open PRs targeting or from the epic branch
                  closed_prs = scrap_close_epic_prs(repo_path, branch_name)
                  closed_prs.each { |pr| puts "  ✓ Closed PR ##{pr} in #{project_key}" }

                  # Delete the remote branch
                  if scrap_delete_branch(repo_path, branch_name)
                    puts "  ✓ Deleted branch '#{branch_name}' in #{project_key}"
                  else
                    errors << "Failed to delete branch '#{branch_name}' in #{project_key}"
                    puts "  ✗ Failed to delete branch '#{branch_name}' in #{project_key}"
                  end
                else
                  errors << "Could not resolve repo path for project '#{project_key}'"
                  puts "  ✗ Could not resolve repo path for '#{project_key}'"
                end

              when :complete_todos
                action[:todo_ids].each do |todo_id|
                  scrap_complete_todo(todo_id, action[:project_id], epic["agent"])
                end
                puts "  ✓ Marked #{action[:todo_ids].size} todo(s) complete in Basecamp"

              when :cleanup_memory
                EpicMemory.cleanup(action[:todolist_id], archive: false)
                puts "  ✓ Cleaned up epic memory"

              when :remove_from_state
                epics.reject! { |e| e["id"] == action[:epic_id] }
                save_epics(epics)
                puts "  ✓ Removed epic from state"
              end
            end

            puts ""
            if errors.empty?
              puts "✅ Epic scrapped successfully."
            else
              puts "⚠️  Epic scrapped with #{errors.size} error(s):"
              errors.each { |e| puts "    - #{e}" }
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

              # If person_id is omitted but agent is given, or only agent name given,
              # try to auto-resolve from Basecamp
              if name && !person_id
                # Single arg: treat as agent name, auto-resolve
                agent = name
                person_id = auto_resolve_person_id(agent)
                unless person_id
                  puts "❌ Could not find '#{agent}' in Basecamp people list."
                  puts "   Try: basecamp people list --jq '.data[] | {id, name}'"
                  return
                end
                name = agent.downcase
              elsif name && person_id && !agent
                # Two args: name + agent, auto-resolve person_id
                agent = person_id
                person_id = auto_resolve_person_id(agent)
                unless person_id
                  puts "❌ Could not find '#{agent}' in Basecamp people list."
                  puts "   Provide the person_id manually:"
                  puts "   brainiac basecamp bot add <name> <person-id> <agent>"
                  return
                end
              elsif !(name && person_id && agent)
                puts "Usage: brainiac basecamp bot add <agent-name>"
                puts "       brainiac basecamp bot add <name> <agent-name>"
                puts "       brainiac basecamp bot add <name> <basecamp-person-id> <agent-name>"
                puts ""
                puts "Examples:"
                puts "  brainiac basecamp bot add Galen                    # auto-resolves person_id"
                puts "  brainiac basecamp bot add andy-server Galen        # auto-resolves person_id"
                puts "  brainiac basecamp bot add andy-server 52992796 Galen"
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

            when "sync"
              # Auto-discover agents from ~/.brainiac/agents.json and resolve their
              # Basecamp person IDs. Creates bot_account entries for any that match.
              config = load_config
              config["bot_accounts"] ||= {}

              agents = load_agents_registry
              if agents.empty?
                puts "No agents found in ~/.brainiac/agents.json"
                return
              end

              puts "Syncing bot accounts from agents registry..."
              puts "Found #{agents.size} agent(s): #{agents.map { |k, v| v['display_name'] || k }.join(', ')}"
              puts ""

              added = 0
              updated = 0
              not_found = 0

              agents.each do |key, agent_config|
                display_name = agent_config["display_name"] || key.capitalize
                # Skip the meta "brainiac" agent
                next if key == "brainiac"

                resolved_id = auto_resolve_person_id(display_name)

                if resolved_id
                  existing = config["bot_accounts"].find { |_k, v| v["default_agent"] == display_name }

                  if existing
                    _existing_key, existing_account = existing
                    if existing_account["person_id"].to_s == resolved_id.to_s
                      puts "  \u00b7 #{display_name}: #{resolved_id} (unchanged)"
                    else
                      existing_account["person_id"] = resolved_id
                      updated += 1
                      puts "  \u2191 #{display_name}: updated person_id \u2192 #{resolved_id}"
                    end
                  else
                    # Create new bot_account entry using agent key as the account name
                    config["bot_accounts"][key] = {
                      "person_id" => resolved_id,
                      "default_agent" => display_name
                    }
                    added += 1
                    puts "  + #{display_name}: #{resolved_id} (new)"
                  end
                else
                  puts "  \u2717 #{display_name}: not found in Basecamp"
                  not_found += 1
                end
              end

              if (added + updated).positive?
                save_config(config)
                puts ""
                puts "\u2713 Added #{added}, updated #{updated} bot account(s)" if added.positive? || updated.positive?
              else
                puts "\nAll bot accounts already up to date."
              end
              puts "  (#{not_found} agent(s) not found in Basecamp)" if not_found.positive?
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

          def cmd_webhook(args)
            action = args.shift

            case action
            when "sync"
              cmd_webhook_sync
            else
              puts "Usage: brainiac basecamp webhook <command>"
              puts ""
              puts "Commands:"
              puts "  sync    Ensure all project webhooks have the required event types"
            end
          end

          def cmd_webhook_sync
            config = load_config
            mappings = config["project_mappings"] || {}

            if mappings.empty?
              puts "No project mappings configured. Add one first:"
              puts "  brainiac basecamp projects map <key> <basecamp-project-id>"
              return
            end

            updated = 0
            skipped = 0
            not_found = 0

            mappings.each do |key, mapping|
              project_id = mapping["basecamp_project_id"]
              puts "Checking project '#{key}' (Basecamp #{project_id})..."

              # List webhooks for this project
              output, status = Open3.capture2("basecamp", "webhooks", "list", "--in", project_id.to_s, "--json")
              unless status.success?
                puts "  ✗ Failed to list webhooks"
                not_found += 1
                next
              end

              data = JSON.parse(output)
              webhooks = data["data"] || []

              if webhooks.empty?
                puts "  ⚠ No webhooks found"
                not_found += 1
                next
              end

              # Find webhooks that point to a /basecamp endpoint (ours)
              our_webhooks = webhooks.select { |wh| wh["payload_url"]&.include?("/basecamp") }

              if our_webhooks.empty?
                puts "  ⚠ No webhooks with /basecamp endpoint found"
                not_found += 1
                next
              end

              our_webhooks.each do |wh|
                current_types = wh["types"] || []
                missing_types = REQUIRED_WEBHOOK_TYPES - current_types

                if missing_types.empty?
                  puts "  · Webhook #{wh['id']} (#{wh['payload_url']}): up to date"
                  skipped += 1
                  next
                end

                new_types = (current_types + missing_types).uniq
                puts "  ↑ Webhook #{wh['id']}: adding #{missing_types.join(', ')}"

                _, stderr, update_status = Open3.capture3(
                  "basecamp", "webhooks", "update", wh["id"].to_s,
                  "--types", new_types.join(","),
                  "--in", project_id.to_s
                )

                if update_status.success?
                  puts "    ✓ Updated: #{new_types.join(', ')}"
                  updated += 1
                else
                  puts "    ✗ Failed: #{stderr.strip}"
                end
              end
            end

            puts ""
            if updated.positive?
              puts "✓ Updated #{updated} webhook(s)"
            elsif skipped.positive? && updated.zero?
              puts "All webhooks already have required types: #{REQUIRED_WEBHOOK_TYPES.join(', ')}"
            else
              puts "No webhooks updated."
            end
          end

          def print_help
            puts <<~HELP
              Usage: brainiac basecamp <command>

              Commands:
                setup                                   Interactive setup guide
                config                                  Show current config
                status                                  Check plugin status
                epics [--all] [-v]                      List active epics (--all for completed too)
                deploy <epic-id> [env]                  Deploy epic worktree to environment
                link <card> <url>                       Link a Fizzy card to a Basecamp todo
                bot add <agent-name>                    Add bot (auto-resolves person_id from Basecamp)
                bot add <name> <person-id> <agent>      Add bot with explicit person_id
                bot sync                                Re-resolve all bot person IDs from Basecamp
                bot list                                List bot accounts
                bot remove <name>                       Remove a bot account
                projects map <key> <basecamp-id>        Map a Brainiac project to Basecamp
                projects list                           List project mappings
                projects unmap <key>                    Remove a project mapping
                set fizzy-account-id <id>               Set Fizzy account ID (for card URLs)
                set review-gate <mode>                  Set review gate (on_complete or on_pr_merge)
                set epic-prefix <prefix>                Set epic todolist prefix (default: "Epic:")
                reset task <card-number> [--to <status>] Reset a task to a given status (default: pending)
                reset epic <todolist-id> [--to <status>] Reset entire epic or all tasks within it
                reset gates <card-number>               Clear gate approvals and re-dispatch gates
                scrap <todolist-id> [--confirm]         Scrap an epic: close cards, delete branches, clean up
                webhook sync                            Ensure webhooks have all required event types

              Config file: ~/.brainiac/basecamp.json
              Epics state: ~/.brainiac/basecamp_epics.json

              Review gate modes:
                on_complete   — Advance to next task as soon as agent finishes (default)
                on_pr_merge   — Wait for PR to be merged before advancing (review gate)

              Deploy environment resolution (in order):
                1. Explicit env argument: brainiac basecamp deploy 12345 dev02
                2. [deploy:env] in epic title: "Epic: My Feature [deploy:dev02]"
                3. deploy:env in epic description
                4. deploy.project_envs.<project> in config (per-project default)
                5. deploy.default_env in config (global default)

              Task statuses (for reset --to):
                pending         — Not yet started, waiting for dependencies
                in_flight       — Agent is actively working on it
                in_review       — PR open, gates reviewing
                final_decision  — Gates passed, awaiting implementation agent merge decision
                complete        — Done
            HELP
          end

          def cmd_set(args)
            key = args.shift
            value = args.shift

            unless key && value
              puts "Usage: brainiac basecamp set <key> <value>"
              puts ""
              puts "Keys:"
              puts "  fizzy-account-id <id>      Fizzy account ID (for card URLs)"
              puts "  review-gate <mode>         on_complete or on_pr_merge"
              puts "  epic-prefix <prefix>       Todolist prefix for epic detection"
              return
            end

            config = load_config

            case key
            when "fizzy-account-id"
              config["fizzy_account_id"] = value
              save_config(config)
              puts "✓ Set fizzy_account_id = #{value}"
              puts "  Card URLs will be: https://app.fizzy.do/#{value}/cards/NNNN"
            when "review-gate"
              unless %w[on_complete on_pr_merge epic_branch].include?(value)
                puts "Error: review-gate must be 'on_complete', 'on_pr_merge', or 'epic_branch'"
                return
              end
              config["review_gate"] = value
              save_config(config)
              puts "✓ Set review_gate = #{value}"
              case value
              when "on_pr_merge"
                puts "  Epic tasks will wait for PR merge before advancing to next task"
              when "epic_branch"
                puts "  Epic tasks auto-merge into an epic branch. Final PR to main when epic completes."
                puts "  Best for overnight/autonomous execution."
              else
                puts "  Epic tasks advance immediately when agent completes"
              end
            when "epic-prefix"
              config["epic_prefix"] = value
              save_config(config)
              puts "✓ Set epic_prefix = #{value}"
            when "profile"
              config["basecamp_profile"] = value
              save_config(config)
              puts "✓ Set basecamp_profile = #{value}"
              puts "  All basecamp CLI commands will use --profile #{value}"
              puts "  Set up the profile: basecamp profile create #{value} && basecamp auth login --profile #{value}"
            else
              puts "Unknown key: #{key}"
              puts "Valid keys: fizzy-account-id, review-gate, epic-prefix, profile"
            end
          end

          def cmd_reset(args)
            subcommand = args.shift

            case subcommand
            when "task"
              cmd_reset_task(args)
            when "epic"
              cmd_reset_epic(args)
            when "gates"
              cmd_reset_gates(args)
            else
              puts <<~HELP
                Usage: brainiac basecamp reset <subcommand>

                Subcommands:
                  task <card-number> [--to <status>]    Reset a task's status (default: pending)
                  epic <todolist-id> [--to <status>]    Reset entire epic or all its tasks
                  gates <card-number>                   Clear gate approvals and re-dispatch

                Task statuses:
                  pending, in_flight, in_review, final_decision, complete

                Examples:
                  brainiac basecamp reset task 1234                  # Reset card #1234 to pending
                  brainiac basecamp reset task 1234 --to in_flight   # Reset to in_flight
                  brainiac basecamp reset gates 1234                 # Clear gates, re-dispatch reviewers
                  brainiac basecamp reset epic 10233212224            # Reset all tasks to pending
                  brainiac basecamp reset epic 10233212224 --to pending  # Same as above
              HELP
            end
          end

          def cmd_reset_task(args)
            card_number = args.shift&.gsub(/^#/, "")
            unless card_number
              puts "Usage: brainiac basecamp reset task <card-number> [--to <status>]"
              return
            end

            target_status = parse_to_flag(args) || "pending"
            unless valid_task_status?(target_status)
              puts "Error: Invalid status '#{target_status}'"
              puts "Valid statuses: pending, in_flight, in_review, final_decision, complete"
              return
            end

            epics = load_epics
            epic = epics.find do |e|
              e["status"] == "active" &&
                e["tasks"]&.any? { |t| t["fizzy_card"] == card_number.to_i }
            end

            unless epic
              puts "Error: Card ##{card_number} not found in any active epic"
              return
            end

            task = epic["tasks"].find { |t| t["fizzy_card"] == card_number.to_i }
            old_status = task["status"]

            # Reset the task
            reset_task_to(task, target_status)

            # If completing this task leaves every task in the epic complete,
            # seal the epic in the same atomic write so the reconcile loop never
            # re-fires the completion notification.
            finalized = finalize_epic_if_all_complete!(epic)

            save_epics(epics)
            puts "✓ Reset card ##{card_number} from '#{old_status}' → '#{target_status}'"
            puts "  Epic: #{epic['title']}"
            puts "✓ All tasks complete — epic finalized (status=complete, notification suppressed)" if finalized

            return unless target_status == "pending"

            puts "  The task will be picked up on next dispatch cycle (restart brainiac or wait for next event)"
          end

          def cmd_reset_gates(args)
            card_number = args.shift&.gsub(/^#/, "")
            unless card_number
              puts "Usage: brainiac basecamp reset gates <card-number>"
              return
            end

            epics = load_epics
            epic = epics.find do |e|
              e["status"] == "active" &&
                e["tasks"]&.any? { |t| t["fizzy_card"] == card_number.to_i }
            end

            unless epic
              puts "Error: Card ##{card_number} not found in any active epic"
              return
            end

            task = epic["tasks"].find { |t| t["fizzy_card"] == card_number.to_i }

            # Clear all gate-related state
            old_approvals = task["gate_approvals"]&.size || 0
            old_changes = task["changes_requested_by"]&.size || 0

            task["gate_approvals"] = []
            task["changes_requested_by"] = []
            task["gates_dispatched_at"] = nil
            task["awaiting_final_decision"] = nil
            task["changes_debounce_started"] = nil
            task["gate_redispatch_counts"] = {}
            task["last_redispatch_at"] = nil
            task["status"] = "in_review"
            epic["updated_at"] = Time.now.iso8601

            save_epics(epics)
            puts "✓ Cleared gates for card ##{card_number}"
            puts "  Removed #{old_approvals} approval(s), #{old_changes} changes_requested"
            puts "  Status set to 'in_review' — gates will be re-dispatched on next health check"
            puts ""
            puts "  To force immediate re-dispatch, restart brainiac:"
            puts "    brainiac restart"
          end

          def cmd_reset_epic(args)
            todolist_id = args.shift
            unless todolist_id
              puts "Usage: brainiac basecamp reset epic <todolist-id> [--to <status>]"
              puts ""
              puts "Options:"
              puts "  --to <status>    Reset all tasks to this status (default: pending)"
              puts "  --reactivate     Reset a completed epic back to active"
              puts ""
              puts "Find your todolist ID with: brainiac basecamp epics --all"
              return
            end

            target_status = parse_to_flag(args) || "pending"
            reactivate = args.include?("--reactivate")

            unless valid_task_status?(target_status)
              puts "Error: Invalid status '#{target_status}'"
              puts "Valid statuses: pending, in_flight, in_review, final_decision, complete"
              return
            end

            epics = load_epics
            epic = epics.find { |e| e["basecamp_todolist_id"] == todolist_id.to_s }

            unless epic
              puts "Error: No epic found with todolist ID #{todolist_id}"
              puts ""
              puts "Active epics:"
              epics.select { |e| e["status"] == "active" }.each do |e|
                puts "  #{e['basecamp_todolist_id']} — #{e['title']}"
              end
              return
            end

            if epic["status"] != "active" && !reactivate
              puts "Error: Epic '#{epic['title']}' is #{epic['status']} (not active)"
              puts "  Use --reactivate to set it back to active"
              return
            end

            # Reactivate if needed
            if epic["status"] != "active" && reactivate
              epic["status"] = "active"
              epic["completed_at"] = nil
              puts "✓ Reactivated epic '#{epic['title']}'"
            end

            # Reset all non-complete tasks (unless resetting to pending, in which case reset all)
            tasks_to_reset = if target_status == "pending"
                               epic["tasks"]
                             else
                               epic["tasks"].reject { |t| t["status"] == "complete" }
                             end

            tasks_to_reset.each { |t| reset_task_to(t, target_status) }
            epic["updated_at"] = Time.now.iso8601

            finalized = finalize_epic_if_all_complete!(epic)

            save_epics(epics)
            puts "✓ Reset #{tasks_to_reset.size} task(s) → '#{target_status}' in epic '#{epic['title']}'"
            puts "✓ All tasks complete — epic finalized (status=complete, notification suppressed)" if finalized
            puts ""
            epic["tasks"].each do |t|
              icon = case t["status"]
                     when "complete" then "✅"
                     when "in_flight" then "🚀"
                     when "in_review" then "👀"
                     when "final_decision" then "⚡"
                     else "⬜"
                     end
              puts "  #{icon} ##{t['fizzy_card']} — #{t['title']} [#{t['status']}]"
            end
          end

          # --- Reset helpers ---

          def valid_task_status?(status)
            %w[pending in_flight in_review final_decision complete].include?(status)
          end

          def parse_to_flag(args)
            idx = args.index("--to")
            return nil unless idx

            args.delete_at(idx) # remove --to
            args.delete_at(idx) # remove the value (now at same index)
          end

          def reset_task_to(task, status)
            task["status"] = status

            case status
            when "pending"
              # Clear all progress state
              task["dispatched_at"] = nil
              task["completed_at"] = nil
              task["pr_number"] = nil
              task["pr_repo"] = nil
              task["gate_approvals"] = []
              task["changes_requested_by"] = []
              task["gates_dispatched_at"] = nil
              task["awaiting_final_decision"] = nil
              task["changes_debounce_started"] = nil
              task["gate_redispatch_counts"] = {}
              task["last_redispatch_at"] = nil
              task["last_reviewed_sha"] = nil
            when "in_flight"
              # Keep PR info but clear gate state
              task["completed_at"] = nil
              task["gate_approvals"] = []
              task["changes_requested_by"] = []
              task["gates_dispatched_at"] = nil
              task["awaiting_final_decision"] = nil
              task["changes_debounce_started"] = nil
              task["gate_redispatch_counts"] = {}
              task["last_redispatch_at"] = nil
              task["dispatched_at"] ||= Time.now.iso8601
            when "in_review"
              # Clear gate approvals but keep PR info
              task["completed_at"] = nil
              task["gate_approvals"] = []
              task["changes_requested_by"] = []
              task["gates_dispatched_at"] = nil
              task["awaiting_final_decision"] = nil
              task["changes_debounce_started"] = nil
              task["gate_redispatch_counts"] = {}
              task["last_redispatch_at"] = nil
            when "final_decision"
              task["completed_at"] = nil
              task["awaiting_final_decision"] = true
            when "complete"
              task["completed_at"] ||= Time.now.iso8601
              # A completed task is no longer awaiting a final decision. Leaving
              # this true lets reconcile_final_decision_task treat the task as
              # unsettled and re-dispatch/re-complete it on the next sweep.
              task["awaiting_final_decision"] = false
            end
          end

          # Seal an epic when a reset leaves every task complete. Without this, an
          # epic can sit status="active" with all tasks done — exactly the
          # thrash-prone state where the 90s reconcile loop re-detects "all
          # complete", re-runs complete_epic, and re-posts the "🎉 Epic completed"
          # notification on every sweep. Setting completion_notified suppresses a
          # notification for this manual, operator-driven completion. Returns true
          # if the epic was finalized.
          def finalize_epic_if_all_complete!(epic)
            return false unless epic["tasks"]&.any?
            return false unless epic["tasks"].all? { |t| t["status"] == "complete" }
            return false if epic["status"] == "complete"

            epic["status"] = "complete"
            epic["completed_at"] ||= Time.now.iso8601
            epic["completion_notified"] = true
            true
          end

          def load_epics
            epics_file = File.join(BRAINIAC_DIR, "basecamp_epics.json")
            return [] unless File.exist?(epics_file)

            data = JSON.parse(File.read(epics_file))
            data["epics"] || []
          rescue JSON::ParserError
            []
          end

          def save_epics(epics)
            epics_file = File.join(BRAINIAC_DIR, "basecamp_epics.json")
            File.write(epics_file, JSON.pretty_generate({
                                                          "epics" => epics,
                                                          "updated_at" => Time.now.iso8601
                                                        }))
          end

          # --- Scrap helpers ---

          # Close a Fizzy card via CLI.
          def scrap_close_fizzy_card(card_number)
            stdout, stderr, status = Open3.capture3("fizzy", "card", "close", card_number.to_s)
            status.success?
          rescue StandardError => e
            false
          end

          # Close all open PRs that reference the epic branch (head or base).
          #
          # @param repo_path [String] Path to the repo
          # @param branch_name [String] Epic branch name
          # @return [Array<Integer>] Closed PR numbers
          def scrap_close_epic_prs(repo_path, branch_name)
            closed = []

            # Find PRs where epic branch is the base (task PRs targeting epic branch)
            stdout, _stderr, status = Open3.capture3(
              "gh", "pr", "list", "--base", branch_name, "--state", "open",
              "--json", "number", "--jq", ".[].number",
              chdir: repo_path
            )
            if status.success? && !stdout.strip.empty?
              stdout.strip.split("\n").each do |pr_num|
                close_pr(repo_path, pr_num.strip.to_i, "Scrapped as part of epic teardown")
                closed << pr_num.strip.to_i
              end
            end

            # Find PRs where epic branch is the head (final PR to main)
            stdout, _stderr, status = Open3.capture3(
              "gh", "pr", "list", "--head", branch_name, "--state", "open",
              "--json", "number", "--jq", ".[].number",
              chdir: repo_path
            )
            if status.success? && !stdout.strip.empty?
              stdout.strip.split("\n").each do |pr_num|
                close_pr(repo_path, pr_num.strip.to_i, "Scrapped as part of epic teardown")
                closed << pr_num.strip.to_i
              end
            end

            closed
          rescue StandardError
            closed
          end

          # Close a single PR with a comment.
          def close_pr(repo_path, pr_number, comment)
            Open3.capture3(
              "gh", "pr", "close", pr_number.to_s, "--comment", "🗑️ #{comment}",
              chdir: repo_path
            )
          rescue StandardError
            # Best effort
          end

          # Delete an epic branch from the remote.
          def scrap_delete_branch(repo_path, branch_name)
            # Delete remote branch
            _stdout, _stderr, status = Open3.capture3(
              "git", "push", "origin", "--delete", branch_name,
              chdir: repo_path
            )

            # Also delete local branch if it exists
            Open3.capture3("git", "branch", "-D", branch_name, chdir: repo_path)

            status.success?
          rescue StandardError
            false
          end

          # Mark a Basecamp todo complete with a scrap comment.
          def scrap_complete_todo(todo_id, project_id, agent)
            # Add a comment first
            Client.run_safe(
              "comments", "create", todo_id.to_s,
              "🗑️ Scrapped — epic torn down via `brainiac basecamp scrap`",
              "--in", project_id.to_s, "--json",
              profile: agent&.downcase
            )

            # Mark complete
            Client.run_safe(
              "todos", "complete", todo_id.to_s,
              "--in", project_id.to_s, "--json",
              profile: agent&.downcase
            )
          rescue StandardError
            # Best effort
          end

          # Resolve a project key to its repo path from projects.json.
          def resolve_repo_path(project_key)
            projects_file = File.join(BRAINIAC_DIR, "projects.json")
            return nil unless File.exist?(projects_file)

            projects = JSON.parse(File.read(projects_file))
            projects.dig(project_key, "repo_path")
          rescue JSON::ParserError
            nil
          end

          # --- Deploy helpers ---

          def list_epics_for_deploy
            epics = load_epics.select { |e| e["status"] == "active" }
            if epics.empty?
              puts "  (no active epics)"
              return
            end

            epics.each do |epic|
              deploy_env = resolve_deploy_env(epic, nil)
              env_display = deploy_env ? "[deploy:#{deploy_env}]" : "(no env)"
              puts "  #{epic['basecamp_todolist_id']} — #{epic['title']} #{env_display}"
            end
          end

          def resolve_deploy_env(epic, override)
            # 1. Explicit override
            return override if override && !override.empty?

            # 2. [deploy:env] in title or deploy:env in description
            env = Basecamp::Epic.extract_deploy_env(epic["title"], epic["description"])
            return env if env

            # 3. Per-project default from config
            # Prefer the project from tasks (set from Fizzy card tags) over basecamp mapping
            # since multiple brainiac projects can share the same basecamp project.
            project_key = (epic["tasks"] || []).filter_map { |t| t["project"] }.first
            project_key ||= Config.brainiac_project_for(epic["basecamp_project_id"])
            project_env = Config.deploy.dig("project_envs", project_key) if project_key
            return project_env if project_env

            # 4. Global default
            Config.deploy["default_env"]
          end

          def find_epic_worktree(epic)
            # Epic branches are stored per-project in epic["epic_branches"]
            # Find any worktree that has the epic branch checked out
            epic_branches = epic["epic_branches"] || {}
            return nil if epic_branches.empty?

            # Load projects to find repo paths
            projects_file = File.join(BRAINIAC_DIR, "projects.json")
            return nil unless File.exist?(projects_file)

            projects = JSON.parse(File.read(projects_file))

            epic_branches.each do |project_key, branch_name|
              repo_path = projects.dig(project_key, "repo_path")
              next unless repo_path && File.directory?(repo_path)

              # List worktrees and find one with this branch
              output, status = Open3.capture2("git", "worktree", "list", "--porcelain", chdir: repo_path)
              next unless status.success?

              # Parse porcelain output
              current_worktree = nil
              output.each_line do |line|
                if line.start_with?("worktree ")
                  current_worktree = line.sub("worktree ", "").strip
                elsif line.start_with?("branch refs/heads/")
                  wt_branch = line.sub("branch refs/heads/", "").strip
                  return current_worktree if wt_branch == branch_name && current_worktree && current_worktree != repo_path
                end
              end
            end

            nil
          rescue JSON::ParserError
            nil
          end

          def run_deploy(worktree_path, env)
            deploy_config = Config.deploy
            command_template = deploy_config["command"] || "belt deploy {env} --auto"
            command = command_template.gsub("{env}", env)

            puts "Running: #{command}"
            puts "-" * 40

            # Run the deploy command in the worktree directory
            system(command, chdir: worktree_path)
          end

          def auto_resolve_person_id(agent_name)
            output, status = Open3.capture2(
              "basecamp", "people", "list", "--jq",
              ".data[] | select(.name | ascii_downcase | contains(\"#{agent_name.downcase}\")) | {id, name}"
            )
            return nil unless status.success? && !output.strip.empty?

            # Parse each JSON line — prefer exact match
            candidates = []
            output.each_line do |line|
              person = JSON.parse(line.strip)
              candidates << person
            rescue JSON::ParserError
              next
            end

            # Exact name match first
            exact = candidates.find { |p| p["name"]&.downcase == agent_name.downcase }
            return exact["id"].to_s if exact

            # Otherwise first contains-match
            candidates.first&.dig("id")&.to_s
          end

          # Load the agents registry from ~/.brainiac/agents.json
          #
          # @return [Hash] Agent key => config hash
          def load_agents_registry
            agents_file = File.join(BRAINIAC_DIR, "agents.json")
            return {} unless File.exist?(agents_file)

            JSON.parse(File.read(agents_file))
          rescue JSON::ParserError
            {}
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
        %w[setup config status epics deploy link bot projects set reset scrap webhook]
      end
    end
  end
end
