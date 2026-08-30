require_relative "test_support"

class TestRPCTranscriptNormalizer < KwardTestCase
  include KwardRPCTestSupport

  def test_session_transcript_normalizes_text_and_image_messages
    Dir.mktmpdir do |config_dir|
      manager = Kward::RPC::SessionManager.new(server: RecordingServer.new, client: FakeClient.new([]), config_dir: config_dir)
      session = manager.create_session(workspace_root: Dir.pwd)
      rpc_session = manager.send(:fetch_session, session[:id])
      png_data = "iVBORw0KGgo="

      rpc_session.conversation.append_user("hello")
      rpc_session.conversation.append_user("see data:image/png;base64,#{png_data}")

      transcript = manager.transcript(session_id: session[:id])
      messages = transcript[:messages]

      assert_equal session[:id], transcript[:session][:id]
      assert_equal session[:persistentId], transcript[:session][:persistentId]
      assert_equal Dir.pwd, transcript[:session][:cwd]
      assert transcript[:session][:modifiedAt]
      assert_equal ["user", "user"], messages.map { |message| message[:role] }
      assert_equal [{ type: "text", text: "hello" }], messages[0][:content]
      image = messages[1][:content].find { |part| part[:type] == "image" }
      assert_equal png_data, image[:data]
      assert_equal "image/png", image[:mimeType]
      refute image.key?(:media_type)
    end
  end

  def test_preserves_a_persisted_message_timestamp
    messages = Kward::RPC::TranscriptNormalizer.new([
      { role: "user", content: "hello", timestamp: "2026-07-13T12:36:44.785Z" },
      { role: "assistant", content: "hello", timestamp: "2026-07-13T12:36:45.123Z" }
    ]).normalize

    assert_equal "2026-07-13T12:36:44.785Z", messages[0][:timestamp]
    assert_equal "2026-07-13T12:36:45.123Z", messages[1][:timestamp]
  end

  def test_session_transcript_restores_reasoning_summary_as_thinking_block
    Dir.mktmpdir do |config_dir|
      manager = Kward::RPC::SessionManager.new(server: RecordingServer.new, client: FakeClient.new([]), config_dir: config_dir)
      session = manager.create_session(workspace_root: Dir.pwd)
      rpc_session = manager.send(:fetch_session, session[:id])

      rpc_session.conversation.append_assistant({
        "role" => "assistant",
        "content" => "Here is the answer.",
        "reasoning_summary" => "Checked the relevant files."
      })

      message = manager.transcript(session_id: session[:id])[:messages].first

      assert_equal "assistant", message[:role]
      assert_equal [
        { type: "thinking", thinking: "Checked the relevant files." },
        { type: "text", text: "Here is the answer." }
      ], message[:content]
    end
  end

  def test_assistant_existing_thinking_and_reasoning_content_normalizes_before_text
    messages = Kward::RPC::TranscriptNormalizer.new([
      {
        role: "assistant",
        reasoning_summary: "ignored because content already has thinking",
        content: [
          { type: "text", text: "final text" },
          { type: "thinking", thinking: "first thought" },
          { type: "reasoning", text: "second thought" }
        ]
      }
    ]).normalize

    assert_equal [
      { type: "thinking", thinking: "first thought" },
      { type: "thinking", thinking: "second thought" },
      { type: "text", text: "final text" }
    ], messages.first[:content]
  end

  def test_assistant_response_items_restore_thinking_text_and_tool_calls
    messages = Kward::RPC::TranscriptNormalizer.new([
      {
        "role" => "assistant",
        "content" => "",
        "tool_calls" => [tool_call("read_file", path: "README.md")],
        "response_items" => [
          { "type" => "reasoning", "summary" => [{ "type" => "summary_text", "text" => "Checked context." }] },
          { "type" => "message", "phase" => "commentary", "content" => [{ "type" => "output_text", "text" => "Need inspect file first." }] },
          { "type" => "message", "phase" => "final_answer", "content" => [{ "type" => "output_text", "text" => "Done." }] }
        ]
      }
    ]).normalize

    assert_equal [
      { type: "thinking", thinking: "Checked context." },
      { type: "thinking", thinking: "Need inspect file first." },
      { type: "text", text: "Done." },
      { type: "toolCall", id: "call_read_file", name: "read", arguments: { path: "README.md" } }
    ], messages.first[:content]
  end

  def test_assistant_response_item_preserves_separate_reasoning_summary_parts
    messages = Kward::RPC::TranscriptNormalizer.new([
      {
        "role" => "assistant",
        "content" => "",
        "response_items" => [
          {
            "type" => "reasoning",
            "summary" => [
              { "type" => "summary_text", "text" => "Checked context." },
              { "type" => "summary_text", "text" => "Planned the edit." }
            ]
          }
        ]
      }
    ]).normalize

    assert_equal [
      { type: "thinking", thinking: "Checked context." },
      { type: "thinking", thinking: "Planned the edit." }
    ], messages.first[:content]
  end

  def test_session_transcript_normalizes_tool_calls_and_results
    Dir.mktmpdir do |config_dir|
      manager = Kward::RPC::SessionManager.new(server: RecordingServer.new, client: FakeClient.new([]), config_dir: config_dir)
      session = manager.create_session(workspace_root: Dir.pwd)
      rpc_session = manager.send(:fetch_session, session[:id])
      edit_args = { path: "src/file.ts", edits: [{ old_text: "old", new_text: "new" }] }

      rpc_session.conversation.append_assistant(assistant_tool_call("edit_file", edit_args))
      rpc_session.conversation.append_tool(
        tool_call_id: "call_edit_file",
        name: "edit_file",
        content: "Edited src/file.ts: replaced 1 block(s)\n--- a/src/file.ts\n+++ b/src/file.ts\n@@ -1 +1 @@\n-old\n+new\n"
      )
      rpc_session.conversation.append_tool(
        tool_call_id: "call_missing",
        name: "write_file",
        content: "Error: existing file must be read before writing: src/file.ts"
      )

      messages = manager.transcript(session_id: session[:id])[:messages]

      refute_includes messages.map { |message| message[:role] }, "tool"
      tool_call = messages[0][:content].find { |part| part[:type] == "toolCall" }
      assert_equal "call_edit_file", tool_call[:id]
      assert_equal "edit", tool_call[:name]
      assert_equal "src/file.ts", tool_call[:arguments][:path]
      assert_equal [{ oldText: "old", newText: "new" }], tool_call[:arguments][:edits]

      result = messages[1]
      assert_equal "toolResult", result[:role]
      assert_equal "call_edit_file", result[:toolCallId]
      assert_equal "edit", result[:toolName]
      assert_equal false, result[:isError]
      assert_includes result[:content], { type: "text", text: "Edited src/file.ts: replaced 1 block(s)\n--- a/src/file.ts\n+++ b/src/file.ts\n@@ -1 +1 @@\n-old\n+new\n" }
      assert_equal ["src/file.ts"], result[:details][:changedFiles]
      assert_includes result[:details][:diff], "--- a/src/file.ts"

      error_result = messages[2]
      assert_equal "toolResult", error_result[:role]
      assert_equal "write", error_result[:toolName]
      assert_equal true, error_result[:isError]
    end
  end
end
