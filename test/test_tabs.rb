require_relative "test_helper"

class TestTabs < KwardTestCase
  class TabPrompt < FakePrompt
    attr_reader :tabs_updates, :restores, :busy_started, :busy_finished, :banner_count, :slash_command_updates

    def initialize(inputs = [])
      super(inputs)
      @tabs_updates = []
      @restores = []
      @poll_inputs = []
      @busy_started = 0
      @busy_finished = 0
      @banner_count = 0
      @slash_command_updates = []
    end

    def update_slash_commands(entries)
      @slash_command_updates << entries
    end

    def update_tabs(labels:, active_index: 0)
      @tabs_updates << { labels: labels, active_index: active_index }
    end

    def tab_update_names
      @tabs_updates.last[:labels].map { |label| label.is_a?(Hash) ? label[:name] : label }
    end

    def tab_update_colors
      @tabs_updates.last[:labels].map { |label| label.is_a?(Hash) ? label[:color] : nil }
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

  class PluginTabDriver
    attr_reader :descriptor, :messages, :submissions

    def initialize(descriptor)
      @descriptor = descriptor
      @messages = []
      @submissions = []
    end

    def submit(input, display_input:, cancellation:, steering: nil)
      @submissions << { input: input, display_input: display_input, cancellation: cancellation, steering: steering }
      @messages << { role: "user", content: input }
      yield Kward::Events::AssistantDelta.new(delta: "Plugin reply") if block_given?
      @messages << { role: "assistant", content: "Plugin reply" }
      "Plugin reply"
    end

    def session?
      false
    end

    def supports_steering?
      false
    end

    def assistant_label
      "Plugin"
    end

    def slash_command_entries
      [{ name: "plugin status", description: "Show plugin status", argument_hint: "" }]
    end
  end

  class << self
    attr_accessor :plugin_events
  end

  def self.write_plugin_tab(home, transcript_events: false)
    plugins = File.join(home, ".kward", "plugins")
    FileUtils.mkdir_p(plugins)
    self.plugin_events = []
    File.write(File.join(plugins, "example.rb"), <<~RUBY)
      Kward.plugin do |plugin|
        plugin.tab_type "example", id: "test.example", title: "Example", singleton: :global, transcript_events: #{transcript_events} do |_host, descriptor|
          TestTabs::PluginTabDriver.new(descriptor)
        end

        plugin.on_transcript_event do |event, ctx|
          TestTabs.plugin_events << [event.type, event.payload[:delta], ctx.transcript.messages]
        end
      end
    RUBY
  end

  class BlockingClient
    attr_reader :started, :release

    def initialize(result: { "role" => "assistant", "content" => "done" })
      @started = Queue.new
      @release = Queue.new
      @result = result
    end

    def chat(messages, tools: [], on_assistant_delta: nil, **_options)
      @started << true
      @release.pop
      raise @result if @result.is_a?(Exception)

      on_assistant_delta&.call(@result["content"])
      @result
    end
  end

  class BlockingSummarizer
    attr_reader :started, :release

    def initialize(summary = "summary")
      @summary = summary
      @started = Queue.new
      @release = Queue.new
    end

    def summarize(*)
      @started << true
      @release.pop
      @summary
    end
  end

  def with_compactor_stub(compactor)
    original_new = Kward::Compactor.method(:new)
    Kward::Compactor.define_singleton_method(:new) { |**_kwargs| compactor }
    yield
  ensure
    Kward::Compactor.define_singleton_method(:new, original_new)
  end

  class BlockingQuestionClient
    attr_reader :started, :release

    def initialize(question)
      @question = question
      @started = Queue.new
      @release = Queue.new
      @calls = 0
    end

    def chat(_messages, tools: [], **_options)
      @calls += 1
      if @calls == 1
        @started << true
        @release.pop
        {
          "role" => "assistant",
          "content" => nil,
          "tool_calls" => [tool_call("ask_user_question", { questions: [@question] })]
        }
      else
        { "role" => "assistant", "content" => "done" }
      end
    end

    private

    def tool_call(name, args)
      {
        "id" => "call_#{name}",
        "type" => "function",
        "function" => {
          "name" => name,
          "arguments" => JSON.dump(args)
        }
      }
    end
  end

  class QuestionTabPrompt < TabPrompt
    attr_reader :questions

    def initialize(inputs = [])
      super
      @questions = Queue.new
      @answers = Queue.new
    end

    def ask_user_question(questions)
      @questions << questions
      @answers.pop
    end

    def answer_question(answers)
      @answers << answers
    end

    def asked_question?
      !@questions.empty?
    end
  end

  def test_opens_persists_and_restores_plugin_tab
    Dir.mktmpdir do |home|
      Dir.mktmpdir do |config_dir|
        Dir.mktmpdir do |workspace|
          self.class.write_plugin_tab(home)
          store = Kward::SessionStore.new(config_dir: config_dir, cwd: workspace)
          prompt = TabPrompt.new

          with_env("HOME" => home) do
            cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: RecordingClient.new([]), session_store: store)
            cli.send(:setup_interactive_tabs, store, nil)
            cli.send(:handle_tab_command, "open example", store)

            tab = cli.send(:active_tab)
            assert_nil tab.session
            assert_instance_of PluginTabDriver, tab.driver
            assert_equal "Example", tab.label
            assert_includes prompt.slash_command_updates.last, { name: "plugin status", description: "Show plugin status", argument_hint: "" }

            cli.send(:submit_tab_input, tab, "hello")
            tab.thread.join
            assert_equal "Plugin reply", tab.answer
            assert_equal ["hello"], tab.driver.submissions.map { |submission| submission[:input] }
            assert_equal "test.example", Kward::TabStore.new(config_dir: config_dir, cwd: workspace).load["tabs"].last["plugin_tab_type"]

            restored_prompt = TabPrompt.new
            restored_cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: restored_prompt, client: RecordingClient.new([]), session_store: store)
            restored_cli.send(:setup_interactive_tabs, store, nil)
            assert_instance_of PluginTabDriver, restored_cli.send(:active_tab).driver
          end
        end
      end
    end
  end

  def test_opted_in_plugin_tab_notifies_transcript_observers
    Dir.mktmpdir do |home|
      Dir.mktmpdir do |config_dir|
        Dir.mktmpdir do |workspace|
          self.class.write_plugin_tab(home, transcript_events: true)
          store = Kward::SessionStore.new(config_dir: config_dir, cwd: workspace)

          with_env("HOME" => home) do
            cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: TabPrompt.new, client: RecordingClient.new([]), session_store: store)
            cli.send(:setup_interactive_tabs, store, nil)
            cli.send(:handle_tab_command, "open example", store)
            tab = cli.send(:active_tab)

            cli.send(:tab_live_renderer, tab).call(Kward::Events::AssistantDelta.new(delta: "Plugin reply"), tab.driver)

            assert_equal [["assistant_delta", "Plugin reply", []]], self.class.plugin_events
          end
        end
      end
    end
  end

  def test_plugin_tab_does_not_notify_transcript_observers_without_opt_in
    Dir.mktmpdir do |home|
      Dir.mktmpdir do |config_dir|
        Dir.mktmpdir do |workspace|
          self.class.write_plugin_tab(home)
          store = Kward::SessionStore.new(config_dir: config_dir, cwd: workspace)

          with_env("HOME" => home) do
            cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: TabPrompt.new, client: RecordingClient.new([]), session_store: store)
            cli.send(:setup_interactive_tabs, store, nil)
            cli.send(:handle_tab_command, "open example", store)
            tab = cli.send(:active_tab)

            cli.send(:tab_live_renderer, tab).call(Kward::Events::AssistantDelta.new(delta: "Private reply"), tab.driver)

            assert_empty self.class.plugin_events
          end
        end
      end
    end
  end

  def test_current_workspace_root_uses_active_tab_conversation_root
    Dir.mktmpdir do |origin|
      Dir.mktmpdir do |worktree|
        conversation = Kward::Conversation.new(system_message: nil, workspace_root: worktree)
        agent = Struct.new(:conversation).new(conversation)
        tab = Kward::CLI::Tabs::TabRuntime.new(agent: agent)
        cli = Kward::CLI.new(argv: [], prompt: TabPrompt.new)
        cli.instance_variable_set(:@tabs, [tab])
        cli.instance_variable_set(:@active_tab_index, 0)
        cli.instance_variable_set(:@active_session, Struct.new(:cwd).new(origin))

        assert_equal File.realpath(worktree), cli.send(:current_workspace_root)
      end
    end
  end

  def test_plugin_tab_allows_normal_messages
    Dir.mktmpdir do |home|
      Dir.mktmpdir do |config_dir|
        Dir.mktmpdir do |workspace|
          self.class.write_plugin_tab(home)
          store = Kward::SessionStore.new(config_dir: config_dir, cwd: workspace)

          with_env("HOME" => home) do
            cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: TabPrompt.new(["/tab open example", "Hallo?", "/exit"]), client: RecordingClient.new([]), session_store: store)
            cli.send(:interactive_loop)

            tab = cli.instance_variable_get(:@tabs).find { |candidate| candidate.driver.is_a?(PluginTabDriver) }
            assert_equal ["Hallo?"], tab.driver.submissions.map { |submission| submission[:input] }
          end
        end
      end
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

  def test_restore_tabs_discards_duplicate_session_descriptors
    Dir.mktmpdir do |config_dir|
      Dir.mktmpdir do |workspace|
        store = Kward::SessionStore.new(config_dir: config_dir, cwd: workspace)
        session = store.create
        conversation = Kward::Conversation.new(workspace_root: workspace)
        session.attach(conversation)
        conversation.append_user("restored once")
        tab_store = Kward::TabStore.new(config_dir: config_dir, cwd: workspace)
        FileUtils.mkdir_p(File.dirname(tab_store.path))
        File.write(tab_store.path, JSON.dump({
          "tabs" => [
            { "kind" => "session", "session_path" => session.path, "label" => "Main" },
            { "kind" => "session", "session_path" => session.path, "label" => "Main" }
          ],
          "active_index" => 1
        }))

        cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: TabPrompt.new, client: RecordingClient.new([]), session_store: store)
        cli.send(:setup_interactive_tabs, store, nil)

        tabs = cli.instance_variable_get(:@tabs)
        assert_equal 1, tabs.length
        assert_equal session.path, tabs.first.session.path
        assert_equal ["Main"], tabs.map(&:label)
        assert_equal 1, JSON.parse(File.read(tab_store.path)).fetch("tabs").length
      end
    end
  end

  def test_restore_tabs_keeps_empty_tab_slot_when_saved_session_was_cleaned_up
    Dir.mktmpdir do |config_dir|
      Dir.mktmpdir do |workspace|
        store = Kward::SessionStore.new(config_dir: config_dir, cwd: workspace)
        used_session = store.create
        conversation = Kward::Conversation.new(workspace_root: workspace)
        used_session.attach(conversation)
        conversation.append_user("kept prompt")
        empty_session = store.create
        empty_path = empty_session.path
        Kward::TabStore.new(config_dir: config_dir, cwd: workspace).save(
          session_paths: [used_session.path, empty_path],
          labels: ["Main", "Scratch"],
          active_index: 1
        )
        empty_session.delete_if_unused

        prompt = TabPrompt.new
        cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: RecordingClient.new([]), session_store: store)

        cli.send(:setup_interactive_tabs, store, nil)

        tabs = cli.instance_variable_get(:@tabs)
        assert_equal 2, tabs.length
        assert_equal used_session.path, tabs[0].session.path
        refute_equal empty_path, tabs[1].session.path
        assert File.file?(tabs[1].session.path)
        assert_equal 1, cli.instance_variable_get(:@active_tab_index)
        assert_equal ["Main", "Scratch"], prompt.tab_update_names
      end
    end
  end

  def test_new_tabs_use_main_then_tab_default_labels
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      prompt = TabPrompt.new
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: RecordingClient.new([]), session_store: store)

      cli.send(:setup_interactive_tabs, store, nil)
      assert_equal ["Main"], prompt.tab_update_names

      cli.send(:handle_tab_command, "new", store)
      assert_equal ["Main", "Tab"], prompt.tab_update_names
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
      assert_equal ["Main"], prompt.tab_update_names
    end
  end

  def test_shell_mode_persists_on_tab_until_exit
    Dir.mktmpdir do |dir|
      config_dir = File.join(dir, "config")
      workspace = File.join(dir, "workspace")
      nested = File.join(workspace, "nested")
      FileUtils.mkdir_p(nested)
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: workspace)
      prompt = TabPrompt.new(["cd nested", { tab_action: :new }, "pwd", "exit"])
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: RecordingClient.new([]), session_store: store)
      cli.send(:setup_interactive_tabs, store, nil)
      first_tab = cli.send(:active_tab)

      cli.send(:run_ekwsh, first_tab.agent)
      assert first_tab.shell
      cli.send(:handle_tab_action, cli.instance_variable_get(:@pending_inputs).shift, store)
      assert_equal 1, cli.instance_variable_get(:@active_tab_index)
      cli.send(:handle_tab_action, { tab_action: :previous }, store)
      assert_same first_tab, cli.send(:active_tab)
      restored_shell_snapshot = prompt.restores.find { |snapshot| Array(snapshot[:transcript]).join.include?("$ cd nested") }
      assert restored_shell_snapshot, "expected returning to a shell tab to restore its transcript snapshot"

      cli.send(:run_ekwsh_loop, first_tab.shell, tab: first_tab)

      output = strip_ansi(prompt.output.join)
      assert_includes output, nested
      assert_nil first_tab.shell
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

  def test_new_tab_clears_active_editor_from_previous_tab
    Dir.mktmpdir do |config_dir|
      Dir.mktmpdir do |workspace|
        path = File.join(workspace, "notes.txt")
        File.write(path, "hello")
        store = Kward::SessionStore.new(config_dir: config_dir, cwd: workspace)
        prompt = TabPrompt.new
        editor_state = nil
        prompt.define_singleton_method(:tab_view_snapshot) do
          { composer: :composer, prompt_label: "Edit>", editor_state: editor_state&.dup, transcript: output.dup }
        end
        prompt.define_singleton_method(:restore_composer_snapshot) do |snapshot|
          restores << snapshot
          editor_state = snapshot[:editor_state]&.dup
        end
        prompt.define_singleton_method(:editor_state) { editor_state }
        cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: RecordingClient.new([]), session_store: store)
        cli.send(:setup_interactive_tabs, store, nil)
        editor_state = Kward::PromptInterface::EditorState.new(path: path, content: "hello")

        cli.send(:handle_tab_action, { tab_action: :new }, store)

        assert_nil prompt.editor_state
        assert prompt.restores.last
        assert_nil prompt.restores.last[:editor_state]
        assert cli.instance_variable_get(:@tabs).first.snapshot[:editor_state]
      end
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

  def test_busy_tab_commands_manage_tabs_without_replacing_running_tab_agent
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      prompt = TabPrompt.new
      client = BlockingClient.new
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client, session_store: store)
      cli.send(:setup_interactive_tabs, store, nil)
      running_tab = cli.send(:active_tab)
      running_agent = running_tab.agent
      cli.send(:handle_tab_action, { tab_action: :new }, store)
      cli.send(:handle_tab_action, { tab_action: :previous }, store)

      cli.send(:submit_tab_input, running_tab, "hello")
      client.started.pop

      cli.send(:handle_tab_busy_input, running_tab, "/tab name Ops")
      assert_equal "Ops", running_tab.label
      assert_same running_agent, running_tab.agent
      assert running_tab.running?

      cli.send(:handle_tab_busy_input, running_tab, "/tab move right")
      assert_equal 1, cli.instance_variable_get(:@active_tab_index)
      assert_same running_tab, cli.send(:active_tab)
      assert_same running_agent, running_tab.agent

      prompt.queue_poll("/tab new")
      assert_equal({ tab_action: :busy_command }, cli.send(:poll_active_tab_input))
      cli.send(:handle_tab_action, { tab_action: :busy_command }, store)
      refute_same running_tab, cli.send(:active_tab)
      assert running_tab.running?
      assert_same running_agent, running_tab.agent

      cli.send(:handle_tab_command, "2", store)
      cli.send(:handle_tab_busy_input, running_tab, "/tab close")
      assert_equal 3, cli.instance_variable_get(:@tabs).length
      assert_includes prompt.output.join, "Tab 2 is running and cannot be closed yet."

      client.release << true
      running_tab.thread.join(1)
      assert_equal "ready", running_tab.status
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

  def test_busy_local_command_switches_tabs_and_restores_spinner_when_switching_back
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      prompt = TabPrompt.new
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([]), session_store: store)
      agent = cli.send(:setup_interactive_tabs, store, nil)
      conversation = agent.conversation
      4.times do |index|
        conversation.append_user("user #{index} #{"x " * 2_000}")
        conversation.append_assistant({ "role" => "assistant", "content" => "assistant #{index} #{"y " * 2_000}" })
      end
      cli.send(:handle_tab_action, { tab_action: :new }, store)
      cli.send(:handle_tab_action, { tab_action: :previous }, store)
      first_tab = cli.send(:active_tab)
      summarizer = BlockingSummarizer.new("## Goal\nsummary")
      compactor = Kward::Compactor.new(
        conversation: conversation,
        client: FakeClient.new([]),
        settings: Kward::Compaction::Settings.new(keep_recent_tokens: 3_000),
        summarizer: summarizer
      )

      with_compactor_stub(compactor) do
        command = Thread.new { cli.send(:handle_local_slash_command, "/compact", agent, store) }
        summarizer.started.pop
        wait_until { first_tab.local_busy? }

        prompt.queue_poll({ tab_action: :next })
        wait_until { cli.instance_variable_get(:@active_tab_index) == 1 }
        assert first_tab.local_busy?

        prompt.queue_poll({ tab_action: :previous })
        wait_until { cli.instance_variable_get(:@active_tab_index).zero? && prompt.busy_started >= 2 }
        assert first_tab.local_busy?
        assert_equal "compacting", first_tab.local_busy_activity

        summarizer.release << true
        command.join(1)
      end

      refute first_tab.local_busy?
      assert_equal cli.instance_variable_get(:@active_tab_index), 0
      assert_operator prompt.busy_finished, :>=, 2
    end
  end

  def test_tabs_run_turns_in_parallel
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
      client.release << true
      client.release << true
      first_tab.thread.join(1)
      second_tab.thread.join(1)
      assert_equal "ready", first_tab.status
      assert_equal "ready", second_tab.status
    end
  end

  def test_tab_label_colors_reflect_runtime_state
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
      assert_equal :yellow, prompt.tab_update_colors.first

      client.release << true
      first_tab.thread.join(1)
      wait_until { prompt.tab_update_colors.first == :green }

      cli.send(:handle_tab_action, { tab_action: :previous }, store)
      assert_nil prompt.tab_update_colors.first
      assert_equal second_tab, cli.instance_variable_get(:@tabs).last
    end
  end

  def test_background_tab_question_waits_for_own_tab_and_marks_green
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      prompt = QuestionTabPrompt.new
      question = question_args("Proceed?")
      client = BlockingQuestionClient.new(question)
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client, session_store: store)
      cli.send(:setup_interactive_tabs, store, nil)
      first_tab = cli.send(:active_tab)
      cli.send(:handle_tab_action, { tab_action: :new }, store)
      second_tab = cli.send(:active_tab)

      cli.send(:submit_tab_input, first_tab, "first")
      client.started.pop
      client.release << true
      wait_until { first_tab.status == "waiting_for_question" }

      assert_equal second_tab, cli.send(:active_tab)
      refute prompt.asked_question?
      assert_equal :green, prompt.tab_update_colors.first

      switch_thread = Thread.new { cli.send(:handle_tab_action, { tab_action: :previous }, store) }
      wait_until { prompt.asked_question? }
      assert_equal [question], prompt.questions.pop

      prompt.answer_question([{ question: "Proceed?", answer: "Yes" }])
      switch_thread.join(1)
      first_tab.thread.join(1)
      assert_equal "ready", first_tab.status
    end
  end

  def test_tab_label_errors_and_cancelled_runs_are_red
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      prompt = TabPrompt.new
      client = BlockingClient.new(result: RuntimeError.new("boom"))
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client, session_store: store)
      cli.send(:setup_interactive_tabs, store, nil)
      failed_tab = cli.send(:active_tab)

      cli.send(:submit_tab_input, failed_tab, "fail")
      client.started.pop
      client.release << true
      failed_tab.thread.join(1)
      wait_until { prompt.tab_update_colors.first == :red }

      assert_includes prompt.output.join, "Runtime> Tab 1 error: boom"
      prompt.output.clear
      cli.send(:render_tab, failed_tab)
      refute_includes prompt.output.join, "Tab 1 error: boom"

      failed_tab.status = "cancelled"
      failed_tab.error_reported = false
      cli.send(:update_prompt_tabs)
      cli.send(:report_tab_runtime_error, failed_tab)
      assert_equal :red, prompt.tab_update_colors.first
      assert_includes prompt.output.join, "Runtime> Tab 1 cancelled."
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

      assert_equal ["Ops"], prompt.tab_update_names
      refute_includes prompt.tab_update_names.first, "1"
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
