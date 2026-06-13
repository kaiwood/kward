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

  def test_banner_enabled_defaults_to_true_and_only_false_disables_it
    assert_equal true, Kward::ConfigFiles.banner_enabled?({})
    assert_equal true, Kward::ConfigFiles.banner_enabled?("banner" => {})
    assert_equal true, Kward::ConfigFiles.banner_enabled?("banner" => { "enabled" => true })
    assert_equal false, Kward::ConfigFiles.banner_enabled?("banner" => { "enabled" => false })
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
