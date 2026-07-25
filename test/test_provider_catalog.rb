require_relative "test_helper"
require_relative "../lib/kward/auth/api_key_store"
require_relative "../lib/kward/model/provider_catalog"

class TestProviderCatalog < KwardTestCase
  def test_api_key_provider_menu_is_alphabetical
    assert_equal [
      "Anthropic", "Azure OpenAI", "Cerebras", "DeepSeek", "Fireworks AI",
      "Google Gemini", "Groq", "Mistral", "NVIDIA NIM", "OpenAI",
      "OpenRouter", "Together AI", "xAI"
    ], Kward::ProviderCatalog.api_key_providers.map(&:name)
  end

  def test_oauth_provider_menu_is_alphabetical
    assert_equal ["Anthropic Claude", "ChatGPT", "GitHub Copilot", "OpenRouter", "xAI Grok"],
      Kward::ProviderCatalog.oauth_providers.filter_map(&:oauth_name).sort
  end

  def test_runtime_metadata_owns_provider_endpoints_and_config_keys
    runtime = Kward::ProviderCatalog.runtime("groq")

    assert_equal "groq", runtime.id
    assert_equal "groq_model", runtime.model_config_key
    assert_equal "https://api.groq.com/openai/v1/chat/completions", runtime.chat_url
    assert runtime.automatic_model_discovery?
    assert_equal :configured, Kward::ProviderCatalog.runtime("azure_openai").model_discovery
    assert_equal "openai_api", Kward::ProviderCatalog.runtime("openai").id
  end

  def test_api_key_store_prefers_the_environment
    Dir.mktmpdir do |directory|
      store = Kward::APIKeyStore.new(path: File.join(directory, "api_keys.json"), env: { "GROQ_API_KEY" => "from-environment" })
      store.store("groq", "stored-key")

      assert_equal "from-environment", store.fetch("groq")
      assert store.stored?("groq")
    end
  end

  def test_api_key_store_migrates_the_legacy_openrouter_config_key
    Dir.mktmpdir do |directory|
      config_path = File.join(directory, "config.json")
      key_path = File.join(directory, "api_keys.json")
      Kward::ConfigFiles.write_config({ "openrouter_api_key" => "legacy-key" }, config_path)
      store = Kward::APIKeyStore.new(path: key_path, config_path: config_path, env: {})

      assert store.migrate_openrouter_config_key!
      assert_equal "legacy-key", store.fetch("openrouter")
      refute Kward::ConfigFiles.read_config(config_path).key?("openrouter_api_key")
      assert_equal 0o600, File.stat(key_path).mode & 0o777
    end
  end
end
