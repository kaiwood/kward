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

  def test_tool_schemas_include_code_search
    tool_names = Kward::ToolRegistry.new.schemas.map { |schema| schema[:function][:name] }

    assert_includes tool_names, "code_search"
  end

  def test_schema_tools_have_explicit_display_names
    tool_names = Kward::ToolRegistry.new(prompt: FakeQuestionPrompt.new([]), skills: [Kward::ConfigFiles::Skill.new(name: "planner")]).schemas.map { |schema| schema[:function][:name] }

    tool_names.each do |name|
      assert Kward::ToolCall.normalized_name(name), "missing display name for #{name}"
    end
  end

  def test_tool_schemas_include_web_tools_by_default
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "config.json"), JSON.dump({}))

      with_env("KWARD_CONFIG_PATH" => File.join(dir, "config.json"), "EXA_API_KEY" => nil, "PERPLEXITY_API_KEY" => nil, "GEMINI_API_KEY" => nil) do
        tool_names = Kward::ToolRegistry.new.schemas.map { |schema| schema[:function][:name] }

        assert_includes tool_names, "web_search"
        assert_includes tool_names, "fetch_content"
        assert_includes tool_names, "fetch_raw"
      end
    end
  end

  def test_web_search_schema_uses_supported_provider_list
    schema = Kward::ToolRegistry.new.schemas.find { |tool_schema| tool_schema[:function][:name] == "web_search" }

    assert_equal Kward::WebSearch::PROVIDERS, schema[:function][:parameters][:properties][:provider][:enum]
  end

  def test_tool_schemas_exclude_web_tools_when_disabled
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "config.json"), JSON.dump({ "web_search" => { "enabled" => false } }))

      with_env("KWARD_CONFIG_PATH" => File.join(dir, "config.json")) do
        tool_names = Kward::ToolRegistry.new.schemas.map { |schema| schema[:function][:name] }

        refute_includes tool_names, "web_search"
        refute_includes tool_names, "fetch_content"
        refute_includes tool_names, "fetch_raw"
      end
    end
  end

  def test_tool_schemas_include_web_tools_when_enabled
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "config.json"), JSON.dump({ "web_search" => { "enabled" => true } }))

      with_env("KWARD_CONFIG_PATH" => File.join(dir, "config.json")) do
        tool_names = Kward::ToolRegistry.new.schemas.map { |schema| schema[:function][:name] }

        assert_includes tool_names, "web_search"
        assert_includes tool_names, "fetch_content"
        assert_includes tool_names, "fetch_raw"
      end
    end
  end

  def test_tool_schemas_ignore_old_web_search_disabled_config
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "config.json"), JSON.dump({ "web_research" => { "enabled" => false } }))

      with_env("KWARD_CONFIG_PATH" => File.join(dir, "config.json")) do
        tool_names = Kward::ToolRegistry.new.schemas.map { |schema| schema[:function][:name] }

        assert_includes tool_names, "web_search"
      end
    end
  end

  def test_tool_schemas_include_read_skill_only_when_skills_exist
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "config.json"), JSON.dump({}))
      skill_dir = File.join(dir, "skills", "planner")
      FileUtils.mkdir_p(skill_dir)
      File.write(File.join(skill_dir, "SKILL.md"), "---\nname: planner\ndescription: Helps plan work.\n---\n")

      with_env("KWARD_CONFIG_PATH" => File.join(dir, "config.json")) do
        tool_names = Kward::ToolRegistry.new.schemas.map { |schema| schema[:function][:name] }

        assert_includes tool_names, "read_skill"
      end
    end
  end

  def test_tool_schemas_include_ask_user_question_only_with_prompt_support
    without_prompt = Kward::ToolRegistry.new(skills: []).schemas.map { |schema| schema[:function][:name] }
    with_prompt = Kward::ToolRegistry.new(prompt: FakeQuestionPrompt.new([]), skills: []).schemas.map { |schema| schema[:function][:name] }

    refute_includes without_prompt, "ask_user_question"
    assert_includes with_prompt, "ask_user_question"
  end

  def test_tool_schemas_can_disable_ask_user_question
    tool_names = Kward::ToolRegistry.new(prompt: FakeQuestionPrompt.new([]), skills: [], ask_user_question_enabled: false).schemas.map { |schema| schema[:function][:name] }

    refute_includes tool_names, "ask_user_question"
  end

  def test_read_file_schema_supports_offset_and_limit
    read_schema = Kward::ToolRegistry.new.schemas.find { |schema| schema[:function][:name] == "read_file" }
    properties = read_schema[:function][:parameters][:properties]

    assert_includes properties.keys, :offset
    assert_includes properties.keys, :limit
  end

  def test_tool_schemas_are_strict_output_contract
    Kward::ToolRegistry.new(prompt: FakeQuestionPrompt.new([]), skills: [Kward::ConfigFiles::Skill.new(name: "planner")]).schemas.each do |schema|
      parameters = schema[:function][:parameters]

      assert_equal false, parameters[:additionalProperties], "#{schema[:function][:name]} should not advertise extra fields"
    end
  end

  def test_tool_registry_ignores_extra_incoming_fields
    Dir.mktmpdir do |dir|
      path = "kward_extra_input.txt"
      File.write(File.join(dir, path), "hello\n")
      conversation = Kward::Conversation.new
      registry = Kward::ToolRegistry.new(workspace: Kward::Workspace.new(root: dir))

      result = registry.dispatch(tool_call("read_file", path: path, offset: 1, ignored: "compatibility"), conversation)

      assert_equal "hello\n", result
    end
  end

  def test_tool_registry_keeps_required_value_errors_for_tolerant_input
    conversation = Kward::Conversation.new
    registry = Kward::ToolRegistry.new

    result = registry.dispatch(tool_call("read_file", path: ""), conversation)

    assert_match(/Error:/, result)
  end

  def test_code_search_schema_advertises_canonical_ecosystems_only
    code_schema = Kward::ToolRegistry.new.schemas.find { |schema| schema[:function][:name] == "code_search" }
    ecosystem_enum = code_schema[:function][:parameters][:properties][:ecosystem][:enum]

    assert_equal %w[rubygems npm pypi crates go], ecosystem_enum
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
    missing_text = registry.dispatch(tool_call("ask_user_question", questions: [question_args("Proceed?").merge(question: "")]), conversation)
    missing_option_label = registry.dispatch(tool_call("ask_user_question", questions: [question_args("Proceed?").merge(options: [{ label: "", description: "Continue." }, { label: "No", description: "Stop." }])]), conversation)

    assert_equal "Error: question 1 requires 2 to 4 options.", too_few
    assert_equal "Error: question 1 uses unsupported multiSelect.", unsupported
    assert_equal "Error: question 1 requires question and header.", missing_text
    assert_equal "Error: question 1 option 1 requires label and description.", missing_option_label
  end

  def test_tool_registry_dispatches_web_search
    search = FakeWebSearch.new("research result")
    registry = Kward::ToolRegistry.new(web_search: search, web_search_enabled: true)
    conversation = Kward::Conversation.new

    result = registry.dispatch(tool_call("web_search", queries: ["ruby"]), conversation)

    assert_equal "research result", result
    assert_equal [{ "queries" => ["ruby"] }], search.calls
  end

  def test_tool_registry_dispatches_fetch_content
    fetch = Object.new
    fetch.define_singleton_method(:fetch_content) do |args|
      @calls ||= []
      @calls << args
      "fetched content"
    end
    fetch.define_singleton_method(:calls) { @calls }
    registry = Kward::ToolRegistry.new(web_fetch: fetch, web_search_enabled: true)
    conversation = Kward::Conversation.new

    result = registry.dispatch(tool_call("fetch_content", url: "https://example.com"), conversation)

    assert_equal "fetched content", result
    assert_equal [{ "url" => "https://example.com" }], fetch.calls
  end

  def test_tool_registry_normalizes_binary_tool_content_for_callbacks
    binary_content = +"fetched \xff content"
    binary_content.force_encoding(Encoding::ASCII_8BIT)
    fetch = Object.new
    fetch.define_singleton_method(:fetch_content) { |_args| binary_content }
    registry = Kward::ToolRegistry.new(web_fetch: fetch, web_search_enabled: true)
    callback_content = nil
    conversation = Kward::Conversation.new
    conversation.on_tool_execution = lambda { |_tool_call, content| callback_content = content }

    result = registry.dispatch(tool_call("fetch_content", url: "https://example.com"), conversation)

    assert_equal Encoding::UTF_8, result.encoding
    assert result.valid_encoding?
    assert_equal result, conversation.messages.last[:content]
    assert_equal result, callback_content
    JSON.generate({ content: callback_content })
  end

  def test_tool_registry_dispatches_code_search
    search = FakeCodeSearch.new("code result")
    registry = Kward::ToolRegistry.new(code_search: search)
    conversation = Kward::Conversation.new

    result = registry.dispatch(tool_call("code_search", action: "list_cache"), conversation)

    assert_equal "code result", result
    assert_equal [{ "action" => "list_cache" }], search.calls
  end

  def test_tool_registry_write_runs_without_confirmation
    Dir.mktmpdir do |dir|
      path = "kward_confirm_tool.txt"
      prompt = FakePrompt.new([], confirmations: [false])
      conversation = Kward::Conversation.new
      registry = Kward::ToolRegistry.new(prompt: prompt, workspace: Kward::Workspace.new(root: dir))

      registry.dispatch(tool_call("write_file", path: path, content: "hello\n"), conversation)

      refute_includes prompt.output, "\nWrite request> #{path} (6 bytes)"
      assert_equal "hello\n", File.read(File.join(dir, path))
    end
  end

  def test_tool_registry_read_file_passes_offset_and_limit
    Dir.mktmpdir do |dir|
      path = "kward_offset_read_tool.txt"
      File.write(File.join(dir, path), "one\ntwo\nthree")
      conversation = Kward::Conversation.new
      registry = Kward::ToolRegistry.new(workspace: Kward::Workspace.new(root: dir))

      result = registry.dispatch(tool_call("read_file", path: path, offset: 2, limit: 1), conversation)

      assert_equal "two\n\n[1 more lines in file. Use offset=3 to continue.]", result
    end
  end

  def test_tool_registry_edit_file_updates_existing_read_file
    Dir.mktmpdir do |dir|
      path = "kward_edit_tool.txt"
      File.write(File.join(dir, path), "hello world\n")
      conversation = Kward::Conversation.new
      registry = Kward::ToolRegistry.new(workspace: Kward::Workspace.new(root: dir))

      registry.dispatch(tool_call("read_file", path: path), conversation)
      result = registry.dispatch(tool_call("edit_file", path: path, edits: [{ old_text: "world", new_text: "there" }]), conversation)

      assert_includes result, "Edited #{path}: replaced 1 block(s)"
      assert_equal "hello there\n", File.read(File.join(dir, path))
    end
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

          assert_includes conversation.system_message[:content], "AGENTS.md"

          registry.dispatch(tool_call("read_file", path: "AGENTS.md"), conversation)
          registry.dispatch(tool_call("edit_file", path: "AGENTS.md", edits: [{ old_text: "Old guidance.", new_text: "New guidance." }]), conversation)

          assert_includes conversation.system_message[:content], "AGENTS.md"
          refute_includes conversation.system_message[:content], "New guidance."
          refute_includes conversation.system_message[:content], "Old guidance."
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
