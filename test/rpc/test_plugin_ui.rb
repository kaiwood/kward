require_relative "test_support"

class TestRPCPluginUI < KwardTestCase
  include KwardRPCTestSupport

  def test_synchronous_plugin_command_fails_closed_for_blocking_ui
    Dir.mktmpdir do |config_dir|
      registry = Kward::PluginRegistry.new
      registry.evaluate do |plugin|
        plugin.command("choose") do |_args, ctx|
          [ctx.ui.supported?(:select), ctx.ui.select("Action", ["Deploy"])].inspect
        end
      end
      manager = Kward::RPC::SessionManager.new(server: RecordingServer.new, client: RecordingClient.new([]), config_dir: config_dir)
      manager.instance_variable_set(:@plugin_registry, registry)
      session = manager.create_session(workspace_root: Dir.pwd)

      result = manager.run_plugin_command(session_id: session[:id], command: "choose")

      assert_equal "[false, nil]", result[:result]
    ensure
      manager&.shutdown_sessions
    end
  end

  def test_plugin_command_uses_structured_rpc_ui_and_emits_events
    Dir.mktmpdir do |config_dir|
      registry = Kward::PluginRegistry.new
      registry.evaluate do |plugin|
        plugin.command("choose") do |_args, ctx|
          ctx.ui.notify("Choose a deployment", :info)
          choice = ctx.ui.select("Deployment", [
            { label: "Deploy", value: "deploy", description: "Ship the release." },
            { label: "Cancel", value: "cancel", description: "Leave it alone." }
          ])
          ctx.ui.progress(id: "deploy", message: "Ready", percent: 100, done: true)
          choice
        end
      end
      server = RecordingServer.new
      manager = Kward::RPC::SessionManager.new(server: server, client: RecordingClient.new([]), config_dir: config_dir)
      manager.instance_variable_set(:@plugin_registry, registry)
      session = manager.create_session(workspace_root: Dir.pwd)

      turn = manager.start_turn(session_id: session[:id], input: "/choose")
      wait_until { server.notifications.any? { |notification| notification[:method] == "ui/request" } }
      request = server.notifications.find { |notification| notification[:method] == "ui/request" }
      manager.answer_plugin_ui(session_id: session[:id], request_id: request[:params][:requestId], value: "deploy")
      wait_until { manager.turn_status(turn_id: turn[:id])[:status] == "completed" }

      assert_equal "select", request[:params][:kind]
      assert_equal session[:id], request[:params][:sessionId]
      assert server.notifications.any? { |notification| notification[:method] == "ui/notification" && notification[:params][:message] == "Choose a deployment" }
      assert server.notifications.any? { |notification| notification[:method] == "ui/progress" && notification[:params][:percent] == 100 }
      answer = manager.turn_events(turn_id: turn[:id])[:events].find { |event| event[:type] == "answer" }
      assert_equal "deploy", answer[:payload][:content]
    ensure
      manager&.shutdown_sessions
    end
  end
end
