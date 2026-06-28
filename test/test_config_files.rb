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
      assert_equal true, config.dig("editor", "auto_close_pairs")
      assert_equal true, config.dig("editor", "soft_wrap")
      assert_equal true, config.dig("editor", "bar_cursor")
      assert_equal "absolute", config.dig("editor", "line_numbers")
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

  def test_read_ekwsh_config_returns_empty_settings_when_missing
    Dir.mktmpdir do |dir|
      path = File.join(dir, "ekwsh.yml")

      assert_equal({
        shell: Kward::Ekwsh::DEFAULT_SHELL,
        timeout_seconds: Kward::Ekwsh::DEFAULT_TIMEOUT_SECONDS,
        max_output_bytes: Kward::Ekwsh::DEFAULT_MAX_OUTPUT_BYTES,
        history_limit: Kward::Ekwsh::DEFAULT_HISTORY_LIMIT,
        env: {},
        aliases: {}
      }, Kward::ConfigFiles.read_ekwsh_config(path))
    end
  end

  def test_read_ekwsh_config_reads_env_and_aliases
    Dir.mktmpdir do |dir|
      path = File.join(dir, "ekwsh.yml")
      File.write(path, <<~YAML)
        shell: /bin/sh
        timeout_seconds: 600
        max_output_bytes: 2097152
        history_limit: 2000
        env:
          FORCE_COLOR: 1
          BAD-NAME: ignored
          EMPTY:
        aliases:
          ll: ls -la
          gs: git status --short
          bad name: ignored
          pwd: ignored
          1bad: ignored
          empty:
      YAML

      config = Kward::ConfigFiles.read_ekwsh_config(path)

      assert_equal "/bin/sh", config[:shell]
      assert_equal 600, config[:timeout_seconds]
      assert_equal 2_097_152, config[:max_output_bytes]
      assert_equal 2_000, config[:history_limit]
      assert_equal({ "FORCE_COLOR" => "1" }, config[:env])
      assert_equal({ "ll" => "ls -la", "gs" => "git status --short" }, config[:aliases])
    end
  end

  def test_read_ekwsh_config_defaults_invalid_runtime_settings
    Dir.mktmpdir do |dir|
      path = File.join(dir, "ekwsh.yml")
      File.write(path, <<~YAML)
        shell: relative-shell
        timeout_seconds: 0
        max_output_bytes: nope
        history_limit: -5
      YAML

      config = Kward::ConfigFiles.read_ekwsh_config(path)

      assert_equal Kward::Ekwsh::DEFAULT_SHELL, config[:shell]
      assert_equal Kward::Ekwsh::DEFAULT_TIMEOUT_SECONDS, config[:timeout_seconds]
      assert_equal Kward::Ekwsh::DEFAULT_MAX_OUTPUT_BYTES, config[:max_output_bytes]
      assert_equal Kward::Ekwsh::DEFAULT_HISTORY_LIMIT, config[:history_limit]
    end
  end

  def test_update_nested_config_merges_one_level_section
    Dir.mktmpdir do |dir|
      path = File.join(dir, "config.json")
      Kward::ConfigFiles.write_config({ "editor" => { "mode" => "vibe", "soft_wrap" => true } }, path)

      config = Kward::ConfigFiles.update_nested_config("editor", { line_numbers: "relative", "soft_wrap" => false }, path)

      assert_equal({ "mode" => "vibe", "soft_wrap" => false, "line_numbers" => "relative" }, config["editor"])
      assert_equal config, Kward::ConfigFiles.read_config(path)
    end
  end

  def test_editor_mode_defaults_to_modern_and_accepts_emacs_and_vibe
    assert_equal "modern", Kward::ConfigFiles.editor_mode({})
    assert_equal "modern", Kward::ConfigFiles.editor_mode("editor" => {})
    assert_equal "modern", Kward::ConfigFiles.editor_mode("editor" => { "mode" => "default" })
    assert_equal "modern", Kward::ConfigFiles.editor_mode("editor" => { "mode" => "modern" })
    assert_equal "modern", Kward::ConfigFiles.editor_mode("editor" => { "mode" => "NANO" })
    assert_equal "emacs", Kward::ConfigFiles.editor_mode("editor" => { "mode" => "emacs" })
    assert_equal "vibe", Kward::ConfigFiles.editor_mode("editor" => { "mode" => "VI" })
    assert_equal "vibe", Kward::ConfigFiles.editor_mode("editor" => { "mode" => "vibe" })
    assert_equal "modern", Kward::ConfigFiles.editor_mode("editor" => { "mode" => "vim" })
  end

  def test_editor_auto_indent_defaults_to_true_and_only_false_disables_it
    assert_equal true, Kward::ConfigFiles.editor_auto_indent?({})
    assert_equal true, Kward::ConfigFiles.editor_auto_indent?("editor" => {})
    assert_equal true, Kward::ConfigFiles.editor_auto_indent?("editor" => { "auto_indent" => true })
    assert_equal false, Kward::ConfigFiles.editor_auto_indent?("editor" => { "auto_indent" => false })
  end

  def test_editor_auto_close_pairs_defaults_to_true_and_only_false_disables_it
    assert_equal true, Kward::ConfigFiles.editor_auto_close_pairs?({})
    assert_equal true, Kward::ConfigFiles.editor_auto_close_pairs?("editor" => {})
    assert_equal true, Kward::ConfigFiles.editor_auto_close_pairs?("editor" => { "auto_close_pairs" => true })
    assert_equal false, Kward::ConfigFiles.editor_auto_close_pairs?("editor" => { "auto_close_pairs" => false })
  end

  def test_editor_soft_wrap_defaults_to_true_and_only_false_disables_it
    assert_equal true, Kward::ConfigFiles.editor_soft_wrap?({})
    assert_equal true, Kward::ConfigFiles.editor_soft_wrap?("editor" => {})
    assert_equal true, Kward::ConfigFiles.editor_soft_wrap?("editor" => { "soft_wrap" => true })
    assert_equal false, Kward::ConfigFiles.editor_soft_wrap?("editor" => { "soft_wrap" => false })
  end

  def test_editor_bar_cursor_defaults_to_true_and_only_false_disables_it
    assert_equal true, Kward::ConfigFiles.editor_bar_cursor?({})
    assert_equal true, Kward::ConfigFiles.editor_bar_cursor?("editor" => {})
    assert_equal true, Kward::ConfigFiles.editor_bar_cursor?("editor" => { "bar_cursor" => true })
    assert_equal false, Kward::ConfigFiles.editor_bar_cursor?("editor" => { "bar_cursor" => false })
  end

  def test_editor_line_numbers_defaults_to_absolute_and_accepts_relative
    assert_equal "absolute", Kward::ConfigFiles.editor_line_numbers({})
    assert_equal "absolute", Kward::ConfigFiles.editor_line_numbers("editor" => {})
    assert_equal "absolute", Kward::ConfigFiles.editor_line_numbers("editor" => { "line_numbers" => "absolute" })
    assert_equal "relative", Kward::ConfigFiles.editor_line_numbers("editor" => { "line_numbers" => "relative" })
    assert_equal "relative", Kward::ConfigFiles.editor_line_numbers("editor" => { "line_numbers" => "RELATIVE" })
    assert_equal "absolute", Kward::ConfigFiles.editor_line_numbers("editor" => { "line_numbers" => "hybrid" })
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
