require_relative "test_support"

class TestRPCAuthManager < KwardTestCase
  include KwardRPCTestSupport

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

      assert_equal({ "providerId" => "openrouter", "message" => "Saved API key for OpenRouter." }, messages[1]["result"])
      refute_includes messages[1].to_s, "sk-secret456"
      assert_equal "sk-secret456", JSON.parse(File.read(config_path))["openrouter_api_key"]
      assert_equal 0o600, File.stat(config_path).mode & 0o777

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

      assert_equal({ "providerId" => "openrouter", "message" => "Logged out of OpenRouter." }, logout_messages[0]["result"])
      assert_equal({ "providerId" => "openai", "message" => "Logged out of OpenAI." }, logout_messages[1]["result"])
      refute JSON.parse(File.read(config_path)).key?("openrouter_api_key")
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
