# frozen_string_literal: true

require_relative "test_helper"

# Regression coverage for two dispatch misfires that made an assigned card look
# like "nothing happened" while two sessions actually spun up and died.
#
# Misfire #1 — a phantom "just completed" epic-review. A ledger flagged a card
#   `complete` with no PR (a stale flag left by the basecamp re-sync that drops
#   merged cards). dispatch_epic_review trusted that flag and posted
#   "Card #N just completed", spawning a pointless review reflex.
#
# Misfire #2 — a dispatch with a blank PR number. A stale in_flight card with no
#   PR was recovered through the "changes requested" template, handing the agent
#   "...fixes on PR #" with an empty number. The agent correctly gave up.
#
# The fixes:
#   1. dispatch_epic_review only fires when the card's completion is backed by a
#      tracked PR number (card_completion_verified?). No evidence → skip the
#      checkpoint but still run the callback so the resolver can advance.
#   2. dispatch_impl_directly builds a clean "start implementation" prompt when
#      there is no PR, and only uses "changes requested" when a real PR exists
#      (build_impl_prompt).
class TestDispatchGuards < Minitest::Test
  Orchestrator = Brainiac::Plugins::Basecamp::Orchestrator
  Hooks = Brainiac::Plugins::Basecamp::Hooks

  # ---------------------------------------------------------------------------
  # Fix #2: build_impl_prompt — no blank "PR #"
  # ---------------------------------------------------------------------------

  def test_impl_prompt_without_pr_is_a_clean_start_implementation
    prompt = Hooks.send(:build_impl_prompt, card_number: 1345, pr_number: nil)

    assert_includes prompt, "Implement — Fizzy Card #1345"
    assert_includes prompt, "no existing PR"
    refute_match(/PR #\s*$/, prompt)
    refute_match(/PR #\s*\n/, prompt)
    refute_includes prompt, "Changes Requested"
  end

  def test_impl_prompt_with_blank_string_pr_is_still_a_clean_start
    # pr_number can arrive as "" from a half-populated ledger entry.
    prompt = Hooks.send(:build_impl_prompt, card_number: 1345, pr_number: "")

    assert_includes prompt, "Implement — Fizzy Card #1345"
    refute_includes prompt, "Changes Requested"
  end

  def test_impl_prompt_with_pr_asks_for_review_fixes
    prompt = Hooks.send(:build_impl_prompt, card_number: 1334, pr_number: 11)

    assert_includes prompt, "Changes Requested — Fizzy Card #1334"
    assert_includes prompt, "PR #11"
    refute_includes prompt, "no existing PR"
  end

  # ---------------------------------------------------------------------------
  # Fix #1: card_completion_verified? gates the epic-review checkpoint
  # ---------------------------------------------------------------------------

  def epic_with(task)
    { "id" => "epic-guard-1", "title" => "Guard", "agent" => "Kaylee", "tasks" => [task] }
  end

  def test_completion_unverified_when_no_pr
    epic = epic_with("fizzy_card" => 1341, "title" => "Docs", "status" => "complete")
    refute Orchestrator.send(:card_completion_verified?, epic, 1341)
  end

  def test_completion_unverified_when_pr_is_blank_string
    epic = epic_with("fizzy_card" => 1341, "title" => "Docs", "status" => "complete", "pr_number" => "")
    refute Orchestrator.send(:card_completion_verified?, epic, 1341)
  end

  def test_completion_verified_when_pr_tracked
    epic = epic_with("fizzy_card" => 1340, "title" => "Engine", "status" => "complete", "pr_number" => 20)
    assert Orchestrator.send(:card_completion_verified?, epic, 1340)
  end

  def test_completion_unverified_for_unknown_card
    epic = epic_with("fizzy_card" => 1340, "title" => "Engine", "status" => "complete", "pr_number" => 20)
    refute Orchestrator.send(:card_completion_verified?, epic, 9999)
  end

  # ---------------------------------------------------------------------------
  # dispatch_epic_review honors the guard: no PR → no checkpoint, callback runs
  # ---------------------------------------------------------------------------

  def test_epic_review_skipped_without_pr_but_callback_still_runs
    epic = {
      "id" => "epic-guard-2", "title" => "Guard", "agent" => "Kaylee",
      "basecamp_todolist_id" => "tl-1", "basecamp_project_id" => "proj-1",
      "tasks" => [
        { "fizzy_card" => 1341, "title" => "Docs", "status" => "complete" }, # no PR → spurious
        { "fizzy_card" => 1347, "title" => "TUI last", "status" => "pending" }
      ]
    }

    callback_ran = false
    review_spawned = false

    # If the guard fails, the real code spawns a Thread that calls run_agent.
    # Stub EpicMemory.ensure_exists_for as a tripwire — it only runs on the
    # dispatch path, after the guard passes.
    Brainiac::Plugins::Basecamp::EpicMemory.stub(:ensure_exists_for, ->(*) { review_spawned = true }) do
      Orchestrator.send(:dispatch_epic_review, epic, 1341) { callback_ran = true }
    end

    assert callback_ran, "callback must run so the resolver can advance"
    refute review_spawned, "no epic-review checkpoint should be dispatched for an unverified completion"
  end

  def test_epic_review_dispatched_when_completion_verified
    epic = {
      "id" => "epic-guard-3", "title" => "Guard", "agent" => "Kaylee",
      "basecamp_todolist_id" => "tl-1", "basecamp_project_id" => "proj-1",
      "tasks" => [
        { "fizzy_card" => 1340, "title" => "Engine", "status" => "complete", "pr_number" => 20 },
        { "fizzy_card" => 1345, "title" => "TUI shell", "status" => "pending" }
      ]
    }

    review_spawned = false

    # Stub the thread-spawning boundary so the test stays hermetic. We assert the
    # guard let us reach the dispatch path via EpicMemory.ensure_exists_for.
    Brainiac::Plugins::Basecamp::EpicMemory.stub(:ensure_exists_for, ->(*) { review_spawned = true }) do
      # Prevent an actual agent process: the run happens inside a Thread that
      # calls Object#run_agent, which isn't defined in tests, so it no-ops.
      Orchestrator.send(:dispatch_epic_review, epic, 1340) { nil }
    end

    assert review_spawned, "a verified completion should reach the epic-review dispatch path"
  end
end
