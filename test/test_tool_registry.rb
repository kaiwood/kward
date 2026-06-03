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

    assert_equal ["list_directory", "read_file", "write_file", "edit_file", "run_shell_command", "web_research", "read_skill"], tool_names
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

  def test_tool_registry_shell_command_runs_without_confirmation
    prompt = FakePrompt.new([], confirmations: [false])
    conversation = Kward::Conversation.new
    registry = Kward::ToolRegistry.new(prompt: prompt)

    result = registry.dispatch(tool_call("run_shell_command", command: "echo ok"), conversation)

    refute_includes prompt.output, "\nShell command request> echo ok"
    assert_includes result, "ok"
  end

end
