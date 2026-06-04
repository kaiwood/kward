require_relative "test_helper"

class TestClient < KwardTestCase
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
    path = "kward_test_config.json"
    File.write(path, JSON.dump("openai_model" => "gpt-config", "openai_reasoning_effort" => "high"))
    client = Kward::Client.new(api_key: nil, openai_access_token: "token", oauth: FakeOAuth.new(nil), config_path: path)

    payload = client.send(:codex_payload, [{ role: "user", content: "hello" }], [])

    assert_equal "gpt-config", payload[:model]
    assert_equal({ effort: "high", summary: "auto" }, payload[:reasoning])
  ensure
    File.delete(path) if path && File.exist?(path)
  end

  def test_codex_payload_includes_max_output_tokens_when_limited
    client = Kward::Client.new(api_key: nil, openai_access_token: "token", oauth: FakeOAuth.new(nil), config_path: "missing_kward_config.json")

    payload = client.send(:codex_payload, [{ role: "user", content: "hello" }], [], max_tokens: 1234)

    assert_equal 1234, payload[:max_output_tokens]
  end

  def test_config_model_and_thinking_level_apply_to_current_provider
    path = "kward_test_config.json"
    File.write(path, JSON.dump("model" => "configured-model", "thinking_level" => "low"))
    client = Kward::Client.new(api_key: nil, openai_access_token: "token", oauth: FakeOAuth.new(nil), config_path: path)

    payload = client.send(:codex_payload, [{ role: "user", content: "hello" }], [])

    assert_equal "configured-model", payload[:model]
    assert_equal({ effort: "low", summary: "auto" }, payload[:reasoning])
  ensure
    File.delete(path) if path && File.exist?(path)
  end

  def test_openrouter_reads_model_from_config
    path = "kward_test_config.json"
    File.write(path, JSON.dump("openrouter_model" => "provider/configured"))
    client = Kward::Client.new(api_key: "token", openai_access_token: nil, oauth: FakeOAuth.new(nil), config_path: path)

    payload = client.send(:request_payload, "OpenRouter", [{ role: "user", content: "hello" }], [])

    assert_equal "provider/configured", payload[:model]
  ensure
    File.delete(path) if path && File.exist?(path)
  end

  def test_openrouter_defaults_to_openai_gpt_5_5
    client = Kward::Client.new(api_key: "token", openai_access_token: nil, oauth: FakeOAuth.new(nil))

    payload = client.send(:request_payload, "OpenRouter", [{ role: "user", content: "hello" }], [])

    assert_equal "openai/gpt-5.5", payload[:model]
    refute payload.key?(:reasoning_effort)
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

  def test_openrouter_is_fallback_when_no_openai_oauth_exists
    client = Kward::Client.new(api_key: "openrouter-token", openai_access_token: nil, oauth: FakeOAuth.new(nil))

    url, token, provider = client.send(:credentials)

    assert_equal Kward::Client::OPENROUTER_URL, url
    assert_equal "openrouter-token", token
    assert_equal "OpenRouter", provider
  end

  def test_openai_access_token_takes_precedence_over_saved_oauth
    client = Kward::Client.new(api_key: nil, openai_access_token: "env-token", oauth: FakeOAuth.new("oauth-token"))

    _url, token, provider = client.send(:credentials)

    assert_equal "env-token", token
    assert_equal "Codex", provider
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
