require_relative "test_helper"

class TestTabs < KwardTestCase
  class TabPrompt < FakePrompt
    attr_reader :tabs_updates, :restores, :busy_started, :busy_finished, :banner_count

    def initialize(inputs = [])
      super(inputs)
      @tabs_updates = []
      @restores = []
      @poll_inputs = []
      @busy_started = 0
      @busy_finished = 0
      @banner_count = 0
    end

    def update_tabs(labels:, active_index: 0)
      @tabs_updates << { labels: labels, active_index: active_index }
    end

    def restore_transcript
      yield
    end

    def clear_transcript; end

    def close; end

    def print_visual_banner(message = nil)
      @banner_count += 1
      @output << (message || "[visual banner]")
    end

    def composer_snapshot
      { composer: :composer, prompt_label: "You>" }
    end

    def tab_view_snapshot
      { composer: :composer, prompt_label: "You>", transcript: output.dup }
    end

    def restore_composer_snapshot(snapshot)
      @restores << snapshot
    end

    def restore_tab_view_snapshot(snapshot)
      @restores << snapshot
    end

    def poll_input
      @poll_inputs.shift
    end

    def queue_poll(*inputs)
      @poll_inputs.concat(inputs)
    end

    def begin_busy_input(_message = "You>", activity: "loading")
      @busy_started += 1
    end

    def finish_busy_input
      @busy_finished += 1
    end

    def start_stream_block(label)
      @output << "start:#{label}"
    end

    def write_delta(delta)
      @output << "delta:#{delta}"
    end

    def finish_stream_block
      @output << "finish"
    end
  end

  class BlockingClient
    attr_reader :started, :release

    def initialize
      @started = Queue.new
      @release = Queue.new
    end

    def chat(messages, tools: [], on_assistant_delta: nil, **_options)
      @started << true
      @release.pop
      on_assistant_delta&.call("done")
      { "role" => "assistant", "content" => "done" }
    end
  end

  def test_restored_tabs_render_active_session_on_startup
    Dir.mktmpdir do |config_dir|
      Dir.mktmpdir do |workspace|
        store = Kward::SessionStore.new(config_dir: config_dir, cwd: workspace)
        session = store.create
        conversation = Kward::Conversation.new(workspace_root: workspace)
        session.attach(conversation)
        conversation.append_user("restored prompt")
        conversation.append_assistant("restored reply")
        Kward::TabStore.new(config_dir: config_dir, cwd: workspace).save(session_paths: [session.path], active_index: 0)
        prompt = TabPrompt.new
        cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("/exit", tty: true), prompt: prompt, client: RecordingClient.new([]), session_store: store)

        cli.send(:interactive_loop)

        output = strip_ansi(prompt.output.join("\n"))
        assert_includes output, "restored prompt"
        assert_includes output, "restored reply"
        refute_includes output, "State your business."
      end
    end
  end

  def test_new_tabs_use_main_then_tab_default_labels
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      prompt = TabPrompt.new
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: RecordingClient.new([]), session_store: store)

      cli.send(:setup_interactive_tabs, store, nil)
      assert_equal ["Main"], prompt.tabs_updates.last[:labels]

      cli.send(:handle_tab_command, "new", store)
      assert_equal ["Main", "Tab"], prompt.tabs_updates.last[:labels]
    end
  end

  def test_new_command_replaces_active_tab_session_without_opening_tab
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      prompt = TabPrompt.new
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: RecordingClient.new([]), session_store: store)
      cli.send(:setup_interactive_tabs, store, nil)
      original_session = cli.send(:active_tab).session

      handled, replacement = cli.send(:handle_local_slash_command, "/new", cli.send(:active_tab).agent, store)
      cli.send(:replace_active_tab_agent, replacement)

      assert handled
      assert_equal 1, cli.instance_variable_get(:@tabs).length
      assert_equal 0, cli.instance_variable_get(:@active_tab_index)
      refute_equal original_session.path, cli.send(:active_tab).session.path
      assert_equal ["Main"], prompt.tabs_updates.last[:labels]
    end
  end

  def test_idle_tab_switch_changes_active_tab
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      prompt = TabPrompt.new
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: RecordingClient.new([]), session_store: store)
      cli.send(:setup_interactive_tabs, store, nil)

      cli.send(:handle_tab_action, { tab_action: :new }, store)
      assert_equal 1, cli.instance_variable_get(:@active_tab_index)

      cli.send(:handle_tab_action, { tab_action: :previous }, store)
      assert_equal 0, cli.instance_variable_get(:@active_tab_index)
      assert_equal 0, prompt.tabs_updates.last[:active_index]
    end
  end

  def test_ctrl_d_closes_only_active_tab_when_multiple_tabs_are_open
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      prompt = TabPrompt.new([nil])
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: RecordingClient.new([]), session_store: store)
      cli.send(:setup_interactive_tabs, store, nil)
      cli.send(:handle_tab_action, { tab_action: :new }, store)

      action = cli.send(:poll_active_tab_input)
      result = cli.send(:handle_tab_action, action, store)

      assert_nil result
      assert_equal 1, cli.instance_variable_get(:@tabs).length
      assert_equal 0, cli.instance_variable_get(:@active_tab_index)
    end
  end

  def test_new_empty_tab_renders_startup_screen_when_revisited
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      prompt = TabPrompt.new
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: RecordingClient.new([]), session_store: store)
      cli.send(:setup_interactive_tabs, store, nil)

      cli.send(:handle_tab_action, { tab_action: :new }, store)
      assert_equal 1, prompt.banner_count
      assert_includes prompt.output.join("\n"), "Kward v#{Kward::VERSION} is online."

      prompt.output.clear
      cli.send(:handle_tab_action, { tab_action: :previous }, store)
      cli.send(:handle_tab_action, { tab_action: :next }, store)

      assert_equal 3, prompt.banner_count
      assert_includes prompt.output.join("\n"), "Kward v#{Kward::VERSION} is online."
    end
  end

  def test_non_empty_tab_renders_transcript_instead_of_startup_screen
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      prompt = TabPrompt.new
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: RecordingClient.new([]), session_store: store)
      cli.send(:setup_interactive_tabs, store, nil)
      cli.send(:active_tab).agent.conversation.append_user("hello")

      cli.send(:render_tab, cli.send(:active_tab))

      output = strip_ansi(prompt.output.join("\n"))
      assert_includes output, "Transcript"
      assert_includes output, "hello"
      refute_includes output, "State your business."
    end
  end

  def test_busy_tab_switches_while_original_turn_keeps_running
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      prompt = TabPrompt.new
      client = BlockingClient.new
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client, session_store: store)
      cli.send(:setup_interactive_tabs, store, nil)
      first_tab = cli.send(:active_tab)
      cli.send(:handle_tab_action, { tab_action: :new }, store)
      cli.send(:handle_tab_action, { tab_action: :previous }, store)

      cli.send(:submit_tab_input, first_tab, "hello")
      client.started.pop
      assert first_tab.running?

      prompt.queue_poll({ tab_action: :next })
      action = cli.send(:poll_active_tab_input)
      cli.send(:handle_tab_action, action, store)

      assert_equal 1, cli.instance_variable_get(:@active_tab_index)
      assert first_tab.running?

      client.release << true
      first_tab.thread.join(1)
      assert_equal "ready", first_tab.status
    end
  end

  def test_tabs_run_turns_in_parallel_without_worker_write_lock
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      prompt = TabPrompt.new
      client = BlockingClient.new
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client, session_store: store)
      cli.send(:setup_interactive_tabs, store, nil)
      first_tab = cli.send(:active_tab)
      cli.send(:handle_tab_action, { tab_action: :new }, store)
      second_tab = cli.send(:active_tab)

      cli.send(:submit_tab_input, first_tab, "first")
      client.started.pop
      cli.send(:submit_tab_input, second_tab, "second")
      wait_until { client.started.size.positive? }

      assert first_tab.running?
      assert second_tab.running?
      assert_nil first_tab.agent.tool_registry.writer_id
      assert_nil second_tab.agent.tool_registry.writer_id

      client.release << true
      client.release << true
      first_tab.thread.join(1)
      second_tab.thread.join(1)
      assert_equal "ready", first_tab.status
      assert_equal "ready", second_tab.status
    end
  end

  def test_replacement_agent_updates_active_tab_before_switching_away
    Dir.mktmpdir do |config_dir|
      Dir.mktmpdir do |workspace|
        store = Kward::SessionStore.new(config_dir: config_dir, cwd: workspace)
        saved = store.create
        conversation = Kward::Conversation.new(workspace_root: workspace)
        saved.attach(conversation)
        conversation.append_user("loaded prompt")
        conversation.append_assistant("loaded reply")
        prompt = TabPrompt.new
        prompt.define_singleton_method(:restore_transcript) do |&block|
          output.clear
          block.call
        end
        cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: RecordingClient.new([]), session_store: store)
        cli.send(:setup_interactive_tabs, store, nil)
        cli.send(:active_tab).agent.conversation.append_user("old prompt")

        replacement = cli.send(:resume_session, store, saved.path)
        cli.send(:replace_active_tab_agent, replacement)
        cli.send(:handle_tab_action, { tab_action: :new }, store)
        cli.send(:handle_tab_action, { tab_action: :previous }, store)

        output = strip_ansi(prompt.output.join("\n"))
        assert_includes output, "loaded prompt"
        assert_includes output, "loaded reply"
        refute_includes output, "old prompt"
      end
    end
  end

  def test_tab_slash_command_switches_active_tab
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      prompt = TabPrompt.new
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: RecordingClient.new([]), session_store: store)
      cli.send(:setup_interactive_tabs, store, nil)
      cli.send(:handle_tab_command, "new", store)

      replacement = cli.send(:handle_tab_command, "1", store)

      assert_equal cli.send(:active_tab).agent, replacement
      assert_equal 0, cli.instance_variable_get(:@active_tab_index)
      assert_equal 0, prompt.tabs_updates.last[:active_index]
    end
  end

  def test_tab_slash_command_moves_active_tab
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      prompt = TabPrompt.new
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: RecordingClient.new([]), session_store: store)
      cli.send(:setup_interactive_tabs, store, nil)
      first_tab = cli.send(:active_tab)
      cli.send(:handle_tab_command, "new", store)

      replacement = cli.send(:handle_tab_command, "move 1", store)

      assert_equal cli.send(:active_tab).agent, replacement
      assert_equal 0, cli.instance_variable_get(:@active_tab_index)
      assert_equal cli.send(:active_tab), cli.instance_variable_get(:@tabs).first
      assert_equal first_tab, cli.instance_variable_get(:@tabs).last
    end
  end

  def test_tab_slash_command_moves_active_tab_left_and_right
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      prompt = TabPrompt.new
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: RecordingClient.new([]), session_store: store)
      cli.send(:setup_interactive_tabs, store, nil)
      cli.send(:handle_tab_command, "new", store)

      cli.send(:handle_tab_command, "move left", store)
      assert_equal 0, cli.instance_variable_get(:@active_tab_index)

      cli.send(:handle_tab_command, "move right", store)
      assert_equal 1, cli.instance_variable_get(:@active_tab_index)
    end
  end

  def test_tab_slash_command_renames_active_tab_label
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      prompt = TabPrompt.new
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: RecordingClient.new([]), session_store: store)
      cli.send(:setup_interactive_tabs, store, nil)

      cli.send(:handle_tab_command, "name Ops", store)

      assert_equal ["Ops"], prompt.tabs_updates.last[:labels]
      refute_includes prompt.tabs_updates.last[:labels].first, "1"
    end
  end

  def test_tab_slash_command_closes_active_tab
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      prompt = TabPrompt.new
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: RecordingClient.new([]), session_store: store)
      cli.send(:setup_interactive_tabs, store, nil)
      cli.send(:handle_tab_command, "new", store)

      replacement = cli.send(:handle_tab_command, "close", store)

      assert_equal cli.send(:active_tab).agent, replacement
      assert_equal 1, cli.instance_variable_get(:@tabs).length
    end
  end

  def test_running_tab_cannot_be_closed
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      prompt = TabPrompt.new
      client = BlockingClient.new
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client, session_store: store)
      cli.send(:setup_interactive_tabs, store, nil)
      tab = cli.send(:active_tab)
      cli.send(:submit_tab_input, tab, "hello")
      client.started.pop

      result = cli.send(:handle_tab_action, { tab_action: :close }, store)

      assert_nil result
      assert_equal 1, cli.instance_variable_get(:@tabs).length
      assert_match(/cannot be closed/, prompt.output.join("\n"))
    ensure
      client.release << true if client
      tab.thread.join(1) if tab&.thread
    end
  end
end
