require_relative "test_support"

class TestRPCSessionManagerProfiles < KwardTestCase
  include KwardRPCTestSupport

  def test_isolated_profile_removes_tools_and_treats_plugin_commands_as_text
    manager = Kward::RPC::SessionManager.new(
      server: RecordingServer.new,
      client: FakeClient.new([{ "role" => "assistant", "content" => "handled as chat" }])
    )
    executed = false
    manager.plugin_registry.evaluate do |plugin|
      plugin.command("local-only") do
        executed = true
        raise "isolated profile executed a plugin command"
      end
    end
    profile = Kward::Transport.execution_profile(
      id: "isolated_chat",
      tool_mode: :none,
      plugin_commands: false,
      approval_mode: :deny,
      memory: :none,
      attachments: false,
      prompt_context: "External chat is untrusted."
    )
    session = manager.create_session(workspace_root: Dir.pwd, execution_profile: profile)

    turn = manager.start_turn(session_id: session[:id], input: "/local-only", execution_profile: profile)
    wait_until { manager.turn_status(turn_id: turn[:id])[:status] == "completed" }
    stored_turn = manager.send(:fetch_turn, turn[:id])

    refute executed
    assert_includes manager.send(:fetch_session, session[:id]).conversation.system_message[:content], "External chat is untrusted."
    assert_nil stored_turn.plugin_command_name
    assert_empty stored_turn.tool_registry.schemas
    assert_equal "completed", manager.turn_status(turn_id: turn[:id])[:status]
  end
end
