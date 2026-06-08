require "base64"
require "socket"
require_relative "test_helper"

class TestPanServer < KwardTestCase
  class PanStreamingClient
    attr_reader :seen_messages, :seen_tools

    def initialize(responses, delay: 0)
      @responses = responses
      @delay = delay
      @seen_messages = []
      @seen_tools = []
    end

    def chat(messages, tools: [], on_assistant_delta: nil, **_kwargs)
      @seen_messages << messages.map(&:dup)
      @seen_tools << tools.map { |tool| tool[:function][:name] }
      content = @responses.shift.to_s
      sleep @delay if @delay.positive?
      on_assistant_delta&.call(content)
      { "role" => "assistant", "content" => content }
    end
  end

  def test_pan_server_requires_basic_auth_config
    Dir.mktmpdir do |dir|
      error = assert_raises(RuntimeError) do
        Kward::PanServer.new(client: PanStreamingClient.new([]), working_directory: dir, config: {})
      end

      assert_includes error.message, "pan_mode.username"
    end
  end

  def test_pan_server_rejects_unauthorized_request
    Dir.mktmpdir do |dir|
      server = build_server(dir)
      response = request(server, "GET / HTTP/1.1\r\nHost: example\r\n\r\n")

      assert_includes response, "HTTP/1.1 401 Unauthorized"
      assert_includes response, "WWW-Authenticate: Basic realm=\"Kward pan mode\""
    end
  end

  def test_pan_server_serves_authenticated_page
    Dir.mktmpdir do |dir|
      server = build_server(dir)
      response = request(server, "GET / HTTP/1.1\r\nHost: example\r\n#{auth_header}\r\n\r\n")

      assert_includes response, "HTTP/1.1 200 OK"
      assert_includes response, "Kward Pan Mode"
      assert_includes response, "Workspace: #{File.realpath(dir)}"
    end
  end

  def test_pan_server_turn_endpoint_persists_and_streams_answer
    Dir.mktmpdir do |dir|
      client = PanStreamingClient.new(["reply"])
      server = build_server(dir, client: client)
      server.send(:start_worker)

      body = JSON.generate(prompt: "hello")
      response = request(server, "POST /turn HTTP/1.1\r\nHost: example\r\n#{auth_header}\r\nContent-Type: application/json\r\nContent-Length: #{body.bytesize}\r\n\r\n#{body}")
      wait_until { client.seen_messages.length == 1 }

      assert_includes response, "HTTP/1.1 202 Accepted"
      assert_equal "hello", client.seen_messages[0][1][:content]
      refute_includes client.seen_tools[0], "ask_user_question"
      records = jsonl_records(server.session.path)
      assert records.any? { |record| record["type"] == "message" && record["message"]["role"] == "user" && record["message"]["content"] == "hello" }
      assert records.any? { |record| record["type"] == "message" && record["message"]["role"] == "assistant" && record["message"]["content"] == "reply" }
    ensure
      stop_worker(server)
    end
  end

  def test_pan_server_transcript_restores_reasoning_and_tools
    Dir.mktmpdir do |dir|
      server = build_server(dir)
      conversation = server.instance_variable_get(:@conversation)
      conversation.messages << {
        role: "assistant",
        content: [
          { type: "thinking", thinking: "checking sensors" },
          { type: "text", text: "ready" }
        ],
        tool_calls: [tool_call("read_file", path: "README.md")]
      }
      conversation.append_tool(tool_call_id: "call_read_file", name: "read_file", content: "README contents")

      transcript = server.transcript_items

      assert_includes transcript, { role: "reasoning", label: "Reasoning", text: "checking sensors" }
      assert_includes transcript, { role: "assistant", label: "Assistant", text: "ready" }
      assert_includes transcript, { role: "tool", label: "Tool", text: "read {\"path\":\"README.md\"}" }
      assert_includes transcript, { role: "tool", label: "Tool output", text: "read: README contents" }
    end
  end

  def test_pan_server_queues_prompt_while_active
    Dir.mktmpdir do |dir|
      client = PanStreamingClient.new(["one", "two"], delay: 0.1)
      server = build_server(dir, client: client)
      server.send(:start_worker)

      server.enqueue_prompt("first")
      wait_until { server.send(:active?) }
      result = server.enqueue_prompt("second")

      assert_equal true, result[:ok]
      assert_equal true, result[:active]
      assert_operator result[:queued], :>=, 1
      wait_until { client.seen_messages.length == 2 }
      assert_equal "first", client.seen_messages[0][1][:content]
      assert_equal "second", client.seen_messages[1].last[:content]
    ensure
      stop_worker(server)
    end
  end

  private

  def build_server(dir, client: PanStreamingClient.new([]))
    config = { "pan_mode" => { "username" => "kward", "password" => "secret", "host" => "127.0.0.1", "port" => 0 } }
    Kward::PanServer.new(client: client, working_directory: dir, config: config, config_dir: File.join(dir, ".kward"), output: StringIO.new)
  end

  def auth_header
    "Authorization: Basic #{Base64.strict_encode64("kward:secret")}"
  end

  def request(server, raw_request)
    left, right = UNIXSocket.pair
    thread = Thread.new { server.send(:handle_client, left) }
    right.write(raw_request)
    right.close_write
    response = right.read
    thread.join
    response
  ensure
    left&.close unless left.closed?
    right&.close unless right.closed?
  end

  def stop_worker(server)
    worker = server&.instance_variable_get(:@worker_thread)
    worker&.kill
    worker&.join
  end
end
