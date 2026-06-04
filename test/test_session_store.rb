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

  def test_session_store_persists_and_loads_compacted_history
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      session = store.create
      conversation = Kward::Conversation.new
      session.attach(conversation)
      conversation.append_user("hello")
      conversation.append_assistant("reply")
      conversation.compact!("summary")
      conversation.append_user("again")

      records = jsonl_records(session.path)
      assert records.any? { |record| record["type"] == "compaction" && record["message"]["content"] == "summary" }

      _loaded_session, loaded_conversation = store.load(session.path)

      assert_equal ["summary", "again"], loaded_conversation.messages.reject { |message| (message["role"] || message[:role]) == "system" }.map { |message| message["content"] || message[:content] }
    end
  end

  def test_session_store_restores_latest_prompt_after_repeated_compaction
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      session = store.create
      conversation = Kward::Conversation.new(system_message: nil)
      session.attach(conversation)
      client = RecordingClient.new(["first summary", "second summary", "third summary", "fourth summary"])
      settings = Kward::Compaction::Settings.new(keep_recent_tokens: 10)

      conversation.append_user("old first prompt " * 20)
      conversation.append_assistant("old first answer " * 20)
      conversation.append_user("kept first prompt")
      conversation.append_assistant("ok")
      Kward::Compactor.new(conversation: conversation, client: client, settings: settings).compact

      conversation.append_user("old second prompt " * 20)
      conversation.append_assistant("old second answer " * 20)
      conversation.append_user("latest prompt")
      conversation.append_assistant("latest answer")
      Kward::Compactor.new(conversation: conversation, client: client, settings: settings).compact

      live_messages = conversation.messages.reject { |message| (message["role"] || message[:role]) == "system" }
      _loaded_session, loaded_conversation = store.load(session.path)
      loaded_messages = loaded_conversation.messages.reject { |message| (message["role"] || message[:role]) == "system" }

      assert_equal live_messages.map { |message| message["role"] || message[:role] }, loaded_messages.map { |message| message["role"] || message[:role] }
      assert_equal live_messages.map { |message| message["summary"] || message[:summary] || message["content"] || message[:content] }, loaded_messages.map { |message| message["summary"] || message[:summary] || message["content"] || message[:content] }
      assert_includes loaded_messages.map { |message| message["content"] || message[:content] }, "latest prompt"
    end
  end

  def test_cloned_compacted_session_restores_tool_result_pair_for_codex
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      conversation = Kward::Conversation.new(system_message: nil)
      conversation.append_user("inspect README")
      conversation.append_assistant(assistant_tool_call("read_file", path: "README.md"))
      conversation.messages << { "role" => "toolResult", "toolCallId" => "call_read_file", "toolName" => "read_file", "content" => "README contents" }
      kept = conversation.messages[1..]
      conversation.compact!("summary", compaction_summary: true, first_kept_entry_id: "message:1", keep_messages: kept)

      clone_session, _clone_conversation = store.create_independent_from_conversation(conversation)
      _loaded_session, loaded_conversation = store.load(clone_session.path)
      client = Kward::Client.new(api_key: nil, openai_access_token: "token", oauth: FakeOAuth.new(nil), config_path: "missing_kward_config.json")
      input = client.send(:codex_payload, loaded_conversation.messages, [])[:input]
      calls = input.select { |item| item[:type] == "function_call" }.map { |item| item[:call_id] }
      outputs = input.select { |item| item[:type] == "function_call_output" }.map { |item| item[:call_id] }

      assert_equal ["call_read_file"], calls
      assert_equal ["call_read_file"], outputs
      assert_empty calls - outputs
    end
  end

end
