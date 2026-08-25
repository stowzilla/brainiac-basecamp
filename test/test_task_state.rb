# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/brainiac/plugins/basecamp/task_state"

class TestTaskState < Minitest::Test
  TaskState = Brainiac::Plugins::Basecamp::TaskState

  def test_valid_transitions_record_a_complete_audit_trail
    task = { "status" => "pending" }
    at = Time.utc(2026, 8, 24, 12, 0, 0)

    TaskState.transition!(task, :dispatch, triggered_by: "orchestrator", at: at)
    TaskState.transition!(task, :submit_for_review, triggered_by: "agent_completed", at: at + 1)
    TaskState.transition!(task, :approve, triggered_by: "review_gates", at: at + 2)
    TaskState.transition!(task, :complete, triggered_by: "pr_merged", at: at + 3)

    assert_equal "complete", task["status"]
    assert_equal(
      {
        "from_state" => "final_decision",
        "to_state" => "complete",
        "triggered_by" => "pr_merged",
        "timestamp" => "2026-08-24T12:00:03Z"
      },
      task["transitions"].last
    )
  end

  def test_invalid_transition_does_not_mutate_task
    task = { "status" => "pending" }

    error = assert_raises(TaskState::InvalidTransition) do
      TaskState.transition!(task, :approve, triggered_by: "review_gates")
    end

    assert_match "cannot approve task from pending", error.message
    assert_equal "pending", task["status"]
    refute task.key?("transitions")
  end

  def test_guard_failure_prevents_transition
    task = { "status" => "in_review" }

    assert_raises(TaskState::InvalidTransition) do
      TaskState.transition!(task, :approve, triggered_by: "review_gates", guard: false)
    end

    assert_equal "in_review", task["status"]
  end

  def test_legacy_task_is_migrated_before_its_next_transition
    task = { "status" => "in_flight" }

    TaskState.transition!(task, :submit_for_review, triggered_by: "pr_synchronized")

    assert_equal "in_flight", task["transitions"].first["to_state"]
    assert_equal "in_review", task["transitions"].last["to_state"]
  end

  def test_idempotent_transition_does_not_duplicate_the_audit_trail
    task = { "status" => "in_flight", "transitions" => [] }

    TaskState.transition!(task, :dispatch, triggered_by: "recovery")

    assert_equal "in_flight", task["status"]
    assert_empty task["transitions"]
  end
end
