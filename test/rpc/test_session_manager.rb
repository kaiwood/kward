require_relative "test_support"

class TestRPCSessionManager < KwardTestCase
  include KwardRPCTestSupport

  def test_delete_session_removes_persisted_session_file
    Dir.mktmpdir do |config_dir|
      workspace_root = File.realpath(Dir.mktmpdir)
      manager = Kward::RPC::SessionManager.new(server: RecordingServer.new, client: FakeClient.new([]), config_dir: config_dir)
      session = manager.create_session(workspace_root: workspace_root)
      manager.send(:fetch_session, session[:id]).conversation.append_user("keep me")

      result = manager.delete_session(session_id: session[:id])

      assert_equal true, result[:deleted]
      assert_equal session[:path], result[:path]
      refute File.exist?(session[:path])
      assert_empty manager.list_sessions(workspace_root: workspace_root, limit: nil)
    ensure
      FileUtils.remove_entry(workspace_root) if workspace_root && File.exist?(workspace_root)
    end
  end

  def test_delete_session_uses_explicit_deletion_for_empty_unnamed_sessions
    Dir.mktmpdir do |config_dir|
      workspace_root = File.realpath(Dir.mktmpdir)
      deleted_paths = []
      session_trash = FakeSessionTrash.new { |path| deleted_paths << path }
      manager = Kward::RPC::SessionManager.new(server: RecordingServer.new, client: FakeClient.new([]), config_dir: config_dir, session_trash: session_trash)
      session = manager.create_session(workspace_root: workspace_root)

      result = manager.delete_session(session_id: session[:id])

      assert_equal true, result[:deleted]
      assert_equal [session[:path]], deleted_paths
      refute_path_exists session[:path]
    ensure
      FileUtils.remove_entry(workspace_root) if workspace_root && File.exist?(workspace_root)
    end
  end

  def test_session_export_supports_markdown_default_and_html
    Dir.mktmpdir do |config_dir|
      manager = Kward::RPC::SessionManager.new(server: RecordingServer.new, client: FakeClient.new([]), config_dir: config_dir)
      session = manager.create_session(workspace_root: Dir.pwd)
      rpc_session = manager.send(:fetch_session, session[:id])
      rpc_session.conversation.append_user("hello <world>")
      rpc_session.conversation.append_assistant("reply")

      markdown = manager.export_session(session_id: session[:id])
      html = manager.export_session(session_id: session[:id], path: File.join(Dir.pwd, "tmp-rpc-export.html"), format: "html")

      assert_equal "markdown", markdown[:format]
      assert_equal ".md", File.extname(markdown[:path])
      assert_includes File.read(markdown[:path]), "## User\n\nhello <world>"
      assert_equal "html", html[:format]
      html_content = File.read(html[:path])
      assert_includes html_content, "<!doctype html>"
      assert_includes html_content, "hello &lt;world&gt;"
    ensure
      File.delete(markdown[:path]) if markdown && File.exist?(markdown[:path])
      File.delete(File.join(Dir.pwd, "tmp-rpc-export.html")) if File.exist?(File.join(Dir.pwd, "tmp-rpc-export.html"))
    end
  end

  def test_session_export_renders_compaction_summary_content
    Dir.mktmpdir do |config_dir|
      manager = Kward::RPC::SessionManager.new(server: RecordingServer.new, client: FakeClient.new([]), config_dir: config_dir)
      session = manager.create_session(workspace_root: Dir.pwd)
      rpc_session = manager.send(:fetch_session, session[:id])
      rpc_session.conversation.compact!("summary content", compaction_summary: true)

      markdown = manager.export_session(session_id: session[:id])

      assert_includes File.read(markdown[:path]), "## Compactionsummary\n\nsummary content"
    ensure
      File.delete(markdown[:path]) if markdown && File.exist?(markdown[:path])
    end
  end

  def test_session_export_rejects_path_outside_workspace_or_session_directory
    Dir.mktmpdir do |config_dir|
      workspace_root = File.realpath(Dir.mktmpdir)
      outside_dir = Dir.mktmpdir
      manager = Kward::RPC::SessionManager.new(server: RecordingServer.new, client: FakeClient.new([]), config_dir: config_dir)
      session = manager.create_session(workspace_root: workspace_root)

      assert_raises(ArgumentError) do
        manager.export_session(session_id: session[:id], path: File.join(outside_dir, "session.md"))
      end
    ensure
      FileUtils.remove_entry(workspace_root) if workspace_root && File.exist?(workspace_root)
      FileUtils.remove_entry(outside_dir) if outside_dir && File.exist?(outside_dir)
    end
  end

  def test_create_session_can_resume_remembered_last_session_when_enabled
    Dir.mktmpdir do |config_dir|
      File.write(File.join(config_dir, "config.json"), JSON.dump("sessions" => { "auto_resume" => true }))
      workspace_root = File.realpath(Dir.mktmpdir)
      first_manager = Kward::RPC::SessionManager.new(server: RecordingServer.new, client: FakeClient.new([]), config_dir: config_dir)
      first = first_manager.create_session(workspace_root: workspace_root)
      first_rpc = first_manager.send(:fetch_session, first[:id])
      first_rpc.conversation.append_user("hello")
      first_rpc.conversation.append_assistant("reply")

      second_manager = Kward::RPC::SessionManager.new(server: RecordingServer.new, client: FakeClient.new([]), config_dir: config_dir)
      resumed = second_manager.create_session(workspace_root: workspace_root, resume_last: true)
      resumed_rpc = second_manager.send(:fetch_session, resumed[:id])

      assert_equal first[:persistentId], resumed[:persistentId]
      assert_equal first[:path], resumed[:path]
      assert_equal true, resumed[:resumed]
      assert !resumed[:activePersonaLabel].to_s.empty?
      assert_equal ["user", "assistant"], resumed[:messages].map { |message| message[:role] }
      messages = resumed_rpc.conversation.messages.reject { |message| (message["role"] || message[:role]) == "system" }
      assert_equal ["hello", "reply"], messages.map { |message| message["content"] || message[:content] }
    ensure
      FileUtils.remove_entry(workspace_root) if workspace_root && File.exist?(workspace_root)
    end
  end

  def test_create_session_does_not_resume_when_auto_resume_disabled
    Dir.mktmpdir do |config_dir|
      File.write(File.join(config_dir, "config.json"), JSON.dump("sessions" => { "auto_resume" => false }))
      workspace_root = File.realpath(Dir.mktmpdir)
      first_manager = Kward::RPC::SessionManager.new(server: RecordingServer.new, client: FakeClient.new([]), config_dir: config_dir)
      first = first_manager.create_session(workspace_root: workspace_root)
      first_rpc = first_manager.send(:fetch_session, first[:id])
      first_rpc.conversation.append_user("hello")

      second_manager = Kward::RPC::SessionManager.new(server: RecordingServer.new, client: FakeClient.new([]), config_dir: config_dir)
      fresh = second_manager.create_session(workspace_root: workspace_root, resume_last: true)

      refute_equal first[:persistentId], fresh[:persistentId]
      refute_equal first[:path], fresh[:path]
    ensure
      FileUtils.remove_entry(workspace_root) if workspace_root && File.exist?(workspace_root)
    end
  end

  def test_session_list_returns_rpc_metadata_message_counts_and_newest_first
    Dir.mktmpdir do |config_dir|
      workspace_root = File.realpath(Dir.mktmpdir)
      manager = Kward::RPC::SessionManager.new(server: RecordingServer.new, client: FakeClient.new([]), config_dir: config_dir)
      older = manager.create_session(workspace_root: workspace_root, name: "Named")
      older_rpc = manager.send(:fetch_session, older[:id])
      older_rpc.conversation.append_user("first prompt\nwith spaces")
      older_rpc.conversation.append_assistant("reply")
      older_rpc.conversation.append_tool(tool_call_id: "call_read_file", name: "read_file", content: "contents")

      newer = manager.create_session(workspace_root: workspace_root)
      newer_rpc = manager.send(:fetch_session, newer[:id])
      newer_rpc.conversation.append_user("new prompt")

      old_time = Time.now - 60
      File.utime(old_time, old_time, older[:path])
      File.utime(Time.now, Time.now, newer[:path])

      sessions = manager.list_sessions(workspace_root: workspace_root, limit: 10)

      assert_equal [newer[:persistentId], older[:persistentId]], sessions.map { |session| session[:id] }
      info = sessions.find { |session| session[:id] == older[:persistentId] }
      assert_equal File.expand_path(older[:path]), info[:path]
      assert_equal workspace_root, info[:cwd]
      assert_equal workspace_root, info[:workspaceRoot]
      assert_equal "Named", info[:name]
      assert_equal "first prompt with spaces", info[:firstMessage]
      assert_equal 3, info[:messageCount]
      assert info[:createdAt]
      assert info[:modifiedAt]
    ensure
      FileUtils.remove_entry(workspace_root) if workspace_root && File.exist?(workspace_root)
    end
  end

  def test_rpc_prompt_template_turn_persists_original_display_content_and_session_name
    Dir.mktmpdir do |config_dir|
      workspace_root = File.realpath(Dir.mktmpdir)
      File.write(File.join(config_dir, "config.json"), JSON.dump({}))
      prompts_dir = File.join(config_dir, "prompts")
      FileUtils.mkdir_p(prompts_dir)
      File.write(File.join(prompts_dir, "plan.md"), "Plan this:\n$ARGUMENTS\n")
      manager = Kward::RPC::SessionManager.new(server: RecordingServer.new, client: RecordingClient.new(["planned"]), config_dir: config_dir)

      with_env("KWARD_CONFIG_PATH" => File.join(config_dir, "config.json")) do
        session = manager.create_session(workspace_root: workspace_root)
        turn = manager.start_turn(session_id: session[:id], input: "/plan fix bug")
        wait_until { manager.turn_status(turn_id: turn[:id])[:status] == "completed" }

        records = jsonl_records(session[:path])
        user_message = records.find { |record| record["type"] == "message" && record.dig("message", "role") == "user" }["message"]
        assert_equal "Plan this:\nfix bug\n", user_message["content"]
        assert_equal "/plan fix bug", user_message["display_content"]
        assert_equal "/plan fix bug", manager.send(:fetch_session, session[:id]).session.name
        assert_equal "/plan fix bug", manager.list_sessions(workspace_root: workspace_root).first[:name]
      end
    ensure
      FileUtils.remove_entry(workspace_root) if workspace_root && File.exist?(workspace_root)
    end
  end

  def test_rpc_first_plain_input_persists_session_name_without_display_content
    Dir.mktmpdir do |config_dir|
      workspace_root = File.realpath(Dir.mktmpdir)
      manager = Kward::RPC::SessionManager.new(server: RecordingServer.new, client: RecordingClient.new(["done"]), config_dir: config_dir)
      session = manager.create_session(workspace_root: workspace_root)
      turn = manager.start_turn(session_id: session[:id], input: "Something is not working")
      wait_until { manager.turn_status(turn_id: turn[:id])[:status] == "completed" }

      user_message = jsonl_records(session[:path]).find { |record| record["type"] == "message" && record.dig("message", "role") == "user" }["message"]
      assert_equal "Something is not working", user_message["content"]
      refute user_message.key?("display_content")
      assert_equal "Something is not working", manager.send(:fetch_session, session[:id]).session.name
    ensure
      FileUtils.remove_entry(workspace_root) if workspace_root && File.exist?(workspace_root)
    end
  end

  def test_rpc_explicit_session_name_is_not_overwritten_by_first_turn
    Dir.mktmpdir do |config_dir|
      workspace_root = File.realpath(Dir.mktmpdir)
      manager = Kward::RPC::SessionManager.new(server: RecordingServer.new, client: RecordingClient.new(["done"]), config_dir: config_dir)
      session = manager.create_session(workspace_root: workspace_root, name: "Explicit")
      turn = manager.start_turn(session_id: session[:id], input: "Something is not working")
      wait_until { manager.turn_status(turn_id: turn[:id])[:status] == "completed" }

      assert_equal "Explicit", manager.send(:fetch_session, session[:id]).session.name
    ensure
      FileUtils.remove_entry(workspace_root) if workspace_root && File.exist?(workspace_root)
    end
  end

  def test_session_list_deletes_empty_unnamed_sessions
    Dir.mktmpdir do |config_dir|
      workspace_root = File.realpath(Dir.mktmpdir)
      manager = Kward::RPC::SessionManager.new(server: RecordingServer.new, client: FakeClient.new([]), config_dir: config_dir)
      empty = Kward::SessionStore.new(config_dir: config_dir, cwd: workspace_root).create
      saved = manager.create_session(workspace_root: workspace_root, name: "Keep me")

      sessions = manager.list_sessions(workspace_root: workspace_root, limit: 10)

      assert_equal [saved[:persistentId]], sessions.map { |session| session[:id] }
      refute_path_exists empty.path
    ensure
      FileUtils.remove_entry(workspace_root) if workspace_root && File.exist?(workspace_root)
    end
  end

  def test_session_list_without_limit_returns_all_sessions
    Dir.mktmpdir do |config_dir|
      workspace_root = File.realpath(Dir.mktmpdir)
      manager = Kward::RPC::SessionManager.new(server: RecordingServer.new, client: FakeClient.new([]), config_dir: config_dir)
      sessions = 25.times.map do |index|
        session = manager.create_session(workspace_root: workspace_root)
        manager.send(:fetch_session, session[:id]).conversation.append_user("saved prompt #{index}")
        session
      end

      listed = manager.list_sessions(workspace_root: workspace_root)

      assert_equal sessions.length, listed.length
      assert_equal sessions.map { |session| session[:persistentId] }.sort, listed.map { |session| session[:id] }.sort
    ensure
      FileUtils.remove_entry(workspace_root) if workspace_root && File.exist?(workspace_root)
    end
  end


  def test_session_tree_returns_labels_and_navigation_editor_text
    Dir.mktmpdir do |config_dir|
      manager = Kward::RPC::SessionManager.new(server: RecordingServer.new, client: FakeClient.new([]), config_dir: config_dir)
      session = manager.create_session(workspace_root: Dir.pwd)
      rpc_session = manager.send(:fetch_session, session[:id])
      rpc_session.conversation.append_user("first")
      rpc_session.conversation.append_assistant("reply")
      first_id = manager.session_tree(session_id: session[:id])[:items].first[:entryId]

      manager.set_tree_label(session_id: session[:id], entry_id: first_id, label: "start")
      tree = manager.session_tree(session_id: session[:id])[:items]
      result = manager.navigate_tree(session_id: session[:id], entry_id: first_id)
      rpc_session = manager.send(:fetch_session, session[:id])

      assert_equal ["user", "assistant"], tree.map { |item| item[:role] }
      assert_equal [true, true], tree.map { |item| item[:selectable] }
      assert_equal "start", tree.first[:label]
      assert tree.first[:labelTimestamp]
      assert_equal "first", result[:editorText]
      assert_nil rpc_session.session.leaf_id
      assert_empty rpc_session.conversation.messages.reject { |message| (message["role"] || message[:role]) == "system" }
    end
  end

  def test_session_tree_navigation_selects_assistant_entry_without_editor_text
    Dir.mktmpdir do |config_dir|
      manager = Kward::RPC::SessionManager.new(server: RecordingServer.new, client: FakeClient.new([]), config_dir: config_dir)
      session = manager.create_session(workspace_root: Dir.pwd)
      rpc_session = manager.send(:fetch_session, session[:id])
      rpc_session.conversation.append_user("first")
      rpc_session.conversation.append_assistant("reply")
      assistant_id = rpc_session.session.leaf_id
      rpc_session.conversation.append_user("future prompt")

      result = manager.navigate_tree(session_id: session[:id], entry_id: assistant_id)
      rpc_session = manager.send(:fetch_session, session[:id])

      assert_equal assistant_id, rpc_session.session.leaf_id
      refute_includes result.keys, :editorText
      assert_equal ["user", "assistant"], rpc_session.conversation.messages.reject { |message| (message["role"] || message[:role]) == "system" }.map { |message| message["role"] || message[:role] }
    end
  end

  def test_session_tree_navigation_can_create_branch_summary
    Dir.mktmpdir do |config_dir|
      manager = Kward::RPC::SessionManager.new(server: RecordingServer.new, client: FakeClient.new([{ "role" => "assistant", "content" => "branch summary" }]), config_dir: config_dir)
      session = manager.create_session(workspace_root: Dir.pwd)
      rpc_session = manager.send(:fetch_session, session[:id])
      rpc_session.conversation.append_user("first")
      rpc_session.conversation.append_assistant("reply")
      first_id = manager.session_tree(session_id: session[:id])[:items].first[:entryId]

      manager.navigate_tree(session_id: session[:id], entry_id: first_id, summarize: true, custom_instructions: "focus")
      tree = manager.session_tree(session_id: session[:id])[:items]

      assert tree.any? { |item| item[:role] == "summary" && item[:selectable] == true && item[:text] == "branch summary" }
      assert jsonl_records(session[:path]).any? { |record| record["type"] == "branch_summary" && record["summary"] == "branch summary" }
    end
  end


  def test_session_tree_keeps_single_child_user_turns_flat
    Dir.mktmpdir do |config_dir|
      manager = Kward::RPC::SessionManager.new(server: RecordingServer.new, client: FakeClient.new([]), config_dir: config_dir)
      session = manager.create_session(workspace_root: Dir.pwd)
      rpc_session = manager.send(:fetch_session, session[:id])
      rpc_session.conversation.append_user("first")
      rpc_session.conversation.append_assistant("reply")
      rpc_session.conversation.append_user("second")
      rpc_session.conversation.append_assistant("reply")
      rpc_session.conversation.append_user("third")

      tree = manager.session_tree(session_id: session[:id])[:items]

      user_items = tree.select { |item| item[:role] == "user" }
      assert_equal ["first", "second", "third"], user_items.map { |item| item[:text] }
      assert_equal [0, 0, 0], user_items.map { |item| item[:depth] }
      assert_equal [true], user_items.map { |item| item[:selectable] }.uniq
      assert tree.any? { |item| item[:role] == "assistant" && item[:selectable] == true }
    end
  end

  def test_session_tree_matches_pi_style_for_active_branches_and_tool_results
    Dir.mktmpdir do |config_dir|
      manager = Kward::RPC::SessionManager.new(server: RecordingServer.new, client: FakeClient.new([]), config_dir: config_dir)
      session = manager.create_session(workspace_root: Dir.pwd)
      rpc_session = manager.send(:fetch_session, session[:id])
      rpc_session.conversation.append_user("root prompt")
      rpc_session.conversation.append_assistant("root reply")
      root_reply_id = rpc_session.session.leaf_id
      rpc_session.conversation.append_user("active branch")
      rpc_session.conversation.append_assistant({
        "role" => "assistant",
        "content" => nil,
        "tool_calls" => [tool_call("read_file", path: "README.md", offset: 2, limit: 3)]
      })
      rpc_session.conversation.append_tool(tool_call_id: "call_read_file", name: "read_file", content: "README contents")
      active_leaf_id = rpc_session.session.leaf_id
      rpc_session.session.branch(root_reply_id)
      rpc_session.conversation.append_user("side branch")
      rpc_session.conversation.append_assistant("side reply")
      rpc_session.session.branch(active_leaf_id)

      tree = manager.session_tree(session_id: session[:id])[:items]
      active_item = tree.find { |item| item[:text] == "active branch" }
      side_item = tree.find { |item| item[:text] == "side branch" }

      refute tree.any? { |item| item[:role] == "assistant" && item[:text].empty? }
      assert tree.any? { |item| item[:role] == "tool" && item[:text] == "[read: README.md:2-4]" }
      assert_equal "├⊟ ", active_item[:prefix]
      assert_equal true, active_item[:activePath]
      assert_equal "└⊟ ", side_item[:prefix]
      refute side_item[:activePath]
      assert_operator tree.index(active_item), :<, tree.index(side_item)
    end
  end

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
      # LLM summarization reformulates first-person to third-person
      assert_equal ["I usually prefer concise and practical answers"], memories.map { |memory| memory["text"] }
      assert_equal ["soft_001"], memories.map { |memory| memory["id"] }
      refute_includes memories.map { |memory| memory["text"] }, "Prefer focused tests and always use minitest"
      refute_includes memories.map { |memory| memory["text"] }, "I always use assistant-generated summaries"
    end
  end

  def test_session_list_keeps_cloned_sessions_in_newest_first_order
    Dir.mktmpdir do |config_dir|
      workspace_root = File.realpath(Dir.mktmpdir)
      manager = Kward::RPC::SessionManager.new(server: RecordingServer.new, client: FakeClient.new([]), config_dir: config_dir)
      parent = manager.create_session(workspace_root: workspace_root)
      parent_rpc = manager.send(:fetch_session, parent[:id])
      parent_rpc.conversation.append_user("parent prompt")
      clone = manager.clone_session(session_id: parent[:id])
      clone_rpc = manager.send(:fetch_session, clone[:id])
      clone_rpc.conversation.append_user("clone prompt")
      old_time = Time.now - 60
      File.utime(old_time, old_time, parent[:path])
      File.utime(Time.now, Time.now, clone[:path])

      sessions = manager.list_sessions(workspace_root: workspace_root, limit: 10)

      assert_equal [clone[:persistentId], parent[:persistentId]], sessions.map { |session| session[:id] }
      assert_equal parent[:persistentId], sessions.first[:parentId]
    ensure
      FileUtils.remove_entry(workspace_root) if workspace_root && File.exist?(workspace_root)
    end
  end

  def test_session_list_keeps_active_named_and_used_sessions
    Dir.mktmpdir do |config_dir|
      workspace_root = File.realpath(Dir.mktmpdir)
      manager = Kward::RPC::SessionManager.new(server: RecordingServer.new, client: FakeClient.new([]), config_dir: config_dir)
      named = manager.create_session(workspace_root: workspace_root, name: "Keep me")
      used = manager.create_session(workspace_root: workspace_root)
      manager.send(:fetch_session, used[:id]).conversation.append_user("keep me")

      sessions = manager.list_sessions(workspace_root: workspace_root, limit: 10)

      assert_includes sessions.map { |session| session[:id] }, named[:persistentId]
      assert_includes sessions.map { |session| session[:id] }, used[:persistentId]
    ensure
      FileUtils.remove_entry(workspace_root) if workspace_root && File.exist?(workspace_root)
    end
  end

  def test_session_resume_returns_metadata_and_restores_transcript
    Dir.mktmpdir do |config_dir|
      workspace_root = File.realpath(Dir.mktmpdir)
      manager = Kward::RPC::SessionManager.new(server: RecordingServer.new, client: FakeClient.new([]), config_dir: config_dir)
      session = manager.create_session(workspace_root: workspace_root, name: "Resume me")
      rpc_session = manager.send(:fetch_session, session[:id])
      rpc_session.conversation.append_user("restored prompt")

      resumed = manager.resume_session(path: session[:path], workspace_root: workspace_root)
      transcript = manager.transcript(session_id: resumed[:id])

      refute_equal session[:id], resumed[:id]
      assert_equal session[:persistentId], resumed[:persistentId]
      assert_equal session[:path], resumed[:path]
      assert_equal workspace_root, resumed[:cwd]
      assert_equal workspace_root, resumed[:workspaceRoot]
      assert_equal "Resume me", resumed[:name]
      assert_equal "restored prompt", transcript[:messages].find { |message| message[:role] == "user" }[:content][0][:text]
    ensure
      FileUtils.remove_entry(workspace_root) if workspace_root && File.exist?(workspace_root)
    end
  end

  def test_session_resume_uses_persisted_workspace_for_restored_read_paths
    Dir.mktmpdir do |config_dir|
      original_root = File.realpath(Dir.mktmpdir)
      wrong_root = File.realpath(Dir.mktmpdir)
      File.write(File.join(original_root, "file.txt"), "old text\n")
      File.write(File.join(wrong_root, "file.txt"), "old text\n")
      manager = Kward::RPC::SessionManager.new(server: RecordingServer.new, client: FakeClient.new([]), config_dir: config_dir)
      session = manager.create_session(workspace_root: original_root)
      source = manager.send(:fetch_session, session[:id])
      source.conversation.append_assistant(assistant_tool_call("read_file", { path: "file.txt" }))
      source.conversation.append_tool(tool_call_id: "call_read_file", name: "read_file", content: "old text\n")

      resumed = manager.resume_session(path: session[:path], workspace_root: wrong_root)
      resumed_rpc = manager.send(:fetch_session, resumed[:id])
      result = resumed_rpc.tool_registry.dispatch(
        tool_call("edit_file", { path: "file.txt", edits: [{ old_text: "old text", new_text: "new text" }] }),
        resumed_rpc.conversation
      )

      assert_equal original_root, resumed[:cwd]
      assert_equal original_root, resumed[:workspaceRoot]
      assert_includes result, "Edited file.txt"
      assert_equal "new text\n", File.read(File.join(original_root, "file.txt"))
      assert_equal "old text\n", File.read(File.join(wrong_root, "file.txt"))
    ensure
      FileUtils.remove_entry(original_root) if original_root && File.exist?(original_root)
      FileUtils.remove_entry(wrong_root) if wrong_root && File.exist?(wrong_root)
    end
  end

  def test_session_rename_clears_empty_names
    Dir.mktmpdir do |config_dir|
      manager = Kward::RPC::SessionManager.new(server: RecordingServer.new, client: FakeClient.new([]), config_dir: config_dir)
      session = manager.create_session(workspace_root: Dir.pwd, name: "Initial")

      renamed = manager.rename_session(session_id: session[:id], name: "   ")

      assert_nil renamed[:name]
      records = jsonl_records(session[:path]).select { |record| record["type"] == "session_info" }
      assert_nil records.last["name"]
    end
  end

  def test_rpc_plugin_footer_notifications_include_session_text
    Dir.mktmpdir do |config_dir|
      registry = Kward::PluginRegistry.new
      registry.evaluate do |plugin|
        plugin.footer do |ctx|
          "#{ctx.session_name || "unnamed"} #{ctx.transcript.messages.length} messages"
        end
      end
      manager = Kward::RPC::SessionManager.new(server: RecordingServer.new, client: RecordingClient.new(["done"]), config_dir: config_dir)
      manager.instance_variable_set(:@plugin_registry, registry)

      session = manager.create_session(workspace_root: Dir.pwd, name: "Bridge")
      create_footer = manager.instance_variable_get(:@server).notifications.find { |notification| notification[:method] == "ui/footer" }
      assert_equal({ sessionId: session[:id], text: "Bridge 1 messages" }, create_footer[:params])

      turn = manager.start_turn(session_id: session[:id], input: "hello")
      wait_until { manager.turn_status(turn_id: turn[:id])[:status] == "completed" }

      footer_notifications = manager.instance_variable_get(:@server).notifications.select { |notification| notification[:method] == "ui/footer" }
      assert_equal({ sessionId: session[:id], text: "Bridge 3 messages" }, footer_notifications.last[:params])
    end
  end

  def test_rpc_plugin_footer_refreshes_on_interval
    original_interval = Kward::RPC::SessionManager::FOOTER_REFRESH_INTERVAL
    Kward::RPC::SessionManager.send(:remove_const, :FOOTER_REFRESH_INTERVAL)
    Kward::RPC::SessionManager.const_set(:FOOTER_REFRESH_INTERVAL, 0.01)

    Dir.mktmpdir do |config_dir|
      count = 0
      registry = Kward::PluginRegistry.new
      registry.evaluate do |plugin|
        plugin.footer do |_ctx|
          count += 1
          "tick #{count}"
        end
      end
      server = RecordingServer.new
      manager = Kward::RPC::SessionManager.new(server: server, client: FakeClient.new([]), config_dir: config_dir)
      manager.instance_variable_set(:@plugin_registry, registry)

      session = manager.create_session(workspace_root: Dir.pwd)
      wait_until { server.notifications.count { |notification| notification[:method] == "ui/footer" } >= 2 }

      footer_notifications = server.notifications.select { |notification| notification[:method] == "ui/footer" }
      assert_equal({ sessionId: session[:id], text: "tick 1" }, footer_notifications.first[:params])
      assert_equal({ sessionId: session[:id], text: "tick 2" }, footer_notifications[1][:params])
      manager.close_session(session_id: session[:id])
    end
  ensure
    Kward::RPC::SessionManager.send(:remove_const, :FOOTER_REFRESH_INTERVAL)
    Kward::RPC::SessionManager.const_set(:FOOTER_REFRESH_INTERVAL, original_interval)
  end

  def test_session_close_deletes_empty_unnamed_session
    Dir.mktmpdir do |config_dir|
      manager = Kward::RPC::SessionManager.new(server: RecordingServer.new, client: FakeClient.new([]), config_dir: config_dir)
      session = manager.create_session(workspace_root: Dir.pwd)

      result = manager.close_session(session_id: session[:id])

      assert_equal({ closed: true }, result)
      refute_path_exists session[:path]
    end
  end

  def test_session_create_deletes_previous_empty_unnamed_session
    Dir.mktmpdir do |config_dir|
      workspace_root = File.realpath(Dir.mktmpdir)
      manager = Kward::RPC::SessionManager.new(server: RecordingServer.new, client: FakeClient.new([]), config_dir: config_dir)
      first = manager.create_session(workspace_root: workspace_root)

      second = manager.create_session(workspace_root: workspace_root)

      refute_path_exists first[:path]
      assert_path_exists second[:path]
      assert_empty manager.list_sessions(workspace_root: workspace_root, limit: 10)
      error = assert_raises(RuntimeError) { manager.runtime_state(session_id: first[:id]) }
      assert_equal "Unknown session: #{first[:id]}", error.message
    ensure
      FileUtils.remove_entry(workspace_root) if workspace_root && File.exist?(workspace_root)
    end
  end

  def test_session_resume_deletes_previous_empty_unnamed_session
    Dir.mktmpdir do |config_dir|
      workspace_root = File.realpath(Dir.mktmpdir)
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: workspace_root)
      target = store.create
      manager = Kward::RPC::SessionManager.new(server: RecordingServer.new, client: FakeClient.new([]), config_dir: config_dir)
      empty = manager.create_session(workspace_root: workspace_root)

      resumed = manager.resume_session(path: target.path, workspace_root: workspace_root)

      refute_path_exists empty[:path]
      assert_path_exists resumed[:path]
    ensure
      FileUtils.remove_entry(workspace_root) if workspace_root && File.exist?(workspace_root)
    end
  end

  def test_session_create_keeps_previous_named_used_and_busy_sessions
    Dir.mktmpdir do |config_dir|
      manager = Kward::RPC::SessionManager.new(server: RecordingServer.new, client: SlowClient.new, config_dir: config_dir)
      named = manager.create_session(workspace_root: Dir.pwd, name: "Keep me")
      used = manager.create_session(workspace_root: Dir.pwd)
      manager.send(:fetch_session, used[:id]).conversation.append_user("keep me")
      busy = manager.create_session(workspace_root: Dir.pwd)
      turn = manager.start_turn(session_id: busy[:id], input: "keep busy")

      fresh = manager.create_session(workspace_root: Dir.pwd)

      assert_path_exists named[:path]
      assert_path_exists used[:path]
      assert_path_exists busy[:path]
      assert_path_exists fresh[:path]
      wait_until { manager.turn_status(turn_id: turn[:id])[:status] == "completed" }
    end
  end

  def test_session_close_keeps_named_and_used_sessions
    Dir.mktmpdir do |config_dir|
      manager = Kward::RPC::SessionManager.new(server: RecordingServer.new, client: FakeClient.new([]), config_dir: config_dir)
      named = manager.create_session(workspace_root: Dir.pwd, name: "Keep me")
      used = manager.create_session(workspace_root: Dir.pwd)
      manager.send(:fetch_session, used[:id]).conversation.append_user("keep me")

      manager.close_session(session_id: named[:id])
      manager.close_session(session_id: used[:id])

      assert_path_exists named[:path]
      assert_path_exists used[:path]
    end
  end

  def test_session_close_stops_idle_worker
    Dir.mktmpdir do |config_dir|
      manager = Kward::RPC::SessionManager.new(server: RecordingServer.new, client: RecordingClient.new(["done"]), config_dir: config_dir)
      session = manager.create_session(workspace_root: Dir.pwd)
      rpc_session = manager.send(:fetch_session, session[:id])
      turn = manager.start_turn(session_id: session[:id], input: "hello")

      wait_until { manager.turn_status(turn_id: turn[:id])[:status] == "completed" }
      worker = rpc_session.worker
      assert worker&.alive?

      manager.close_session(session_id: session[:id])

      wait_until { !worker.alive? && rpc_session.worker.nil? }
    end
  end

  def test_cleanup_unused_sessions_stops_idle_workers
    Dir.mktmpdir do |config_dir|
      manager = Kward::RPC::SessionManager.new(server: RecordingServer.new, client: RecordingClient.new(["done"]), config_dir: config_dir)
      session = manager.create_session(workspace_root: Dir.pwd)
      rpc_session = manager.send(:fetch_session, session[:id])
      turn = manager.start_turn(session_id: session[:id], input: "hello")

      wait_until { manager.turn_status(turn_id: turn[:id])[:status] == "completed" }
      worker = rpc_session.worker
      assert worker&.alive?

      manager.cleanup_unused_sessions

      wait_until { !worker.alive? && rpc_session.worker.nil? }
    end
  end

  def test_session_clone_uses_independent_conversation_and_file
    Dir.mktmpdir do |config_dir|
      workspace_root = File.realpath(Dir.mktmpdir)
      manager = Kward::RPC::SessionManager.new(server: RecordingServer.new, client: FakeClient.new([]), config_dir: config_dir)
      source = manager.create_session(workspace_root: workspace_root, name: "Draft")
      manager.rename_session(session_id: source[:id], name: "Useful")
      source_rpc = manager.send(:fetch_session, source[:id])
      source_rpc.conversation.append_user("original prompt")
      source_rpc.conversation.append_assistant("original reply")

      clone = manager.clone_session(session_id: source[:id])
      clone_rpc = manager.send(:fetch_session, clone[:id])

      refute_equal source[:persistentId], clone[:persistentId]
      refute_equal source[:path], clone[:path]
      refute_same source_rpc.conversation, clone_rpc.conversation
      assert_equal source[:persistentId], clone[:parentId]
      assert_equal source[:path], clone[:parentPath]
      assert_equal "Useful", clone[:name]

      clone_rpc.conversation.append_user("clone only")
      source_rpc.conversation.append_user("source only")

      source_records = jsonl_records(source[:path]).to_s
      clone_records = jsonl_records(clone[:path]).to_s
      assert_includes source_records, "original prompt"
      assert_includes source_records, "source only"
      refute_includes source_records, "clone only"
      assert_includes clone_records, "original prompt"
      assert_includes clone_records, "clone only"
      refute_includes clone_records, "source only"

      listed = manager.list_sessions(workspace_root: workspace_root, limit: 10)
      listed_source = listed.find { |item| item[:id] == source[:persistentId] }
      listed_clone = listed.find { |item| item[:id] == clone[:persistentId] }
      assert_equal source[:persistentId], listed_clone[:parentId]
      assert_equal source[:path], listed_clone[:parentPath]
      assert_equal "Useful", listed_clone[:name]
      assert_equal 0, listed_source[:depth]
      assert_equal 0, listed_clone[:depth]
      assert_equal [], listed_clone[:ancestorContinues]
    ensure
      FileUtils.remove_entry(workspace_root) if workspace_root && File.exist?(workspace_root)
    end
  end

  def test_session_compact_emits_events_persists_summary_and_restores_transcript
    Dir.mktmpdir do |config_dir|
      File.write(File.join(config_dir, "config.json"), JSON.dump({ "compaction" => { "keep_recent_tokens" => 10 } }))
      server = RecordingServer.new
      client = RecordingClient.new(["summary"])
      manager = Kward::RPC::SessionManager.new(server: server, client: client, config_dir: config_dir)
      session = manager.create_session(workspace_root: Dir.pwd)
      rpc_session = manager.send(:fetch_session, session[:id])
      rpc_session.conversation.append_user("hello with enough detail for compaction")
      rpc_session.conversation.append_assistant("reply")
      rpc_session.conversation.append_user("recent turn")
      rpc_session.conversation.append_assistant("recent reply")

      result = manager.compact_session(session_id: session[:id], custom_instructions: "focus")

      assert_includes result[:summary], "summary"
      assert_match /\A(?:message:\d+|[0-9a-f]{8})\z/, result[:firstKeptEntryId]
      assert_includes client.seen_messages.last.last[:content], "Additional focus: focus"
      live_messages = rpc_session.conversation.messages.reject { |message| (message["role"] || message[:role]) == "system" }
      assert_equal ["compactionSummary", "user", "assistant"], live_messages.map { |message| message[:role] || message["role"] }
      assert_includes live_messages.first[:summary], "summary"
      records = jsonl_records(session[:path])
      assert records.any? { |record| record["type"] == "compaction" && record["message"]["role"] == "compactionSummary" && record["message"]["summary"].to_s.include?("summary") }

      event_types = server.notifications.select { |notification| notification[:method] == "session/event" }.map { |notification| notification[:params][:type] }
      assert_equal ["compactionStart", "compactionEnd"], event_types
      end_payload = server.notifications.last[:params][:payload]
      assert_equal false, end_payload[:aborted]
      assert_equal result, end_payload[:result]

      resumed = manager.resume_session(path: session[:path], workspace_root: Dir.pwd)
      transcript_message = manager.transcript(session_id: resumed[:id])[:messages].first
      assert_equal "compactionSummary", transcript_message[:role]
      assert_includes transcript_message[:summary], "summary"
    end
  end

  def test_session_fork_messages_returns_stable_user_entries
    Dir.mktmpdir do |config_dir|
      manager = Kward::RPC::SessionManager.new(server: RecordingServer.new, client: FakeClient.new([]), config_dir: config_dir)
      session = manager.create_session(workspace_root: Dir.pwd)
      rpc_session = manager.send(:fetch_session, session[:id])
      rpc_session.conversation.append_user("first prompt\nwith spaces")
      rpc_session.conversation.append_assistant("reply")
      rpc_session.conversation.append_user("second prompt")

      before = manager.fork_messages(session_id: session[:id])[:messages]
      rpc_session.conversation.append_user("third prompt")
      after = manager.fork_messages(session_id: session[:id])[:messages]

      assert_equal 2, before.length
      assert before.all? { |message| message[:entryId].to_s.match?(/\A[0-9a-f]{8}\z/) }
      assert_equal "first prompt with spaces", before.first[:text]
      assert_equal before.map { |message| message[:entryId] }, after.first(2).map { |message| message[:entryId] }
      assert after.last[:entryId].to_s.match?(/\A[0-9a-f]{8}\z/)
    end
  end

  def test_session_fork_creates_independent_session_and_returns_selected_text
    Dir.mktmpdir do |config_dir|
      workspace_root = File.realpath(Dir.mktmpdir)
      manager = Kward::RPC::SessionManager.new(server: RecordingServer.new, client: FakeClient.new([]), config_dir: config_dir)
      source = manager.create_session(workspace_root: workspace_root)
      source_rpc = manager.send(:fetch_session, source[:id])
      source_rpc.conversation.append_user("keep this")
      source_rpc.conversation.append_assistant("kept reply")
      source_rpc.conversation.append_user("edit this prompt")
      source_rpc.conversation.append_assistant("future reply")

      fork = manager.fork_session(session_id: source[:id], entry_id: "message:2")
      fork_rpc = manager.send(:fetch_session, fork[:session][:id])

      assert_equal "edit this prompt", fork[:text]
      assert_equal false, fork[:cancelled]
      refute_equal source[:persistentId], fork[:session][:persistentId]
      refute_equal source[:path], fork[:session][:path]
      refute_same source_rpc.conversation, fork_rpc.conversation
      assert_equal ["keep this", "kept reply"], fork_rpc.conversation.messages.reject { |message| message[:role] == "system" || message["role"] == "system" }.map { |message| message[:content] || message["content"] }

      fork_rpc.conversation.append_user("fork only")
      source_rpc.conversation.append_user("source only")

      source_records = jsonl_records(source[:path]).to_s
      fork_records = jsonl_records(fork[:session][:path]).to_s
      assert_includes source_records, "edit this prompt"
      assert_includes source_records, "source only"
      refute_includes source_records, "fork only"
      assert_includes fork_records, "keep this"
      assert_includes fork_records, "fork only"
      refute_includes fork_records, "edit this prompt"
      refute_includes fork_records, "source only"
    ensure
      FileUtils.remove_entry(workspace_root) if workspace_root && File.exist?(workspace_root)
    end
  end

  class FakeSessionTrash
    def initialize(&block)
      @block = block
    end

    def delete(path)
      @block.call(path)
      File.delete(path)
      true
    end
  end

end
