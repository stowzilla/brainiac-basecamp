# frozen_string_literal: true

require_relative "test_helper"

# Regression coverage for the "🎉 Epic completed" notification thrash loop.
#
# The failure mode (observed 2026-09-03 with the belt-organizations epic): an
# operator resets the last straggler task to complete with
# `brainiac basecamp reset task <card> --to complete`. The task became complete,
# but the epic itself stayed status="active" — and the last task kept
# awaiting_final_decision=true. That is exactly the "all tasks done but epic
# still active" state the 90s reconcile loop re-detects: it re-runs complete_epic
# and re-posts the completion notification on every sweep. The only workaround
# was hand-editing basecamp_epics.json.
#
# The fix: both `reset task` and `reset epic` finalize the epic in the same
# atomic write when the reset leaves every task complete
# (status=complete, completed_at, completion_notified=true), and a completed
# task no longer carries awaiting_final_decision. These tests drive the REAL
# disk-backed load_epics/save_epics (test_helper points BRAINIAC_DIR at a
# tmpdir).
class TestResetFinalizesEpic < Minitest::Test
  Cli = Brainiac::Plugins::Basecamp::Cli
  EPICS_FILE = File.join(Cli::BRAINIAC_DIR, "basecamp_epics.json")

  def setup
    FileUtils.rm_f(EPICS_FILE)
  end

  def teardown
    FileUtils.rm_f(EPICS_FILE)
  end

  def write_epic(epic)
    File.write(EPICS_FILE, JSON.pretty_generate("epics" => [epic]))
  end

  def reload_epic(todolist_id)
    JSON.parse(File.read(EPICS_FILE))["epics"].find { |e| e["basecamp_todolist_id"] == todolist_id }
  end

  # An epic with one straggler still parked in final_decision — the exact shape
  # that produced the reported thrash loop.
  def epic_with_one_straggler
    {
      "basecamp_todolist_id" => "10264779750",
      "title" => "Epic: belt-organizations plugin",
      "status" => "active",
      "agent" => "Kaylee",
      "tasks" => [
        { "fizzy_card" => 1001, "title" => "Task one", "status" => "complete" },
        { "fizzy_card" => 1341, "title" => "Docs/README/SECURITY/AGENTS",
          "status" => "final_decision", "awaiting_final_decision" => true }
      ]
    }
  end

  # --- reset task ---------------------------------------------------------

  def test_reset_task_to_complete_finalizes_the_epic
    write_epic(epic_with_one_straggler)

    silence_output { Cli.send(:cmd_reset_task, %w[1341 --to complete]) }

    epic = reload_epic("10264779750")
    assert_equal "complete", epic["status"], "epic must be finalized, not left active with all tasks done"
    assert epic["completed_at"], "completed_at must be stamped"
    assert epic["completion_notified"], "completion_notified must be set so the reconcile loop never re-notifies"
    assert(epic["tasks"].all? { |t| t["status"] == "complete" })
  end

  def test_reset_task_to_complete_clears_awaiting_final_decision
    write_epic(epic_with_one_straggler)

    silence_output { Cli.send(:cmd_reset_task, %w[1341 --to complete]) }

    straggler = reload_epic("10264779750")["tasks"].find { |t| t["fizzy_card"] == 1341 }
    refute straggler["awaiting_final_decision"],
           "a completed task must not still be awaiting a final decision (reconciler treats it as unsettled)"
  end

  def test_reset_task_does_not_finalize_when_others_incomplete
    epic = epic_with_one_straggler
    epic["tasks"] << { "fizzy_card" => 1400, "title" => "Task three", "status" => "in_review" }
    write_epic(epic)

    silence_output { Cli.send(:cmd_reset_task, %w[1341 --to complete]) }

    reloaded = reload_epic("10264779750")
    assert_equal "active", reloaded["status"], "epic must stay active while any task is incomplete"
    refute reloaded["completion_notified"]
  end

  # --- reset epic ---------------------------------------------------------

  def test_reset_epic_to_complete_finalizes_the_epic
    write_epic(epic_with_one_straggler)

    silence_output { Cli.send(:cmd_reset_epic, %w[10264779750 --to complete]) }

    epic = reload_epic("10264779750")
    assert_equal "complete", epic["status"]
    assert epic["completed_at"]
    assert epic["completion_notified"]
  end

  def test_finalized_epic_drops_out_of_active_reconcile_set
    write_epic(epic_with_one_straggler)

    silence_output { Cli.send(:cmd_reset_task, %w[1341 --to complete]) }

    active = JSON.parse(File.read(EPICS_FILE))["epics"].select { |e| e["status"] == "active" }
    assert_empty active, "the finalized epic must drop out of the active set the 90s loop scans"
  end

  private

  def silence_output
    original = $stdout
    $stdout = StringIO.new
    yield
  ensure
    $stdout = original
  end
end
