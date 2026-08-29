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
      assert_equal({}, config.dig("editor", "agent"))
      assert_equal({}, config.dig("editor", "runners"))
      assert_equal true, config.dig("editor", "auto_indent")
      assert_equal true, config.dig("editor", "auto_close_pairs")
      assert_equal true, config.dig("editor", "soft_wrap")
      assert_equal true, config.dig("editor", "bar_cursor")
      assert_equal "absolute", config.dig("editor", "line_numbers")
      assert_equal "auto", config.dig("editor", "diff_view")
      assert_equal "center", config.dig("overlay", "alignment")
      assert_equal "maximum", config.dig("overlay", "width")
      assert_equal "off", config.dig("project_browser", "icons")
      assert_equal true, config.dig("web_search", "enabled")
      assert_equal "auto", config.dig("web_search", "provider")
      assert_equal false, config.dig("web_search", "allow_model_providers")
      assert_equal true, config.dig("updates", "check")
      assert_equal false, config.dig("sessions", "auto_resume")
      assert_equal false, config.dig("skills", "trust_project")
      assert_equal false, config["enforce_workspace_agents_file"]
      assert_equal true, config.dig("tools", "workspace_guardrails")
      assert_equal false, config.dig("permissions", "enabled")
      assert_equal "ask", config.dig("permissions", "mode")
      assert_equal "off", config.dig("sandbox", "mode")
      assert_equal "deny", config.dig("sandbox", "network")
      assert_equal [], config.dig("sandbox", "writable_roots")
      assert_equal true, config.dig("sandbox", "protect_git_metadata")
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

  def test_editor_runners_are_optional_and_nested_under_editor
    config = {
      "editor" => {
        "runners" => {
          "node" => { "binary" => "/opt/node/bin/node" },
          "python" => { "binary" => ".venv/bin/python" }
        }
      }
    }

    assert_equal config["editor"]["runners"], Kward::ConfigFiles.editor_runners(config)
    assert_equal({}, Kward::ConfigFiles.editor_runners({}))
    assert_equal({}, Kward::ConfigFiles.editor_runners("editor" => { "runners" => [] }))
  end

  def test_editor_agent_settings_are_optional_and_trimmed
    config = {
      "editor" => {
        "agent" => {
          "provider" => "  anthropic  ",
          "model" => "  gpt-editor  ",
          "reasoning_effort" => " medium "
        }
      }
    }

    with_env("KWARD_EDITOR_PROVIDER" => nil) do
      assert_equal "anthropic", Kward::ConfigFiles.editor_agent_provider(config)
      assert_equal "gpt-editor", Kward::ConfigFiles.editor_agent_model(config)
      assert_equal "medium", Kward::ConfigFiles.editor_agent_reasoning_effort(config)
    end
    with_env("KWARD_EDITOR_PROVIDER" => " openrouter ") do
      assert_equal "openrouter", Kward::ConfigFiles.editor_agent_provider(config)
    end
    assert_nil Kward::ConfigFiles.editor_agent_provider({})
    assert_nil Kward::ConfigFiles.editor_agent_model({})
    assert_nil Kward::ConfigFiles.editor_agent_reasoning_effort({ "editor" => { "agent" => {} } })
  end

  def test_shell_agent_settings_prefer_environment_over_main_config
    config = {
      "shell" => {
        "agent" => {
          "provider" => "  anthropic  ",
          "model" => "  config-model  ",
          "reasoning_effort" => " medium "
        }
      }
    }

    with_env("KWSH_PROVIDER" => nil, "KWSH_MODE" => nil, "KWSH_REASONING" => nil) do
      assert_equal "anthropic", Kward::ConfigFiles.shell_agent_provider(config)
      assert_equal "config-model", Kward::ConfigFiles.shell_agent_model(config)
      assert_equal "medium", Kward::ConfigFiles.shell_agent_reasoning_effort(config)
    end

    with_env("KWSH_PROVIDER" => " openrouter ", "KWSH_MODE" => " env-model ", "KWSH_REASONING" => " none ") do
      assert_equal "openrouter", Kward::ConfigFiles.shell_agent_provider(config)
      assert_equal "env-model", Kward::ConfigFiles.shell_agent_model(config)
      assert_equal "none", Kward::ConfigFiles.shell_agent_reasoning_effort(config)
    end

    with_env("KWSH_MODE" => nil, "KWSH_REASONING" => nil) do
      assert_equal "config-model", Kward::ConfigFiles.shell_agent_model(config)
      assert_equal "medium", Kward::ConfigFiles.shell_agent_reasoning_effort(config)
    end

    with_env("KWSH_MODE" => " env-model ", "KWSH_REASONING" => " none ") do
      assert_equal "env-model", Kward::ConfigFiles.shell_agent_model(config)
      assert_equal "none", Kward::ConfigFiles.shell_agent_reasoning_effort(config)
    end

    with_env("KWSH_MODE" => nil, "KWSH_REASONING" => nil) do
      assert_nil Kward::ConfigFiles.shell_agent_model({})
      assert_nil Kward::ConfigFiles.shell_agent_reasoning_effort({ "shell" => { "agent" => {} } })
    end
  end

  def test_sandbox_policy_uses_only_global_configured_roots
    Dir.mktmpdir do |dir|
      workspace = File.join(dir, "workspace")
      extra_root = File.join(dir, "extra")
      FileUtils.mkdir_p([workspace, extra_root])
      config = {
        "sandbox" => {
          "mode" => "workspace_write",
          "network" => "allow",
          "writable_roots" => [extra_root],
          "protect_git_metadata" => false
        }
      }

      policy = Kward::ConfigFiles.sandbox_policy(workspace, config)

      assert_equal "workspace_write", policy.mode
      assert_equal "allow", policy.network
      assert_equal [File.realpath(workspace), File.realpath(extra_root)], policy.command_writable_roots
      refute policy.protect_git_metadata?
    end
  end

  def test_transport_config_is_scoped_and_copied
    config = { "transports" => { "com.example.test" => { "token" => "secret" } } }

    values = Kward::ConfigFiles.transport_config("com.example.test", config)
    values["token"] = "changed"

    assert_equal({ "token" => "secret" }, Kward::ConfigFiles.transport_config("com.example.test", config))
    assert_equal({}, Kward::ConfigFiles.transport_config("missing", config))
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

  def test_read_config_raises_structured_error_for_invalid_json
    Dir.mktmpdir do |dir|
      config_path = File.join(dir, "config.json")
      File.write(config_path, "{\n  \"model\": \"gpt-5\"\n  \"provider\": \"openai\"\n}")

      error = assert_raises(Kward::ConfigFiles::ConfigError) do
        Kward::ConfigFiles.read_config(config_path)
      end

      assert_equal config_path, error.path
      assert_equal "JSON", error.format
      assert_includes error.detail, "line"
      assert_includes error.message, config_path
    end
  end

  def test_read_config_rejects_valid_json_that_is_not_an_object
    Dir.mktmpdir do |dir|
      config_path = File.join(dir, "config.json")
      File.write(config_path, "[]")

      error = assert_raises(Kward::ConfigFiles::ConfigError) do
        Kward::ConfigFiles.read_config(config_path)
      end

      assert_equal config_path, error.path
      assert_equal "JSON", error.format
      assert_equal "top-level value must be an object", error.detail
    end
  end

  def test_skip_config_ignores_main_config_reads_and_writes
    Dir.mktmpdir do |dir|
      config_path = File.join(dir, "config.json")
      File.write(config_path, "{\n  \"model\": \"gpt-5\"\n  \"provider\": \"openai\"\n}")

      with_env("KWARD_CONFIG_PATH" => config_path) do
        Kward::ConfigFiles.skip_config = true

        assert_equal({}, Kward::ConfigFiles.read_config)
        assert_equal false, Kward::ConfigFiles.ensure_default_config!
        error = assert_raises(RuntimeError) do
          Kward::ConfigFiles.write_config({ "model" => "changed" })
        end
        assert_includes error.message, "--skip-config"
        assert_includes File.read(config_path), "gpt-5"
      ensure
        Kward::ConfigFiles.skip_config = false
      end
    end
  end

  def test_workspace_hooks_are_loaded_only_when_trusted
    Dir.mktmpdir do |dir|
      config_path = File.join(dir, "config.json")
      workspace = File.join(dir, "workspace")
      FileUtils.mkdir_p(File.join(workspace, ".kward"))
      File.write(config_path, JSON.dump("hooks" => { "turn_end" => [{ "id" => "user-hook", "command" => "echo user" }] }))
      File.write(File.join(workspace, ".kward", "hooks.json"), JSON.dump("hooks" => { "turn_end" => [{ "id" => "workspace-hook", "command" => "echo workspace" }] }))

      with_env("KWARD_CONFIG_PATH" => config_path) do
        untrusted = Kward::ConfigFiles.lifecycle_hooks_config(workspace)
        assert_equal ["user-hook"], untrusted.dig("hooks", "turn_end").map { |entry| entry["id"] }

        Kward::ConfigFiles.trust_workspace_hooks!(workspace)
        trusted = Kward::ConfigFiles.lifecycle_hooks_config(workspace)
        assert_equal ["user-hook", "workspace-hook"], trusted.dig("hooks", "turn_end").map { |entry| entry["id"] }

        File.write(File.join(workspace, ".kward", "hooks.json"), JSON.dump("hooks" => { "turn_end" => [{ "id" => "changed", "command" => "echo changed" }] }))
        invalidated = Kward::ConfigFiles.lifecycle_hooks_config(workspace)
        assert_equal ["user-hook"], invalidated.dig("hooks", "turn_end").map { |entry| entry["id"] }
      end
    end
  end

  def test_read_kwsh_config_returns_defaults_when_rc_files_are_missing
    Dir.mktmpdir do |home|
      with_env("HOME" => home, "KWARD_CONFIG_PATH" => nil) do
        assert_equal({
          shell: Kward::Kwsh::DEFAULT_SHELL,
          timeout_seconds: Kward::Kwsh::DEFAULT_TIMEOUT_SECONDS,
          max_output_bytes: Kward::Kwsh::DEFAULT_MAX_OUTPUT_BYTES,
          history_limit: Kward::Kwsh::DEFAULT_HISTORY_LIMIT,
          env: {},
          aliases: {}
        }, Kward::ConfigFiles.read_kwsh_config)
      end
    end
  end

  def test_read_kwsh_config_loads_kwshrc_files_in_order_and_sources_declarative_directives
    Dir.mktmpdir do |home|
      config_dir = File.join(home, ".kward")
      FileUtils.mkdir_p(config_dir)
      source_path = File.join(config_dir, "aliases.kwshrc")
      File.write(File.join(config_dir, "kwshrc"), <<~KWSHRC)
        export KWARD_KWSH_CONFIG_TEST=first
        alias ll='ls -la'
        source aliases.kwshrc
      KWSHRC
      File.write(source_path, <<~KWSHRC)
        export KWARD_KWSH_SOURCE_TEST="$KWARD_KWSH_CONFIG_TEST/source"
        alias gs='git status --short'
      KWSHRC
      File.write(File.join(home, ".kwshrc"), <<~KWSHRC)
        export KWARD_KWSH_CONFIG_TEST=second
        export KWARD_KWSH_LITERAL='$KWARD_KWSH_CONFIG_TEST'
        alias ll="ls -l"
      KWSHRC

      with_env("HOME" => home, "KWARD_CONFIG_PATH" => nil) do
        config = Kward::ConfigFiles.read_kwsh_config

        assert_equal [File.join(config_dir, "kwshrc"), File.join(home, ".kwshrc")], Kward::ConfigFiles.kwshrc_paths
        assert_equal "second", config[:env]["KWARD_KWSH_CONFIG_TEST"]
        assert_equal "first/source", config[:env]["KWARD_KWSH_SOURCE_TEST"]
        assert_equal "$KWARD_KWSH_CONFIG_TEST", config[:env]["KWARD_KWSH_LITERAL"]
        assert_equal({ "ll" => "ls -l", "gs" => "git status --short" }, config[:aliases])
      end
    end
  end

  def test_read_kwsh_config_ignores_unsupported_kwshrc_scripting
    Dir.mktmpdir do |home|
      config_dir = File.join(home, ".kward")
      FileUtils.mkdir_p(config_dir)
      marker = File.join(home, "should-not-exist")
      File.write(File.join(config_dir, "kwshrc"), <<~KWSHRC)
        if true; then
          touch #{marker}
        fi
        export KWARD_KWSH_SUPPORTED=yes
      KWSHRC

      with_env("HOME" => home, "KWARD_CONFIG_PATH" => nil) do
        config = Kward::ConfigFiles.read_kwsh_config

        assert_equal "yes", config[:env]["KWARD_KWSH_SUPPORTED"]
        refute File.exist?(marker)
      end
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

  def test_project_browser_icon_theme_defaults_to_off_and_accepts_nerd_font
    assert_equal "off", Kward::ConfigFiles.project_browser_icon_theme({})
    assert_equal "off", Kward::ConfigFiles.project_browser_icon_theme("project_browser" => {})
    assert_equal "off", Kward::ConfigFiles.project_browser_icon_theme("project_browser" => { "icons" => "emoji" })
    assert_equal "nerd-font", Kward::ConfigFiles.project_browser_icon_theme("project_browser" => { "icons" => "nerd-font" })
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

  def test_diff_view_defaults_to_auto_and_accepts_unified_and_side_by_side
    assert_equal "auto", Kward::ConfigFiles.diff_view({})
    assert_equal "auto", Kward::ConfigFiles.diff_view("editor" => {})
    assert_equal "auto", Kward::ConfigFiles.diff_view("editor" => { "diff_view" => "auto" })
    assert_equal "unified", Kward::ConfigFiles.diff_view("editor" => { "diff_view" => "unified" })
    assert_equal "side_by_side", Kward::ConfigFiles.diff_view("editor" => { "diff_view" => "side-by-side" })
    assert_equal "side_by_side", Kward::ConfigFiles.diff_view("editor" => { "diff_view" => "SIDE_BY_SIDE" })
    assert_equal "auto", Kward::ConfigFiles.diff_view("editor" => { "diff_view" => "wide" })
  end

  def test_workspace_guardrails_enabled_defaults_to_true_and_only_false_disables_it
    assert_equal true, Kward::ConfigFiles.workspace_guardrails_enabled?({})
    assert_equal true, Kward::ConfigFiles.workspace_guardrails_enabled?("tools" => {})
    assert_equal true, Kward::ConfigFiles.workspace_guardrails_enabled?("tools" => { "workspace_guardrails" => true })
    assert_equal false, Kward::ConfigFiles.workspace_guardrails_enabled?("tools" => { "workspace_guardrails" => false })
  end

  def test_project_skills_trusted_defaults_to_false_and_only_true_enables_it
    assert_equal false, Kward::ConfigFiles.project_skills_trusted?({})
    assert_equal false, Kward::ConfigFiles.project_skills_trusted?("skills" => {})
    assert_equal true, Kward::ConfigFiles.project_skills_trusted?("skills" => { "trust_project" => true })
    assert_equal false, Kward::ConfigFiles.project_skills_trusted?("skills" => { "trust_project" => false })
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
