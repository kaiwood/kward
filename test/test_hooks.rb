require_relative "test_helper"
require_relative "../lib/kward/hooks"

class TestHooks < KwardTestCase
  def test_event_is_immutable_and_serializable
    event = Kward::Hooks::Event.new(
      name: "tool_call_before",
      session: { id: "session-1" },
      payload: { tool_name: "read_file", arguments: { path: "README.md" } }
    )

    assert_equal "tool_call_before", event.name
    assert_equal "before", event.phase
    assert_equal "read_file", event[:tool_name]
    assert event.to_h[:id].start_with?("hookevt_")
    assert_raises(FrozenError) { event.payload[:tool_name] = "edit_file" }
  end

  def test_decision_normalizes_hashes_and_helpers
    deny = Kward::Hooks::Decision.normalize(decision: "deny", message: "blocked")
    modify = Kward::Hooks::Decision.modify({ timeout_seconds: 60 })

    assert deny.deny?
    assert_equal "blocked", deny.message
    assert modify.modify?
    assert_equal({ timeout_seconds: 60 }, modify.payload)
    assert Kward::Hooks::Decision.normalize(nil).allow?
  end

  def test_manager_runs_matching_hooks_in_order_and_merges_modifications
    manager = Kward::Hooks::Manager.new
    calls = []

    manager.register("shell_command_before", id: "second", order: 20) do |event|
      calls << ["second", event.payload[:timeout_seconds]]
      Kward::Hooks::Decision.allow
    end
    manager.register("shell_command_before", id: "first", order: 10, match: { command_regex: "rake" }) do |_event|
      calls << ["first", nil]
      Kward::Hooks::Decision.modify({ timeout_seconds: 120 })
    end

    result = manager.run(Kward::Hooks::Event.new(
      name: "shell_command_before",
      payload: { command: "bundle exec rake test", timeout_seconds: 30 }
    ))

    assert result.allowed?
    assert_equal [["first", nil], ["second", 120]], calls
    assert_equal 120, result.payload[:timeout_seconds]
  end

  def test_manager_stops_on_denial
    manager = Kward::Hooks::Manager.new
    calls = []

    manager.register("tool_call_before", id: "deny", order: 1) do
      calls << "deny"
      Kward::Hooks::Decision.deny("nope")
    end
    manager.register("tool_call_before", id: "later", order: 2) do
      calls << "later"
      Kward::Hooks::Decision.allow
    end

    result = manager.run(Kward::Hooks::Event.new(name: "tool_call_before"))

    assert result.denied?
    assert_equal "nope", result.decision.message
    assert_equal ["deny"], calls
  end

  def test_hook_errors_become_warnings
    manager = Kward::Hooks::Manager.new
    manager.register("turn_end", id: "bad") { raise "boom" }

    result = manager.run(Kward::Hooks::Event.new(name: "turn_end"))

    assert result.allowed?
    assert_equal ["Hook bad failed: boom"], result.warnings
  end

  def test_matcher_supports_file_globs_and_tool_names
    manager = Kward::Hooks::Manager.new
    calls = []
    manager.register("file_change_after", match: { paths: ["lib/**/*.rb"], operation: "edit" }) do
      calls << "matched"
      Kward::Hooks::Decision.allow
    end

    manager.run(Kward::Hooks::Event.new(
      name: "file_change_after",
      payload: { operation: "edit", files: [{ path: "lib/kward/hooks.rb" }] }
    ))
    manager.run(Kward::Hooks::Event.new(
      name: "file_change_after",
      payload: { operation: "edit", files: [{ path: "README.md" }] }
    ))

    assert_equal ["matched"], calls
  end
end
