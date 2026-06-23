require "shellwords"
require_relative "test_helper"

class TestCLI < KwardTestCase
  def rewrite_session_timestamps(path, timestamps_by_id)
    lines = File.readlines(path).map do |line|
      record = JSON.parse(line)
      timestamp = timestamps_by_id[record["id"]]
      record["timestamp"] = timestamp.utc.iso8601(3) if timestamp
      JSON.generate(record)
    end
    File.write(path, lines.join("\n") + "\n")
  end

  def hide_composer_git_branch(cli)
    cli.define_singleton_method(:composer_git_branch_text) { nil }
  end

  class RecordingPromptInterface < FakePrompt
    attr_reader :options, :started

    def initialize(**options)
      super([])
      @options = options
      @started = false
    end

    def start
      @started = true
    end
  end

  class RecordingPromptInterfaceCLI < Kward::CLI
    def load_prompt_interface
      RecordingPromptInterface
    end
  end

  class BannerPrompt < FakePrompt
    attr_reader :banner_count

    def initialize(inputs)
      super(inputs)
      @banner_count = 0
    end

    def print_visual_banner(message = nil)
      @banner_count += 1
      @output << (message || "[visual banner]")
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

  class BusyWorkersPrompt < FakePrompt
    attr_reader :busy_inputs, :select_messages

    def initialize(inputs, selections:, tasks:)
      super(tasks)
      @poll_inputs = inputs
      @selections = selections
      @busy_inputs = []
      @select_messages = []
    end

    def poll_input
      @poll_inputs.shift
    end

    def begin_busy_input(message, activity: "streaming")
      @busy_inputs << [message, activity]
    end

    def modal_active?
      false
    end

    def select(message, choices, title: "Sessions", custom: false, initial_index: 0, action_keys: {}, action_handlers: {})
      @select_messages << message
      @selections.shift || choices.first
    end

    def say(message)
      super
      Object.new
    end
  end

  class BusyWorkersCLI < Kward::CLI
    private

    def send_worker_request(topic, _agent)
      @prompt.say("Worker sent: #{topic}")
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

    def select(message, choices, title: "Sessions", custom: false, initial_index: 0, action_keys: {}, action_handlers: {})
      @select_messages << message
      @select_choices << choices
      @select_titles << title
      @select_initial_indices << initial_index
      @selections.empty? ? choices.first : @selections.shift
    end
  end

  class BusyPollingSelectPrompt < BusySelectPrompt
    def initialize(inputs, selections: [])
      super([], selections: selections)
      @poll_inputs = inputs
    end

    def poll_input
      @poll_inputs.shift
    end
  end

  class DelayedEventAgent
    attr_reader :conversation

    def initialize(conversation, delay:, events:, answer: "")
      @conversation = conversation
      @delay = delay
      @events = events
      @answer = answer
    end

    def ask(_input, **_options)
      sleep @delay
      @events.each { |event| yield event }
      @answer
    end
  end

  class SlowModelsClient < FakeClient
    def available_models
      sleep 0.05
      super
    end
  end

  class ReloadTrackingClient < FakeClient
    def initialize
      super([])
    end
  end

  def with_fake_net_http(responses)
    fake_http = Object.new
    fake_http.define_singleton_method(:requests) { @requests ||= [] }
    fake_http.define_singleton_method(:request) do |request|
      requests << request
      responses.shift
    end
    original_start = Net::HTTP.method(:start)
    Net::HTTP.define_singleton_method(:start) do |_host, _port, **_options, &block|
      block.call(fake_http)
    end
    yield fake_http
  ensure
    Net::HTTP.define_singleton_method(:start, original_start) if original_start
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

  def test_sysprompt_prints_annotated_effective_prompt
    Dir.mktmpdir do |config_dir|
      Dir.mktmpdir do |workspace_dir|
        Dir.mktmpdir do |home|
          File.write(File.join(config_dir, "config.json"), JSON.dump({
            "personas" => {
              "workspaces" => { workspace_dir => "Workspace persona." }
            }
          }))
          File.write(File.join(config_dir, "PRINCIPLES.md"), "Global principles.\n")
          File.write(File.join(workspace_dir, "AGENTS.md"), "Workspace instructions.\n")
          plugins_dir = File.join(home, ".kward", "plugins")
          FileUtils.mkdir_p(plugins_dir)
          File.write(File.join(plugins_dir, "context.rb"), <<~'RUBY')
            Kward.plugin do |plugin|
              plugin.prompt_context { |ctx| "Plugin workspace: #{ctx.workspace_root}" }
            end
          RUBY

          prompt = FakePrompt.new([])
          with_env("HOME" => home, "KWARD_CONFIG_PATH" => File.join(config_dir, "config.json")) do
            Kward::CLI.new(argv: ["--working-directory", workspace_dir, "sysprompt"], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([])).run
          end

          output = prompt.output.join("\n")
          assert_includes output, "Kward System Prompt"
          workspace_root = File.realpath(workspace_dir)
          assert_includes output, "Workspace: #{workspace_root}"
          assert_includes output, "## Config principles"
          assert_includes output, "Source: #{File.join(config_dir, "PRINCIPLES.md")}"
          assert_includes output, "Global principles."
          assert_includes output, "## Persona"
          assert_includes output, "Workspace persona."
          assert_includes output, "## Plugin context"
          assert_includes output, "Plugin workspace: #{workspace_root}"
          assert_includes output, "## Workspace AGENTS.md hint"
          assert_includes output, File.join(workspace_root, "AGENTS.md")
          refute_includes output, "Workspace instructions."
          assert_includes output, "Memory: not included"
        end
      end
    end
  end

  def test_sysprompt_raw_prints_unannotated_effective_prompt
    Dir.mktmpdir do |config_dir|
      Dir.mktmpdir do |workspace_dir|
        File.write(File.join(config_dir, "config.json"), JSON.dump({}))
        File.write(File.join(config_dir, "PRINCIPLES.md"), "Global principles.\n")
        File.write(File.join(workspace_dir, "AGENTS.md"), "Workspace instructions.\n")

        prompt = FakePrompt.new([])
        with_env("KWARD_CONFIG_PATH" => File.join(config_dir, "config.json")) do
          Kward::CLI.new(argv: ["--working-directory=#{workspace_dir}", "sysprompt", "--raw"], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([])).run
        end

        output = prompt.output.join("\n")
        assert_includes output, "You are Kward"
        assert_includes output, "Global principles."
        assert_includes output, "Workspace guidance is available"
        refute_includes output, "Kward System Prompt"
        refute_includes output, "## Config principles"
        refute_includes output, "Workspace instructions."
      end
    end
  end

  def test_init_command_creates_default_config_and_reports_result
    Dir.mktmpdir do |config_dir|
      prompt = FakePrompt.new([])
      calls = []
      original_install = Kward::StarterPackInstaller.method(:install)
      Kward::StarterPackInstaller.define_singleton_method(:install) do
        calls << true
        Kward::StarterPackInstaller::Result.new(installed: ["PRINCIPLES.md"], skipped: ["prompts/plan.md"])
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

  def test_install_starter_pack_flag_is_treated_as_prompt
    Dir.mktmpdir do |config_dir|
      client = RecordingClient.new(["reply"])

      with_env("KWARD_CONFIG_PATH" => File.join(config_dir, "config.json")) do
        capture_io do
          Kward::CLI.new(argv: ["--install-starter-pack"], stdin: FakeInput.new("", tty: true), prompt: FakePrompt.new([]), client: client).run
        end

        assert_equal "--install-starter-pack", client.seen_messages.first.last[:content]
      end
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

    assert_equal ["OpenAI", "Anthropic", "OpenRouter", "GitHub"], cli.send(:login_provider_choices)
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

  def test_prompt_interface_interactive_turn_returns_after_question_answer_without_extra_input
    input, writer = IO.pipe
    output = StringIO.new
    prompt = Kward::PromptInterface.new(input: input, output: output)
    client = FakeClient.new([
      assistant_tool_call("ask_user_question", { questions: [question_args("Proceed?")] }),
      { "role" => "assistant", "content" => "done" }
    ])
    registry = Kward::ToolRegistry.new(prompt: prompt, skills: [])
    agent = Kward::Agent.new(client: client, tool_registry: registry, conversation: Kward::Conversation.new)
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client)
    queued_inputs = nil

    thread = Thread.new { queued_inputs = cli.send(:run_interactive_turn, agent, "/plan fix", display_input: "/plan fix") }
    wait_until { prompt.instance_variable_get(:@question_state) }
    writer.write("\r")
    thread.join(1)

    refute thread.alive?, "turn should finish after the question answer without requiring another keypress"
    assert_equal [], queued_inputs
  ensure
    thread&.kill if thread&.alive?
    writer&.close unless writer&.closed?
    input&.close unless input&.closed?
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
    readme_tool_call = tool_call("read_file", path: "README.md")
    events = [
      Kward::Events::AssistantDelta.new(delta: "before tool"),
      Kward::Events::ToolCall.new(tool_call: readme_tool_call),
      Kward::Events::ToolResult.new(tool_call: readme_tool_call, content: "README contents\n")
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

    assistant_output = capture_io { cli.send(:start_stream_block, "Assistant") }.first
    reasoning_output = capture_io { cli.send(:start_stream_block, "Reasoning") }.first
    retry_output = capture_io { cli.send(:start_stream_block, "Retry") }.first
    tool_output = capture_io { cli.send(:print_tool_result, tool_call("read_file", path: "README.md"), "content") }.first
    failed_tool_output = capture_io { cli.send(:print_tool_result, tool_call("read_file", path: "README.md"), "Error: missing") }.first

    runtime_prompt = FakePrompt.new([])
    runtime_cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: runtime_prompt, client: FakeClient.new([]))
    runtime_cli.instance_variable_set(:@color_enabled, true)
    runtime_cli.send(:runtime_output, "Saved.")

    assert_includes assistant_output, "\e[32;1mAssistant>\e[0m"
    assert_includes reasoning_output, "\e[90;1mReasoning>\e[0m"
    assert_includes retry_output, "\e[33;1mRetry>\e[0m"
    assert_includes tool_output, "\e[36;1mTool>\e[0m"
    assert_includes failed_tool_output, "\e[31;1mTool>\e[0m"
    assert_includes runtime_prompt.output.join, "\e[90;1mRuntime>\e[0m"
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
        assert_includes system_message, "Workspace guidance is available"
        assert_includes system_message, File.join(File.realpath(workspace_dir), "AGENTS.md")
        refute_includes system_message, "Workspace marker from option"
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

  def test_removed_pan_mode_flag_is_treated_as_prompt
    Dir.mktmpdir do |config_dir|
      client = RecordingClient.new(["reply"])
      cli = Kward::CLI.new(argv: ["--pan-mode"], stdin: FakeInput.new("", tty: true), client: client)

      with_env("KWARD_CONFIG_PATH" => File.join(config_dir, "config.json")) do
        output = capture_io { cli.run }.first

        assert_includes output, "reply"
        assert_equal "--pan-mode", client.seen_messages.first.last[:content]
      end
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
    assert_equal 4, conversation.messages.length
    assert_equal 5, conversation.context_messages.length
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
      messages = records.select { |record| record["type"] == "message" }.map { |record| record["message"] }
      assert_equal "hello", messages[0]["content"]
      assert_equal "reply", messages[1]["content"]
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

  def test_interactive_mode_resumes_last_session_on_startup_when_enabled
    Dir.mktmpdir do |config_dir|
      config_path = File.join(config_dir, "config.json")
      File.write(config_path, JSON.dump("sessions" => { "auto_resume" => true }))
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      first_prompt = FakePrompt.new(["hello", "/exit"])
      first_client = RecordingClient.new(["reply"])
      with_env("KWARD_CONFIG_PATH" => config_path) do
        Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: first_prompt, client: first_client, session_store: store).interactive_loop
      end

      assert_path_exists store.last_session_path

      second_prompt = BannerPrompt.new(["again", "/exit"])
      second_client = RecordingClient.new(["second"])
      with_env("KWARD_CONFIG_PATH" => config_path) do
        Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: second_prompt, client: second_client, session_store: store).interactive_loop
      end

      assert_equal "hello", second_client.seen_messages[0][1]["content"]
      assert_equal "reply", second_client.seen_messages[0][2]["content"]
      assert_equal "again", second_client.seen_messages[0][3][:content]
      assert_equal 0, second_prompt.banner_count
      output = strip_ansi(second_prompt.output.join("\n"))
      assert_includes output, "Resumed session:"
      assert_includes output, "You> hello"
      assert_includes output, "reply"
    end
  end

  def test_interactive_mode_starts_new_session_when_auto_resume_disabled
    Dir.mktmpdir do |config_dir|
      config_path = File.join(config_dir, "config.json")
      File.write(config_path, JSON.dump("sessions" => { "auto_resume" => false }))
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      first_prompt = FakePrompt.new(["hello", "/exit"])
      first_client = RecordingClient.new(["reply"])
      with_env("KWARD_CONFIG_PATH" => config_path) do
        Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: first_prompt, client: first_client, session_store: store).interactive_loop
      end

      second_prompt = FakePrompt.new(["again", "/exit"])
      second_client = RecordingClient.new(["second"])
      with_env("KWARD_CONFIG_PATH" => config_path) do
        Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: second_prompt, client: second_client, session_store: store).interactive_loop
      end

      message = second_client.seen_messages[0][1]
      assert_equal "again", message["content"] || message[:content]
      output = strip_ansi(second_prompt.output.join("\n"))
      refute_includes output, "Resumed session:"
      refute_includes output, "You> hello"
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
      output = prompt.output.join("\n")
      assert_includes output, "Kward v#{Kward::VERSION} is online."
      assert_includes output, "State your business."
      files = Dir.glob(File.join(store.session_dir, "*.jsonl"))
      assert_equal 1, files.length
      refute_includes File.read(files.first), "Kward v#{Kward::VERSION} is online."
    end
  end

  def test_startup_plugins_value_lists_loaded_plugin_filenames
    registry = Kward::PluginRegistry.new
    registry.instance_variable_set(:@paths, ["/tmp/plugins/alpha.rb", "/tmp/plugins/beta.rb"])
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: FakePrompt.new([]), client: RecordingClient.new([]))
    cli.instance_variable_set(:@plugin_registry, registry)

    assert_equal "alpha.rb, beta.rb", cli.send(:startup_plugins_value)
  end

  def test_startup_plugins_value_shows_none_without_loaded_plugins
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: FakePrompt.new([]), client: RecordingClient.new([]))
    cli.instance_variable_set(:@plugin_registry, Kward::PluginRegistry.new)

    assert_equal "none", cli.send(:startup_plugins_value)
  end

  def test_startup_info_screen_uses_color_when_enabled
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: FakePrompt.new([]), client: RecordingClient.new([]))
    cli.instance_variable_set(:@color_enabled, true)
    cli.instance_variable_set(:@plugin_registry, Kward::PluginRegistry.new)

    output = cli.send(:startup_info_screen)

    assert_includes output, "\e[32m●\e[0m Kward v#{Kward::VERSION} is online."
    refute_includes output, "\e[36;1mKward\e[0m"
    assert_includes output, "\e[90mWorkspace   \e[0m"
    assert_includes output, "\e[1mState your business.\e[0m"
    refute_includes output, "\e[33;1mState your business.\e[0m"
    assert_includes Kward::ANSI.strip(output), "Plugins     none"
  end

  def test_startup_workspace_label_uses_parent_and_folder_outside_home
    Dir.mktmpdir do |dir|
      workspace = File.join(dir, "kaiwood", "kward")
      FileUtils.mkdir_p(workspace)
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: FakePrompt.new([]), client: RecordingClient.new([]))
      cli.instance_variable_set(:@working_directory, workspace)

      with_env("HOME" => File.join(dir, "home")) do
        assert_equal "kaiwood/kward", cli.send(:startup_workspace_label)
      end
    end
  end

  def test_startup_workspace_label_uses_parent_and_folder_for_nested_path_inside_home
    Dir.mktmpdir do |home|
      workspace = File.join(home, "Repositories", "github.com", "kaiwood", "kward")
      FileUtils.mkdir_p(workspace)
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: FakePrompt.new([]), client: RecordingClient.new([]))
      cli.instance_variable_set(:@working_directory, workspace)

      with_env("HOME" => home) do
        assert_equal "kaiwood/kward", cli.send(:startup_workspace_label)
      end
    end
  end

  def test_startup_workspace_label_uses_home_relative_path_for_direct_child_of_home
    Dir.mktmpdir do |home|
      workspace = File.join(home, "project")
      FileUtils.mkdir_p(workspace)
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: FakePrompt.new([]), client: RecordingClient.new([]))
      cli.instance_variable_set(:@working_directory, workspace)

      with_env("HOME" => home) do
        assert_equal "~/project", cli.send(:startup_workspace_label)
      end
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

  def test_rename_names_empty_session_and_keeps_it_on_exit
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      prompt = FakePrompt.new(["/rename Useful", "/exit"])
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: RecordingClient.new([]), session_store: store)

      cli.interactive_loop

      files = Dir.glob(File.join(store.session_dir, "*.jsonl"))
      assert_equal 1, files.length
      assert jsonl_records(files.first).any? { |record| record["type"] == "session_info" && record["name"] == "Useful" }
    end
  end

  def test_rename_requires_name
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      prompt = FakePrompt.new(["/rename", "/exit"])
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: RecordingClient.new([]), session_store: store)

      cli.interactive_loop

      assert prompt.output.any? { |line| line.include?("Usage: /rename <name>") }
      assert_empty Dir.glob(File.join(store.session_dir, "*.jsonl"))
    end
  end

  def test_name_does_not_enter_busy_state
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      prompt = BusyPrompt.new(["/name Useful", "/exit"])
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: RecordingClient.new([]), session_store: store)

      cli.interactive_loop

      refute_includes prompt.events, [:begin_busy_input, "You>", "loading"]
      assert prompt.output.any? { |line| line.include?("Named session: Useful") }
      assert jsonl_records(Dir.glob(File.join(store.session_dir, "*.jsonl")).first).any? { |record| record["type"] == "session_info" && record["name"] == "Useful" }
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
    refute_includes output, "Tool output>"
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

  def test_sessions_explicit_session_path_loads_prior_messages
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      saved = store.create
      conversation = Kward::Conversation.new
      saved.attach(conversation)
      conversation.append_user("hello")
      conversation.append_assistant("reply")
      prompt = BannerPrompt.new(["/sessions #{saved.path}", "again", "/exit"])
      client = RecordingClient.new(["second"])
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client, session_store: store)

      cli.interactive_loop

      assert_equal "hello", client.seen_messages[0][1]["content"]
      assert_equal "reply", client.seen_messages[0][2]["content"]
      assert_equal "again", client.seen_messages[0][3][:content]
      assert_equal 1, prompt.banner_count
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

  def test_resume_picker_loads_sessions_with_spinner_before_opening_picker
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      saved = store.create
      conversation = Kward::Conversation.new
      saved.attach(conversation)
      conversation.append_user("hello")
      prompt = BusyPrompt.new(["/resume", "/exit"])
      prompt.define_singleton_method(:select) do |_message, choices, title: "Sessions", custom: false, **_kwargs|
        events << [:select_session]
        choices.first
      end
      store.define_singleton_method(:recent_tree) do |limit: 20|
        prompt.events << [:recent_tree, limit]
        super(limit: limit)
      end
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: RecordingClient.new([]), session_store: store)

      cli.interactive_loop

      recent_index = prompt.events.index([:recent_tree, nil])
      select_index = prompt.events.index([:select_session])
      loading_start_index = prompt.events.index([:begin_busy_input, "You>", "loading"])
      loading_finish_index = prompt.events.index([:finish_busy_input])
      assert recent_index
      assert select_index
      assert loading_start_index
      assert loading_finish_index
      assert_operator loading_start_index, :<, recent_index
      assert_operator recent_index, :<, loading_finish_index
      assert_operator loading_finish_index, :<, select_index
    end
  end

  def test_resume_picker_displays_cloned_sessions_as_tree_children
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      source = store.create
      conversation = Kward::Conversation.new(system_message: nil)
      source.attach(conversation)
      conversation.append_user("source prompt")
      store.create_independent_from_conversation(conversation, parent_session: source)
      prompt = BusySelectPrompt.new(["/resume", "/exit"])
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: RecordingClient.new([]), session_store: store)

      cli.interactive_loop

      choices = prompt.select_choices.first
      assert choices.any? { |label| label.start_with?("└─ source prompt") }, choices.inspect
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
      hide_composer_git_branch(cli)

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
      assert_includes output, "Reasoning> Need to inspect the file."
      assert_includes output, "I'll read it."
      assert_includes output, "Tool> read_file: README.md\n\n1 lines, 16 bytes"
      refute_includes output, "Tool output>"
      assert_includes output, "1 lines, 16 bytes"
      refute_includes output, "README contents"
    end
  end

  def test_resume_renders_response_item_reasoning_and_hides_commentary
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      saved = store.create
      conversation = Kward::Conversation.new
      saved.attach(conversation)
      conversation.append_user("inspect file")
      conversation.append_assistant({
        "role" => "assistant",
        "content" => "",
        "tool_calls" => [tool_call("read_file", path: "README.md")],
        "response_items" => [
          { "type" => "reasoning", "summary" => [{ "type" => "summary_text", "text" => "Need context." }] },
          { "type" => "message", "phase" => "commentary", "content" => [{ "type" => "output_text", "text" => "Need inspect file first." }] },
          { "type" => "function_call", "id" => "fc_1", "call_id" => "call_read_file", "name" => "read_file", "arguments" => JSON.dump("path" => "README.md") }
        ]
      })
      conversation.append_tool(tool_call_id: "call_read_file", name: "read_file", content: "README contents\n")
      prompt = FakePrompt.new(["/resume #{saved.path}", "/exit"])
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: RecordingClient.new([]), session_store: store)

      cli.interactive_loop

      output = strip_ansi(prompt.output.join("\n"))
      assert_includes output, "Reasoning> Need context."
      refute_includes output, "Need inspect file first."
      assert_includes output, "Tool> read_file: README.md\n\n1 lines, 16 bytes"
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
    assert_includes read_output, "read_file: README.md\n\n2 lines, 18 bytes"
    assert_includes read_output, "2 lines, 18 bytes"
    refute_includes read_output, "line one"

    shell_output = capture_io do
      cli.send(:print_tool_result, tool_call("run_shell_command", command: "echo ok"), "Exit status: 0\n\nSTDOUT:\nok\n\nSTDERR:\nwarn\n")
    end.first
    assert_includes shell_output, "run_shell_command: echo ok\n\nExit status: 0"
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

    summary = strip_ansi(output).split("Tool> ", 2).last
    assert_equal 10, summary.lines.reject { |line| line == "\n" }.length
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

      assert_includes output, "Tool>"
      refute_includes output, "Tool output>"
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
      assert_includes output, "Tool> custom_tool: line1\n\nline2"
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

  def test_sessions_picker_clone_action_ignores_missing_inserted_copy
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      source = store.create
      conversation = Kward::Conversation.new
      source.attach(conversation)
      conversation.append_user("saved prompt")
      prompt = FakePrompt.new([])
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: RecordingClient.new([]), session_store: store)
      sessions = store.recent_tree(limit: nil)
      labels = cli.send(:session_picker_labels, sessions)

      result = cli.send(:copy_session_selection, store, sessions, labels, labels.first) do
        File.join(store.session_dir, "missing.jsonl")
      end

      assert_nil result
    end
  end

  def test_sessions_picker_clone_action_clones_and_keeps_picker_open
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      source = store.create
      conversation = Kward::Conversation.new
      source.attach(conversation)
      conversation.append_user("saved prompt")
      conversation.append_assistant("saved reply")
      prompt = FakePrompt.new(["/sessions", "/exit"])
      prompt.define_singleton_method(:select) do |_message, choices, title: "Sessions", custom: false, initial_index: 0, action_keys: {}, action_handlers: {}|
        @clone_result = action_handlers.fetch(action_keys.fetch("c")[:action]).call(choices.first)
        nil
      end
      client = RecordingClient.new([])
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client, session_store: store)

      cli.interactive_loop

      files = Dir.glob(File.join(store.session_dir, "*.jsonl"))
      assert_equal 2, files.length
      clone_path = (files - [source.path]).first
      clone_result = prompt.instance_variable_get(:@clone_result)
      cloned_label = clone_result[:choices][clone_result[:selection_index]]

      assert_equal true, clone_result[:select_continue]
      assert_includes cloned_label, File.basename(clone_path)
      refute_includes strip_ansi(prompt.output.join("\n")), "Cloned session: #{clone_path}"
    end
  end

  def test_sessions_picker_fork_action_opens_fork_prompt_selector
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      source = store.create
      conversation = Kward::Conversation.new
      source.attach(conversation)
      conversation.append_user("kept prompt")
      conversation.append_assistant("kept reply")
      conversation.append_user("saved prompt")
      conversation.append_assistant("saved reply")
      prompt = FakePrompt.new(["/sessions", "/exit"])
      prompt.define_singleton_method(:select) do |message, choices, title: "Sessions", custom: false, initial_index: 0, action_keys: {}, action_handlers: {}|
        @select_messages ||= []
        @select_titles ||= []
        @select_choices ||= []
        @select_initial_indices ||= []
        @select_messages << message
        @select_titles << title
        @select_choices << choices
        @select_initial_indices << initial_index
        if message == "Session>" && @select_messages.count("Session>") == 1
          action = action_keys.fetch("f")
          { action: action.is_a?(Hash) ? action[:action] : action, choice: choices.first, defer_finish_render: action.is_a?(Hash) && action[:defer_finish_render] }
        elsif message == "Session>"
          @forked_label = choices[initial_index]
          nil
        else
          choices.find { |choice| choice.include?("saved prompt") } || choices.first
        end
      end
      client = RecordingClient.new([])
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client, session_store: store)

      cli.interactive_loop

      files = Dir.glob(File.join(store.session_dir, "*.jsonl"))
      assert_equal 2, files.length
      fork_path = (files - [source.path]).first
      fork_session, fork_conversation = store.load(fork_path)
      fork_messages = fork_conversation.messages.reject { |message| (message["role"] || message[:role]) == "system" }
      output = strip_ansi(prompt.output.join("\n"))

      assert_equal ["Session>", "Fork>", "Session>"], prompt.instance_variable_get(:@select_messages)
      assert_equal "Fork", prompt.instance_variable_get(:@select_titles)[1]
      assert_empty prompt.prefilled_inputs
      assert_equal prompt.instance_variable_get(:@forked_label), prompt.instance_variable_get(:@select_choices)&.last&.[](prompt.instance_variable_get(:@select_initial_indices)&.last)
      assert_equal ["kept prompt", "kept reply"], fork_messages.map { |message| message["content"] || message[:content] }
      assert_equal fork_session.leaf_id, fork_messages.last["id"]
      refute_includes output, "Forked session: #{fork_path}"
      refute_includes File.read(fork_path), "saved prompt"
      refute_includes File.read(fork_path), "saved reply"
      source_header = jsonl_records(source.path).find { |record| record["type"] == "session" }
      fork_header = jsonl_records(fork_path).find { |record| record["type"] == "session" }
      assert_equal source_header["id"], fork_header["parentId"]
    end
  end

  def test_sessions_picker_repeated_fork_action_does_not_escape_as_agent
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      source = store.create
      conversation = Kward::Conversation.new
      source.attach(conversation)
      conversation.append_user("kept prompt")
      conversation.append_assistant("kept reply")
      conversation.append_user("saved prompt")
      conversation.append_assistant("saved reply")
      prompt = FakePrompt.new(["/sessions"])
      prompt.define_singleton_method(:select) do |message, choices, title: "Sessions", custom: false, initial_index: 0, action_keys: {}, action_handlers: {}|
        @select_messages ||= []
        @select_messages << message
        if message == "Session>"
          return nil if @select_messages.count("Session>") == 3

          action = action_keys.fetch("f")
          { action: action.is_a?(Hash) ? action[:action] : action, choice: choices[initial_index] || choices.first, defer_finish_render: action.is_a?(Hash) && action[:defer_finish_render] }
        else
          return nil if @select_messages.count("Fork>") == 2

          choices.find { |choice| choice.include?("saved prompt") } || choices.first
        end
      end
      client = RecordingClient.new([])
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client, session_store: store)

      conversation = cli.interactive_loop

      assert_kind_of Kward::Conversation, conversation
      assert_equal ["Session>", "Fork>", "Session>", "Fork>", "Session>"], prompt.instance_variable_get(:@select_messages)
      assert_equal 2, Dir.glob(File.join(store.session_dir, "*.jsonl")).length
    end
  end

  def test_sessions_picker_rename_action_keeps_picker_open
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      source = store.create
      conversation = Kward::Conversation.new
      source.attach(conversation)
      conversation.append_user("saved prompt")
      prompt = FakePrompt.new(["/sessions", "/exit"])
      test = self
      prompt.define_singleton_method(:select) do |message, choices, title: "Sessions", custom: false, initial_index: 0, action_keys: {}, action_handlers: {}|
        @select_messages ||= []
        @select_choices ||= []
        @select_initial_indices ||= []
        @select_messages << message
        @select_choices << choices
        @select_initial_indices << initial_index
        action = action_keys.fetch("r")
        test.assert_equal :rename, action[:action]
        test.assert_equal "Name>", action[:input_prompt]
        result = action_handlers.fetch(:rename).call(choices.first, "Renamed session")
        @select_choices << result[:choices]
        @select_initial_indices << result[:selection_index]
        nil
      end
      client = RecordingClient.new([])
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client, session_store: store)

      cli.interactive_loop

      records = jsonl_records(source.path)
      assert_equal "Renamed session", records.select { |record| record["type"] == "session_info" }.last["name"]
      assert_equal ["Session>"], prompt.instance_variable_get(:@select_messages)
      assert_includes prompt.instance_variable_get(:@select_choices).last[prompt.instance_variable_get(:@select_initial_indices).last], "Renamed session"
    end
  end

  def test_sessions_picker_delete_action_deletes_selected_session
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      source = store.create
      conversation = Kward::Conversation.new
      source.attach(conversation)
      conversation.append_user("saved prompt")
      prompt = FakePrompt.new(["/sessions", "/exit"])
      test = self
      prompt.define_singleton_method(:select) do |_message, choices, title: "Sessions", custom: false, initial_index: 0, action_keys: {}, action_handlers: {}|
        test.assert_equal "Press d again to delete, Esc to cancel.", action_keys.fetch("d")[:confirm]
        result = action_handlers.fetch(action_keys.fetch("d")[:action]).call(choices.first)
        test.assert_equal [], result[:choices]
        nil
      end
      original_new = Kward::SessionTrash.method(:new)
      Kward::SessionTrash.define_singleton_method(:new) do |**_kwargs|
        Object.new.tap do |trash|
          trash.define_singleton_method(:delete) do |path|
            File.delete(path) if File.exist?(path)
            true
          end
        end
      end
      client = RecordingClient.new([])
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client, session_store: store)

      cli.interactive_loop

      refute File.exist?(source.path)
    ensure
      Kward::SessionTrash.define_singleton_method(:new, original_new) if original_new
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
      assert_equal 1, prompt.select_choices.first.length
      assert_match(/\Aselected session — #{Regexp.escape(File.basename(saved.path))}\s+just now\z/, prompt.select_choices.first.first)
      assert_equal "selected session", client.seen_messages[0][1]["content"]
      assert_equal "again", client.seen_messages[0][3][:content]
    end
  end


  def test_fork_slash_command_creates_new_session_from_selected_prompt
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      session = store.create
      conversation = Kward::Conversation.new(system_message: nil)
      session.attach(conversation)
      conversation.append_user("keep this")
      conversation.append_assistant("kept reply")
      conversation.append_user("edit this prompt")
      conversation.append_assistant("future reply")
      prompt = FakeSessionSelectPrompt.new(["/resume #{session.path}", "/fork", "/exit"], "edit this prompt")
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: RecordingClient.new([]), session_store: store)

      cli.interactive_loop

      files = Dir.glob(File.join(store.session_dir, "*.jsonl"))
      assert_equal 2, files.length
      fork_path = (files - [session.path]).first
      fork_session, fork_conversation = store.load(fork_path)
      fork_messages = fork_conversation.messages.reject { |message| (message["role"] || message[:role]) == "system" }
      output = strip_ansi(prompt.output.join("\n"))

      assert_equal ["Fork>"], prompt.select_messages.last(1)
      assert_equal "Fork", prompt.select_titles.last
      assert_equal ["edit this prompt"], prompt.prefilled_inputs
      assert_equal ["keep this", "kept reply"], fork_messages.map { |message| message["content"] || message[:content] }
      assert_equal fork_session.leaf_id, fork_messages.last["id"]
      assert_includes output, "Forked session: #{fork_path}"
      refute_includes File.read(fork_path), "edit this prompt"
      refute_includes File.read(fork_path), "future reply"
      source = jsonl_records(session.path).find { |record| record["type"] == "session" }
      fork = jsonl_records(fork_path).find { |record| record["type"] == "session" }
      assert_equal source["id"], fork["parentId"]
    end
  end

  def test_fork_slash_command_without_composer_prefill_does_not_auto_run_selected_text
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      session = store.create
      conversation = Kward::Conversation.new(system_message: nil)
      session.attach(conversation)
      conversation.append_user("first prompt")
      prompt = FakeSessionSelectNoPrefillPrompt.new(["/resume #{session.path}", "/fork", "/exit"], "first prompt")
      client = RecordingClient.new(["should not be used"])
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client, session_store: store)

      cli.interactive_loop

      assert_empty client.seen_messages
      assert_includes prompt.output.join("\n"), "Selected prompt for editing:\nfirst prompt"
    end
  end

  def test_rewind_slash_command_selects_user_prompt_and_prefills_prompt
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      session = store.create
      conversation = Kward::Conversation.new(system_message: nil)
      session.attach(conversation)
      conversation.append_user("first prompt")
      conversation.append_assistant("first reply")
      conversation.append_user("edit this prompt")
      conversation.append_assistant("future reply")
      prompt = FakeSessionSelectPrompt.new(["/resume #{session.path}", "/rewind", "/exit"], "edit this prompt")
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: RecordingClient.new([]), session_store: store)

      cli.interactive_loop
      loaded_session, loaded_conversation = store.load(session.path)

      assert_equal ["Rewind>"], prompt.select_messages.last(1)
      assert_equal "Rewind", prompt.select_titles.last
      assert prompt.select_choices.last.all? { |choice| choice.include?("prompt") }
      assert prompt.select_choices.last.first.include?("Last prompt: edit this prompt")
      assert_equal ["edit this prompt"], prompt.prefilled_inputs
      assert_equal "first reply", loaded_conversation.messages.reject { |message| (message["role"] || message[:role]) == "system" }.last["content"]
      assert_equal loaded_session.leaf_id, loaded_conversation.messages.reject { |message| (message["role"] || message[:role]) == "system" }.last["id"]
    end
  end

  def test_settings_interface_can_change_editor_mode
    Dir.mktmpdir do |dir|
      config_path = File.join(dir, "config.json")
      Kward::ConfigFiles.write_config({ "editor" => { "mode" => "default" } }, config_path)
      prompt = FakeSettingsPrompt.new(["/settings", "/exit"], ["Interface", "Editor mode (nano)", "vi"])
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: RecordingClient.new([]))

      with_env("KWARD_CONFIG_PATH" => config_path) do
        cli.interactive_loop
      end

      assert_equal "vi", JSON.parse(File.read(config_path)).dig("editor", "mode")
      assert_includes prompt.output.join("\n"), "Editor mode set to vi. New editor buffers will use this mode."
      editor_mode_index = prompt.select_messages.index("Editor mode")
      assert editor_mode_index
      assert_includes prompt.select_choices[editor_mode_index], "nano (current)"
      assert_includes prompt.select_choices[editor_mode_index], "emacs"
      assert_includes prompt.select_choices[editor_mode_index], "vi"
    end
  end

  def test_rewind_slash_command_can_return_to_where_user_was
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      session = store.create
      conversation = Kward::Conversation.new(system_message: nil)
      session.attach(conversation)
      conversation.append_user("first prompt")
      conversation.append_assistant("first reply")
      conversation.append_user("edit this prompt")
      conversation.append_assistant("future reply")
      prompt = FakeSettingsPrompt.new(
        ["/resume #{session.path}", "/rewind", "/rewind", "/exit"],
        []
      )
      prompt.define_singleton_method(:select) do |message, choices, title: "Sessions", custom: false, initial_index: 0, **_kwargs|
        @select_messages << message
        @select_choices << choices
        @select_titles << title
        @select_initial_indices << initial_index
        choices.find { |choice| choice.include?("Return to where I was") } || choices.find { |choice| choice.include?("Last prompt: edit this prompt") }
      end
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: RecordingClient.new([]), session_store: store)

      cli.interactive_loop
      loaded_session, loaded_conversation = store.load(session.path)

      assert_equal ["edit this prompt"], prompt.prefilled_inputs
      assert_includes prompt.select_choices[1].first, "Return to where I was: future reply"
      assert_equal "future reply", loaded_conversation.messages.reject { |message| (message["role"] || message[:role]) == "system" }.last["content"]
      assert_equal loaded_session.leaf_id, loaded_conversation.messages.reject { |message| (message["role"] || message[:role]) == "system" }.last["id"]
    end
  end

  def test_rewind_slash_command_shows_only_user_prompts
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      session = store.create
      conversation = Kward::Conversation.new(system_message: nil)
      session.attach(conversation)
      conversation.append_user("root prompt")
      conversation.append_assistant({
        "role" => "assistant",
        "content" => nil,
        "tool_calls" => [tool_call("read_file", path: "README.md")]
      })
      conversation.append_tool(tool_call_id: "call_read_file", name: "read_file", content: "README contents")
      conversation.append_assistant("assistant reply")
      conversation.append_user("latest prompt")
      prompt = FakeSessionSelectPrompt.new(["/resume #{session.path}", "/rewind", "/exit"], "root prompt")
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: RecordingClient.new([]), session_store: store)

      cli.interactive_loop

      choices = prompt.select_choices.last
      assert_equal 2, choices.length
      assert choices.any? { |choice| choice.include?("root prompt") }
      assert choices.any? { |choice| choice.include?("latest prompt") }
      refute choices.any? { |choice| choice.include?("assistant reply") }
      refute choices.any? { |choice| choice.include?("README contents") }
      refute choices.any? { |choice| choice.include?("read_file") }
    end
  end

  def test_rewind_slash_command_shows_relative_timestamps
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      session = store.create
      conversation = Kward::Conversation.new(system_message: nil)
      session.attach(conversation)
      conversation.append_user("older prompt")
      older_entry = session.leaf_id
      conversation.append_assistant("older reply")
      conversation.append_user("newer prompt")
      newer_entry = session.leaf_id
      rewrite_session_timestamps(session.path, { older_entry => Time.now.utc - 14 * 60, newer_entry => Time.now.utc - 4 * 60 })
      prompt = FakeSessionSelectPrompt.new(["/resume #{session.path}", "/rewind", "/exit"], "older prompt")
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: RecordingClient.new([]), session_store: store)

      cli.interactive_loop

      choices = prompt.select_choices.last
      assert choices.any? { |choice| choice.include?("newer prompt") && choice.end_with?("4 min ago") }
      assert choices.any? { |choice| choice.include?("older prompt") && choice.end_with?("14 min ago") }
    end
  end

  def test_rewind_slash_command_uses_display_content_for_prefill
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      session = store.create
      conversation = Kward::Conversation.new(system_message: nil)
      session.attach(conversation)
      conversation.append_user("Plan this:\nfix bug\n", display_content: "/plan fix bug")
      conversation.append_assistant("future reply")
      prompt = FakeSessionSelectPrompt.new(["/resume #{session.path}", "/rewind", "/exit"], "/plan fix bug")
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: RecordingClient.new([]), session_store: store)

      cli.interactive_loop

      assert_equal ["/plan fix bug"], prompt.prefilled_inputs
      assert prompt.select_choices.last.any? { |choice| choice.include?("Last prompt: /plan fix bug") }
    end
  end

  def test_rewind_slash_command_without_composer_prefill_does_not_auto_run_selected_text
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      session = store.create
      conversation = Kward::Conversation.new(system_message: nil)
      session.attach(conversation)
      conversation.append_user("first prompt")
      prompt = FakeSessionSelectNoPrefillPrompt.new(["/resume #{session.path}", "/rewind", "/exit"], "first prompt")
      client = RecordingClient.new(["should not be used"])
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client, session_store: store)

      cli.interactive_loop

      assert_empty client.seen_messages
      assert_includes prompt.output.join("\n"), "Selected prompt for editing:\nfirst prompt"
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

  def test_tree_slash_command_loads_tree_with_spinner_before_opening_picker
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      session = store.create
      conversation = Kward::Conversation.new(system_message: nil)
      session.attach(conversation)
      conversation.append_user("first prompt")
      conversation.append_assistant("first reply")
      prompt = BusySelectPrompt.new(["/resume #{session.path}", "/tree", "/exit"])
      prompt.define_singleton_method(:select) do |message, choices, title: "Sessions", custom: false, initial_index: 0, **_kwargs|
        events << [:select, message, title, initial_index]
        choices.first
      end
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: RecordingClient.new([]), session_store: store)

      cli.interactive_loop

      tree_select_index = prompt.events.index { |event| event[0] == :select && event[1] == "Tree>" }
      loading_indices = prompt.events.each_index.select { |index| prompt.events[index] == [:begin_busy_input, "You>", "loading"] }
      tree_loading_index = loading_indices.find { |index| tree_select_index && index < tree_select_index }
      tree_finish_index = prompt.events[tree_loading_index..tree_select_index]&.index([:finish_busy_input])
      assert tree_select_index
      assert tree_loading_index
      assert tree_finish_index
      assert_operator tree_loading_index, :<, tree_select_index
      assert_operator tree_loading_index + tree_finish_index, :<, tree_select_index
    end
  end

  def test_tree_slash_command_applies_selection_with_loading_spinner
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      session = store.create
      conversation = Kward::Conversation.new(system_message: nil)
      session.attach(conversation)
      conversation.append_user("first prompt")
      conversation.append_assistant("first reply")
      conversation.append_user("edit this prompt")
      prompt = BusySelectPrompt.new(["/resume #{session.path}", "/tree", "/exit"])
      prompt.define_singleton_method(:select) do |message, choices, title: "Sessions", custom: false, initial_index: 0, **_kwargs|
        events << [:select, message, title, initial_index]
        choices.find { |choice| choice.include?("edit this prompt") } || choices.first
      end
      prompt.define_singleton_method(:prefill_input) do |value|
        events << [:prefill_input, value]
        super(value)
      end
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: RecordingClient.new([]), session_store: store)

      cli.interactive_loop

      tree_select_index = prompt.events.index { |event| event[0] == :select && event[1] == "Tree>" }
      loading_indices = prompt.events.each_index.select { |index| prompt.events[index] == [:begin_busy_input, "You>", "loading"] }
      tree_loading_index = loading_indices.find { |index| tree_select_index && index > tree_select_index }
      tree_finish_index = prompt.events[tree_loading_index..]&.index([:finish_busy_input])
      prefill_index = prompt.events.index([:prefill_input, "edit this prompt"])
      assert tree_select_index
      assert tree_loading_index
      assert tree_finish_index
      assert prefill_index
      assert_operator tree_select_index, :<, tree_loading_index
      assert_operator tree_loading_index + tree_finish_index, :<, prefill_index
    end
  end

  def test_tree_slash_command_uses_display_content_for_prefill
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      session = store.create
      conversation = Kward::Conversation.new(system_message: nil)
      session.attach(conversation)
      conversation.append_user("Plan this:\nfix bug\n", display_content: "/plan fix bug")
      conversation.append_assistant("future reply")
      prompt = FakeSessionSelectPrompt.new(["/resume #{session.path}", "/tree", "/exit"], "/plan fix bug")
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: RecordingClient.new([]), session_store: store)

      cli.interactive_loop

      assert_equal ["/plan fix bug"], prompt.prefilled_inputs
      assert prompt.select_choices.last.any? { |choice| choice.include?("user: /plan fix bug") }
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
      root_choice = choices.find { |choice| choice.include?("root prompt") }
      assert root_choice.start_with?("• user: root prompt"), root_choice
      assert_includes active_choice, "      ├⊟ • user: active branch"
      assert_includes side_choice, "      └⊟ user: side branch"
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
      assert_match(/\Aroot session — #{Regexp.escape(File.basename(source.path))}\s+1 min ago\z/, prompt.select_choices.first.first)
      assert prompt.select_choices.first.any? { |choice| choice.match?(/\A└─ clone session — #{Regexp.escape(File.basename(clone.path))}\s+just now\z/) }
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
      assert prompt.select_choices.first.any? { |choice| choice.match?(/\Asaved session — #{Regexp.escape(File.basename(saved.path))}\s+just now\z/) }
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
      assert prompt.select_choices.first.any? { |choice| choice.match?(/\AUseful — .*\s+just now\z/) }
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

  def test_interactive_prompt_slash_command_persists_original_display_content_and_session_name
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
        assert_equal "/plan fix bug", store.recent.first.name
        assert_equal "/plan fix bug", store.recent.first.first_message
      end
    end
  end

  def test_interactive_first_plain_input_persists_session_name
    Dir.mktmpdir do |dir|
      store = Kward::SessionStore.new(config_dir: dir, cwd: Dir.pwd)
      prompt = FakePrompt.new(["Something is not working", "/exit"])
      client = RecordingClient.new(["done"])
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client, session_store: store)

      cli.interactive_loop

      assert_equal "Something is not working", store.recent.first.name
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

  def test_workers_command_requires_experimental_flag
    prompt = FakePrompt.new([])
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: RecordingClient.new([]))
    agent = Kward::Agent.new(client: RecordingClient.new([]), tool_registry: Kward::ToolRegistry.new(prompt: prompt))

    handled, replacement = cli.send(:handle_local_slash_command, "/workers", agent, nil)

    assert handled
    assert_nil replacement
    assert_includes prompt.output.join, "--experimental-workers"
  end

  def test_busy_input_opens_workers_command_without_queuing
    prompt = PollingPrompt.new(["/workers"])
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: RecordingClient.new([]))
    cli.instance_variable_set(:@experimental_workers, true)
    queued = []

    cli.send(:collect_busy_input, queued, nil, Object.new)

    assert_empty queued
    assert_includes prompt.output.join, "Usage: /workers"
  end

  def test_busy_workers_new_read_only_does_not_replace_agent_with_prompt_output
    prompt = BusyWorkersPrompt.new(["/workers"], selections: ["New worker"], tasks: ["map the codebase"])
    cli = BusyWorkersCLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: RecordingClient.new([]))
    cli.instance_variable_set(:@experimental_workers, true)
    agent = Object.new
    agent.define_singleton_method(:conversation) { Object.new }
    agent.define_singleton_method(:ask) { |_input, **_options| "" }
    queued = []

    cli.send(:collect_busy_input, queued, nil, agent)

    assert_empty queued
    assert_nil cli.instance_variable_get(:@busy_replacement_agent)
    assert_equal [["You>", "streaming"]], prompt.busy_inputs
    assert_equal ["Workers"], prompt.select_messages
    assert_includes prompt.output.join, "Worker sent: map the codebase"
  end

  def test_interactive_session_store_is_reused_for_background_workers
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: FakePrompt.new([]), client: RecordingClient.new([]))

    session_store = cli.send(:interactive_session_store, nil)

    assert_instance_of Kward::SessionStore, session_store
    assert_same session_store, cli.instance_variable_get(:@session_store)
  end

  def test_busy_input_queues_when_steering_submit_fails
    prompt = PollingPrompt.new(["fallback"])
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: RecordingClient.new([]))
    queued = []

    cli.send(:collect_busy_input, queued, FailingSteering.new)

    assert_equal ["fallback"], queued
  end

  def test_busy_input_queues_slash_command_instead_of_steering
    prompt = PollingPrompt.new(["/git"])
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: RecordingClient.new([]))
    queued = []
    submitted = []
    steering = Object.new
    steering.define_singleton_method(:submit) { |input| submitted << input }

    cli.send(:collect_busy_input, queued, steering)

    assert_equal ["/git"], queued
    assert_empty submitted
  end

  def test_tab_busy_input_queues_slash_command_instead_of_steering
    prompt = FakePrompt.new([])
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: RecordingClient.new([]))
    submitted = []
    steering = Object.new
    steering.define_singleton_method(:submit) { |input| submitted << input }
    tab = Kward::CLI::Tabs::TabRuntime.new(queued_inputs: [], steering: steering)

    cli.send(:handle_tab_busy_input, tab, "/git")

    assert_equal ["/git"], tab.queued_inputs
    assert_empty submitted
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
    assert_includes rendered, "You> steer this"
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

  def test_workers_show_streams_live_worker_events
    Dir.mktmpdir do |dir|
      config_dir = File.join(dir, "config")
      workspace = File.join(dir, "workspace")
      FileUtils.mkdir_p(workspace)
      session_store = Kward::SessionStore.new(config_dir: config_dir, cwd: workspace)
      worker_store = Kward::Workers::Store.new(path: File.join(config_dir, "workers.json"))
      session = session_store.create(provider: "openai", model: "gpt-test", reasoning_effort: nil)
      conversation = Kward::Conversation.new(workspace_root: workspace, provider: "openai", model: "gpt-test")
      session.attach(conversation)
      worker = Kward::Workers::Worker.new(id: "abc123", title: "worker task", role: "request", workspace_root: workspace, status: "running", prompt: "worker task", conversation: conversation, session: session)
      manager = Object.new
      manager.define_singleton_method(:list) { [worker] }
      manager.define_singleton_method(:find) { |id| id == worker.id ? worker : nil }
      prompt = BusySelectPrompt.new([], selections: ["List workers", "abc123 [request/running] worker task", "Show"])
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([]), session_store: session_store)
      cli.instance_variable_set(:@experimental_workers, true)
      cli.instance_variable_set(:@worker_store, worker_store)
      cli.instance_variable_set(:@experimental_workers, true)
      cli.instance_variable_set(:@worker_manager, manager)
      agent = Kward::Agent.new(client: FakeClient.new([]), tool_registry: Kward::ToolRegistry.new, conversation: Kward::Conversation.new(workspace_root: workspace))

      _handled, replacement = cli.send(:handle_local_slash_command, "/workers", agent, session_store)
      worker.event_history << Kward::Events::AssistantMessage.new(message: { "role" => "assistant", "content" => "live answer" })
      worker.update_status("ready")

      wait_until(timeout: 1) { prompt.output.join.include?("live answer") }
      cli.send(:stop_live_worker_view)
      assert replacement
      assert_includes prompt.output.join, "live answer"
    end
  end

  def test_busy_workers_show_suppresses_old_turn_rendering_after_switch
    Dir.mktmpdir do |dir|
      config_dir = File.join(dir, "config")
      workspace = File.join(dir, "workspace")
      FileUtils.mkdir_p(workspace)
      session_store = Kward::SessionStore.new(config_dir: config_dir, cwd: workspace)
      worker_store = Kward::Workers::Store.new(path: File.join(config_dir, "workers.json"))
      worker_session = session_store.create(provider: "openai", model: "gpt-test", reasoning_effort: nil)
      worker_conversation = Kward::Conversation.new(workspace_root: workspace, provider: "openai", model: "gpt-test")
      worker_session.attach(worker_conversation)
      worker_conversation.append_user("worker task")
      worker_conversation.append_assistant("worker transcript")
      worker = Kward::Workers::Worker.new(id: "abc123", title: "worker task", role: "request", workspace_root: workspace, status: "running", prompt: "worker task", conversation: worker_conversation, session: worker_session)
      manager = Object.new
      manager.define_singleton_method(:list) { [worker] }
      manager.define_singleton_method(:find) { |id| id == worker.id ? worker : nil }
      prompt = BusyPollingSelectPrompt.new(["/workers"], selections: ["List workers", "abc123 [request/running] worker task", "Show"])
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([]), session_store: session_store)
      cli.instance_variable_set(:@experimental_workers, true)
      cli.instance_variable_set(:@worker_store, worker_store)
      cli.instance_variable_set(:@experimental_workers, true)
      cli.instance_variable_set(:@worker_manager, manager)
      implementation_conversation = Kward::Conversation.new(workspace_root: workspace, provider: "openai", model: "gpt-test")
      agent = DelayedEventAgent.new(
        implementation_conversation,
        delay: 0.05,
        events: [Kward::Events::AssistantDelta.new(delta: "implementation overwrite")],
        answer: "implementation final"
      )

      cli.send(:run_interactive_turn, agent, "implementation task")
      cli.send(:stop_live_worker_view)

      rendered = prompt.output.join
      assert_includes rendered, "worker transcript"
      refute_includes rendered, "implementation overwrite"
      refute_includes rendered, "implementation final"
    end
  end

  def test_workers_dismiss_archives_runtime_worker
    Dir.mktmpdir do |dir|
      config_dir = File.join(dir, "config")
      workspace = File.join(dir, "workspace")
      FileUtils.mkdir_p(workspace)
      session_store = Kward::SessionStore.new(config_dir: config_dir, cwd: workspace)
      worker_store = Kward::Workers::Store.new(path: File.join(config_dir, "workers.json"))
      worker = Kward::Workers::Worker.new(id: "abc123", title: "worker task", role: "request", workspace_root: workspace, status: "ready", prompt: "worker task")
      worker_store.upsert(worker)
      manager = Object.new
      archived = []
      manager.define_singleton_method(:list) { [worker].reject { |item| item.status == "archived" } }
      manager.define_singleton_method(:find) { |id| id == worker.id ? worker : nil }
      manager.define_singleton_method(:archive) { |id| archived << id; worker.update_status("archived") }
      prompt = BusySelectPrompt.new([], selections: ["List workers", "abc123 [request/ready] worker task", "Dismiss"])
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([]), session_store: session_store)
      cli.instance_variable_set(:@experimental_workers, true)
      cli.instance_variable_set(:@worker_store, worker_store)
      cli.instance_variable_set(:@experimental_workers, true)
      cli.instance_variable_set(:@worker_manager, manager)
      agent = Kward::Agent.new(client: FakeClient.new([]), tool_registry: Kward::ToolRegistry.new, conversation: Kward::Conversation.new(workspace_root: workspace))

      handled, replacement = cli.send(:handle_local_slash_command, "/workers", agent, session_store)

      assert handled
      assert_nil replacement
      assert_equal ["abc123"], archived
      assert_equal "archived", worker.status
      assert_equal "archived", worker_store.find("abc123").fetch("status")
      refute_includes cli.send(:worker_jobs, agent).map { |job| job.fetch("id") }, "abc123"
    end
  end

  def test_request_worker_yes_queues_implementation_worker
    Dir.mktmpdir do |dir|
      config_dir = File.join(dir, "config")
      workspace = File.join(dir, "workspace")
      FileUtils.mkdir_p(workspace)
      session_store = Kward::SessionStore.new(config_dir: config_dir, cwd: workspace)
      request_session = session_store.create(provider: "openai", model: "gpt-test", reasoning_effort: nil)
      request_conversation = Kward::Conversation.new(workspace_root: workspace, provider: "openai", model: "gpt-test")
      request_session.attach(request_conversation)
      request_conversation.append_user("append baz")
      request_conversation.append_assistant("Should we proceed?")
      request_worker = Kward::Workers::Worker.new(id: "abc123", title: "append baz", role: "request", workspace_root: workspace, status: "ready", prompt: "append baz", conversation: request_conversation, session: request_session)
      request_worker.update_status("ready", report: "# Request Review\nAppend baz.\n\nShould we proceed?")
      client = RecordingClient.new(["implementation done"])
      prompt = BusyPrompt.new(["yes", "/exit"])
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client, session_store: session_store)
      manager = Kward::Workers::Manager.new(
        client_factory: -> { client },
        prompt: prompt,
        workspace_root: workspace,
        session_store: session_store,
        provider: "openai",
        model: "gpt-test",
        write_lock: Kward::Workers::WriteLock.new
      )
      cli.instance_variable_set(:@experimental_workers, true)
      cli.instance_variable_set(:@worker_manager, manager)
      cli.instance_variable_set(:@worker_manager_workspace_root, Kward::ConfigFiles.canonical_workspace_root(workspace))
      cli.instance_variable_set(:@visible_worker, request_worker)
      cli.instance_variable_set(:@visible_worker_id, request_worker.id)
      cli.instance_variable_set(:@active_worker_role, "request")
      cli.instance_variable_set(:@active_session, request_session)
      agent = cli.send(:build_worker_agent, request_conversation, role: "request")
      cli.instance_variable_set(:@active_worker_role, "request")
      cli.instance_variable_set(:@session_store, session_store)

      cli.interactive_loop(agent: agent)

      output = prompt.output.join
      assert_includes output, "Worker abc123 queued from request abc123"
      wait_until(timeout: 1) { client.seen_messages.any? }
      implementation_prompt = client.seen_messages.last.find { |message| message[:role] == "user" || message["role"] == "user" }
      implementation_text = Kward::MessageAccess.content(implementation_prompt)
      assert_includes implementation_text, "Original request:"
      assert_includes implementation_text, "append baz"
      assert_includes implementation_text, "Request review:"
      assert_includes implementation_text, "Append baz."
    end
  end

  def test_request_worker_non_approval_input_is_blocked
    Dir.mktmpdir do |dir|
      config_dir = File.join(dir, "config")
      workspace = File.join(dir, "workspace")
      FileUtils.mkdir_p(workspace)
      session_store = Kward::SessionStore.new(config_dir: config_dir, cwd: workspace)
      session = session_store.create(provider: "openai", model: "gpt-test", reasoning_effort: nil)
      conversation = Kward::Conversation.new(workspace_root: workspace, provider: "openai", model: "gpt-test")
      session.attach(conversation)
      worker = Kward::Workers::Worker.new(id: "abc123", title: "append baz", role: "request", workspace_root: workspace, status: "ready", prompt: "append baz", conversation: conversation, session: session)
      client = RecordingClient.new([])
      prompt = BusyPrompt.new(["what about tests?", "/exit"])
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client, session_store: session_store)
      cli.instance_variable_set(:@visible_worker, worker)
      cli.instance_variable_set(:@visible_worker_id, worker.id)
      cli.instance_variable_set(:@active_worker_role, "request")
      cli.instance_variable_set(:@experimental_workers, true)
      cli.instance_variable_set(:@active_session, session)
      agent = cli.send(:build_worker_agent, conversation, role: "request")
      cli.instance_variable_set(:@active_worker_role, "request")
      cli.instance_variable_set(:@session_store, session_store)

      cli.interactive_loop(agent: agent)

      assert_empty client.seen_messages
      assert_includes prompt.output.join, "read-only request review"
    end
  end

  def test_workers_show_switches_to_worker_session
    Dir.mktmpdir do |dir|
      config_dir = File.join(dir, "config")
      workspace = File.join(dir, "workspace")
      FileUtils.mkdir_p(workspace)
      session_store = Kward::SessionStore.new(config_dir: config_dir, cwd: workspace)
      worker_store = Kward::Workers::Store.new(path: File.join(config_dir, "workers.json"))
      session = session_store.create(provider: "openai", model: "gpt-test", reasoning_effort: nil)
      conversation = Kward::Conversation.new(workspace_root: workspace, provider: "openai", model: "gpt-test")
      session.attach(conversation)
      conversation.append_user("worker task")
      conversation.append_assistant("worker answer")
      worker = Kward::Workers::Worker.new(id: "abc123", title: "worker task", role: "request", workspace_root: workspace, status: "ready", prompt: "worker task", conversation: conversation, session: session)
      worker_store.upsert(worker)
      prompt = BusySelectPrompt.new([], selections: ["List workers", "abc123 [request/ready] worker task", "Show"])
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([]), session_store: session_store)
      cli.instance_variable_set(:@experimental_workers, true)
      cli.instance_variable_set(:@worker_store, worker_store)
      agent = Kward::Agent.new(client: FakeClient.new([]), tool_registry: Kward::ToolRegistry.new, conversation: Kward::Conversation.new(workspace_root: workspace))

      handled, replacement = cli.send(:handle_local_slash_command, "/workers", agent, session_store)

      assert handled
      assert replacement
      assert_equal "worker answer", Kward::MessageAccess.content(replacement.conversation.messages.last)
      refute_includes replacement.tool_registry.schemas.map { |schema| schema.dig(:function, :name) || schema.dig("function", "name") }, "write_file"
      refute_includes prompt.output.join, "Worker abc123 [ready]"
    end
  end

  def test_refresh_implementation_writer_reacquires_released_lock
    conversation = Kward::Conversation.new
    prompt = BusySelectPrompt.new([])
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([]))
    write_lock = Kward::Workers::WriteLock.new
    assert write_lock.acquire("background")
    cli.instance_variable_set(:@worker_write_lock, write_lock)
    cli.instance_variable_set(:@active_worker_role, "implementation")
    agent = cli.send(:build_worker_agent, conversation, role: "implementation")
    assert_nil agent.tool_registry.writer_id

    write_lock.release("background")
    refreshed = cli.send(:refresh_implementation_writer, agent)

    assert_equal "implementation", refreshed.tool_registry.writer_id
  end

  def test_workers_list_includes_implementation_worker
    Dir.mktmpdir do |dir|
      config_dir = File.join(dir, "config")
      workspace = File.join(dir, "workspace")
      FileUtils.mkdir_p(workspace)
      session_store = Kward::SessionStore.new(config_dir: config_dir, cwd: workspace)
      session = session_store.create(provider: "openai", model: "gpt-test", reasoning_effort: nil)
      conversation = Kward::Conversation.new(workspace_root: workspace, provider: "openai", model: "gpt-test")
      session.attach(conversation)
      prompt = BusySelectPrompt.new([], selections: ["List workers", "implementation [implementation/active] Implementation", "Show"])
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([]), session_store: session_store)
      cli.instance_variable_set(:@experimental_workers, true)
      cli.instance_variable_set(:@active_session, session)
      agent = cli.send(:build_interactive_agent, conversation)

      _handled, replacement = cli.send(:handle_local_slash_command, "/workers", agent, session_store)

      assert replacement
      assert_includes prompt.select_choices[1], "implementation [implementation/active] Implementation"
    end
  end

  def test_workers_slash_entry_is_hidden_without_experimental_flag
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: FakePrompt.new([]), client: FakeClient.new([]))

    refute_includes cli.send(:slash_command_entries).map { |entry| entry[:name] }, "workers"
  end

  def test_workers_slash_entry_is_visible_with_experimental_flag
    cli = Kward::CLI.new(argv: ["--experimental-workers"], stdin: FakeInput.new("", tty: true), prompt: FakePrompt.new([]), client: FakeClient.new([]))
    cli.send(:extract_global_options, ["--experimental-workers"])

    assert_includes cli.send(:slash_command_entries).map { |entry| entry[:name] }, "workers"
  end

  def test_login_slash_command_selects_openai_provider_without_calling_client
    prompt = FakeSettingsPrompt.new(["/login", "/exit"], ["OpenAI"])
    client = RecordingClient.new([])
    agent = Kward::Agent.new(client: client, tool_registry: Kward::ToolRegistry.new(prompt: prompt))
    cli = RecordingLoginCLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client)

    cli.interactive_loop(agent: agent)

    assert_equal ["openai"], cli.login_providers
    assert_equal ["OpenAI", "Anthropic", "OpenRouter", "GitHub"], prompt.select_choices.first
    assert_equal "Login", prompt.select_titles.first
    assert_empty client.seen_messages
  end

  def test_login_slash_command_shows_running_spinner_after_provider_selection
    prompt = BusySelectPrompt.new(["/login", "/exit"], selections: ["OpenAI"])
    client = RecordingClient.new([])
    agent = Kward::Agent.new(client: client, tool_registry: Kward::ToolRegistry.new(prompt: prompt))
    cli = RecordingLoginCLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client)

    cli.interactive_loop(agent: agent)

    running_index = prompt.events.index([:begin_busy_input, "You>", "running"])
    assert running_index
    finish_after_running = prompt.events[running_index..].index([:finish_busy_input])
    assert finish_after_running
    assert_equal ["openai"], cli.login_providers
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

  def test_memory_commands_use_runtime_output_label
    Dir.mktmpdir do |config_dir|
      config_path = File.join(config_dir, "config.json")
      prompt = FakePrompt.new(["/memory core Captain likes coffee", "/memory list", "/memory forget core_001", "/exit"])
      client = FakeClient.new([])
      agent = Kward::Agent.new(client: client, tool_registry: Kward::ToolRegistry.new(prompt: prompt), conversation: Kward::Conversation.new)
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client)

      with_env("KWARD_CONFIG_PATH" => config_path) do
        cli.interactive_loop(agent: agent)
      end

      output = prompt.output.join("\n")
      assert_includes output, "Runtime> Added core memory core_001."
      assert_includes output, "Runtime> Forgot core_001."
      assert_includes output, "\nRuntime>\nGlobal Core Memories:"
      refute_includes output, "Runtime> Global Core Memories:"
      refute_includes output, "Assistant> Added core memory"
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
        { "content" => "The user prefers concise and practical answers" }
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

      # LLM summarization reformulates first-person to canonical third-person user wording
      assert_equal ["The user prefers concise and practical answers"], conversation.session_memories.map { |memory| memory["text"] }
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
        { "content" => "The user prefers concise and practical answers" }
      ])
      conversation = Kward::Conversation.new
      agent = Kward::Agent.new(client: client, tool_registry: Kward::ToolRegistry.new(prompt: prompt), conversation: conversation)
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client)

      with_env("KWARD_CONFIG_PATH" => config_path) do
        cli.interactive_loop(agent: agent)
      end

      assert_equal ["The user prefers concise and practical answers"], conversation.session_memories.map { |memory| memory["text"] }
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
        { "content" => "The user prefers concise and practical answers" }
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
      assert_equal ["The user prefers concise and practical answers"], conversation.session_memories.map { |memory| memory["text"] }
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
    def context_usage.call(provider:, model:, context_window:, **_kwargs)
      @seen = { provider: provider, model: model, context_window: context_window }
      { percent: 12.4 }
    end
    def context_usage.seen
      @seen
    end
    client = FakeClient.new([])
    client.provider = "Codex"
    client.model = "gpt-5.5"
    client.reasoning_effort = "medium"
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), client: client, context_usage: context_usage)
    hide_composer_git_branch(cli)
    conversation = Kward::Conversation.new(system_message: nil, provider: "Codex", model: "gpt-5.5", reasoning_effort: "low")
    conversation.append_user("Status report.")
    cli.instance_variable_set(:@footer_conversation, conversation)

    assert_equal "12% · Codex gpt-5.5 · low", cli.send(:composer_status_text)
    assert_equal "Codex", context_usage.seen[:provider]
    assert_equal "gpt-5.5", context_usage.seen[:model]
    assert_equal Kward::ModelInfo.context_window("Codex", "gpt-5.5"), context_usage.seen[:context_window]
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

  def test_composer_status_hides_visible_worker_label
    context_usage = Object.new
    def context_usage.call(**_kwargs)
      { percent: 42 }
    end
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), client: FakeClient.new([]), context_usage: context_usage)
    hide_composer_git_branch(cli)
    cli.instance_variable_set(:@visible_worker_id, "abc123")
    cli.instance_variable_set(:@visible_worker_status, "ready")
    cli.instance_variable_set(:@session_diff, Kward::SessionDiff.new(additions: 7, deletions: 5))

    assert_equal "+7|-5 · 42% · Codex fake-model · medium", strip_ansi(cli.send(:composer_status_text))
  end

  def test_build_interactive_agent_keeps_worker_label_out_of_composer_status
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), client: FakeClient.new([]))
    hide_composer_git_branch(cli)

    cli.send(:build_interactive_agent, Kward::Conversation.new)

    assert_equal "Codex fake-model · medium", strip_ansi(cli.send(:composer_status_text))
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

  def test_piped_prompt_reads_non_tty_input
    cli = Kward::CLI.new(stdin: FakeInput.new("hello from stdin\n", tty: false), client: FakeClient.new([]))

    assert_equal "hello from stdin", cli.piped_prompt
  end

  def test_piped_prompt_ignores_tty_input
    cli = Kward::CLI.new(stdin: FakeInput.new("ignored", tty: true), client: FakeClient.new([]))

    assert_equal "", cli.piped_prompt
  end

  def test_reload_plugins_updates_footer_renderer
    Dir.mktmpdir do |home|
      plugins_dir = File.join(home, ".kward", "plugins")
      plugin_path = File.join(plugins_dir, "footer.rb")
      FileUtils.mkdir_p(plugins_dir)
      File.write(plugin_path, <<~'RUBY')
        Kward.plugin do |plugin|
          plugin.footer do |_ctx|
            "footer=v1"
          end
        end
      RUBY

      with_env("HOME" => home, "KWARD_CONFIG_PATH" => nil) do
        cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: FakePrompt.new([]), client: FakeClient.new([]))
        footer = cli.send(:prompt_footer_renderer)
        conversation = Kward::Conversation.new(plugin_registry: cli.send(:plugin_registry))

        assert_equal "footer=v1", footer.call

        File.write(plugin_path, <<~'RUBY')
          Kward.plugin do |plugin|
            plugin.footer do |_ctx|
              "footer=v2"
            end
          end
        RUBY
        cli.send(:reload_plugins, conversation)

        assert_equal "footer=v2", footer.call
      end
    end
  end

  def test_reload_plugins_updates_commands_and_current_system_message
    Dir.mktmpdir do |home|
      plugins_dir = File.join(home, ".kward", "plugins")
      plugin_path = File.join(plugins_dir, "version.rb")
      FileUtils.mkdir_p(plugins_dir)
      File.write(plugin_path, <<~'RUBY')
        Kward.plugin do |plugin|
          plugin.command "version" do |_args, ctx|
            ctx.say("plugin=v1")
          end
          plugin.prompt_context do |_ctx|
            "Plugin context: v1"
          end
        end
      RUBY

      with_env("HOME" => home, "KWARD_CONFIG_PATH" => nil) do
        prompt = FakePrompt.new([])
        cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([]))
        registry = cli.send(:plugin_registry)
        conversation = Kward::Conversation.new(plugin_registry: registry)
        agent = Kward::Agent.new(client: FakeClient.new([]), tool_registry: Kward::ToolRegistry.new(prompt: prompt), conversation: conversation)

        cli.send(:run_plugin_command, "version", "", agent)
        File.write(plugin_path, <<~'RUBY')
          Kward.plugin do |plugin|
            plugin.command "version" do |_args, ctx|
              ctx.say("plugin=v2")
            end
            plugin.prompt_context do |_ctx|
              "Plugin context: v2"
            end
          end
        RUBY
        cli.send(:reload_plugins, conversation)
        cli.send(:run_plugin_command, "version", "", agent)

        output = prompt.output.join("\n")
        assert_includes output, "plugin=v1"
        assert_includes output, "Plugins reloaded."
        assert_includes output, "plugin=v2"
        system_message = conversation.system_message
        assert_includes Kward::MessageAccess.content(system_message), "Plugin context: v2"
        refute_includes Kward::MessageAccess.content(system_message), "Plugin context: v1"
      end
    end
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
      assert_includes prompt.output.join("\n"), "messages=2"
    end
  end

  def test_openrouter_refresh_caches_models_for_configured_key
    Dir.mktmpdir do |dir|
      config_path = File.join(dir, "config.json")
      File.write(config_path, JSON.dump("openrouter_api_key" => "sk-or-secret"))
      prompt = FakePrompt.new([])
      client = ReloadTrackingClient.new
      body = JSON.dump("data" => [
        {
          "id" => "anthropic/claude-sonnet-4.5",
          "architecture" => { "input_modalities" => ["text"], "output_modalities" => ["text"] }
        }
      ])

      with_env("KWARD_CONFIG_PATH" => config_path, "OPENROUTER_API_KEY" => nil) do
        with_fake_net_http([fake_net_response(200, body)]) do |http|
          Kward::CLI.new(argv: ["openrouter", "refresh"], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client).run

          cache_path = File.join(dir, "cache", "openrouter_models.json")
          cache = JSON.parse(File.read(cache_path))
          assert_equal ["anthropic/claude-sonnet-4.5"], cache.fetch("models").map { |model| model.fetch("id") }
          assert_equal URI("https://openrouter.ai/api/v1/models/user"), http.requests.first.uri
          assert_equal "Bearer sk-or-secret", http.requests.first["Authorization"]
          assert_equal 1, client.reload_count
          assert_includes prompt.output.join("\n"), "Refreshed 1 OpenRouter text model"
        end
      end
    end
  end

  def test_openrouter_list_prints_cached_models
    Dir.mktmpdir do |dir|
      config_path = File.join(dir, "config.json")
      cache_path = File.join(dir, "cache", "openrouter_models.json")
      FileUtils.mkdir_p(File.dirname(cache_path))
      File.write(config_path, JSON.dump("openrouter_api_key" => "sk-or-secret"))
      File.write(cache_path, JSON.dump("version" => 1, "refreshed_at" => "2026-06-20T00:00:00Z", "models" => [{ "id" => "openai/gpt-5.5" }]))
      prompt = FakePrompt.new([])

      with_env("KWARD_CONFIG_PATH" => config_path, "OPENROUTER_API_KEY" => nil) do
        Kward::CLI.new(argv: ["openrouter", "list"], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([])).run
      end

      output = prompt.output.join("\n")
      assert_includes output, "OpenRouter models cached at 2026-06-20T00:00:00Z"
      assert_includes output, "openai/gpt-5.5"
    end
  end

  class GitPrompt < BusyPrompt
    attr_reader :git_status_lines

    def initialize(message, actions: [])
      super(["/git", "/exit"])
      @message = message
      @actions = actions
      @git_status_lines = nil
    end

    def ask(_message)
      @inputs.shift
    end

    def git_commit_message(status_lines)
      @git_status_lines = status_lines
      @actions.each do |action|
        @git_status_lines = yield(action)
      end
      @message
    end
  end

  def test_git_slash_command_commits_staged_changes_only
    Dir.mktmpdir do |dir|
      system("git", "init", chdir: dir, out: File::NULL, err: File::NULL)
      system("git", "config", "user.email", "test@example.com", chdir: dir)
      system("git", "config", "user.name", "Test User", chdir: dir)
      File.write(File.join(dir, "tracked.txt"), "old\n")
      system("git", "add", "tracked.txt", chdir: dir)
      system("git", "commit", "-m", "initial", chdir: dir, out: File::NULL, err: File::NULL)
      File.write(File.join(dir, "tracked.txt"), "new\n")
      File.write(File.join(dir, "untracked.txt"), "new\n")
      system("git", "add", "tracked.txt", chdir: dir)
      prompt = GitPrompt.new("ship changes")
      client = RecordingClient.new([])

      Dir.chdir(dir) do
        cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client)
        agent = Kward::Agent.new(client: client, tool_registry: Kward::ToolRegistry.new(prompt: prompt), conversation: Kward::Conversation.new(workspace_root: dir))
        cli.interactive_loop(agent: agent)
      end

      assert_includes prompt.git_status_lines, "?? untracked.txt"
      assert_equal "ship changes", `git -C #{Shellwords.escape(dir)} log -1 --pretty=%s`.strip
      assert_equal "?? untracked.txt", `git -C #{Shellwords.escape(dir)} status --short`.strip
      assert_equal "new", File.read(File.join(dir, "tracked.txt")).strip
      assert_includes prompt.output.join("\n"), "Git commit succeeded"
    end
  end

  def test_git_slash_command_can_stage_selected_untracked_file
    Dir.mktmpdir do |dir|
      system("git", "init", chdir: dir, out: File::NULL, err: File::NULL)
      system("git", "config", "user.email", "test@example.com", chdir: dir)
      system("git", "config", "user.name", "Test User", chdir: dir)
      File.write(File.join(dir, "new.txt"), "new\n")
      prompt = GitPrompt.new("ship file", actions: [{ action: :toggle_stage, index: 0 }])
      client = RecordingClient.new([])

      Dir.chdir(dir) do
        cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client)
        agent = Kward::Agent.new(client: client, tool_registry: Kward::ToolRegistry.new(prompt: prompt), conversation: Kward::Conversation.new(workspace_root: dir))
        cli.interactive_loop(agent: agent)
      end

      assert_empty `git -C #{Shellwords.escape(dir)} status --short`.strip
      assert_equal "ship file", `git -C #{Shellwords.escape(dir)} log -1 --pretty=%s`.strip
    end
  end

  def test_git_slash_command_can_unstage_selected_file
    Dir.mktmpdir do |dir|
      system("git", "init", chdir: dir, out: File::NULL, err: File::NULL)
      system("git", "config", "user.email", "test@example.com", chdir: dir)
      system("git", "config", "user.name", "Test User", chdir: dir)
      File.write(File.join(dir, "file.txt"), "old\n")
      system("git", "add", "file.txt", chdir: dir)
      system("git", "commit", "-m", "initial", chdir: dir, out: File::NULL, err: File::NULL)
      File.write(File.join(dir, "file.txt"), "new\n")
      system("git", "add", "file.txt", chdir: dir)
      prompt = GitPrompt.new("should fail", actions: [{ action: :toggle_stage, index: 0 }])
      client = RecordingClient.new([])

      Dir.chdir(dir) do
        cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client)
        agent = Kward::Agent.new(client: client, tool_registry: Kward::ToolRegistry.new(prompt: prompt), conversation: Kward::Conversation.new(workspace_root: dir))
        cli.interactive_loop(agent: agent)
      end

      assert_equal "initial", `git -C #{Shellwords.escape(dir)} log -1 --pretty=%s`.strip
      assert_equal "M file.txt", `git -C #{Shellwords.escape(dir)} status --short`.strip
      assert_includes prompt.output.join("\n"), "Git commit failed"
    end
  end

  def test_git_slash_command_surfaces_blank_message_failure
    Dir.mktmpdir do |dir|
      system("git", "init", chdir: dir, out: File::NULL, err: File::NULL)
      system("git", "config", "user.email", "test@example.com", chdir: dir)
      system("git", "config", "user.name", "Test User", chdir: dir)
      File.write(File.join(dir, "file.txt"), "new\n")
      prompt = GitPrompt.new("")
      client = RecordingClient.new([])

      Dir.chdir(dir) do
        cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client)
        agent = Kward::Agent.new(client: client, tool_registry: Kward::ToolRegistry.new(prompt: prompt), conversation: Kward::Conversation.new(workspace_root: dir))
        cli.interactive_loop(agent: agent)
      end

      assert_includes prompt.output.join("\n"), "Git commit failed"
      refute_empty `git -C #{Shellwords.escape(dir)} status --short`.strip
    end
  end

  def test_interactive_plugin_slash_command_shows_running_spinner
    Dir.mktmpdir do |home|
      plugins_dir = File.join(home, ".kward", "plugins")
      FileUtils.mkdir_p(plugins_dir)
      File.write(File.join(plugins_dir, "news.rb"), <<~'RUBY')
        Kward.plugin do |plugin|
          plugin.command "news", description: "Show news" do |_args, ctx|
            ctx.say("news ready")
          end
        end
      RUBY
      prompt = BusyPrompt.new(["/news", "/exit"])
      client = RecordingClient.new([])

      with_env("HOME" => home, "KWARD_CONFIG_PATH" => nil) do
        agent = Kward::Agent.new(client: client, tool_registry: Kward::ToolRegistry.new(prompt: prompt))
        cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client)
        cli.interactive_loop(agent: agent)
      end

      running_index = prompt.events.index([:begin_busy_input, "You>", "running"])
      assert running_index
      finish_after_running = prompt.events[running_index..].index([:finish_busy_input])
      assert finish_after_running
      assert_equal 0, client.seen_messages.length
      assert_includes prompt.output.join("\n"), "news ready"
    end
  end

end
