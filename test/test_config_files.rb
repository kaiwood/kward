require_relative "test_helper"

class TestConfigFiles < KwardTestCase
  def test_ensure_default_config_creates_runtime_defaults_with_active_kward_persona
    Dir.mktmpdir do |dir|
      config_path = File.join(dir, "config.json")

      created = Kward::ConfigFiles.ensure_default_config!(config_path)

      assert_equal true, created
      config = JSON.parse(File.read(config_path))
      assert_equal Kward::ConfigFiles.default_config, config
      personas = config.fetch("personas")
      assert_equal "kward", personas["default"]
      assert_equal ["characters", "default"], personas.keys
      assert_equal ["kward"], personas.fetch("characters").map { |entry| entry["key"] }
      assert_equal "Kward", personas.dig("characters", 0, "label")
      assert_includes personas.dig("characters", 0, "instruction"), "grim Andruid"
      assert_equal false, config.dig("memory", "enabled")
      assert_equal false, config.dig("memory", "auto_summary")
      assert_equal true, config.dig("composer", "busy_help")
      assert_equal "modern", config.dig("editor", "mode")
      assert_equal true, config.dig("editor", "auto_indent")
      assert_equal false, config.dig("sessions", "auto_resume")
      assert_equal false, config["enforce_workspace_agents_file"]
      assert_equal true, config.dig("tools", "workspace_guardrails")
      refute config.key?("provider")
      refute config.key?("model")
      refute config.key?("openai_model")
      refute config.key?("openai_reasoning_effort")
      refute config.key?("openrouter_model")
      refute config.key?("openrouter_reasoning_effort")
      refute config.key?("copilot_model")
      refute config.key?("copilot_reasoning_effort")
      refute config.key?("openai_oauth_client_id")
      refute config.key?("openrouter_api_key")
    end
  end

  def test_ensure_default_config_does_not_modify_existing_config
    Dir.mktmpdir do |dir|
      config_path = File.join(dir, "config.json")
      content = JSON.dump("openai_model" => "custom-model")
      File.write(config_path, content)

      created = Kward::ConfigFiles.ensure_default_config!(config_path)

      assert_equal false, created
      assert_equal content, File.read(config_path)
    end
  end

  def test_editor_mode_defaults_to_modern_and_accepts_emacs_and_vi
    assert_equal "modern", Kward::ConfigFiles.editor_mode({})
    assert_equal "modern", Kward::ConfigFiles.editor_mode("editor" => {})
    assert_equal "modern", Kward::ConfigFiles.editor_mode("editor" => { "mode" => "default" })
    assert_equal "modern", Kward::ConfigFiles.editor_mode("editor" => { "mode" => "modern" })
    assert_equal "modern", Kward::ConfigFiles.editor_mode("editor" => { "mode" => "NANO" })
    assert_equal "emacs", Kward::ConfigFiles.editor_mode("editor" => { "mode" => "emacs" })
    assert_equal "vi", Kward::ConfigFiles.editor_mode("editor" => { "mode" => "VI" })
    assert_equal "vi", Kward::ConfigFiles.editor_mode("editor" => { "mode" => "vi" })
    assert_equal "modern", Kward::ConfigFiles.editor_mode("editor" => { "mode" => "vim" })
  end

  def test_editor_auto_indent_defaults_to_true_and_only_false_disables_it
    assert_equal true, Kward::ConfigFiles.editor_auto_indent?({})
    assert_equal true, Kward::ConfigFiles.editor_auto_indent?("editor" => {})
    assert_equal true, Kward::ConfigFiles.editor_auto_indent?("editor" => { "auto_indent" => true })
    assert_equal false, Kward::ConfigFiles.editor_auto_indent?("editor" => { "auto_indent" => false })
  end

  def test_workspace_guardrails_enabled_defaults_to_true_and_only_false_disables_it
    assert_equal true, Kward::ConfigFiles.workspace_guardrails_enabled?({})
    assert_equal true, Kward::ConfigFiles.workspace_guardrails_enabled?("tools" => {})
    assert_equal true, Kward::ConfigFiles.workspace_guardrails_enabled?("tools" => { "workspace_guardrails" => true })
    assert_equal false, Kward::ConfigFiles.workspace_guardrails_enabled?("tools" => { "workspace_guardrails" => false })
  end

  def test_session_auto_resume_enabled_defaults_to_false_and_only_true_enables_it
    assert_equal false, Kward::ConfigFiles.session_auto_resume_enabled?({})
    assert_equal false, Kward::ConfigFiles.session_auto_resume_enabled?("sessions" => {})
    assert_equal true, Kward::ConfigFiles.session_auto_resume_enabled?("sessions" => { "auto_resume" => true })
    assert_equal false, Kward::ConfigFiles.session_auto_resume_enabled?("sessions" => { "auto_resume" => false })
  end

  def test_enforce_workspace_agents_file_defaults_to_false_and_only_true_enables_it
    assert_equal false, Kward::ConfigFiles.enforce_workspace_agents_file?({})
    assert_equal true, Kward::ConfigFiles.enforce_workspace_agents_file?("enforce_workspace_agents_file" => true)
    assert_equal false, Kward::ConfigFiles.enforce_workspace_agents_file?("enforce_workspace_agents_file" => false)
  end

  def test_web_search_config_accepts_current_key_only
    assert_equal({}, Kward::ConfigFiles.web_search_config({}))
    assert_equal({ "enabled" => false }, Kward::ConfigFiles.web_search_config("web_search" => { "enabled" => false }))
    assert_equal({}, Kward::ConfigFiles.web_search_config("webSearch" => { "provider" => "exa" }))
    assert_equal({}, Kward::ConfigFiles.web_search_config("web_research" => { "provider" => "old" }))
    assert_equal({}, Kward::ConfigFiles.web_search_config("webResearch" => { "provider" => "duckduckgo" }))
    assert_equal({}, Kward::ConfigFiles.web_search_config("web_search" => "nope"))
  end

  def test_cli_run_creates_default_config_without_onboarding_output
    Dir.mktmpdir do |dir|
      config_path = File.join(dir, "config.json")
      client = RecordingClient.new(["reply"])
      cli = Kward::CLI.new(argv: ["hello"], stdin: FakeInput.new("", tty: true), client: client)

      out, err = with_env("KWARD_CONFIG_PATH" => config_path) do
        capture_io { cli.run }
      end

      assert_equal "reply\n", out
      assert_equal "", err
      assert File.exist?(config_path)
      config = JSON.parse(File.read(config_path))
      assert_equal Kward::ConfigFiles.default_config, config
      assert_equal "kward", config.dig("personas", "default")
      assert_includes client.seen_messages.first.first[:content], "grim Andruid"
    end
  end
end
