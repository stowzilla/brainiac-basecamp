# frozen_string_literal: true

module Brainiac
  module Plugins
    module Basecamp
      # Epic-level shared memory.
      #
      # Unlike per-card memory (agent-specific, gitignored), epic memory is shared
      # across all agents working the epic AND persisted to git. It accumulates
      # architectural decisions, patterns established, gotchas discovered, and
      # cross-task learnings.
      #
      # The epic review agent writes to this file after each task completes.
      # All task agents and gate agents read it as part of their context.
      #
      # Location: ~/.brainiac/brain/knowledge/epics/epic-<todolist-id>.md
      #
      # This is under knowledge/ (not memory/) because:
      # - memory/ is gitignored — per-card, per-agent, ephemeral
      # - knowledge/ is synced to git — shared, permanent, valuable
      # - Epic learnings should persist and be searchable via qmd
      module EpicMemory
        BRAINIAC_DIR = ENV.fetch("BRAINIAC_DIR", File.join(Dir.home, ".brainiac"))
        EPIC_MEMORY_DIR = File.join(BRAINIAC_DIR, "brain", "knowledge", "epics")

        class << self
          # Path to the epic memory file for a given epic.
          #
          # @param todolist_id [String, Integer] Basecamp todolist ID
          # @return [String] Absolute file path
          def path_for(todolist_id)
            File.join(EPIC_MEMORY_DIR, "epic-#{todolist_id}.md")
          end

          # Ensure the epic memory directory exists.
          def ensure_directory!
            FileUtils.mkdir_p(EPIC_MEMORY_DIR) unless File.directory?(EPIC_MEMORY_DIR)
          end

          # Read the epic memory content, if it exists.
          #
          # @param todolist_id [String, Integer] Basecamp todolist ID
          # @return [String, nil] Content or nil if no memory exists
          def read(todolist_id)
            path = path_for(todolist_id)
            return nil unless File.exist?(path)

            content = File.read(path).strip
            content.empty? ? nil : content
          rescue StandardError => e
            LOG.warn "[Basecamp:EpicMemory] Failed to read epic memory: #{e.message}" if defined?(LOG)
            nil
          end

          # Check if epic memory exists.
          #
          # @param todolist_id [String, Integer] Basecamp todolist ID
          # @return [Boolean]
          def exists?(todolist_id)
            File.exist?(path_for(todolist_id))
          end

          # Ensure epic memory exists for an epic (creates if missing).
          # Called on resume for epics that started before the feature existed.
          #
          # @param epic [Hash] Epic state
          def ensure_exists_for(epic)
            return if exists?(epic["basecamp_todolist_id"])

            initialize_for(epic)
          end

          # Initialize epic memory with the epic title and initial context.
          # Called when an epic starts.
          #
          # @param epic [Hash] Epic state
          def initialize_for(epic)
            ensure_directory!
            path = path_for(epic["basecamp_todolist_id"])

            # Don't overwrite existing memory (in case of resume)
            return if File.exist?(path) && !File.read(path).strip.empty?

            initial_content = <<~MARKDOWN
              # Epic Memory: #{epic['title']}

              Epic started: #{epic['started_at']}
              Orchestrating agent: #{epic['agent']}

              ---

              ## Architectural Decisions

              (No decisions recorded yet)

              ## Patterns Established

              (No patterns recorded yet)

              ## Gotchas & Learnings

              (No learnings recorded yet)

              ## Cross-Task Notes

              (No notes recorded yet)
            MARKDOWN

            File.write(path, initial_content)
            LOG.info "[Basecamp:EpicMemory] Initialized memory for epic #{epic['id']}" if defined?(LOG)
          rescue StandardError => e
            LOG.error "[Basecamp:EpicMemory] Failed to initialize: #{e.message}" if defined?(LOG)
          end

          # Append a section to the epic memory.
          # Used by the epic review agent after each task completes.
          #
          # @param todolist_id [String, Integer] Basecamp todolist ID
          # @param section [String] Section title (e.g., "After Task #1234")
          # @param content [String] Content to add
          def append_section(todolist_id, section:, content:)
            ensure_directory!
            path = path_for(todolist_id)

            existing = File.exist?(path) ? File.read(path) : ""
            timestamp = Time.now.strftime("%Y-%m-%d %H:%M")

            new_section = <<~MARKDOWN

              ---

              ## #{section}
              _Updated: #{timestamp}_

              #{content.strip}
            MARKDOWN

            File.write(path, existing + new_section)
            LOG.info "[Basecamp:EpicMemory] Appended section '#{section}' to epic #{todolist_id}" if defined?(LOG)
          rescue StandardError => e
            LOG.error "[Basecamp:EpicMemory] Failed to append: #{e.message}" if defined?(LOG)
          end

          # Build context injection for an agent prompt.
          # Returns a formatted string with the epic memory, or nil if none exists.
          #
          # @param todolist_id [String, Integer] Basecamp todolist ID
          # @return [String, nil] Formatted context for prompt injection
          def build_context(todolist_id)
            content = read(todolist_id)
            return nil unless content

            <<~CONTEXT
              ## Epic Memory (Shared Knowledge)

              The following is shared knowledge accumulated across this epic.
              Reference this when making implementation decisions.

              #{content}
            CONTEXT
          end

          # Clean up epic memory after epic completes.
          # Optionally archives to a different location rather than deleting.
          #
          # @param todolist_id [String, Integer] Basecamp todolist ID
          # @param archive [Boolean] Whether to archive rather than delete
          def cleanup(todolist_id, archive: true)
            path = path_for(todolist_id)
            return unless File.exist?(path)

            if archive
              archive_dir = File.join(EPIC_MEMORY_DIR, "archived")
              FileUtils.mkdir_p(archive_dir)
              archive_path = File.join(archive_dir, "epic-#{todolist_id}-#{Time.now.strftime('%Y%m%d')}.md")
              FileUtils.mv(path, archive_path)
              LOG.info "[Basecamp:EpicMemory] Archived epic memory to #{archive_path}" if defined?(LOG)
            else
              FileUtils.rm(path)
              LOG.info "[Basecamp:EpicMemory] Deleted epic memory for #{todolist_id}" if defined?(LOG)
            end
          rescue StandardError => e
            LOG.warn "[Basecamp:EpicMemory] Cleanup failed: #{e.message}" if defined?(LOG)
          end
        end
      end
    end
  end
end
