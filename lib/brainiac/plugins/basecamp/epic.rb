# frozen_string_literal: true

require "json"

module Brainiac
  module Plugins
    module Basecamp
      # Parses Basecamp todo subtasks to extract Fizzy card references and dependencies.
      # Also manages the epic state (dependency graph, execution status).
      module Epic
        # Represents a single task within an epic (one subtask → one Fizzy card).
        Task = Struct.new(:step_id, :title, :fizzy_card, :depends_on, :status, :completed, keyword_init: true)

        class << self
          # Parse subtask titles into a structured task list with dependency graph.
          #
          # @param subtasks [Array<Hash>] Raw subtask data from Basecamp API
          # @return [Array<Task>] Parsed tasks with card refs and dependencies
          def parse_subtasks(subtasks)
            subtasks.map do |subtask|
              title = subtask["title"] || ""
              step_id = subtask["id"]
              completed = subtask["completed"] || false

              fizzy_card = extract_fizzy_card(title)
              depends_on = extract_dependencies(title)

              Task.new(
                step_id: step_id,
                title: title,
                fizzy_card: fizzy_card,
                depends_on: depends_on,
                status: completed ? :complete : :pending,
                completed: completed
              )
            end
          end

          # Determine which tasks are unblocked (all dependencies satisfied).
          #
          # @param tasks [Array<Task>] All tasks in the epic
          # @return [Array<Task>] Tasks ready to be worked on
          def unblocked_tasks(tasks)
            completed_cards = tasks.select { |t| t.status == :complete }.map(&:fizzy_card).compact

            tasks.select do |task|
              task.status == :pending &&
                task.fizzy_card &&
                task.depends_on.all? { |dep| completed_cards.include?(dep) }
            end
          end

          # Build a full dependency graph from tasks.
          #
          # @param tasks [Array<Task>] All tasks
          # @return [Hash] Graph structure for visualization/debugging
          def dependency_graph(tasks)
            {
              total: tasks.size,
              complete: tasks.count { |t| t.status == :complete },
              pending: tasks.count { |t| t.status == :pending },
              blocked: tasks.count { |t| t.status == :pending && t.depends_on.any? { |dep| !tasks.any? { |ct| ct.fizzy_card == dep && ct.status == :complete } } },
              unblocked: unblocked_tasks(tasks).size,
              tasks: tasks.map do |t|
                {
                  fizzy_card: t.fizzy_card,
                  status: t.status,
                  depends_on: t.depends_on,
                  step_id: t.step_id
                }
              end
            }
          end

          private

          # Extract Fizzy card number from subtask title.
          # Supports formats:
          #   "Fizzy 1234"
          #   "#1234 — Description"
          #   "#1234"
          #
          # @param title [String]
          # @return [Integer, nil]
          def extract_fizzy_card(title)
            # Try "#NNNN" format first (more explicit)
            if title.match?(/\A#(\d+)/)
              return title.match(/\A#(\d+)/)[1].to_i
            end

            # Try "Fizzy NNNN" format
            if title.match?(/Fizzy\s+(\d+)/i)
              return title.match(/Fizzy\s+(\d+)/i)[1].to_i
            end

            nil
          end

          # Extract dependency card numbers from subtask title.
          # Supports: [depends:1234,1235]
          #
          # @param title [String]
          # @return [Array<Integer>]
          def extract_dependencies(title)
            match = title.match(/\[depends:([\d,]+)\]/)
            return [] unless match

            match[1].split(",").map(&:strip).map(&:to_i)
          end
        end
      end
    end
  end
end
