require_relative "test_helper"

class TestClient < KwardTestCase
  class FakeHTTP
    attr_reader :requests

    def initialize(responses)
      @responses = responses
      @requests = []
    end

    def request(request)
      @requests << request
      response = @responses.shift
      raise response if response.is_a?(Exception)

      if block_given?
        yield response
      else
        response
      end
    end
  end

  def with_fake_http(responses)
    fake_http = FakeHTTP.new(responses)
    original_start = Net::HTTP.method(:start)
    Net::HTTP.define_singleton_method(:start) do |_host, _port, **_options, &block|
      block.call(fake_http)
    end
    yield fake_http
  ensure
    Net::HTTP.define_singleton_method(:start, original_start) if original_start
  end

  def disable_sleep(client)
    client.define_singleton_method(:sleep_with_cancellation) { |_seconds, _cancellation| nil }
  end

  def test_client_requires_openai_oauth_login_or_openrouter
    client = Kward::Client.new(api_key: nil, openai_access_token: nil, oauth: FakeOAuth.new(nil))

    error = assert_raises(RuntimeError) do
      client.chat([{ role: "user", content: "hello" }])
    end

    assert_equal Kward::Client::AUTH_ERROR, error.message
  end

  def test_codex_oauth_defaults_to_gpt_5_5_medium_reasoning
    client = Kward::Client.new(api_key: nil, openai_access_token: "token", oauth: FakeOAuth.new(nil), config_path: "missing_kward_config.json")

    payload = client.send(:codex_payload, [{ role: "user", content: "hello" }], [])

    assert_equal "gpt-5.5", payload[:model]
    assert_equal({ effort: "medium", summary: "auto" }, payload[:reasoning])
    assert_equal true, payload[:stream]
    assert_equal false, payload[:store]
  end

  def test_codex_payload_converts_tool_result_role_to_function_call_output
    client = Kward::Client.new(api_key: nil, openai_access_token: "token", oauth: FakeOAuth.new(nil), config_path: "missing_kward_config.json")
    messages = [
      { "role" => "compactionSummary", "summary" => "summary" },
      assistant_tool_call("read_file", path: "README.md"),
      { "role" => "toolResult", "toolCallId" => "call_read_file", "toolName" => "read_file", "content" => "README contents" }
    ]

    input = client.send(:codex_payload, messages, [])[:input]
    calls = input.select { |item| item[:type] == "function_call" }.map { |item| item[:call_id] }
    outputs = input.select { |item| item[:type] == "function_call_output" }.map { |item| item[:call_id] }

    assert_equal ["call_read_file"], calls
    assert_equal ["call_read_file"], outputs
    assert_empty calls - outputs
  end

  def test_codex_oauth_reads_model_and_reasoning_from_config
    Dir.mktmpdir do |dir|
      path = File.join(dir, "config.json")
      File.write(path, JSON.dump("openai_model" => "gpt-config", "openai_reasoning_effort" => "high"))
      client = Kward::Client.new(api_key: nil, openai_access_token: "token", oauth: FakeOAuth.new(nil), config_path: path)

      payload = client.send(:codex_payload, [{ role: "user", content: "hello" }], [])

      assert_equal "gpt-config", payload[:model]
      assert_equal({ effort: "high", summary: "auto" }, payload[:reasoning])
    end
  end

  def test_codex_payload_omits_unsupported_max_output_tokens
    client = Kward::Client.new(api_key: nil, openai_access_token: "token", oauth: FakeOAuth.new(nil), config_path: "missing_kward_config.json")

    payload = client.send(:codex_payload, [{ role: "user", content: "hello" }], [], max_tokens: 1234)

    refute payload.key?(:max_output_tokens)
  end

  def test_config_model_and_thinking_level_apply_to_current_provider
    Dir.mktmpdir do |dir|
      path = File.join(dir, "config.json")
      File.write(path, JSON.dump("model" => "configured-model", "thinking_level" => "low"))
      client = Kward::Client.new(api_key: nil, openai_access_token: "token", oauth: FakeOAuth.new(nil), config_path: path)

      payload = client.send(:codex_payload, [{ role: "user", content: "hello" }], [])

      assert_equal "configured-model", payload[:model]
      assert_equal({ effort: "low", summary: "auto" }, payload[:reasoning])
    end
  end

  def test_openrouter_reads_model_from_config
    Dir.mktmpdir do |dir|
      path = File.join(dir, "config.json")
      File.write(path, JSON.dump("openrouter_model" => "provider/configured"))
      client = Kward::Client.new(api_key: "token", openai_access_token: nil, oauth: FakeOAuth.new(nil), config_path: path)

      payload = client.send(:request_payload, "OpenRouter", [{ role: "user", content: "hello" }], [])

      assert_equal "provider/configured", payload[:model]
    end
  end

  def test_anthropic_reads_model_from_config
    Dir.mktmpdir do |dir|
      path = File.join(dir, "config.json")
      File.write(path, JSON.dump("anthropic_model" => "claude-opus-4.5", "anthropic_reasoning_effort" => "high"))
      client = Kward::Client.new(api_key: nil, openai_access_token: nil, oauth: FakeOAuth.new(nil), anthropic_oauth: FakeAnthropicOAuth.new("anthropic-token"), config_path: path)

      tools = [
        { function: { name: "read_file", description: "Read a file", parameters: { properties: { path: { type: "string" } }, required: ["path"] } } },
        { function: { name: "fetch_content", description: "Fetch content", parameters: { properties: { url: { type: "string" } }, required: ["url"] } } }
      ]
      payload = client.send(:anthropic_payload, [{ role: "system", content: "ship rules" }, { role: "user", content: "hello" }], tools)

      assert_equal "claude-opus-4-5", payload[:model]
      assert_equal true, payload[:stream]
      assert_equal "You are Claude Code, Anthropic's official CLI for Claude.", payload[:system].first[:text]
      assert_equal "ship rules", payload[:system].last[:text]
      assert_equal({ type: "adaptive", display: "summarized" }, payload[:thinking])
      assert_equal({ effort: "high" }, payload[:output_config])
      assert_equal "Read", payload[:tools].first[:name]
      assert_equal "WebFetch", payload[:tools].last[:name]
    end
  end

  def test_anthropic_payload_disables_thinking_for_models_without_reasoning_effort
    Dir.mktmpdir do |dir|
      path = File.join(dir, "config.json")
      File.write(path, JSON.dump("provider" => "anthropic", "anthropic_model" => "claude-haiku-4.5"))
      client = Kward::Client.new(api_key: nil, openai_access_token: nil, oauth: FakeOAuth.new(nil), anthropic_oauth: FakeAnthropicOAuth.new("anthropic-token"), config_path: path)

      payload = client.send(:request_body_payload, "Anthropic", [{ role: "user", content: "hello" }], [], model: "claude-haiku-4-5")

      assert_equal "claude-haiku-4-5", payload[:model]
      assert_equal({ type: "disabled" }, payload[:thinking])
      refute payload.key?(:output_config)
    end
  end

  def test_available_models_include_only_logged_in_provider_picker_choices
    client = Kward::Client.new(
      api_key: "openrouter-token",
      openai_access_token: "token",
      oauth: FakeOAuth.new(nil),
      github_oauth: FakeGithubOAuth.new("github-token"),
      anthropic_oauth: FakeAnthropicOAuth.new("anthropic-token"),
      config_path: "missing_kward_config.json"
    )

    models = client.available_models

    assert_includes models, { provider: "Codex", id: "gpt-5.5", current: true }
    assert_includes models, { provider: "Codex", id: "gpt-5.4", current: false }
    assert_includes models, { provider: "Codex", id: "gpt-5.4-mini", current: false }
    assert_includes models, { provider: "Codex", id: "gpt-5.3-codex-spark", current: false }
    assert_includes models, { provider: "OpenRouter", id: "openai/gpt-5.3-codex-spark", current: false }
    assert_includes models, { provider: "Copilot", id: "gpt-5-mini", current: false }
    assert_includes models, { provider: "Anthropic", id: "claude-sonnet-4-6", current: false }
    assert_includes models, { provider: "Anthropic", id: "claude-opus-4-8", current: false }
    assert_includes models, { provider: "Anthropic", id: "claude-sonnet-4-5", current: false }
    assert_includes models, { provider: "Anthropic", id: "claude-opus-4-5", current: false }
    refute models.any? { |model| model[:provider] == "Copilot" && model[:id] == "claude-sonnet-4.6" }
    assert_includes models, { provider: "Copilot", id: "gemini-3.1-pro-preview", current: false }
  end

  def test_available_models_hide_providers_without_credentials
    client = Kward::Client.new(api_key: nil, openai_access_token: "token", oauth: FakeOAuth.new(nil), github_oauth: FakeGithubOAuth.new(nil), anthropic_oauth: FakeAnthropicOAuth.new(nil), config_path: "missing_kward_config.json")

    models = client.available_models

    assert models.any? { |model| model[:provider] == "Codex" }
    refute models.any? { |model| model[:provider] == "OpenRouter" }
    refute models.any? { |model| model[:provider] == "Copilot" }
    refute models.any? { |model| model[:provider] == "Anthropic" }
  end

  def test_anthropic_chat_uses_messages_endpoint_and_parses_stream
    Dir.mktmpdir do |dir|
      path = File.join(dir, "config.json")
      File.write(path, JSON.dump("provider" => "anthropic", "anthropic_model" => "claude-sonnet-4-5"))
      client = Kward::Client.new(api_key: nil, openai_access_token: nil, oauth: FakeOAuth.new(nil), anthropic_oauth: FakeAnthropicOAuth.new("sk-ant-oat-test"), config_path: path)
      stream = [
        "event: message_start\ndata: #{JSON.dump("type" => "message_start", "message" => { "usage" => { "input_tokens" => 3, "output_tokens" => 0 } })}\n\n",
        "event: content_block_start\ndata: #{JSON.dump("type" => "content_block_start", "index" => 0, "content_block" => { "type" => "text", "text" => "" })}\n\n",
        "event: content_block_delta\ndata: #{JSON.dump("type" => "content_block_delta", "index" => 0, "delta" => { "type" => "text_delta", "text" => "hello" })}\n\n",
        "event: message_stop\ndata: #{JSON.dump("type" => "message_stop")}\n\n"
      ].join

      with_fake_http([fake_net_response(200, stream)]) do |http|
        message = client.chat([{ role: "user", content: "hello" }])

        assert_equal "hello", message["content"]
        assert_equal "Anthropic", message["provider"]
        assert_equal URI("https://api.anthropic.com/v1/messages"), http.requests.first.uri
        assert_equal "Bearer sk-ant-oat-test", http.requests.first["Authorization"]
        assert_equal "claude-code-20250219,oauth-2025-04-20", http.requests.first["anthropic-beta"]
        payload = JSON.parse(http.requests.first.body)
        assert_equal "claude-sonnet-4-5", payload.fetch("model")
        assert_equal true, payload.fetch("stream")
      end
    end
  end

  def test_openrouter_available_models_use_live_model_ids_when_available
    Dir.mktmpdir do |dir|
      path = File.join(dir, "config.json")
      File.write(path, JSON.dump("provider" => "openrouter", "openrouter_model" => "stale/model"))
      client = Kward::Client.new(api_key: "openrouter-token", openai_access_token: nil, oauth: FakeOAuth.new(nil), config_path: path)
      body = JSON.dump("data" => [{ "id" => "anthropic/claude-sonnet-4.5" }, { "id" => "openai/gpt-5.5" }])

      with_fake_http([fake_net_response(200, body)]) do |http|
        models = client.available_models
        cached_models = client.available_models

        assert_equal models, cached_models
        assert_includes models, { provider: "OpenRouter", id: "anthropic/claude-sonnet-4.5", current: false }
        assert_includes models, { provider: "OpenRouter", id: "openai/gpt-5.5", current: false }
        assert_includes models, { provider: "OpenRouter", id: "stale/model", current: true }
        refute_includes models, { provider: "OpenRouter", id: "openai/gpt-5.3-codex-spark", current: false }
        openrouter_requests = http.requests.select { |request| request.uri == URI("https://openrouter.ai/api/v1/models") }
        assert_equal 1, openrouter_requests.length
        assert_equal "Bearer openrouter-token", openrouter_requests.first["Authorization"]
      end
    end
  end

  def test_openrouter_available_models_fall_back_to_static_choices_when_fetch_fails
    client = Kward::Client.new(api_key: "openrouter-token", openai_access_token: nil, oauth: FakeOAuth.new(nil), config_path: "missing_kward_config.json")

    with_fake_http([fake_net_response(500, "error")]) do
      models = client.available_models

      assert_includes models, { provider: "OpenRouter", id: "openai/gpt-5.3-codex-spark", current: false }
    end
  end

  def test_available_models_does_not_fetch_inactive_provider_catalogs
    Dir.mktmpdir do |dir|
      path = File.join(dir, "config.json")
      File.write(path, JSON.dump("provider" => "openai"))
      client = Kward::Client.new(api_key: "openrouter-token", openai_access_token: "openai-token", oauth: FakeOAuth.new(nil), github_oauth: FakeGithubOAuth.new("github-token"), config_path: path)

      with_fake_http([]) do |http|
        models = client.available_models

        assert_includes models, { provider: "OpenRouter", id: "openai/gpt-5.3-codex-spark", current: false }
        assert_includes models, { provider: "Copilot", id: "gpt-5-mini", current: false }
        refute models.any? { |model| model[:provider] == "Anthropic" }
        assert_empty http.requests
      end
    end
  end

  def test_openrouter_catalog_fetches_full_catalog_without_authorization_header
    client = Kward::Client.new(api_key: "openrouter-token", openai_access_token: nil, oauth: FakeOAuth.new(nil), config_path: "missing_kward_config.json")
    body = JSON.dump("data" => [{ "id" => "google/gemini-pro" }, { "slug" => "meta/llama" }])

    with_fake_http([fake_net_response(200, body)]) do |http|
      models = client.openrouter_catalog

      assert_equal [
        { provider: "OpenRouter", id: "google/gemini-pro", current: false },
        { provider: "OpenRouter", id: "meta/llama", current: false }
      ], models
      assert_equal URI("https://openrouter.ai/api/v1/models"), http.requests.first.uri
      assert_nil http.requests.first["Authorization"]
    end
  end

  def test_copilot_available_models_use_live_model_ids_when_available
    Dir.mktmpdir do |dir|
      path = File.join(dir, "config.json")
      File.write(path, JSON.dump("provider" => "copilot", "copilot_model" => "stale-model"))
      client = Kward::Client.new(api_key: nil, openai_access_token: nil, oauth: FakeOAuth.new(nil), github_oauth: FakeGithubOAuth.new("github-token"), config_path: path)
      body = JSON.dump("data" => [
        { "id" => "gpt-5-mini-2025-08-07", "model_picker_enabled" => true },
        { "id" => "hidden-model", "model_picker_enabled" => false },
        { "id" => "gemini-3.1-pro-preview", "model_picker_enabled" => true }
      ])

      with_fake_http([fake_net_response(200, body)]) do |http|
        models = client.available_models
        cached_models = client.available_models

        assert_equal models, cached_models
        assert_includes models, { provider: "Copilot", id: "gpt-5-mini-2025-08-07", current: false }
        assert_includes models, { provider: "Copilot", id: "gemini-3.1-pro-preview", current: false }
        refute models.any? { |model| model[:provider] == "Copilot" && model[:id] == "hidden-model" }
        assert_includes models, { provider: "Copilot", id: "stale-model", current: true }
        assert_equal 1, http.requests.length
        assert_equal URI("https://api.individual.githubcopilot.com/models"), http.requests.first.uri
      end
    end
  end

  def test_copilot_chat_uses_responses_endpoint_for_gpt_5_models
    Dir.mktmpdir do |dir|
      path = File.join(dir, "config.json")
      File.write(path, JSON.dump("provider" => "copilot", "copilot_model" => "gpt-5-mini"))
      client = Kward::Client.new(api_key: nil, openai_access_token: nil, oauth: FakeOAuth.new(nil), github_oauth: FakeGithubOAuth.new("github-token"), config_path: path)
      models_body = JSON.dump("data" => [{ "id" => "gpt-5-mini", "model_picker_enabled" => true }])
      response_body = "data: #{JSON.dump("type" => "response.output_text.delta", "delta" => "ok")}\n\n"

      with_fake_http([fake_net_response(200, models_body), fake_net_response(200, response_body)]) do |http|
        message = client.chat([{ role: "user", content: "hello" }])

        assert_equal "ok", message["content"]
        assert_equal URI("https://api.individual.githubcopilot.com/responses"), http.requests.last.uri
        payload = JSON.parse(http.requests.last.body)
        assert_equal "gpt-5-mini", payload.fetch("model")
        assert_equal true, payload.fetch("stream")
        assert_equal false, payload.fetch("store")
        assert_equal({ "effort" => "medium", "summary" => "auto" }, payload.fetch("reasoning"))
      end
    end
  end

  def test_copilot_responses_payload_omits_reasoning_when_disabled
    client = Kward::Client.new(api_key: nil, openai_access_token: nil, oauth: FakeOAuth.new(nil), github_oauth: FakeGithubOAuth.new("github-token"), config_path: "missing_kward_config.json")

    payload = client.send(:request_body_payload, "Copilot", [{ role: "user", content: "hello" }], [], model: "gpt-5-mini", reasoning: false)

    refute payload.key?(:reasoning)
  end

  def test_copilot_chat_payload_does_not_include_reasoning_for_gemini_models
    client = Kward::Client.new(api_key: nil, openai_access_token: nil, oauth: FakeOAuth.new(nil), github_oauth: FakeGithubOAuth.new("github-token"), config_path: "missing_kward_config.json")

    payload = client.send(:request_body_payload, "Copilot", [{ role: "user", content: "hello" }], [], model: "gemini-2.5-pro")

    refute payload.key?(:reasoning)
  end

  def test_copilot_chat_uses_first_live_model_when_configured_model_is_unavailable
    Dir.mktmpdir do |dir|
      path = File.join(dir, "config.json")
      File.write(path, JSON.dump("provider" => "copilot", "copilot_model" => "stale-model"))
      client = Kward::Client.new(api_key: nil, openai_access_token: nil, oauth: FakeOAuth.new(nil), github_oauth: FakeGithubOAuth.new("github-token"), config_path: path)
      models_body = JSON.dump("data" => [{ "id" => "gemini-3.1-pro-preview", "model_picker_enabled" => true }])
      chat_body = "data: #{JSON.dump("choices" => [{ "delta" => { "content" => "ok" } }])}\n\n"

      with_fake_http([fake_net_response(200, models_body), fake_net_response(200, chat_body)]) do |http|
        message = client.chat([{ role: "user", content: "hello" }])

        assert_equal "ok", message["content"]
        assert_equal URI("https://api.individual.githubcopilot.com/chat/completions"), http.requests.last.uri
        assert_equal "gemini-3.1-pro-preview", JSON.parse(http.requests.last.body).fetch("model")
      end
    end
  end

  def test_copilot_chat_reports_when_only_unsupported_live_models_are_available
    Dir.mktmpdir do |dir|
      path = File.join(dir, "config.json")
      File.write(path, JSON.dump("provider" => "copilot", "copilot_model" => "stale-model"))
      client = Kward::Client.new(api_key: nil, openai_access_token: nil, oauth: FakeOAuth.new(nil), github_oauth: FakeGithubOAuth.new("github-token"), config_path: path)
      models_body = JSON.dump("data" => [{ "id" => "claude-sonnet-4.6", "model_picker_enabled" => true }])

      with_fake_http([fake_net_response(200, models_body)]) do
        error = assert_raises(RuntimeError) do
          client.chat([{ role: "user", content: "hello" }])
        end

        assert_includes error.message, "No Copilot models supported by Kward are available"
      end
    end
  end

  def test_openrouter_defaults_to_openai_gpt_5_5
    with_env("OPENROUTER_MODEL" => nil) do
      client = Kward::Client.new(api_key: "token", openai_access_token: nil, oauth: FakeOAuth.new(nil), config_path: "missing_kward_config.json")

      payload = client.send(:request_payload, "OpenRouter", [{ role: "user", content: "hello" }], [])

      assert_equal "openai/gpt-5.5", payload[:model]
      assert_equal({ effort: "medium" }, payload[:reasoning])
      refute payload.key?(:reasoning_effort)
    end
  end

  def test_openrouter_payload_reads_reasoning_effort_from_config
    Dir.mktmpdir do |dir|
      path = File.join(dir, "config.json")
      File.write(path, JSON.dump("openrouter_reasoning_effort" => "high"))
      client = Kward::Client.new(api_key: "token", openai_access_token: nil, oauth: FakeOAuth.new(nil), config_path: path)

      payload = client.send(:request_payload, "OpenRouter", [{ role: "user", content: "hello" }], [])

      assert_equal({ effort: "high" }, payload[:reasoning])
    end
  end

  def test_openrouter_payload_omits_reasoning_when_disabled
    client = Kward::Client.new(api_key: "token", openai_access_token: nil, oauth: FakeOAuth.new(nil))

    payload = client.send(:request_payload, "OpenRouter", [{ role: "user", content: "hello" }], [], reasoning: false)

    refute payload.key?(:reasoning)
  end

  def test_openrouter_payload_includes_max_tokens_when_limited
    client = Kward::Client.new(api_key: "token", openai_access_token: nil, oauth: FakeOAuth.new(nil))

    payload = client.send(:request_payload, "OpenRouter", [{ role: "user", content: "hello" }], [], max_tokens: 1234)

    assert_equal 1234, payload[:max_tokens]
  end

  def test_openai_oauth_takes_precedence_over_openrouter_env
    client = Kward::Client.new(api_key: "openrouter-token", openai_access_token: nil, oauth: FakeOAuth.new("oauth-token"))

    url, token, provider = client.send(:credentials)

    assert_equal Kward::Client::CODEX_URL, url
    assert_equal "oauth-token", token
    assert_equal "Codex", provider
  end

  def test_explicit_openrouter_reports_missing_openrouter_key
    Dir.mktmpdir do |dir|
      path = File.join(dir, "config.json")
      File.write(path, JSON.dump("provider" => "openrouter"))
      client = Kward::Client.new(api_key: nil, openai_access_token: nil, oauth: FakeOAuth.new(nil), config_path: path)

      error = assert_raises(RuntimeError) do
        client.chat([{ role: "user", content: "hello" }])
      end

      assert_equal Kward::Client::OPENROUTER_AUTH_ERROR, error.message
    end
  end

  def test_explicit_copilot_reports_missing_copilot_login
    Dir.mktmpdir do |dir|
      path = File.join(dir, "config.json")
      File.write(path, JSON.dump("provider" => "copilot"))
      client = Kward::Client.new(api_key: nil, openai_access_token: nil, oauth: FakeOAuth.new(nil), github_oauth: FakeGithubOAuth.new(nil), config_path: path)

      error = assert_raises(RuntimeError) do
        client.chat([{ role: "user", content: "hello" }])
      end

      assert_equal Kward::Client::COPILOT_AUTH_ERROR, error.message
    end
  end

  def test_openrouter_provider_is_explicit_and_uses_openrouter_even_with_openai_token
    Dir.mktmpdir do |dir|
      path = File.join(dir, "config.json")
      File.write(path, JSON.dump("provider" => "openrouter", "openrouter_model" => "provider/configured"))
      client = Kward::Client.new(api_key: "openrouter-token", openai_access_token: "openai-token", oauth: FakeOAuth.new("oauth-token"), config_path: path)

      url, token, provider = client.send(:credentials)

      assert_equal Kward::Client::OPENROUTER_URL, url
      assert_equal "openrouter-token", token
      assert_equal "OpenRouter", provider
      assert_equal "OpenRouter", client.current_provider
      assert_equal "provider/configured", client.current_model
    end
  end

  def test_openrouter_is_fallback_when_no_openai_oauth_exists
    client = Kward::Client.new(api_key: "openrouter-token", openai_access_token: nil, oauth: FakeOAuth.new(nil))

    url, token, provider = client.send(:credentials)

    assert_equal Kward::Client::OPENROUTER_URL, url
    assert_equal "openrouter-token", token
    assert_equal "OpenRouter", provider
  end

  def test_copilot_provider_is_explicit_and_uses_copilot_chat_endpoint
    Dir.mktmpdir do |dir|
      path = File.join(dir, "config.json")
      File.write(path, JSON.dump("provider" => "copilot"))
      github_oauth = Object.new
      github_oauth.define_singleton_method(:access_token) { "github-token" }
      github_oauth.define_singleton_method(:base_url) { "https://api.individual.githubcopilot.com" }
      client = Kward::Client.new(api_key: "openrouter-token", openai_access_token: "openai-token", oauth: FakeOAuth.new("oauth-token"), github_oauth: github_oauth, config_path: path)

      url, token, provider = client.send(:credentials)

      assert_equal URI("https://api.individual.githubcopilot.com/chat/completions"), url
      assert_equal "github-token", token
      assert_equal "Copilot", provider
      assert_equal "Copilot", client.current_provider
      assert_equal "gpt-5-mini", client.current_model
    end
  end

  def test_in_flight_steer_supported_for_codex_provider
    client = Kward::Client.new(api_key: nil, openai_access_token: "token", oauth: FakeOAuth.new(nil))

    assert_equal true, client.supports_in_flight_steer?
  end

  def test_in_flight_steer_not_supported_for_openrouter_provider
    client = Kward::Client.new(api_key: "openrouter-token", openai_access_token: nil, oauth: FakeOAuth.new(nil))

    assert_equal false, client.supports_in_flight_steer?
  end

  def test_openai_access_token_takes_precedence_over_saved_oauth
    client = Kward::Client.new(api_key: nil, openai_access_token: "env-token", oauth: FakeOAuth.new("oauth-token"))

    _url, token, provider = client.send(:credentials)

    assert_equal "env-token", token
    assert_equal "Codex", provider
  end

  def test_chat_rejects_images_for_model_without_image_support_before_request
    client = Kward::Client.new(api_key: nil, openai_access_token: "token", oauth: FakeOAuth.new(nil), model: "gpt-5.3-codex-spark", config_path: "missing_kward_config.json")
    messages = [{ role: "user", content: [{ type: "text", text: "look" }, { type: "image", media_type: "image/png", data: Base64.strict_encode64("png") }] }]

    with_fake_http([fake_net_response(200, "")]) do |http|
      error = assert_raises(RuntimeError) do
        client.chat(messages)
      end

      assert_empty http.requests
      assert_equal "Model 'gpt-5.3-codex-spark' does not support image inputs. Switch to a vision-capable model or remove the image attachment.", error.message
    end
  end

  def test_codex_request_retries_transient_failure_and_reports_retry
    client = Kward::Client.new(api_key: nil, openai_access_token: "token", oauth: FakeOAuth.new(nil), config_path: "missing_kward_config.json")
    retries = []
    success = fake_net_response(200, "data: {\"type\":\"response.output_text.delta\",\"delta\":\"ok\"}\n\n")

    disable_sleep(client)
    with_fake_http([fake_net_response(503, "upstream connect error"), success]) do |http|
      message = client.chat([{ role: "user", content: "hello" }], on_retry: ->(event) { retries << event })

      assert_equal "ok", message["content"]
      assert_equal http.requests.first.body.bytesize, retries[0][:request_bytes]
    end

    assert_equal 1, retries.length
    assert_equal "Codex", retries[0][:provider]
    assert_equal 2, retries[0][:attempt]
    assert_equal 3, retries[0][:max_attempts]
    assert_equal 1, retries[0][:delay_seconds]
    assert_includes retries[0][:error], "Codex request failed: 503 upstream connect error"
  end

  def test_codex_request_exhaustion_uses_request_wording_not_oauth_wording
    client = Kward::Client.new(api_key: nil, openai_access_token: "token", oauth: FakeOAuth.new(nil), config_path: "missing_kward_config.json")

    error = nil
    disable_sleep(client)
    with_fake_http([fake_net_response(503, "upstream connect error"), fake_net_response(503, "upstream connect error"), fake_net_response(503, "upstream connect error")]) do |_http|
      error = assert_raises(RuntimeError) do
        client.chat([{ role: "user", content: "hello" }])
      end
    end

    assert_includes error.message, "Codex request failed after 3 attempts: 503 upstream connect error"
    refute_includes error.message, "Codex OAuth request failed"
  end

  def test_codex_sse_server_error_retries_and_redacts_response_details
    client = Kward::Client.new(api_key: nil, openai_access_token: "token", oauth: FakeOAuth.new(nil), config_path: "missing_kward_config.json")
    retries = []
    failure_event = {
      "type" => "response.failed",
      "response" => {
        "error" => { "code" => "server_error", "message" => "retry me" },
        "instructions" => "secret prompt"
      }
    }
    failure = fake_net_response(200, "data: #{JSON.dump(failure_event)}\n\n")
    success = fake_net_response(200, "data: {\"type\":\"response.output_text.delta\",\"delta\":\"ok\"}\n\n")

    disable_sleep(client)
    with_fake_http([failure, success]) do |_http|
      message = client.chat([{ role: "user", content: "hello" }], on_retry: ->(event) { retries << event })

      assert_equal "ok", message["content"]
    end

    assert_equal 1, retries.length
    assert_includes retries[0][:error], "Codex request failed: 500 response.failed: server_error: retry me"
    refute_includes retries[0][:error], "secret prompt"
    refute_includes retries[0][:error], "instructions"
  end

  def test_codex_sse_failure_error_is_concise
    client = Kward::Client.new(api_key: nil, openai_access_token: "env-token", oauth: FakeOAuth.new(nil))
    event = {
      "type" => "response.failed",
      "response" => {
        "error" => { "code" => "bad_request", "message" => "bad input" },
        "instructions" => "secret prompt"
      }
    }

    error = assert_raises(Kward::Client::RequestError) do
      client.send(:parse_codex_sse, "data: #{JSON.dump(event)}\n\n")
    end

    assert_includes error.message, "Codex request failed: 400 response.failed: bad_request: bad input"
    refute_includes error.message, "secret prompt"
    refute_includes error.message, "instructions"
  end

  def test_openrouter_retries_429_and_does_not_retry_401
    client = Kward::Client.new(api_key: "token", openai_access_token: nil, oauth: FakeOAuth.new(nil), config_path: "missing_kward_config.json")
    success_body = JSON.dump("choices" => [{ "message" => { "role" => "assistant", "content" => "ok" } }])
    retries = []

    disable_sleep(client)
    with_fake_http([fake_net_response(429, "slow down"), fake_net_response(200, success_body)]) do |_http|
      message = client.chat([{ role: "user", content: "hello" }], on_retry: ->(event) { retries << event })

      assert_equal "ok", message["content"]
    end

    assert_equal 1, retries.length
    assert_equal "OpenRouter", retries[0][:provider]
    assert_operator retries[0][:request_bytes], :>, 0

    with_fake_http([fake_net_response(401, "bad token")]) do |http|
      error = assert_raises(Kward::Client::RequestError) do
        client.chat([{ role: "user", content: "hello" }])
      end

      assert_equal 1, http.requests.length
      assert_includes error.message, "OpenRouter request failed: 401 bad token"
    end
  end

  def test_openrouter_does_not_retry_provider_quota_429
    client = Kward::Client.new(api_key: "token", openai_access_token: nil, oauth: FakeOAuth.new(nil), config_path: "missing_kward_config.json")
    retries = []

    disable_sleep(client)
    with_fake_http([fake_net_response(429, JSON.dump("error" => { "message" => "Monthly usage limit reached" }))]) do |http|
      error = assert_raises(Kward::Client::RequestError) do
        client.chat([{ role: "user", content: "hello" }], on_retry: ->(event) { retries << event })
      end

      assert_equal 1, http.requests.length
      assert_empty retries
      assert error.provider_limit?
      refute error.transient?
    end
  end

  def test_context_overflow_request_error_is_not_transient
    error = Kward::Client::RequestError.new(
      provider: "OpenRouter",
      code: 429,
      body: "Your request has too many tokens for the model context window."
    )

    assert error.context_overflow?
    refute error.transient?
  end

  def test_openrouter_chat_logs_token_usage_when_enabled
    Dir.mktmpdir do |dir|
      config_path = File.join(dir, "config.json")
      File.write(config_path, JSON.dump("logging" => { "enabled" => true, "tokens" => true, "performance" => true }))
      client = Kward::Client.new(api_key: "token", openai_access_token: nil, oauth: FakeOAuth.new(nil), config_path: config_path)
      body = JSON.dump(
        "choices" => [{ "message" => { "role" => "assistant", "content" => "ok" } }],
        "usage" => { "prompt_tokens" => 42, "completion_tokens" => 7, "total_tokens" => 49 }
      )

      with_fake_http([fake_net_response(200, body)]) do |_http|
        client.chat([{ role: "user", content: "do not log this prompt" }])
      end

      records = Dir[File.join(dir, "logs", "*.jsonl")].flat_map { |path| jsonl_records(path) }
      token_record = records.find { |record| record["category"] == "tokens" && record["event"] == "model_usage" }
      performance_record = records.find { |record| record["category"] == "performance" && record["event"] == "model_request" }
      assert_equal "OpenRouter", token_record["provider"]
      assert_equal 49, token_record["usage"]["total_tokens"]
      assert_equal "completed", performance_record["status"]
      refute_includes records.map(&:to_json).join("\n"), "do not log this prompt"
    end
  end

  def test_openrouter_chat_persists_provider_model_and_usage
    client = Kward::Client.new(api_key: "token", openai_access_token: nil, oauth: FakeOAuth.new(nil), config_path: "missing_kward_config.json")
    body = JSON.dump(
      "choices" => [{ "message" => { "role" => "assistant", "content" => "ok" } }],
      "usage" => {
        "prompt_tokens" => 42,
        "completion_tokens" => 7,
        "total_tokens" => 49,
        "prompt_tokens_details" => { "cached_tokens" => 5 }
      }
    )

    with_fake_http([fake_net_response(200, body)]) do |_http|
      message = client.chat([{ role: "user", content: "hello" }])

      assert_equal "OpenRouter", message["provider"]
      assert_equal "openai/gpt-5.5", message["model"]
      assert_equal({
        "input_tokens" => 42,
        "output_tokens" => 7,
        "cache_read_tokens" => 5,
        "cache_write_tokens" => 0,
        "total_tokens" => 49,
        "estimated" => false
      }, message["usage"])
    end
  end

  def test_openrouter_payload_strips_persisted_assistant_metadata
    client = Kward::Client.new(api_key: "token", openai_access_token: nil, oauth: FakeOAuth.new(nil), config_path: "missing_kward_config.json")
    assistant = {
      "role" => "assistant",
      "content" => "ok",
      "provider" => "OpenRouter",
      "model" => "openai/gpt-5.5",
      "usage" => { "total_tokens" => 49 },
      "tool_calls" => [tool_call("read_file", "path" => "README.md")]
    }

    payload = client.send(:request_payload, "OpenRouter", [{ role: "user", content: "hello" }, assistant], [])
    sent_assistant = payload[:messages].last

    assert_equal "assistant", sent_assistant[:role]
    assert_equal "ok", sent_assistant[:content]
    assert_equal assistant["tool_calls"], sent_assistant[:tool_calls]
    refute sent_assistant.key?(:provider)
    refute sent_assistant.key?(:model)
    refute sent_assistant.key?(:usage)
  end

  def test_codex_sse_parses_text_response
    client = Kward::Client.new(api_key: nil, openai_access_token: "env-token", oauth: FakeOAuth.new(nil))
    body = "data: {\"type\":\"response.output_text.delta\",\"delta\":\"hi\"}\n\n" \
      "data: {\"type\":\"response.completed\",\"response\":{}}\n\n"

    message = client.send(:parse_codex_sse, body)

    assert_equal "assistant", message["role"]
    assert_equal "hi", message["content"]
  end

  def test_codex_sse_parses_reasoning_summary
    client = Kward::Client.new(api_key: nil, openai_access_token: "env-token", oauth: FakeOAuth.new(nil))
    deltas = []
    body = "data: {\"type\":\"response.reasoning_summary_text.delta\",\"delta\":\"thinking\"}\n\n" \
      "data: {\"type\":\"response.output_text.delta\",\"delta\":\"hi\"}\n\n"

    message = client.send(:parse_codex_sse, body, on_reasoning_delta: ->(delta) { deltas << delta })

    assert_equal "thinking", message["reasoning_summary"]
    assert_equal ["thinking"], deltas
  end

  def test_codex_sse_parses_response_usage
    client = Kward::Client.new(api_key: nil, openai_access_token: "env-token", oauth: FakeOAuth.new(nil))
    event = {
      "type" => "response.completed",
      "response" => {
        "usage" => {
          "input_tokens" => 100,
          "output_tokens" => 20,
          "total_tokens" => 120,
          "input_tokens_details" => { "cached_tokens" => 10 }
        }
      }
    }

    message = client.send(:parse_codex_sse, "data: #{JSON.dump(event)}\n\n")

    assert_equal({
      "input_tokens" => 100,
      "output_tokens" => 20,
      "cache_read_tokens" => 10,
      "cache_write_tokens" => 0,
      "total_tokens" => 120,
      "estimated" => false
    }, message["usage"])
  end

  def test_codex_sse_parses_tool_call
    client = Kward::Client.new(api_key: nil, openai_access_token: "env-token", oauth: FakeOAuth.new(nil))
    event = {
      "type" => "response.output_item.done",
      "item" => {
        "type" => "function_call",
        "call_id" => "call_1",
        "name" => "list_directory",
        "arguments" => JSON.dump("path" => ".")
      }
    }
    body = "data: #{JSON.dump(event)}\n\n"

    message = client.send(:parse_codex_sse, body)

    assert_equal "call_1", message["tool_calls"].first["id"]
    assert_equal "list_directory", message["tool_calls"].first["function"]["name"]
  end

end
