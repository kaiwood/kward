require_relative "test_support"

class TestRPCModelCatalogs < KwardTestCase
  include KwardRPCTestSupport

  def with_catalog_client(provider, providers: [provider])
    Dir.mktmpdir do |dir|
      path = File.join(dir, "config.json")
      config = Kward::ModelInfo.config_values_for_selection(provider, "configured-model")
      File.write(path, JSON.generate(config))
      env = Kward::ProviderCatalog.all.flat_map(&:api_key_env).to_h { |key| [key, nil] }
      Kward::ProviderCatalog.all.each { |entry| env["#{entry.id.upcase}_MODEL"] = nil }
      env.merge!("KWARD_CONFIG_PATH" => path, "KWARD_PROVIDER" => nil, "KWARD_LOCAL_MODEL" => nil, "OPENAI_API_MODEL" => nil)
      with_env(env) do
        keys = Kward::ProviderCatalog.all.to_h { |entry| [entry.id, "fixture-secret"] }
        client = Kward::Client.new(
          config_path: path, api_key_store: keys, api_key: "fixture-secret", openai_access_token: nil,
          oauth: FakeOAuth.new(nil), github_oauth: FakeGithubOAuth.new("fixture-token"),
          anthropic_oauth: FakeAnthropicOAuth.new(nil)
        )
        client.define_singleton_method(:provider_logged_in?) { |name| providers.include?(name) }
        client.define_singleton_method(:current_provider) { Kward::ModelInfo.provider_label(@config["provider"]) }
        yield client, dir, path
      end
    end
  end

  def with_discovery_responses(*responses)
    requests = []
    expected_count = responses.length
    http = Object.new
    http.define_singleton_method(:request) do |request|
      requests << request
      response = responses.shift
      raise "Unexpected discovery request" unless response
      raise response if response.is_a?(Exception)

      response
    end
    original_start = Net::HTTP.method(:start)
    Net::HTTP.define_singleton_method(:start) { |*_args, **_options, &block| block.call(http) }
    yield requests
    assert_empty responses, "Expected all discovery responses to be consumed"
    assert_equal expected_count, requests.length
  ensure
    Net::HTTP.define_singleton_method(:start, original_start) if original_start
  end

  def rpc_result(client, method, params = {})
    messages = run_rpc([
      { jsonrpc: "2.0", id: 1, method: method, params: params },
      { jsonrpc: "2.0", id: 2, method: "shutdown" }
    ], client: client)
    response = messages.find { |message| message["id"] == 1 }
    refute response.key?("error"), response.inspect
    response.fetch("result")
  end

  def test_rpc_catalog_is_complete_and_matches_the_shared_picker_rule
    client = FakeClient.new([])
    client.provider = "Local"
    client.model = "selected-embedding"
    client.define_singleton_method(:available_models) do
      [
        { provider: "Local", id: "selected-embedding", current: false, supportedParameters: ["embeddings"] },
        { provider: "Local", id: "other-embedding", supportedParameters: ["embeddings"], source: "cached" },
        { provider: "Local", id: "unknown" },
        { provider: "Local", id: "tool-model", supportedParameters: ["tool_choice"] }
      ]
    end

    models = rpc_result(client, "models/list").fetch("models")
    assert_equal 4, models.length
    assert_equal [true, false, true, true], models.map { |model| model["defaultSelectable"] }
    assert_equal "cached", models[1]["source"]
    assert_equal ["embeddings"], models[1]["supportedParameters"]
    models.each do |model|
      normalized = model.transform_keys(&:to_sym)
      assert_equal Kward::ModelInfo.default_selectable_model?(normalized), model["defaultSelectable"]
    end
  end

  def test_openrouter_refresh_replaces_memory_and_disk_and_reports_safe_fallback
    with_catalog_client("OpenRouter") do |client, dir, _path|
      cache_path = File.join(dir, "cache", "openrouter_models.json")
      FileUtils.mkdir_p(File.dirname(cache_path))
      File.write(cache_path, JSON.generate("version" => 1, "models" => [{ "id" => "vendor/old" }]))
      assert_includes client.available_models.map { |model| model[:id] }, "vendor/old"
      fresh = fake_net_response(200, JSON.generate("data" => [{
        "id" => "vendor/new", "supported_parameters" => ["tools"],
        "architecture" => { "input_modalities" => ["text"], "output_modalities" => ["text"] }
      }]))
      failed = fake_net_response(403, "Authorization: Bearer fixture-secret private-provider-body")
      with_discovery_responses(fresh, failed) do |requests|
        result = rpc_result(client, "models/refresh")
        assert_equal({ "provider" => "OpenRouter", "status" => "success", "fallbackUsed" => false }, result["refresh"])
        models = rpc_result(client, "models/list").fetch("models")
        assert_equal result["models"], models
        assert_includes models.map { |model| model["id"] }, "vendor/new"
        refute_includes models.map { |model| model["id"] }, "vendor/old"
        saved = File.read(cache_path)
        result = rpc_result(client, "models/refresh")
        assert_equal({ "provider" => "OpenRouter", "status" => "failed", "fallbackUsed" => true }, result["refresh"])
        assert_equal models, result["models"]
        assert_equal saved, File.read(cache_path)
        %w[fixture-secret private-provider-body Authorization api_key_sha256].each do |secret|
          refute_includes JSON.generate(result), secret
        end
        assert_equal ["/api/v1/models/user"] * 2, requests.map(&:path)
      end
    end
  end

  def test_copilot_and_local_refresh_bypass_memoization_and_retain_last_good_catalog_on_failure
    { "Copilot" => %w[gpt-5-old gpt-5-new], "Local" => %w[org/old org/new] }.each do |provider, ids|
      with_catalog_client(provider) do |client, _dir, _path|
        responses = ids.map { |id| fake_net_response(200, JSON.generate("data" => [{ "id" => id }])) }
        responses << fake_net_response(200, "not JSON: fixture-secret")
        with_discovery_responses(*responses) do |requests|
          assert_includes client.available_models.map { |model| model[:id] }, ids.first
          refreshed = rpc_result(client, "models/refresh")
          assert_equal({ "provider" => provider, "status" => "success", "fallbackUsed" => false }, refreshed["refresh"])
          assert_includes refreshed["models"].map { |model| model["id"] }, ids.last
          refute_includes refreshed["models"].map { |model| model["id"] }, ids.first
          assert_equal refreshed["models"], rpc_result(client, "models/list")["models"]
          failed = rpc_result(client, "models/refresh")
          assert_equal "failed", failed["refresh"]["status"]
          assert_equal true, failed["refresh"]["fallbackUsed"]
          assert_equal refreshed["models"], failed["models"]
          assert_equal 3, requests.length
        end
      end
    end
  end

  def test_explicit_inactive_copilot_refresh_is_consumed_without_changing_active_provider
    with_catalog_client("Codex", providers: ["Codex", "Copilot"]) do |client, _dir, _path|
      with_discovery_responses(fake_net_response(200, '{"data":[{"id":"gpt-5-discovered"}]}')) do |requests|
        result = rpc_result(client, "models/refresh", provider: "GitHub Copilot")
        assert_equal "success", result["refresh"]["status"]
        assert_equal "Copilot", result["refresh"]["provider"]
        assert_includes result["models"].map { |model| model["id"] }, "gpt-5-discovered"
        assert_equal "Codex", client.current_provider
        assert_equal 1, requests.length
      end
    end
  end

  def test_general_and_anthropic_refresh_are_consumed_and_failure_preserves_disk
    %w[Groq Anthropic OpenAI].each do |provider|
      with_catalog_client(provider) do |client, _dir, _path|
        fresh = fake_net_response(200, '{"data":[{"id":"org/discovered","supported_parameters":["tools"]}]}')
        with_discovery_responses(fresh, fake_net_response(500, "fixture-secret")) do |requests|
          result = rpc_result(client, "models/refresh")
          assert_equal({ "provider" => provider, "status" => "success", "fallbackUsed" => false }, result["refresh"])
          assert_includes result["models"].map { |model| model["id"] }, "org/discovered"
          assert_equal result["models"], rpc_result(client, "models/list")["models"]
          failed = rpc_result(client, "models/refresh")
          assert_equal "failed", failed["refresh"]["status"]
          assert_equal result["models"], failed["models"]
          assert_equal 2, requests.length
        end
      end
    end
  end

  def test_omitted_provider_targets_only_active_provider_and_unsupported_is_not_failure
    with_catalog_client("Codex", providers: ["Codex", "Copilot", "OpenAI"]) do |client, _dir, _path|
      with_discovery_responses do |requests|
        before = rpc_result(client, "models/list")["models"]
        result = rpc_result(client, "models/refresh")
        assert_equal({ "provider" => "Codex", "status" => "unsupported", "fallbackUsed" => true }, result["refresh"])
        assert_equal before, result["models"]
        assert_equal before.map { |model| model["id"] }, client.refresh_available_models.map { |model| model[:id] }
        assert_empty requests
      end
    end
  end

  def test_provider_identities_and_slash_ids_round_trip_through_set
    with_catalog_client("Codex", providers: ["Codex", "OpenAI", "OpenRouter"]) do |client, _dir, _path|
      with_discovery_responses do
        %w[OpenAI Codex OpenRouter].each do |provider|
          selected = rpc_result(client, "models/set", provider: provider, model: "org/model/variant")
          assert_equal provider, selected["provider"]
          assert_equal "org/model/variant", selected["id"]
          entry = rpc_result(client, "models/list")["models"].find { |model| model["current"] }
          assert_equal provider, entry["provider"]
          selected = rpc_result(client, "models/set", provider: entry["provider"], model: entry["id"])
          assert_equal [provider, "org/model/variant"], selected.values_at("provider", "id")
        end
      end
    end
  end
  def test_runtime_reload_adopts_external_configuration_and_openrouter_cache_changes
    with_catalog_client("OpenRouter") do |client, dir, path|
      cache_path = File.join(dir, "cache", "openrouter_models.json")
      FileUtils.mkdir_p(File.dirname(cache_path))
      File.write(cache_path, JSON.generate("version" => 1, "models" => [{ "id" => "org/before" }]))
      server = Kward::RPC::Server.new(input: StringIO.new, output: StringIO.new, error_output: StringIO.new, client: client)
      begin
        manager = server.session_manager
        session = manager.create_session(workspace_root: dir)
        reload_count = 0
        original_reload = manager.method(:reload_plugins)
        manager.define_singleton_method(:reload_plugins) { reload_count += 1; original_reload.call }
        with_discovery_responses do
          assert_includes server.send(:models_list)[:models].map { |model| model[:id] }, "org/before"
          File.write(cache_path, JSON.generate("version" => 1, "models" => [{ "id" => "org/after" }]))
          File.write(path, JSON.generate(Kward::ModelInfo.config_values_for_selection("OpenRouter", "external/default")))
          assert_includes server.send(:models_list)[:models].map { |model| model[:id] }, "org/before"
          assert_equal "configured-model", client.current_model
          assert_equal 0, reload_count
          server.send(:runtime_reload, "sessionId" => session[:id])
          models = server.send(:models_list)[:models]
          assert_includes models.map { |model| model[:id] }, "org/after"
          refute_includes models.map { |model| model[:id] }, "org/before"
          assert_equal "external/default", models.find { |model| model[:current] }[:id]
          assert_equal 1, reload_count
        end
      ensure
        server.shutdown
      end
    end
  end

  def test_refresh_does_not_reload_configuration_plugins_or_change_session_selection
    with_catalog_client("Local") do |client, dir, path|
      server = Kward::RPC::Server.new(input: StringIO.new, output: StringIO.new, error_output: StringIO.new, client: client)
      begin
        manager = server.session_manager
        session = manager.create_session(workspace_root: dir)
        conversation = manager.send(:fetch_session, session[:id]).conversation
        conversation.update_runtime_context!(provider: "Local", model: "conversation/model", reasoning_effort: nil)
        manager.define_singleton_method(:reload_plugins) { raise "Plugins must not reload" }
        File.write(path, JSON.generate(Kward::ModelInfo.config_values_for_selection("Local", "external/default")))
        with_discovery_responses(fake_net_response(200, '{"data":[{"id":"org/new"}]}')) do
          result = server.send(:models_refresh, {})
          assert_equal "success", result[:refresh][:status]
          assert_equal "configured-model", client.current_model
          assert_equal "conversation/model", conversation.model
          assert_includes server.send(:models_list)[:models].map { |model| model[:id] }, "org/new"
        end
      ensure
        server.shutdown
      end
    end
  end

  def test_valid_empty_catalogs_succeed_but_invalid_catalogs_preserve_fallback
    %w[OpenRouter Copilot Local Anthropic].each do |provider|
      with_catalog_client(provider) do |client, _dir, _path|
        with_discovery_responses(fake_net_response(200, '{"data":[]}'), fake_net_response(200, '{"error":"fixture-secret"}')) do
          result = rpc_result(client, "models/refresh")
          assert_equal "success", result["refresh"]["status"]
          assert_equal false, result["refresh"]["fallbackUsed"]
          failed = rpc_result(client, "models/refresh")
          assert_equal "failed", failed["refresh"]["status"]
          assert_equal result["models"], failed["models"]
          refute_includes JSON.generate(failed), "fixture-secret"
        end
      end
    end
  end

  def test_configured_only_provider_retains_its_deployment_without_discovery
    with_catalog_client("Azure OpenAI") do |client, _dir, _path|
      with_discovery_responses do
        result = rpc_result(client, "models/refresh")
        assert_equal({ "provider" => "Azure OpenAI", "status" => "unsupported", "fallbackUsed" => true }, result["refresh"])
        assert_equal ["configured-model"], result["models"].map { |model| model["id"] }
      end
    end
  end

  def test_initial_discovery_failure_does_not_retry_during_the_following_list
    %w[Copilot Local].each do |provider|
      with_catalog_client(provider) do |client, _dir, _path|
        with_discovery_responses(fake_net_response(401, "fixture-secret")) do
          result = rpc_result(client, "models/refresh")
          assert_equal "failed", result["refresh"]["status"]
          assert_equal true, result["refresh"]["fallbackUsed"]
          assert_includes result["models"].map { |model| model["id"] }, "configured-model"
          assert_equal result["models"], rpc_result(client, "models/list")["models"]
        end
      end
    end
  end

  def test_openai_catalog_id_selects_direct_openai_not_codex
    with_catalog_client("Codex", providers: ["OpenAI", "Codex"]) do |client, _dir, path|
      result = rpc_result(client, "models/set", provider: "openai", model: "models/org/variant")
      assert_equal "OpenAI", result["provider"]
      assert_equal "models/org/variant", result["id"]
      assert_equal "openai_api", JSON.parse(File.read(path))["provider"]
    end
  end

end
