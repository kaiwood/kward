require "shellwords"
require_relative "../test_helper"

class TestCLIComposerStatus < KwardTestCase
  def hide_composer_git_branch(cli)
    cli.define_singleton_method(:composer_git_branch_text) { nil }
  end

  class BusyPrompt < FakePrompt
    def initialize(inputs)
      super(inputs)
      @redraw_count = 0
      @busy = false
    end

    def begin_busy_input(_message, activity: "streaming")
      @busy = true
    end

    def finish_busy_input
      @busy = false
    end

    def poll_input
      @inputs.shift
    end

    def start_stream_block(_label)
    end

    def write_delta(_delta)
    end

    def finish_stream_block
    end

    def close
    end
  end

  class EventAgent
    def initialize(events, answer: "")
      @events = events
      @answer = answer
    end

    def ask(_input, **_options)
      @events.each { |event| yield event } if block_given?
      { "role" => "assistant", "content" => @answer }
    end
  end

  def test_composer_status_includes_git_branch_before_session_diff
    skip "git is not available" unless system("git", "--version", out: File::NULL, err: File::NULL)

    Dir.mktmpdir do |workspace|
      system("git", "init", "-b", "main", chdir: workspace, out: File::NULL, err: File::NULL)
      system("git", "config", "user.email", "test@example.com", chdir: workspace, out: File::NULL, err: File::NULL)
      system("git", "config", "user.name", "Test User", chdir: workspace, out: File::NULL, err: File::NULL)
      File.write(File.join(workspace, "file.txt"), "one\n")
      system("git", "add", "file.txt", chdir: workspace, out: File::NULL, err: File::NULL)
      system("git", "commit", "-m", "initial", chdir: workspace, out: File::NULL, err: File::NULL)
      context_usage = Object.new
      def context_usage.call(**_kwargs)
        { percent: 42 }
      end
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), client: FakeClient.new([]), context_usage: context_usage)
      cli.instance_variable_set(:@working_directory, workspace)
      cli.instance_variable_set(:@session_diff, Kward::SessionDiff.new(additions: 7, deletions: 5))

      assert_equal "main · +7|-5 · 42% · Codex fake-model · medium", strip_ansi(cli.send(:composer_status_text))
    end
  end

  def test_composer_status_colors_dirty_git_branch
    skip "git is not available" unless system("git", "--version", out: File::NULL, err: File::NULL)

    Dir.mktmpdir do |workspace|
      system("git", "init", "-b", "main", chdir: workspace, out: File::NULL, err: File::NULL)
      File.write(File.join(workspace, "dirty.txt"), "dirty\n")
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), client: FakeClient.new([]))
      cli.instance_variable_set(:@working_directory, workspace)
      cli.instance_variable_set(:@color_enabled, true)

      assert_includes cli.send(:composer_status_text), "\e[33mmain\e[0m · Codex fake-model"
    end
  end

  def test_composer_status_hides_git_branch_outside_repository
    Dir.mktmpdir do |workspace|
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), client: FakeClient.new([]))
      cli.instance_variable_set(:@working_directory, workspace)

      assert_equal "Codex fake-model · medium", cli.send(:composer_status_text)
    end
  end

  def test_composer_status_falls_back_to_git_sha_without_branch
    skip "git is not available" unless system("git", "--version", out: File::NULL, err: File::NULL)

    Dir.mktmpdir do |workspace|
      system("git", "init", "-b", "main", chdir: workspace, out: File::NULL, err: File::NULL)
      system("git", "config", "user.email", "test@example.com", chdir: workspace, out: File::NULL, err: File::NULL)
      system("git", "config", "user.name", "Test User", chdir: workspace, out: File::NULL, err: File::NULL)
      File.write(File.join(workspace, "file.txt"), "one\n")
      system("git", "add", "file.txt", chdir: workspace, out: File::NULL, err: File::NULL)
      system("git", "commit", "-m", "initial", chdir: workspace, out: File::NULL, err: File::NULL)
      sha = `git -C #{Shellwords.escape(workspace)} rev-parse --short HEAD`.strip
      system("git", "checkout", "--detach", "HEAD", chdir: workspace, out: File::NULL, err: File::NULL)
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), client: FakeClient.new([]))
      cli.instance_variable_set(:@working_directory, workspace)

      assert_equal "#{sha} · Codex fake-model · medium", strip_ansi(cli.send(:composer_status_text))
    end
  end

  def test_composer_status_includes_context_percentage_when_available
    context_usage = Object.new
    def context_usage.call(**_kwargs)
      { percent: 12.4 }
    end
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), client: FakeClient.new([]), context_usage: context_usage)
    hide_composer_git_branch(cli)
    conversation = Kward::Conversation.new(system_message: nil)
    conversation.append_user("Status report.")
    cli.instance_variable_set(:@footer_conversation, conversation)

    assert_equal "12% · Codex fake-model · medium", cli.send(:composer_status_text)
  end

  def test_composer_status_uses_resumed_session_runtime_over_client_defaults
    context_usage = Object.new
    def context_usage.call(provider:, model:, context_window:, context_parts:)
      @seen = { provider: provider, model: model, context_window: context_window, context_parts: context_parts }
      { percent: 12.4 }
    end
    def context_usage.seen
      @seen
    end
    client = Kward::Client.new(api_key: nil, openai_access_token: "token", oauth: FakeOAuth.new(nil), config_path: "missing_kward_config.json")
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), client: client, context_usage: context_usage)
    hide_composer_git_branch(cli)
    conversation = Kward::Conversation.new(system_message: nil, provider: "Anthropic", model: "claude-sonnet-4-6", reasoning_effort: "low")
    conversation.append_user("Status report.")
    cli.instance_variable_set(:@footer_conversation, conversation)

    assert_equal "12% · Anthropic claude-sonnet-4-6 · low", cli.send(:composer_status_text)
    assert_equal "Anthropic", context_usage.seen[:provider]
    assert_equal "claude-sonnet-4-6", context_usage.seen[:model]
    assert_equal Kward::ModelInfo.context_window("Anthropic", "claude-sonnet-4-6"), context_usage.seen[:context_window]
    assert_equal "Anthropic", context_usage.seen[:context_parts][:provider]
    assert context_usage.seen[:context_parts].key?(:system)
  end

  def test_composer_status_colors_context_percentage_by_threshold
    context_usage = Object.new
    percent = 49
    context_usage.define_singleton_method(:call) do |**_kwargs|
      { percent: percent }
    end
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), client: FakeClient.new([]), context_usage: context_usage)
    hide_composer_git_branch(cli)
    cli.instance_variable_set(:@color_enabled, true)

    assert_includes cli.send(:composer_status_text), "49% · Codex fake-model"
    refute_includes cli.send(:composer_status_text), "\e["

    percent = 50
    assert_includes cli.send(:composer_status_text), "\e[33m50%\e[0m · Codex fake-model"

    percent = 85
    assert_includes cli.send(:composer_status_text), "\e[31m85%\e[0m · Codex fake-model"
  end

  def test_composer_status_hides_context_percentage_when_unavailable
    context_usage = Object.new
    def context_usage.call(**_kwargs)
      nil
    end
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), client: FakeClient.new([]), context_usage: context_usage)
    hide_composer_git_branch(cli)

    assert_equal "Codex fake-model · medium", cli.send(:composer_status_text)
  end

  def test_composer_status_shows_reasoning_for_copilot_gpt_5_responses_models
    client = FakeClient.new([])
    client.provider = "Copilot"
    client.model = "gpt-5-mini"
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), client: client)
    hide_composer_git_branch(cli)

    assert_equal "Copilot gpt-5-mini · medium", cli.send(:composer_status_text)
  end

  def test_composer_status_keeps_reasoning_unavailable_for_copilot_chat_models
    client = FakeClient.new([])
    client.provider = "Copilot"
    client.model = "gemini-2.5-pro"
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), client: client)
    hide_composer_git_branch(cli)

    assert_equal "Copilot gemini-2.5-pro · n/a", cli.send(:composer_status_text)
  end

  def test_composer_status_shows_session_diff_before_context_percentage
    context_usage = Object.new
    def context_usage.call(**_kwargs)
      { percent: 42 }
    end
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), client: FakeClient.new([]), context_usage: context_usage)
    hide_composer_git_branch(cli)
    cli.instance_variable_set(:@session_diff, Kward::SessionDiff.new(additions: 700, deletions: 572))

    assert_equal "+700|-572 · 42% · Codex fake-model · medium", strip_ansi(cli.send(:composer_status_text))
  end

  def test_composer_status_colors_session_diff
    context_usage = Object.new
    def context_usage.call(**_kwargs)
      nil
    end
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), client: FakeClient.new([]), context_usage: context_usage)
    cli.instance_variable_set(:@color_enabled, true)
    cli.instance_variable_set(:@session_diff, Kward::SessionDiff.new(additions: 7, deletions: 5))

    assert_includes cli.send(:composer_status_text), "\e[32m+7\e[0m|\e[31m-5\e[0m · Codex fake-model"
  end

  def test_prompt_interface_tool_result_updates_session_diff_and_redraws
    prompt = BusyPrompt.new([])
    content = "Edited file.txt\n--- file.txt\n+++ file.txt\n@@ -1,1 +1,2 @@\n-old\n+new\n+extra\n"
    agent = EventAgent.new([Kward::Events::ToolResult.new(tool_call: tool_call("edit_file", path: "file.txt"), content: content)])
    context_usage = Object.new
    def context_usage.call(**_kwargs)
      { percent: 10 }
    end
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([]), context_usage: context_usage)
    hide_composer_git_branch(cli)

    cli.send(:run_interactive_turn, agent, "hello")

    assert_equal 1, prompt.redraw_count
    assert_equal "+2|-1 · 10% · Codex fake-model · medium", strip_ansi(cli.send(:composer_status_text))
  end

  def test_prompt_interface_ignores_non_mutation_tool_result_diff_text
    prompt = BusyPrompt.new([])
    content = "Exit status: 0\n\nSTDOUT:\n--- file.txt\n+++ file.txt\n@@ -1,25 +0,0 @@\n" + (1..25).map { |index| "-line #{index}\n" }.join
    agent = EventAgent.new([Kward::Events::ToolResult.new(tool_call: tool_call("run_shell_command", command: "git diff"), content: content)])
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([]))
    hide_composer_git_branch(cli)

    cli.send(:run_interactive_turn, agent, "hello")

    assert_equal 0, prompt.redraw_count
    assert_equal "Codex fake-model · medium", strip_ansi(cli.send(:composer_status_text))
  end

end
