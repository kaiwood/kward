require "json"
require_relative "test_helper"

class TestPluginCodexResponses < KwardTestCase
  def test_stream_sends_nonstored_codex_request_and_yields_parsed_events
    request_body = nil
    authorization = nil
    server = Kward::PluginHTTPServer.new do |request, response|
      request_body = JSON.parse(request.body)
      authorization = request["authorization"]
      response["Content-Type"] = "text/event-stream"
      response.body = <<~SSE
        event: response.output_text.delta
        data: {"type":"response.output_text.delta","delta":"hello"}

        event: response.completed
        data: {"type":"response.completed","response":{"usage":{"input_tokens":2,"output_tokens":1}}}

      SSE
    end
    server.start
    oauth = Struct.new(:access_token).new("synthetic-token")
    client = Kward::PluginCodexResponses.new(oauth: oauth, endpoint: "http://127.0.0.1:#{server.port}/v1/responses")
    events = []

    client.stream(model: "gpt-5-mini", input: [{ role: "user", content: "hello" }], text: { format: { type: "json_object" } }) do |event|
      events << event
    end

    assert_equal "Bearer synthetic-token", authorization
    assert_equal({ "model" => "gpt-5-mini", "input" => [{ "role" => "user", "content" => "hello" }], "store" => false, "stream" => true, "text" => { "format" => { "type" => "json_object" } } }, request_body)
    assert_equal ["response.output_text.delta", "response.completed"], events.map { |event| event.fetch("type") }
  ensure
    server&.stop
  end

  def test_upstream_http_errors_do_not_include_response_body_or_token
    server = Kward::PluginHTTPServer.new do |_request, response|
      response.status = 401
      response.body = "synthetic secret response"
    end
    server.start
    client = Kward::PluginCodexResponses.new(oauth: Struct.new(:access_token).new("synthetic-token"), endpoint: "http://127.0.0.1:#{server.port}/")

    error = assert_raises(Kward::PluginCodexResponses::RequestError) do
      client.stream(model: "model", input: []) { |_event| }
    end

    assert_equal 401, error.status
    refute_includes error.message, "synthetic"
  ensure
    server&.stop
  end

  def test_missing_oauth_token_fails_before_network_access
    client = Kward::PluginCodexResponses.new(oauth: Struct.new(:access_token).new(nil))

    assert_raises(Kward::PluginCodexResponses::AuthenticationError) do
      client.stream(model: "model", input: []) { |_event| }
    end
  end

  def test_stream_must_end_with_a_terminal_responses_event
    server = Kward::PluginHTTPServer.new do |_request, response|
      response["Content-Type"] = "text/event-stream"
      response.body = "data: {\"type\":\"response.output_text.delta\",\"delta\":\"partial\"}\n\n"
    end
    server.start
    client = Kward::PluginCodexResponses.new(oauth: Struct.new(:access_token).new("token"), endpoint: "http://127.0.0.1:#{server.port}/")

    error = assert_raises(StandardError) do
      client.stream(model: "model", input: []) { |_event| }
    end
    assert_includes error.message, "without a terminal event"
  ensure
    server&.stop
  end
end
