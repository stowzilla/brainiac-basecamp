# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/brainiac/plugins/basecamp/epic"

class TestEpicParser < Minitest::Test
  # --- Title parsing ---

  def test_extract_fizzy_card_hash_format
    todos = [{ "id" => 1, "title" => "#1234 — Build user auth", "completed" => false }]
    tasks = Brainiac::Plugins::Basecamp::Epic.parse_todos(todos)

    assert_equal 1, tasks.size
    assert_equal 1234, tasks.first.fizzy_card
    assert_equal :pending, tasks.first.status
  end

  def test_extract_fizzy_card_fizzy_format
    todos = [{ "id" => 2, "title" => "Fizzy 5678", "completed" => false }]
    tasks = Brainiac::Plugins::Basecamp::Epic.parse_todos(todos)

    assert_equal 5678, tasks.first.fizzy_card
  end

  def test_extract_fizzy_card_from_description_link
    todos = [{
      "id" => 3,
      "title" => "Build auth system",
      "description" => '<a href="https://app.fizzy.do/stowzilla/cards/1234">Fizzy #1234</a>',
      "completed" => false
    }]
    tasks = Brainiac::Plugins::Basecamp::Epic.parse_todos(todos)

    assert_equal 1234, tasks.first.fizzy_card
  end

  def test_extract_dependencies_from_title
    todos = [{ "id" => 3, "title" => "#1236 — Frontend [depends:1234,1235]", "completed" => false }]
    tasks = Brainiac::Plugins::Basecamp::Epic.parse_todos(todos)

    assert_equal [1234, 1235], tasks.first.depends_on
  end

  def test_extract_dependencies_from_description
    todos = [{
      "id" => 4,
      "title" => "#1236 — Frontend",
      "description" => '<div><strong>Depends on:</strong> #1234, #1235</div>',
      "completed" => false
    }]
    tasks = Brainiac::Plugins::Basecamp::Epic.parse_todos(todos)

    assert_equal [1234, 1235], tasks.first.depends_on
  end

  def test_no_dependencies_returns_empty_array
    todos = [{ "id" => 4, "title" => "#1234 — Simple task", "completed" => false }]
    tasks = Brainiac::Plugins::Basecamp::Epic.parse_todos(todos)

    assert_equal [], tasks.first.depends_on
  end

  def test_completed_todo_has_complete_status
    todos = [{ "id" => 5, "title" => "#1234", "completed" => true }]
    tasks = Brainiac::Plugins::Basecamp::Epic.parse_todos(todos)

    assert_equal :complete, tasks.first.status
  end

  # --- Dependency resolution ---

  def test_unblocked_tasks_no_deps
    todos = [
      { "id" => 1, "title" => "#1234", "completed" => false },
      { "id" => 2, "title" => "#1235", "completed" => false }
    ]
    tasks = Brainiac::Plugins::Basecamp::Epic.parse_todos(todos)
    unblocked = Brainiac::Plugins::Basecamp::Epic.unblocked_tasks(tasks)

    assert_equal 2, unblocked.size
  end

  def test_unblocked_tasks_with_deps
    todos = [
      { "id" => 1, "title" => "#1234", "completed" => true },
      { "id" => 2, "title" => "#1235 [depends:1234]", "completed" => false },
      { "id" => 3, "title" => "#1236 [depends:1234,1235]", "completed" => false }
    ]
    tasks = Brainiac::Plugins::Basecamp::Epic.parse_todos(todos)
    unblocked = Brainiac::Plugins::Basecamp::Epic.unblocked_tasks(tasks)

    # Only #1235 is unblocked (1234 is complete, satisfying its dep)
    # #1236 depends on 1234 (complete) and 1235 (pending) — still blocked
    assert_equal 1, unblocked.size
    assert_equal 1235, unblocked.first.fizzy_card
  end

  def test_unblocked_tasks_all_deps_complete
    todos = [
      { "id" => 1, "title" => "#1234", "completed" => true },
      { "id" => 2, "title" => "#1235", "completed" => true },
      { "id" => 3, "title" => "#1236 [depends:1234,1235]", "completed" => false }
    ]
    tasks = Brainiac::Plugins::Basecamp::Epic.parse_todos(todos)
    unblocked = Brainiac::Plugins::Basecamp::Epic.unblocked_tasks(tasks)

    assert_equal 1, unblocked.size
    assert_equal 1236, unblocked.first.fizzy_card
  end

  def test_unblocked_skips_tasks_without_fizzy_card
    todos = [
      { "id" => 1, "title" => "No card ref", "completed" => false },
      { "id" => 2, "title" => "#1234", "completed" => false }
    ]
    tasks = Brainiac::Plugins::Basecamp::Epic.parse_todos(todos)
    unblocked = Brainiac::Plugins::Basecamp::Epic.unblocked_tasks(tasks)

    assert_equal 1, unblocked.size
    assert_equal 1234, unblocked.first.fizzy_card
  end

  # --- Dependency graph ---

  def test_dependency_graph_summary
    todos = [
      { "id" => 1, "title" => "#1234", "completed" => true },
      { "id" => 2, "title" => "#1235 [depends:1234]", "completed" => false },
      { "id" => 3, "title" => "#1236 [depends:1234,1235]", "completed" => false }
    ]
    tasks = Brainiac::Plugins::Basecamp::Epic.parse_todos(todos)
    graph = Brainiac::Plugins::Basecamp::Epic.dependency_graph(tasks)

    assert_equal 3, graph[:total]
    assert_equal 1, graph[:complete]
    assert_equal 2, graph[:pending]
    assert_equal 1, graph[:unblocked]
    assert_equal 1, graph[:blocked]
  end

  # --- Description builder ---

  def test_build_todo_description_with_deps
    html = Brainiac::Plugins::Basecamp::Epic.build_todo_description(
      fizzy_card: 1234,
      fizzy_account_id: "6098707",
      depends_on: [1230, 1232],
      agent: "Sherlock"
    )

    assert_includes html, 'href="https://app.fizzy.do/6098707/cards/1234"'
    assert_includes html, "#1234"
    assert_includes html, 'href="https://app.fizzy.do/6098707/cards/1230"'
    assert_includes html, 'href="https://app.fizzy.do/6098707/cards/1232"'
    assert_includes html, "Sherlock"
    assert_includes html, "Depends on:"
  end

  def test_build_todo_description_no_deps
    html = Brainiac::Plugins::Basecamp::Epic.build_todo_description(
      fizzy_card: 5678,
      fizzy_account_id: "6098707"
    )

    assert_includes html, 'href="https://app.fizzy.do/6098707/cards/5678"'
    assert_includes html, "Depends on:</strong> none"
    refute_includes html, "Agent:"
  end

  # --- Assignees and metadata ---

  def test_parses_assignees
    todos = [{
      "id" => 1,
      "title" => "#1234",
      "completed" => false,
      "assignees" => [{ "id" => 100, "name" => "Andy" }]
    }]
    tasks = Brainiac::Plugins::Basecamp::Epic.parse_todos(todos)

    assert_equal ["Andy"], tasks.first.assignees
  end

  def test_parses_due_on
    todos = [{
      "id" => 1,
      "title" => "#1234",
      "completed" => false,
      "due_on" => "2026-09-01"
    }]
    tasks = Brainiac::Plugins::Basecamp::Epic.parse_todos(todos)

    assert_equal "2026-09-01", tasks.first.due_on
  end

  def test_no_fizzy_card_in_title_or_description
    todos = [{ "id" => 1, "title" => "Some random task", "completed" => false }]
    tasks = Brainiac::Plugins::Basecamp::Epic.parse_todos(todos)

    assert_nil tasks.first.fizzy_card
  end

  # --- Deploy environment extraction ---

  def test_extract_deploy_env_from_title_bracket_format
    env = Brainiac::Plugins::Basecamp::Epic.extract_deploy_env(
      "Epic: Build Auth System [deploy:dev02]"
    )

    assert_equal "dev02", env
  end

  def test_extract_deploy_env_from_title_with_other_brackets
    env = Brainiac::Plugins::Basecamp::Epic.extract_deploy_env(
      "Epic: Build Auth [depends:1234] [deploy:dev03]"
    )

    assert_equal "dev03", env
  end

  def test_extract_deploy_env_from_description_fallback
    env = Brainiac::Plugins::Basecamp::Epic.extract_deploy_env(
      "Epic: Build Auth System",
      "This epic should deploy:staging after completion"
    )

    assert_equal "staging", env
  end

  def test_extract_deploy_env_title_takes_precedence
    env = Brainiac::Plugins::Basecamp::Epic.extract_deploy_env(
      "Epic: Build Auth System [deploy:dev02]",
      "deploy:staging"
    )

    assert_equal "dev02", env
  end

  def test_extract_deploy_env_returns_nil_when_not_present
    env = Brainiac::Plugins::Basecamp::Epic.extract_deploy_env(
      "Epic: Build Auth System",
      "Just a regular description"
    )

    assert_nil env
  end

  def test_extract_deploy_env_handles_nil_description
    env = Brainiac::Plugins::Basecamp::Epic.extract_deploy_env(
      "Epic: Build Auth System",
      nil
    )

    assert_nil env
  end

  def test_extract_deploy_env_strips_whitespace
    env = Brainiac::Plugins::Basecamp::Epic.extract_deploy_env(
      "Epic: Build Auth System [deploy: dev02 ]"
    )

    assert_equal "dev02", env
  end
end
