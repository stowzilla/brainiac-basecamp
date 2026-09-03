# frozen_string_literal: true

require_relative "test_helper"

# Regression coverage for `brainiac basecamp reset epic <id> --to complete`.
#
# The failure mode: the reset command marked tasks complete but left the epic
# itself status="active" and never set completion_notified. That is exactly the
# "all tasks done but epic still active" state that the 90s reconcile loop
# re-detects — it re-runs complete_epic and re-posts the "🎉 Epic completed"
# notification on every sweep. Operators had to hand-edit basecamp_epics.json to
# finalize the epic.
#
# The fix: when a reset leaves every task complete, finalize the epic in the same
# atomic write (status=complete, completed_at, completion_notified=true) and clear
# awaiting_final_decision on the reset tasks. These tests exercise the REAL
# disk-backed load_epics/save_epics (test_helper points BRAINIAC_DIR at a tmpdir).
class TestResetEpicFinalization < Minitest::Test
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

  # An epic with one straggler task still parked in final_decision — the shape
  # that produced the reported thrash loop.
  def epic_with_one_straggler
    {
      "basecamp_todolist_id" => "10261260344",
      "title" => "Belt Cost Monitoring & Anomaly Detection",
      "status" => "active",
      "agent" => "Kaylee",
      "tasks" => [
        { "fizzy_card" => 1001, "title" => "Task one", "status" => "complete" },
        { "fizzy_card" => 1332, "title" => "Straggler", "status" => "final_decision", "awaiting_final_decision" => true }
      ]
    }
  end

  def test_reset_to_complete_finalizes_the_epic
    write_epic(epic_with_one_straggler)

    silence_output { Cli.send(:cmd_reset_epic, ["10261260344", "--to", "complete"]) }

    epic = reload_epic("10261260344")
    assert_equal "complete", epic["status"], "epic must be finalized, not left active with all tasks done"
    assert epic["completed_at"], "completed_at must be stamped"
    assert epic["completion_notified"], "completion_notified must be set so the reconcile loop never re-notifies"
    assert(epic["tasks"].all? { |t| t["status"] == "complete" })
  end

  def test_reset_to_complete_clears_awaiting_final_decision
    write_epic(epic_with_one_straggler)

    silence_output { Cli.send(:cmd_reset_epic, ["10261260344", "--to", "complete"]) }

    straggler = reload_epic("10261260344")["tasks"].find { |t| t["fizzy_card"] == 1332 }
    refute straggler["awaiting_final_decision"],
           "a completed task must not still be awaiting a final decision (reconciler treats it as unsettled)"
  end

  def test_finalized_epic_is_excluded_from_active_reconcile_set
    write_epic(epic_with_one_straggler)

    silence_output { Cli.send(:cmd_reset_epic, ["10261260344", "--to", "complete"]) }

    active = JSON.parse(File.read(EPICS_FILE))["epics"].select { |e| e["status"] == "active" }
    assert_empty active, "the finalized epic must drop out of the active set the 90s loop scans"
  end

  def test_partial_reset_does_not_finalize_the_epic
    # Resetting to a non-terminal status must leave the epic active — we only
    # finalize when EVERY task ends up complete.
    epic = epic_with_one_straggler
    epic["tasks"] << { "fizzy_card" => 1400, "title" => "Task three", "status" => "in_review" }
    write_epic(epic)

    silence_output { Cli.send(:cmd_reset_epic, ["10261260344", "--to", "pending"]) }

    reloaded = reload_epic("10261260344")
    assert_equal "active", reloaded["status"]
    refute reloaded["completion_notified"]
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
