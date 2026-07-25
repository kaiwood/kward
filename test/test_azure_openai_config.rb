require_relative "test_helper"
require_relative "../lib/kward/model/azure_openai_config"

class TestAzureOpenAIConfig < KwardTestCase
  def test_normalizes_and_serializes_valid_setup
    setup = Kward::AzureOpenAIConfig.new(
      endpoint: " https://example.openai.azure.com/// ",
      deployment: "production-gpt-5",
      api_version: "2025-04-01-preview"
    )

    assert_equal "https://example.openai.azure.com", setup.endpoint
    assert_equal "production-gpt-5", setup.deployment
    assert_equal "2025-04-01-preview", setup.api_version
    assert_equal({
      "azure_openai_endpoint" => "https://example.openai.azure.com",
      "azure_openai_model" => "production-gpt-5",
      "azure_openai_api_version" => "2025-04-01-preview"
    }, setup.to_config)
  end

  def test_rejects_unsafe_or_invalid_endpoints
    [
      "",
      "http://example.openai.azure.com",
      "https://user:password@example.openai.azure.com",
      "https://example.openai.azure.com?api-key=secret",
      "https://example.openai.azure.com#fragment",
      "not a URL"
    ].each do |endpoint|
      assert_raises(ArgumentError, endpoint.inspect) do
        Kward::AzureOpenAIConfig.new(endpoint: endpoint, deployment: "deployment", api_version: "2025-04-01-preview")
      end
    end
  end

  def test_requires_safe_deployment_and_api_version_values
    ["", "bad/deployment", "bad?deployment", "bad#deployment"].each do |deployment|
      assert_raises(ArgumentError, deployment.inspect) do
        Kward::AzureOpenAIConfig.new(endpoint: "https://example.openai.azure.com", deployment: deployment, api_version: "2025-04-01-preview")
      end
    end

    ["", "2025-04-01-preview&api-key=secret", "version/other"].each do |api_version|
      assert_raises(ArgumentError, api_version.inspect) do
        Kward::AzureOpenAIConfig.new(endpoint: "https://example.openai.azure.com", deployment: "deployment", api_version: api_version)
      end
    end
  end

  def test_azure_login_validates_setup_before_storing_the_key
    Dir.mktmpdir do |dir|
      config_path = File.join(dir, "config.json")
      prompt = FakePrompt.new(["fixture-key", "http://insecure.example.com", "deployment", "2025-04-01-preview"])
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([]))

      with_env("KWARD_CONFIG_PATH" => config_path) do
        assert_raises(ArgumentError) { cli.login(provider: "azure_openai") }
      end

      refute File.exist?(File.join(dir, "api_keys.json"))
      refute_includes prompt.output.join, "fixture-key"
    end
  end

  def test_configured_deployment_is_the_only_selectable_azure_model
    Dir.mktmpdir do |dir|
      config_path = File.join(dir, "config.json")
      File.write(config_path, JSON.dump(
        "provider" => "azure_openai",
        "azure_openai_endpoint" => "https://example.openai.azure.com",
        "azure_openai_model" => "deployment-one",
        "azure_openai_api_version" => "2025-04-01-preview"
      ))
      store = Kward::APIKeyStore.new(path: File.join(dir, "api_keys.json"), config_path: config_path, env: { "AZURE_OPENAI_API_KEY" => "fixture-key" })
      client = Kward::Client.new(api_key: nil, openai_access_token: nil, oauth: FakeOAuth.new(nil), api_key_store: store, config_path: config_path)

      azure_models = client.available_models.select { |model| model[:provider] == "Azure OpenAI" }

      assert_equal ["deployment-one"], azure_models.map { |model| model[:id] }
    end
  end

  def test_azure_login_persists_valid_setup_and_deployment_model
    Dir.mktmpdir do |dir|
      config_path = File.join(dir, "config.json")
      prompt = FakePrompt.new(["fixture-key", "https://example.openai.azure.com/", "deployment-one", "2025-04-01-preview"])
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([]))

      with_env("KWARD_CONFIG_PATH" => config_path) do
        cli.login(provider: "azure_openai")
      end

      config = JSON.parse(File.read(config_path))
      assert_equal "https://example.openai.azure.com", config["azure_openai_endpoint"]
      assert_equal "deployment-one", config["azure_openai_model"]
      assert_equal "2025-04-01-preview", config["azure_openai_api_version"]
      assert_equal "fixture-key", JSON.parse(File.read(File.join(dir, "api_keys.json")))["azure_openai"]
    end
  end
end
