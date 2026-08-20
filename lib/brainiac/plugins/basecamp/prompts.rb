# frozen_string_literal: true

module Brainiac
  module Plugins
    module Basecamp
      # Prompt templates for Basecamp-aware agent sessions.
      module Prompts
        # Injected into agent prompts when working on an epic task.
        # Placeholders use %{name} format (rendered by the orchestrator).
        EPIC_CONTEXT = <<~'PROMPT'
          ## Basecamp Epic Context

          You are working on a task that is part of a larger epic managed in Basecamp.
          The orchestrator will automatically advance to the next task when you complete this one.

          **Important:**
          - Focus only on this specific card's requirements
          - When done, commit and push as normal — the orchestrator handles sequencing
          - If you discover the task needs changes to the plan (new dependencies, scope change),
            mention it in your Fizzy comment so the human can adjust the Basecamp epic

          Epic: %{epic_title}
          Progress: %{epic_progress}
          Your task: %{task_title} (Fizzy #%{fizzy_card})
          %{dependencies}
        PROMPT

        # Template for the Basecamp channel (if agents post directly to Basecamp).
        # Currently unused — agents post to Fizzy/Discord, orchestrator posts to Basecamp.
        CHANNEL = <<~'PROMPT'
          ## Basecamp Communication

          When referencing Basecamp items:
          - Use the basecamp CLI for queries: `basecamp todos list --in <project> --json`
          - Format card references as: Fizzy #NNNN
          - Keep Basecamp comments brief — detailed discussion happens in Fizzy/Discord
        PROMPT
      end
    end
  end
end
