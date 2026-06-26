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

  def test_session_store_persists_system_prompt_snapshots_only_when_changed
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      session = store.create
      conversation = Kward::Conversation.new(system_message: { role: "system", content: "system v1" })

      session.attach(conversation)
      session.attach(conversation)
      conversation.memory_context = "system v2"
      conversation.refresh_system_message!

      snapshots = jsonl_records(session.path).select { |record| record["type"] == "system_prompt" }
      assert_equal 2, snapshots.length
      assert_equal "system v1", snapshots[0]["content"]
      assert_includes snapshots[1]["content"], "system v2"
      assert snapshots.all? { |record| record["hash"].start_with?("sha256:") }
      assert_equal ["attach", "changed"], snapshots.map { |record| record["reason"] }
      assert_empty jsonl_records(session.path).select { |record| record["type"] == "message" && record.dig("message", "role") == "system" }
    end
  end

  def test_session_store_skips_missing_restored_read_paths
    Dir.mktmpdir do |config_dir|
      Dir.mktmpdir do |workspace_dir|
        path = File.join(workspace_dir, "missing.txt")
        File.write(path, "old\n")
        store = Kward::SessionStore.new(config_dir: config_dir, cwd: workspace_dir)
        session = store.create
        conversation = Kward::Conversation.new
        session.attach(conversation)
        conversation.append_assistant(assistant_tool_call("read_file", path: "missing.txt"))
        conversation.append_tool(tool_call_id: "call_read_file", name: "read_file", content: "old\n")
        File.delete(path)

        _loaded_session, loaded_conversation = store.load(session.path, workspace: Kward::Workspace.new(root: workspace_dir))

        assert_empty loaded_conversation.read_paths
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

  def test_load_recovers_header_missing_from_jsonl_session
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      session = store.create
      conversation = Kward::Conversation.new(system_message: nil)
      session.attach(conversation)
      conversation.append_user("saved prompt")
      records = jsonl_records(session.path).reject { |record| record["type"] == "session" }
      File.write(session.path, records.map { |record| JSON.generate(record) }.join("\n") + "\n")

      loaded_session, loaded_conversation = store.load(session.path)
      info = store.send(:session_info, session.path)

      assert_equal session.id, loaded_session.id
      assert_equal session.id, info.id
      assert_equal ["saved prompt"], loaded_conversation.messages.map { |message| message["content"] || message[:content] }
    end
  end

  def test_recent_deletes_empty_unnamed_sessions
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      empty = store.create
      saved = store.create
      conversation = Kward::Conversation.new(system_message: nil)
      saved.attach(conversation)
      conversation.append_user("saved prompt")

      recent = store.recent(limit: 10)

      assert_equal [saved.id], recent.map(&:id)
      refute_path_exists empty.path
    end
  end

  def test_recent_without_limit_returns_all_sessions
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      sessions = 25.times.map do |index|
        session = store.create
        conversation = Kward::Conversation.new(system_message: nil)
        session.attach(conversation)
        conversation.append_user("saved prompt #{index}")
        session
      end

      recent = store.recent(limit: nil)

      assert_equal sessions.length, recent.length
      assert_equal sessions.map(&:id).sort, recent.map(&:id).sort
    end
  end

  def test_cloned_session_persists_parent_metadata_and_tree_shape
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      source = store.create
      conversation = Kward::Conversation.new(system_message: nil)
      source.attach(conversation)
      conversation.append_user("source prompt")

      clone, _clone_conversation = store.create_independent_from_conversation(conversation, parent_session: source)
      _loaded_clone, loaded_conversation = store.load(clone.path)
      tree = store.recent_tree(limit: 10)
      source_info = tree.find { |info| info.id == source.id }
      clone_info = tree.find { |info| info.id == clone.id }

      loaded_user_messages = loaded_conversation.messages.reject { |message| (message["role"] || message[:role]) == "system" }
      assert_equal ["source prompt"], loaded_user_messages.map { |message| message["content"] || message[:content] }
      assert_equal source.id, clone.parent_id
      assert_equal source.path, clone.parent_path
      assert_equal source.id, clone_info.parent_id
      assert_equal 0, source_info.depth
      assert_equal 1, clone_info.depth
      assert_equal [], clone_info.ancestor_continues
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


  def test_session_tree_persists_entry_ids_labels_and_leaf_navigation
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      session = store.create
      conversation = Kward::Conversation.new(system_message: nil)
      session.attach(conversation)
      conversation.append_user("first")
      first_id = session.leaf_id
      conversation.append_assistant("reply")
      reply_id = session.leaf_id
      session.append_label_change(first_id, "start")
      session.branch(first_id)
      conversation.append_user("alternate")

      records = jsonl_records(session.path)
      tree = store.session_tree(session.path)
      _loaded_session, loaded_conversation = store.load(session.path)
      loaded_messages = loaded_conversation.messages.reject { |message| (message["role"] || message[:role]) == "system" }

      assert records.any? { |record| record["type"] == "message" && record["id"] == first_id && record.dig("message", "id") == first_id }
      assert_equal first_id, records.find { |record| record["id"] == reply_id }["parentId"]
      assert_equal "alternate", loaded_messages.last["content"]
      assert_equal "start", tree.first["label"]
      assert_equal session.leaf_id, store.current_leaf(session.path)
    end
  end

  def test_session_tree_renderer_handles_deep_linear_trees
    root = { "entry" => { "type" => "message", "id" => "0", "message" => { "role" => "user", "content" => "0" } }, "children" => [] }
    node = root
    3_000.times do |index|
      id = (index + 1).to_s
      child = { "entry" => { "type" => "message", "id" => id, "parentId" => index.to_s, "message" => { "role" => "user", "content" => id } }, "children" => [] }
      node["children"] << child
      node = child
    end

    items = Kward::SessionTreeRenderer.new(roots: [root], current_leaf_id: "3000").items

    assert_equal 3_001, items.length
    assert_equal "3000", items.last[:entry]["id"]
  end

  def test_session_tree_handles_duplicate_entry_ids_without_self_cycle
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      session = store.create
      conversation = Kward::Conversation.new(system_message: nil)
      session.attach(conversation)
      conversation.append_user("first")
      reused_message = conversation.messages.first
      conversation.append_assistant(reused_message)

      tree = store.session_tree(session.path)
      items = Kward::SessionTreeRenderer.new(roots: tree, current_leaf_id: session.leaf_id).items

      assert_equal 1, tree.length
      assert_empty tree.first["children"]
      assert_equal ["first"], items.map { |item| item[:entry].dig("message", "content") }
    end
  end

  def test_session_ignores_linear_records_without_entry_ids
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      session = store.create
      File.open(session.path, "a") do |file|
        file.puts(JSON.generate({ type: "message", timestamp: Time.now.utc.iso8601(3), message: { role: "user", content: "old" } }))
        file.puts(JSON.generate({ type: "message", timestamp: Time.now.utc.iso8601(3), message: { role: "assistant", content: "reply" } }))
      end

      tree = store.session_tree(session.path)
      _loaded_session, loaded_conversation = store.load(session.path)

      assert_empty tree
      loaded_messages = loaded_conversation.messages.reject { |message| (message["role"] || message[:role]) == "system" }
      assert_empty loaded_messages
    end
  end

  def test_session_persists_normalized_edit_tool_execution_record
    Dir.mktmpdir do |config_dir|
      Dir.mktmpdir do |workspace_dir|
        File.write(File.join(workspace_dir, "file.txt"), "old one\nold two\n")
        store = Kward::SessionStore.new(config_dir: config_dir, cwd: workspace_dir)
        session = store.create
        conversation = Kward::Conversation.new(system_message: nil, workspace_root: workspace_dir)
        session.attach(conversation)
        registry = Kward::ToolRegistry.new(workspace: Kward::Workspace.new(root: workspace_dir))

        registry.dispatch(tool_call("read_file", path: "file.txt"), conversation)
        registry.dispatch(tool_call("edit_file", path: "file.txt", edits: [{ old_text: "old one", new_text: "new one" }]), conversation)

        records = jsonl_records(session.path)
        record = records.find { |item| item["type"] == "tool_execution_end" && item["toolName"] == "edit" }
        raw_tool = records.find { |item| item["type"] == "message" && item.dig("message", "role") == "tool" && item.dig("message", "name") == "edit_file" }

        assert raw_tool, "expected raw tool message to remain persisted"
        assert record, "expected normalized edit execution record"
        assert_equal "call_edit_file", record["toolCallId"]
        assert_equal "file.txt", record.dig("args", "path")
        assert_equal [{ "oldText" => "old one", "newText" => "new one" }], record.dig("args", "edits")
        assert_equal false, record.dig("result", "isError")
        assert_includes record.dig("result", "diff"), "--- file.txt"
        assert_equal false, record["isError"]
      end
    end
  end

  def test_session_persists_normalized_write_tool_execution_record
    Dir.mktmpdir do |config_dir|
      Dir.mktmpdir do |workspace_dir|
        store = Kward::SessionStore.new(config_dir: config_dir, cwd: workspace_dir)
        session = store.create
        conversation = Kward::Conversation.new(system_message: nil, workspace_root: workspace_dir)
        session.attach(conversation)
        registry = Kward::ToolRegistry.new(workspace: Kward::Workspace.new(root: workspace_dir))

        registry.dispatch(tool_call("write_file", path: "new.txt", content: "complete\ncontent\n"), conversation)

        record = jsonl_records(session.path).find { |item| item["type"] == "tool_execution_end" && item["toolName"] == "write" }

        assert record, "expected normalized write execution record"
        assert_equal "new.txt", record.dig("args", "path")
        assert_equal "complete\ncontent\n", record.dig("args", "content")
        assert_equal false, record.dig("result", "isError")
        assert_equal ["new.txt"], record.dig("result", "changedFiles")
        assert_equal false, record["isError"]
      end
    end
  end

  def test_session_persists_failed_mutation_without_changed_files
    Dir.mktmpdir do |config_dir|
      Dir.mktmpdir do |workspace_dir|
        File.write(File.join(workspace_dir, "existing.txt"), "keep\n")
        store = Kward::SessionStore.new(config_dir: config_dir, cwd: workspace_dir)
        session = store.create
        conversation = Kward::Conversation.new(system_message: nil, workspace_root: workspace_dir)
        session.attach(conversation)
        registry = Kward::ToolRegistry.new(workspace: Kward::Workspace.new(root: workspace_dir))

        registry.dispatch(tool_call("write_file", path: "existing.txt", content: "replace\n"), conversation)

        record = jsonl_records(session.path).find { |item| item["type"] == "tool_execution_end" && item["toolName"] == "write" }

        assert record, "expected normalized failed write execution record"
        assert_equal true, record.dig("result", "isError")
        assert_equal true, record["isError"]
        refute record["result"].key?("changedFiles")
      end
    end
  end

  def test_session_load_restores_compacted_tool_output_artifacts
    Dir.mktmpdir do |config_dir|
      Dir.mktmpdir do |workspace_dir|
        output = (["start"] + Array.new(2_000) { |index| "line #{index}" } + ["ERROR: important failure", "end"]).join("\n")
        store = Kward::SessionStore.new(config_dir: config_dir, cwd: workspace_dir)
        session = store.create
        conversation = Kward::Conversation.new(system_message: nil, workspace_root: workspace_dir)
        session.attach(conversation)
        registry = Kward::ToolRegistry.new(code_search: FakeCodeSearch.new(output), web_search_enabled: false)

        compacted = registry.dispatch(tool_call("code_search", action: "list_cache"), conversation)
        artifact_id = compacted[/toolout_[a-f0-9]{16}/]

        _loaded_session, loaded_conversation = store.load(session.path, workspace: Kward::Workspace.new(root: workspace_dir))
        result = Kward::ToolRegistry.new(web_search_enabled: false).dispatch(tool_call("retrieve_tool_output", id: artifact_id, query: "important", limit: 1), loaded_conversation)

        assert artifact_id, "expected compacted output to include an artifact id"
        assert_includes result, "[Retrieved tool output #{artifact_id} matching \"important\""
        assert_includes result, "ERROR: important failure"
      end
    end
  end

  def test_session_loads_older_files_without_tool_execution_records
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      session = store.create
      conversation = Kward::Conversation.new(system_message: nil)
      session.append_message({ role: "user", content: "hello" })
      session.append_message({ role: "assistant", content: "reply" })

      _loaded_session, loaded_conversation = store.load(session.path)

      loaded_messages = loaded_conversation.messages.reject { |message| (message["role"] || message[:role]) == "system" }

      assert_empty jsonl_records(session.path).select { |record| record["type"] == "tool_execution_end" }
      assert_equal ["hello", "reply"], loaded_messages.map { |message| message["content"] || message[:content] }
    end
  end

  def test_session_load_prefers_persisted_reasoning_and_model_for_persona_evaluation
    Dir.mktmpdir do |config_dir|
      Dir.mktmpdir do |workspace_dir|
        File.write(File.join(config_dir, "config.json"), JSON.dump({
          "personas" => {
            "default" => "Default persona.",
            "persona_modifiers" => {
              "reasoning" => {
                "low" => "Reasoning was low.",
                "xhigh" => "Reasoning was extra high."
              }
            }
          }
        }))

        with_env("KWARD_CONFIG_PATH" => File.join(config_dir, "config.json")) do
          store = Kward::SessionStore.new(config_dir: config_dir, cwd: workspace_dir)
          conversation = Kward::Conversation.new(
            workspace_root: workspace_dir,
            provider: "Codex",
            model: "gpt-5.5",
            reasoning_effort: "low"
          )
          session = store.create(provider: conversation.provider, model: conversation.model, reasoning_effort: conversation.reasoning_effort)
          session.attach(conversation)
          conversation.append_user("hello")

          _loaded_session, loaded_conversation = store.load(session.path, workspace: Kward::Workspace.new(root: workspace_dir), model: "gpt-5.5", reasoning_effort: "xhigh")

          prompt = loaded_conversation.system_message[:content]
          assert_includes prompt, "Default persona."
          assert_includes prompt, "Reasoning was low."
          refute_includes prompt, "Reasoning was extra high."
        end
      end
    end
  end

  def test_runtime_restores_latest_provider_model_and_reasoning
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      session = store.create(provider: "Codex", model: "gpt-5.4", reasoning_effort: "low")
      session.update_runtime(provider: "OpenRouter", model: "openai/gpt-5.5", reasoning_effort: "high")

      _loaded_session, conversation = store.load(session.path, provider: "Codex", model: "fallback", reasoning_effort: "medium")

      assert_equal "OpenRouter", conversation.provider
      assert_equal "openai/gpt-5.5", conversation.model
      assert_equal "high", conversation.reasoning_effort
    end
  end

  def test_runtime_falls_back_for_legacy_sessions_without_runtime_metadata
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      session = store.create

      _loaded_session, conversation = store.load(session.path, provider: "Codex", model: "gpt-5.5", reasoning_effort: "medium")

      assert_equal "Codex", conversation.provider
      assert_equal "gpt-5.5", conversation.model
      assert_equal "medium", conversation.reasoning_effort
    end
  end

  def test_recent_sessions_include_latest_runtime_metadata
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      session = store.create(provider: "Codex", model: "gpt-5.4", reasoning_effort: "low")
      session.update_runtime(provider: "OpenRouter", model: "openai/gpt-5.5", reasoning_effort: "high")
      session.append_message("role" => "user", "content" => "hello")

      info = store.recent.first

      assert_equal "OpenRouter", info.provider
      assert_equal "openai/gpt-5.5", info.model
      assert_equal "high", info.reasoning_effort
    end
  end

  def test_tool_execution_end_record_matches_tauren_session_diff_shape
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      session = store.create
      record = {
        type: "tool_execution_end",
        timestamp: Time.now.utc.iso8601(3),
        toolCallId: "call_123",
        toolName: "edit",
        args: { path: "src/file.ts", edits: [{ oldText: "old", newText: "new" }] },
        result: { content: "Edited src/file.ts", isError: false, diff: "--- src/file.ts\n+++ src/file.ts\n", changedFiles: ["src/file.ts"], images: [] },
        isError: false
      }
      store.append_record(session.path, record)

      parsed = jsonl_records(session.path).last

      assert_equal "tool_execution_end", parsed["type"]
      assert_equal "edit", parsed["toolName"]
      assert_equal "src/file.ts", parsed.dig("args", "path")
      assert_equal [{ "oldText" => "old", "newText" => "new" }], parsed.dig("args", "edits")
      assert_equal false, parsed.dig("result", "isError")
      assert_equal false, parsed["isError"]
      assert_equal ["src/file.ts"], parsed.dig("result", "changedFiles")
    end
  end

end
