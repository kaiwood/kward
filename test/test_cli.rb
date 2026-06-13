require_relative "test_helper"

class TestCLI < KwardTestCase
  class BannerPrompt < FakePrompt
    attr_reader :banner_count

    def initialize(inputs)
      super(inputs)
      @banner_count = 0
    end

    def print_visual_banner
      @banner_count += 1
      @output << "[visual banner]"
    end
  end

  class EventAgent
    def initialize(events, answer: "")
      @events = events
      @answer = answer
    end

    def ask(_input, **_options)
      @events.each { |event| yield event }
      @answer
    end
  end

  class PollingPrompt < FakePrompt
    def poll_input
      @inputs.shift
    end
  end

  class FailingSteering
    def submit(_input)
      raise "steering failed"
    end
  end

  class RecordingLoginCLI < Kward::CLI
    attr_reader :login_providers

    def initialize(*args, fail_login: false, **kwargs)
      super(*args, **kwargs)
      @fail_login = fail_login
      @login_providers = []
    end

    def login(provider: nil, oauth: nil)
      raise "OAuth timed out" if @fail_login

      @login_providers << provider
      @prompt.say("Saved #{provider} OAuth login")
    end
  end

  class BusyPrompt < FakePrompt
    attr_reader :events, :write_deltas

    def initialize(inputs)
      super(inputs)
      @events = []
      @write_deltas = []
      @stream_block = nil
    end

    def begin_busy_input(message, activity: "streaming")
      @events << [:begin_busy_input, message, activity]
    end

    def finish_busy_input
      @events << [:finish_busy_input]
    end

    def poll_input
      nil
    end

    def start_stream_block(label)
      return if @stream_block == label

      @stream_block = label
      @events << [:start_stream_block, label]
    end

    def write_delta(delta)
      @events << [:write_delta, delta]
      @write_deltas << delta
      @output << delta
    end

    def finish_stream_block
      @stream_block = nil
      @events << [:finish_stream_block]
    end

    def close
      @events << [:close]
    end
  end

  class BusySelectPrompt < BusyPrompt
    attr_reader :select_messages, :select_choices, :select_titles, :select_initial_indices

    def initialize(inputs, selections: [])
      super(inputs)
      @selections = selections
      @select_messages = []
      @select_choices = []
      @select_titles = []
      @select_initial_indices = []
    end

    def select(message, choices, title: "Sessions", custom: false, initial_index: 0)
      @select_messages << message
      @select_choices << choices
      @select_titles << title
      @select_initial_indices << initial_index
      @selections.empty? ? choices.first : @selections.shift
    end
  end

  class SlowModelsClient < FakeClient
    def available_models
      sleep 0.05
      super
    end
  end

  def with_clipboard_stub(copy_proc)
    original_new = Kward::Clipboard.method(:new)
    Kward::Clipboard.define_singleton_method(:new) do |**_kwargs|
      Object.new.tap do |clipboard|
        clipboard.define_singleton_method(:copy) { |text| copy_proc.call(text) }
      end
    end
    yield
  ensure
    Kward::Clipboard.define_singleton_method(:new, original_new)
  end

  def test_init_command_creates_default_config_and_reports_result
    Dir.mktmpdir do |config_dir|
      prompt = FakePrompt.new([])
      calls = []
      original_install = Kward::StarterPackInstaller.method(:install)
      Kward::StarterPackInstaller.define_singleton_method(:install) do
        calls << true
        Kward::StarterPackInstaller::Result.new(installed: ["AGENTS.md"], skipped: ["prompts/plan.md"])
      end

      with_env("KWARD_CONFIG_PATH" => File.join(config_dir, "config.json")) do
        Kward::CLI.new(argv: ["init"], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([])).run
      end

      assert_equal [true], calls
      assert_path_exists File.join(config_dir, "config.json")
      output = prompt.output.join("\n")
      assert_includes output, "Installed 1 starter pack file."
      assert_includes output, "Skipped 1 existing starter pack file."
    ensure
      Kward::StarterPackInstaller.define_singleton_method(:install, original_install) if original_install
    end
  end

  def test_install_starter_pack_flag_remains_as_compatibility_alias
    Dir.mktmpdir do |config_dir|
      prompt = FakePrompt.new([])
      calls = []
      original_install = Kward::StarterPackInstaller.method(:install)
      Kward::StarterPackInstaller.define_singleton_method(:install) do
        calls << true
        Kward::StarterPackInstaller::Result.new(installed: [], skipped: [])
      end

      with_env("KWARD_CONFIG_PATH" => File.join(config_dir, "config.json")) do
        Kward::CLI.new(argv: ["--install-starter-pack"], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([])).run
      end

      assert_equal [true], calls
    ensure
      Kward::StarterPackInstaller.define_singleton_method(:install, original_install) if original_install
    end
  end

  def test_interactive_response_prompt_falls_back_to_assistant_without_persona_label
    Dir.mktmpdir do |config_dir|
      File.write(File.join(config_dir, "config.json"), JSON.dump({}))
      prompt = FakePrompt.new(["hello", nil])
      client = FakeClient.new([{ "role" => "assistant", "content" => "reply" }])

      with_env("KWARD_CONFIG_PATH" => File.join(config_dir, "config.json")) do
        cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client)
        cli.interactive_loop(agent: Kward::Agent.new(client: client, tool_registry: Kward::ToolRegistry.new(prompt: prompt), conversation: Kward::Conversation.new))
      end

      output = strip_ansi(prompt.output.join)
      assert_includes output, "Assistant> reply"
      refute_includes output, "Kward> reply"
    end
  end

  def test_one_shot_renders_markdown_without_streaming
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), client: FakeClient.new([{ "role" => "assistant", "content" => "# Plan\nRun `bundle test`.\n" }]))
    cli.instance_variable_set(:@color_enabled, true)

    output = cli.one_shot("hello")

    assert_includes output, "# \e[1mPlan\e[0m"
    assert_includes output, "`\e[2mbundle test\e[0m`"
  end

  def test_login_github_uses_github_oauth_label
    prompt = FakePrompt.new([])
    oauth = Object.new
    oauth.define_singleton_method(:login) { |prompt:| "/tmp/github_auth.json" }
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([]))

    cli.login(provider: "github", oauth: oauth)

    assert_includes prompt.output.join, "GitHub OAuth login to /tmp/github_auth.json"
  end

  def test_login_openrouter_stores_api_key_in_config
    Dir.mktmpdir do |dir|
      path = File.join(dir, "config.json")
      prompt = FakePrompt.new(["sk-or-test"])
      auth = Kward::OpenRouterAPIKey.new(config_path: path)
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([]))

      cli.login(provider: "openrouter", oauth: auth)

      assert_equal "sk-or-test", JSON.parse(File.read(path))["openrouter_api_key"]
      assert_includes prompt.output.join, "OpenRouter API key to #{path}"
      refute_includes prompt.output.join, "sk-or-test"
    end
  end

  def test_login_picker_includes_openrouter
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: FakePrompt.new([]), client: FakeClient.new([]))

    assert_equal ["OpenAI", "OpenRouter", "GitHub"], cli.send(:login_provider_choices)
    assert_equal "openrouter", cli.send(:selected_login_provider, "OpenRouter")
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

    assert_includes output, "# \e[1mPlan\e[0m"
    assert_includes output, "\e[90m┌─ code ruby\e[0m"
    assert_includes output, "\e[2m│ puts :ok\e[0m"
  end

  def test_interactive_loop_runs_bang_shell_command_without_model_turn
    Dir.mktmpdir do |dir|
      prompt = FakePrompt.new(["!echo hello", "/exit"])
      conversation = Kward::Conversation.new(system_message: nil, workspace_root: dir)
      agent = Object.new
      agent.define_singleton_method(:conversation) { conversation }
      agent.define_singleton_method(:ask) { |_input, **_options| raise "model should not be called" }
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([]))

      cli.interactive_loop(agent: agent)

      output = strip_ansi(prompt.output.join)
      assert_includes output, "Shell> echo hello"
      assert_includes output, "Exit status: 0"
      assert_includes output, "STDOUT:\nhello"
      assert_empty conversation.messages
    end
  end

  def test_interactive_loop_runs_bang_shell_command_from_workspace_root
    Dir.mktmpdir do |dir|
      prompt = FakePrompt.new(["!pwd", "/exit"])
      conversation = Kward::Conversation.new(system_message: nil, workspace_root: dir)
      agent = Object.new
      agent.define_singleton_method(:conversation) { conversation }
      agent.define_singleton_method(:ask) { |_input, **_options| raise "model should not be called" }
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([]))

      cli.interactive_loop(agent: agent)

      output = strip_ansi(prompt.output.join)
      assert_includes output, "STDOUT:\n#{File.realpath(dir)}"
    end
  end

  def test_interactive_loop_reports_empty_bang_shell_command
    prompt = FakePrompt.new(["!", "/exit"])
    conversation = Kward::Conversation.new(system_message: nil)
    agent = Object.new
    agent.define_singleton_method(:conversation) { conversation }
    agent.define_singleton_method(:ask) { |_input, **_options| raise "model should not be called" }
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([]))

    cli.interactive_loop(agent: agent)

    assert_includes prompt.output.join, "Shell command is required after !"
    assert_empty conversation.messages
  end

  def test_interactive_loop_reports_turn_error_without_crashing
    prompt = BusyPrompt.new(["hello", "/exit"])
    conversation = Kward::Conversation.new(system_message: nil)
    agent = Object.new
    agent.define_singleton_method(:conversation) { conversation }
    agent.define_singleton_method(:ask) do |_input, **_options|
      raise Kward::Client::RequestError.new(provider: "Copilot", code: 400, body: JSON.dump("error" => { "code" => "model_not_supported" }))
    end
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([]))

    cli.interactive_loop(agent: agent)

    assert_includes prompt.output.join, "Error: Copilot request failed: 400"
    assert_includes prompt.events, [:finish_busy_input]
  end

  def test_prompt_interface_interactive_turn_batches_streamed_deltas
    prompt = BusyPrompt.new([])
    events = 10.times.map { |index| Kward::Events::AssistantDelta.new(delta: index.to_s) }
    agent = EventAgent.new(events)
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([]))

    cli.send(:run_interactive_turn, agent, "hello")

    assert_equal ["0123456789"], prompt.write_deltas
    assert_operator prompt.write_deltas.length, :<, events.length
  end

  def test_prompt_interface_interactive_turn_renders_streamed_inline_bold
    prompt = BusyPrompt.new([])
    events = [Kward::Events::ReasoningDelta.new(delta: "**Exploring key handling** -> Better Markdown")]
    agent = EventAgent.new(events)
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([]))
    cli.instance_variable_set(:@color_enabled, true)

    cli.send(:run_interactive_turn, agent, "hello")

    assert_equal ["\e[1mExploring key handling\e[0m -> Better Markdown"], prompt.write_deltas
  end

  def test_prompt_interface_interactive_turn_cancels_on_busy_ctrl_c
    prompt = BusyPrompt.new([Kward::PromptInterface::CANCEL_INPUT])
    prompt.define_singleton_method(:poll_input) { @inputs.shift }
    assert_interactive_turn_cancels(prompt)
  end

  def test_prompt_interface_interactive_turn_cancels_on_interrupt_signal
    poll_count = 0
    prompt = BusyPrompt.new([])
    prompt.define_singleton_method(:poll_input) do
      poll_count += 1
      raise Interrupt if poll_count > 1
    end
    assert_interactive_turn_cancels(prompt)
  end

  def assert_interactive_turn_cancels(prompt)
    cancellation_seen = Queue.new
    agent = Object.new
    agent.define_singleton_method(:ask) do |_input, cancellation: nil, &block|
      block.call(Kward::Events::AssistantDelta.new(delta: "partial"))
      cancellation_seen << cancellation
      sleep 10
    end
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([]))

    queued = cli.send(:run_interactive_turn, agent, "hello")

    assert_empty queued
    assert cancellation_seen.pop.cancelled?
    assert_equal ["partial"], prompt.write_deltas
    assert_includes prompt.events, [:finish_busy_input]
    refute_includes prompt.output.join, "Error: cancelled"
  end

  def test_prompt_interface_interactive_turn_flushes_pending_delta_on_completion
    prompt = BusyPrompt.new([])
    agent = EventAgent.new([Kward::Events::AssistantDelta.new(delta: "final")])
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([]))

    cli.send(:run_interactive_turn, agent, "hello")

    assert_equal ["final"], prompt.write_deltas
  end

  def test_prompt_interface_interactive_turn_renders_late_reasoning_before_assistant
    prompt = BusyPrompt.new([])
    conversation = Kward::Conversation.new(system_message: nil, model: "gpt-5")
    agent = Object.new
    agent.define_singleton_method(:conversation) { conversation }
    agent.define_singleton_method(:ask) do |_input, **_options, &block|
      block.call(Kward::Events::AssistantDelta.new(delta: "answer"))
      sleep Kward::CLI::STREAM_RENDER_INTERVAL + 0.01
      block.call(Kward::Events::ReasoningDelta.new(delta: "thinking"))
      "answer"
    end
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([]))

    cli.send(:run_interactive_turn, agent, "hello")

    assert_order(prompt.events, [:start_stream_block, "Reasoning"], [:start_stream_block, "Assistant"])
    assert_equal ["thinking", "answer"], prompt.write_deltas
  end

  def test_prompt_interface_interactive_turn_keeps_late_reasoning_before_already_flushable_assistant
    prompt = BusyPrompt.new([])
    conversation = Kward::Conversation.new(system_message: nil, model: "gpt-5")
    agent = Object.new
    agent.define_singleton_method(:conversation) { conversation }
    agent.define_singleton_method(:ask) do |_input, **_options, &block|
      block.call(Kward::Events::ReasoningDelta.new(delta: "early\n"))
      block.call(Kward::Events::AssistantDelta.new(delta: "```text\npartial\n"))
      deadline = Time.now + 1
      sleep 0.005 until prompt.write_deltas.include?("early\n") || Time.now > deadline
      raise "timed out waiting for early reasoning flush" unless prompt.write_deltas.include?("early\n")

      block.call(Kward::Events::ReasoningDelta.new(delta: "late\n"))
      "answer"
    end
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([]))

    cli.send(:run_interactive_turn, agent, "hello")

    assert_order(prompt.events, [:write_delta, "early\n"], [:write_delta, "late\n"], [:start_stream_block, "Assistant"])
    assert_includes prompt.write_deltas.last, "┌─ code text"
    assert_includes prompt.write_deltas.last, "└"
  end

  def test_prompt_interface_interactive_turn_streams_assistant_without_reasoning_on_non_reasoning_model
    prompt = BusyPrompt.new([])
    conversation = Kward::Conversation.new(system_message: nil, model: "gpt-4.1")
    agent = Object.new
    agent.define_singleton_method(:conversation) { conversation }
    agent.define_singleton_method(:ask) do |_input, **_options, &block|
      block.call(Kward::Events::AssistantDelta.new(delta: "answer"))
      sleep Kward::CLI::STREAM_RENDER_INTERVAL + 0.01
      "answer"
    end
    client = FakeClient.new([])
    client.provider = "Copilot"
    client.model = "gpt-4.1"
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client)

    cli.send(:run_interactive_turn, agent, "hello")

    assert_equal ["answer"], prompt.write_deltas
  end

  def test_prompt_interface_interactive_turn_notifies_plugin_transcript_events
    prompt = BusyPrompt.new([])
    conversation = Kward::Conversation.new(system_message: nil)
    conversation.append_user("hello")
    agent = EventAgent.new([Kward::Events::AssistantDelta.new(delta: "live")])
    agent.define_singleton_method(:conversation) { conversation }
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([]))
    registry = Kward::PluginRegistry.new
    received = []
    registry.evaluate do |plugin|
      plugin.on_transcript_event do |event, ctx|
        received << [event.type, event.payload[:delta], ctx.transcript.messages.length]
      end
    end
    cli.instance_variable_set(:@plugin_registry, registry)

    cli.send(:run_interactive_turn, agent, "hello")

    assert_equal [["assistant_delta", "live", 1]], received
    assert_equal ["live"], prompt.write_deltas
  end

  def test_prompt_interface_interactive_turn_keeps_stream_block_open_between_throttled_flushes
    prompt = BusyPrompt.new([])
    events = ["I am Commander K’", "warD, sir —", " your officer"].map do |chunk|
      Kward::Events::AssistantDelta.new(delta: chunk)
    end
    agent = Object.new
    agent.define_singleton_method(:ask) do |_input, **_options, &block|
      events.each do |event|
        block.call(event)
        sleep Kward::CLI::STREAM_RENDER_INTERVAL + 0.01
      end
      ""
    end
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([]))

    cli.send(:run_interactive_turn, agent, "hello")

    assert_equal 1, prompt.events.count { |event| event == [:start_stream_block, "Assistant"] }
    assert_equal ["I am Commander K’", "warD, sir —", " your officer"], prompt.write_deltas
    assert_equal 1, prompt.events.count { |event| event == [:finish_stream_block] }
  end

  def test_prompt_interface_interactive_turn_flushes_deltas_before_tool_events
    prompt = BusyPrompt.new([])
    events = [
      Kward::Events::AssistantDelta.new(delta: "before tool"),
      Kward::Events::ToolCall.new(tool_call: tool_call("read_file", path: "README.md"))
    ]
    agent = EventAgent.new(events)
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([]))

    cli.send(:run_interactive_turn, agent, "hello")

    assert_order(prompt.events, [:start_stream_block, "Assistant"], [:write_delta, "before tool"], [:finish_stream_block], [:start_stream_block, "Tool"])
  end

  def test_prompt_interface_interactive_turn_keeps_markdown_fence_state_across_flushes
    prompt = BusyPrompt.new([])
    chunks = [
      "```ruby\nKward::",
      "Resources::AvatarKwardLogo::PIXELS\n```\n\ninstead of the missing PNG fixture:\n\n```ruby\nlib/kward/resources/avatar_k",
      "ward_48x48.png\n```\n"
    ]
    agent = Object.new
    agent.define_singleton_method(:ask) do |_input, **_options, &block|
      chunks.each do |chunk|
        block.call(Kward::Events::AssistantDelta.new(delta: chunk))
        sleep Kward::CLI::STREAM_RENDER_INTERVAL + 0.01
      end
      chunks.join
    end
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([]))

    cli.send(:run_interactive_turn, agent, "hello")

    output = strip_ansi(prompt.write_deltas.join)
    assert_includes output, "│ Kward::Resources::AvatarKwardLogo::PIXELS\n└"
    assert_includes output, "│ lib/kward/resources/avatar_kward_48x48.png\n└"
    refute_includes output, "└───────────────────────────────────────Resources"
    refute_includes output, "\nlib/kward/resources/avatar_kward_48x48.png\n┌─ code"
  end

  def test_transcript_block_renders_markdown_when_colored
    prompt = FakePrompt.new([])
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([]))
    cli.instance_variable_set(:@color_enabled, true)

    cli.send(:render_transcript_block, "Assistant", "## Plan\nRun `bundle test`.\n")

    output = prompt.output.join("\n")
    assert_includes output, "## \e[1mPlan\e[0m"
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

  def test_help_command_prints_colored_command_overview
    prompt = FakePrompt.new([])
    cli = Kward::CLI.new(argv: ["--help"], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([]))
    cli.instance_variable_set(:@color_enabled, true)

    cli.run

    output = prompt.output.join("\n")
    assert_includes output, "\e[32;1mKward\e[0m - an extendable CLI coding agent"
    assert_includes output, "\e[34;1mUsage\e[0m"
    assert_includes output, "\e[32;1mkward login\e[0m"
    assert_includes output, "\e[32;1mkward init\e[0m"
    assert_includes output, "\e[32;1mkward pan\e[0m"
    assert_includes output, "\e[36m\"Review this diff\"\e[0m"
    refute_includes output, "--install-starter-pack"
    refute_includes output, "--pan-mode"
    assert_includes output, "Command names take precedence. Anything else is sent as a one-shot prompt."
  end

  def test_version_command_prints_version
    prompt = FakePrompt.new([])
    cli = Kward::CLI.new(argv: ["version"], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([]))

    cli.run

    assert_equal ["kward #{Kward::VERSION}"], prompt.output
  end

  def test_command_specific_help_prints_usage_and_examples
    prompt = FakePrompt.new([])
    cli = Kward::CLI.new(argv: ["help", "pan"], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([]))
    cli.instance_variable_set(:@color_enabled, true)

    cli.run

    output = prompt.output.join("\n")
    assert_includes output, "\e[32;1mpan\e[0m - Start Pan mode"
    assert_includes output, "\e[34;1mUsage\e[0m"
    assert_includes output, "\e[32;1mkward pan\e[0m"
    assert_includes output, "\e[32;1mkward --working-directory ~/code/project pan\e[0m"
  end

  def test_command_help_option_prints_command_help
    prompt = FakePrompt.new([])
    cli = Kward::CLI.new(argv: ["pan", "--help"], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([]))

    cli.run

    assert_includes prompt.output.join("\n"), "Usage\n  kward pan"
  end

  def test_doctor_reports_local_setup
    Dir.mktmpdir do |config_dir|
      Dir.mktmpdir do |workspace_dir|
        config_path = File.join(config_dir, "config.json")
        File.write(config_path, JSON.dump({ "openrouter_api_key" => "sk-test", "pan_mode" => { "username" => "u", "password" => "p" } }))
        prompt = FakePrompt.new([])
        cli = Kward::CLI.new(argv: ["--working-directory", workspace_dir, "doctor"], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([]))

        with_env("KWARD_CONFIG_PATH" => config_path) do
          cli.run
        end

        output = strip_ansi(prompt.output.join("\n"))
        assert_includes output, "Kward Doctor"
        assert_includes output, "Config: #{config_path}"
        assert_includes output, "Config JSON: valid"
        assert_includes output, "Workspace: #{File.expand_path(workspace_dir)}"
        assert_includes output, "Model: Codex / fake-model"
        assert_includes output, "Auth:"
        assert_includes output, "OpenRouter API key"
        assert_includes output, "Pan mode: credentials configured"
      end
    end
  end

  def test_doctor_help_is_available
    prompt = FakePrompt.new([])
    cli = Kward::CLI.new(argv: ["doctor", "--help"], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([]))

    cli.run

    assert_includes prompt.output.join("\n"), "Usage\n  kward doctor"
  end

  def test_auth_status_reports_configured_credentials_without_secret_values
    Dir.mktmpdir do |config_dir|
      auth_path = File.join(config_dir, "auth.json")
      github_path = File.join(config_dir, "github_auth.json")
      config_path = File.join(config_dir, "config.json")
      File.write(auth_path, JSON.dump({ "tokens" => { "access_token" => "secret-openai" } }))
      File.write(github_path, JSON.dump({ "tokens" => { "access" => "secret-github" } }))
      File.write(config_path, JSON.dump({ "openrouter_api_key" => "secret-openrouter" }))
      prompt = FakePrompt.new([])
      cli = Kward::CLI.new(argv: ["auth", "status"], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([]))

      with_env("KWARD_CONFIG_PATH" => config_path, "KWARD_AUTH_PATH" => auth_path, "KWARD_GITHUB_AUTH_PATH" => github_path) do
        cli.run
      end

      output = strip_ansi(prompt.output.join("\n"))
      assert_includes output, "Auth Status"
      assert_includes output, "OpenAI OAuth: configured"
      assert_includes output, "GitHub OAuth: configured"
      assert_includes output, "OpenRouter API key: configured"
      refute_includes output, "secret-openai"
      refute_includes output, "secret-github"
      refute_includes output, "secret-openrouter"
    end
  end

  def test_auth_logout_removes_saved_credentials
    Dir.mktmpdir do |config_dir|
      auth_path = File.join(config_dir, "auth.json")
      github_path = File.join(config_dir, "github_auth.json")
      config_path = File.join(config_dir, "config.json")
      File.write(auth_path, JSON.dump({ "tokens" => { "access_token" => "secret-openai" } }))
      File.write(github_path, JSON.dump({ "tokens" => { "access" => "secret-github" } }))
      File.write(config_path, JSON.dump({ "openrouter_api_key" => "secret-openrouter" }))
      prompt = FakePrompt.new([])
      cli = Kward::CLI.new(argv: ["auth", "logout"], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([]))

      with_env("KWARD_CONFIG_PATH" => config_path, "KWARD_AUTH_PATH" => auth_path, "KWARD_GITHUB_AUTH_PATH" => github_path) do
        cli.run
      end

      refute_path_exists auth_path
      refute_path_exists github_path
      refute JSON.parse(File.read(config_path)).key?("openrouter_api_key")
      assert_includes prompt.output.join("\n"), "Removed 3 saved credentials."
    end
  end

  def test_auth_help_is_available
    prompt = FakePrompt.new([])
    cli = Kward::CLI.new(argv: ["auth", "--help"], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([]))

    cli.run

    assert_includes prompt.output.join("\n"), "Usage\n  kward auth status|logout"
  end

  def test_known_command_with_invalid_arguments_does_not_run_one_shot
    Dir.mktmpdir do |config_dir|
      client = Object.new
      client.define_singleton_method(:chat) { |_messages, **_opts| raise "model should not be called" }
      cli = Kward::CLI.new(argv: ["pan", "extra"], stdin: FakeInput.new("", tty: true), client: client)

      stderr = with_env("KWARD_CONFIG_PATH" => File.join(config_dir, "config.json")) do
        capture_io do
          assert_raises(SystemExit) { cli.run }
        end.last
      end

      assert_includes stderr, "Usage: kward pan"
      assert_includes stderr, "Run `kward help` for available commands."
    end
  end

  def test_help_with_too_many_arguments_reports_usage
    prompt = FakePrompt.new([])
    cli = Kward::CLI.new(argv: ["help", "pan", "extra"], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([]))

    stderr = capture_io do
      assert_raises(SystemExit) { cli.run }
    end.last

    assert_includes stderr, "Usage: kward help [command]"
    assert_empty prompt.output
  end

  def test_multi_argument_input_runs_as_one_shot_prompt
    Dir.mktmpdir do |config_dir|
      client = RecordingClient.new(["summary"])
      cli = Kward::CLI.new(argv: ["Explain", "this", "project"], stdin: FakeInput.new("", tty: true), client: client)

      stdout = with_env("KWARD_CONFIG_PATH" => File.join(config_dir, "config.json")) do
        capture_io { cli.run }.first
      end

      assert_includes stdout, "summary"
      assert_equal "Explain this project", client.seen_messages.first.last[:content]
    end
  end

  def test_single_argument_prompt_still_runs_one_shot
    Dir.mktmpdir do |config_dir|
      cli = Kward::CLI.new(argv: ["Explain this project"], stdin: FakeInput.new("", tty: true), client: FakeClient.new([{ "role" => "assistant", "content" => "summary" }]))

      stdout = with_env("KWARD_CONFIG_PATH" => File.join(config_dir, "config.json")) do
        capture_io { cli.run }.first
      end

      assert_includes stdout, "summary"
    end
  end

  def test_working_directory_option_sets_one_shot_workspace
    Dir.mktmpdir do |config_dir|
      Dir.mktmpdir do |workspace_dir|
        File.write(File.join(workspace_dir, "AGENTS.md"), "Workspace marker from option")
        client = RecordingClient.new(["ok"])
        cli = Kward::CLI.new(argv: ["--working-directory", workspace_dir, "hello"], stdin: FakeInput.new("", tty: true), client: client)

        with_env("KWARD_CONFIG_PATH" => File.join(config_dir, "config.json")) do
          capture_io { cli.run }
        end

        system_message = client.seen_messages.first.first[:content]
        assert_includes system_message, "Workspace marker from option"
      end
    end
  end

  def test_working_directory_option_can_follow_prompt_words
    Dir.mktmpdir do |config_dir|
      Dir.mktmpdir do |workspace_dir|
        client = RecordingClient.new(["ok"])
        cli = Kward::CLI.new(argv: ["Explain", "this", "--working-directory=#{workspace_dir}", "project"], stdin: FakeInput.new("", tty: true), client: client)

        with_env("KWARD_CONFIG_PATH" => File.join(config_dir, "config.json")) do
          capture_io { cli.run }
        end

        assert_equal "Explain this project", client.seen_messages.first.last[:content]
      end
    end
  end

  def test_prompt_delimiter_preserves_option_like_prompt_text
    Dir.mktmpdir do |config_dir|
      client = RecordingClient.new(["ok"])
      cli = Kward::CLI.new(argv: ["--", "explain", "--working-directory", "option"], stdin: FakeInput.new("", tty: true), client: client)

      with_env("KWARD_CONFIG_PATH" => File.join(config_dir, "config.json")) do
        capture_io { cli.run }
      end

      assert_equal "explain --working-directory option", client.seen_messages.first.last[:content]
    end
  end

  def test_prompt_delimiter_preserves_command_like_prompt_text
    Dir.mktmpdir do |config_dir|
      client = RecordingClient.new(["ok"])
      cli = Kward::CLI.new(argv: ["--", "pan", "extra"], stdin: FakeInput.new("", tty: true), client: client)

      with_env("KWARD_CONFIG_PATH" => File.join(config_dir, "config.json")) do
        capture_io { cli.run }
      end

      assert_equal "pan extra", client.seen_messages.first.last[:content]
    end
  end

  def test_missing_working_directory_option_value_exits_with_error
    Dir.mktmpdir do |config_dir|
      cli = Kward::CLI.new(argv: ["--working-directory"], stdin: FakeInput.new("", tty: true), client: FakeClient.new([]))

      stderr = with_env("KWARD_CONFIG_PATH" => File.join(config_dir, "config.json")) do
        capture_io do
          assert_raises(SystemExit) { cli.run }
        end.last
      end

      assert_includes stderr, "Missing value for --working-directory"
      assert_includes stderr, "Run `kward help` for available commands."
    end
  end

  def test_pan_command_starts_pan_server_with_working_directory
    Dir.mktmpdir do |config_dir|
      Dir.mktmpdir do |workspace_dir|
        calls = []
        original_new = Kward::PanServer.method(:new)
        Kward::PanServer.define_singleton_method(:new) do |client:, working_directory:|
          calls << { client: client, working_directory: working_directory }
          Object.new.tap { |server| server.define_singleton_method(:run) { calls << :run } }
        end
        client = FakeClient.new([])
        cli = Kward::CLI.new(argv: ["--working-directory", workspace_dir, "pan"], stdin: FakeInput.new("", tty: true), client: client)

        with_env("KWARD_CONFIG_PATH" => File.join(config_dir, "config.json")) do
          cli.run
        end

        assert_equal [{ client: client, working_directory: File.expand_path(workspace_dir) }, :run], calls
      ensure
        Kward::PanServer.define_singleton_method(:new, original_new) if original_new
      end
    end
  end

  def test_legacy_pan_mode_flag_still_starts_pan_server
    Dir.mktmpdir do |config_dir|
      calls = []
      original_new = Kward::PanServer.method(:new)
      Kward::PanServer.define_singleton_method(:new) do |client:, working_directory:|
        calls << working_directory
        Object.new.tap { |server| server.define_singleton_method(:run) { calls << :run } }
      end
      cli = Kward::CLI.new(argv: ["--pan-mode"], stdin: FakeInput.new("", tty: true), client: FakeClient.new([]))

      with_env("KWARD_CONFIG_PATH" => File.join(config_dir, "config.json")) do
        cli.run
      end

      assert_equal [Dir.pwd, :run], calls
    ensure
      Kward::PanServer.define_singleton_method(:new, original_new) if original_new
    end
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

  def test_copy_defaults_to_last_assistant_response
    prompt = FakePrompt.new(["hello", "/copy", "/exit"])
    client = RecordingClient.new(["reply"])
    agent = Kward::Agent.new(client: client, tool_registry: Kward::ToolRegistry.new(prompt: prompt))
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client)
    copied = []
    with_clipboard_stub(lambda { |text| copied << text; Kward::Clipboard::Result.new(success?: true, method: "test", message: "copied") }) do
      cli.interactive_loop(agent: agent)
    end

    assert_equal ["reply"], copied
    assert_includes prompt.output.join("\n"), "Copied last assistant response."
  end

  def test_copy_transcript_copies_markdown_transcript
    prompt = FakePrompt.new(["hello", "/copy transcript", "/exit"])
    client = RecordingClient.new(["reply"])
    agent = Kward::Agent.new(client: client, tool_registry: Kward::ToolRegistry.new(prompt: prompt))
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client)
    copied = []
    with_clipboard_stub(lambda { |text| copied << text; Kward::Clipboard::Result.new(success?: true, method: "test", message: "copied") }) do
      cli.interactive_loop(agent: agent)
    end

    assert_equal 1, copied.length
    assert_includes copied.first, "# Kward Session"
    assert_includes copied.first, "## User\n\nhello"
    assert_includes copied.first, "## Assistant\n\nreply"
  end

  def test_copy_rejects_composer_target
    prompt = FakePrompt.new(["/copy composer", "/exit"])
    client = RecordingClient.new([])
    agent = Kward::Agent.new(client: client, tool_registry: Kward::ToolRegistry.new(prompt: prompt))
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client)
    copied = []
    with_clipboard_stub(lambda { |text| copied << text; Kward::Clipboard::Result.new(success?: true, method: "test", message: "copied") }) do
      cli.interactive_loop(agent: agent)
    end

    assert_empty copied
    assert_includes prompt.output.join("\n"), "Usage: /copy [last|transcript]"
  end

  def test_copy_reports_clipboard_failure
    prompt = FakePrompt.new(["hello", "/copy", "/exit"])
    client = RecordingClient.new(["reply"])
    agent = Kward::Agent.new(client: client, tool_registry: Kward::ToolRegistry.new(prompt: prompt))
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client)
    with_clipboard_stub(lambda { |_text| Kward::Clipboard::Result.new(success?: false, message: "no supported clipboard mechanism found") }) do
      cli.interactive_loop(agent: agent)
    end

    assert_includes prompt.output.join("\n"), "Copy failed: no supported clipboard mechanism found."
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

  def test_interactive_startup_omits_title_session_and_help_text
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      prompt = FakePrompt.new(["/exit"])
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: RecordingClient.new([]), session_store: store)

      cli.interactive_loop

      output = prompt.output.join("\n")
      refute_includes output, "Ruby CLI Agent"
      refute_includes output, "Session:"
      refute_includes output, "Ask a question and press Enter"
    end
  end

  def test_interactive_mode_prints_visual_banner_once_without_persisting_it
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      prompt = BannerPrompt.new(["hello", "/exit"])
      client = RecordingClient.new(["reply"])
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client, session_store: store)

      cli.interactive_loop

      assert_equal 1, prompt.banner_count
      assert_includes prompt.output, "[visual banner]"
      files = Dir.glob(File.join(store.session_dir, "*.jsonl"))
      assert_equal 1, files.length
      refute_includes File.read(files.first), "visual banner"
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
      refute_includes strip_ansi(after_clear), "Kward>"
      refute_includes strip_ansi(after_clear), "Started new session:"
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
    assert_includes client.seen_messages[1][3][:content], "# Kward"
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
      prompt = BannerPrompt.new(["/resume #{saved.path}", "again", "/exit"])
      client = RecordingClient.new(["second"])
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client, session_store: store)

      cli.interactive_loop

      assert_equal "hello", client.seen_messages[0][1]["content"]
      assert_equal "reply", client.seen_messages[0][2]["content"]
      assert_equal "again", client.seen_messages[0][3][:content]
      assert_equal 1, prompt.banner_count
      output = strip_ansi(prompt.output.join("\n"))
      assert_includes output, "You> hello"
      assert_includes output, "reply"
    end
  end

  def test_resume_prompt_interface_preserves_scrollback_with_synchronized_redraw
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      saved = store.create
      conversation = Kward::Conversation.new(system_message: nil)
      saved.attach(conversation)
      1.upto(30) do |index|
        conversation.append_user(format("turn %03d", index))
      end
      output = StringIO.new
      input, writer = IO.pipe
      writer.write("/resume #{saved.path}\r/exit\r")
      writer.close
      prompt = Kward::PromptInterface.new(input: input, output: output)
      original_width = TTY::Screen.method(:width)
      original_height = TTY::Screen.method(:height)
      TTY::Screen.define_singleton_method(:width) { 80 }
      TTY::Screen.define_singleton_method(:height) { 20 }
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: RecordingClient.new([]), session_store: store)

      cli.interactive_loop

      rendered = strip_ansi(output.string)
      assert_includes output.string, Kward::PromptInterface::SYNCHRONIZED_OUTPUT_ENABLE
      assert_includes output.string, Kward::PromptInterface::SYNCHRONIZED_OUTPUT_DISABLE
      assert_includes output.string, TTY::Cursor.clear_screen
      assert_includes rendered, "turn 001\r\n"
      assert_includes rendered, "turn 030"
    ensure
      TTY::Screen.define_singleton_method(:width, original_width) if original_width
      TTY::Screen.define_singleton_method(:height, original_height) if original_height
      input&.close unless input&.closed?
    end
  end

  def test_resume_slash_command_shows_loading_spinner
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      saved = store.create
      conversation = Kward::Conversation.new
      saved.attach(conversation)
      conversation.append_user("hello")
      prompt = BusyPrompt.new(["/resume #{saved.path}", "/exit"])
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: RecordingClient.new([]), session_store: store)

      cli.interactive_loop

      loading_index = prompt.events.index([:begin_busy_input, "You>", "loading"])
      assert loading_index
      finish_after_loading = prompt.events[loading_index..].index([:finish_busy_input])
      assert finish_after_loading
      assert_includes prompt.output.join("\n"), "Resumed session:"
    end
  end

  def test_resume_picker_is_covered_by_loading_spinner
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      saved = store.create
      conversation = Kward::Conversation.new
      saved.attach(conversation)
      conversation.append_user("hello")
      prompt = BusyPrompt.new(["/resume", "/exit"])
      prompt.define_singleton_method(:select) do |_message, choices, title: "Sessions", custom: false|
        events << [:select_session]
        choices.first
      end
      store.define_singleton_method(:recent) do |limit: 20|
        prompt.events << [:recent, limit]
        super(limit: limit)
      end
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: RecordingClient.new([]), session_store: store)

      cli.interactive_loop

      loading_index = prompt.events.index([:begin_busy_input, "You>", "loading"])
      recent_index = prompt.events.index([:recent, nil])
      select_index = prompt.events.index([:select_session])
      assert loading_index
      assert recent_index
      assert select_index
      assert_operator loading_index, :<, recent_index
      assert_operator loading_index, :<, select_index
    end
  end

  def test_resume_updates_composer_context_usage_source
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      saved = store.create
      conversation = Kward::Conversation.new(system_message: nil)
      saved.attach(conversation)
      conversation.append_user("resumed context")
      prompt = FakePrompt.new(["/resume #{saved.path}", "/exit"])
      context_usage = Object.new
      seen_messages = []
      context_usage.define_singleton_method(:call) do |context_parts:, **_kwargs|
        seen_messages.replace(context_parts[:messages])
        { percent: 9 }
      end
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([]), session_store: store, context_usage: context_usage)

      cli.interactive_loop

      assert_equal "9% · Codex fake-model · medium", cli.send(:composer_status_text)
      assert_equal "resumed context", seen_messages.last["content"] || seen_messages.last[:content]
      assert_equal 1, prompt.redraw_count
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

      output = strip_ansi(prompt.output.join("\n"))
      assert_includes output, "You> inspect file"
      assert_includes output, "Reasoning>\nNeed to inspect the file."
      assert_includes output, "I'll read it."
      assert_includes output, "Tool>\nread_file"
      assert_includes output, "Tool output>\nread_file: README.md"
      assert_includes output, "1 lines, 16 bytes"
      refute_includes output, "README contents"
    end
  end

  def test_retry_event_renders_retry_message
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), client: FakeClient.new([]))
    event = Kward::Events::Retry.new(provider: "Codex", model: "gpt-test", attempt: 2, max_attempts: 3, delay_seconds: 1, error: "Codex request failed: 503 upstream", request_bytes: 123)

    output = capture_io do
      cli.send(:print_retry, event)
    end.first

    assert_includes output, "Retry>"
    assert_includes output, "Retrying Codex request after transient failure (attempt 2/3) in 1s with 123 byte payload"
    assert_includes output, "Codex request failed: 503 upstream"
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
      cli.send(:print_tool_result, tool_call("web_search", queries: ["ruby"]), "# Web search\n\n## Query: ruby\n1. Ruby\n   URL: https://ruby-lang.org\n")
    end.first
    assert_includes research_output, "web_search"
    assert_includes research_output, "ruby: 1 result(s)"
  end

  def test_interactive_tool_output_limit_keeps_10_line_summary_unchanged
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: FakePrompt.new([]), client: FakeClient.new([]))
    content = (1..10).map { |index| "line#{index}" }.join("\n")

    output = capture_io do
      cli.send(:print_tool_result, tool_call("custom_tool", {}), content, line_limit: Kward::CLI::INTERACTIVE_TOOL_OUTPUT_LINE_LIMIT)
    end.first

    summary = strip_ansi(output).split("Tool output>\n", 2).last
    assert_equal 10, summary.lines.length
    assert_includes output, "line10"
    refute_includes output, "truncated"
  end

  def test_interactive_tool_output_limit_does_not_truncate_model_context
    command = %q(ruby -e '12.times { |i| puts "line#{i + 1}" }')
    prompt = FakePrompt.new(["show lines", "/exit"])
    client = RecordingClient.new([assistant_tool_call("run_shell_command", command: command), "done"])
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client, session_store: store)

      output = capture_io do
        cli.interactive_loop
      end.first

      assert_includes output, "Tool output>"
      assert_includes output, "...[truncated"
      refute_includes output, "line12"
      tool_message = client.seen_messages[1].find { |message| (message["role"] || message[:role]) == "tool" }
      assert_includes tool_message[:content], "line12"
    end
  end

  def test_resume_limits_restored_tool_output_to_10_lines
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      saved = store.create
      conversation = Kward::Conversation.new
      saved.attach(conversation)
      conversation.append_user("inspect restored output")
      conversation.append_assistant({
        "role" => "assistant",
        "content" => nil,
        "tool_calls" => [tool_call("custom_tool", {})]
      })
      conversation.append_tool(tool_call_id: "call_custom_tool", name: "custom_tool", content: (1..12).map { |index| "line#{index}" }.join("\n"))
      prompt = FakePrompt.new(["/resume #{saved.path}", "/exit"])
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: RecordingClient.new([]), session_store: store)

      cli.interactive_loop

      output = strip_ansi(prompt.output.join("\n"))
      assert_includes output, "Tool output>\ncustom_tool: line1"
      assert_includes output, "...[truncated 3 lines]"
      refute_includes output, "line12"
    end
  end

  def test_session_commands_name_clone_and_export
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      export_path = File.join(store.session_dir, "session.md")
      prompt = FakePrompt.new(["hello", "/name Draft", "/name Useful", "/clone", "/export #{export_path}", "/exit"])
      client = RecordingClient.new(["reply"])
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client, session_store: store)

      cli.interactive_loop

      files = Dir.glob(File.join(store.session_dir, "*.jsonl"))
      assert_equal 2, files.length
      assert files.any? { |file| jsonl_records(file).any? { |record| record["type"] == "session_info" && record["name"] == "Useful" } }
      output = strip_ansi(prompt.output.join("\n"))
      assert_includes output, "You> hello"
      assert_includes output, "reply"
      assert_includes File.read(export_path), "## User\n\nhello"
      assert_includes File.read(export_path), "## Assistant\n\nreply"
      source_path, clone_path = files.sort_by { |file| jsonl_records(file).find { |record| record["type"] == "session" }.key?("parentId") ? 1 : 0 }
      source = jsonl_records(source_path).find { |record| record["type"] == "session" }
      clone = jsonl_records(clone_path).find { |record| record["type"] == "session" }
      clone_name = jsonl_records(clone_path).select { |record| record["type"] == "session_info" }.last
      assert_equal source["id"], clone["parentId"]
      assert_equal "Useful", clone_name["name"]
    end
  end

  def test_export_renders_compaction_summary_content
    export_path = File.join(Dir.pwd, "tmp-cli-export.md")
    conversation = Kward::Conversation.new(system_message: nil)
    conversation.compact!("summary content", compaction_summary: true)
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: FakePrompt.new([]), client: RecordingClient.new([]))

    cli.send(:export_session, conversation, export_path)

    assert_includes File.read(export_path), "## Compactionsummary\n\nsummary content"
  ensure
    File.delete(export_path) if export_path && File.exist?(export_path)
  end

  def test_export_rejects_explicit_path_outside_workspace_or_session_directory
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      outside_path = File.join(Dir.mktmpdir, "session.md")
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: FakePrompt.new([]), client: RecordingClient.new([]), session_store: store)

      assert_raises(ArgumentError) { cli.send(:export_path, outside_path) }
    ensure
      FileUtils.remove_entry(File.dirname(outside_path)) if outside_path && File.exist?(File.dirname(outside_path))
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
      assert_equal ["selected session — #{File.basename(saved.path)}"], prompt.select_choices.first
      assert_equal "selected session", client.seen_messages[0][1]["content"]
      assert_equal "again", client.seen_messages[0][3][:content]
    end
  end


  def test_tree_slash_command_selects_user_entry_and_prefills_prompt
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      session = store.create
      conversation = Kward::Conversation.new(system_message: nil)
      session.attach(conversation)
      conversation.append_user("first prompt")
      conversation.append_assistant("first reply")
      conversation.append_user("edit this prompt")
      conversation.append_assistant("future reply")
      prompt = FakeSessionSelectPrompt.new(["/resume #{session.path}", "/tree", "/exit"], "edit this prompt")
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: RecordingClient.new([]), session_store: store)

      cli.interactive_loop
      loaded_session, loaded_conversation = store.load(session.path)

      assert_equal ["Tree>"], prompt.select_messages.last(1)
      assert_equal prompt.select_choices.last.length - 1, prompt.select_initial_indices.last
      assert_equal ["edit this prompt"], prompt.prefilled_inputs
      assert_equal "first reply", loaded_conversation.messages.reject { |message| (message["role"] || message[:role]) == "system" }.last["content"]
      assert_equal loaded_session.leaf_id, loaded_conversation.messages.reject { |message| (message["role"] || message[:role]) == "system" }.last["id"]
    end
  end

  def test_tree_slash_command_starts_cursor_at_current_tree_position
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      session = store.create
      conversation = Kward::Conversation.new(system_message: nil)
      session.attach(conversation)
      conversation.append_user("first prompt")
      conversation.append_assistant("first reply")
      first_reply_id = session.leaf_id
      conversation.append_user("future prompt")
      conversation.append_assistant("future reply")
      session.branch(first_reply_id)
      prompt = FakeSessionSelectPrompt.new(["/resume #{session.path}", "/tree", "/exit"], "first reply")
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: RecordingClient.new([]), session_store: store)

      cli.interactive_loop

      choices = prompt.select_choices.last
      assert_equal choices.index { |choice| choice.include?("first reply") }, prompt.select_initial_indices.last
    end
  end

  def test_tree_slash_command_selects_assistant_entry_without_prefill_or_autorun
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      session = store.create
      conversation = Kward::Conversation.new(system_message: nil)
      session.attach(conversation)
      conversation.append_user("first prompt")
      conversation.append_assistant("visible reply")
      conversation.append_user("future prompt")
      prompt = FakeSessionSelectPrompt.new(["/resume #{session.path}", "/tree", "/exit"], "visible reply")
      client = RecordingClient.new(["should not be used"])
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client, session_store: store)

      cli.interactive_loop
      loaded_session, loaded_conversation = store.load(session.path)

      choices = prompt.select_choices.last
      assert choices.any? { |choice| choice.include?("user: first prompt") }
      assert choices.any? { |choice| choice.include?("assistant: visible reply") }
      assert_empty prompt.prefilled_inputs
      assert_empty client.seen_messages
      refute_includes prompt.output.join("
"), "Only user turns can be edited from the session tree."
      assert_equal "visible reply", loaded_conversation.messages.reject { |message| (message["role"] || message[:role]) == "system" }.last["content"]
      assert_equal loaded_session.leaf_id, loaded_conversation.messages.reject { |message| (message["role"] || message[:role]) == "system" }.last["id"]
    end
  end

  def test_tree_slash_command_uses_pi_style_active_path_branch_prefixes_and_tool_results
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      session = store.create
      conversation = Kward::Conversation.new(system_message: nil)
      session.attach(conversation)
      conversation.append_user("root prompt")
      conversation.append_assistant("root reply")
      root_reply_id = session.leaf_id
      conversation.append_user("active branch")
      conversation.append_assistant({
        "role" => "assistant",
        "content" => nil,
        "tool_calls" => [tool_call("read_file", path: "README.md", offset: 2, limit: 3)]
      })
      conversation.append_tool(tool_call_id: "call_read_file", name: "read_file", content: "README contents")
      active_leaf_id = session.leaf_id
      session.branch(root_reply_id)
      conversation.append_user("side branch")
      conversation.append_assistant("side reply")
      session.branch(active_leaf_id)
      prompt = FakeSessionSelectPrompt.new(["/resume #{session.path}", "/tree", "/exit"], "active branch")
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: RecordingClient.new([]), session_store: store)

      cli.interactive_loop

      choices = prompt.select_choices.last
      active_choice = choices.find { |choice| choice.include?("active branch") }
      side_choice = choices.find { |choice| choice.include?("side branch") }
      refute choices.any? { |choice| choice.include?("assistant: ") && choice.include?("(no content)") }
      assert choices.any? { |choice| choice.include?("[read: README.md:2-4]") }
      assert_includes active_choice, "├⊟ • user: active branch"
      assert_includes side_choice, "└⊟ user: side branch"
      assert_operator choices.index(active_choice), :<, choices.index(side_choice)
    end
  end

  def test_tree_slash_command_without_composer_prefill_does_not_auto_run_selected_text
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      session = store.create
      conversation = Kward::Conversation.new(system_message: nil)
      session.attach(conversation)
      conversation.append_user("first prompt")
      conversation.append_assistant("first reply")
      conversation.append_user("edit this prompt")
      prompt = FakeSessionSelectNoPrefillPrompt.new(["/resume #{session.path}", "/tree", "/exit"], "edit this prompt")
      client = RecordingClient.new(["should not be used"])
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client, session_store: store)

      cli.interactive_loop

      assert_empty client.seen_messages
      assert_includes prompt.output.join("
"), "Selected text for editing:
edit this prompt"
    end
  end

  def test_resume_picker_shows_cloned_sessions_newest_first
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      source = store.create
      conversation = Kward::Conversation.new(system_message: nil)
      source.attach(conversation)
      conversation.append_user("root session")
      clone, clone_conversation = store.create_independent_from_conversation(conversation, parent_session: source)
      clone.rename("clone session")
      clone_conversation.append_user("clone session")
      old_time = Time.now - 60
      File.utime(old_time, old_time, source.path)
      File.utime(Time.now, Time.now, clone.path)
      prompt = FakeSessionSelectPrompt.new(["/resume", "/exit"], "clone session")
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: RecordingClient.new([]), session_store: store)

      cli.interactive_loop

      assert_equal ["Session>"], prompt.select_messages
      assert_equal "clone session — #{File.basename(clone.path)}", prompt.select_choices.first.first
      assert_includes prompt.select_choices.first, "root session — #{File.basename(source.path)}"
      refute prompt.select_choices.first.any? { |choice| choice.include?("└─ clone session") }
    end
  end

  def test_resume_picker_deletes_empty_unnamed_sessions
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      empty = store.create
      saved = store.create
      conversation = Kward::Conversation.new(system_message: nil)
      saved.attach(conversation)
      conversation.append_user("saved session")
      prompt = FakeSessionSelectPrompt.new(["/resume", "/exit"], "saved session")
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: RecordingClient.new([]), session_store: store)

      cli.interactive_loop

      assert_equal ["Session>"], prompt.select_messages
      assert_includes prompt.select_choices.first, "saved session — #{File.basename(saved.path)}"
      refute_path_exists empty.path
    end
  end

  def test_resume_picker_reports_no_saved_sessions_when_only_empty_unnamed_session_exists
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      prompt = FakePrompt.new(["/resume", "/exit"])
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: RecordingClient.new([]), session_store: store)

      cli.interactive_loop

      assert_empty Dir.glob(File.join(store.session_dir, "*.jsonl"))
      assert_empty prompt.output.grep(/Recent sessions:/)
      assert_includes prompt.output.join("\n"), "No saved sessions found."
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
      Dir.mktmpdir do |home|
        File.write(File.join(dir, "config.json"), JSON.dump({}))
        prompts_dir = File.join(dir, "prompts")
        FileUtils.mkdir_p(prompts_dir)
        File.write(File.join(prompts_dir, "plan.md"), "---\ndescription: Plan work.\nargument-hint: <task>\n---\nPlan this:\n$ARGUMENTS\n")
        prompt = FakePrompt.new(["/plan fix bug", "/exit"])
        client = RecordingClient.new(["planned"])

        with_env("HOME" => home, "KWARD_CONFIG_PATH" => File.join(dir, "config.json")) do
          agent = Kward::Agent.new(client: client, tool_registry: Kward::ToolRegistry.new(prompt: prompt))
          cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client)

          cli.interactive_loop(agent: agent)
        end

        assert_equal "Plan this:\nfix bug\n", client.seen_messages[0][1][:content]
      end
    end
  end

  def test_interactive_prompt_slash_command_persists_original_display_content
    Dir.mktmpdir do |dir|
      Dir.mktmpdir do |home|
        File.write(File.join(dir, "config.json"), JSON.dump({}))
        prompts_dir = File.join(dir, "prompts")
        FileUtils.mkdir_p(prompts_dir)
        File.write(File.join(prompts_dir, "plan.md"), "Plan this:\n$ARGUMENTS\n")
        store = Kward::SessionStore.new(config_dir: dir, cwd: Dir.pwd)
        prompt = FakePrompt.new(["/plan fix bug", "/exit"])
        client = RecordingClient.new(["planned"])

        with_env("HOME" => home, "KWARD_CONFIG_PATH" => File.join(dir, "config.json")) do
          cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client, session_store: store)

          cli.interactive_loop
        end

        user_message = jsonl_records(Dir.glob(File.join(store.session_dir, "*.jsonl")).first).find do |record|
          record["type"] == "message" && record.dig("message", "role") == "user"
        end["message"]
        assert_equal "Plan this:\nfix bug\n", user_message["content"]
        assert_equal "/plan fix bug", user_message["display_content"]
        assert_equal "/plan fix bug", store.recent.first.first_message
      end
    end
  end

  def test_prompt_interface_slash_command_displays_original_input
    Dir.mktmpdir do |dir|
      Dir.mktmpdir do |home|
        File.write(File.join(dir, "config.json"), JSON.dump({}))
        prompts_dir = File.join(dir, "prompts")
        FileUtils.mkdir_p(prompts_dir)
        File.write(File.join(prompts_dir, "plan.md"), "Plan this:\n$ARGUMENTS\n")
        prompt = BusyPrompt.new(["/plan fix bug", "/exit"])
        client = RecordingClient.new(["planned"])

        with_env("HOME" => home, "KWARD_CONFIG_PATH" => File.join(dir, "config.json")) do
          agent = Kward::Agent.new(client: client, tool_registry: Kward::ToolRegistry.new(prompt: prompt))
          cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client)

          cli.interactive_loop(agent: agent)
        end

        output = strip_ansi(prompt.output.join("\n"))
        assert_includes output, "You> /plan fix bug"
        refute_includes output, "Plan this:"
        assert_equal "Plan this:\nfix bug\n", client.seen_messages[0][1][:content]
      end
    end
  end

  def test_transcript_and_export_show_original_slash_command_display_content
    conversation = Kward::Conversation.new(system_message: nil)
    conversation.append_user("Plan this:\nfix bug\n", display_content: "/plan fix bug")
    conversation.append_assistant("planned")
    prompt = FakePrompt.new([])
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: RecordingClient.new([]))

    cli.send(:render_conversation_transcript, conversation)
    transcript_output = strip_ansi(prompt.output.join("\n"))
    assert_includes transcript_output, "You> /plan fix bug"
    refute_includes transcript_output, "Plan this:"

    markdown = cli.send(:markdown_transcript, conversation)
    assert_includes markdown, "/plan fix bug"
    refute_includes markdown, "Plan this:"
  end

  def test_transcript_replay_renders_structured_user_image_parts
    original_term_program = ENV["TERM_PROGRAM"]
    original_kitty_window_id = ENV["KITTY_WINDOW_ID"]
    ENV.delete("TERM_PROGRAM")
    ENV["KITTY_WINDOW_ID"] = "1"
    data = Base64.strict_encode64("png bytes")
    conversation = Kward::Conversation.new(
      system_message: nil,
      messages: [
        {
          role: "user",
          content: [
            { type: "text", text: "look\ndata:image/png;base64,#{data}" },
            { type: "image", media_type: "image/png", data: data }
          ]
        }
      ]
    )
    prompt = FakePrompt.new([])
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: RecordingClient.new([]))

    cli.send(:render_conversation_transcript, conversation)

    output = prompt.output.join("\n")
    stripped = strip_ansi(output)
    assert_includes stripped, "You> look"
    refute_includes stripped, "You> look\ndata:image/png;base64"
    assert_includes output, "[image] pasted image · image/png · 9 B"
    assert_includes output, "\e_Ginline=1;preserveAspectRatio=1;width=40:#{data}\e\\"
  ensure
    original_term_program ? ENV["TERM_PROGRAM"] = original_term_program : ENV.delete("TERM_PROGRAM")
    original_kitty_window_id ? ENV["KITTY_WINDOW_ID"] = original_kitty_window_id : ENV.delete("KITTY_WINDOW_ID")
  end

  def test_interactive_prompt_slash_command_allows_empty_arguments
    Dir.mktmpdir do |dir|
      Dir.mktmpdir do |home|
        File.write(File.join(dir, "config.json"), JSON.dump({}))
        prompts_dir = File.join(dir, "prompts")
        FileUtils.mkdir_p(prompts_dir)
        File.write(File.join(prompts_dir, "plan.md"), "Plan this:\n$ARGUMENTS\n")
        prompt = FakePrompt.new(["/plan", "/exit"])
        client = RecordingClient.new(["planned"])

        with_env("HOME" => home, "KWARD_CONFIG_PATH" => File.join(dir, "config.json")) do
          agent = Kward::Agent.new(client: client, tool_registry: Kward::ToolRegistry.new(prompt: prompt))
          cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client)

          cli.interactive_loop(agent: agent)
        end

        assert_equal "Plan this:\n\n", client.seen_messages[0][1][:content]
      end
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
      Dir.mktmpdir do |home|
        File.write(File.join(dir, "config.json"), JSON.dump({}))
        prompts_dir = File.join(dir, "prompts")
        FileUtils.mkdir_p(prompts_dir)
        File.write(File.join(prompts_dir, "plan.md"), "Plan this:\n$ARGUMENTS\n")
        prompt = FakeSelectPrompt.new(["/p", "/exit"])
        client = RecordingClient.new(["planned"])

        with_env("HOME" => home, "KWARD_CONFIG_PATH" => File.join(dir, "config.json")) do
          agent = Kward::Agent.new(client: client, tool_registry: Kward::ToolRegistry.new(prompt: prompt))
          cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client)

          cli.interactive_loop(agent: agent)
        end

        assert_equal "Plan this:\n\n", client.seen_messages[0][1][:content]
        assert_equal ["Slash command>"], prompt.select_messages
      end
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
    original_kitty_window_id = ENV["KITTY_WINDOW_ID"]
    ENV.delete("TERM_PROGRAM")
    ENV["KITTY_WINDOW_ID"] = "1"
    File.binwrite(path, "png bytes")
    prompt = FakePrompt.new([])
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([]))

    cli.send(:print_user_transcript, "look #{path}")

    assert_includes strip_ansi(prompt.output.join("\n")), "You> look #{path}"
    assert_includes prompt.output.join("\n"), "[image] #{path} · image/png · 9 B"
    assert_includes prompt.output.join("\n"), "\e_Ginline=1;preserveAspectRatio=1;width=40;name=#{Base64.strict_encode64(path)}:#{Base64.strict_encode64("png bytes")}\e\\"
  ensure
    original_term_program ? ENV["TERM_PROGRAM"] = original_term_program : ENV.delete("TERM_PROGRAM")
    original_kitty_window_id ? ENV["KITTY_WINDOW_ID"] = original_kitty_window_id : ENV.delete("KITTY_WINDOW_ID")
    File.delete(path) if path && File.exist?(path)
  end

  def test_user_transcript_uses_display_input_for_hidden_attachment
    path = "kward_hidden_transcript.png"
    original_term_program = ENV["TERM_PROGRAM"]
    original_kitty_window_id = ENV["KITTY_WINDOW_ID"]
    ENV.delete("TERM_PROGRAM")
    ENV["KITTY_WINDOW_ID"] = "1"
    File.binwrite(path, "png bytes")
    prompt = FakePrompt.new([])
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([]))

    cli.send(:print_user_transcript, "look\n#{path}", display_input: "look")

    output = prompt.output.join("\n")
    stripped = strip_ansi(output)
    assert_includes stripped, "You> look"
    refute_includes stripped, "You> look\n#{path}"
    assert_includes output, "[image] #{path} · image/png · 9 B"
    assert_includes output, "\e_Ginline=1;preserveAspectRatio=1;width=40;name=#{Base64.strict_encode64(path)}:#{Base64.strict_encode64("png bytes")}\e\\"
  ensure
    original_term_program ? ENV["TERM_PROGRAM"] = original_term_program : ENV.delete("TERM_PROGRAM")
    original_kitty_window_id ? ENV["KITTY_WINDOW_ID"] = original_kitty_window_id : ENV.delete("KITTY_WINDOW_ID")
    File.delete(path) if path && File.exist?(path)
  end

  def test_user_transcript_hides_data_url_text_and_renders_image_escape
    original_term_program = ENV["TERM_PROGRAM"]
    original_kitty_window_id = ENV["KITTY_WINDOW_ID"]
    ENV.delete("TERM_PROGRAM")
    ENV["KITTY_WINDOW_ID"] = "1"
    data = Base64.strict_encode64("png bytes")
    prompt = FakePrompt.new([])
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([]))

    cli.send(:print_user_transcript, "look\ndata:image/png;base64,#{data}", display_input: "look")

    output = prompt.output.join("\n")
    stripped = strip_ansi(output)
    assert_includes stripped, "You> look"
    refute_includes stripped, "You> look\ndata:image/png;base64"
    assert_includes output, "[image] pasted image · image/png · 9 B"
    assert_includes output, "\e_Ginline=1;preserveAspectRatio=1;width=40:#{data}\e\\"
  ensure
    original_term_program ? ENV["TERM_PROGRAM"] = original_term_program : ENV.delete("TERM_PROGRAM")
    original_kitty_window_id ? ENV["KITTY_WINDOW_ID"] = original_kitty_window_id : ENV.delete("KITTY_WINDOW_ID")
  end

  def test_user_transcript_skips_image_escape_without_supported_terminal
    path = "kward_unsupported_transcript.png"
    original_term = ENV["TERM"]
    original_term_program = ENV["TERM_PROGRAM"]
    original_kitty_window_id = ENV["KITTY_WINDOW_ID"]
    ENV["TERM"] = "xterm-256color"
    ENV.delete("TERM_PROGRAM")
    ENV.delete("KITTY_WINDOW_ID")
    File.binwrite(path, "png bytes")
    prompt = FakePrompt.new([])
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([]))

    cli.send(:print_user_transcript, "look #{path}")

    output = prompt.output.join("\n")
    assert_includes output, "[image] #{path} · image/png · 9 B"
    refute_includes output, "\e_G"
    refute_includes output, "\e]1337;File="
  ensure
    original_term ? ENV["TERM"] = original_term : ENV.delete("TERM")
    original_term_program ? ENV["TERM_PROGRAM"] = original_term_program : ENV.delete("TERM_PROGRAM")
    original_kitty_window_id ? ENV["KITTY_WINDOW_ID"] = original_kitty_window_id : ENV.delete("KITTY_WINDOW_ID")
    File.delete(path) if path && File.exist?(path)
  end

  def test_composer_attachment_badges_reports_missing_image
    prompt = FakePrompt.new([])
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([]))

    badges = cli.send(:composer_attachment_badges, "look Screenshot 2099-01-01 at 12.00.00.png")

    assert_equal ["[image?] Screenshot 2099-01-01 at 12.00.00.png not found"], badges
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

  def test_busy_input_queues_when_steering_submit_fails
    prompt = PollingPrompt.new(["fallback"])
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: RecordingClient.new([]))
    queued = []

    cli.send(:collect_busy_input, queued, FailingSteering.new)

    assert_equal ["fallback"], queued
  end

  def test_interactive_turn_steers_prompt_during_streaming_when_supported
    input, writer = IO.pipe
    output = StringIO.new
    prompt = Kward::PromptInterface.new(input: input, output: output)
    client = SteeringRecordingClient.new
    agent = Kward::Agent.new(client: client, tool_registry: Kward::ToolRegistry.new(prompt: prompt))
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client)

    writer_thread = Thread.new do
      sleep 0.03
      writer.write("steer this\r")
      writer.close
    end

    queued = cli.send(:run_interactive_turn, agent, "first")

    assert_empty queued
    rendered = strip_ansi(output.string)
    assert_equal ["first", "steer this"], agent.conversation.messages.select { |message| message[:role] == "user" }.map { |message| message[:content] }
    assert_equal "first", client.seen_messages[0][1][:content]
    assert_includes rendered, "steering"
    assert_includes rendered, "streaming"
    refute_includes rendered, "steered"
  ensure
    writer_thread&.join
    input&.close unless input&.closed?
  end

  def test_builtin_slash_commands_match_reserved_prompt_commands
    assert_equal Kward::CLI::BUILTIN_SLASH_COMMAND_NAMES.sort, Kward::PromptCommands::BUILTIN_RESERVED_COMMAND_NAMES.sort
  end

  def test_login_is_builtin_slash_command
    assert_includes Kward::CLI::BUILTIN_SLASH_COMMAND_NAMES, "login"
  end

  def test_login_slash_command_selects_openai_provider_without_calling_client
    prompt = FakeSettingsPrompt.new(["/login", "/exit"], ["OpenAI"])
    client = RecordingClient.new([])
    agent = Kward::Agent.new(client: client, tool_registry: Kward::ToolRegistry.new(prompt: prompt))
    cli = RecordingLoginCLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client)

    cli.interactive_loop(agent: agent)

    assert_equal ["openai"], cli.login_providers
    assert_equal ["OpenAI", "OpenRouter", "GitHub"], prompt.select_choices.first
    assert_equal "Login", prompt.select_titles.first
    assert_empty client.seen_messages
  end

  def test_login_slash_command_selects_github_provider_without_calling_client
    prompt = FakeSettingsPrompt.new(["/login", "/exit"], ["GitHub"])
    client = RecordingClient.new([])
    agent = Kward::Agent.new(client: client, tool_registry: Kward::ToolRegistry.new(prompt: prompt))
    cli = RecordingLoginCLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client)

    cli.interactive_loop(agent: agent)

    assert_equal ["github"], cli.login_providers
    assert_empty client.seen_messages
  end

  def test_login_slash_command_reports_failure_and_continues_session
    prompt = FakeSettingsPrompt.new(["/login", "/status", "/exit"], ["OpenAI"])
    client = RecordingClient.new([])
    agent = Kward::Agent.new(client: client, tool_registry: Kward::ToolRegistry.new(prompt: prompt))
    cli = RecordingLoginCLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client, fail_login: true)

    cli.interactive_loop(agent: agent)

    output = prompt.output.join("\n")
    assert_includes output, "Login error: OAuth timed out"
    assert_includes output, Kward::CLI::STATUS_MESSAGE
    assert_empty client.seen_messages
  end

  def test_status_slash_command_prints_static_status_without_calling_client
    prompt = FakePrompt.new(["/status", "/exit"])
    client = RecordingClient.new([])
    agent = Kward::Agent.new(client: client, tool_registry: Kward::ToolRegistry.new(prompt: prompt))
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client)

    cli.interactive_loop(agent: agent)

    assert_includes prompt.output.join("\n"), Kward::CLI::STATUS_MESSAGE
    assert_includes prompt.output.join("\n"), "Auto-compaction reserve:"
    assert_empty client.seen_messages
  end

  def test_status_shows_auto_compaction_disabled
    Dir.mktmpdir do |config_dir|
      config_path = File.join(config_dir, "config.json")
      File.write(config_path, JSON.dump({ "compaction" => { "enabled" => false } }))

      prompt = FakePrompt.new(["/status", "/exit"])
      client = RecordingClient.new([])
      agent = Kward::Agent.new(client: client, tool_registry: Kward::ToolRegistry.new(prompt: prompt))
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client)

      with_env("KWARD_CONFIG_PATH" => config_path) do
        cli.interactive_loop(agent: agent)
      end

      assert_includes prompt.output.join("\n"), "Auto-compaction: disabled"
    end
  end

  def test_memory_auto_summary_command_toggles_setting
    Dir.mktmpdir do |config_dir|
      config_path = File.join(config_dir, "config.json")
      prompt = FakePrompt.new(["/memory auto-summary enable", "/memory auto-summary disable", "/exit"])
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([]))
      agent = Kward::Agent.new(client: FakeClient.new([]), tool_registry: Kward::ToolRegistry.new(prompt: prompt), conversation: Kward::Conversation.new)

      with_env("KWARD_CONFIG_PATH" => config_path) do
        cli.interactive_loop(agent: agent)
      end

      config = JSON.parse(File.read(config_path))
      refute config.fetch("memory").key?("auto_summary")
      output = prompt.output.join("\n")
      assert_includes output, "Memory auto-summary enabled."
      assert_includes output, "Memory auto-summary disabled."
    end
  end

  def test_memory_summarize_only_uses_user_messages_for_inference
    Dir.mktmpdir do |config_dir|
      prompt = FakePrompt.new(["I am starting the session", "/memory summarize", "/exit"])
      client = FakeClient.new([
        "ok",
        { "content" => "The captain prefers concise and practical answers" }
      ])
      conversation = Kward::Conversation.new
      conversation.append_user("I usually prefer concise and practical answers.")
      conversation.append_assistant("I always use assistant-generated summaries.")
      conversation.append_tool(tool_call_id: "skill_1", name: "read_skill", content: "Prefer focused tests and always use minitest.")
      agent = Kward::Agent.new(client: client, tool_registry: Kward::ToolRegistry.new(prompt: prompt), conversation: conversation)
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client)
      config_path = File.join(config_dir, "config.json")

      with_env("KWARD_CONFIG_PATH" => config_path) do
        cli.interactive_loop(agent: agent)
      end

      # LLM summarization reformulates first-person to third-person
      assert_equal ["The captain prefers concise and practical answers"], conversation.session_memories.map { |memory| memory["text"] }
      assert_equal ["soft_001"], conversation.session_memories.map { |memory| memory["id"] }
      refute_includes conversation.session_memories.map { |memory| memory["text"] }, "Prefer focused tests and always use minitest"
      refute_includes conversation.session_memories.map { |memory| memory["text"] }, "I always use assistant-generated summaries"
      assert_includes prompt.output.join, "Learned 1 soft memory."
    end
  end

  def test_memory_auto_summary_runs_after_interactive_turn_when_enabled
    Dir.mktmpdir do |config_dir|
      config_path = File.join(config_dir, "config.json")
      File.write(config_path, JSON.dump("memory" => { "enabled" => true, "auto_summary" => true }))
      prompt = FakePrompt.new(["Here is an important information: I usually prefer concise and practical answers.", "/exit"])
      client = FakeClient.new([
        { "role" => "assistant", "content" => "ok" },
        { "content" => "The captain prefers concise and practical answers" }
      ])
      conversation = Kward::Conversation.new
      agent = Kward::Agent.new(client: client, tool_registry: Kward::ToolRegistry.new(prompt: prompt), conversation: conversation)
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client)

      with_env("KWARD_CONFIG_PATH" => config_path) do
        cli.interactive_loop(agent: agent)
      end

      assert_equal ["The captain prefers concise and practical answers"], conversation.session_memories.map { |memory| memory["text"] }
      refute_includes prompt.output.join("\n"), "Learned 1 soft memory."
    end
  end

  def test_memory_auto_summary_requires_memory_enabled
    Dir.mktmpdir do |config_dir|
      config_path = File.join(config_dir, "config.json")
      File.write(config_path, JSON.dump("memory" => { "auto_summary" => true }))
      prompt = FakePrompt.new(["Here is an important information: I usually prefer concise and practical answers.", "/exit"])
      client = FakeClient.new([
        { "role" => "assistant", "content" => "ok" },
        { "content" => "The captain prefers concise and practical answers" }
      ])
      conversation = Kward::Conversation.new
      agent = Kward::Agent.new(client: client, tool_registry: Kward::ToolRegistry.new(prompt: prompt), conversation: conversation)
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client)

      with_env("KWARD_CONFIG_PATH" => config_path) do
        cli.interactive_loop(agent: agent)
      end

      assert_empty conversation.session_memories
    end
  end

  def test_model_slash_command_shows_loading_spinner_before_overlay
    Dir.mktmpdir do |config_dir|
      config_path = File.join(config_dir, "config.json")
      File.write(config_path, JSON.dump({}))
      prompt = BusySelectPrompt.new(["/model", "/exit"])
      client = SlowModelsClient.new([])
      agent = Kward::Agent.new(client: client, tool_registry: Kward::ToolRegistry.new(prompt: prompt))
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client)

      with_env("KWARD_CONFIG_PATH" => config_path) do
        cli.interactive_loop(agent: agent)
      end

      loading_index = prompt.events.index([:begin_busy_input, "You>", "loading"])
      assert loading_index
      finish_after_loading = prompt.events[loading_index..].index([:finish_busy_input])
      assert finish_after_loading
      assert_equal ["Default model"], prompt.select_messages
    end
  end

  def test_compact_slash_command_keeps_busy_composer_visible_while_running
    Dir.mktmpdir do |config_dir|
      config_path = File.join(config_dir, "config.json")
      File.write(config_path, JSON.dump({ "compaction" => { "keep_recent_tokens" => 20 } }))
      prompt = BusyPrompt.new(["hello with enough detail to compact", "second turn before compaction", "/compact focus", "/exit"])
      client = RecordingClient.new(["reply", "second reply", "summary"])
      agent = Kward::Agent.new(client: client, tool_registry: Kward::ToolRegistry.new(prompt: prompt))
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client)

      with_env("KWARD_CONFIG_PATH" => config_path) do
        cli.interactive_loop(agent: agent)
      end

      compacting_index = prompt.events.index([:begin_busy_input, "You>", "compacting"])
      assert compacting_index
      finish_after_compacting = prompt.events[compacting_index..].index([:finish_busy_input])
      assert finish_after_compacting
      assert_includes prompt.output.join("\n"), "Compacted context:"
    end
  end

  def test_memory_summarize_keeps_busy_composer_visible_while_running
    Dir.mktmpdir do |config_dir|
      prompt = BusyPrompt.new(["I am starting the session", "/memory summarize", "/exit"])
      client = FakeClient.new([
        "ok",
        { "content" => "The captain prefers concise and practical answers" }
      ])
      conversation = Kward::Conversation.new
      conversation.append_user("I usually prefer concise and practical answers.")
      agent = Kward::Agent.new(client: client, tool_registry: Kward::ToolRegistry.new(prompt: prompt), conversation: conversation)
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client)
      config_path = File.join(config_dir, "config.json")

      with_env("KWARD_CONFIG_PATH" => config_path) do
        cli.interactive_loop(agent: agent)
      end

      summarizing_index = prompt.events.index([:begin_busy_input, "You>", "summarizing"])
      assert summarizing_index
      finish_after_summarizing = prompt.events[summarizing_index..].index([:finish_busy_input])
      assert finish_after_summarizing
      assert_equal ["The captain prefers concise and practical answers"], conversation.session_memories.map { |memory| memory["text"] }
    end
  end

  def test_composer_status_includes_context_percentage_when_available
    context_usage = Object.new
    def context_usage.call(**_kwargs)
      { percent: 12.4 }
    end
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), client: FakeClient.new([]), context_usage: context_usage)
    conversation = Kward::Conversation.new(system_message: nil)
    conversation.append_user("Status report.")
    cli.instance_variable_set(:@footer_conversation, conversation)

    assert_equal "12% · Codex fake-model · medium", cli.send(:composer_status_text)
  end

  def test_composer_status_colors_context_percentage_by_threshold
    context_usage = Object.new
    percent = 49
    context_usage.define_singleton_method(:call) do |**_kwargs|
      { percent: percent }
    end
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), client: FakeClient.new([]), context_usage: context_usage)
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

    assert_equal "Codex fake-model · medium", cli.send(:composer_status_text)
  end

  def test_composer_status_shows_reasoning_for_copilot_gpt_5_responses_models
    client = FakeClient.new([])
    client.provider = "Copilot"
    client.model = "gpt-5-mini"
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), client: client)

    assert_equal "Copilot gpt-5-mini · medium", cli.send(:composer_status_text)
  end

  def test_composer_status_keeps_reasoning_unavailable_for_copilot_chat_models
    client = FakeClient.new([])
    client.provider = "Copilot"
    client.model = "gemini-2.5-pro"
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), client: client)

    assert_equal "Copilot gemini-2.5-pro · n/a", cli.send(:composer_status_text)
  end

  def test_composer_status_shows_session_diff_before_context_percentage
    context_usage = Object.new
    def context_usage.call(**_kwargs)
      { percent: 42 }
    end
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), client: FakeClient.new([]), context_usage: context_usage)
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

    cli.send(:run_interactive_turn, agent, "hello")

    assert_equal 1, prompt.redraw_count
    assert_equal "+2|-1 · 10% · Codex fake-model · medium", strip_ansi(cli.send(:composer_status_text))
  end

  def test_prompt_interface_ignores_non_mutation_tool_result_diff_text
    prompt = BusyPrompt.new([])
    content = "Exit status: 0\n\nSTDOUT:\n--- file.txt\n+++ file.txt\n@@ -1,25 +0,0 @@\n" + (1..25).map { |index| "-line #{index}\n" }.join
    agent = EventAgent.new([Kward::Events::ToolResult.new(tool_call: tool_call("run_shell_command", command: "git diff"), content: content)])
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([]))

    cli.send(:run_interactive_turn, agent, "hello")

    assert_equal 0, prompt.redraw_count
    assert_equal "Codex fake-model · medium", strip_ansi(cli.send(:composer_status_text))
  end

  def test_piped_prompt_reads_non_tty_input
    cli = Kward::CLI.new(stdin: FakeInput.new("hello from stdin\n", tty: false), client: FakeClient.new([]))

    assert_equal "hello from stdin", cli.piped_prompt
  end

  def test_piped_prompt_ignores_tty_input
    cli = Kward::CLI.new(stdin: FakeInput.new("ignored", tty: true), client: FakeClient.new([]))

    assert_equal "", cli.piped_prompt
  end

  def test_interactive_plugin_slash_command_runs_without_calling_client
    Dir.mktmpdir do |home|
      plugins_dir = File.join(home, ".kward", "plugins")
      FileUtils.mkdir_p(plugins_dir)
      File.write(File.join(plugins_dir, "count.rb"), <<~'RUBY')
        Kward.plugin do |plugin|
          plugin.command "count", description: "Count transcript messages" do |_args, ctx|
            ctx.say("messages=#{ctx.transcript.messages.length}")
          end
        end
      RUBY
      prompt = FakePrompt.new(["hello", "/count", "/exit"])
      client = RecordingClient.new(["reply"])

      with_env("HOME" => home, "KWARD_CONFIG_PATH" => nil) do
        agent = Kward::Agent.new(client: client, tool_registry: Kward::ToolRegistry.new(prompt: prompt))
        cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client)
        cli.interactive_loop(agent: agent)
      end

      assert_equal 1, client.seen_messages.length
      assert_includes prompt.output.join("\n"), "messages=3"
    end
  end

end
