require_relative "test_support"

class TestRPCPluginActions < KwardTestCase
  include KwardRPCTestSupport

  def test_typed_command_accepts_object_arguments_and_returns_structured_result
    Dir.mktmpdir do |config_dir|
      registry = Kward::PluginRegistry.new
      received = nil
      registry.evaluate(id: "com.example.release", version: "1.0.0", api: "1") do |plugin|
        plugin.command "deploy", schema: {
          type: "object",
          properties: {
            environment: { type: "string", enum: %w[staging production] },
            dry_run: { type: "boolean", default: false }
          },
          required: ["environment"]
        } do |args, ctx|
          received = [args, ctx.args]
          ctx.say("Preparing")
          ctx.result(message: "Queued", data: { environment: args.fetch("environment") })
        end
      end
      manager = Kward::RPC::SessionManager.new(server: RecordingServer.new, client: RecordingClient.new([]), config_dir: config_dir)
      manager.instance_variable_set(:@plugin_registry, registry)
      session = manager.create_session(workspace_root: Dir.pwd)

      response = manager.run_plugin_command(
        session_id: session[:id],
        command: "deploy",
        arguments: { "environment" => "production", "dry_run" => true }
      )

      assert_equal received.first, received.last
      assert_equal ["Preparing"], response[:output]
      assert_equal({ message: "Queued", data: { "environment" => "production" } }, response[:result])
    ensure
      manager&.shutdown_sessions
    end
  end

  def test_typed_slash_turn_emits_structured_result_event
    Dir.mktmpdir do |config_dir|
      registry = Kward::PluginRegistry.new
      registry.evaluate do |plugin|
        plugin.command "deploy", schema: {
          type: "object",
          properties: { environment: { type: "string" } },
          required: ["environment"]
        } do |args, ctx|
          ctx.result(message: "Queued #{args.fetch('environment')}", data: { id: 7 })
        end
      end
      manager = Kward::RPC::SessionManager.new(server: RecordingServer.new, client: RecordingClient.new([]), config_dir: config_dir)
      manager.instance_variable_set(:@plugin_registry, registry)
      session = manager.create_session(workspace_root: Dir.pwd)

      turn = manager.start_turn(session_id: session[:id], input: "/deploy --environment staging")
      wait_until { manager.turn_status(turn_id: turn[:id])[:status] == "completed" }
      events = manager.turn_events(turn_id: turn[:id])[:events]
      result_event = events.find { |event| event[:type] == "pluginCommandResult" }
      answer = events.find { |event| event[:type] == "answer" }

      assert_equal "deploy", result_event[:payload][:command]
      assert_equal({ message: "Queued staging", data: { "id" => 7 } }, result_event[:payload][:result])
      assert_equal "Queued staging", answer[:payload][:content]
    ensure
      manager&.shutdown_sessions
    end
  end

  def test_rpc_lists_and_runs_namespaced_plugin_actions
    Dir.mktmpdir do |config_dir|
      server = Kward::RPC::Server.new(
        input: StringIO.new,
        output: StringIO.new,
        error_output: StringIO.new,
        client: RecordingClient.new([])
      )
      registry = server.session_manager.plugin_registry
      status_schema = {
        type: "object",
        properties: { deployment_id: { type: "integer" } },
        required: ["deployment_id"]
      }
      registry.evaluate(id: "com.example.release", version: "1.0.0", api: "1") do |plugin|
        plugin.command("deployment-status", description: "Read deployment status", schema: status_schema) { nil }
        plugin.action "status", description: "Read deployment status", schema: status_schema do |args, ctx|
          ctx.say("Looking up deployment")
          ctx.result(data: { id: args.fetch("deployment_id"), state: "ready" })
        end
      end
      session = server.session_manager.create_session(workspace_root: config_dir)

      listing = server.send(:dispatch, "pluginActions/list", { sessionId: session[:id] })
      commands = server.send(:dispatch, "commands/list", { sessionId: session[:id] })
      response = server.send(
        :dispatch,
        "pluginActions/run",
        { sessionId: session[:id], id: "com.example.release/status", arguments: { deployment_id: 42 } }
      )
      capabilities = server.send(:capabilities)

      assert_equal [{
        id: "com.example.release/status",
        name: "status",
        pluginId: "com.example.release",
        description: "Read deployment status",
        schema: registry.action_for("com.example.release/status").schema
      }], listing[:actions]
      typed_command = commands[:commands].find { |command| command[:name] == "deployment-status" }
      assert_equal true, typed_command[:typed]
      assert_equal "com.example.release", typed_command[:pluginId]
      assert_equal status_schema[:required], typed_command.dig(:schema, :required)
      assert_equal [], typed_command[:positionals]
      assert_equal ["Looking up deployment"], response[:output]
      assert_equal({ data: { "id" => 42, "state" => "ready" } }, response[:result])
      assert_equal Kward::RPC::Server::PLUGIN_ACTION_METHODS, capabilities[:pluginActions][:methods]
      assert_equal 1, capabilities[:pluginActions][:registered]
    ensure
      server&.shutdown
    end
  end

  def test_plugin_actions_obey_session_execution_profile
    manager = Kward::RPC::SessionManager.new(server: RecordingServer.new, client: RecordingClient.new([]))
    manager.plugin_registry.evaluate(id: "com.example.release", version: "1.0.0", api: "1") do |plugin|
      plugin.command("deploy") { "unexpected" }
      plugin.action("deploy", description: "Deploy") { "unexpected" }
    end
    profile = Kward::Transport.execution_profile(id: "restricted", plugin_commands: false)
    session = manager.create_session(workspace_root: Dir.pwd, execution_profile: profile)

    error = assert_raises(ArgumentError) do
      manager.run_plugin_action(session_id: session[:id], id: "com.example.release/deploy")
    end

    assert_includes error.message, "disabled"
    command_error = assert_raises(ArgumentError) do
      manager.run_plugin_command(session_id: session[:id], command: "deploy")
    end
    assert_includes command_error.message, "disabled"
  ensure
    manager&.shutdown_sessions
  end
end
