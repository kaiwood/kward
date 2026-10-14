require "net/http"
require_relative "../examples/plugins/openrouter_proxy/server"
require_relative "test_helper"

class TestOpenRouterProxyServer < KwardTestCase
  class FakeCodex
    attr_reader :requests

    def initialize(events:)
      @events = events
      @requests = []
    end

    def stream(**request)
      @requests << request
      @events.each { |event| yield event }
    end
  end

  def setup
    @directory = Dir.mktmpdir
    @host = Kward::PluginHost.new(
      id: "com.kward.openrouter-proxy",
      version: "1.0.0",
      api_version: "1",
      config: {
        "api_key" => "local-test-key",
        "model_map" => { "openai/gpt-5-mini" => "gpt-5-mini" },
        "fake_embedding_models" => { "kward/fake-embedding-8" => 8 }
      },
      storage_root: @directory
    )
  end

  def teardown
    @host&.shutdown
    FileUtils.remove_entry(@directory) if @directory && File.exist?(@directory)
  end

  def test_nonstream_chat_completion_is_authenticated_and_translated
    codex = FakeCodex.new(events: [
      { "type" => "response.output_text.delta", "delta" => "{\"ok\":true}" },
      { "type" => "response.completed", "response" => { "id" => "resp_fake", "usage" => { "input_tokens" => 4, "output_tokens" => 3 } } }
    ])
    server, uri = start_proxy(codex)

    response = post(uri, request_payload)

    assert_equal "200", response.code
    completion = JSON.parse(response.body)
    assert_equal "chat.completion", completion["object"]
    assert_equal "{\"ok\":true}", completion.dig("choices", 0, "message", "content")
    assert_equal "openai/gpt-5-mini", completion["model"]
    assert_equal 7, completion.dig("usage", "total_tokens")
    assert_equal "gpt-5-mini", codex.requests.first[:model]
  ensure
    server&.stop
  end

  def test_fake_embeddings_are_authenticated_deterministic_and_do_not_call_codex
    codex = FakeCodex.new(events: [])
    server, uri = start_proxy(codex, path: "/api/v1/embeddings")
    payload = { "model" => "kward/fake-embedding-8", "input" => ["alpha beta", "alpha beta"] }

    response = post(uri, payload)

    assert_equal "200", response.code
    body = JSON.parse(response.body)
    assert_equal "list", body["object"]
    assert_equal "kward/fake-embedding-8", body["model"]
    assert_equal 2, body["data"].length
    assert_equal body.dig("data", 0, "embedding"), body.dig("data", 1, "embedding")
    assert_equal 8, body.dig("data", 0, "embedding").length
    assert_in_delta 1.0, Math.sqrt(body.dig("data", 0, "embedding").sum { |value| value * value }), 1e-10
    assert_equal({ "prompt_tokens" => 4, "total_tokens" => 4 }, body["usage"])
    assert_empty codex.requests
  ensure
    server&.stop
  end

  def test_fake_embeddings_reject_unknown_models_and_unsupported_fields
    codex = FakeCodex.new(events: [])
    server, uri = start_proxy(codex, path: "/api/v1/embeddings")

    unknown_model = post(uri, { "model" => "not-configured", "input" => "text" })
    unsupported_field = post(uri, { "model" => "kward/fake-embedding-8", "input" => "text", "user" => "ignored" })

    assert_equal "400", unknown_model.code
    assert_equal "Fake embedding model is not configured", JSON.parse(unknown_model.body).dig("error", "message")
    assert_equal "400", unsupported_field.code
    assert_empty codex.requests
  ensure
    server&.stop
  end

  def test_chat_completion_passes_protocol_symbol_keyed_messages_to_kward_client
    client = Object.new
    client.define_singleton_method(:chat) do |_messages, **options|
      options.fetch(:on_assistant_delta).call(%q({"ok":true}))
      { "content" => %q({"ok":true}), "usage" => { "input_tokens" => 2, "output_tokens" => 3, "total_tokens" => 5 } }
    end
    codex = Kward::PluginCodexResponses.new(client: client)
    server, uri = start_proxy(codex)

    response = post(uri, request_payload)

    assert_equal "200", response.code
    completion = JSON.parse(response.body)
    assert_equal %q({"ok":true}), completion.dig("choices", 0, "message", "content")
    assert_equal 5, completion.dig("usage", "total_tokens")
  ensure
    server&.stop
  end

  def test_invalid_bearer_token_is_rejected_without_inference
    codex = FakeCodex.new(events: [])
    server, uri = start_proxy(codex)

    response = post(uri, request_payload, token: "wrong-token")

    assert_equal "401", response.code
    assert_equal "invalid_api_key", JSON.parse(response.body).dig("error", "code")
    assert_empty codex.requests
  ensure
    server&.stop
  end

  def test_streaming_response_uses_chat_completion_sse_and_done_marker
    codex = FakeCodex.new(events: [
      { "type" => "response.created" },
      { "type" => "response.output_text.delta", "delta" => "Hello" },
      { "type" => "response.completed", "response" => { "usage" => { "input_tokens" => 2, "output_tokens" => 1 } } }
    ])
    server, uri = start_proxy(codex)

    response = post(uri, request_payload.merge("stream" => true))

    assert_equal "200", response.code
    assert_includes response["content-type"], "text/event-stream"
    chunks = response.body.lines.filter_map do |line|
      JSON.parse(line.delete_prefix("data: ")) if line.start_with?("data: {")
    end
    assert_equal "assistant", chunks.first.dig("choices", 0, "delta", "role")
    assert_equal "Hello", chunks.find { |chunk| chunk.dig("choices", 0, "delta", "content") }&.dig("choices", 0, "delta", "content")
    assert_equal 3, chunks.find { |chunk| chunk.key?("usage") }.dig("usage", "total_tokens")
    assert_includes response.body, "data: [DONE]"
    assert_kind_of Kward::Cancellation, codex.requests.first[:cancellation]
  ensure
    server&.stop
  end

  def test_shipped_plugin_registers_the_documented_startup_option
    registry = Kward::PluginRegistry.load(paths: [File.expand_path("../examples/plugins/openrouter_proxy/plugin.rb", __dir__)])

    option = registry.startup_option_for("--openrouter-proxy")
    refute_nil option
    assert_equal "com.kward.openrouter-proxy", option.plugin_id
  end

  def test_pre_stream_upstream_failure_returns_json_gateway_error
    codex = Object.new
    def codex.stream(**_request)
      raise Kward::PluginCodexResponses::RequestError, 401
    end
    server, uri = start_proxy(codex)

    response = post(uri, request_payload.merge("stream" => true))

    assert_equal "502", response.code
    assert_equal "upstream_error", JSON.parse(response.body).dig("error", "code")
  ensure
    server&.stop
  end

  private

  def start_proxy(codex, path: "/api/v1/chat/completions")
    proxy = Kward::OpenRouterProxy::Server.new(host: @host, codex: codex, output: StringIO.new)
    listener = @host.http_server(port: 0) { |request, response| proxy.handle(request, response) }
    listener.start
    [listener, URI("http://127.0.0.1:#{listener.port}#{path}")]
  end

  def request_payload
    {
      "model" => "openai/gpt-5-mini",
      "messages" => [{ "role" => "user", "content" => "Return JSON" }],
      "response_format" => {
        "type" => "json_schema",
        "json_schema" => { "name" => "result", "strict" => true, "schema" => { "type" => "object" } }
      }
    }
  end

  def post(uri, payload, token: "local-test-key")
    request = Net::HTTP::Post.new(uri)
    request["Authorization"] = "Bearer #{token}"
    request["Content-Type"] = "application/json"
    request.body = JSON.generate(payload)
    Net::HTTP.start(uri.host, uri.port) { |http| http.request(request) }
  end
end
