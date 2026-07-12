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

  def test_read_skill_wraps_default_activation_and_lists_resources
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "config.json"), JSON.dump({}))
      skill_dir = File.join(dir, "skills", "planner")
      FileUtils.mkdir_p(File.join(skill_dir, "references"))
      FileUtils.mkdir_p(File.join(skill_dir, "scripts"))
      File.write(File.join(skill_dir, "SKILL.md"), "---\nname: planner\ndescription: Helps plan work.\n---\n\nFull skill body.\n")
      File.write(File.join(skill_dir, "references", "details.md"), "Skill details.\n")
      File.write(File.join(skill_dir, "scripts", "run.sh"), "echo hi\n")

      with_env("KWARD_CONFIG_PATH" => File.join(dir, "config.json")) do
        registry = Kward::ToolRegistry.new
        conversation = Kward::Conversation.new(system_message: nil)
        result = registry.dispatch(tool_call("read_skill", name: "planner"), conversation)

        assert_includes result, '<skill_content name="planner">'
        assert_includes result, "Full skill body."
        assert_includes result, "Skill directory: #{File.realpath(skill_dir)}"
        assert_includes result, "<skill_resources>"
        assert_includes result, "<file>references/details.md</file>"
        assert_includes result, "<file>scripts/run.sh</file>"
        assert_includes result, "</skill_content>"
      end
    end
  end

  def test_read_skill_repeats_content_even_when_artifact_exists
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "config.json"), JSON.dump({}))
      skill_dir = File.join(dir, "skills", "planner")
      FileUtils.mkdir_p(skill_dir)
      skill_content = "---\nname: planner\ndescription: Helps plan work.\n---\n\nFull skill body.\n"
      File.write(File.join(skill_dir, "SKILL.md"), skill_content)

      with_env("KWARD_CONFIG_PATH" => File.join(dir, "config.json")) do
        registry = Kward::ToolRegistry.new
        conversation = Kward::Conversation.new(system_message: nil)
        artifact_id = conversation.restore_tool_output_artifact(tool_name: "read_skill", content: skill_content)

        result = registry.dispatch(tool_call("read_skill", name: "planner"), conversation)

        assert_includes result, "Full skill body."
        refute_includes result, "Same as previous tool output #{artifact_id}"
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

  def test_read_skill_schema_constrains_names_to_available_skills
    skills = [
      Kward::ConfigFiles::Skill.new(name: "planner", description: "Plans."),
      Kward::ConfigFiles::Skill.new(name: "reviewer", description: "Reviews.")
    ]
    schema = Kward::ToolRegistry.new(skills: skills).schemas.find { |tool| tool[:function][:name] == "read_skill" }

    assert_equal ["planner", "reviewer"], schema[:function][:parameters][:properties][:name][:enum]
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

  def test_tool_schemas_include_summarize_file_structure
    tool_names = Kward::ToolRegistry.new.schemas.map { |schema| schema[:function][:name] }

    assert_includes tool_names, "summarize_file_structure"
  end

  def test_tool_schemas_include_context_for_task
    tool_names = Kward::ToolRegistry.new.schemas.map { |schema| schema[:function][:name] }

    assert_includes tool_names, "context_for_task"
  end

  def test_context_for_task_returns_ranked_outlines_and_excerpts_within_budget
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "lib"))
      File.write(File.join(dir, "lib", "auth.rb"), "class AuthService\n  def validate_token(token)\n    token == 'valid'\n  end\nend\n")
      File.write(File.join(dir, "lib", "billing.rb"), "class Billing\n  def charge\n  end\nend\n")
      registry = Kward::ToolRegistry.new(workspace: Kward::Workspace.new(root: dir), web_search_enabled: false)
      conversation = Kward::Conversation.new(system_message: nil, workspace_root: dir)

      result = registry.dispatch(tool_call("context_for_task", task: "debug validate token", paths: ["lib"], budget: 2_000), conversation)

      assert_includes result, "# Focused context"
      assert_includes result, "## lib/auth.rb"
      assert_includes result, "def validate_token(token)"
      assert_includes result, "### Matching excerpts"
      refute_includes result, "## lib/billing.rb"
    end
  end

  def test_context_for_task_reports_when_candidates_do_not_match_task
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "lib"))
      File.write(File.join(dir, "lib", "billing.rb"), "class Billing\n  def charge\n  end\nend\n")
      registry = Kward::ToolRegistry.new(workspace: Kward::Workspace.new(root: dir), web_search_enabled: false)
      conversation = Kward::Conversation.new(system_message: nil, workspace_root: dir)

      result = registry.dispatch(tool_call("context_for_task", task: "debug validate token", paths: ["lib"], budget: 2_000), conversation)

      assert_equal "No matching candidate files found for focused context.", result
    end
  end

  def test_context_budget_stats_reports_conversation_tool_savings
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "demo.txt"), "hello world\n")
      compactor = Object.new
      def compactor.compact(name, content)
        name == "read_file" ? "short" : content
      end
      registry = Kward::ToolRegistry.new(
        workspace: Kward::Workspace.new(root: dir),
        web_search_enabled: false,
        tool_output_compactor: compactor
      )
      conversation = Kward::Conversation.new(system_message: nil, workspace_root: dir)

      registry.dispatch(tool_call("read_file", path: "demo.txt"), conversation)
      result = registry.dispatch(tool_call("context_budget_stats", {}), conversation)

      assert_includes result, "# Context budget stats"
      assert_includes result, "- Calls: 1"
      assert_includes result, "- Saved bytes: 7"
      assert_includes result, "- read_file: 1 call(s), 7 bytes saved"
    end
  end

  def test_tool_output_compaction_hooks_wrap_compactor
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "demo.txt"), "hello world\n")
      compactor = Object.new
      def compactor.compact(_name, _content)
        "short"
      end
      manager = Kward::Hooks::Manager.new
      events = []
      manager.register("tool_output_compact_before") do |event, _ctx|
        events << [event.name, event.payload[:tool_name], event.payload[:bytes]]
        Kward::Hooks::Decision.allow
      end
      manager.register("tool_output_compact_after") do |event, _ctx|
        events << [event.name, event.payload[:tool_name], event.payload[:compacted]]
        Kward::Hooks::Decision.allow
      end
      registry = Kward::ToolRegistry.new(workspace: Kward::Workspace.new(root: dir), web_search_enabled: false, tool_output_compactor: compactor, hook_manager: manager)
      conversation = Kward::Conversation.new(system_message: nil, workspace_root: dir)

      result = registry.dispatch(tool_call("read_file", path: "demo.txt"), conversation)

      assert_equal "short", result
      assert_equal "tool_output_compact_before", events[0][0]
      assert_equal "read_file", events[0][1]
      assert_equal ["tool_output_compact_after", "read_file", true], events[1]
    end
  end

  def test_tool_output_compaction_before_hook_can_skip_compaction
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "demo.txt"), "hello world\n")
      compactor = Object.new
      def compactor.compact(_name, _content)
        "short"
      end
      manager = Kward::Hooks::Manager.new
      manager.register("tool_output_compact_before") { Kward::Hooks::Decision.deny("No compaction") }
      registry = Kward::ToolRegistry.new(workspace: Kward::Workspace.new(root: dir), web_search_enabled: false, tool_output_compactor: compactor, hook_manager: manager)
      conversation = Kward::Conversation.new(system_message: nil, workspace_root: dir)

      result = registry.dispatch(tool_call("read_file", path: "demo.txt"), conversation)

      assert_includes result, "hello world"
    end
  end

  def test_context_budget_stats_survive_tool_registry_rebuild_for_same_conversation
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "demo.txt"), "hello world\n")
      compactor = Object.new
      def compactor.compact(name, content)
        name == "read_file" ? "short" : content
      end
      conversation = Kward::Conversation.new(system_message: nil, workspace_root: dir)

      Kward::ToolRegistry.new(workspace: Kward::Workspace.new(root: dir), web_search_enabled: false, tool_output_compactor: compactor).dispatch(tool_call("read_file", path: "demo.txt"), conversation)
      result = Kward::ToolRegistry.new(workspace: Kward::Workspace.new(root: dir), web_search_enabled: false).dispatch(tool_call("context_budget_stats", {}), conversation)

      assert_includes result, "- Calls: 1"
      assert_includes result, "- Saved bytes: 7"
    end
  end

  def test_context_budget_stats_are_isolated_by_conversation
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "demo.txt"), "hello world\n")
      compactor = Object.new
      def compactor.compact(name, content)
        name == "read_file" ? "short" : content
      end
      registry = Kward::ToolRegistry.new(workspace: Kward::Workspace.new(root: dir), web_search_enabled: false, tool_output_compactor: compactor)
      first = Kward::Conversation.new(system_message: nil, workspace_root: dir)
      second = Kward::Conversation.new(system_message: nil, workspace_root: dir)

      registry.dispatch(tool_call("read_file", path: "demo.txt"), first)
      result = registry.dispatch(tool_call("context_budget_stats", {}), second)

      assert_includes result, "- Calls: 0"
      assert_includes result, "- Saved bytes: 0"
    end
  end

  def test_read_file_schema_supports_offset_and_limit
    read_schema = Kward::ToolRegistry.new.schemas.find { |schema| schema[:function][:name] == "read_file" }
    properties = read_schema[:function][:parameters][:properties]

    assert_includes properties.keys, :offset
    assert_includes properties.keys, :limit
  end

  def test_tool_schema_properties_are_deterministically_sorted
    Kward::ToolRegistry.new(prompt: FakeQuestionPrompt.new([]), skills: [Kward::ConfigFiles::Skill.new(name: "planner")]).schemas.each do |schema|
      keys = schema[:function][:parameters][:properties].keys.map(&:to_s)

      assert_equal keys.sort, keys, "#{schema[:function][:name]} properties should be sorted"
    end
  end

  def test_tool_schemas_are_strict_output_contract
    Kward::ToolRegistry.new(prompt: FakeQuestionPrompt.new([]), skills: [Kward::ConfigFiles::Skill.new(name: "planner")]).schemas.each do |schema|
      parameters = schema[:function][:parameters]

      assert_equal false, parameters[:additionalProperties], "#{schema[:function][:name]} should not advertise extra fields"
    end
  end

  def test_tool_registry_runs_mcp_lifecycle_hooks
    client = Object.new
    client.define_singleton_method(:name) { "demo-server" }
    client.define_singleton_method(:list_tools) do
      [{ "name" => "inspect", "description" => "Inspect", "inputSchema" => { "type" => "object", "properties" => {}, "additionalProperties" => false } }]
    end
    client.define_singleton_method(:call_tool) do |_name, _args|
      { "content" => [{ "type" => "text", "text" => "ok" }] }
    end
    events = []
    manager = Kward::Hooks::Manager.new
    %w[mcp_tool_before mcp_tool_after].each do |event_name|
      manager.register(event_name) do |event, _context|
        events << [event.name, event.payload[:server_name], event.payload[:remote_name]]
        Kward::Hooks::Decision.allow
      end
    end
    registry = Kward::ToolRegistry.new(mcp_clients: [client], hook_manager: manager)
    conversation = Kward::Conversation.new

    result = registry.dispatch(tool_call("demo-server__inspect", {}), conversation)

    assert_equal "ok", result
    assert_equal [
      ["mcp_tool_before", "demo-server", "inspect"],
      ["mcp_tool_after", "demo-server", "inspect"]
    ], events
  end

  def test_tool_registry_mcp_before_hook_can_deny
    client = Object.new
    client.define_singleton_method(:name) { "demo-server" }
    client.define_singleton_method(:list_tools) { [{ "name" => "inspect", "inputSchema" => {} }] }
    client.define_singleton_method(:call_tool) { |_name, _args| flunk("MCP client should not be called") }
    manager = Kward::Hooks::Manager.new
    manager.register("mcp_tool_before") { Kward::Hooks::Decision.deny("blocked") }
    registry = Kward::ToolRegistry.new(mcp_clients: [client], hook_manager: manager)

    result = registry.dispatch(tool_call("demo-server__inspect", {}), Kward::Conversation.new)

    assert_equal "Declined: blocked", result
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

  def test_tool_registry_reuses_artifact_for_repeated_large_output
    output = (["start"] + Array.new(2_000) { |index| "line #{index}" } + ["end"]).join("\n")
    search = FakeCodeSearch.new(output)
    registry = Kward::ToolRegistry.new(code_search: search)
    conversation = Kward::Conversation.new

    first = registry.dispatch(tool_call("code_search", action: "list_cache"), conversation)
    artifact_id = first[/toolout_[a-f0-9]{16}/]
    second = registry.dispatch(tool_call("code_search", action: "list_cache"), conversation)

    assert_includes second, "Same as previous tool output #{artifact_id}"
    assert_operator second.bytesize, :<, first.bytesize
    assert_equal 1, conversation.tool_output_artifacts.length
    assert_operator conversation.context_budget_meter.snapshot.saved_bytes, :>=, output.bytesize - second.bytesize
  end

  def test_tool_registry_does_not_store_artifacts_for_uncompacted_output
    search = FakeCodeSearch.new("small output")
    registry = Kward::ToolRegistry.new(code_search: search)
    conversation = Kward::Conversation.new

    registry.dispatch(tool_call("code_search", action: "list_cache"), conversation)

    assert_empty conversation.tool_output_artifacts
  end

  def test_tool_registry_compacts_large_tool_output_for_model_context
    output = (["start"] + Array.new(2_000) { |index| "line #{index}" } + ["ERROR: important failure", "end"]).join("\n")
    search = FakeCodeSearch.new(output)
    registry = Kward::ToolRegistry.new(code_search: search)
    callback_content = nil
    conversation = Kward::Conversation.new
    conversation.on_tool_execution = lambda { |_tool_call, content| callback_content = content }

    result = registry.dispatch(tool_call("code_search", action: "list_cache"), conversation)

    assert_includes result, "[Tool output compacted by Kward:"
    assert_includes result, "ERROR: important failure"
    assert_match(/Full output id: toolout_[a-f0-9]{16}/, result)
    assert_operator result.bytesize, :<, output.bytesize
    assert_equal result, conversation.messages.last[:content]
    assert_equal output, callback_content
  end

  def test_tool_registry_compacts_shell_sections_independently
    output = "Exit status: 1\n\nSTDOUT:\n" + Array.new(2_000) { |index| "out #{index}" }.join("\n") + "\nSTDERR:\n" + Array.new(2_000) { |index| "err #{index}" }.join("\n") + "\nfatal: build failed"
    workspace = Object.new
    workspace.define_singleton_method(:run_shell_command) { |_command, **_kwargs| output }
    registry = Kward::ToolRegistry.new(workspace: workspace)
    conversation = Kward::Conversation.new

    result = registry.dispatch(tool_call("run_shell_command", command: "bundle exec rake"), conversation)

    assert_includes result, "STDOUT:"
    assert_includes result, "STDERR:"
    assert_includes result, "fatal: build failed"
    assert_operator result.bytesize, :<, output.bytesize
  end

  def test_tool_registry_preserves_search_result_anchors_in_compacted_output
    output = (["# Code search", ""] + Array.new(1_500) { |index| "noise #{index}" } + ["## lib/kward/agent.rb:42", "- lib/kward/agent.rb:42: def run_turn", "https://github.com/kaiwood/kward/blob/main/lib/kward/agent.rb#L42"]).join("\n")
    search = FakeCodeSearch.new(output)
    registry = Kward::ToolRegistry.new(code_search: search)
    conversation = Kward::Conversation.new

    result = registry.dispatch(tool_call("code_search", action: "repo_search"), conversation)

    assert_includes result, "## lib/kward/agent.rb:42"
    assert_includes result, "lib/kward/agent.rb:42: def run_turn"
    assert_includes result, "https://github.com/kaiwood/kward"
    assert_operator result.bytesize, :<, output.bytesize
  end

  def test_tool_registry_preserves_fetched_content_headings_and_links_in_compacted_output
    body = (["# Fetched content", "- URL: https://example.com/guide", "", "# Main Guide"] + Array.new(1_500) { |index| "paragraph #{index}" } + ["## Important Section", "https://example.com/guide#important"]).join("\n")
    fetch = Object.new
    fetch.define_singleton_method(:fetch_content) { |_args| body }
    registry = Kward::ToolRegistry.new(web_fetch: fetch, web_search_enabled: true)
    conversation = Kward::Conversation.new

    result = registry.dispatch(tool_call("fetch_content", url: "https://example.com/guide"), conversation)

    assert_includes result, "# Fetched content"
    assert_includes result, "# Main Guide"
    assert_includes result, "## Important Section"
    assert_includes result, "https://example.com/guide#important"
    assert_operator result.bytesize, :<, body.bytesize
  end

  def test_tool_registry_preserves_test_failure_summaries_in_compacted_output
    output = "Exit status: 1\n\nSTDOUT:\n" + Array.new(1_500) { |index| "progress #{index}" }.join("\n") + "\n  1) Failure:\nTestThing#test_breaks [test/test_thing.rb:12]:\nExpected true.\n\n42 runs, 100 assertions, 1 failures, 0 errors, 0 skips"
    workspace = Object.new
    workspace.define_singleton_method(:run_shell_command) { |_command, **_kwargs| output }
    registry = Kward::ToolRegistry.new(workspace: workspace)
    conversation = Kward::Conversation.new

    result = registry.dispatch(tool_call("run_shell_command", command: "ruby -Itest test/test_thing.rb"), conversation)

    assert_includes result, "1) Failure:"
    assert_includes result, "TestThing#test_breaks"
    assert_includes result, "42 runs, 100 assertions, 1 failures, 0 errors, 0 skips"
    assert_operator result.bytesize, :<, output.bytesize
  end

  def test_retrieve_tool_output_returns_original_compacted_output
    output = (["start"] + Array.new(2_000) { |index| "line #{index}" } + ["ERROR: important failure", "end"]).join("\n")
    search = FakeCodeSearch.new(output)
    registry = Kward::ToolRegistry.new(code_search: search)
    conversation = Kward::Conversation.new

    compacted = registry.dispatch(tool_call("code_search", action: "list_cache"), conversation)
    artifact_id = compacted[/toolout_[a-f0-9]{16}/]
    result = registry.dispatch(tool_call("retrieve_tool_output", id: artifact_id, query: "important", limit: 1), conversation)

    assert_includes result, "[Retrieved tool output #{artifact_id} matching \"important\""
    assert_includes result, "ERROR: important failure"
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

  def test_tool_registry_runs_lifecycle_hooks_around_tools
    manager = Kward::Hooks::Manager.new
    events = []
    manager.register("tool_call_before") do |event, _ctx|
      events << [event.name, event.payload[:tool_name]]
      Kward::Hooks::Decision.allow
    end
    manager.register("tool_call_after") do |event, _ctx|
      events << [event.name, event.payload[:tool_name], event.payload[:content].include?("test_agent.rb")]
      Kward::Hooks::Decision.allow
    end
    registry = Kward::ToolRegistry.new(hook_manager: manager)
    conversation = Kward::Conversation.new

    result = registry.dispatch(tool_call("list_directory", path: "test"), conversation)

    assert_includes result, "test_tool_registry.rb"
    assert_equal [["tool_call_before", "list_directory"], ["tool_call_after", "list_directory", true]], events
  end

  def test_tool_registry_hook_can_deny_tool_call
    manager = Kward::Hooks::Manager.new
    manager.register("tool_call_before") { Kward::Hooks::Decision.deny("Blocked by policy") }
    registry = Kward::ToolRegistry.new(hook_manager: manager)
    conversation = Kward::Conversation.new

    result = registry.dispatch(tool_call("list_directory", path: "."), conversation)

    assert_equal "Declined: Blocked by policy", result
  end

  def test_tool_registry_shell_hook_can_modify_command
    workspace = Object.new
    commands = []
    workspace.define_singleton_method(:root) { Dir.pwd }
    workspace.define_singleton_method(:run_shell_command) do |command, timeout_seconds:, **_kwargs|
      commands << [command, timeout_seconds]
      "ran #{command}"
    end
    manager = Kward::Hooks::Manager.new
    manager.register("shell_command_before") do |_event, _ctx|
      Kward::Hooks::Decision.modify(command: "echo modified", timeout_seconds: 77)
    end
    registry = Kward::ToolRegistry.new(workspace: workspace, hook_manager: manager)
    conversation = Kward::Conversation.new

    result = registry.dispatch(tool_call("run_shell_command", command: "echo original", timeout_seconds: 1), conversation)

    assert_equal "ran echo modified", result
    assert_equal [["echo modified", 77]], commands
  end

  def test_tool_registry_runs_file_change_before_hook
    Dir.mktmpdir do |workspace_dir|
      manager = Kward::Hooks::Manager.new
      events = []
      manager.register("file_change_before") do |event, _ctx|
        events << event.payload
        Kward::Hooks::Decision.allow
      end
      registry = Kward::ToolRegistry.new(workspace: Kward::Workspace.new(root: workspace_dir), hook_manager: manager)
      conversation = Kward::Conversation.new

      result = registry.dispatch(tool_call("write_file", path: "hello.txt", content: "hi\n"), conversation)

      assert_includes result, "Wrote"
      assert_equal "hello.txt", events.first[:path]
      assert_equal "write", events.first[:operation]
      assert_equal "hi\n", events.first[:content]
      assert_equal "hi\n", File.read(File.join(workspace_dir, "hello.txt"))
    end
  end

  def test_tool_registry_file_change_before_hook_can_deny_write
    Dir.mktmpdir do |workspace_dir|
      manager = Kward::Hooks::Manager.new
      manager.register("file_change_before") { Kward::Hooks::Decision.deny("No writes") }
      registry = Kward::ToolRegistry.new(workspace: Kward::Workspace.new(root: workspace_dir), hook_manager: manager)
      conversation = Kward::Conversation.new

      result = registry.dispatch(tool_call("write_file", path: "hello.txt", content: "hi\n"), conversation)

      assert_equal "Declined: No writes", result
      refute_path_exists File.join(workspace_dir, "hello.txt")
    end
  end

  def test_tool_registry_runs_file_change_after_hook
    Dir.mktmpdir do |workspace_dir|
      manager = Kward::Hooks::Manager.new
      events = []
      manager.register("file_change_after") do |event, _ctx|
        events << event.payload
        Kward::Hooks::Decision.allow
      end
      registry = Kward::ToolRegistry.new(workspace: Kward::Workspace.new(root: workspace_dir), hook_manager: manager)
      conversation = Kward::Conversation.new

      result = registry.dispatch(tool_call("write_file", path: "hello.txt", content: "hi\n"), conversation)

      assert_includes result, "Wrote"
      assert_equal "hello.txt", events.first[:path]
      assert_equal "write", events.first[:operation]
    end
  end

  def test_permission_policy_denies_a_tool_before_execution
    workspace = Kward::Workspace.new
    executed = false
    workspace.define_singleton_method(:run_shell_command) { |_command, **_kwargs| executed = true }
    policy = Kward::Permissions::Policy.new(enabled: true, mode: "read-only")
    registry = Kward::ToolRegistry.new(workspace: workspace, permission_policy: policy)

    result = registry.dispatch(tool_call("run_shell_command", command: "echo should-not-run"), Kward::Conversation.new)

    assert_equal "Declined: read-only mode: run_shell_command", result
    refute executed
  end

  def test_permission_policy_uses_existing_approval_callback
    approvals = []
    policy = Kward::Permissions::Policy.new(enabled: true)
    registry = Kward::ToolRegistry.new(
      permission_policy: policy,
      tool_approval: lambda { |tool_call:, name:, args:, cancellation:|
        approvals << [tool_call, name, args, cancellation]
        false
      }
    )

    result = registry.dispatch(tool_call("run_shell_command", command: "echo should-not-run"), Kward::Conversation.new)

    assert_equal "Declined: tool execution denied by user: run_shell_command", result
    assert_equal "run_shell_command", approvals.first[1]
  end

  def test_permission_policy_does_not_ask_for_allowed_read_tools
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "README.md"), "read me\n")
      policy = Kward::Permissions::Policy.new(enabled: true)
      registry = Kward::ToolRegistry.new(
        workspace: Kward::Workspace.new(root: dir),
        permission_policy: policy,
        tool_approval: ->(**_kwargs) { flunk "read tools should not request approval" }
      )

      result = registry.dispatch(tool_call("read_file", path: "README.md"), Kward::Conversation.new)

      assert_equal "read me\n", result
    end
  end

  def test_permission_policy_can_allow_a_tool_for_the_session
    calls = 0
    workspace = Kward::Workspace.new
    workspace.define_singleton_method(:run_shell_command) { |_command, **_kwargs| calls += 1; "ran" }
    policy = Kward::Permissions::Policy.new(enabled: true)
    registry = Kward::ToolRegistry.new(
      workspace: workspace,
      permission_policy: policy,
      tool_approval: ->(**_kwargs) { :allow_for_session }
    )
    conversation = Kward::Conversation.new

    assert_equal "ran", registry.dispatch(tool_call("run_shell_command", command: "echo first"), conversation)
    assert_equal "ran", registry.dispatch(tool_call("run_shell_command", command: "echo second"), conversation)
    assert_equal 2, calls
  end

  def test_permission_policy_fails_closed_without_an_approval_callback
    policy = Kward::Permissions::Policy.new(enabled: true)
    registry = Kward::ToolRegistry.new(permission_policy: policy)

    result = registry.dispatch(tool_call("run_shell_command", command: "echo should-not-run"), Kward::Conversation.new)

    assert_equal "Declined: tool execution denied by user: run_shell_command", result
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
