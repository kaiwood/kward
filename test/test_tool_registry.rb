require_relative "test_helper"

class TestToolRegistry < KwardTestCase
  def test_read_skill_reads_skill_and_related_file_from_config_dir
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "config.json"), JSON.dump({}))
      skill_dir = File.join(dir, "skills", "planner")
      FileUtils.mkdir_p(skill_dir)
      File.write(File.join(skill_dir, "SKILL.md"), "---\nname: planner\ndescription: Helps plan work.\n---\n\nFull skill body.\n")
      File.write(File.join(skill_dir, "details.md"), "Skill details.\n")

      with_env("KWARD_CONFIG_PATH" => File.join(dir, "config.json")) do
        registry = Kward::ToolRegistry.new
        conversation = Kward::Conversation.new(system_message: nil)

        assert_includes registry.dispatch(tool_call("read_skill", name: "planner"), conversation), "Full skill body."
        assert_includes registry.dispatch(tool_call("read_skill", name: "planner", path: "details.md"), conversation), "Skill details."
      end
    end
  end

  def test_read_skill_rejects_path_traversal
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "config.json"), JSON.dump({}))
      skill_dir = File.join(dir, "skills", "planner")
      FileUtils.mkdir_p(skill_dir)
      File.write(File.join(skill_dir, "SKILL.md"), "---\nname: planner\ndescription: Helps plan work.\n---\n")
      File.write(File.join(dir, "skills", "outside.md"), "outside\n")

      with_env("KWARD_CONFIG_PATH" => File.join(dir, "config.json")) do
        registry = Kward::ToolRegistry.new
        conversation = Kward::Conversation.new(system_message: nil)

        assert_equal "Error: skill path outside skill folder: ../outside.md", registry.dispatch(tool_call("read_skill", name: "planner", path: "../outside.md"), conversation)
      end
    end
  end

  def test_tool_schemas_include_edit_file_shell_command_and_web_research
    tool_names = Kward::ToolRegistry.new.schemas.map { |schema| schema[:function][:name] }

    assert_equal ["list_directory", "read_file", "write_file", "edit_file", "run_shell_command", "web_research", "read_skill", "ask_user_question"], tool_names
  end

  def test_read_file_schema_supports_offset_and_limit
    read_schema = Kward::ToolRegistry.new.schemas.find { |schema| schema[:function][:name] == "read_file" }
    properties = read_schema[:function][:parameters][:properties]

    assert_includes properties.keys, :offset
    assert_includes properties.keys, :limit
  end

  def test_ask_user_question_returns_prompt_answers_as_readable_text
    prompt = FakeQuestionPrompt.new([{ question: "Proceed?", answer: "Yes" }])
    conversation = Kward::Conversation.new
    registry = Kward::ToolRegistry.new(prompt: prompt)

    result = registry.dispatch(tool_call("ask_user_question", questions: [question_args("Proceed?")]), conversation)

    assert_equal "Proceed?: Yes", result
    assert_equal [[{ question: "Proceed?", header: "Confirm", options: [{ label: "Yes", description: "Continue." }, { label: "No", description: "Stop." }] }]], prompt.questions
  end

  def test_ask_user_question_requires_interactive_prompt_support
    conversation = Kward::Conversation.new
    registry = Kward::ToolRegistry.new(prompt: FakePrompt.new([]))

    result = registry.dispatch(tool_call("ask_user_question", questions: [question_args("Proceed?")]), conversation)

    assert_equal "Error: ask_user_question requires interactive prompt support.", result
  end

  def test_ask_user_question_validates_question_shape
    prompt = FakeQuestionPrompt.new([])
    conversation = Kward::Conversation.new
    registry = Kward::ToolRegistry.new(prompt: prompt)

    too_few = registry.dispatch(tool_call("ask_user_question", questions: [{ question: "Proceed?", header: "Confirm", options: [{ label: "Yes", description: "Continue." }] }]), conversation)
    unsupported = registry.dispatch(tool_call("ask_user_question", questions: [question_args("Proceed?").merge(multiSelect: true)]), conversation)

    assert_equal "Error: question 1 requires 2 to 4 options.", too_few
    assert_equal "Error: question 1 uses unsupported multiSelect.", unsupported
  end

  def test_tool_registry_dispatches_web_research
    research = FakeWebResearch.new("research result")
    registry = Kward::ToolRegistry.new(web_research: research)
    conversation = Kward::Conversation.new

    result = registry.dispatch(tool_call("web_research", queries: ["ruby"]), conversation)

    assert_equal "research result", result
    assert_equal [{ "queries" => ["ruby"] }], research.calls
  end

  def test_tool_registry_write_runs_without_confirmation
    path = "kward_confirm_tool.txt"
    prompt = FakePrompt.new([], confirmations: [false])
    conversation = Kward::Conversation.new
    registry = Kward::ToolRegistry.new(prompt: prompt)

    registry.dispatch(tool_call("write_file", path: path, content: "hello\n"), conversation)

    refute_includes prompt.output, "\nWrite request> #{path} (6 bytes)"
    assert_equal "hello\n", File.read(path)
  ensure
    File.delete(path) if path && File.exist?(path)
  end

  def test_tool_registry_read_file_passes_offset_and_limit
    path = "kward_offset_read_tool.txt"
    File.write(path, "one\ntwo\nthree")
    conversation = Kward::Conversation.new
    registry = Kward::ToolRegistry.new

    result = registry.dispatch(tool_call("read_file", path: path, offset: 2, limit: 1), conversation)

    assert_equal "two\n\n[1 more lines in file. Use offset=3 to continue.]", result
  ensure
    File.delete(path) if path && File.exist?(path)
  end

  def test_tool_registry_edit_file_updates_existing_read_file
    path = "kward_edit_tool.txt"
    File.write(path, "hello world\n")
    conversation = Kward::Conversation.new
    registry = Kward::ToolRegistry.new

    registry.dispatch(tool_call("read_file", path: path), conversation)
    result = registry.dispatch(tool_call("edit_file", path: path, edits: [{ old_text: "world", new_text: "there" }]), conversation)

    assert_includes result, "Edited #{path}: replaced 1 block(s)"
    assert_equal "hello there\n", File.read(path)
  ensure
    File.delete(path) if path && File.exist?(path)
  end

  def test_editing_workspace_agents_refreshes_system_prompt
    Dir.mktmpdir do |config_dir|
      Dir.mktmpdir do |workspace|
        File.write(File.join(config_dir, "config.json"), JSON.dump({}))
        agents_path = File.join(workspace, "AGENTS.md")
        File.write(agents_path, "Old guidance.\n")

        with_env("KWARD_CONFIG_PATH" => File.join(config_dir, "config.json")) do
          conversation = Kward::Conversation.new(workspace_root: workspace)
          registry = Kward::ToolRegistry.new(workspace: Kward::Workspace.new(root: workspace))

          assert_includes conversation.messages.first[:content], "Old guidance."

          registry.dispatch(tool_call("read_file", path: "AGENTS.md"), conversation)
          registry.dispatch(tool_call("edit_file", path: "AGENTS.md", edits: [{ old_text: "Old guidance.", new_text: "New guidance." }]), conversation)

          assert_includes conversation.messages.first[:content], "New guidance."
          refute_includes conversation.messages.first[:content], "Old guidance."
        end
      end
    end
  end

  def test_tool_registry_shell_command_runs_without_confirmation
    prompt = FakePrompt.new([], confirmations: [false])
    conversation = Kward::Conversation.new
    registry = Kward::ToolRegistry.new(prompt: prompt)

    result = registry.dispatch(tool_call("run_shell_command", command: "echo ok"), conversation)

    refute_includes prompt.output, "\nShell command request> echo ok"
    assert_includes result, "ok"
  end

end
