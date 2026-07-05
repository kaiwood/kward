require_relative "../test_helper"

class TestCLIWorkers < KwardTestCase
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
    attr_reader :select_messages, :busy_inputs, :tasks

    def initialize(inputs, selections:, tasks:)
      super(tasks)
      @poll_inputs = inputs
      @selections = selections
      @select_messages = []
      @busy_inputs = []
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

  def test_workers_command_requires_experimental_flag
    prompt = FakePrompt.new([])
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: RecordingClient.new([]))
    agent = Kward::Agent.new(client: RecordingClient.new([]), tool_registry: Kward::ToolRegistry.new(prompt: prompt))

    handled, replacement = cli.send(:handle_local_slash_command, "/workers", agent, nil)

    assert handled
    assert_nil replacement
    assert_includes prompt.output.join, "--experimental-workers"
  end

  def test_busy_input_blocks_workers_command_without_queuing
    prompt = PollingPrompt.new(["/workers"])
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: RecordingClient.new([]))
    cli.instance_variable_set(:@experimental_workers, true)
    queued = []

    cli.send(:collect_busy_input, queued, nil, Object.new)

    assert_empty queued
    refute_includes prompt.output.join, "Usage: /workers"
  end

  def test_busy_workers_new_read_only_is_blocked_like_other_slash_commands
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
    assert_empty prompt.busy_inputs
    assert_empty prompt.select_messages
    refute_includes prompt.output.join, "Worker sent: map the codebase"
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

  def test_workers_show_renders_worker_transcript_after_turn_finishes
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
      prompt = BusyPollingSelectPrompt.new([], selections: ["List workers", "abc123 [request/running] worker task", "Show"])
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
      cli.send(:handle_local_slash_command, "/workers", agent, session_store)
      cli.send(:stop_live_worker_view)

      rendered = prompt.output.join
      assert_includes rendered, "worker transcript"
      assert_includes rendered, "implementation overwrite"
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

end
