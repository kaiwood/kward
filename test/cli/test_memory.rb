require_relative "../test_helper"

class TestCLIMemory < KwardTestCase
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

end
