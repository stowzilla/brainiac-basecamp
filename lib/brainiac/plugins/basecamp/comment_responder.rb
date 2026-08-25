# frozen_string_literal: true

require "open3"

module Brainiac
  module Plugins
    module Basecamp
      # Handles inbound Basecamp comments on epic todolists/todos.
      #
      # Routing:
      #   1. If a bot account is @mentioned in the comment → dispatch that agent
      #   2. If no mention → dispatch the last agent who responded on this epic
      #   3. If no prior responder → dispatch the epic's default agent
      #
      # The dispatched agent receives the comment content as a prompt with epic context,
      # and posts its reply back via Client.add_comment.
      module CommentResponder
        MENTION_TAG_OPEN = "<bc-attachment"
        MENTION_TAG_CLOSE = "</bc-attachment>"

        class << self
          # Process a comment_created webhook and dispatch the appropriate agent.
          #
          # @param payload [Hash] Full webhook payload
          # @param recording [Hash] The comment recording from the payload
          # @return [Array(Integer, String)] HTTP status code and response body
          def handle(payload, recording)
            content = recording["content"] || ""
            creator = payload["creator"] || {}
            creator_id = creator["id"]&.to_s
            parent = recording["parent"] || {}
            parent_type = parent["type"]
            parent_id = parent["id"]
            parent_title = parent["title"] || ""
            project_id = recording.dig("bucket", "id")&.to_s

            # Ignore comments posted by our own bot accounts (prevent loops)
            if Config.bot_account_for_person(creator_id)
              LOG.debug "[Basecamp:Comment] Ignoring comment from our own bot (person #{creator_id})" if defined?(LOG)
              return [200, { status: "ignored", reason: "self_comment" }.to_json]
            end

            # Determine if this comment is on an epic todolist or a todo within one
            epic = resolve_epic_for_comment(parent_type, parent_id, parent_title, project_id)
            unless epic
              LOG.debug "[Basecamp:Comment] Comment not on an epic recording — ignoring" if defined?(LOG)
              return [200, { status: "ignored", reason: "not_epic" }.to_json]
            end

            # Determine which agent to dispatch
            agent_name = resolve_target_agent(content, epic)

            LOG.info "[Basecamp:Comment] Dispatching #{agent_name} to respond to comment on '#{epic['title']}'" if defined?(LOG)

            # Strip HTML tags for a clean text prompt, preserve @mentions as names
            clean_content = strip_html_preserve_mentions(content)
            commenter_name = creator["name"] || "Someone"

            # Dispatch the agent in a background thread
            Thread.new do
              dispatch_comment_response(
                epic: epic,
                agent_name: agent_name,
                comment_text: clean_content,
                commenter_name: commenter_name,
                recording_id: parent_id,
                project_id: project_id
              )
            rescue StandardError => e
              LOG.error "[Basecamp:Comment] Dispatch failed: #{e.message}\n#{e.backtrace.first(3).join("\n")}" if defined?(LOG)
            end

            # Track last responding agent on the epic
            epic["last_responding_agent"] = agent_name
            epic["updated_at"] = Time.now.iso8601
            Hooks.send(:save_epic_state, epic)

            [200, { status: "dispatched", agent: agent_name, epic_id: epic["id"] }.to_json]
          end

          # Resolve Basecamp person IDs for known agent names using the basecamp CLI.
          # Used during setup to auto-map bot accounts.
          #
          # @param agent_names [Array<String>] Agent names to look up (e.g. ["Galen", "Kaylee"])
          # @param project_id [String, nil] Optional project/bucket ID for scoping
          # @return [Hash<String, String>] agent_name => person_id mapping
          def resolve_person_ids(agent_names)
            results = {}

            agent_names.each do |name|
              # Use jq to filter people by name
              output, status = Open3.capture2(
                "basecamp", "people", "list", "--jq",
                ".data[] | select(.name | ascii_downcase | contains(\"#{name.downcase}\")) | {id, name}"
              )

              next unless status.success?

              # Parse each JSON line (could be multiple matches)
              output.each_line do |line|
                person = JSON.parse(line.strip)
                # Exact match preferred, otherwise first contains-match
                if person["name"]&.downcase == name.downcase
                  results[name] = person["id"].to_s
                  break
                elsif !results.key?(name)
                  results[name] = person["id"].to_s
                end
              rescue JSON::ParserError
                next
              end
            end

            results
          end

          private

          # Find the active epic that this comment belongs to.
          #
          # @param parent_type [String] "Todolist" or "Todo"
          # @param parent_id [Integer, String] ID of the parent recording
          # @param parent_title [String] Title of the parent
          # @param project_id [String] Basecamp bucket/project ID
          # @return [Hash, nil] Epic state or nil
          def resolve_epic_for_comment(parent_type, parent_id, _parent_title, _project_id)
            active_epics = Orchestrator.active_epics

            case parent_type
            when "Todolist"
              # Comment directly on the epic todolist
              active_epics.find { |e| e["todolist_id"].to_s == parent_id.to_s }
            when "Todo"
              # Comment on a specific todo within an epic
              active_epics.find do |e|
                e["tasks"]&.any? { |t| t["todo_id"].to_s == parent_id.to_s }
              end
            end
          end

          # Determine which agent should respond to this comment.
          #
          # Priority:
          #   1. Explicit @mention of a bot account in the comment HTML
          #   2. Last agent who responded on this epic
          #   3. Epic's default agent
          #
          # @param content [String] Comment HTML content
          # @param epic [Hash] Epic state
          # @return [String] Agent name
          def resolve_target_agent(content, epic)
            # 1. Check for @mentions of bot accounts
            mentioned_agent = detect_mentioned_agent(content)
            return mentioned_agent if mentioned_agent

            # 2. Fall back to last responding agent
            return epic["last_responding_agent"] if epic["last_responding_agent"]

            # 3. Fall back to epic's default agent
            epic["agent"] || "Galen"
          end

          # Parse Basecamp rich text HTML to find @mentions of bot accounts.
          #
          # Basecamp mentions look like:
          #   <bc-attachment sgid="..." content-type="application/vnd.basecamp.mention">@Name</bc-attachment>
          #
          # We also check for plain-text @AgentName patterns as a fallback.
          #
          # @param content [String] HTML content of the comment
          # @return [String, nil] Agent name if a bot was mentioned, nil otherwise
          def detect_mentioned_agent(content)
            bot_accounts = Config.current["bot_accounts"] || {}

            # Strategy 1: Parse bc-attachment mentions (Basecamp's native format)
            # The sgid encodes the person — but we can match by the visible name text
            each_basecamp_mention(content) do |mention_content|
              mention_name = strip_html_tags(mention_content).delete_prefix("@").strip
              bot_accounts.each_value do |account|
                agent = account["default_agent"]
                # Match if the mention text contains the agent name (case insensitive)
                return agent if mention_name.downcase.include?(agent.downcase)
              end
            end

            # Strategy 2: Plain text @AgentName pattern (fallback for simple comments)
            bot_accounts.each_value do |account|
              agent = account["default_agent"]
              return agent if content.match?(/(?:^|\s)@#{Regexp.escape(agent)}\b/i)
            end

            nil
          end

          # Strip HTML tags but preserve mention names as readable text.
          # Uses bounded atomic groups to prevent polynomial regex backtracking,
          # and loops until stable to prevent incomplete sanitization (e.g. nested tags
          # that reconstruct dangerous elements after a single pass).
          #
          # @param html [String] HTML content
          # @return [String] Clean text
          def strip_html_preserve_mentions(html)
            text = +""
            cursor = 0

            while (tag_start = html.index("<", cursor))
              text << html[cursor...tag_start]
              tag_end = html.index(">", tag_start + 1)
              break unless tag_end

              tag = html[tag_start..tag_end]
              if basecamp_mention_tag?(tag)
                closing_start = html.index(MENTION_TAG_CLOSE, tag_end + 1)
                break unless closing_start

                mention_content = html[(tag_end + 1)...closing_start]
                text << "@#{strip_html_tags(mention_content).delete_prefix('@').strip}"
                cursor = closing_start + MENTION_TAG_CLOSE.size
                next
              end

              cursor = tag_end + 1
            end

            text << html[cursor..] unless cursor >= html.length || tag_start
            text.split.join(" ")
          end

          # Iterate over the text from native Basecamp mention attachments. This uses
          # bounded String operations rather than a backtracking regular expression,
          # because comment content comes from an untrusted webhook payload.
          def each_basecamp_mention(html)
            cursor = 0

            while (tag_start = html.index(MENTION_TAG_OPEN, cursor))
              tag_end = html.index(">", tag_start + 1)
              break unless tag_end

              closing_start = html.index(MENTION_TAG_CLOSE, tag_end + 1)
              break unless closing_start

              tag = html[tag_start..tag_end]
              yield html[(tag_end + 1)...closing_start] if basecamp_mention_tag?(tag)
              cursor = closing_start + MENTION_TAG_CLOSE.size
            end
          end

          # Return whether an attachment tag has a content-type value containing
          # "mention". Basecamp uses application/vnd.basecamp.mention.
          def basecamp_mention_tag?(tag)
            marker = "content-type="
            marker_start = tag.downcase.index(marker)
            return false unless marker_start

            value_start = marker_start + marker.length
            quote = tag[value_start]
            return false unless ['"', "'"].include?(quote)

            value_end = tag.index(quote, value_start + 1)
            return false unless value_end

            tag[(value_start + 1)...value_end].downcase.include?("mention")
          end

          # Remove markup without returning a dangling '<' sequence. An unclosed tag
          # is discarded with the remainder of the input, keeping the result safe as
          # plain text if it is ever rendered by a downstream consumer.
          def strip_html_tags(html)
            text = +""
            cursor = 0

            while (tag_start = html.index("<", cursor))
              text << html[cursor...tag_start]
              tag_end = html.index(">", tag_start + 1)
              return text if tag_end.nil?

              cursor = tag_end + 1
            end

            text << html[cursor..]
            text
          end

          # Dispatch an agent to respond to the Basecamp comment.
          #
          # @param epic [Hash] Epic state
          # @param agent_name [String] Agent to dispatch
          # @param comment_text [String] Clean text of the comment
          # @param commenter_name [String] Name of the person who commented
          # @param recording_id [String, Integer] The recording to reply to
          # @param project_id [String] Basecamp project/bucket ID
          def dispatch_comment_response(epic:, agent_name:, comment_text:, commenter_name:, recording_id:, project_id:)
            # Build context about the epic state
            tasks_summary = (epic["tasks"] || []).map do |t|
              status_icon = case t["status"]
                            when "complete" then "✅"
                            when "in_flight" then "🚀"
                            when "in_review" then "👀"
                            when "final_decision" then "⚖️"
                            else "⏳"
                            end
              "#{status_icon} ##{t['fizzy_card']} — #{t['title'] || 'Untitled'} (#{t['status']})"
            end.join("\n")

            prompt = <<~PROMPT
              ## Basecamp Comment — Reply Required

              **#{commenter_name}** commented on the epic "#{epic['title']}":

              > #{comment_text}

              ### Epic Status
              #{tasks_summary}

              ### Instructions
              You're responding to a comment on a Basecamp epic todolist. Reply conversationally
              and helpfully. If they're asking about status, give specifics from the task list.
              If they're asking you to do something (pause, skip, adjust), explain what you can do.

              **Reply format:** Write your response as plain text (Basecamp supports basic Markdown).
              Keep it concise but informative.

              When you're done composing your reply, post it using:
              ```
              basecamp comments create #{recording_id} "<your reply>" --in #{project_id}
              ```
            PROMPT

            # Resolve project config for the agent
            project_key = Config.brainiac_project_for(project_id)
            projects_file = File.join(ENV.fetch("BRAINIAC_DIR", File.join(Dir.home, ".brainiac")), "projects.json")
            projects = File.exist?(projects_file) ? JSON.parse(File.read(projects_file)) : {}
            project_config = projects[project_key]

            repo_path = project_config&.dig("repo_path") || Dir.home

            # Spawn the agent
            pid = nil
            log_file = nil
            card_key = "basecamp-comment-#{epic['id']}"

            begin
              pid, log_file = Hooks.send(:run_agent,
                                         prompt,
                                         project_config: project_config,
                                         chdir: repo_path,
                                         log_name: "basecamp-comment-#{epic['id']}-#{Time.now.strftime('%Y%m%d-%H%M%S')}",
                                         agent_name: agent_name,
                                         source: :basecamp,
                                         env: {})
            rescue NameError
              if Object.respond_to?(:run_agent, true)
                pid, log_file = Object.send(:run_agent,
                                            prompt,
                                            project_config: project_config,
                                            chdir: repo_path,
                                            log_name: "basecamp-comment-#{epic['id']}-#{Time.now.strftime('%Y%m%d-%H%M%S')}",
                                            agent_name: agent_name,
                                            source: :basecamp,
                                            env: {})
              else
                LOG.warn "[Basecamp:Comment] run_agent not available — comment response skipped" if defined?(LOG)
                return
              end
            end

            return unless pid

            if defined?(register_session)
              register_session(card_key, pid, log_file: log_file, agent_name: agent_name)
            elsif Object.respond_to?(:register_session, true)
              Object.send(:register_session, card_key, pid, log_file: log_file, agent_name: agent_name)
            end
            LOG.info "[Basecamp:Comment] Spawned #{agent_name} (pid #{pid}) to respond on epic '#{epic['title']}'" if defined?(LOG)
          end
        end
      end
    end
  end
end
