require_relative "test_helper"

class TestCLISettings < KwardTestCase
  def test_settings_slash_command_reports_unavailable_without_tui_prompt
    prompt = FakePrompt.new(["/settings", "/exit"])
    client = RecordingClient.new([])
    agent = Kward::Agent.new(client: client, tool_registry: Kward::ToolRegistry.new(prompt: prompt))
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client)

    cli.interactive_loop(agent: agent)

    assert_includes prompt.output.join("\n"), "Settings overlay is unavailable"
    assert_empty client.seen_messages
  end

  def test_model_slash_command_reports_unavailable_without_tui_prompt
    prompt = FakePrompt.new(["/model", "/exit"])
    client = RecordingClient.new([])
    agent = Kward::Agent.new(client: client, tool_registry: Kward::ToolRegistry.new(prompt: prompt))
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client)

    cli.interactive_loop(agent: agent)

    assert_includes prompt.output.join("\n"), "Model overlay is unavailable"
    assert_empty client.seen_messages
  end

  def test_model_slash_command_persists_custom_model_and_reloads_config
    Dir.mktmpdir do |dir|
      config_path = File.join(dir, "config.json")
      File.write(config_path, JSON.dump({ "openai_model" => "existing" }))
      prompt = FakeSettingsPrompt.new(["/model", "/exit"], ["custom-model"])
      client = FakeClient.new([])
      client.provider = "Codex"
      client.model = "existing"
      agent = Kward::Agent.new(client: client, tool_registry: Kward::ToolRegistry.new(prompt: prompt))
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client)

      with_env("KWARD_CONFIG_PATH" => config_path) do
        cli.interactive_loop(agent: agent)
      end

      config = JSON.parse(File.read(config_path))
      assert_equal "custom-model", config["openai_model"]
      assert_equal "codex", config["provider"]
      assert_equal 1, client.reload_count
      assert_equal ["Default model"], prompt.select_messages
      assert_equal ["Models"], prompt.select_titles
      assert_includes prompt.select_choices.first, "Codex existing (current)"
      assert_empty prompt.output
      assert_equal 1, prompt.redraw_count
    end
  end

  def test_model_slash_command_persists_selected_provider_model
    Dir.mktmpdir do |dir|
      config_path = File.join(dir, "config.json")
      prompt = FakeSettingsPrompt.new(["/model", "/exit"], ["OpenRouter openai/gpt-5.5"])
      client = FakeClient.new([])
      client.provider = "Codex"
      client.model = "gpt-5.5"
      def client.available_models
        [
          { provider: "Codex", id: "gpt-5.5", current: true },
          { provider: "OpenRouter", id: "openai/gpt-5.5", current: false }
        ]
      end
      agent = Kward::Agent.new(client: client, tool_registry: Kward::ToolRegistry.new(prompt: prompt))
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client)

      with_env("KWARD_CONFIG_PATH" => config_path) do
        cli.interactive_loop(agent: agent)
      end

      config = JSON.parse(File.read(config_path))
      assert_equal "openai/gpt-5.5", config["openrouter_model"]
      assert_equal "openrouter", config["provider"]
      assert_equal 1, client.reload_count
    end
  end

  def test_model_slash_command_switches_to_selected_copilot_provider_model
    Dir.mktmpdir do |dir|
      config_path = File.join(dir, "config.json")
      File.write(config_path, JSON.dump("openai_model" => "gpt-5.5"))
      prompt = FakeSettingsPrompt.new(["/model", "/exit"], ["Copilot gemini-2.5-pro"])
      client = Kward::Client.new(api_key: nil, openai_access_token: "openai-token", oauth: FakeOAuth.new(nil), github_oauth: FakeGithubOAuth.new("github-token"), config_path: config_path)
      agent = Kward::Agent.new(client: client, tool_registry: Kward::ToolRegistry.new(prompt: prompt))
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client)
      cli.instance_variable_set(:@working_directory, dir)

      with_env("KWARD_CONFIG_PATH" => config_path, "KWARD_PROVIDER" => nil, "COPILOT_MODEL" => nil) do
        cli.interactive_loop(agent: agent)
      end

      config = JSON.parse(File.read(config_path))
      assert_equal "gemini-2.5-pro", config["copilot_model"]
      assert_equal "copilot", config["provider"]
      assert_equal "Copilot gemini-2.5-pro · n/a", cli.send(:composer_status_text)
    end
  end

  def test_model_slash_command_switches_back_from_copilot_to_codex
    Dir.mktmpdir do |dir|
      config_path = File.join(dir, "config.json")
      File.write(config_path, JSON.dump("provider" => "copilot", "copilot_model" => "gemini-2.5-pro"))
      prompt = FakeSettingsPrompt.new(["/model", "/exit"], ["Codex gpt-5.5"])
      client = Kward::Client.new(api_key: nil, openai_access_token: "openai-token", oauth: FakeOAuth.new(nil), github_oauth: FakeGithubOAuth.new("github-token"), config_path: config_path)
      agent = Kward::Agent.new(client: client, tool_registry: Kward::ToolRegistry.new(prompt: prompt))
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client)
      cli.instance_variable_set(:@working_directory, dir)

      with_env("KWARD_CONFIG_PATH" => config_path, "KWARD_PROVIDER" => nil, "OPENAI_MODEL" => nil) do
        cli.interactive_loop(agent: agent)
      end

      config = JSON.parse(File.read(config_path))
      assert_equal "gpt-5.5", config["openai_model"]
      assert_equal "codex", config["provider"]
      assert_equal "Codex gpt-5.5 · medium", cli.send(:composer_status_text)
    end
  end

  def test_model_slash_command_refreshes_active_conversation_persona_and_session_runtime
    Dir.mktmpdir do |dir|
      config_path = File.join(dir, "config.json")
      File.write(config_path, JSON.dump(
        "openai_model" => "gpt-5.3-codex-spark",
        "personas" => {
          "models" => {
            "gpt-5.3-codex-spark" => "Your name is Commander Spark.",
            "gpt-5.5" => "Your name is Commander K'warD."
          }
        }
      ))
      workspace_dir = File.join(dir, "workspace")
      FileUtils.mkdir_p(workspace_dir)
      store = Kward::SessionStore.new(config_dir: dir, cwd: workspace_dir)
      prompt = FakeSettingsPrompt.new(["/name keep", "/model", "/exit"], ["gpt-5.5"])
      client = FakeClient.new([])
      client.model = "gpt-5.3-codex-spark"
      client.instance_variable_set(:@config_path, config_path)
      def client.reload_config
        @reload_count += 1
        @model = JSON.parse(File.read(@config_path))["openai_model"]
      end
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client, session_store: store)

      conversation = with_env("KWARD_CONFIG_PATH" => config_path) do
        cli.interactive_loop
      end

      assert_equal "gpt-5.5", conversation.model
      assert_includes conversation.system_message[:content], "Commander K'warD"
      refute_includes conversation.system_message[:content], "Commander Spark"

      session_path = Dir.glob(File.join(store.session_dir, "*.jsonl")).first
      _session, restored = with_env("KWARD_CONFIG_PATH" => config_path) do
        store.load(session_path, workspace: Kward::Workspace.new(root: workspace_dir), model: "fallback", reasoning_effort: "fallback")
      end
      assert_equal "gpt-5.3-codex-spark", restored.model
      assert_includes restored.system_message[:content], "Commander Spark"
      refute_includes restored.system_message[:content], "Commander K'warD"
    end
  end

  def test_model_and_reasoning_pickers_mark_resumed_session_runtime_current
    client = FakeClient.new([])
    client.provider = "Codex"
    client.model = "gpt-5.5"
    client.reasoning_effort = "medium"
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), client: client)
    conversation = Kward::Conversation.new(system_message: nil, provider: "Codex", model: "gpt-5.5", reasoning_effort: "low")
    cli.instance_variable_set(:@footer_conversation, conversation)

    models = cli.send(:normalized_available_models, conversation)

    assert_equal ["Codex gpt-5.5 (current)"], cli.send(:model_choices, models, conversation)
    assert_includes cli.send(:reasoning_choices, Kward::ModelInfo.reasoning_effort_choices("Codex", "gpt-5.5"), conversation), "Low (current)"
    refute_includes cli.send(:reasoning_choices, Kward::ModelInfo.reasoning_effort_choices("Codex", "gpt-5.5"), conversation), "Medium (current)"
  end

  def test_reasoning_slash_command_persists_effort_and_reloads_config
    Dir.mktmpdir do |dir|
      config_path = File.join(dir, "config.json")
      prompt = FakeSettingsPrompt.new(["/reasoning", "/exit"], ["Extra High"])
      client = FakeClient.new([])
      client.reasoning_effort = "medium"
      agent = Kward::Agent.new(client: client, tool_registry: Kward::ToolRegistry.new(prompt: prompt))
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client)

      with_env("KWARD_CONFIG_PATH" => config_path) do
        cli.interactive_loop(agent: agent)
      end

      config = JSON.parse(File.read(config_path))
      assert_equal "xhigh", config["openai_reasoning_effort"]
      assert_equal 1, client.reload_count
      assert_equal ["Reasoning effort"], prompt.select_messages
      assert_equal ["Reasoning"], prompt.select_titles
      assert_equal ["None", "Low", "Medium (current)", "High", "Extra High"], prompt.select_choices.first
      assert_empty prompt.output
      assert_equal 1, prompt.redraw_count
    end
  end

  def test_reasoning_slash_command_persists_openrouter_effort_for_openrouter_provider
    Dir.mktmpdir do |dir|
      config_path = File.join(dir, "config.json")
      File.write(config_path, JSON.dump("provider" => "openrouter"))
      prompt = FakeSettingsPrompt.new(["/reasoning", "/exit"], ["High"])
      client = FakeClient.new([])
      client.provider = "OpenRouter"
      client.reasoning_effort = "medium"
      agent = Kward::Agent.new(client: client, tool_registry: Kward::ToolRegistry.new(prompt: prompt))
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client)

      with_env("KWARD_CONFIG_PATH" => config_path) do
        cli.interactive_loop(agent: agent)
      end

      config = JSON.parse(File.read(config_path))
      assert_equal "high", config["openrouter_reasoning_effort"]
      refute config.key?("openai_reasoning_effort")
    end
  end

  def test_reasoning_slash_command_persists_copilot_effort_for_copilot_provider
    Dir.mktmpdir do |dir|
      config_path = File.join(dir, "config.json")
      File.write(config_path, JSON.dump("provider" => "copilot", "openai_reasoning_effort" => "low"))
      prompt = FakeSettingsPrompt.new(["/reasoning", "/exit"], ["High"])
      client = FakeClient.new([])
      client.provider = "Copilot"
      client.model = "gpt-5-mini"
      client.reasoning_effort = "medium"
      agent = Kward::Agent.new(client: client, tool_registry: Kward::ToolRegistry.new(prompt: prompt))
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client)

      with_env("KWARD_CONFIG_PATH" => config_path) do
        cli.interactive_loop(agent: agent)
      end

      config = JSON.parse(File.read(config_path))
      assert_equal "high", config["copilot_reasoning_effort"]
      assert_equal "low", config["openai_reasoning_effort"]
    end
  end

  def test_settings_slash_command_persists_overlay_settings
    Dir.mktmpdir do |dir|
      config_path = File.join(dir, "config.json")
      File.write(config_path, JSON.dump({ "openai_model" => "existing" }))
      prompt = FakeSettingsPrompt.new(
        ["/settings", "/exit"],
        ["Interface", "Overlay alignment", "Right", "Interface", "Overlay width", "Maximum", "Done"]
      )
      client = RecordingClient.new([])
      agent = Kward::Agent.new(client: client, tool_registry: Kward::ToolRegistry.new(prompt: prompt))
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client)

      with_env("KWARD_CONFIG_PATH" => config_path) do
        cli.interactive_loop(agent: agent)
      end

      config = JSON.parse(File.read(config_path))
      assert_equal "existing", config["openai_model"]
      assert_equal({ "alignment" => "right", "width" => "maximum" }, config["overlay"])
      assert_equal [{ "alignment" => "right", "width" => "maximum" }, { "alignment" => "right", "width" => "maximum" }], prompt.overlay_settings_updates
      assert_equal ["Settings category", "Interface", "Overlay alignment", "Settings category", "Interface", "Overlay width", "Settings category"], prompt.select_messages
      assert_equal ["Settings", "Settings", "Settings", "Settings", "Settings", "Settings", "Settings"], prompt.select_titles
    end
  end

  def test_settings_slash_command_toggles_memory_web_search_compaction_and_logging
    Dir.mktmpdir do |dir|
      config_path = File.join(dir, "config.json")
      File.write(config_path, JSON.dump({}))
      prompt = FakeSettingsPrompt.new(
        ["/settings", "/exit"],
        [
          "Memory", "Enable memory",
          "Tools & Search", "Disable web search",
          "Context & Compaction", "Disable auto-compaction",
          "Logging", "Enable local logging",
          "Done"
        ]
      )
      client = RecordingClient.new([])
      agent = Kward::Agent.new(client: client, tool_registry: Kward::ToolRegistry.new(prompt: prompt))
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client)

      with_env("KWARD_CONFIG_PATH" => config_path) do
        cli.interactive_loop(agent: agent)
      end

      config = JSON.parse(File.read(config_path))
      assert_equal true, config.dig("memory", "enabled")
      assert_equal false, config.dig("web_search", "enabled")
      assert_equal false, config.dig("compaction", "enabled")
      assert_equal true, config.dig("logging", "enabled")
    end
  end

  def test_settings_slash_command_updates_web_search_provider
    Dir.mktmpdir do |dir|
      config_path = File.join(dir, "config.json")
      prompt = FakeSettingsPrompt.new(["/settings", "/exit"], ["Tools & Search", "Web search provider", "duckduckgo", "Done"])
      client = RecordingClient.new([])
      agent = Kward::Agent.new(client: client, tool_registry: Kward::ToolRegistry.new(prompt: prompt))
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client)

      with_env("KWARD_CONFIG_PATH" => config_path) do
        cli.interactive_loop(agent: agent)
      end

      config = JSON.parse(File.read(config_path))
      assert_equal "duckduckgo", config.dig("web_search", "provider")
      assert_includes prompt.select_choices.find { |choices| choices.include?("duckduckgo") }, "duckduckgo"
    end
  end

  def test_settings_slash_command_updates_provider_and_reloads_runtime
    Dir.mktmpdir do |dir|
      config_path = File.join(dir, "config.json")
      prompt = FakeSettingsPrompt.new(["/settings", "/exit"], ["Model & Reasoning", "Provider", "OpenRouter", "Done"])
      client = FakeClient.new([])
      client.provider = "Codex"
      agent = Kward::Agent.new(client: client, tool_registry: Kward::ToolRegistry.new(prompt: prompt))
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client)

      with_env("KWARD_CONFIG_PATH" => config_path) do
        cli.interactive_loop(agent: agent)
      end

      config = JSON.parse(File.read(config_path))
      assert_equal "openrouter", config["provider"]
      assert_equal 1, client.reload_count
      assert_equal 1, prompt.redraw_count
    end
  end

end
