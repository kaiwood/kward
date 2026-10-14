require_relative "../examples/plugins/openrouter_proxy/protocol"
require_relative "test_helper"

class TestOpenRouterProxyProtocol < KwardTestCase
  def setup
    @protocol = Kward::OpenRouterProxy::Protocol.new(model_map: { "openai/gpt-5-mini" => "gpt-5-mini" })
  end

  def test_translates_chat_completion_request_with_strict_schema_to_responses_api
    request = @protocol.parse_request(
      "model" => "openai/gpt-5-mini",
      "messages" => [
        { "role" => "system", "content" => "Use the schema." },
        { "role" => "user", "content" => "Produce JSON." }
      ],
      "response_format" => {
        "type" => "json_schema",
        "json_schema" => {
          "name" => "answer",
          "strict" => true,
          "schema" => { "type" => "object", "properties" => { "answer" => { "type" => "string" } } }
        }
      }
    )

    assert_equal "gpt-5-mini", request.model
    assert_equal "Use the schema.", request.instructions
    assert_equal [{ role: "user", content: "Produce JSON." }], request.input
    assert_equal({
      model: "gpt-5-mini",
      input: [{ role: "user", content: "Produce JSON." }],
      instructions: "Use the schema.",
      text: { format: { type: "json_schema", name: "answer", schema: { "type" => "object", "properties" => { "answer" => { "type" => "string" } } }, strict: true } }
    }, @protocol.responses_request(request))
  end

  def test_maps_completed_response_events_to_openai_chat_completion
    request = @protocol.parse_request("model" => "openai/gpt-5-mini", "messages" => [{ "role" => "user", "content" => "Hi" }])
    response = @protocol.chat_completion(request, [
      { "type" => "response.output_text.delta", "delta" => "Hello" },
      { "type" => "response.completed", "response" => { "id" => "resp_test", "usage" => { "input_tokens" => 4, "output_tokens" => 2, "total_tokens" => 6 } } }
    ])

    assert_equal "chatcmpl-resp_test", response[:id]
    assert_equal "chat.completion", response[:object]
    assert_equal "openai/gpt-5-mini", response[:model]
    assert_equal "Hello", response.dig(:choices, 0, :message, :content)
    assert_equal "stop", response.dig(:choices, 0, :finish_reason)
    assert_equal({ prompt_tokens: 4, completion_tokens: 2, total_tokens: 6 }, response[:usage])
  end

  def test_formats_responses_events_as_chat_completion_sse_chunks
    request = @protocol.parse_request("model" => "openai/gpt-5-mini", "messages" => [{ "role" => "user", "content" => "Hi" }], "stream" => true)
    state = @protocol.stream_state(request)

    assert_equal "assistant", @protocol.stream_start_chunk(state).dig(:choices, 0, :delta, :role)
    text = @protocol.stream_chunks(state, "type" => "response.output_text.delta", "delta" => "Hello").first
    assert_equal "Hello", text.dig(:choices, 0, :delta, :content)
    assert_nil text.dig(:choices, 0, :finish_reason)

    final_chunks = @protocol.stream_chunks(state, "type" => "response.completed", "response" => { "usage" => { "input_tokens" => 2, "output_tokens" => 1 } })
    assert_equal "stop", final_chunks.first.dig(:choices, 0, :finish_reason)
    assert_equal({ prompt_tokens: 2, completion_tokens: 1, total_tokens: 3 }, final_chunks.last[:usage])
    assert_empty @protocol.stream_chunks(state, "type" => "response.output_text.delta", "delta" => "late")
  end

  def test_streaming_provider_failure_uses_openai_compatible_error_chunk
    request = @protocol.parse_request("model" => "openai/gpt-5-mini", "messages" => [{ "role" => "user", "content" => "Hi" }], "stream" => true)
    state = @protocol.stream_state(request)
    chunk = @protocol.stream_chunks(state, "type" => "response.failed").first

    assert_equal "error", chunk.dig(:choices, 0, :finish_reason)
    assert_equal "server_error", chunk.dig(:error, :code)
    assert_equal "Codex response did not complete", chunk.dig(:error, :message)
  end

  def test_rejects_unknown_models_fields_and_unsupported_message_content
    assert_request_error("Model is not configured") do
      @protocol.parse_request("model" => "not-configured", "messages" => [{ "role" => "user", "content" => "Hi" }])
    end
    assert_request_error("Unsupported request fields") do
      @protocol.parse_request("model" => "openai/gpt-5-mini", "messages" => [{ "role" => "user", "content" => "Hi" }], "temperature" => 0)
    end
    assert_request_error("Message 0") do
      @protocol.parse_request("model" => "openai/gpt-5-mini", "messages" => [{ "role" => "user", "content" => [{ "type" => "text", "text" => "Hi" }] }])
    end
  end

  def test_maps_noncompleted_upstream_responses_to_gateway_error
    request = @protocol.parse_request("model" => "openai/gpt-5-mini", "messages" => [{ "role" => "user", "content" => "Hi" }])

    error = assert_raises(Kward::OpenRouterProxy::RequestError) do
      @protocol.chat_completion(request, [{ "type" => "response.failed" }])
    end
    assert_equal 502, error.status
  end

  private

  def assert_request_error(message)
    error = assert_raises(Kward::OpenRouterProxy::RequestError) { yield }
    assert_includes error.message, message
  end
end
