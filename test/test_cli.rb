require_relative "test_helper"

class TestCLI < KwardTestCase
  def test_one_shot_renders_markdown_without_streaming
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), client: FakeClient.new([{ "role" => "assistant", "content" => "# Plan\nRun `bundle test`.\n" }]))
    cli.instance_variable_set(:@color_enabled, true)

    output = cli.one_shot("hello")

    assert_includes output, "\e[1m# Plan\e[0m"
    assert_includes output, "`\e[2mbundle test\e[0m`"
  end

  def test_streamed_interactive_turn_renders_markdown_after_buffering
    prompt = FakePrompt.new([])
    client = MarkdownStreamingClient.new(["# Pla", "n\n```ruby\n", "puts :ok\n```\n"])
    agent = Kward::Agent.new(client: client, tool_registry: Kward::ToolRegistry.new(prompt: prompt))
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client)
    cli.instance_variable_set(:@color_enabled, true)

    output = capture_io do
      cli.send(:run_blocking_interactive_turn, agent, "hello")
    end.first

    assert_includes output, "\e[1m# Plan\e[0m"
    assert_includes output, "\e[90m┌─ code ruby\e[0m"
    assert_includes output, "\e[2m│ puts :ok\e[0m"
  end

  def test_transcript_block_renders_markdown_when_colored
    prompt = FakePrompt.new([])
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([]))
    cli.instance_variable_set(:@color_enabled, true)

    cli.send(:render_transcript_block, "Assistant", "## Plan\nRun `bundle test`.\n")

    output = prompt.output.join("\n")
    assert_includes output, "\e[1m## Plan\e[0m"
    assert_includes output, "`\e[2mbundle test\e[0m`"
  end

  def test_cli_colors_stream_labels_when_forced
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), client: FakeClient.new([]))
    cli.instance_variable_set(:@color_enabled, true)
    output = capture_io do
      cli.send(:start_stream_block, "Assistant")
    end.first

    assert_includes output, "\e[32;1mAssistant>\e[0m"
  end

  def test_module_split_keeps_one_shot_mode_working
    cli = Kward::CLI.new(argv: ["hello"], stdin: FakeInput.new("", tty: true), client: FakeClient.new([{ "role" => "assistant", "content" => "hi" }]))

    assert_equal "hi", cli.one_shot("hello")
  end

  def test_rpc_subcommand_starts_rpc_server
    initialize_body = JSON.generate({ jsonrpc: "2.0", id: 1, method: "initialize" })
    shutdown_body = JSON.generate({ jsonrpc: "2.0", id: 2, method: "shutdown" })
    stdin = StringIO.new("Content-Length: #{initialize_body.bytesize}\r\n\r\n#{initialize_body}Content-Length: #{shutdown_body.bytesize}\r\n\r\n#{shutdown_body}")
    cli = Kward::CLI.new(argv: ["rpc"], stdin: stdin, client: FakeClient.new([]))

    output = capture_io { cli.run }.first

    assert_includes output, '"protocolVersion":1'
    assert_includes output, '"ok":true'
  end

  def test_interactive_conversation_history_still_works
    prompt = FakePrompt.new(["hello", "again", "/exit"])
    client = RecordingClient.new(["reply 1", "reply 2"])
    agent = Kward::Agent.new(client: client, tool_registry: Kward::ToolRegistry.new(prompt: prompt))
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client)

    conversation = cli.interactive_loop(agent: agent)

    assert_equal "hello", client.seen_messages[0][1][:content]
    assert_equal "reply 1", client.seen_messages[1][2]["content"]
    assert_equal "again", client.seen_messages[1][3][:content]
    assert_equal 5, conversation.messages.length
  end

  def test_interactive_mode_persists_session_jsonl
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      prompt = FakePrompt.new(["hello", "/exit"])
      client = RecordingClient.new(["reply"])
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client, session_store: store)

      cli.interactive_loop

      files = Dir.glob(File.join(store.session_dir, "*.jsonl"))
      assert_equal 1, files.length
      records = jsonl_records(files.first)
      assert_equal "session", records[0]["type"]
      assert_equal "hello", records[1]["message"]["content"]
      assert_equal "reply", records[2]["message"]["content"]
    end
  end

  def test_unused_session_removed_on_exit
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      prompt = FakePrompt.new(["/exit"])
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: RecordingClient.new([]), session_store: store)

      cli.interactive_loop

      assert_empty Dir.glob(File.join(store.session_dir, "*.jsonl"))
    end
  end

  def test_new_command_clears_prompt_transcript
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      output = StringIO.new
      input, writer = IO.pipe
      writer.write("hello\r/new\r/exit\r")
      writer.close
      prompt = Kward::PromptInterface.new(input: input, output: output)
      client = RecordingClient.new(["reply"])
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client, session_store: store)

      cli.interactive_loop

      assert_includes strip_ansi(output.string), "You> hello"
      assert_includes output.string, TTY::Cursor.clear_screen
      after_clear = output.string.split(TTY::Cursor.clear_screen).last
      refute_includes strip_ansi(after_clear), "You> hello"
      refute_includes strip_ansi(after_clear), "Assistant>"
      assert_includes strip_ansi(after_clear), "Started new session:"
    ensure
      input&.close unless input&.closed?
    end
  end

  def test_non_empty_session_kept_on_exit
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      prompt = FakePrompt.new(["hello", "/exit"])
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: RecordingClient.new(["reply"]), session_store: store)

      cli.interactive_loop

      files = Dir.glob(File.join(store.session_dir, "*.jsonl"))
      assert_equal 1, files.length
      assert jsonl_records(files.first).any? { |record| record["type"] == "message" && record["message"]["role"] == "user" }
    end
  end

  def test_named_empty_session_kept_on_exit
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      prompt = FakePrompt.new(["/name Useful", "/exit"])
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: RecordingClient.new([]), session_store: store)

      cli.interactive_loop

      files = Dir.glob(File.join(store.session_dir, "*.jsonl"))
      assert_equal 1, files.length
      assert jsonl_records(files.first).any? { |record| record["type"] == "session_info" && record["name"] == "Useful" }
    end
  end

  def test_quit_exits_like_exit
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      client = RecordingClient.new([])
      prompt = FakePrompt.new(["/quit"])
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client, session_store: store)

      cli.interactive_loop

      assert_empty client.seen_messages
      assert_empty Dir.glob(File.join(store.session_dir, "*.jsonl"))
    end
  end

  def test_one_shot_does_not_create_session_file
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      client = RecordingClient.new(["reply"])
      cli = Kward::CLI.new(argv: ["hello"], stdin: FakeInput.new("", tty: true), client: client, session_store: store)

      assert_equal "reply", cli.one_shot("hello")

      refute Dir.exist?(store.session_dir)
    end
  end

  def test_one_shot_executes_tool_calls
    client = RecordingClient.new([
      assistant_tool_call("read_file", path: "README.md"),
      "README summary"
    ])
    cli = Kward::CLI.new(argv: ["read README"], stdin: FakeInput.new("", tty: true), client: client)

    output = capture_io do
      assert_equal "README summary", cli.one_shot("read README")
    end.first

    assert_equal 2, client.seen_messages.length
    assert_equal "tool", client.seen_messages[1][3][:role]
    assert_equal "call_read_file", client.seen_messages[1][3][:tool_call_id]
    assert_equal "read_file", client.seen_messages[1][3][:name]
    assert_includes client.seen_messages[1][3][:content], "# Ruby CLI Agent"
    assert_includes output, "Tool>"
    assert_includes output, "Tool output>"
  end

  def test_resume_explicit_session_path_loads_prior_messages
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      saved = store.create
      conversation = Kward::Conversation.new
      saved.attach(conversation)
      conversation.append_user("hello")
      conversation.append_assistant("reply")
      prompt = FakePrompt.new(["/resume #{saved.path}", "again", "/exit"])
      client = RecordingClient.new(["second"])
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client, session_store: store)

      cli.interactive_loop

      assert_equal "hello", client.seen_messages[0][1]["content"]
      assert_equal "reply", client.seen_messages[0][2]["content"]
      assert_equal "again", client.seen_messages[0][3][:content]
      output = prompt.output.join("\n")
      assert_includes output, "You> hello"
      assert_includes output, "Assistant>\nreply"
    end
  end

  def test_resume_renders_reasoning_tools_and_tool_output
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      saved = store.create
      conversation = Kward::Conversation.new
      saved.attach(conversation)
      conversation.append_user("inspect file")
      conversation.append_assistant({
        "role" => "assistant",
        "content" => "I'll read it.",
        "reasoning_summary" => "Need to inspect the file.",
        "tool_calls" => [tool_call("read_file", path: "README.md")]
      })
      conversation.append_tool(tool_call_id: "call_read_file", name: "read_file", content: "README contents\n")
      prompt = FakePrompt.new(["/resume #{saved.path}", "/exit"])
      client = RecordingClient.new([])
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client, session_store: store)

      cli.interactive_loop

      output = prompt.output.join("\n")
      assert_includes output, "You> inspect file"
      assert_includes output, "Reasoning>\nNeed to inspect the file."
      assert_includes output, "Assistant>\nI'll read it."
      assert_includes output, "Tool>\nread_file"
      assert_includes output, "Tool output>\nread_file: README.md"
      assert_includes output, "1 lines, 16 bytes"
      refute_includes output, "README contents"
    end
  end

  def test_tool_output_display_uses_compact_summaries
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: FakePrompt.new([]), client: FakeClient.new([]))

    read_output = capture_io do
      cli.send(:print_tool_result, tool_call("read_file", path: "README.md"), "line one\nline two\n")
    end.first
    assert_includes read_output, "read_file: README.md"
    assert_includes read_output, "2 lines, 18 bytes"
    refute_includes read_output, "line one"

    shell_output = capture_io do
      cli.send(:print_tool_result, tool_call("run_shell_command", command: "echo ok"), "Exit status: 0\n\nSTDOUT:\nok\n\nSTDERR:\nwarn\n")
    end.first
    assert_includes shell_output, "run_shell_command: echo ok"
    assert_includes shell_output, "Exit status: 0"
    assert_includes shell_output, "stdout (3 bytes):\nok"
    assert_includes shell_output, "stderr (5 bytes):\nwarn"

    research_output = capture_io do
      cli.send(:print_tool_result, tool_call("web_research", queries: ["ruby"]), "# Web research\n\n## Query: ruby\n1. Ruby\n   URL: https://ruby-lang.org\n")
    end.first
    assert_includes research_output, "web_research"
    assert_includes research_output, "ruby: 1 result(s)"
  end

  def test_session_commands_name_clone_and_export
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      export_path = File.join(config_dir, "session.md")
      prompt = FakePrompt.new(["hello", "/name Useful", "/clone", "/export #{export_path}", "/exit"])
      client = RecordingClient.new(["reply"])
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client, session_store: store)

      cli.interactive_loop

      files = Dir.glob(File.join(store.session_dir, "*.jsonl"))
      assert_equal 2, files.length
      assert files.any? { |file| jsonl_records(file).any? { |record| record["type"] == "session_info" && record["name"] == "Useful" } }
      output = prompt.output.join("\n")
      assert_includes output, "You> hello"
      assert_includes output, "Assistant>\nreply"
      assert_includes File.read(export_path), "## User\n\nhello"
      assert_includes File.read(export_path), "## Assistant\n\nreply"
    end
  end

  def test_export_renders_compaction_summary_content
    Dir.mktmpdir do |config_dir|
      export_path = File.join(config_dir, "session.md")
      conversation = Kward::Conversation.new(system_message: nil)
      conversation.compact!("summary content", compaction_summary: true)
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: FakePrompt.new([]), client: RecordingClient.new([]))

      cli.send(:export_session, conversation, export_path)

      assert_includes File.read(export_path), "## Compactionsummary\n\nsummary content"
    end
  end

  def test_compact_command_summarizes_context_before_next_turn
    Dir.mktmpdir do |config_dir|
      config_path = File.join(config_dir, "config.json")
      File.write(config_path, JSON.dump({ "compaction" => { "keep_recent_tokens" => 20 } }))
      prompt = FakePrompt.new(["hello with enough detail to compact", "second turn before compaction", "/compact focus on files", "again", "/exit"])
      client = RecordingClient.new(["reply", "second reply", "summary", "after"])
      agent = Kward::Agent.new(client: client, tool_registry: Kward::ToolRegistry.new(prompt: prompt))
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client)

      conversation = nil
      with_env("KWARD_CONFIG_PATH" => config_path) do
        conversation = cli.interactive_loop(agent: agent)
      end

      refute client.seen_messages.flatten.any? { |message| message.is_a?(Hash) && message[:content] == "/compact focus on files" }
      assert_includes client.seen_messages[2].last[:content], "Additional focus: focus on files"
      summary_message = client.seen_messages[3].find { |message| (message[:role] || message["role"]) == "compactionSummary" }
      assert summary_message
      assert_includes summary_message[:summary], "summary"
      assert_equal "again", client.seen_messages[3].last[:content]
      assert_equal "after", conversation.messages.last["content"]
      assert_includes prompt.output.join("\n"), "Compacted context:"
    end
  end

  def test_compact_command_reports_empty_context_without_calling_client
    prompt = FakePrompt.new(["/compact", "/exit"])
    client = RecordingClient.new([])
    agent = Kward::Agent.new(client: client, tool_registry: Kward::ToolRegistry.new(prompt: prompt))
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client)

    cli.interactive_loop(agent: agent)

    assert_empty client.seen_messages
    assert_includes prompt.output.join("\n"), "Nothing to compact"
  end

  def test_interactive_resume_can_select_recent_session
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      saved = store.create
      conversation = Kward::Conversation.new
      saved.attach(conversation)
      conversation.append_user("selected session")
      conversation.append_assistant("old reply")
      prompt = FakeSessionSelectPrompt.new(["/resume", "again", "/exit"], "selected session")
      client = RecordingClient.new(["new reply"])
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client, session_store: store)

      cli.interactive_loop

      assert_equal ["Session>"], prompt.select_messages
      assert_equal "selected session", client.seen_messages[0][1]["content"]
      assert_equal "again", client.seen_messages[0][3][:content]
    end
  end

  def test_resume_picker_shows_renamed_active_session_immediately
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      saved = store.create
      conversation = Kward::Conversation.new
      saved.attach(conversation)
      conversation.append_user("selected session")
      conversation.append_assistant("old reply")
      prompt = FakeSessionSelectPrompt.new(["/resume #{saved.path}", "/name Useful", "/resume", "/exit"], "Useful")
      client = RecordingClient.new([])
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client, session_store: store)

      cli.interactive_loop

      assert_equal ["Session>"], prompt.select_messages
      assert prompt.select_choices.first.any? { |choice| choice.start_with?("Useful —") }
    end
  end

  def test_interactive_prompt_slash_command_expands_template
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "config.json"), JSON.dump({}))
      prompts_dir = File.join(dir, "prompts")
      FileUtils.mkdir_p(prompts_dir)
      File.write(File.join(prompts_dir, "plan.md"), "---\ndescription: Plan work.\nargument-hint: <task>\n---\nPlan this:\n$ARGUMENTS\n")
      prompt = FakePrompt.new(["/plan fix bug", "/exit"])
      client = RecordingClient.new(["planned"])

      with_env("KWARD_CONFIG_PATH" => File.join(dir, "config.json")) do
        agent = Kward::Agent.new(client: client, tool_registry: Kward::ToolRegistry.new(prompt: prompt))
        cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client)

        cli.interactive_loop(agent: agent)
      end

      assert_equal "Plan this:\nfix bug\n", client.seen_messages[0][1][:content]
    end
  end

  def test_interactive_prompt_slash_command_allows_empty_arguments
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "config.json"), JSON.dump({}))
      prompts_dir = File.join(dir, "prompts")
      FileUtils.mkdir_p(prompts_dir)
      File.write(File.join(prompts_dir, "plan.md"), "Plan this:\n$ARGUMENTS\n")
      prompt = FakePrompt.new(["/plan", "/exit"])
      client = RecordingClient.new(["planned"])

      with_env("KWARD_CONFIG_PATH" => File.join(dir, "config.json")) do
        agent = Kward::Agent.new(client: client, tool_registry: Kward::ToolRegistry.new(prompt: prompt))
        cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client)

        cli.interactive_loop(agent: agent)
      end

      assert_equal "Plan this:\n\n", client.seen_messages[0][1][:content]
    end
  end

  def test_one_shot_does_not_expand_prompt_slash_command
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "config.json"), JSON.dump({}))
      prompts_dir = File.join(dir, "prompts")
      FileUtils.mkdir_p(prompts_dir)
      File.write(File.join(prompts_dir, "plan.md"), "Plan this:\n$ARGUMENTS\n")
      client = RecordingClient.new(["ok"])
      cli = Kward::CLI.new(argv: ["/plan fix bug"], stdin: FakeInput.new("", tty: true), client: client)

      with_env("KWARD_CONFIG_PATH" => File.join(dir, "config.json")) do
        cli.one_shot("/plan fix bug")
      end

      assert_equal "/plan fix bug", client.seen_messages[0][1][:content]
    end
  end

  def test_non_tui_slash_command_selection_expands_template
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "config.json"), JSON.dump({}))
      prompts_dir = File.join(dir, "prompts")
      FileUtils.mkdir_p(prompts_dir)
      File.write(File.join(prompts_dir, "plan.md"), "Plan this:\n$ARGUMENTS\n")
      prompt = FakeSelectPrompt.new(["/p", "/exit"])
      client = RecordingClient.new(["planned"])

      with_env("KWARD_CONFIG_PATH" => File.join(dir, "config.json")) do
        agent = Kward::Agent.new(client: client, tool_registry: Kward::ToolRegistry.new(prompt: prompt))
        cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client)

        cli.interactive_loop(agent: agent)
      end

      assert_equal "Plan this:\n\n", client.seen_messages[0][1][:content]
      assert_equal ["Slash command>"], prompt.select_messages
    end
  end

  def test_interactive_loop_redraw_command_refreshes_prompt
    prompt = FakePrompt.new(["/redraw", "/exit"])
    client = RecordingClient.new([])
    agent = Kward::Agent.new(client: client, tool_registry: Kward::ToolRegistry.new(prompt: prompt))
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client)

    cli.interactive_loop(agent: agent)

    assert_equal 1, prompt.redraw_count
    assert_empty client.seen_messages
  end

  def test_interactive_loop_exits_when_prompt_returns_nil
    prompt = FakePrompt.new([nil])
    client = RecordingClient.new([])
    agent = Kward::Agent.new(client: client, tool_registry: Kward::ToolRegistry.new(prompt: prompt))
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client)

    conversation = cli.interactive_loop(agent: agent)

    assert_empty client.seen_messages
    assert_equal Kward::Conversation.new.messages, conversation.messages
  end

  def test_interactive_turn_displays_pasted_image
    path = "kward_user_transcript.png"
    original_term_program = ENV["TERM_PROGRAM"]
    ENV.delete("TERM_PROGRAM")
    File.binwrite(path, "png bytes")
    prompt = FakePrompt.new([])
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([]))

    cli.send(:print_user_transcript, "look #{path}")

    assert_includes prompt.output.join("\n"), "You> look #{path}"
    assert_includes prompt.output.join("\n"), "\e_Ginline=1;preserveAspectRatio=1;width=40;name=#{Base64.strict_encode64(path)}:#{Base64.strict_encode64("png bytes")}\e\\"
  ensure
    original_term_program ? ENV["TERM_PROGRAM"] = original_term_program : ENV.delete("TERM_PROGRAM")
    File.delete(path) if path && File.exist?(path)
  end

  def test_interactive_turn_returns_prompt_queued_during_streaming
    input, writer = IO.pipe
    output = StringIO.new
    prompt = Kward::PromptInterface.new(input: input, output: output)
    client = StreamingRecordingClient.new(["reply 1"])
    agent = Kward::Agent.new(client: client, tool_registry: Kward::ToolRegistry.new(prompt: prompt))
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client)

    writer_thread = Thread.new do
      sleep 0.03
      writer.write("second\r")
      writer.close
    end

    queued = cli.send(:run_interactive_turn, agent, "first")

    assert_includes strip_ansi(output.string), "You> first"
    assert_equal ["second"], queued
    assert_equal "first", client.seen_messages[0][1][:content]
  ensure
    writer_thread&.join
    input&.close unless input&.closed?
  end

  def test_status_slash_command_prints_static_status_without_calling_client
    prompt = FakePrompt.new(["/status", "/exit"])
    client = RecordingClient.new([])
    agent = Kward::Agent.new(client: client, tool_registry: Kward::ToolRegistry.new(prompt: prompt))
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client)

    cli.interactive_loop(agent: agent)

    assert_includes prompt.output.join("\n"), Kward::CLI::STATUS_MESSAGE
    assert_empty client.seen_messages
  end

  def test_settings_slash_command_reports_unavailable_without_tui_prompt
    prompt = FakePrompt.new(["/settings", "/exit"])
    client = RecordingClient.new([])
    agent = Kward::Agent.new(client: client, tool_registry: Kward::ToolRegistry.new(prompt: prompt))
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client)

    cli.interactive_loop(agent: agent)

    assert_includes prompt.output.join("\n"), "Settings overlay is unavailable"
    assert_empty client.seen_messages
  end

  def test_settings_slash_command_persists_overlay_settings
    Dir.mktmpdir do |dir|
      config_path = File.join(dir, "config.json")
      File.write(config_path, JSON.dump({ "openai_model" => "existing" }))
      prompt = FakeSettingsPrompt.new(["/settings", "/exit"], ["Right", "Maximum"])
      client = RecordingClient.new([])
      agent = Kward::Agent.new(client: client, tool_registry: Kward::ToolRegistry.new(prompt: prompt))
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client)

      with_env("KWARD_CONFIG_PATH" => config_path) do
        cli.interactive_loop(agent: agent)
      end

      config = JSON.parse(File.read(config_path))
      assert_equal "existing", config["openai_model"]
      assert_equal({ "alignment" => "right", "width" => "maximum" }, config["overlay"])
      assert_equal [{ "alignment" => "right", "width" => "capped" }, { "alignment" => "right", "width" => "maximum" }], prompt.overlay_settings_updates
      assert_equal ["Overlay alignment", "Overlay width"], prompt.select_messages
      assert_equal ["Settings", "Settings"], prompt.select_titles
    end
  end

  def test_piped_prompt_reads_non_tty_input
    cli = Kward::CLI.new(stdin: FakeInput.new("hello from stdin\n", tty: false), client: FakeClient.new([]))

    assert_equal "hello from stdin", cli.piped_prompt
  end

  def test_piped_prompt_ignores_tty_input
    cli = Kward::CLI.new(stdin: FakeInput.new("ignored", tty: true), client: FakeClient.new([]))

    assert_equal "", cli.piped_prompt
  end

end
