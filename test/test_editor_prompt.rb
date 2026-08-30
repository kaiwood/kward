require_relative "test_helper"

class EditorPromptTestPrompt
  attr_reader :context, :statuses, :transcript

  def initialize(context)
    @context = context
    @statuses = []
    @transcript = []
  end

  def editor_prompt_context
    @context.dup
  end

  def suspend_editor_for_agent
    true
  end

  def commit_editor_prompt(session)
    @context[:content] = session.content
    true
  end

  def resume_editor_for_agent(status: nil)
    @statuses << status
  end

  def begin_busy_input(*); end
  def finish_busy_input; end
  def poll_input; nil; end
  def say(_message); end
  def write_transcript(message); @transcript << message; end
  def start_stream_block(_label); end
  def write_delta(_delta); end
  def finish_stream_block; end
end

class EditorPromptTestClient
  attr_reader :tools, :messages, :requests

  def initialize
    @calls = 0
    @messages = []
    @requests = []
  end

  def chat(messages, tools:, **options)
    @messages << messages
    @requests << options
    @tools = tools
    @calls += 1
    return {
      "role" => "assistant",
      "content" => nil,
      "tool_calls" => [{
        "id" => "call_replace_editor_buffer",
        "type" => "function",
        "function" => {
          "name" => "replace_editor_buffer",
          "arguments" => JSON.dump("content" => "class HelloWorld; end\n")
        }
      }]
    } if @calls == 1

    { "role" => "assistant", "content" => "updated" }
  end
end

class TestEditorPrompt < KwardTestCase
  def test_editor_prompt_session_keeps_agent_changes_in_a_draft
    session = Kward::EditorPromptSession.new(content: "old", path: "notes.txt")

    session.replace("new")

    assert_equal "old", session.initial_content
    assert_equal "new", session.content
    assert session.changed?
  end

  def test_prompt_commits_editor_prompt_as_one_undoable_change
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "vibe")
    editor = Kward::PromptInterface::EditorState.new(path: "notes.txt", content: "old", editor_mode: "vibe")
    prompt.instance_variable_set(:@editor_state, editor)
    context = prompt.editor_prompt_context
    session = Kward::EditorPromptSession.new(context)
    session.replace("new")

    assert prompt.suspend_editor_for_agent
    assert prompt.commit_editor_prompt(session)
    assert prompt.resume_editor_for_agent
    assert_equal "new", editor.buffer
    assert editor.undo
    assert_equal "old", editor.buffer
  end

  def test_editor_stays_visible_and_shows_spinner_while_agent_runs
    output = StringIO.new
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: output, editor_mode: "vibe")
    editor = Kward::PromptInterface::EditorState.new(path: "notes.txt", content: "old", editor_mode: "vibe")
    prompt.instance_variable_set(:@editor_state, editor)

    assert prompt.suspend_editor_for_agent
    prompt.begin_busy_input("You>")

    assert prompt.send(:editor_visible?)
    status = strip_ansi(output.string)
    assert_includes status, "Agent is working"
    assert_includes status, "· ·"
    prompt.send(:handle_key, "i")
    assert_equal "old", editor.buffer
  end

  def test_prompt_does_not_commit_when_the_live_buffer_changed
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "vibe")
    editor = Kward::PromptInterface::EditorState.new(path: "notes.txt", content: "old", editor_mode: "vibe")
    prompt.instance_variable_set(:@editor_state, editor)
    session = Kward::EditorPromptSession.new(prompt.editor_prompt_context)
    session.replace("agent")

    assert prompt.suspend_editor_for_agent
    editor.move_file_end
    editor.insert(" user")

    refute prompt.commit_editor_prompt(session)
    assert_equal "old user", editor.buffer
  end

  def test_cli_runs_editor_prompt_in_an_isolated_agent_and_commits_the_draft
    prompt = EditorPromptTestPrompt.new(content: "class OldName; end\n", display_path: "hello.rb", language: :ruby)
    client = EditorPromptTestClient.new
    active_agent = Kward::Agent.new(client: client, conversation: Kward::Conversation.new(system_message: nil), tool_registry: Kward::ToolRegistry.new(workspace: Kward::Workspace.new))
    cli = Kward::CLI.new(prompt: prompt, client: client)

    cli.send(:run_editor_prompt_turn, { instruction: "write a HelloWorld class", display_input: ":prompt write a HelloWorld class" }, active_agent)

    request_messages = client.messages.first
    assert_equal "system", request_messages.first[:role]
    assert_includes request_messages.first[:content], "in-memory editor assistant"
    assert_includes request_messages.last[:content], "class OldName; end"
    refute_includes prompt.transcript.join, "write a HelloWorld class"
    assert_equal "class HelloWorld; end\n", prompt.context[:content]
    assert_equal [], active_agent.conversation.messages
    assert_equal [nil], prompt.statuses
  end

  def test_editor_prompt_uses_configured_model_and_reasoning
    Dir.mktmpdir do |dir|
      config_path = File.join(dir, "config.json")
      File.write(config_path, JSON.dump("editor" => { "agent" => { "provider" => "anthropic", "model" => "editor-model", "reasoning_effort" => "high" } }))
      prompt = EditorPromptTestPrompt.new(content: "old\n", display_path: "hello.rb", language: :ruby)
      client = EditorPromptTestClient.new
      active_conversation = Kward::Conversation.new(system_message: nil, provider: "OpenAI", model: "tab-model", reasoning_effort: "low")
      active_agent = Kward::Agent.new(client: client, conversation: active_conversation, tool_registry: Kward::ToolRegistry.new(workspace: Kward::Workspace.new))
      cli = Kward::CLI.new(prompt: prompt, client: client)

      with_env("KWARD_CONFIG_PATH" => config_path, "KWARD_EDITOR_PROVIDER" => nil) do
        cli.send(:run_editor_prompt_turn, { instruction: "update it" }, active_agent)
      end

      assert_equal "anthropic", client.requests.first[:provider]
      assert_equal "editor-model", client.requests.first[:model]
      assert_equal "high", client.requests.first[:reasoning]
      assert_equal true, client.requests.first[:provider_required]
    end
  end

  def test_editor_prompt_does_not_inherit_model_or_reasoning_for_a_configured_provider
    Dir.mktmpdir do |dir|
      config_path = File.join(dir, "config.json")
      File.write(config_path, JSON.dump("editor" => { "agent" => { "provider" => "anthropic" } }))
      prompt = EditorPromptTestPrompt.new(content: "old\n", display_path: "hello.rb", language: :ruby)
      client = EditorPromptTestClient.new
      active_conversation = Kward::Conversation.new(system_message: nil, provider: "Codex", model: "tab-model", reasoning_effort: "low")
      active_agent = Kward::Agent.new(client: client, conversation: active_conversation, tool_registry: Kward::ToolRegistry.new(workspace: Kward::Workspace.new))
      cli = Kward::CLI.new(prompt: prompt, client: client)

      with_env("KWARD_CONFIG_PATH" => config_path, "KWARD_EDITOR_PROVIDER" => nil) do
        cli.send(:run_editor_prompt_turn, { instruction: "update it" }, active_agent)
      end

      assert_equal "anthropic", client.requests.first[:provider]
      assert_nil client.requests.first[:model]
      assert_nil client.requests.first[:reasoning]
    end
  end

  def test_editor_prompt_falls_back_to_active_tab_model_and_reasoning
    prompt = EditorPromptTestPrompt.new(content: "old\n", display_path: "hello.rb", language: :ruby)
    client = EditorPromptTestClient.new
    active_conversation = Kward::Conversation.new(system_message: nil, provider: "OpenAI", model: "tab-model", reasoning_effort: "low")
    active_agent = Kward::Agent.new(client: client, conversation: active_conversation, tool_registry: Kward::ToolRegistry.new(workspace: Kward::Workspace.new))
    cli = Kward::CLI.new(prompt: prompt, client: client)

    cli.send(:run_editor_prompt_turn, { instruction: "update it" }, active_agent)

    assert_equal "tab-model", client.requests.first[:model]
    assert_equal "low", client.requests.first[:reasoning]
  end

  def test_real_agent_receives_editor_tool_and_commits_its_result
    prompt = EditorPromptTestPrompt.new(content: "# Foo\n\n", display_path: "scratchpad.rb", language: :ruby)
    client = EditorPromptTestClient.new
    conversation = Kward::Conversation.new(system_message: nil)
    agent = Kward::Agent.new(client: client, conversation: conversation, tool_registry: Kward::ToolRegistry.new(workspace: Kward::Workspace.new))
    cli = Kward::CLI.new(prompt: prompt, client: client)

    cli.send(:run_editor_prompt_turn, { instruction: "Write me a HelloWorld class", display_input: ":prompt Write me a HelloWorld class" }, agent)

    names = client.tools.map { |schema| schema.dig(:function, :name) }
    assert_includes names, "replace_editor_buffer"
    refute_includes names, "write_file"
    assert_equal "class HelloWorld; end\n", prompt.context[:content]
  end

  def test_editor_registry_exposes_only_in_memory_editor_writes
    base_registry = Kward::ToolRegistry.new(workspace: Kward::Workspace.new)
    refute_includes base_registry.schemas.map { |schema| schema.dig(:function, :name) }, "replace_editor_buffer"

    session = Kward::EditorPromptSession.new(content: "old", path: "notes.txt")
    registry = base_registry.for_editor_prompt(session)
    conversation = Kward::Conversation.new(system_message: nil)

    assert_includes registry.schemas.map { |schema| schema.dig(:function, :name) }, "replace_editor_buffer"
    refute_includes registry.schemas.map { |schema| schema.dig(:function, :name) }, "write_file"
    refute_includes registry.schemas.map { |schema| schema.dig(:function, :name) }, "edit_file"

    result = registry.dispatch(tool_call("replace_editor_buffer", content: "new"), conversation)

    assert_includes result, "The file has not been saved"
    assert_equal "new", session.content
  end
end
