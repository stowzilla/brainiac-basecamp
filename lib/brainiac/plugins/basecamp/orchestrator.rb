# frozen_string_literal: true

require "json"
require "time"

module Brainiac
  module Plugins
    module Basecamp
      # Manages active epic execution state.
      #
      # An epic = a Basecamp todolist where each todo is linked to a Fizzy card.
      # The orchestrator drives execution: reads the todolist, builds the dep graph,
      # assigns unblocked Fizzy cards, and advances state as cards complete.
      #
      # State is persisted to ~/.brainiac/basecamp_epics.json.
      module Orchestrator
        BRAINIAC_DIR = ENV.fetch("BRAINIAC_DIR", File.join(Dir.home, ".brainiac"))
        EPICS_FILE = File.join(BRAINIAC_DIR, "basecamp_epics.json")

        class << self
          # Start orchestrating an epic from a todolist.
          #
          # @param todolist_id [String, Integer] Basecamp todolist ID
          # @param project_id [String, Integer] Basecamp project/bucket ID
          # @param agent [String] Agent name to orchestrate
          # @param title [String] Epic/todolist title
          # @return [Hash] The created epic run state
          def start_epic(todolist_id:, project_id:, agent:, title:)
            review_gate = Config.review_gate

            epic = {
              "id" => "epic-#{todolist_id}",
              "basecamp_todolist_id" => todolist_id.to_s,
              "basecamp_project_id" => project_id.to_s,
              "agent" => agent,
              "title" => title,
              "status" => "active",
              "review_gate" => review_gate,
              "started_at" => Time.now.iso8601,
              "updated_at" => Time.now.iso8601,
              "tasks" => [],
              "epic_branches" => {},
              "history" => []
            }

            save_epic(epic)
            log_event(epic, "started", "Epic orchestration started by #{agent} (review_gate: #{review_gate})")

            LOG.info "[Basecamp:Orchestrator] Started epic '#{title}' (todolist #{todolist_id}) " \
                     "with agent #{agent}, review_gate: #{review_gate}" if defined?(LOG)

            # FIRST: Populate tasks with project info from Fizzy card tags
            # This must happen BEFORE creating epic branches so we know which repos are involved
            populate_tasks(epic)

            # THEN: Create epic branches for all projects (now that we know which projects are involved)
            if review_gate == "epic_branch"
              create_epic_branches_for(epic)

              # Sync PR state from work_items for cards that already have open PRs
              sync_existing_pr_state(epic)
            end

            # CRITICAL: Save epic state BEFORE dispatching tasks.
            # The resolve_pr_target hook reads from disk, so tasks and epic_branches
            # must be persisted before the agent is dispatched.
            save_epic(epic)

            # For tasks with open PRs, dispatch review gates immediately
            if review_gate == "epic_branch"
              dispatch_gates_for_existing_prs(epic)
            end

            # Finally: Dispatch unblocked work (skips tasks already in_review)
            dispatch_unblocked_tasks(epic)

            save_epic(epic)
            epic
          end

          # Start an epic from a single "trigger" todo that contains the todolist context.
          # This is the webhook entry point — a todo is assigned to the bot account,
          # and its parent todolist becomes the epic.
          #
          # @param todo_id [String, Integer] The trigger todo ID
          # @param todolist_id [String, Integer] Parent todolist ID
          # @param project_id [String, Integer] Basecamp project/bucket ID
          # @param agent [String] Agent name
          # @param title [String] Todolist title
          # @return [Hash] The created epic run state
          def start_epic_from_todo(todo_id:, todolist_id:, project_id:, agent:, title:)
            # Check if this epic is already running
            existing = find_epic_by_todolist(todolist_id)
            if existing && existing["status"] == "active"
              LOG.info "[Basecamp:Orchestrator] Epic for todolist #{todolist_id} already active, skipping" if defined?(LOG)
              return existing
            end

            start_epic(todolist_id: todolist_id, project_id: project_id, agent: agent, title: title)
          end

          # Called when an agent completes a Fizzy card session.
          # Checks if the card is part of an active epic and advances the orchestration.
          #
          # @param card_number [Integer, String] Fizzy card number that was completed
          # @return [Boolean] Whether this card was part of an epic
          def on_card_completed(card_number)
            card_number = card_number.to_i
            epic = find_epic_for_card(card_number)
            return false unless epic

            # Idempotency check — don't process completion twice
            task = epic["tasks"].find { |t| t["fizzy_card"] == card_number }
            if task && task["status"] == "complete"
              LOG.info "[Basecamp:Orchestrator] Card ##{card_number} already complete, skipping duplicate completion" if defined?(LOG)
              return true
            end

            LOG.info "[Basecamp:Orchestrator] Card ##{card_number} completed, advancing epic '#{epic['title']}'" if defined?(LOG)

            # Mark the task as complete in our state
            if task
              TaskState.transition!(task, :complete, triggered_by: "fizzy_card_completed")
              task["completed_at"] = Time.now.iso8601
              epic["updated_at"] = Time.now.iso8601
              log_event(epic, "task_completed", "Card ##{card_number} completed")
            end

            # Mark the corresponding Basecamp todo as complete
            mark_todo_complete(epic, card_number)

            # Post a status comment on the Basecamp todo
            post_completion_comment(epic, card_number)

            # Check if epic is fully done
            if epic["tasks"].all? { |t| t["status"] == "complete" }
              complete_epic(epic)
            else
              # Dispatch epic review agent before moving to next tasks
              # This ensures the plan still makes sense after implementation decisions
              dispatch_epic_review(epic, card_number) do
                # After review completes, dispatch next unblocked tasks
                resolve_and_dispatch(epic)
              end
            end

            save_epic(epic)
            true
          end

          # Find an active epic that contains a given Fizzy card.
          #
          # @param card_number [Integer] Fizzy card number
          # @return [Hash, nil] Epic state or nil
          def find_epic_for_card(card_number)
            load_epics.find do |epic|
              epic["status"] == "active" &&
                epic["tasks"].any? { |t| t["fizzy_card"] == card_number.to_i }
            end
          end

          # Find an epic by its todolist ID.
          #
          # @param todolist_id [String, Integer] Basecamp todolist ID
          # @return [Hash, nil]
          def find_epic_by_todolist(todolist_id)
            load_epics.find { |e| e["basecamp_todolist_id"] == todolist_id.to_s }
          end

          # Get all active epics.
          #
          # @return [Array<Hash>]
          def active_epics
            load_epics.select { |e| e["status"] == "active" }
          end

          # Get all epics (active and completed).
          #
          # @return [Array<Hash>]
          def all_epics
            load_epics
          end

          # Get a specific epic by ID.
          #
          # @param epic_id [String] Epic ID
          # @return [Hash, nil]
          def find_epic(epic_id)
            load_epics.find { |e| e["id"] == epic_id }
          end

          private

          # Resolve current todolist state from Basecamp and dispatch unblocked cards.
          def resolve_and_dispatch(epic)
            populate_tasks(epic)
            dispatch_unblocked_tasks(epic)
          end

          # Populate/refresh task list from Basecamp todolist.
          # Resolves project key for each task from Fizzy card tags.
          # IMPORTANT: Preserves completed tasks that Basecamp API no longer returns.
          # Also preserves PR/gate state for tasks that are in progress.
          def populate_tasks(epic)
            todos = fetch_todos(epic)
            return unless todos

            # Parse new todos from Basecamp
            new_tasks = Epic.parse_todos(todos)
            existing_tasks = epic["tasks"] || []

            # Build a map of existing tasks by fizzy_card for quick lookup
            existing_by_card = existing_tasks.each_with_object({}) { |t, h| h[t["fizzy_card"]] = t }

            # Start with tasks from the API (incomplete todos)
            updated_tasks = new_tasks.map do |task|
              existing = existing_by_card[task.fizzy_card]
              status = if task.completed
                         existing&.dig("status") || "complete"
                       elsif existing&.dig("status")
                         # Preserve existing status (in_flight, in_review, final_decision, etc.)
                         existing["status"]
                       else
                         "pending"
                       end

              project_key = existing&.dig("project") ||
                            resolve_project_from_fizzy_card(task.fizzy_card) ||
                            Config.brainiac_project_for(epic["basecamp_project_id"])

              # Build task, preserving all existing state
              new_task = {
                "todo_id" => task.todo_id,
                "fizzy_card" => task.fizzy_card,
                "title" => task.title,
                "depends_on" => task.depends_on,
                "status" => status,
                "project" => project_key,
                "completed_at" => task.completed ? (existing&.dig("completed_at") || Time.now.iso8601) : nil,
                "assignees" => task.assignees,
                "due_on" => task.due_on
              }

              # Preserve PR and gate state from existing task
              if existing
                %w[dispatched_at pr_number pr_repo gates_dispatched_at gate_approvals
                   changes_requested_by gate_redispatch_counts gate_states
                   awaiting_final_decision changes_debounce_started
                   fizzy_internal_id transitions].each do |key|
                  new_task[key] = existing[key] if existing.key?(key)
                end
              end

              TaskState.migrate!(new_task, triggered_by: "basecamp_sync")
              if task.completed && !TaskState.in?(new_task, :complete)
                TaskState.transition!(new_task, :complete, triggered_by: "basecamp_todo_completed")
              end

              new_task
            end

            # Preserve completed tasks that are no longer in the Basecamp API response
            new_card_numbers = new_tasks.map(&:fizzy_card)
            completed_tasks = existing_tasks.select do |t|
              t["status"] == "complete" && !new_card_numbers.include?(t["fizzy_card"])
            end

            epic["tasks"] = completed_tasks + updated_tasks
            epic["updated_at"] = Time.now.iso8601
          end

          # Dispatch unblocked tasks that do not have a live implementation session.
          def dispatch_unblocked_tasks(epic)
            tasks = epic["tasks"].map do |t|
              # A stale in_flight state is diagnostic state, not liveness evidence.
              # It becomes dispatchable again only after the implementation session has
              # died; in_review/final_decision remain intentionally non-dispatchable.
              # Give a newly assigned implementation agent time to register its
              # session. Without this grace period, a recovery pass that just
              # re-assigned a stale card can immediately assign it a second time
              # before Fizzy's normal spawn hook has run.
              dispatch_status = if TaskState.in?(t, :in_flight) &&
                                   !SessionRegistry.implementation_alive?(t["fizzy_card"]) &&
                                   Basecamp.send(:stale_dispatch?, t)
                                  :pending
                                else
                                  t["status"].to_sym
                                end
              Epic::Task.new(
                todo_id: t["todo_id"],
                fizzy_card: t["fizzy_card"],
                title: t["title"],
                depends_on: t["depends_on"] || [],
                status: dispatch_status,
                completed: t["status"] == "complete",
                project: t["project"]
              )
            end

            # The registry, rather than Fizzy assignment or a persisted status field,
            # is the authority for whether an implementation dispatch is already live.
            unblocked = Epic.unblocked_tasks(tasks)
            complete_cards = epic["tasks"].select { |t| t["status"] == "complete" }.map { |t| t["fizzy_card"] }

            ready_to_dispatch = unblocked.reject do |task|
              complete_cards.include?(task.fizzy_card) || SessionRegistry.implementation_alive?(task.fizzy_card)
            end

            ready_to_dispatch.each do |task|
              dispatch_card(epic, task)
            end

            # Log summary
            LOG.info "[Basecamp:Orchestrator] Epic '#{epic['title']}': " \
                     "#{epic['tasks'].count { |t| t['status'] == 'complete' }}/#{epic['tasks'].size} complete, " \
                     "#{ready_to_dispatch.size} dispatched, " \
                     "#{epic['tasks'].count { |t| t['status'] == 'in_flight' }} in-flight" if defined?(LOG)
          end

          # Dispatch a Fizzy card to the appropriate agent.
          # Uses the project-specific agent if configured, otherwise falls back to the epic's agent.
          def dispatch_card(epic, task)
            card_number = task.fizzy_card

            if SessionRegistry.implementation_alive?(card_number)
              LOG.info "[Basecamp:Orchestrator] Skipping Fizzy card ##{card_number} — implementation session is still live" if defined?(LOG)
              return false
            end

            # Resolve agent from project config — each project can have its own default agent
            project_key = task.is_a?(Hash) ? task["project"] : task.project
            agent = resolve_agent_for_project(project_key) || epic["agent"]

            LOG.info "[Basecamp:Orchestrator] Dispatching Fizzy card ##{card_number} to #{agent} (project: #{project_key})" if defined?(LOG)

            # Mark as in-flight in our state
            epic_task = epic["tasks"].find { |t| t["fizzy_card"] == card_number }
            if epic_task
              TaskState.transition!(epic_task, :dispatch, triggered_by: "orchestrator_dispatch")
              epic_task["dispatched_at"] = Time.now.iso8601
            end
            epic["updated_at"] = Time.now.iso8601

            log_event(epic, "dispatched", "Card ##{card_number} dispatched to #{agent}")

            # Assign the card in Fizzy via CLI — this triggers the normal Fizzy webhook flow
            assign_fizzy_card(card_number, agent)

            # Post a comment on the Basecamp todo
            if epic_task && epic_task["todo_id"]
              Client.run_safe(
                "comments", "create", epic_task["todo_id"].to_s,
                "🚀 Dispatched to **#{agent}** via Brainiac",
                "--in", epic["basecamp_project_id"], "--json",
                profile: agent.downcase
              )
            end

            true
          end

          # Sync PR state from work_items for cards that already have open PRs.
          # Called when an epic starts to detect cards mid-flight.
          def sync_existing_pr_state(epic)
            work_items_file = File.join(BRAINIAC_DIR, "work_items.json")
            return unless File.exist?(work_items_file)

            work_items = JSON.parse(File.read(work_items_file))

            epic["tasks"].each do |task|
              card_number = task["fizzy_card"]
              next if task["pr_number"] # Already has PR tracked

              # Find work item by card number
              work_item = work_items.values.find do |wi|
                wi.dig("sources", "fizzy", "card_number") == card_number
              end
              next unless work_item

              # Check if work item has a PR
              pr = work_item.dig("sources", "github", "prs")&.first
              next unless pr

              pr_number = pr["number"]
              LOG.info "[Basecamp:Orchestrator] Found existing PR ##{pr_number} for card ##{card_number}" if defined?(LOG)

              task["pr_number"] = pr_number
              task["pr_repo"] = work_item.dig("sources", "github", "repo")
              TaskState.transition!(task, :submit_for_review, triggered_by: "existing_pr_sync")
            end
          rescue StandardError => e
            LOG.warn "[Basecamp:Orchestrator] Error syncing PR state: #{e.message}" if defined?(LOG)
          end

          # Dispatch review gates for tasks that already have open PRs.
          # Called when an epic starts to kick off reviews for mid-flight cards.
          def dispatch_gates_for_existing_prs(epic)
            return unless ReviewGate.enabled?

            tasks_with_prs = epic["tasks"].select { |t| t["pr_number"] && t["status"] == "in_review" }
            return if tasks_with_prs.empty?

            LOG.info "[Basecamp:Orchestrator] Dispatching gates for #{tasks_with_prs.size} existing PR(s)" if defined?(LOG)

            tasks_with_prs.each do |task|
              card_number = task["fizzy_card"]
              pr_number = task["pr_number"]
              project_key = task["project"]

              # Get repo info
              projects_file = File.join(BRAINIAC_DIR, "projects.json")
              projects = File.exist?(projects_file) ? JSON.parse(File.read(projects_file)) : {}
              project_config = projects[project_key] || {}
              repo_path = project_config["repo_path"]
              github_repo = project_config["github_repo"]

              next unless repo_path && github_repo

              # Sync gate state from GitHub first (in case reviews already happened)
              ReviewGate.sync_from_github(task, repo_path: repo_path)

              # Check if all gates already passed
              if ReviewGate.all_gates_passed?(task)
                LOG.info "[Basecamp:Orchestrator] Gates already passed for card ##{card_number} — dispatching final decision" if defined?(LOG)
                TaskState.transition!(task, :approve, triggered_by: "existing_pr_gate_sync", guard: ReviewGate.all_gates_passed?(task))
                task["awaiting_final_decision"] = true
                # Final decision dispatch happens in resume logic
              else
                # Dispatch gate agents
                LOG.info "[Basecamp:Orchestrator] Dispatching gates for card ##{card_number} (PR ##{pr_number})" if defined?(LOG)
                ReviewGate.dispatch_gates(
                  epic: epic,
                  task: task,
                  pr_number: pr_number,
                  repo_name: github_repo,
                  repo_path: repo_path
                )
              end
            end

            save_epic(epic)
          end

          # Assign a Fizzy card to an agent via Fizzy CLI.
          # If the agent is already assigned, skip — the webhook should have already fired.
          def assign_fizzy_card(card_number, agent)
            agent_config = load_agent_registry[agent.downcase]
            fizzy_name = agent_config&.dig("fizzy_name") || agent

            # Resolve the Fizzy user ID from the agent's display name
            fizzy_user_id = resolve_fizzy_user_id(fizzy_name)
            unless fizzy_user_id
              LOG.error "[Basecamp:Orchestrator] Could not resolve Fizzy user ID for '#{fizzy_name}'" if defined?(LOG)
              return
            end

            # Check if agent is already assigned — if so, skip (webhook should have fired)
            stdout, _, status = Open3.capture3("fizzy", "card", "show", card_number.to_s, "--json")
            if status.success?
              card_data = JSON.parse(stdout).dig("data") rescue nil
              if card_data
                current_assignees = (card_data["assignees"] || []).map { |a| a["id"] }
                if current_assignees.include?(fizzy_user_id)
                  LOG.info "[Basecamp:Orchestrator] Agent already assigned to ##{card_number}, skipping (webhook should have fired)" if defined?(LOG)
                  return
                end
              end
            end

            stdout, stderr, status = Open3.capture3("fizzy", "card", "assign", card_number.to_s, "--user", fizzy_user_id)

            if status.success?
              LOG.info "[Basecamp:Orchestrator] Assigned Fizzy ##{card_number} to #{fizzy_name} (#{fizzy_user_id})" if defined?(LOG)
            else
              LOG.error "[Basecamp:Orchestrator] Failed to assign Fizzy ##{card_number}: #{stderr.strip}" if defined?(LOG)
            end
          rescue Errno::ENOENT => e
            LOG.error "[Basecamp:Orchestrator] fizzy CLI not found: #{e.message}" if defined?(LOG)
          end

          # Resolve a Fizzy user ID from their display name.
          # Reads from ~/.brainiac/fizzy.json authorized_users list.
          def resolve_fizzy_user_id(name)
            @fizzy_users ||= begin
              fizzy_config_file = File.join(BRAINIAC_DIR, "fizzy.json")
              return {} unless File.exist?(fizzy_config_file)

              config = JSON.parse(File.read(fizzy_config_file))
              users = config["authorized_users"] || []
              users.each_with_object({}) { |u, h| h[u["name"].downcase] = u["id"] }
            rescue StandardError
              {}
            end

            @fizzy_users[name.downcase]
          end

          # Resolve the default agent for a project from projects.json.
          # Returns nil if no project-specific agent is configured.
          #
          # @param project_key [String, nil] Brainiac project key
          # @return [String, nil] Agent name or nil
          def resolve_agent_for_project(project_key)
            return nil unless project_key

            projects_file = File.join(BRAINIAC_DIR, "projects.json")
            return nil unless File.exist?(projects_file)

            projects = JSON.parse(File.read(projects_file))
            projects.dig(project_key, "agent_name")
          rescue StandardError => e
            LOG.warn "[Basecamp:Orchestrator] Could not resolve agent for project #{project_key}: #{e.message}" if defined?(LOG)
            nil
          end

          # Resolve the brainiac project key for a Fizzy card by querying its tags.
          # Uses the same logic as brainiac-fizzy: card tags are matched against
          # each project's fizzy_tags configuration.
          #
          # @param card_number [Integer, String] Fizzy card number
          # @return [String, nil] Brainiac project key or nil
          def resolve_project_from_fizzy_card(card_number)
            return nil unless card_number

            # Query the Fizzy card for its tags and board
            stdout, _, status = Open3.capture3("fizzy", "card", "show", card_number.to_s, "--json")
            return nil unless status.success?

            card_data = JSON.parse(stdout)
            # Handle both envelope format and direct data
            card = card_data.is_a?(Hash) && card_data["data"] ? card_data["data"] : card_data
            tags = card["tags"] || []

            # Load projects for matching
            projects_file = File.join(BRAINIAC_DIR, "projects.json")
            return nil unless File.exist?(projects_file)

            all_projects = JSON.parse(File.read(projects_file))

            # Priority 1: Match by card tags (same as fizzy handler)
            tag_names = tags.map { |t| t.is_a?(Hash) ? t["name"] : t.to_s }.map(&:downcase)
            unless tag_names.empty?
              all_projects.each do |key, config|
                project_tags = (config["tags"] || config["fizzy_tags"] || []).map(&:downcase)
                return key if tag_names.intersect?(project_tags)
              end
            end

            # Priority 2: Match by card's board → board_key → project with fizzy_board
            # This mirrors the fizzy handler's fallback logic to prevent project mismatch
            board_id = card.dig("board", "id")
            if board_id
              board_key = resolve_board_key_for_id(board_id)
              if board_key
                # Check for board's default_project in fizzy config
                fizzy_config_file = File.join(BRAINIAC_DIR, "fizzy.json")
                if File.exist?(fizzy_config_file)
                  fizzy_config = JSON.parse(File.read(fizzy_config_file))
                  board_config = fizzy_config.dig("boards", board_key)
                  if board_config && board_config["default_project"]
                    project_key = board_config["default_project"]
                    return project_key if all_projects.key?(project_key)
                  end
                end

                # Fall back to any project whose fizzy_board matches this board_key
                all_projects.each do |key, config|
                  return key if config["fizzy_board"] == board_key
                end
              end
            end

            nil
          rescue StandardError => e
            LOG.warn "[Basecamp:Orchestrator] Could not resolve project for Fizzy card ##{card_number}: #{e.message}" if defined?(LOG)
            nil
          end

          # Resolve a fizzy board_key from a board_id by checking fizzy.json boards config.
          def resolve_board_key_for_id(board_id)
            fizzy_config_file = File.join(BRAINIAC_DIR, "fizzy.json")
            return nil unless File.exist?(fizzy_config_file)

            fizzy_config = JSON.parse(File.read(fizzy_config_file))
            boards = fizzy_config["boards"] || {}

            boards.each do |key, config|
              return key if config["board_id"] == board_id
            end

            nil
          rescue StandardError
            nil
          end

          # Whether a card's completion is backed by real evidence of shipped work.
          #
          # A card genuinely completes when it has an associated PR that merged (or,
          # at minimum, a tracked PR number). Without any PR evidence the completion
          # is almost certainly spurious — a stale ledger flag left behind by a
          # basecamp re-sync that dropped merged cards — and we should not treat it
          # as a real completion that warrants an epic-review checkpoint.
          #
          # @param epic [Hash] epic state
          # @param card_number [Integer, String] the card claimed complete
          # @return [Boolean]
          def card_completion_verified?(epic, card_number)
            task = epic["tasks"].find { |t| t["fizzy_card"] == card_number.to_i }
            return false unless task

            # A tracked PR number is our recorded evidence that work shipped.
            !task["pr_number"].to_s.strip.empty?
          end

          # Dispatch an agent to review the epic state after a task completes.
          # This ensures the remaining plan still makes sense given implementation decisions.
          # The callback is called after the review completes.
          def dispatch_epic_review(epic, completed_card_number, &callback)
            agent_name = epic["agent"]
            remaining_tasks = epic["tasks"].select { |t| t["status"] == "pending" }

            # Skip review if no remaining tasks
            if remaining_tasks.empty?
              callback&.call
              return
            end

            # Only post a "just completed" checkpoint when the card actually shipped
            # work. A ledger flagged `complete` with no PR (and no merge) means the
            # completion was spurious — usually the basecamp re-sync dropping merged
            # cards and leaving a stale flag. Posting "Card #N just completed" in that
            # case is a false claim that spawns a pointless epic-review reflex.
            # Still run the callback so the resolver can advance (it correctly does
            # nothing for cards that remain blocked).
            unless card_completion_verified?(epic, completed_card_number)
              if defined?(LOG)
                LOG.warn "[Basecamp:Orchestrator] Skipping epic review after card " \
                         "##{completed_card_number} — no PR/merge evidence of completion"
              end
              callback&.call
              return
            end

            LOG.info "[Basecamp:Orchestrator] Dispatching epic review after card ##{completed_card_number}" if defined?(LOG)

            # Ensure epic memory exists (in case this epic started before the feature)
            EpicMemory.ensure_exists_for(epic)

            # Build the review prompt
            completed_tasks = epic["tasks"].select { |t| t["status"] == "complete" }
            completed_summary = completed_tasks.map { |t| "- ##{t['fizzy_card']}: #{t['title']}" }.join("\n")
            remaining_summary = remaining_tasks.map do |t|
              deps = t["depends_on"] || []
              dep_str = deps.any? ? " [depends: #{deps.map { |d| "##{d}" }.join(', ')}]" : ""
              "- ##{t['fizzy_card']}: #{t['title']}#{dep_str}"
            end.join("\n")

            prompt = <<~PROMPT
              ## Epic Review: #{epic['title']}

              Card ##{completed_card_number} just completed. Before dispatching the next task(s), review the epic state.

              ### Completed tasks:
              #{completed_summary}

              ### Remaining tasks (with current dependencies):
              #{remaining_summary}

              ### Your job:
              1. Read the memory files for completed tasks to understand what was implemented
              2. Check if remaining tasks still make sense given the implementation decisions
              3. **Update dependencies** if implementation created new relationships between tasks
                 - Add `[depends:NNNN]` to a Fizzy card title if it now depends on another card
                 - Remove dependencies that are no longer needed
              4. If a remaining task is now obsolete, update its Fizzy card with a comment explaining why
              5. If a remaining task needs different scope, update its Fizzy card description
              6. If new tasks are needed, create new Fizzy cards (tag with the project)

              Memory files are at: `~/.brainiac/brain/memory/#{agent_name&.downcase}/card-<number>.md`

              After reviewing, post a brief summary comment on the Basecamp todolist:
              `basecamp comments create #{epic['basecamp_todolist_id']} "Epic review after ##{completed_card_number}: <your summary>" --in #{epic['basecamp_project_id']}`

              Keep it concise — this is a checkpoint, not a full analysis.
            PROMPT

            # Get project config for the agent
            task = epic["tasks"].find { |t| t["fizzy_card"] == completed_card_number.to_i }
            project_key = task&.dig("project") || Config.brainiac_project_for(epic["basecamp_project_id"])
            projects_file = File.join(BRAINIAC_DIR, "projects.json")
            projects = File.exist?(projects_file) ? JSON.parse(File.read(projects_file)) : {}
            project_config = projects[project_key] || {}
            repo_path = project_config["repo_path"] || Dir.pwd

            # Spawn the review agent
            Thread.new do
              card_key = "epic-review-#{epic['basecamp_todolist_id']}"

              begin
                pid, log_file = if Object.respond_to?(:run_agent, true)
                                  Object.send(:run_agent,
                                              prompt,
                                              project_config: project_config,
                                              chdir: repo_path,
                                              log_name: "epic-review-#{completed_card_number}",
                                              agent_name: agent_name,
                                              source: :basecamp,
                                              card_number: completed_card_number)
                                end

                # Register session in SessionRegistry for liveness tracking
                if pid
                  SessionRegistry.register_session(
                    card_key, pid,
                    log_file: log_file,
                    agent_name: agent_name,
                    epic_id: epic["id"],
                    card_number: completed_card_number
                  )
                end

                # Wait for the review to complete
                Process.wait(pid) if pid

                LOG.info "[Basecamp:Orchestrator] Epic review completed for card ##{completed_card_number}" if defined?(LOG)
              rescue StandardError => e
                LOG.error "[Basecamp:Orchestrator] Epic review failed: #{e.message}" if defined?(LOG)
              ensure
                # Call the callback to dispatch next tasks
                callback&.call
              end
            end
          end

          # Mark a Basecamp todo as complete.
          def mark_todo_complete(epic, card_number)
            task = epic["tasks"].find { |t| t["fizzy_card"] == card_number.to_i }
            return unless task && task["todo_id"]

            Client.run_safe("todos", "complete", task["todo_id"].to_s, "--json",
                           profile: epic["agent"]&.downcase)
          end

          # Post a completion comment on the Basecamp todo.
          def post_completion_comment(epic, card_number)
            task = epic["tasks"].find { |t| t["fizzy_card"] == card_number.to_i }
            return unless task && task["todo_id"]

            Client.run_safe(
              "comments", "create", task["todo_id"].to_s,
              "✅ Fizzy card ##{card_number} completed",
              "--in", epic["basecamp_project_id"], "--json",
              profile: epic["agent"]&.downcase
            )
          end

          # Complete the entire epic.
          def complete_epic(epic)
            # Idempotency — don't complete twice
            if epic["status"] == "complete"
              LOG.info "[Basecamp:Orchestrator] Epic '#{epic['title']}' already complete, skipping duplicate completion" if defined?(LOG)
              return
            end

            epic["status"] = "complete"
            epic["completed_at"] = Time.now.iso8601
            epic["updated_at"] = Time.now.iso8601
            log_event(epic, "completed", "All tasks complete — epic finished!")

            # Persist the completed status to disk IMMEDIATELY, before any slow
            # network calls (opening final PRs, posting to Basecamp). Recovery
            # reconciliation reads epics fresh from disk every 90s; if we defer
            # the write until after those calls, an overlapping reconcile pass
            # reads status="active", passes the guard above, and re-runs the
            # whole completion flow — including the notification below. That's
            # how the "Epic completed" Discord message fired repeatedly.
            save_epic(epic)

            LOG.info "[Basecamp:Orchestrator] Epic '#{epic['title']}' completed!" if defined?(LOG)

            # If epic_branch mode, open final PRs to main
            if epic["review_gate"] == "epic_branch" && epic["epic_branches"]&.any?
              open_final_prs(epic)

              # Trigger automated deploy if configured
              trigger_deploy_if_configured(epic, "on_final_pr")
            end

            # Post a summary message in Basecamp
            summary = build_completion_summary(epic)
            Client.run_safe(
              "messages", "create", "Epic Complete: #{epic['title']}", summary,
              "--in", epic["basecamp_project_id"], "--json",
              profile: epic["agent"]&.downcase
            )

            # Send the completion notification at most once, ever. This is a
            # belt-and-suspenders guard on top of the early status persistence
            # above — even if two passes somehow race past the status check, the
            # notification will only go out for the first one to reach here.
            unless epic["completion_notified"]
              epic["completion_notified"] = true
              save_epic(epic)

              send_notification(
                event: :epic_completed,
                message: "🎉 Epic completed: **#{epic['title']}** (#{epic['tasks'].size} tasks)",
                agent: epic["agent"]
              )
            end
          end

          # Fetch todos from the epic's todolist.
          def fetch_todos(epic)
            result = Client.run_safe(
              "todos", "list", "--in", epic["basecamp_project_id"],
              "--list", epic["basecamp_todolist_id"], "--json"
            )

            return nil unless result

            # Handle both envelope format and raw array
            if result.is_a?(Hash)
              result["data"] || []
            elsif result.is_a?(Array)
              result
            else
              nil
            end
          end

          # Build a completion summary for the epic.
          def build_completion_summary(epic)
            tasks = epic["tasks"]
            duration = if epic["started_at"] && epic["completed_at"]
                         started = Time.parse(epic["started_at"])
                         completed = Time.parse(epic["completed_at"])
                         hours = ((completed - started) / 3600).round(1)
                         hours > 24 ? "#{(hours / 24).round(1)} days" : "#{hours} hours"
                       end

            lines = []
            lines << "All #{tasks.size} tasks completed#{duration ? " in #{duration}" : ''}."
            lines << ""
            tasks.each do |task|
              lines << "- ✅ #{task['title']} (Fizzy ##{task['fizzy_card']})"
            end
            lines << ""
            lines << "Orchestrated by #{epic['agent']} via brainiac-basecamp."
            lines.join("\n")
          end

          # Log an event to the epic's history.
          def log_event(epic, event_type, message)
            epic["history"] ||= []
            epic["history"] << {
              "event" => event_type,
              "message" => message,
              "at" => Time.now.iso8601
            }
          end

          # Load all epics from disk.
          def load_epics
            return [] unless File.exist?(EPICS_FILE)

            data = JSON.parse(File.read(EPICS_FILE))
            data["epics"] || []
          rescue JSON::ParserError
            []
          end

          # Save an epic to disk (upsert by ID).
          def save_epic(epic)
            all = load_epics
            idx = all.index { |e| e["id"] == epic["id"] }
            if idx
              all[idx] = epic
            else
              all << epic
            end

            File.write(EPICS_FILE, JSON.pretty_generate({ "epics" => all, "updated_at" => Time.now.iso8601 }))
          end

          # Load agent registry from ~/.brainiac/agents.json.
          def load_agent_registry
            agents_file = File.join(BRAINIAC_DIR, "agents.json")
            return {} unless File.exist?(agents_file)

            JSON.parse(File.read(agents_file))
          rescue JSON::ParserError
            {}
          end

          # Create epic branches for all projects involved in this epic.
          def create_epic_branches_for(epic)
            project_repos = resolve_project_repos(epic)
            return if project_repos.empty?

            epic["epic_branches"] = EpicBranch.create_epic_branches(epic, project_repos)
            log_event(epic, "branches_created", "Epic branches: #{epic['epic_branches'].values.uniq.join(', ')}")
          rescue StandardError => e
            LOG.error "[Basecamp:Orchestrator] Failed to create epic branches: #{e.message}" if defined?(LOG)
          end

          # Open final PRs from epic branches to main.
          def open_final_prs(epic)
            project_repos = resolve_project_repos(epic)
            return if project_repos.empty?

            prs = EpicBranch.open_final_prs(epic, project_repos, epic["epic_branches"])
            epic["final_prs"] = prs
            log_event(epic, "final_prs_opened", "Opened #{prs.size} final PR(s): #{prs.map { |p| p[:url] }.join(', ')}")

            # Send notification about final PRs
            if prs.any?
              pr_list = prs.map { |p| p[:url] }.join("\n")
              send_notification(
                event: :epic_prs_ready,
                message: "📋 Epic **#{epic['title']}** — final PR ready for review:\n#{pr_list}",
                agent: epic["agent"]
              )
            end
          rescue StandardError => e
            LOG.error "[Basecamp:Orchestrator] Failed to open final PRs: #{e.message}" if defined?(LOG)
          end

          # Resolve project_key => repo_path for all projects in the epic's tasks.
          def resolve_project_repos(epic)
            projects_file = File.join(BRAINIAC_DIR, "projects.json")
            return {} unless File.exist?(projects_file)

            all_projects = JSON.parse(File.read(projects_file))
            project_keys = (epic["tasks"] || []).map { |t| t["project"] }.compact.uniq

            # If no per-task project is set, use the brainiac project mapped to this basecamp project
            if project_keys.empty?
              mapped = Config.brainiac_project_for(epic["basecamp_project_id"])
              project_keys = [mapped] if mapped
            end

            project_keys.each_with_object({}) do |key, hash|
              repo = all_projects.dig(key, "repo_path")
              hash[key] = repo if repo
            end
          rescue JSON::ParserError
            {}
          end

          # Send a notification via the configured channel.
          # Supports multiple notification backends via the :notify hook.
          #
          # Config in basecamp.json:
          #   "notifications": {
          #     "channel": "discord",           # or "slack", etc.
          #     "target": "1423854179880927274", # channel/room ID
          #     "epic_completed": true,          # per-event toggles
          #     ...
          #   }
          #
          # Legacy config (still supported):
          #   "notifications": { "discord_channel_id": "..." }
          #
          def send_notification(event:, message:, agent: nil)
            return unless defined?(Brainiac) && Brainiac.respond_to?(:emit)

            # Check if this event type is enabled
            notifications_config = Config.current.dig("notifications") || {}
            return unless notifications_config[event.to_s] != false

            # Get channel type and target (supports both new and legacy config)
            channel = notifications_config["channel"]&.to_sym || :discord
            target = notifications_config["target"] || notifications_config["discord_channel_id"]
            return unless target

            Brainiac.emit(:notify,
                          channel: channel,
                          target: target,
                          message: message,
                          agent: agent)
          end

          # Trigger automated deploy if configured for the given trigger point.
          #
          # @param epic [Hash] Epic state
          # @param trigger [String] Trigger point ("on_final_pr", "on_task_merge", etc.)
          def trigger_deploy_if_configured(epic, trigger)
            deploy_config = Config.deploy
            return unless deploy_config["enabled"]
            return unless deploy_config["trigger"] == trigger

            # Resolve deploy environment
            deploy_env = resolve_epic_deploy_env(epic)
            unless deploy_env
              LOG.warn "[Basecamp:Orchestrator] Deploy triggered but no environment configured for epic '#{epic['title']}'" if defined?(LOG)
              return
            end

            # Find worktree
            worktree_path = find_epic_worktree(epic)
            unless worktree_path
              LOG.warn "[Basecamp:Orchestrator] Deploy triggered but no worktree found for epic '#{epic['title']}'" if defined?(LOG)
              return
            end

            LOG.info "[Basecamp:Orchestrator] Auto-deploying epic '#{epic['title']}' to #{deploy_env}" if defined?(LOG)

            # Run deploy
            command_template = deploy_config["command"] || "belt deploy {env} --auto"
            command = command_template.gsub("{env}", deploy_env)

            success = system(command, chdir: worktree_path)

            # Record deploy result
            epic["last_deploy"] = {
              "env" => deploy_env,
              "at" => Time.now.iso8601,
              "status" => success ? "success" : "failed",
              "trigger" => trigger
            }

            # Send notification
            if success
              send_notification(
                event: :epic_deployed,
                message: "🚀 Epic **#{epic['title']}** deployed to **#{deploy_env}**",
                agent: epic["agent"]
              )
            else
              send_notification(
                event: :epic_deploy_failed,
                message: "❌ Epic **#{epic['title']}** deploy to **#{deploy_env}** failed",
                agent: epic["agent"]
              )
            end
          rescue StandardError => e
            LOG.error "[Basecamp:Orchestrator] Deploy failed: #{e.message}" if defined?(LOG)
            epic["last_deploy"] = {
              "env" => deploy_env,
              "at" => Time.now.iso8601,
              "status" => "error",
              "error" => e.message,
              "trigger" => trigger
            }
          end

          # Resolve deploy environment for an epic.
          #
          # @param epic [Hash] Epic state
          # @return [String, nil] Environment name or nil
          def resolve_epic_deploy_env(epic)
            # 1. [deploy:env] in title or deploy:env in description
            env = Epic.extract_deploy_env(epic["title"], epic["description"])
            return env if env

            # 2. Per-project default from config
            # Prefer the project from tasks (set from Fizzy card tags) over basecamp mapping
            # since multiple brainiac projects can share the same basecamp project.
            project_key = (epic["tasks"] || []).map { |t| t["project"] }.compact.first
            project_key ||= Config.brainiac_project_for(epic["basecamp_project_id"])
            project_env = Config.deploy.dig("project_envs", project_key) if project_key
            return project_env if project_env

            # 3. Global default
            Config.deploy["default_env"]
          end

          # Find the worktree path for an epic's branch.
          #
          # @param epic [Hash] Epic state
          # @return [String, nil] Worktree path or nil
          def find_epic_worktree(epic)
            epic_branches = epic["epic_branches"] || {}
            return nil if epic_branches.empty?

            projects_file = File.join(BRAINIAC_DIR, "projects.json")
            return nil unless File.exist?(projects_file)

            projects = JSON.parse(File.read(projects_file))

            epic_branches.each do |project_key, branch_name|
              repo_path = projects.dig(project_key, "repo_path")
              next unless repo_path && File.directory?(repo_path)

              # List worktrees and find one with this branch
              output, status = Open3.capture2("git", "worktree", "list", "--porcelain", chdir: repo_path)
              next unless status.success?

              current_worktree = nil
              output.each_line do |line|
                if line.start_with?("worktree ")
                  current_worktree = line.sub("worktree ", "").strip
                elsif line.start_with?("branch refs/heads/")
                  wt_branch = line.sub("branch refs/heads/", "").strip
                  if wt_branch == branch_name && current_worktree && current_worktree != repo_path
                    return current_worktree
                  end
                end
              end
            end

            nil
          rescue JSON::ParserError
            nil
          end
        end
      end
    end
  end
end
