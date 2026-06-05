require_relative "test_support"

class TestRPCSessionManagerRuntime < KwardTestCase
  include KwardRPCTestSupport

  def test_current_model_does_not_give_fake_model_a_production_context_window
    client = FakeClient.new([])
    client.context_window = nil
    manager = Kward::RPC::SessionManager.new(server: RecordingServer.new, client: client)

    model = manager.current_model

    assert_equal "fake-model", model[:id]
    refute model.key?(:contextWindow)
  end

  def test_runtime_state_returns_session_and_model_info
    Dir.mktmpdir do |config_dir|
      manager = Kward::RPC::SessionManager.new(server: RecordingServer.new, client: FakeClient.new([]), config_dir: config_dir)
      session = manager.create_session(workspace_root: Dir.pwd, name: "Work")
      rpc_session = manager.send(:fetch_session, session[:id])
      rpc_session.conversation.append_user("hello")

      state = manager.runtime_state(session_id: session[:id])

      assert_equal session[:path], state[:sessionFile]
      assert_equal session[:persistentId], state[:sessionId]
      assert_equal session[:id], state[:rpcSessionId]
      assert_equal session[:persistentId], state[:persistentSessionId]
      assert_equal "Work", state[:sessionName]
      assert_equal "kward-rpc", state[:transport]
      assert_equal false, state[:isStreaming]
      assert_equal 1, state[:messageCount]
      assert_equal 0, state[:pendingMessageCount]
      assert_equal "Codex", state[:model][:provider]
      assert_equal "fake-model", state[:model][:id]
      assert_equal "fake-model", state[:model][:name]
      assert_equal true, state[:model][:reasoning]
      assert_equal "medium", state[:thinkingLevel]
      assert_equal "Codex/fake-model", state[:defaultModel]
    end
  end

  def test_runtime_stats_counts_messages_and_tool_activity
    Dir.mktmpdir do |config_dir|
      context_usage = StaticContextUsage.new(tokens: 50)
      manager = Kward::RPC::SessionManager.new(server: RecordingServer.new, client: FakeClient.new([]), config_dir: config_dir, context_usage: context_usage)
      session = manager.create_session(workspace_root: Dir.pwd, name: "Stats")
      rpc_session = manager.send(:fetch_session, session[:id])

      rpc_session.conversation.append_user("hello")
      rpc_session.conversation.append_assistant(assistant_tool_call("read_file", { path: "README.md" }))
      rpc_session.conversation.append_tool(tool_call_id: "call_read_file", name: "read_file", content: "contents")
      rpc_session.conversation.append_assistant("done")

      stats = manager.runtime_stats(session_id: session[:id])

      assert_equal session[:path], stats[:sessionFile]
      assert_equal session[:persistentId], stats[:sessionId]
      assert_equal session[:id], stats[:rpcSessionId]
      assert_equal session[:persistentId], stats[:persistentSessionId]
      assert_equal "Stats", stats[:sessionName]
      assert_equal 1, stats[:userMessages]
      assert_equal 2, stats[:assistantMessages]
      assert_equal 1, stats[:toolCalls]
      assert_equal 1, stats[:toolResults]
      assert_equal 4, stats[:totalMessages]
      assert_equal true, stats[:usingSubscription]
      assert_equal true, stats[:autoCompactionEnabled]
      assert_equal({ tokens: 50, contextWindow: 200_000, percent: 0.03 }, stats[:contextUsage])
      refute stats.key?(:tokens)
    end
  end
end
