# frozen_string_literal: true

require_relative "test_helper"

# Regression coverage for the duplicate "Epic completed" notification bug.
#
# The failure mode: complete_epic set status="complete" in memory but only
# persisted it to disk at the very END of the method — after slow network
# calls (opening PRs, posting to Basecamp). The recovery reconciler loads
# epics FRESH FROM DISK every 90s. During the window where the epic was
# "complete" in memory but still "active" on disk, an overlapping reconcile
# pass would read status="active", sail past the idempotency guard, and
# re-run the whole completion flow — firing the notification again. Five
# passes = five 🎉 messages.
#
# The fix has two layers, and each gets its own test here:
#   1. Persist status="complete" to disk IMMEDIATELY after the guard, before
#      any network calls — closes the race window.
#   2. A completion_notified flag so the notification can fire at most once,
#      even if two passes somehow race past the status check.
#
# These tests use the REAL disk-backed save_epic/load_epics (test_helper points
# BRAINIAC_DIR at a tmpdir) and the REAL Brainiac.emit(:notify) hook to count
# notifications. The only stub is Client.run_safe — that's the external
# Basecamp HTTP boundary, not a query method.
class TestEpicCompletionDedup < Minitest::Test
  Orchestrator = Brainiac::Plugins::Basecamp::Orchestrator
  Config = Brainiac::Plugins::Basecamp::Config
  Client = Brainiac::Plugins::Basecamp::Client
  EPICS_FILE = Orchestrator::EPICS_FILE

  def setup
    # Clean epic store between tests so save_epic/load_epics start fresh.
    FileUtils.rm_f(EPICS_FILE)

    # Real notify hook: count every epic_completed notification that goes out.
    Brainiac.reset_hooks!
    @notifications = []
    Brainiac.on(:notify) { |ctx| @notifications << ctx }

    # Notifications only emit when a target is configured. Point at a fake
    # channel so the real send_notification path runs end-to-end.
    Config.instance_variable_set(:@config, Config::DEFAULT_CONFIG.merge(
                                             "notifications" => { "channel" => "discord", "target" => "test-channel", "epic_completed" => true }
                                           ))
    Config.instance_variable_set(:@config_mtime, Config.send(:config_mtime))
  end

  def teardown
    Brainiac.reset_hooks!
    Config.instance_variable_set(:@config, nil)
    FileUtils.rm_f(EPICS_FILE)
  end

  # A minimal epic that is NOT in epic_branch mode (so open_final_prs/deploy
  # don't run) and already lives on disk as "active".
  def persisted_active_epic
    epic = {
      "id" => "epic-race-1",
      "title" => "Race Condition Repro",
      "status" => "active",
      "agent" => "Kaylee",
      "basecamp_project_id" => "proj-1",
      "started_at" => (Time.now - 3600).iso8601,
      "tasks" => [
        { "fizzy_card" => 1001, "title" => "Task one", "status" => "complete" },
        { "fizzy_card" => 1002, "title" => "Task two", "status" => "complete" }
      ]
    }
    Orchestrator.send(:save_epic, epic)
    epic
  end

  def disk_epic(id)
    Orchestrator.send(:load_epics).find { |e| e["id"] == id }
  end

  def epic_completed_count
    @notifications.count { |n| n[:message].to_s.include?("Epic completed") }
  end

  # ---------------------------------------------------------------------------
  # Layer 1: status is persisted to disk BEFORE the slow network calls.
  # ---------------------------------------------------------------------------

  def test_status_is_persisted_to_disk_before_network_calls
    epic = persisted_active_epic

    # Prove the write happens before the Basecamp post: capture the on-disk
    # status at the moment run_safe (the network call) is invoked.
    status_seen_by_network_call = nil
    Client.stub(:run_safe, lambda { |*_args, **_kwargs|
      status_seen_by_network_call = disk_epic(epic["id"])&.fetch("status")
      nil
    }) do
      Orchestrator.send(:complete_epic, epic)
    end

    assert_equal "complete", status_seen_by_network_call,
                 "status must already be 'complete' on disk by the time the Basecamp post fires"
    assert_equal "complete", disk_epic(epic["id"])["status"]
  end

  def test_status_survives_a_crash_after_the_guard
    epic = persisted_active_epic

    # Simulate the process dying mid-flight: blow up inside the network call,
    # which happens AFTER the early save_epic. Disk must still reflect complete.
    Client.stub(:run_safe, ->(*_a, **_k) { raise "simulated crash posting to Basecamp" }) do
      assert_raises(RuntimeError) { Orchestrator.send(:complete_epic, epic) }
    end

    assert_equal "complete", disk_epic(epic["id"])["status"],
                 "an early persist means a crash can't leave the epic 'active' on disk"
  end

  # ---------------------------------------------------------------------------
  # Layer 2: the completion notification fires at most once.
  # ---------------------------------------------------------------------------

  def test_happy_path_fires_completion_notification_exactly_once
    epic = persisted_active_epic

    Client.stub(:run_safe, ->(*_a, **_k) {}) do
      Orchestrator.send(:complete_epic, epic)
    end

    assert_equal 1, epic_completed_count
    assert epic["completion_notified"], "completion_notified flag should be set after notifying"
    assert disk_epic(epic["id"])["completion_notified"], "flag must be persisted to disk"
  end

  def test_idempotency_guard_blocks_a_second_completion_reading_fresh_from_disk
    epic = persisted_active_epic

    Client.stub(:run_safe, ->(*_a, **_k) {}) do
      # Pass 1 completes the epic.
      Orchestrator.send(:complete_epic, epic)

      # Pass 2 is the recovery reconciler: it loads the epic FRESH FROM DISK.
      # With the fix, disk already says "complete", so the guard trips.
      reloaded = disk_epic(epic["id"])
      Orchestrator.send(:complete_epic, reloaded)
    end

    assert_equal "complete", disk_epic(epic["id"])["status"]
    assert_equal 1, epic_completed_count,
                 "a reconcile pass reading the persisted 'complete' status must not re-notify"
  end

  def test_completion_notified_flag_blocks_double_fire_even_if_status_guard_is_bypassed
    epic = persisted_active_epic

    Client.stub(:run_safe, ->(*_a, **_k) {}) do
      # Pass 1: normal completion.
      Orchestrator.send(:complete_epic, epic)

      # Simulate the pathological race the flag defends against: a second pass
      # somehow gets an epic object whose status was flipped back to "active"
      # (stale in-memory copy) but which still carries completion_notified.
      # The status guard would NOT stop this — only the flag does.
      racing_copy = disk_epic(epic["id"])
      racing_copy["status"] = "active"

      Orchestrator.send(:complete_epic, racing_copy)
    end

    assert_equal 1, epic_completed_count,
                 "completion_notified is the belt-and-suspenders guard: notify once, ever"
  end

  def test_five_overlapping_reconcile_passes_still_notify_only_once
    # Direct reproduction of the reported symptom: five passes, one 🎉.
    epic = persisted_active_epic

    Client.stub(:run_safe, ->(*_a, **_k) {}) do
      5.times do
        # Each pass reads fresh from disk, exactly like the reconciler does.
        pass_epic = disk_epic(epic["id"])
        Orchestrator.send(:complete_epic, pass_epic)
      end
    end

    assert_equal 1, epic_completed_count,
                 "the original bug fired this five times; the fix fires it once"
  end
end
