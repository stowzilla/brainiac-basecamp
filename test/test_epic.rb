# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/brainiac/plugins/basecamp/epic"

class TestEpicParser < Minitest::Test
  def test_extract_fizzy_card_hash_format
    subtasks = [{ "id" => 1, "title" => "#1234 — Build user auth", "completed" => false }]
    tasks = Brainiac::Plugins::Basecamp::Epic.parse_subtasks(subtasks)

    assert_equal 1, tasks.size
    assert_equal 1234, tasks.first.fizzy_card
    assert_equal :pending, tasks.first.status
  end

  def test_extract_fizzy_card_fizzy_format
    subtasks = [{ "id" => 2, "title" => "Fizzy 5678", "completed" => false }]
    tasks = Brainiac::Plugins::Basecamp::Epic.parse_subtasks(subtasks)

    assert_equal 5678, tasks.first.fizzy_card
  end

  def test_extract_dependencies
    subtasks = [{ "id" => 3, "title" => "#1236 — Frontend [depends:1234,1235]", "completed" => false }]
    tasks = Brainiac::Plugins::Basecamp::Epic.parse_subtasks(subtasks)

    assert_equal [1234, 1235], tasks.first.depends_on
  end

  def test_no_dependencies_returns_empty_array
    subtasks = [{ "id" => 4, "title" => "#1234 — Simple task", "completed" => false }]
    tasks = Brainiac::Plugins::Basecamp::Epic.parse_subtasks(subtasks)

    assert_equal [], tasks.first.depends_on
  end

  def test_completed_subtask_has_complete_status
    subtasks = [{ "id" => 5, "title" => "#1234", "completed" => true }]
    tasks = Brainiac::Plugins::Basecamp::Epic.parse_subtasks(subtasks)

    assert_equal :complete, tasks.first.status
  end

  def test_unblocked_tasks_no_deps
    subtasks = [
      { "id" => 1, "title" => "#1234", "completed" => false },
      { "id" => 2, "title" => "#1235", "completed" => false }
    ]
    tasks = Brainiac::Plugins::Basecamp::Epic.parse_subtasks(subtasks)
    unblocked = Brainiac::Plugins::Basecamp::Epic.unblocked_tasks(tasks)

    assert_equal 2, unblocked.size
  end

  def test_unblocked_tasks_with_deps
    subtasks = [
      { "id" => 1, "title" => "#1234", "completed" => true },
      { "id" => 2, "title" => "#1235 [depends:1234]", "completed" => false },
      { "id" => 3, "title" => "#1236 [depends:1234,1235]", "completed" => false }
    ]
    tasks = Brainiac::Plugins::Basecamp::Epic.parse_subtasks(subtasks)
    unblocked = Brainiac::Plugins::Basecamp::Epic.unblocked_tasks(tasks)

    # Only #1235 is unblocked (#1234 is complete, so its dep is satisfied)
    # #1236 depends on both 1234 (complete) and 1235 (pending) — still blocked
    assert_equal 1, unblocked.size
    assert_equal 1235, unblocked.first.fizzy_card
  end

  def test_unblocked_tasks_all_deps_complete
    subtasks = [
      { "id" => 1, "title" => "#1234", "completed" => true },
      { "id" => 2, "title" => "#1235", "completed" => true },
      { "id" => 3, "title" => "#1236 [depends:1234,1235]", "completed" => false }
    ]
    tasks = Brainiac::Plugins::Basecamp::Epic.parse_subtasks(subtasks)
    unblocked = Brainiac::Plugins::Basecamp::Epic.unblocked_tasks(tasks)

    assert_equal 1, unblocked.size
    assert_equal 1236, unblocked.first.fizzy_card
  end

  def test_dependency_graph_summary
    subtasks = [
      { "id" => 1, "title" => "#1234", "completed" => true },
      { "id" => 2, "title" => "#1235 [depends:1234]", "completed" => false },
      { "id" => 3, "title" => "#1236 [depends:1234,1235]", "completed" => false }
    ]
    tasks = Brainiac::Plugins::Basecamp::Epic.parse_subtasks(subtasks)
    graph = Brainiac::Plugins::Basecamp::Epic.dependency_graph(tasks)

    assert_equal 3, graph[:total]
    assert_equal 1, graph[:complete]
    assert_equal 2, graph[:pending]
    assert_equal 1, graph[:unblocked]
    assert_equal 1, graph[:blocked]
  end

  def test_no_fizzy_card_in_title
    subtasks = [{ "id" => 1, "title" => "Some random task", "completed" => false }]
    tasks = Brainiac::Plugins::Basecamp::Epic.parse_subtasks(subtasks)

    assert_nil tasks.first.fizzy_card
  end

  def test_unblocked_skips_tasks_without_fizzy_card
    subtasks = [
      { "id" => 1, "title" => "No card ref", "completed" => false },
      { "id" => 2, "title" => "#1234", "completed" => false }
    ]
    tasks = Brainiac::Plugins::Basecamp::Epic.parse_subtasks(subtasks)
    unblocked = Brainiac::Plugins::Basecamp::Epic.unblocked_tasks(tasks)

    # Only #1234 should be unblocked (the other has no fizzy_card)
    assert_equal 1, unblocked.size
    assert_equal 1234, unblocked.first.fizzy_card
  end
end
