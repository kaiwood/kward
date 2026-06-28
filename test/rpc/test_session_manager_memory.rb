require_relative "test_support"

class TestRPCSessionManagerMemory < KwardTestCase
  include KwardRPCTestSupport

  def test_memory_status_includes_auto_summary_and_toggles_setting
    Dir.mktmpdir do |config_dir|
      manager = Kward::RPC::SessionManager.new(server: RecordingServer.new, client: FakeClient.new([]), config_dir: config_dir)

      refute manager.memory_status[:autoSummary]

      manager.memory_auto_summary_enable
      assert_equal true, manager.memory_status[:autoSummary]

      manager.memory_auto_summary_disable
      assert_equal false, manager.memory_status[:autoSummary]
    end
  end

  def test_memory_summarize_only_uses_user_messages_for_inference
    Dir.mktmpdir do |config_dir|
      manager = Kward::RPC::SessionManager.new(server: RecordingServer.new, client: FakeClient.new([]), config_dir: config_dir)
      session = manager.create_session(workspace_root: Dir.pwd)
      rpc_session = manager.send(:fetch_session, session[:id])

      rpc_session.conversation.append_user("I usually prefer concise and practical answers.")
      rpc_session.conversation.append_assistant("I always use assistant-generated summaries.")
      rpc_session.conversation.append_tool(tool_call_id: "skill_1", name: "read_skill", content: "Prefer focused tests and always use minitest.")

      result = manager.memory_summarize(session_id: session[:id])

      memories = result[:memories]
      assert_equal 1, memories.length
      # Memory summarization canonicalizes first-person user preferences.
      assert_equal ["The user usually prefers concise and practical answers"], memories.map { |memory| memory["text"] }
      assert_equal ["soft_001"], memories.map { |memory| memory["id"] }
      refute_includes memories.map { |memory| memory["text"] }, "Prefer focused tests and always use minitest"
      refute_includes memories.map { |memory| memory["text"] }, "I always use assistant-generated summaries"
    end
  end

end
