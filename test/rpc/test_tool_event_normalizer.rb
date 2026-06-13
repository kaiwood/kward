require_relative "test_support"

class TestRPCToolEventNormalizer < KwardTestCase
  include KwardRPCTestSupport

  def test_tool_events_include_normalized_edit_metadata_and_diff_result
    Dir.mktmpdir do |config_dir|
      workspace_root = Dir.mktmpdir
      path = File.join(workspace_root, "test.txt")
      File.write(path, "old one\nold two\n")
      edit_file_args = {
        path: "test.txt",
        edits: [
          { old_text: "old one", new_text: "new one" },
          { old_text: "old two", new_text: "new two" }
        ]
      }
      responses = [
        assistant_tool_call("read_file", { path: "test.txt" }),
        assistant_tool_call("edit_file", edit_file_args),
        { "role" => "assistant", "content" => "done" }
      ]
      manager = Kward::RPC::SessionManager.new(server: RecordingServer.new, client: FakeClient.new(responses), config_dir: config_dir)
      session = manager.create_session(workspace_root: workspace_root)
      turn = manager.start_turn(session_id: session[:id], input: "edit")

      wait_until { manager.turn_status(turn_id: turn[:id])[:status] == "completed" }

      tool_events = manager.turn_events(turn_id: turn[:id])[:events].select { |event| ["toolCall", "toolResult"].include?(event[:type]) && event[:payload][:toolName] == "edit" }
      assert_equal 2, tool_events.length
      tool_events.each do |tool_event|
        assert_equal "call_edit_file", tool_event[:payload][:toolCallId]
        assert_equal "edit", tool_event[:payload][:toolName]
        assert_equal "test.txt", tool_event[:payload][:args][:path]
        assert_equal [
          { oldText: "old one", newText: "new one" },
          { oldText: "old two", newText: "new two" }
        ], tool_event[:payload][:args][:edits]
        refute tool_event[:payload].key?(:tool)
        refute tool_event[:payload].key?(:toolCall)
        refute tool_event[:payload].key?(:rawToolCall)
      end
      result = tool_events.find { |event| event[:type] == "toolResult" }[:payload][:result]
      assert_equal false, result[:isError]
      assert_equal ["test.txt"], result[:changedFiles]
      assert_includes result[:diff], "--- test.txt"
    ensure
      FileUtils.remove_entry(workspace_root) if workspace_root && File.exist?(workspace_root)
    end
  end

  def test_write_and_shell_tool_events_include_normalized_args
    Dir.mktmpdir do |config_dir|
      workspace_root = Dir.mktmpdir
      responses = [
        assistant_tool_call("write_file", { path: "new.txt", content: "hello" }),
        assistant_tool_call("run_shell_command", { command: "echo hi", timeout_seconds: 7 }),
        { "role" => "assistant", "content" => "done" }
      ]
      manager = Kward::RPC::SessionManager.new(server: RecordingServer.new, client: FakeClient.new(responses), config_dir: config_dir)
      session = manager.create_session(workspace_root: workspace_root)
      turn = manager.start_turn(session_id: session[:id], input: "write and shell")

      wait_until { manager.turn_status(turn_id: turn[:id])[:status] == "completed" }

      events = manager.turn_events(turn_id: turn[:id])[:events]
      write_call = events.find { |event| event[:type] == "toolCall" && event[:payload][:toolName] == "write" }
      write_result = events.find { |event| event[:type] == "toolResult" && event[:payload][:toolName] == "write" }
      shell_call = events.find { |event| event[:type] == "toolCall" && event[:payload][:toolName] == "bash" }
      shell_result = events.find { |event| event[:type] == "toolResult" && event[:payload][:toolName] == "bash" }

      assert_equal({ path: "new.txt", content: "hello" }, write_call[:payload][:args])
      assert_equal false, write_result[:payload][:result][:isError]
      assert_equal ["new.txt"], write_result[:payload][:result][:changedFiles]
      assert_equal({ command: "echo hi", timeout: 7 }, shell_call[:payload][:args])
      assert_equal({ command: "echo hi", timeout: 7 }, shell_result[:payload][:args])
      assert_equal false, shell_result[:payload][:result][:isError]
    ensure
      FileUtils.remove_entry(workspace_root) if workspace_root && File.exist?(workspace_root)
    end
  end

  def test_failed_tool_result_and_failed_turn_events_are_normalized
    Dir.mktmpdir do |config_dir|
      workspace_root = Dir.mktmpdir
      manager = Kward::RPC::SessionManager.new(
        server: RecordingServer.new,
        client: FakeClient.new([assistant_tool_call("edit_file", { path: "missing.txt", edits: [{ old_text: "old", new_text: "new" }] }), { "role" => "assistant", "content" => "done" }]),
        config_dir: config_dir
      )
      session = manager.create_session(workspace_root: workspace_root)
      turn = manager.start_turn(session_id: session[:id], input: "bad edit")

      wait_until { manager.turn_status(turn_id: turn[:id])[:status] == "completed" }

      tool_result = manager.turn_events(turn_id: turn[:id])[:events].find { |event| event[:type] == "toolResult" }
      assert_equal "edit", tool_result[:payload][:toolName]
      assert_equal true, tool_result[:payload][:result][:isError]
      refute tool_result[:payload][:result].key?(:changedFiles)

      failing_manager = Kward::RPC::SessionManager.new(server: RecordingServer.new, client: ErrorClient.new, config_dir: config_dir)
      failing_session = failing_manager.create_session(workspace_root: workspace_root)
      failing_turn = failing_manager.start_turn(session_id: failing_session[:id], input: "explode")

      wait_until { failing_manager.turn_status(turn_id: failing_turn[:id])[:status] == "failed" }

      events = failing_manager.turn_events(turn_id: failing_turn[:id])[:events]
      error_event = events.find { |event| event[:type] == "error" }
      finished_event = events.find { |event| event[:type] == "turnFinished" }
      assert_equal "boom", error_event[:payload][:message]
      assert_equal "RuntimeError", error_event[:payload][:code]
      assert_equal false, error_event[:payload][:fatal]
      assert_equal "failed", finished_event[:payload][:status]
      assert_equal error_event[:payload], finished_event[:payload][:error]
    ensure
      FileUtils.remove_entry(workspace_root) if workspace_root && File.exist?(workspace_root)
    end
  end
end
