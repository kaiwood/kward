require_relative "test_helper"
require_relative "../lib/kward/plugins/codex_responses"

class TestPluginCodexResponses < KwardTestCase
  class FakeModelClient
    attr_reader :calls

    def initialize(result: { "content" => "hello", "usage" => { "input_tokens" => 2, "output_tokens" => 1, "total_tokens" => 3 } }, error: nil)
      @result = result
      @error = error
      @calls = []
    end

    def chat(messages, **options)
      @calls << { messages: messages, options: options }
      raise @error if @error

      options[:on_assistant_delta]&.call("hel")
      options[:on_assistant_delta]&.call("lo")
      @result
    end
  end

  def test_stream_uses_kward_codex_provider_and_translates_to_responses_events
    client = FakeModelClient.new
    adapter = Kward::PluginCodexResponses.new(client: client)
    events = []
    text_format = { format: { type: "json_schema", name: "result", schema: { type: "object" }, strict: true } }

    adapter.stream(
      model: "gpt-6-luna",
      input: [{ role: "user", content: "hello" }],
      instructions: "Answer briefly.",
      text: text_format,
      max_output_tokens: 120,
      cancellation: Kward::Cancellation.new
    ) { |event| events << event }

    call = client.calls.first
    assert_equal [
      { role: "system", content: "Answer briefly." },
      { role: "user", content: "hello" }
    ], call[:messages]
    assert_equal "codex", call.dig(:options, :provider)
    assert call.dig(:options, :provider_required)
    assert_equal "gpt-6-luna", call.dig(:options, :model)
    assert_equal 120, call.dig(:options, :max_tokens)
    assert_equal text_format, call.dig(:options, :text_format)
    assert_equal ["hel", "lo"], events.select { |event| event["type"] == "response.output_text.delta" }.map { |event| event["delta"] }
    assert_equal "response.completed", events.last["type"]
    assert_equal({ "input_tokens" => 2, "output_tokens" => 1, "total_tokens" => 3 }, events.last.dig("response", "usage"))
  end

  def test_stream_emits_final_content_if_the_client_did_not_emit_deltas
    client = FakeModelClient.new(result: { "content" => "hello", "usage" => nil })
    client.define_singleton_method(:chat) do |_messages, **options|
      @calls << { messages: _messages, options: options }
      { "content" => "hello", "usage" => nil }
    end
    events = []

    Kward::PluginCodexResponses.new(client: client).stream(
      model: "gpt-6-luna",
      input: [{ role: "user", content: "hello" }]
    ) { |event| events << event }

    assert_equal [{ "type" => "response.output_text.delta", "delta" => "hello" }], events[0...-1]
  end

  def test_stream_maps_missing_kward_credentials_to_plugin_authentication_error
    error = Kward::Client::AuthenticationError.new(Kward::Client::AUTH_ERROR)
    adapter = Kward::PluginCodexResponses.new(client: FakeModelClient.new(error: error))

    wrapped = assert_raises(Kward::PluginCodexResponses::AuthenticationError) do
      adapter.stream(model: "gpt-6-luna", input: [{ "role" => "user", "content" => "hello" }]) { |_event| }
    end

    assert_equal Kward::Client::AUTH_ERROR, wrapped.message
  end

  def test_stream_maps_kward_upstream_status_to_plugin_request_error
    error = Kward::Client::RequestError.new(provider: "Codex", code: 401, body: "auth rejected")
    adapter = Kward::PluginCodexResponses.new(client: FakeModelClient.new(error: error))

    wrapped = assert_raises(Kward::PluginCodexResponses::RequestError) do
      adapter.stream(model: "gpt-6-luna", input: [{ "role" => "user", "content" => "hello" }]) { |_event| }
    end

    assert_equal 401, wrapped.status
    refute_includes wrapped.message, "auth rejected"
  end
end
