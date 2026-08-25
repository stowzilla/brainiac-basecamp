# frozen_string_literal: true

require_relative "test_helper"

class TestSessionAwarenessScenarios < Minitest::Test
  Basecamp = Brainiac::Plugins::Basecamp
  Registry = Basecamp::SessionRegistry
  ReviewGate = Basecamp::ReviewGate
  Orchestrator = Basecamp::Orchestrator
  Hooks = Basecamp::Hooks
  Config = Basecamp::Config

  def setup
    Registry.reset!
    Registry.suppress_global_forward = true
    File.write(Config::CONFIG_FILE, JSON.generate(
                                      "review_gates" => [
                                        { "agent" => "Avon", "role" => "test-engineer" },
                                        { "agent" => "Brainiac", "role" => "code-reviewer" }
                                      ]
                                    ))
    Config.load!
  end

  def teardown
    Registry.reset!
  end

  def test_restart_recovery_reassigns_a_dead_session_once_then_honors_registration_grace
    epic = epic_with(task(status: "in_flight", dispatched_at: stale_time))
    task = epic.fetch("tasks").first
    Registry.register_session(Registry.implementation_session_id(1228), 99_999_999,
                              epic_id: epic["id"], card_number: 1228)
    assignments = []

    Orchestrator.stub(:resolve_agent_for_project, "Kaylee") do
      Orchestrator.stub(:resolve_fizzy_user_id, "42") do
        Hooks.stub(:safe_assign_card, ->(card, user) { assignments << [card, user] }) do
          Orchestrator.stub(:dispatch_card, ->(*) { flunk "fresh recovery dispatch must stay in its registration grace period" }) do
            Orchestrator.stub(:save_epic, ->(*) {}) do
              Basecamp.reconcile_active_epics([epic], triggered_by: "startup_recovery")
            end
          end
        end
      end
    end

    assert_equal [[1228, "42"]], assignments
    assert_operator Time.parse(task.fetch("dispatched_at")), :>, Time.now - 5
    assert_equal "dead", Registry.find_session(Registry.implementation_session_id(1228)).fetch("status")
  end

  def test_stale_gate_is_retried_then_explicitly_times_out_during_recovery
    task = task_with_review
    ReviewGate.gate_states(task)["avon"].merge!(
      "status" => "dispatched", "dispatched_at" => stale_time, "dispatch_count" => 1
    )
    ReviewGate.gate_states(task)["brainiac"]["status"] = "approved"

    reconcile_review(task)

    assert_equal "dispatched", ReviewGate.gate_states(task)["avon"].fetch("status")
    assert_equal 2, ReviewGate.gate_states(task)["avon"].fetch("dispatch_count")

    ReviewGate.gate_states(task)["avon"].merge!(
      "dispatched_at" => stale_time, "dispatch_count" => Basecamp::MAX_GATE_REDISPATCH_RETRIES + 1
    )

    refute reconcile_review(task)
    assert_equal "timed_out", ReviewGate.gate_states(task)["avon"].fetch("status")
    assert_equal "in_review", task.fetch("status")
  end

  def test_terminal_epic_does_not_dispatch_new_work_after_restart_reconciliation
    epic = epic_with(task(status: "complete"))
    completed = []

    Orchestrator.stub(:mark_todo_complete, ->(_epic, card) { completed << card }) do
      Orchestrator.stub(:complete_epic, ->(value) { value["status"] = "complete" }) do
        Orchestrator.stub(:save_epic, ->(*) {}) do
          Orchestrator.stub(:dispatch_unblocked_tasks, ->(*) { flunk "terminal epics must not dispatch" }) do
            assert Basecamp.reconcile_epic(epic, triggered_by: "startup_recovery")
          end
        end
      end
    end

    assert_equal [1228], completed
    assert_equal "complete", epic.fetch("status")
  end

  private

  def stale_time
    (Time.now - Basecamp::STALE_DISPATCH_TIMEOUT - 1).iso8601
  end

  def epic_with(task)
    { "id" => "epic-session-awareness", "title" => "Session awareness", "agent" => "Kaylee", "tasks" => [task] }
  end

  def task(status:, dispatched_at: nil)
    {
      "todo_id" => 1, "fizzy_card" => 1228, "project" => "brainiac-basecamp",
      "status" => status, "dispatched_at" => dispatched_at
    }
  end

  def task_with_review
    task(status: "in_review").merge("pr_number" => 55)
  end

  def reconcile_review(task)
    Basecamp.stub(:projects_config, {
                    "brainiac-basecamp" => { "repo_path" => Dir.pwd, "github_repo" => "example/repo" }
                  }) do
      ReviewGate.stub(:sync_from_github, { synced: true }) do
        Basecamp.send(:reconcile_in_review_task, { "id" => "epic-session-awareness", "title" => "Session awareness" }, task,
                      triggered_by: "periodic_recovery")
      end
    end
  end
end
