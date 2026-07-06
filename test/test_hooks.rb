require "net/http"
require "shellwords"
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

  def test_catalog_lists_known_events_and_defaults
    assert_includes Kward::Hooks::Catalog.event_names, "shell_command_before"
    assert Kward::Hooks::Catalog.known?("tool_call_before")
    assert_equal "deny", Kward::Hooks::Catalog.failure_policy("shell_command_before")
    assert_equal "warn", Kward::Hooks::Catalog.failure_policy("file_change_after")
  end

  def test_manager_uses_failure_policy_for_hook_errors
    manager = Kward::Hooks::Manager.new
    manager.register("tool_call_before", id: "bad", failure_policy: "deny") { raise "boom" }

    result = manager.run(Kward::Hooks::Event.new(name: "tool_call_before"))

    assert result.denied?
    assert_equal "Hook bad failed: boom", result.decision.message
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
    manager.register("turn_end", id: "bad", failure_policy: "warn") { raise "boom" }

    result = manager.run(Kward::Hooks::Event.new(name: "turn_end"))

    assert result.allowed?
    assert_equal ["Hook bad failed: boom"], result.warnings
  end

  def test_command_handler_uses_json_protocol
    Dir.mktmpdir do |dir|
      script = File.join(dir, "hook.rb")
      File.write(script, <<~'RUBY')
        require "json"
        event = JSON.parse($stdin.read)
        if event.fetch("payload").fetch("command").include?("gem push")
          puts JSON.dump(decision: "deny", message: "release blocked")
        else
          puts JSON.dump(decision: "allow")
        end
      RUBY

      handler = Kward::Hooks::CommandHandler.new(command: "ruby #{Shellwords.escape(script)}")
      event = Kward::Hooks::Event.new(name: "shell_command_before", payload: { command: "gem push kward.gem" })
      decision = handler.call(event)

      assert decision.deny?
      assert_equal "release blocked", decision.message
    end
  end

  def test_command_handler_failure_policy_can_deny_failures
    handler = Kward::Hooks::CommandHandler.new(command: "ruby -e 'exit 7'", failure_policy: "deny")
    decision = handler.call(Kward::Hooks::Event.new(name: "shell_command_before"))

    assert decision.deny?
    assert_match(/Command hook failed/, decision.message)
  end

  def test_audit_log_records_handler_and_result_without_payload_values
    Dir.mktmpdir do |dir|
      path = File.join(dir, "hooks.jsonl")
      audit_log = Kward::Hooks::AuditLog.new(path: path)
      manager = Kward::Hooks::Manager.new(audit_log: audit_log)
      manager.register("shell_command_before", id: "block-release") do
        Kward::Hooks::Decision.deny("blocked secret-token")
      end

      manager.run(Kward::Hooks::Event.new(
        name: "shell_command_before",
        payload: { command: "echo secret-token", api_key: "secret-token" }
      ))

      records = jsonl_records(path)
      assert_equal ["handler", "result"], records.map { |record| record["kind"] }
      assert_equal "block-release", records.first["hook_id"]
      assert_equal "deny", records.last["decision"]
      assert_includes records.last["payload_keys"], "command"
      refute_includes File.read(path), "echo secret-token"
    end
  end

  def test_http_handler_uses_json_protocol
    response = Net::HTTPOK.new("1.1", "200", "OK")
    response.instance_variable_set(:@read, true)
    response.body = JSON.dump(decision: "deny", message: "remote policy")
    requests = []
    client = Class.new do
      define_method(:initialize) { |requests, response| @requests = requests; @response = response }
      define_method(:start) do |_host, _port, **_options, &block|
        requests = @requests
        response = @response
        http = Object.new
        http.define_singleton_method(:request) do |request|
          requests << request
          response
        end
        block.call(http)
      end
    end.new(requests, response)

    handler = Kward::Hooks::HttpHandler.new(url: "http://example.test/hooks", http_client: client)
    decision = handler.call(Kward::Hooks::Event.new(name: "turn_end", payload: { answer: "ok" }))

    assert decision.deny?
    assert_equal "remote policy", decision.message
    assert_equal "application/json", requests.first["Content-Type"]
    assert_equal "turn_end", JSON.parse(requests.first.body).fetch("name")
  end

  def test_config_loader_registers_http_hooks
    response = Net::HTTPOK.new("1.1", "200", "OK")
    response.instance_variable_set(:@read, true)
    response.body = JSON.dump(decision: "deny", message: "remote")
    original_new = Kward::Hooks::HttpHandler.method(:new)
    Kward::Hooks::HttpHandler.define_singleton_method(:new) do |**_kwargs|
      Object.new.tap do |handler|
        handler.define_singleton_method(:call) { |_event, _context = nil| Kward::Hooks::Decision.deny("remote") }
      end
    end

    manager = Kward::Hooks::ConfigLoader.new({
      "hooks" => {
        "turn_end" => [{ "id" => "remote", "type" => "http", "url" => "http://example.test/hooks" }]
      }
    }).manager

    result = manager.run(Kward::Hooks::Event.new(name: "turn_end"))

    assert result.denied?
    assert_equal "remote", result.decision.message
  ensure
    Kward::Hooks::HttpHandler.define_singleton_method(:new, original_new) if original_new
  end

  def test_config_loader_async_hooks_schedule_without_blocking_or_denying
    queue = Queue.new
    original_new = Kward::Hooks::CommandHandler.method(:new)
    Kward::Hooks::CommandHandler.define_singleton_method(:new) do |**_kwargs|
      Object.new.tap do |handler|
        handler.define_singleton_method(:call) do |event, _context = nil|
          queue << event.name
          Kward::Hooks::Decision.deny("ignored")
        end
      end
    end

    manager = Kward::Hooks::ConfigLoader.new({
      "hooks" => {
        "turn_end" => [{ "id" => "notify", "command" => "notify", "async" => true }]
      }
    }).manager
    result = manager.run(Kward::Hooks::Event.new(name: "turn_end"))

    assert result.allowed?
    assert_equal "Async hook scheduled", result.decisions.first.message
    assert_equal "turn_end", queue.pop
  ensure
    Kward::Hooks::CommandHandler.define_singleton_method(:new, original_new) if original_new
  end

  def test_config_loader_registers_command_hooks
    Dir.mktmpdir do |dir|
      script = File.join(dir, "hook.rb")
      File.write(script, "require 'json'; puts JSON.dump(decision: 'deny', message: 'no')\n")
      manager = Kward::Hooks::ConfigLoader.new({
        "hooks" => {
          "tool_call_before" => [
            { "id" => "deny-all", "type" => "command", "command" => "ruby #{Shellwords.escape(script)}" }
          ]
        }
      }).manager

      result = manager.run(Kward::Hooks::Event.new(name: "tool_call_before"))

      assert result.denied?
      assert_equal "no", result.decision.message
    end
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
