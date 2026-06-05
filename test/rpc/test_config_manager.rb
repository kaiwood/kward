require_relative "test_support"

class TestRPCConfigManager < KwardTestCase
  include KwardRPCTestSupport

  def test_model_rpc_methods_read_and_update_config
    Dir.mktmpdir do |config_dir|
      config_path = File.join(config_dir, "config.json")
      client = ReloadableFakeClient.new([], config_path)
      messages = run_rpc([
        { jsonrpc: "2.0", id: 1, method: "models/current" },
        { jsonrpc: "2.0", id: 2, method: "models/list" },
        { jsonrpc: "2.0", id: 3, method: "models/set", params: { model: "new-openai-model" } },
        { jsonrpc: "2.0", id: 4, method: "reasoning/set", params: { effort: "high" } },
        { jsonrpc: "2.0", id: 5, method: "shutdown" }
      ], client: client, env: { "KWARD_CONFIG_PATH" => config_path })

      assert_equal "Codex", messages[0]["result"]["provider"]
      assert_equal "fake-model", messages[0]["result"]["id"]
      assert_equal "fake-model", messages[0]["result"]["model"]
      assert_equal "fake-model", messages[0]["result"]["name"]
      assert_equal true, messages[0]["result"]["reasoning"]
      list_model = messages[1]["result"]["models"].find { |model| model["provider"] == "Codex" }
      assert_equal "fake-model", list_model["id"]
      assert_equal "fake-model", list_model["name"]
      assert_equal true, list_model["reasoning"]
      assert_equal "medium", list_model["reasoningEffort"]
      assert_equal 200_000, list_model["contextWindow"]
      assert_equal "new-openai-model", messages[2]["result"]["id"]
      assert_equal "new-openai-model", messages[2]["result"]["model"]
      assert_equal "high", messages[3]["result"]["reasoningEffort"]
      assert_equal 2, client.reload_count

      config = JSON.parse(File.read(config_path))
      assert_equal "new-openai-model", config["openai_model"]
      assert_equal "high", config["openai_reasoning_effort"]
    end
  end

  def test_config_update_redacts_secrets_in_response
    Dir.mktmpdir do |config_dir|
      config_path = File.join(config_dir, "config.json")
      messages = run_rpc([
        { jsonrpc: "2.0", id: 1, method: "config/update", params: { values: { openrouter_api_key: "sk-secret123", model: "test-model" } } },
        { jsonrpc: "2.0", id: 2, method: "shutdown" }
      ], env: { "KWARD_CONFIG_PATH" => config_path })

      config = messages[0]["result"]["config"]
      assert_equal "[REDACTED]", config["openrouter_api_key"]
      assert_equal "test-model", config["model"]
      assert_equal "sk-secret123", JSON.parse(File.read(config_path))["openrouter_api_key"]
    end
  end

  def test_runtime_update_setting_and_reload
    Dir.mktmpdir do |config_dir|
      config_path = File.join(config_dir, "config.json")
      client = ReloadableFakeClient.new([], config_path)
      with_env("KWARD_CONFIG_PATH" => config_path) do
        server = Kward::RPC::Server.new(input: StringIO.new, output: StringIO.new, error_output: StringIO.new, client: client)
        session = server.instance_variable_get(:@session_manager).create_session(workspace_root: Dir.pwd)

        model_result = server.send(:runtime_update_setting, "sessionId" => session[:id], "settingId" => "defaultModel", "value" => "OpenRouter/anthropic/claude-sonnet")
        thinking_result = server.send(:runtime_update_setting, "sessionId" => session[:id], "settingId" => "defaultThinkingLevel", "value" => "high")
        reload_result = server.send(:runtime_reload, "sessionId" => session[:id])

        assert_equal "live", model_result[:applied]
        assert_equal "Model updated for this session.", model_result[:message]
        assert_equal "Thinking level updated for this session.", thinking_result[:message]
        assert_equal({ ok: true, message: "Resources reloaded." }, reload_result)
        config = JSON.parse(File.read(config_path))
        assert_equal "anthropic/claude-sonnet", config["openrouter_model"]
        assert_equal "high", config["openai_reasoning_effort"]
        assert_equal 3, client.reload_count

        error = assert_raises(ArgumentError) do
          server.send(:runtime_update_setting, "sessionId" => session[:id], "settingId" => "transport", "value" => "stdio")
        end
        assert_equal "Unsupported runtime setting: transport", error.message
      end
    end
  end
end
