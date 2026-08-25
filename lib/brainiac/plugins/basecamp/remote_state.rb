# frozen_string_literal: true

require "json"
require "time"
require "open3"
require "fileutils"
require "socket"

module Brainiac
  module Plugins
    module Basecamp
      # Manages epic state with a write-through cache pattern.
      #
      # Source of truth: a Basecamp document in the project's Docs & Files.
      # Local cache: ~/.brainiac/basecamp_epics.json (fast reads within a session).
      #
      # On every write: update remote first, then local cache.
      # On startup / before dispatch: pull fresh from remote.
      #
      # Config key in ~/.brainiac/basecamp.json:
      #   "remote_state" => {
      #     "enabled" => true,
      #     "document_id" => "12345678",       # Basecamp document ID (auto-created if nil)
      #     "project_id" => "45920028"         # Basecamp project to store the doc in
      #   }
      module RemoteState
        BRAINIAC_DIR = ENV.fetch("BRAINIAC_DIR", File.join(Dir.home, ".brainiac"))
        EPICS_FILE = File.join(BRAINIAC_DIR, "basecamp_epics.json")
        DOC_TITLE = "_brainiac_epics_state"

        class << self
          # Whether remote state sync is enabled.
          #
          # @return [Boolean]
          def enabled?
            config = remote_state_config
            config && config["enabled"] == true && config["project_id"]
          end

          # Load all epics. Uses remote if enabled, falls back to local cache.
          #
          # @param force_remote [Boolean] Force a fetch from Basecamp (ignores local cache)
          # @return [Array<Hash>]
          def load_epics(force_remote: false)
            if enabled? && force_remote
              epics = fetch_remote
              if epics
                write_local_cache(epics)
                return epics
              end
              # Remote fetch failed — fall back to local
              LOG.warn "[Basecamp:RemoteState] Remote fetch failed, using local cache" if defined?(LOG)
            end

            load_local
          end

          # Save an epic (upsert by ID). Writes remote first, then local cache.
          #
          # @param epic [Hash] The epic state to save
          def save_epic(epic)
            all = load_local
            idx = all.index { |e| e["id"] == epic["id"] }
            if idx
              all[idx] = epic
            else
              all << epic
            end

            # Write remote first (source of truth)
            if enabled?
              success = write_remote(all)
              unless success
                LOG.warn "[Basecamp:RemoteState] Remote write failed, saving locally only" if defined?(LOG)
              end
            end

            # Always write local cache
            write_local_cache(all)
          end

          # Sync local state from remote. Call on startup or before critical operations.
          #
          # @return [Boolean] true if sync succeeded
          def sync!
            return false unless enabled?

            epics = fetch_remote
            if epics
              write_local_cache(epics)
              LOG.info "[Basecamp:RemoteState] Synced #{epics.size} epic(s) from Basecamp document" if defined?(LOG)
              true
            else
              LOG.warn "[Basecamp:RemoteState] Sync failed — remote unavailable" if defined?(LOG)
              false
            end
          end

          # Ensure the remote document exists. Creates it if needed and stores the ID in config.
          #
          # @return [String, nil] Document ID or nil on failure
          def ensure_document!
            return nil unless remote_state_config&.dig("project_id")

            doc_id = remote_state_config["document_id"]

            # If we have a doc ID, verify it still exists
            if doc_id
              return doc_id if document_exists?(doc_id)

              LOG.warn "[Basecamp:RemoteState] Document #{doc_id} not found, will create new one" if defined?(LOG)
            end

            # Create the document
            doc_id = create_document
            if doc_id
              save_document_id(doc_id)
              LOG.info "[Basecamp:RemoteState] Created state document: #{doc_id}" if defined?(LOG)
            end

            doc_id
          end

          # Get current remote state config.
          #
          # @return [Hash, nil]
          def remote_state_config
            Config.current["remote_state"]
          end

          private

          # Read epics from local cache file.
          #
          # @return [Array<Hash>]
          def load_local
            return [] unless File.exist?(EPICS_FILE)

            data = JSON.parse(File.read(EPICS_FILE))
            data["epics"] || []
          rescue JSON::ParserError
            []
          end

          # Write epics to local cache file.
          #
          # @param epics [Array<Hash>]
          def write_local_cache(epics)
            FileUtils.mkdir_p(BRAINIAC_DIR)
            File.write(EPICS_FILE, JSON.pretty_generate({
                                                          "epics" => epics,
                                                          "updated_at" => Time.now.iso8601
                                                        }))
          end

          # Fetch epics from the remote Basecamp document.
          #
          # @return [Array<Hash>, nil] Parsed epics array or nil on failure
          def fetch_remote
            doc_id = remote_state_config&.dig("document_id")
            return nil unless doc_id

            project_id = remote_state_config["project_id"]
            stdout, stderr, status = Open3.capture3(
              "basecamp", "files", "show", doc_id.to_s,
              "--in", project_id.to_s,
              "--json"
            )

            unless status.success?
              LOG.error "[Basecamp:RemoteState] Failed to fetch document: #{stderr.strip}" if defined?(LOG)
              return nil
            end

            doc = JSON.parse(stdout)
            content = doc.dig("data", "content") || doc["content"]

            # The document content is stored as JSON wrapped in a code block or raw
            parse_document_content(content)
          rescue JSON::ParserError => e
            LOG.error "[Basecamp:RemoteState] Failed to parse remote document: #{e.message}" if defined?(LOG)
            nil
          rescue StandardError => e
            LOG.error "[Basecamp:RemoteState] Remote fetch error: #{e.message}" if defined?(LOG)
            nil
          end

          # Write epics to the remote Basecamp document.
          #
          # @param epics [Array<Hash>]
          # @return [Boolean] success
          def write_remote(epics)
            doc_id = ensure_document!
            return false unless doc_id

            project_id = remote_state_config["project_id"]
            content = JSON.pretty_generate({
                                             "epics" => epics,
                                             "updated_at" => Time.now.iso8601,
                                             "synced_from" => Socket.gethostname
                                           })

            stdout, stderr, status = Open3.capture3(
              "basecamp", "files", "update", doc_id.to_s,
              "--in", project_id.to_s,
              "--content", content
            )

            unless status.success?
              LOG.error "[Basecamp:RemoteState] Failed to write document: #{stderr.strip}" if defined?(LOG)
              return false
            end

            true
          rescue StandardError => e
            LOG.error "[Basecamp:RemoteState] Remote write error: #{e.message}" if defined?(LOG)
            false
          end

          # Check if a document exists.
          #
          # @param doc_id [String] Document ID
          # @return [Boolean]
          def document_exists?(doc_id)
            project_id = remote_state_config["project_id"]
            _stdout, _stderr, status = Open3.capture3(
              "basecamp", "files", "show", doc_id.to_s,
              "--in", project_id.to_s,
              "--json"
            )
            status.success?
          rescue StandardError
            false
          end

          # Create the state document in Basecamp.
          #
          # @return [String, nil] Document ID or nil on failure
          def create_document
            project_id = remote_state_config["project_id"]
            initial_content = JSON.pretty_generate({
                                                     "epics" => load_local,
                                                     "updated_at" => Time.now.iso8601,
                                                     "synced_from" => Socket.gethostname
                                                   })

            stdout, stderr, status = Open3.capture3(
              "basecamp", "files", "documents", "create",
              DOC_TITLE, initial_content,
              "--in", project_id.to_s,
              "--no-subscribe",
              "--json"
            )

            unless status.success?
              LOG.error "[Basecamp:RemoteState] Failed to create document: #{stderr.strip}" if defined?(LOG)
              return nil
            end

            doc = JSON.parse(stdout)
            doc.dig("data", "id")&.to_s || doc["id"]&.to_s
          rescue StandardError => e
            LOG.error "[Basecamp:RemoteState] Create document error: #{e.message}" if defined?(LOG)
            nil
          end

          # Save the document ID back to the config file.
          #
          # @param doc_id [String]
          def save_document_id(doc_id)
            config_file = Config::CONFIG_FILE
            config = if File.exist?(config_file)
                       JSON.parse(File.read(config_file))
                     else
                       {}
                     end

            config["remote_state"] ||= {}
            config["remote_state"]["document_id"] = doc_id

            File.write(config_file, JSON.pretty_generate(config))
            Config.load! # Reload cached config
          end

          # Parse the content from a Basecamp document into epics array.
          # Handles both raw JSON content and HTML-wrapped content.
          #
          # @param content [String] Document content (may be HTML or raw JSON)
          # @return [Array<Hash>, nil]
          def parse_document_content(content)
            return nil if content.nil? || content.empty?

            # Strip HTML tags if present (Basecamp wraps content in <div> tags)
            text = content.gsub(/<[^>]+>/, "").strip

            # Decode HTML entities
            text = text.gsub("&lt;", "<").gsub("&gt;", ">").gsub("&amp;", "&").gsub("&quot;", "\"")

            return nil if text.empty?

            data = JSON.parse(text)
            data["epics"] || []
          rescue JSON::ParserError
            nil
          end
        end
      end
    end
  end
end
