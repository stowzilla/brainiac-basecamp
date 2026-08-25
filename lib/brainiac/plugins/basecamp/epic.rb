# frozen_string_literal: true

require "json"

module Brainiac
  module Plugins
    module Basecamp
      # Parses Basecamp todolist-based epics.
      #
      # Epic structure (Option C):
      #   Todolist: "Epic: Build Auth System"
      #     Todo: "#1234 — Set up auth models"
      #       Description: <a href="https://app.fizzy.do/org/cards/1234">Fizzy #1234</a>
      #                    [depends:none] or [depends:1234,1235]
      #     Todo: "#1235 — Add API endpoints"
      #       Description: ...
      #
      # Each todo in the list = one work item linked to a Fizzy card.
      # Dependencies are declared in the todo description or title.
      module Epic
        # Represents a single task within an epic (one todo → one Fizzy card).
        Task = Struct.new(:todo_id, :title, :fizzy_card, :depends_on, :status, :completed,
                          :description, :assignees, :due_on, :project, keyword_init: true)

        class << self
          # Parse todos from a todolist into structured tasks with dependency graph.
          #
          # @param todos [Array<Hash>] Raw todo data from Basecamp API
          # @return [Array<Task>] Parsed tasks with card refs and dependencies
          def parse_todos(todos)
            todos.map do |todo|
              title = todo["title"] || todo["content"] || ""
              description = todo["description"] || ""
              todo_id = todo["id"]
              completed = todo["completed"] || false
              assignees = (todo["assignees"] || []).map { |a| a["name"] || a["id"].to_s }
              due_on = todo["due_on"]

              fizzy_card = extract_fizzy_card(title) || extract_fizzy_card_from_description(description)
              depends_on = extract_dependencies(title)
              depends_on = extract_dependencies(description) if depends_on.empty?

              Task.new(
                todo_id: todo_id,
                title: title,
                fizzy_card: fizzy_card,
                depends_on: depends_on,
                status: completed ? :complete : :pending,
                completed: completed,
                description: description,
                assignees: assignees,
                due_on: due_on
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
            completed_cards = tasks.select { |t| t.status == :complete }.map(&:fizzy_card).compact

            {
              total: tasks.size,
              complete: tasks.count { |t| t.status == :complete },
              pending: tasks.count { |t| t.status == :pending },
              in_flight: tasks.count { |t| t.status == :in_flight },
              blocked: tasks.count do |t|
                t.status == :pending &&
                  t.depends_on.any? { |dep| !completed_cards.include?(dep) }
              end,
              unblocked: unblocked_tasks(tasks).size,
              tasks: tasks.map do |t|
                {
                  todo_id: t.todo_id,
                  fizzy_card: t.fizzy_card,
                  title: t.title,
                  status: t.status,
                  depends_on: t.depends_on,
                  assignees: t.assignees,
                  due_on: t.due_on
                }
              end
            }
          end

          # Generate a rich text HTML description for a todo linked to a Fizzy card.
          #
          # @param fizzy_card [Integer] Fizzy card number
          # @param fizzy_account_id [String] Fizzy account ID (for URL)
          # @param depends_on [Array<Integer>] Card numbers this task depends on
          # @param agent [String, nil] Agent name assigned to this task
          # @return [String] HTML description
          def build_todo_description(fizzy_card:, fizzy_account_id:, depends_on: [], agent: nil)
            lines = []
            lines << "<div>"
            lines << "<strong>Fizzy:</strong> <a href=\"https://app.fizzy.do/#{fizzy_account_id}/cards/#{fizzy_card}\">##{fizzy_card}</a><br>"

            if depends_on.any?
              dep_links = depends_on.map { |d| "<a href=\"https://app.fizzy.do/#{fizzy_account_id}/cards/#{d}\">##{d}</a>" }
              lines << "<strong>Depends on:</strong> #{dep_links.join(', ')}<br>"
            else
              lines << "<strong>Depends on:</strong> none<br>"
            end

            lines << "<strong>Agent:</strong> #{agent}<br>" if agent
            lines << "</div>"
            lines.join("\n")
          end

          # Extract deploy environment from epic title or description.
          # Supports:
          #   [deploy:dev02]  — in title (preferred)
          #   deploy:dev02    — in description (fallback)
          #
          # @param title [String] Epic/todolist title
          # @param description [String, nil] Optional description to check as fallback
          # @return [String, nil] Environment name or nil
          def extract_deploy_env(title, description = nil)
            # Try [deploy:env] format in title (preferred)
            if title
              marker = "[deploy:"
              value_start = title.index(marker)
              if value_start
                value_start += marker.length
                value_end = title.index("]", value_start)
                if value_end
                  environment = title[value_start...value_end].strip
                  return environment unless environment.empty?
                end
              end
            end

            # Fallback: try deploy:env in description
            if description && (match = description.match(/deploy:(\S+)/i))
              return match[1].strip
            end

            nil
          end

          private

          # Extract Fizzy card number from title.
          # Supports formats:
          #   "#1234 — Description"
          #   "#1234"
          #   "Fizzy 1234"
          #   "Fizzy #1234"
          #
          # @param text [String]
          # @return [Integer, nil]
          def extract_fizzy_card(text)
            # Try "#NNNN" format first (more explicit)
            if (match = text.match(/\A#(\d+)/) || text.match(/#(\d+)/))
              return match[1].to_i
            end

            # Try "Fizzy NNNN" or "Fizzy #NNNN" format
            if (match = text.match(/Fizzy\s+#?(\d+)/i))
              return match[1].to_i
            end

            nil
          end

          # Extract Fizzy card from a rich text description (look for link to fizzy.do).
          #
          # @param description [String] HTML description
          # @return [Integer, nil]
          def extract_fizzy_card_from_description(description)
            return nil if description.nil? || description.empty?

            # Look for fizzy.do card URLs
            if (match = description.match(%r{app\.fizzy\.do/[^/]+/cards/(\d+)}))
              return match[1].to_i
            end

            # Fallback: look for "#NNNN" in description text
            if (match = description.match(/#(\d+)/))
              return match[1].to_i
            end

            nil
          end

          # Extract dependency card numbers from text (title or description).
          # Supports:
          #   [depends:1234,1235]
          #   Depends on: #1234, #1235
          #   <strong>Depends on:</strong> #1234, #1235
          #
          # @param text [String]
          # @return [Array<Integer>]
          def extract_dependencies(text)
            return [] if text.nil? || text.empty?

            # Try [depends:N,N] format
            if (match = text.match(/\[depends:([\d,]+)\]/))
              return match[1].split(",").map(&:strip).map(&:to_i)
            end

            # Try "Depends on:" format (handles HTML tags around it)
            # Strip HTML tags first for matching
            stripped = text.gsub(/<[^>]+>/, "")
            if (match = stripped.match(/Depends on:\s*((?:#\d+[\s,]*)+)/i))
              return match[1].scan(/#(\d+)/).flatten.map(&:to_i)
            end

            []
          end
        end
      end
    end
  end
end
