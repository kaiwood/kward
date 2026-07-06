require_relative "../test_helper"

class TestCLISettingsInteractions < KwardTestCase
  class CountingConversation < Kward::Conversation
    attr_reader :refresh_count

    def refresh_system_message!
      @refresh_count ||= 0
      @refresh_count += 1
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

  def test_prompt_reasoning_action_cycles_reasoning_forward
    Dir.mktmpdir do |dir|
      config_path = File.join(dir, "config.json")
      Kward::ConfigFiles.write_config({ "openai_reasoning_effort" => "medium" }, config_path)
      client = FakeClient.new([])
      client.provider = "Codex"
      client.model = "gpt-5.5"
      client.reasoning_effort = "medium"
      prompt = FakePrompt.new([{ reasoning_action: :next }, "/exit"])
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client)

      with_env("KWARD_CONFIG_PATH" => config_path) do
        cli.interactive_loop
      end

      assert_equal "high", JSON.parse(File.read(config_path))["openai_reasoning_effort"]
      assert_equal "high", cli.send(:current_footer_conversation).reasoning_effort
      assert_equal 1, client.reload_count
      assert_equal 1, prompt.refresh_composer_status_count
      assert_equal 0, prompt.redraw_count
    end
  end

  def test_prompt_reasoning_action_debounces_config_persistence
    Dir.mktmpdir do |dir|
      config_path = File.join(dir, "config.json")
      Kward::ConfigFiles.write_config({ "openai_reasoning_effort" => "medium" }, config_path)
      client = FakeClient.new([])
      client.provider = "Codex"
      client.model = "gpt-5.5"
      client.reasoning_effort = "medium"
      prompt = FakePrompt.new([{ reasoning_action: :next }, { reasoning_action: :next }, { reasoning_action: :previous }])
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client)
      cli.define_singleton_method(:schedule_reasoning_config_flush) {}
      conversation = CountingConversation.new(system_message: nil, provider: "Codex", model: "gpt-5.5", reasoning_effort: "medium")
      with_env("KWARD_CONFIG_PATH" => config_path) do
        cli.send(:cycle_reasoning, conversation, direction: :next, persist: :debounced)
        cli.send(:cycle_reasoning, conversation, direction: :next, persist: :debounced)

        assert_equal "xhigh", conversation.reasoning_effort
        assert_equal "medium", JSON.parse(File.read(config_path))["openai_reasoning_effort"]
        assert_equal 0, client.reload_count
        assert_equal 0, conversation.refresh_count.to_i
        assert_equal 2, prompt.refresh_composer_status_count
        assert_equal 0, prompt.redraw_count

        cli.send(:flush_pending_reasoning_config, conversation: conversation)
      end

      assert_equal "xhigh", JSON.parse(File.read(config_path))["openai_reasoning_effort"]
      assert_equal 1, client.reload_count
      assert_equal 1, conversation.refresh_count
    end
  end

  def test_prompt_reasoning_action_cycles_reasoning_backward_with_wraparound
    Dir.mktmpdir do |dir|
      config_path = File.join(dir, "config.json")
      Kward::ConfigFiles.write_config({ "openai_reasoning_effort" => "none" }, config_path)
      client = FakeClient.new([])
      client.provider = "Codex"
      client.model = "gpt-5.5"
      client.reasoning_effort = "none"
      prompt = FakePrompt.new([{ reasoning_action: :previous }, "/exit"])
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client)

      with_env("KWARD_CONFIG_PATH" => config_path) do
        cli.interactive_loop
      end

      assert_equal "xhigh", JSON.parse(File.read(config_path))["openai_reasoning_effort"]
      assert_equal "xhigh", cli.send(:current_footer_conversation).reasoning_effort
    end
  end

  def test_prompt_reasoning_action_noops_for_unsupported_models
    Dir.mktmpdir do |dir|
      config_path = File.join(dir, "config.json")
      Kward::ConfigFiles.write_config({ "openai_reasoning_effort" => "medium" }, config_path)
      client = FakeClient.new([])
      client.provider = "OpenAI"
      client.model = "gpt-4.1"
      client.reasoning_effort = "medium"
      prompt = FakePrompt.new([{ reasoning_action: :next }, "/exit"])
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client)

      with_env("KWARD_CONFIG_PATH" => config_path) do
        cli.interactive_loop
      end

      assert_equal "medium", JSON.parse(File.read(config_path))["openai_reasoning_effort"]
      assert_empty prompt.output
      assert_equal 0, client.reload_count
      assert_equal 0, prompt.refresh_composer_status_count
      assert_equal 0, prompt.redraw_count
    end
  end

  def test_settings_interface_can_change_editor_mode
    Dir.mktmpdir do |dir|
      config_path = File.join(dir, "config.json")
      Kward::ConfigFiles.write_config({ "editor" => { "mode" => "default" } }, config_path)
      prompt = FakeSettingsPrompt.new(["/settings", "/exit"], ["Interface", "Editor mode (modern)", "vibe"])
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: RecordingClient.new([]))

      with_env("KWARD_CONFIG_PATH" => config_path) do
        cli.interactive_loop
      end

      assert_equal "vibe", JSON.parse(File.read(config_path)).dig("editor", "mode")
      assert_includes prompt.output.join("\n"), "Editor mode set to vibe. New editor buffers will use this mode."
      editor_mode_index = prompt.select_messages.index("Editor mode")
      assert editor_mode_index
      assert_includes prompt.select_choices[editor_mode_index], "modern (current)"
      assert_includes prompt.select_choices[editor_mode_index], "emacs"
      assert_includes prompt.select_choices[editor_mode_index], "vibe"
    end
  end

  def test_settings_interface_can_set_editor_line_numbers
    Dir.mktmpdir do |dir|
      config_path = File.join(dir, "config.json")
      Kward::ConfigFiles.write_config({ "editor" => { "line_numbers" => "absolute" } }, config_path)
      prompt = FakeSettingsPrompt.new(["/settings", "/exit"], ["Interface", "Editor line numbers (absolute)", "relative"])
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: RecordingClient.new([]))

      with_env("KWARD_CONFIG_PATH" => config_path) do
        cli.interactive_loop
      end

      assert_equal "relative", JSON.parse(File.read(config_path)).dig("editor", "line_numbers")
      assert_includes prompt.output.join("\n"), "Editor line numbers set to relative."
      line_numbers_index = prompt.select_messages.index("Editor line numbers")
      assert line_numbers_index
      assert_includes prompt.select_choices[line_numbers_index], "absolute (current)"
      assert_includes prompt.select_choices[line_numbers_index], "relative"
    end
  end

  def test_settings_interface_can_set_diff_view
    Dir.mktmpdir do |dir|
      config_path = File.join(dir, "config.json")
      Kward::ConfigFiles.write_config({ "editor" => { "diff_view" => "auto" } }, config_path)
      prompt = FakeSettingsPrompt.new(["/settings", "/exit"], ["Interface", "Diff view (auto)", "side-by-side"])
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: RecordingClient.new([]))

      with_env("KWARD_CONFIG_PATH" => config_path) do
        cli.interactive_loop
      end

      assert_equal "side_by_side", JSON.parse(File.read(config_path)).dig("editor", "diff_view")
      assert_includes prompt.output.join("\n"), "Diff view set to side-by-side."
      diff_view_index = prompt.select_messages.index("Diff view")
      assert diff_view_index
      assert_includes prompt.select_choices[diff_view_index], "auto (current)"
      assert_includes prompt.select_choices[diff_view_index], "unified"
      assert_includes prompt.select_choices[diff_view_index], "side-by-side"
    end
  end

  def test_settings_interface_can_toggle_editor_soft_wrap
    Dir.mktmpdir do |dir|
      config_path = File.join(dir, "config.json")
      Kward::ConfigFiles.write_config({ "editor" => { "soft_wrap" => true } }, config_path)
      prompt = FakeSettingsPrompt.new(["/settings", "/exit"], ["Interface", "Disable soft-wrap (currently on)"])
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: RecordingClient.new([]))

      with_env("KWARD_CONFIG_PATH" => config_path) do
        cli.interactive_loop
      end

      assert_equal false, JSON.parse(File.read(config_path)).dig("editor", "soft_wrap")
      assert_includes prompt.output.join("\n"), "Editor soft-wrap disabled."
      interface_index = prompt.select_messages.index("Interface")
      assert interface_index
      assert_includes prompt.select_choices[interface_index], "Disable soft-wrap (currently on)"
    end
  end

  def test_settings_interface_can_toggle_editor_bar_cursor
    Dir.mktmpdir do |dir|
      config_path = File.join(dir, "config.json")
      Kward::ConfigFiles.write_config({ "editor" => { "bar_cursor" => true } }, config_path)
      prompt = FakeSettingsPrompt.new(["/settings", "/exit"], ["Interface", "Disable bar cursor (currently on)"])
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: RecordingClient.new([]))

      with_env("KWARD_CONFIG_PATH" => config_path) do
        cli.interactive_loop
      end

      assert_equal false, JSON.parse(File.read(config_path)).dig("editor", "bar_cursor")
      assert_includes prompt.output.join("\n"), "Editor bar cursor disabled."
      interface_index = prompt.select_messages.index("Interface")
      assert interface_index
      assert_includes prompt.select_choices[interface_index], "Disable bar cursor (currently on)"
    end
  end

end
