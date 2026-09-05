require_relative "test_support"

class TestRPCPluginTurns < KwardTestCase
  include KwardRPCTestSupport

  def with_plugin_manager(handler: ->(text, ctx) { ctx.request_turn(system: text) })
    Dir.mktmpdir do |config_dir|
      registry = Kward::PluginRegistry.new
      registry.evaluate(id: "test.iddqd", version: "1.0.0", api: 1) do |plugin|
        plugin.command("iddqd", &handler)
      end
      client = RecordingClient.new(["Tauren", "Next answer"])
      manager = Kward::RPC::SessionManager.new(server: RecordingServer.new, client: client, config_dir: config_dir)
      manager.instance_variable_set(:@plugin_registry, registry)
      session = manager.create_session(workspace_root: Dir.pwd)
      yield manager, session, client
    ensure
      manager&.shutdown_sessions
    end
  end

  def test_async_command_runs_model_and_persists_scoped_history
    with_plugin_manager do |manager, session, client|
      turn = manager.start_turn(session_id: session[:id], input: "/iddqd Speak as a starship.")
      wait_until { %w[completed failed].include?(manager.turn_status(turn_id: turn[:id])[:status]) }
      assert_equal "completed", manager.turn_status(turn_id: turn[:id])[:status]
      messages = client.seen_messages.first
      assert messages.any? { |message| message[:role] == "system" && message[:content] == "Speak as a starship." }
      refute messages.any? { |message| message[:role] == "user" }
      answers = manager.turn_events(turn_id: turn[:id])[:events].select { |event| event[:type] == "answer" }
      assert_equal ["Tauren"], answers.map { |event| event[:payload][:content] }
      runtime = manager.send(:fetch_session, session[:id])
      records = File.readlines(runtime.session.path).map { |line| JSON.parse(line) }
      record = records.find { |entry| entry.dig("message", "plugin_system_turn") }
      assert_equal "test.iddqd", record.dig("message", "plugin_system_turn", "plugin_id")
      assert_equal "Speak as a starship.", record.dig("message", "plugin_system_turn", "system")
      refute_includes JSON.generate(runtime.conversation.context_messages), "Speak as a starship."
    end
  end

  def test_synchronous_command_rejects_model_requests_without_calling_model
    with_plugin_manager do |manager, session, client|
      error = assert_raises(ArgumentError) { manager.run_plugin_command(session_id: session[:id], command: "iddqd", arguments: "Hello") }
      assert_includes error.message, "turns/start"
      assert_empty client.seen_messages
    end
  end

  def test_handler_failure_discards_staged_turn
    handler = lambda do |text, ctx|
      ctx.request_turn(system: text)
      raise "Command failed"
    end
    with_plugin_manager(handler: handler) do |manager, session, client|
      turn = manager.start_turn(session_id: session[:id], input: "/iddqd Hello")
      wait_until { manager.turn_status(turn_id: turn[:id])[:status] == "failed" }
      assert_empty client.seen_messages
      assert_empty manager.send(:fetch_session, session[:id]).conversation.messages
    end
  end

  def test_cancellation_after_staging_discards_request
    handler = lambda do |text, ctx|
      ctx.request_turn(system: text)
      ctx.cancellation.cancel!
    end
    with_plugin_manager(handler: handler) do |manager, session, client|
      turn = manager.start_turn(session_id: session[:id], input: "/iddqd Hello")
      wait_until { manager.turn_status(turn_id: turn[:id])[:status] == "canceled" }
      assert_empty client.seen_messages
      assert_empty manager.send(:fetch_session, session[:id]).conversation.messages
    end
  end

  def test_system_turn_honors_execution_profile_tool_filtering
    with_plugin_manager do |manager, session, client|
      profile = Kward::Transport.execution_profile(id: "no_tools", tool_mode: :none, plugin_commands: true, approval_mode: :deny, memory: :none, attachments: false)
      turn = manager.start_turn(session_id: session[:id], input: "/iddqd Answer without tools", execution_profile: profile)
      wait_until { %w[completed failed].include?(manager.turn_status(turn_id: turn[:id])[:status]) }
      assert_equal "completed", manager.turn_status(turn_id: turn[:id])[:status]
      assert_empty client.requests.first[:tools]
      assert client.seen_messages.first.any? { |message| message[:role] == "system" && message[:content] == "Answer without tools" }
    end
  end

  def test_initialize_reports_asynchronous_system_turn_contract
    result = run_rpc([{ jsonrpc: "2.0", id: 1, method: "initialize" }]).first
    capability = result.dig("result", "capabilities", "commands", "modelTurns")
    assert_equal true, capability["supported"]
    assert_equal "turns/start", capability["method"]
    assert_equal false, capability["synchronous"]
    assert_equal "turn", capability["scope"]
    assert_equal 65_536, capability["maxSystemBytes"]
    assert_equal false, capability["pan"]
  end

end
