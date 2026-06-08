require_relative "test_support"

class TestRPCSessionManager < KwardTestCase
  include KwardRPCTestSupport

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

  def test_session_list_hides_active_empty_unnamed_session
    Dir.mktmpdir do |config_dir|
      workspace_root = File.realpath(Dir.mktmpdir)
      manager = Kward::RPC::SessionManager.new(server: RecordingServer.new, client: FakeClient.new([]), config_dir: config_dir)
      session = manager.create_session(workspace_root: workspace_root)

      sessions = manager.list_sessions(workspace_root: workspace_root, limit: 10)

      assert_empty sessions
      assert_path_exists session[:path]
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
      source = manager.create_session(workspace_root: workspace_root)
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
      assert_equal 0, listed_source[:depth]
      assert_equal 1, listed_clone[:depth]
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
      assert_equal "message:2", result[:firstKeptEntryId]
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

      assert_equal ["message:0", "message:2"], before.map { |message| message[:entryId] }
      assert_equal "first prompt with spaces", before.first[:text]
      assert_equal before.map { |message| message[:entryId] }, after.first(2).map { |message| message[:entryId] }
      assert_equal "message:3", after.last[:entryId]
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
end
