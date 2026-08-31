require_relative "../test_helper"

class TestCLIBusyInput < KwardTestCase
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

  def test_interactive_session_store_is_reused
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

  def test_busy_input_blocks_slash_command_instead_of_queueing_or_steering
    prompt = PollingPrompt.new(["/git"])
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: RecordingClient.new([]))
    queued = []
    submitted = []
    steering = Object.new
    steering.define_singleton_method(:submit) { |input| submitted << input }

    cli.send(:collect_busy_input, queued, steering)

    assert_empty queued
    assert_empty submitted
  end

  def test_busy_input_queues_deferred_control_commands
    prompt = PollingPrompt.new(["/exit"])
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: RecordingClient.new([]))
    queued = []
    submitted = []
    steering = Object.new
    steering.define_singleton_method(:submit) { |input| submitted << input }

    cli.send(:collect_busy_input, queued, steering)

    assert_equal ["/exit"], queued
    assert_empty submitted

    prompt = PollingPrompt.new(["/new"])
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: RecordingClient.new([]))
    queued = []
    submitted = []
    steering = Object.new
    steering.define_singleton_method(:submit) { |input| submitted << input }

    cli.send(:collect_busy_input, queued, steering)

    assert_equal ["/new"], queued
    assert_empty submitted
  end

  def test_tab_busy_input_blocks_slash_command_instead_of_queueing_or_steering
    prompt = FakePrompt.new([])
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: RecordingClient.new([]))
    submitted = []
    steering = Object.new
    steering.define_singleton_method(:submit) { |input| submitted << input }
    tab = Kward::CLI::Tabs::TabRuntime.new(queued_inputs: [], steering: steering)

    cli.send(:handle_tab_busy_input, tab, "/git")

    assert_empty tab.queued_inputs
    assert_empty submitted
  end

  def test_tab_busy_input_queues_deferred_control_command
    prompt = FakePrompt.new([])
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: RecordingClient.new([]))
    submitted = []
    steering = Object.new
    steering.define_singleton_method(:submit) { |input| submitted << input }
    tab = Kward::CLI::Tabs::TabRuntime.new(queued_inputs: [], steering: steering)

    cli.send(:handle_tab_busy_input, tab, "/exit")

    assert_equal ["/exit"], tab.queued_inputs
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
    assert_includes rendered, "thinking"
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

  def test_session_is_builtin_slash_command
    assert_includes Kward::CLI::BUILTIN_SLASH_COMMAND_NAMES, "session"
    refute_includes Kward::CLI::BUILTIN_SLASH_COMMAND_NAMES, "sessions"
    assert_includes Kward::CLI::BUILTIN_SLASH_COMMAND_NAMES, "name"
  end

end
