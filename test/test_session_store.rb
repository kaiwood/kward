require_relative "test_helper"

class TestSessionStore < KwardTestCase
  def test_session_store_restores_read_paths_and_skips_bad_jsonl
    Dir.mktmpdir do |config_dir|
      Dir.mktmpdir do |workspace_dir|
        path = File.join(workspace_dir, "file.txt")
        File.write(path, "old\n")
        store = Kward::SessionStore.new(config_dir: config_dir, cwd: workspace_dir)
        session = store.create
        conversation = Kward::Conversation.new
        session.attach(conversation)
        conversation.append_assistant(assistant_tool_call("read_file", path: "file.txt"))
        conversation.append_tool(tool_call_id: "call_read_file", name: "read_file", content: "old\n")
        File.open(session.path, "a") { |file| file.puts("not json") }

        workspace = Kward::Workspace.new(root: workspace_dir)
        _loaded_session, loaded_conversation = store.load(session.path, workspace: workspace)

        assert_includes loaded_conversation.read_paths, workspace.resolved_path("file.txt")
      end
    end
  end

end
