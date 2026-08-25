# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/brainiac/plugins/basecamp/session_registry"

class TestSessionRegistry < Minitest::Test
  Registry = Brainiac::Plugins::Basecamp::SessionRegistry

  def test_tracks_fizzy_implementation_session_with_epic_metadata
    epic = { "id" => "epic-99" }

    Brainiac::Plugins::Basecamp::Orchestrator.stub(:find_epic_for_card, epic) do
      Registry.track_global_implementation_session("card-1234", Process.pid,
                                                   log_file: "/tmp/agent.log", agent_name: "Kaylee")
    end

    session = Registry.find_session(Registry.implementation_session_id(1234))
    assert_equal Process.pid, session["pid"]
    assert_equal "Kaylee", session["agent_name"]
    assert_equal "epic-99", session["epic_id"]
    assert_equal 1234, session["card_number"]
  end

  def setup
    Registry.reset!
    Registry.suppress_global_forward = true
  end

  def teardown
    Registry.reset!
  end

  # --- register_session ---

  def test_register_session_stores_entry
    Registry.register_session("gate-glados-1234", Process.pid, agent_name: "GLaDOS", epic_id: "epic-100", card_number: 1234)

    session = Registry.find_session("gate-glados-1234")
    assert session
    assert_equal "gate-glados-1234", session["task_id"]
    assert_equal Process.pid, session["pid"]
    assert_equal "GLaDOS", session["agent_name"]
    assert_equal "epic-100", session["epic_id"]
    assert_equal 1234, session["card_number"]
    assert_equal "active", session["status"]
    assert session["started_at"]
  end

  def test_register_session_with_log_file
    Registry.register_session("final-decision-5678", Process.pid, log_file: "/tmp/test.log")

    session = Registry.find_session("final-decision-5678")
    assert_equal "/tmp/test.log", session["log_file"]
  end

  def test_register_session_overwrites_existing
    Registry.register_session("task-1", 100, agent_name: "Old")
    Registry.register_session("task-1", 200, agent_name: "New")

    session = Registry.find_session("task-1")
    assert_equal 200, session["pid"]
    assert_equal "New", session["agent_name"]
  end

  # --- alive? ---

  def test_alive_returns_true_for_current_process
    Registry.register_session("test-alive", Process.pid)

    assert Registry.alive?("test-alive")
  end

  def test_alive_returns_false_for_dead_pid
    # PID 99999999 almost certainly doesn't exist
    Registry.register_session("test-dead", 99_999_999)

    refute Registry.alive?("test-dead")
  end

  def test_alive_returns_false_for_unknown_task
    refute Registry.alive?("nonexistent-task")
  end

  def test_alive_returns_false_for_marked_dead
    Registry.register_session("test-marked", Process.pid)
    Registry.mark_dead("test-marked")

    refute Registry.alive?("test-marked")
  end

  # --- mark_dead ---

  def test_mark_dead_updates_status
    Registry.register_session("task-to-kill", Process.pid)
    result = Registry.mark_dead("task-to-kill")

    assert result
    session = Registry.find_session("task-to-kill")
    assert_equal "dead", session["status"]
    assert session["ended_at"]
  end

  def test_mark_dead_returns_false_for_unknown
    refute Registry.mark_dead("nonexistent")
  end

  # --- sessions_for_epic ---

  def test_sessions_for_epic_filters_correctly
    Registry.register_session("gate-a-100", Process.pid, epic_id: "epic-1", card_number: 100)
    Registry.register_session("gate-b-100", Process.pid, epic_id: "epic-1", card_number: 100)
    Registry.register_session("gate-c-200", Process.pid, epic_id: "epic-2", card_number: 200)

    sessions = Registry.sessions_for_epic("epic-1")
    assert_equal 2, sessions.size
    assert(sessions.all? { |s| s["epic_id"] == "epic-1" })
  end

  def test_sessions_for_epic_returns_empty_for_unknown
    assert_equal [], Registry.sessions_for_epic("nonexistent")
  end

  # --- active_sessions_for_epic ---

  def test_active_sessions_for_epic_excludes_dead
    Registry.register_session("alive-session", Process.pid, epic_id: "epic-1")
    Registry.register_session("dead-session", 99_999_999, epic_id: "epic-1")

    active = Registry.active_sessions_for_epic("epic-1")
    assert_equal 1, active.size
    assert_equal "alive-session", active.first["task_id"]
  end

  # --- any_alive_for_card? ---

  def test_any_alive_for_card_true
    Registry.register_session("gate-glados-42", Process.pid, card_number: 42)

    assert Registry.any_alive_for_card?(42)
  end

  def test_any_alive_for_card_false_when_dead
    Registry.register_session("gate-glados-42", 99_999_999, card_number: 42)

    refute Registry.any_alive_for_card?(42)
  end

  def test_any_alive_for_card_false_when_empty
    refute Registry.any_alive_for_card?(9999)
  end

  # --- active_sessions_for_card ---

  def test_active_sessions_for_card
    Registry.register_session("gate-glados-42", Process.pid, card_number: 42)
    Registry.register_session("gate-threepio-42", Process.pid, card_number: 42)
    Registry.register_session("gate-dead-42", 99_999_999, card_number: 42)

    active = Registry.active_sessions_for_card(42)
    assert_equal 2, active.size
  end

  # --- clear_all! ---

  def test_clear_all_marks_sessions_dead
    Registry.register_session("s1", Process.pid)
    Registry.register_session("s2", Process.pid)

    count = Registry.clear_all!
    assert_equal 2, count

    refute Registry.alive?("s1")
    refute Registry.alive?("s2")
    assert_equal "dead", Registry.find_session("s1")["status"]
    assert_equal "dead", Registry.find_session("s2")["status"]
  end

  def test_clear_all_returns_zero_when_empty
    assert_equal 0, Registry.clear_all!
  end

  # --- sweep! ---

  def test_sweep_removes_old_dead_sessions
    Registry.register_session("old-dead", Process.pid)
    session = Registry.find_session("old-dead")
    session["status"] = "dead"
    session["ended_at"] = (Time.now - 7200).iso8601 # 2 hours ago

    swept = Registry.sweep!(max_age: 3600)
    assert_equal 1, swept
    assert_nil Registry.find_session("old-dead")
  end

  def test_sweep_keeps_recent_dead_sessions
    Registry.register_session("recent-dead", Process.pid)
    Registry.mark_dead("recent-dead")

    swept = Registry.sweep!(max_age: 3600)
    assert_equal 0, swept
    assert Registry.find_session("recent-dead")
  end

  def test_sweep_keeps_active_sessions
    Registry.register_session("still-alive", Process.pid)

    swept = Registry.sweep!(max_age: 0)
    assert_equal 0, swept
    assert Registry.find_session("still-alive")
  end

  # --- reap_dead! ---

  def test_reap_dead_marks_exited_pids
    Registry.register_session("dead-agent", 99_999_999)

    reaped = Registry.reap_dead!
    assert_includes reaped, "dead-agent"

    session = Registry.find_session("dead-agent")
    assert_equal "dead", session["status"]
    assert_equal "pid_exited", session["death_reason"]
  end

  def test_reap_dead_keeps_alive_pids
    Registry.register_session("alive-agent", Process.pid)

    reaped = Registry.reap_dead!
    assert_empty reaped
    assert_equal "active", Registry.find_session("alive-agent")["status"]
  end

  # --- status ---

  def test_status_returns_summary
    Registry.register_session("alive", Process.pid, agent_name: "Galen")
    Registry.register_session("dead", 99_999_999, agent_name: "GLaDOS")

    status = Registry.status
    assert_equal 2, status["total"]
    assert_equal 1, status["active"]
    assert_equal 1, status["dead"]
    assert_equal 2, status["sessions"].size
  end

  # --- persistence ---

  def test_persists_to_disk
    Registry.register_session("persist-test", Process.pid, agent_name: "Test")

    sessions_file = File.join(ENV.fetch("BRAINIAC_DIR"), "basecamp_sessions.json")
    assert File.exist?(sessions_file)

    data = JSON.parse(File.read(sessions_file))
    assert data["sessions"]["persist-test"]
    assert_equal "Test", data["sessions"]["persist-test"]["agent_name"]
  end
end
