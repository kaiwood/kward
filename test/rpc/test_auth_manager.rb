require_relative "test_support"

class TestRPCAuthManager < KwardTestCase
  include KwardRPCTestSupport

  def test_github_provider_ignores_general_github_tokens_for_copilot_auth
    Dir.mktmpdir do |config_dir|
      config_path = File.join(config_dir, "config.json")
      github_auth_path = File.join(config_dir, "github_auth.json")
      messages = run_rpc([
        { jsonrpc: "2.0", id: 1, method: "auth/providers" },
        { jsonrpc: "2.0", id: 2, method: "shutdown" }
      ], env: { "KWARD_CONFIG_PATH" => config_path, "KWARD_GITHUB_AUTH_PATH" => github_auth_path, "GH_TOKEN" => "github-token", "GITHUB_TOKEN" => "github-token" })

      github = messages[0]["result"]["providers"].find { |provider| provider["id"] == "copilot" }
      assert_equal false, github["configured"]
      assert_equal "Not configured", github["label"]
      refute github.key?("source")
    end
  end

  def test_github_provider_does_not_offer_rpc_logout
    Dir.mktmpdir do |config_dir|
      config_path = File.join(config_dir, "config.json")
      github_auth_path = File.join(config_dir, "github_auth.json")
      File.write(github_auth_path, JSON.pretty_generate(
        "tokens" => {
          "copilot_access_token" => "copilot-token",
          "copilot_expires_at" => (Time.now.utc + 3600).iso8601
        }
      ))
      File.chmod(0o600, github_auth_path)

      messages = run_rpc([
        { jsonrpc: "2.0", id: 1, method: "auth/providers" },
        { jsonrpc: "2.0", id: 2, method: "shutdown" }
      ], env: { "KWARD_CONFIG_PATH" => config_path, "KWARD_GITHUB_AUTH_PATH" => github_auth_path })

      github = messages[0]["result"]["providers"].find { |provider| provider["id"] == "copilot" }
      assert_equal true, github["configured"]
      assert_equal "stored", github["source"]
      assert_equal false, github["canLogout"]
    end
  end

  def test_anthropic_provider_reports_stored_oauth_and_logout
    Dir.mktmpdir do |config_dir|
      config_path = File.join(config_dir, "config.json")
      anthropic_auth_path = File.join(config_dir, "anthropic_auth.json")
      File.write(anthropic_auth_path, JSON.pretty_generate("tokens" => { "access_token" => "stored-anthropic-token" }))
      File.chmod(0o600, anthropic_auth_path)

      messages = run_rpc([
        { jsonrpc: "2.0", id: 1, method: "auth/providers" },
        { jsonrpc: "2.0", id: 2, method: "auth/logoutProvider", params: { providerId: "anthropic" } },
        { jsonrpc: "2.0", id: 3, method: "shutdown" }
      ], env: { "KWARD_CONFIG_PATH" => config_path, "KWARD_ANTHROPIC_AUTH_PATH" => anthropic_auth_path })

      anthropic = messages[0]["result"]["providers"].find { |provider| provider["id"] == "anthropic" }
      assert_equal "oauth", anthropic["authType"]
      assert_equal true, anthropic["configured"]
      assert_equal "stored", anthropic["source"]
      assert_equal true, anthropic["canLogout"]
      assert_equal true, anthropic["usesCallbackServer"]
      assert_equal true, messages[1]["result"]["removed"]
      assert_equal "Logged out of Anthropic.", messages[1]["result"]["message"]
      refute File.exist?(anthropic_auth_path)
    end
  end

  def test_provider_catalog_reports_api_key_and_unsupported_oauth_availability
    Dir.mktmpdir do |config_dir|
      config_path = File.join(config_dir, "config.json")
      messages = run_rpc([
        { jsonrpc: "2.0", id: 1, method: "auth/providers" },
        { jsonrpc: "2.0", id: 2, method: "initialize" },
        { jsonrpc: "2.0", id: 3, method: "shutdown" }
      ], env: { "KWARD_CONFIG_PATH" => config_path })

      providers = messages[0]["result"]["providers"]
      assert_equal Kward::ProviderCatalog.all.map(&:id), providers.map { |provider| provider["id"] }
      openai = providers.find { |provider| provider["id"] == "openai" }
      assert_equal ["api_key", "oauth"], openai["authMethods"].map { |method| method["id"] }
      xai_oauth = providers.find { |provider| provider["id"] == "xai" }["authMethods"].find { |method| method["id"] == "oauth" }
      assert_equal false, xai_oauth["supported"]
      assert_includes xai_oauth["reason"], "No official stable"

      auth_capabilities = messages[1]["result"]["capabilities"]["auth"]
      assert_equal Kward::ProviderCatalog.api_key_providers.map(&:id), auth_capabilities["apiKeyProviders"]
      assert_equal "No official stable third-party OAuth flow is available.", auth_capabilities.dig("unsupportedOAuthProviders", "xai")
    end
  end

  def test_api_key_login_supports_catalog_providers_without_exposing_secrets
    Dir.mktmpdir do |config_dir|
      config_path = File.join(config_dir, "config.json")
      messages = run_rpc([
        { jsonrpc: "2.0", id: 1, method: "auth/loginWithApiKey", params: { providerId: "groq", apiKey: "nonstandard-fixture-secret" } },
        { jsonrpc: "2.0", id: 2, method: "auth/status" },
        { jsonrpc: "2.0", id: 3, method: "shutdown" }
      ], env: { "KWARD_CONFIG_PATH" => config_path })

      refute_includes messages.to_s, "nonstandard-fixture-secret"
      assert_equal "nonstandard-fixture-secret", JSON.parse(File.read(File.join(config_dir, "api_keys.json")))["groq"]
      groq = messages[1]["result"]["providers"].find { |provider| provider["id"] == "groq" }
      assert_equal true, groq["configured"]
      assert_equal "stored", groq["source"]

      logout = run_rpc([
        { jsonrpc: "2.0", id: 1, method: "auth/logoutProvider", params: { providerId: "groq", authMethod: "api_key" } },
        { jsonrpc: "2.0", id: 2, method: "shutdown" }
      ], env: { "KWARD_CONFIG_PATH" => config_path })
      assert_equal true, logout[0]["result"]["removed"]
    end
  end

  def test_azure_api_key_login_validates_and_saves_non_secret_configuration
    Dir.mktmpdir do |config_dir|
      config_path = File.join(config_dir, "config.json")
      messages = run_rpc([
        {
          jsonrpc: "2.0",
          id: 1,
          method: "auth/loginWithApiKey",
          params: {
            providerId: "azure_openai",
            apiKey: "azure-rpc-fixture-key",
            configuration: {
              endpoint: "https://example.openai.azure.com/",
              deployment: "deployment-one",
              apiVersion: "2025-04-01-preview"
            }
          }
        },
        { jsonrpc: "2.0", id: 2, method: "shutdown" }
      ], env: { "KWARD_CONFIG_PATH" => config_path })

      refute_includes messages.to_s, "azure-rpc-fixture-key"
      config = JSON.parse(File.read(config_path))
      assert_equal "https://example.openai.azure.com", config["azure_openai_endpoint"]
      assert_equal "deployment-one", config["azure_openai_model"]
      assert_equal "2025-04-01-preview", config["azure_openai_api_version"]
      assert_equal "azure-rpc-fixture-key", JSON.parse(File.read(File.join(config_dir, "api_keys.json")))["azure_openai"]
    end
  end

  def test_unavailable_oauth_flow_returns_an_explicit_sanitized_error
    Dir.mktmpdir do |config_dir|
      messages = run_rpc([
        { jsonrpc: "2.0", id: 1, method: "auth/loginWithOAuth", params: { providerId: "xai" } },
        { jsonrpc: "2.0", id: 2, method: "shutdown" }
      ], env: { "KWARD_CONFIG_PATH" => File.join(config_dir, "config.json"), "XAI_API_KEY" => "xai-rpc-fixture-key" })

      assert_includes messages[0]["error"]["message"], "no official stable third-party flow"
      refute_includes messages[0].to_s, "xai-rpc-fixture-key"
    end
  end

  def test_auth_provider_cards_api_key_login_and_logout
    Dir.mktmpdir do |config_dir|
      config_path = File.join(config_dir, "config.json")
      auth_path = File.join(config_dir, "auth.json")
      File.write(auth_path, JSON.pretty_generate("tokens" => { "access_token" => "stored-openai-token" }))
      File.chmod(0o600, auth_path)

      messages = run_rpc([
        { jsonrpc: "2.0", id: 1, method: "auth/providers" },
        { jsonrpc: "2.0", id: 2, method: "auth/loginWithApiKey", params: { providerId: "openrouter", apiKey: "sk-secret456" } },
        { jsonrpc: "2.0", id: 3, method: "auth/providers" },
        { jsonrpc: "2.0", id: 4, method: "shutdown" }
      ], env: { "KWARD_CONFIG_PATH" => config_path, "KWARD_AUTH_PATH" => auth_path, "OPENROUTER_API_KEY" => "sk-env456" })

      openai = messages[0]["result"]["providers"].find { |provider| provider["id"] == "openai" }
      assert_equal "oauth", openai["authType"]
      assert_equal true, openai["configured"]
      assert_equal "stored", openai["source"]
      assert_equal true, openai["canLogout"]
      assert_equal true, openai["usesCallbackServer"]

      assert_equal "openrouter", messages[1]["result"]["providerId"]
      assert_equal "api_key", messages[1]["result"]["authMethod"]
      refute_includes messages[1].to_s, "sk-secret456"
      credentials_path = File.join(config_dir, "api_keys.json")
      assert_equal "sk-secret456", JSON.parse(File.read(credentials_path))["openrouter"]
      assert_equal 0o600, File.stat(credentials_path).mode & 0o777

      openrouter = messages[2]["result"]["providers"].find { |provider| provider["id"] == "openrouter" }
      assert_equal true, openrouter["configured"]
      assert_equal "environment", openrouter["source"]
      assert_equal true, openrouter["canLogout"]

      logout_messages = run_rpc([
        { jsonrpc: "2.0", id: 1, method: "auth/logoutProvider", params: { providerId: "openrouter" } },
        { jsonrpc: "2.0", id: 2, method: "auth/logoutProvider", params: { providerId: "openai" } },
        { jsonrpc: "2.0", id: 3, method: "auth/providers" },
        { jsonrpc: "2.0", id: 4, method: "shutdown" }
      ], env: { "KWARD_CONFIG_PATH" => config_path, "KWARD_AUTH_PATH" => auth_path, "OPENROUTER_API_KEY" => "sk-env456", "OPENAI_ACCESS_TOKEN" => "env-openai-token" })

      assert_equal true, logout_messages[0]["result"]["removed"]
      assert_equal "Logged out of OpenRouter.", logout_messages[0]["result"]["message"]
      assert_equal true, logout_messages[1]["result"]["removed"]
      assert_equal "Logged out of OpenAI.", logout_messages[1]["result"]["message"]
      refute JSON.parse(File.read(credentials_path)).key?("openrouter")
      refute File.exist?(auth_path)
      openrouter = logout_messages[2]["result"]["providers"].find { |provider| provider["id"] == "openrouter" }
      assert_equal true, openrouter["configured"]
      assert_equal "environment", openrouter["source"]
      assert_equal false, openrouter["canLogout"]
      openai = logout_messages[2]["result"]["providers"].find { |provider| provider["id"] == "openai" }
      assert_equal true, openai["configured"]
      assert_equal "environment", openai["source"]
      assert_equal false, openai["canLogout"]
    end
  end
end
