# frozen_string_literal: true

require_relative "test_helper"

class TestRecovery < Minitest::Test
  Basecamp = Brainiac::Plugins::Basecamp
  Registry = Basecamp::SessionRegistry
  TaskState = Basecamp::TaskState
  ReviewGate = Basecamp::ReviewGate
  Orchestrator = Basecamp::Orchestrator
  Hooks = Basecamp::Hooks

  def setup
    Registry.reset!
    Registry.suppress_global_forward = true
  end

  def task(status: "in_flight")
    {
      "fizzy_card" => 1226,
      "project" => "brainiac-basecamp",
      "status" => status,
      "dispatched_at" => (Time.now - Basecamp::STALE_DISPATCH_TIMEOUT - 1).iso8601
    }
  end

  def test_live_implementation_session_blocks_stale_redispatch
    task = task()
    Registry.register_session("implementation-1226", Process.pid, card_number: 1226)

    result = Basecamp.send(:reconcile_in_flight_task, { "agent" => "Kaylee" }, task)

    refute result
  end

  def test_dead_implementation_session_is_redispatched_after_grace_period
    task = task()
    assigned = nil

    Orchestrator.stub(:resolve_agent_for_project, "Kaylee") do
      Orchestrator.stub(:resolve_fizzy_user_id, "42") do
        Hooks.stub(:safe_assign_card, ->(card, user) { assigned = [card, user] }) do
          assert Basecamp.send(:reconcile_in_flight_task, { "agent" => "Kaylee" }, task)
        end
      end
    end

    assert_equal [1226, "42"], assigned
    assert_operator Time.parse(task["dispatched_at"]), :>, Time.now - 5
  end

  def test_gate_recovery_transitions_through_task_state
    task = task(status: "in_review").merge("pr_number" => 12)
    epic = { "id" => "epic-1", "agent" => "Kaylee" }
    dispatched = false

    ReviewGate.stub(:enabled?, true) do
      ReviewGate.stub(:sync_from_github, { synced: true }) do
        ReviewGate.stub(:all_gates_passed?, true) do
          Hooks.stub(:dispatch_final_decision, ->(*) { dispatched = true }) do
            Basecamp.stub(:projects_config, { "brainiac-basecamp" => { "repo_path" => Dir.pwd, "github_repo" => "example/repo" } }) do
              assert Basecamp.send(:reconcile_in_review_task, epic, task, triggered_by: "test_recovery")
            end
          end
        end
      end
    end

    assert TaskState.in?(task, :final_decision)
    assert_equal "test_recovery", task.fetch("transitions").last.fetch("triggered_by")
    assert dispatched
  end
end
