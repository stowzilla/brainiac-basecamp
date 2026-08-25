# frozen_string_literal: true

require_relative "test_helper"

class TestReviewGate < Minitest::Test
  ReviewGate = Brainiac::Plugins::Basecamp::ReviewGate
  Config = Brainiac::Plugins::Basecamp::Config
  Registry = Brainiac::Plugins::Basecamp::SessionRegistry

  def setup
    Registry.reset!
    Registry.suppress_global_forward = true
    config = {
      "review_gates" => [
        { "agent" => "Avon", "role" => "test-engineer" },
        { "agent" => "Brainiac", "role" => "code-reviewer" }
      ]
    }
    File.write(Config::CONFIG_FILE, JSON.generate(config))
    Config.load!
  end

  def task
    { "fizzy_card" => 1224, "pr_number" => 12 }
  end

  def test_gate_states_are_initialized_per_configured_gate
    states = ReviewGate.gate_states(task)

    assert_equal %w[avon brainiac], states.keys.sort
    assert_equal(
      {
        "agent" => "Avon", "role" => "test-engineer", "status" => "pending",
        "dispatched_at" => nil, "responded_at" => nil, "dispatch_count" => 0
      }, states["avon"]
    )
  end

  def test_gate_states_lazily_adds_a_new_configured_gate
    ReviewGate.gate_states(task)
    File.write(
      Config::CONFIG_FILE,
      JSON.generate(
        "review_gates" => [{ "agent" => "Galen", "role" => "code-reviewer" }]
      )
    )
    Config.load!

    states = ReviewGate.gate_states(task)

    assert_equal "pending", states.fetch("galen").fetch("status")
  end

  def test_legacy_gate_fields_are_migrated_to_state_records
    legacy_task = task.merge(
      "gates_dispatched_at" => "2026-08-24T12:00:00Z",
      "gate_approvals" => [{ "agent" => "Avon", "role" => "test-engineer", "approved_at" => "2026-08-24T12:01:00Z" }],
      "changes_requested_by" => ["Brainiac"],
      "gate_redispatch_counts" => { "brainiac" => 2 }
    )

    states = ReviewGate.gate_states(legacy_task)

    assert_equal "approved", states["avon"]["status"]
    assert_equal "2026-08-24T12:01:00Z", states["avon"]["responded_at"]
    assert_equal "changes_requested", states["brainiac"]["status"]
    assert_equal 2, states["brainiac"]["dispatch_count"]
    refute legacy_task.key?("gate_approvals")
    refute legacy_task.key?("changes_requested_by")
    refute legacy_task.key?("gates_dispatched_at")
  end

  def test_review_responses_update_the_individual_gate_state
    review_task = task

    ReviewGate.record_approval(review_task, agent: "Avon", role: "test-engineer")
    ReviewGate.record_changes_requested(review_task, agent: "Brainiac", role: "code-reviewer")

    assert_equal "approved", ReviewGate.gate_states(review_task)["avon"]["status"]
    assert_equal "changes_requested", ReviewGate.gate_states(review_task)["brainiac"]["status"]
    assert ReviewGate.changes_requested?(review_task)
    assert ReviewGate.all_gates_responded?(review_task)
    refute ReviewGate.all_gates_passed?(review_task)

    ReviewGate.record_approval(review_task, agent: "Brainiac", role: "code-reviewer")
    assert ReviewGate.all_gates_passed?(review_task)
  end

  def test_stale_gate_is_redispatched_from_its_own_record
    review_task = task
    ReviewGate.gate_states(review_task)["avon"].merge!(
      "status" => "dispatched", "dispatched_at" => (Time.now - 301).iso8601, "dispatch_count" => 1
    )
    ReviewGate.gate_states(review_task)["brainiac"]["status"] = "approved"

    dispatched = ReviewGate.redispatch_stale_gates(
      epic: { "id" => "epic-1", "title" => "Test" }, task: review_task,
      pr_number: 12, repo_name: "stowzilla/test", repo_path: Dir.pwd
    )

    assert_equal ["Avon"], dispatched
    state = ReviewGate.gate_states(review_task)["avon"]
    assert_equal "dispatched", state["status"]
    assert_equal 2, state["dispatch_count"]
  end

  def test_live_session_blocks_redispatch_of_a_stale_gate
    review_task = task
    ReviewGate.gate_states(review_task)["avon"].merge!(
      "status" => "dispatched", "dispatched_at" => (Time.now - 301).iso8601, "dispatch_count" => 1
    )
    ReviewGate.gate_states(review_task)["brainiac"]["status"] = "approved"
    Registry.register_session("gate-avon-1224", Process.pid, card_number: 1224)

    assert_empty ReviewGate.redispatch_stale_gates(
      epic: { "id" => "epic-1", "title" => "Test" }, task: review_task,
      pr_number: 12, repo_name: "stowzilla/test", repo_path: Dir.pwd
    )
    state = ReviewGate.gate_states(review_task)["avon"]
    assert_equal "dispatched", state["status"]
    assert_equal 1, state["dispatch_count"]
  end

  def test_gate_times_out_after_its_redispatch_budget
    review_task = task
    ReviewGate.gate_states(review_task)["avon"].merge!(
      "status" => "dispatched", "dispatched_at" => (Time.now - 301).iso8601, "dispatch_count" => 4
    )
    ReviewGate.gate_states(review_task)["brainiac"]["status"] = "approved"

    assert_empty ReviewGate.redispatch_stale_gates(
      epic: { "id" => "epic-1", "title" => "Test" }, task: review_task,
      pr_number: 12, repo_name: "stowzilla/test", repo_path: Dir.pwd
    )
    assert_equal "timed_out", ReviewGate.gate_states(review_task)["avon"]["status"]
  end
end
