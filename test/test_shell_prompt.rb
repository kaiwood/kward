require_relative "test_helper"

class TestShellPrompt < KwardTestCase
  def test_shell_context_tracks_the_last_command_and_bounded_output
    shell = Kward::Kwsh.new(cwd: Dir.pwd, shell: "/bin/sh")

    shell.run_for_agent("printf ready")
    context = shell.context_snapshot(max_output_bytes: 8)

    assert_equal "printf ready", context[:last_command]
    assert_equal 0, context[:exit_status]
    assert_operator context[:last_output].bytesize, :<=, 8
  end

  def test_shell_prompt_session_prepares_without_executing
    Dir.mktmpdir("shell-prompt") do |dir|
      nested = File.join(dir, "nested")
      Dir.mkdir(nested)
      shell = Kward::Kwsh.new(cwd: dir, shell: "/bin/sh")
      session = Kward::ShellPromptSession.new(shell)

      session.prepare("cd nested")

      assert_equal "cd nested", session.prepared_command
      assert_equal dir, shell.cwd
    end
  end

  def test_shell_prompt_session_runs_commands_in_the_shell_state
    Dir.mktmpdir("shell-prompt") do |dir|
      nested = File.join(dir, "nested")
      Dir.mkdir(nested)
      shell = Kward::Kwsh.new(cwd: dir, shell: "/bin/sh")
      session = Kward::ShellPromptSession.new(shell)

      output = session.run("cd nested")

      assert_includes output, "Exit status: 0"
      assert_includes output, nested
      assert_equal nested, shell.cwd
    end
  end

  def test_shell_prompt_session_preserves_environment_changes
    shell = Kward::Kwsh.new(cwd: Dir.pwd, shell: "/bin/sh")
    session = Kward::ShellPromptSession.new(shell)

    session.run("export KWARD_SHELL_PROMPT=ready")
    output = session.run("printf %s \\\"$KWARD_SHELL_PROMPT\\\"")

    assert_includes output, "ready"
  end

  def test_shell_prompt_registry_exposes_shared_shell_tools_without_file_writes
    Dir.mktmpdir("shell-prompt") do |dir|
      shell = Kward::Kwsh.new(cwd: dir, shell: "/bin/sh")
      shell_prompt = Kward::ShellPromptSession.new(shell)
      registry = Kward::ToolRegistry.new(
        workspace: Kward::Workspace.new(root: dir),
        web_search_enabled: false,
        skills: []
      ).for_shell_prompt(shell_prompt)
      names = registry.schemas.map { |schema| schema.dig(:function, :name) }

      assert_includes names, "run_shell_command"
      assert_includes names, "prepare_shell_command"
      refute_includes names, "write_file"
      refute_includes names, "edit_file"

      conversation = Kward::Conversation.new(system_message: nil)
      registry.dispatch(tool_call("prepare_shell_command", command: "pwd"), conversation)

      assert_equal "pwd", shell_prompt.prepared_command
    end
  end

  def test_cli_shell_prompt_passes_context_and_prefills_prepared_command
    Dir.mktmpdir("shell-prompt") do |dir|
      prompt = FakePrompt.new([])
      client = RecordingClient.new([
        assistant_tool_call("prepare_shell_command", command: "find . -name '*.rb'"),
        "Prepared."
      ])
      shell = Kward::Kwsh.new(cwd: dir, shell: "/bin/sh")
      shell.run_for_agent("printf previous-error")
      conversation = Kward::Conversation.new(system_message: nil, workspace_root: dir)
      agent = Kward::Agent.new(
        client: client,
        conversation: conversation,
        tool_registry: Kward::ToolRegistry.new(workspace: Kward::Workspace.new(root: dir))
      )
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client)

      pending = cli.send(:run_shell_prompt_turn, "? prepare a search", shell, agent)

      assert_empty pending
      assert_equal ["find . -name '*.rb'"], prompt.prefilled_inputs
      assert_includes client.seen_messages.first.last[:content], "previous-error"
      assert_includes client.seen_messages.first.last[:content], "prepare a search"
      refute_includes agent.conversation.messages.map { |message| message[:content].to_s }, "prepare a search"
    end
  end

  def test_cli_shell_loop_routes_question_input_to_the_shell_agent
    Dir.mktmpdir("shell-prompt") do |dir|
      prompt = FakePrompt.new(["? explain the previous failure", "exit"])
      client = RecordingClient.new(["The previous command failed."])
      conversation = Kward::Conversation.new(system_message: nil, workspace_root: dir)
      agent = Kward::Agent.new(
        client: client,
        conversation: conversation,
        tool_registry: Kward::ToolRegistry.new(workspace: Kward::Workspace.new(root: dir))
      )
      shell = Kward::PersistentShellSession.new(cwd: dir, shell: "/bin/sh")
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client)
      shell_agent = cli.send(:build_shell_prompt_agent, agent)

      assert_equal :exited, cli.send(:run_kwsh_loop, shell, shell_agent: shell_agent)

      assert_includes prompt.output.join, "The previous command failed."
      assert_equal 2, shell_agent.conversation.messages.length
      assert_equal "? explain the previous failure", shell_agent.conversation.messages.first[:display_content]
    end
  end

  def test_cli_shell_prompt_executes_explicit_cd_in_shared_state
    Dir.mktmpdir("shell-prompt") do |dir|
      nested = File.join(dir, "nested")
      Dir.mkdir(nested)
      prompt = FakePrompt.new([])
      client = RecordingClient.new([
        assistant_tool_call("run_shell_command", command: "cd nested"),
        "Changed directory."
      ])
      shell = Kward::PersistentShellSession.new(cwd: dir, shell: "/bin/sh")
      conversation = Kward::Conversation.new(system_message: nil, workspace_root: dir)
      agent = Kward::Agent.new(
        client: client,
        conversation: conversation,
        tool_registry: Kward::ToolRegistry.new(workspace: Kward::Workspace.new(root: dir))
      )
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client)

      cli.send(:run_shell_prompt_turn, "? cd into nested", shell, agent)

      assert_equal nested, shell.cwd
      assert_empty prompt.prefilled_inputs
    ensure
      shell&.close
    end
  end
end
