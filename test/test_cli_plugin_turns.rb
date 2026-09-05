require_relative "test_helper"

class TestCLIPluginTurns < KwardTestCase
  def test_system_turn_renders_and_runs_in_a_real_tui_session_tab
    output = StringIO.new
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: output)
    client = RecordingClient.new(["Done"])
    agent = Kward::Agent.new(client: client, conversation: Kward::Conversation.new(system_message: nil))
    cli = Kward::CLI.new(argv: [], prompt: prompt, client: client)
    tab = cli.send(:build_tab, nil, agent, label: "Test")
    cli.instance_variable_set(:@tabs, [tab])
    cli.instance_variable_set(:@active_tab_index, 0)
    request = Kward::PluginTurnRequest.new(system: "Explain ./missing.png without attaching it.", command: "iddqd")

    cli.send(:start_tab_turn, tab, request, display_input: request.to_s)
    assert tab.thread.join(2), "Model turn did not finish"

    assert_nil tab.error
    assert_equal "Done", tab.answer
    assert_equal "ready", tab.status
    assert_includes output.string, request.to_s
    refute_includes output.string, "[image?]"
    assert_equal [{ role: "system", content: request.system }], client.seen_messages.first
    refute_includes JSON.generate(agent.conversation.context_messages), request.system
  ensure
    tab&.cancellation&.cancel!
    tab&.thread&.join(2)
    prompt&.close
  end

  def test_slash_command_dispatches_system_turn_then_normal_turn
    Dir.mktmpdir do |home|
      with_env("HOME" => home, "KWARD_CONFIG_PATH" => nil) do
        registry = Kward::PluginRegistry.new
        registry.evaluate do |plugin|
          plugin.command("iddqd") { |text, ctx| ctx.request_turn(system: text) }
        end
        prompt = FakePrompt.new(["/iddqd Reply in French.", "Now reply normally.", "/exit"])
        client = RecordingClient.new(["Bonjour", "Hello"])
        agent = Kward::Agent.new(client: client, tool_registry: Kward::ToolRegistry.new(prompt: prompt))
        cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client)
        cli.instance_variable_set(:@plugin_registry, registry)

        cli.interactive_loop(agent: agent)

        assert_equal 2, client.seen_messages.length
        assert client.seen_messages.first.any? { |message| message[:role] == "system" && message[:content] == "Reply in French." }
        refute client.seen_messages.first.any? { |message| message[:role] == "user" }
        refute_includes JSON.generate(client.seen_messages.last), "Reply in French."
        assert_includes prompt.output.join("\n"), "Bonjour"
        assert_includes prompt.output.join("\n"), "Hello"
      end
    end
  end

  def test_request_stays_with_originating_tab_after_switch
    registry = Kward::PluginRegistry.new
    registry.evaluate do |plugin|
      plugin.command("iddqd") { |text, ctx| ctx.request_turn(system: text) }
    end
    client = RecordingClient.new(["Origin answer"])
    agent = Kward::Agent.new(client: client)
    other_agent = Kward::Agent.new(client: RecordingClient.new([]))
    tab_type = Struct.new(:agent, :session)
    origin = tab_type.new(agent, nil)
    other = tab_type.new(other_agent, nil)
    cli = Kward::CLI.new(argv: [], prompt: FakePrompt.new([]), client: client)
    cli.instance_variable_set(:@plugin_registry, registry)
    cli.instance_variable_set(:@tabs, [origin, other])
    cli.instance_variable_set(:@active_tab_index, 0)
    cli.define_singleton_method(:run_busy_local_command_and_requeue) do |**_options, &block|
      result = block.call
      @active_tab_index = 1
      result
    end
    submitted = []
    cli.define_singleton_method(:submit_tab_input) do |tab, input, **_options|
      submitted << tab
      tab.agent.ask(input)
    end

    assert_equal [true, nil], cli.send(:run_plugin_command_and_turn, "iddqd", "Stay with the origin", agent)
    assert_equal [origin], submitted
    assert_empty other_agent.conversation.messages
    assert_equal "Stay with the origin", agent.conversation.messages.first[:plugin_system_turn][:system]
  end

  def test_cancelled_busy_command_is_handled_without_falling_back_to_user_input
    cli = Kward::CLI.new(argv: [], prompt: FakePrompt.new([]), client: RecordingClient.new([]))
    cli.define_singleton_method(:run_busy_local_command_and_requeue) { |**_options| nil }
    assert_equal [true, nil], cli.send(:run_plugin_command_and_turn, "iddqd", "Do not submit", Kward::Agent.new(client: RecordingClient.new([])))
  end

  def test_failed_command_does_not_dispatch_staged_turn
    registry = Kward::PluginRegistry.new
    registry.evaluate do |plugin|
      plugin.command("iddqd") do |text, ctx|
        ctx.request_turn(system: text)
        raise "Command failed"
      end
    end
    prompt = FakePrompt.new([])
    client = RecordingClient.new([])
    agent = Kward::Agent.new(client: client)
    cli = Kward::CLI.new(argv: [], prompt: prompt, client: client)
    cli.instance_variable_set(:@plugin_registry, registry)

    assert_equal [true, nil], cli.send(:run_plugin_command_and_turn, "iddqd", "Hello", agent)
    assert_empty client.seen_messages
    assert_empty agent.conversation.messages
    assert_includes prompt.output.join("\n"), "Command failed"
  end
end
