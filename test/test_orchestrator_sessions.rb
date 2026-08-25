# frozen_string_literal: true

require_relative "test_helper"

class TestOrchestratorSessions < Minitest::Test
  Orchestrator = Brainiac::Plugins::Basecamp::Orchestrator
  Registry = Brainiac::Plugins::Basecamp::SessionRegistry

  def setup
    Registry.reset!
    Registry.suppress_global_forward = true
  end

  def teardown
    Registry.reset!
  end

  def test_dispatch_card_skips_a_live_implementation_session
    epic = epic_with_task
    task = epic["tasks"].first
    Registry.register_session(
      Registry.implementation_session_id(1234), Process.pid,
      agent_name: "Kaylee", epic_id: epic["id"], card_number: 1234
    )

    Orchestrator.stub(:resolve_agent_for_project, nil) do
      Orchestrator.stub(:assign_fizzy_card, ->(*) { flunk "must not assign while session is live" }) do
        assert_equal false, Orchestrator.send(:dispatch_card, epic, epic_task(task))
      end
    end
  end

  def test_dead_in_flight_session_is_eligible_for_recovery_dispatch
    epic = epic_with_task(status: "in_flight")
    dispatched = []

    Orchestrator.stub(:dispatch_card, ->(_epic, task) { dispatched << task.fizzy_card }) do
      Orchestrator.send(:dispatch_unblocked_tasks, epic)
    end

    assert_equal [1234], dispatched
  end

  def test_live_in_flight_session_is_not_redispatched
    epic = epic_with_task(status: "in_flight")
    Registry.register_session(
      Registry.implementation_session_id(1234), Process.pid,
      agent_name: "Kaylee", epic_id: epic["id"], card_number: 1234
    )

    Orchestrator.stub(:dispatch_card, ->(*) { flunk "must not redispatch a live session" }) do
      Orchestrator.send(:dispatch_unblocked_tasks, epic)
    end
  end

  def test_failed_implementation_completion_marks_its_session_dead
    epic = epic_with_task(status: "in_flight")
    Registry.register_session(
      Registry.implementation_session_id(1234), Process.pid,
      agent_name: "Kaylee", epic_id: epic["id"], card_number: 1234
    )
    Brainiac.reset_hooks!
    Brainiac::Plugins::Basecamp::Hooks.send(:register_agent_completed)

    Orchestrator.stub(:find_epic_for_card, epic) do
      Brainiac.emit(
        :agent_completed,
        source: :fizzy,
        card_number: 1234,
        agent_name: "Kaylee",
        exit_status: 1,
        signaled: false
      )
    end

    refute Registry.implementation_alive?(1234)
  ensure
    Brainiac.reset_hooks!
  end

  private

  def epic_with_task(status: "pending")
    {
      "id" => "epic-1", "title" => "Session test", "agent" => "Kaylee", "tasks" => [{
        "todo_id" => 1, "fizzy_card" => 1234, "title" => "Task", "depends_on" => [],
        "status" => status, "project" => "test-project"
      }]
    }
  end

  def epic_task(task)
    Brainiac::Plugins::Basecamp::Epic::Task.new(
      todo_id: task["todo_id"], fizzy_card: task["fizzy_card"], title: task["title"],
      depends_on: task["depends_on"], status: task["status"].to_sym, project: task["project"]
    )
  end
end
