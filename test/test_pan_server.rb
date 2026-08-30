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

  def test_pan_server_defaults_to_loopback
    Dir.mktmpdir do |dir|
      config = { "pan_mode" => { "username" => "kward", "password" => "secret", "port" => 0 } }
      server = build_server(dir, config: config)

      assert_equal "127.0.0.1", server.host
    end
  end

  def test_pan_server_accepts_password_from_environment
    Dir.mktmpdir do |dir|
      config = { "pan_mode" => { "username" => "kward", "host" => "127.0.0.1", "port" => 0 } }
      server = with_env("KWARD_PAN_PASSWORD" => "environment-secret") do
        build_server(dir, config: config)
      end
      authorization = Base64.strict_encode64("kward:environment-secret")
      response = request(server, "GET / HTTP/1.1\r\nHost: example\r\nAuthorization: Basic #{authorization}\r\n\r\n")

      assert_includes response, "HTTP/1.1 200 OK"
      refute_includes response, "environment-secret"
    end
  end

  def test_pan_server_warns_when_exposed_over_plain_http
    Dir.mktmpdir do |dir|
      output = StringIO.new
      config = { "pan_mode" => { "username" => "kward", "password" => "secret", "host" => "0.0.0.0", "port" => 0 } }
      server = Kward::PanServer.new(client: PanStreamingClient.new([]), working_directory: dir, config: config, config_dir: File.join(dir, ".kward"), output: output)

      server.send(:warn_if_exposed)

      assert_includes output.string, "Pan is exposed over plain HTTP on 0.0.0.0"
      assert_includes output.string, "bind pan_mode.host to 127.0.0.1"
      refute_includes output.string, "secret"
    end
  end

  def test_pan_server_does_not_warn_for_loopback
    Dir.mktmpdir do |dir|
      output = StringIO.new
      config = { "pan_mode" => { "username" => "kward", "password" => "secret", "host" => "127.0.0.1", "port" => 0 } }
      server = Kward::PanServer.new(client: PanStreamingClient.new([]), working_directory: dir, config: config, config_dir: File.join(dir, ".kward"), output: output)

      server.send(:warn_if_exposed)

      assert_empty output.string
    end
  end

  def test_pan_server_displays_routed_lan_address_for_all_interfaces
    Dir.mktmpdir do |dir|
      socket = LanAddressSocket.new("192.168.1.25")
      socket_class = Class.new { define_singleton_method(:new) { socket } }
      server = build_server(dir, host: "0.0.0.0", udp_socket_class: socket_class)

      assert_equal "192.168.1.25", server.send(:display_host)

      assert_equal [Kward::PanServer::ROUTING_PROBE_ADDRESS, Kward::PanServer::ROUTING_PROBE_PORT], socket.connection
      assert_equal true, socket.closed
    end
  end

  def test_pan_server_uses_placeholder_when_lan_address_is_unavailable
    Dir.mktmpdir do |dir|
      socket_class = Class.new { define_singleton_method(:new) { raise Errno::ENETUNREACH } }
      server = build_server(dir, host: "0.0.0.0", udp_socket_class: socket_class)

      assert_equal "<lan-address>", server.send(:display_host)
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
      assert_includes response, "<strong>Assistant</strong>"
      assert_includes response, "Workspace: #{File.realpath(dir)}"
      assert_includes response, "State your business."
      assert_includes response, "Authenticated HTTP workspace"
      assert_includes response, "src=\"/kward-logo.png\""
    end
  end

  def test_pan_server_serves_a_dependency_free_safe_markdown_transcript_renderer
    Dir.mktmpdir do |dir|
      server = build_server(dir)
      response = request(server, "GET / HTTP/1.1\r\nHost: example\r\n#{auth_header}\r\n\r\n")

      assert_includes response, "function renderMarkdown(node, source)"
      assert_includes response, "function appendInlineMarkdown(node, source)"
      assert_includes response, "function safeLinkHref(value)"
      assert_includes response, "node.replaceChildren()"
      assert_includes response, "['http:', 'https:', 'mailto:'].includes(url.protocol)"
      refute_includes response, "innerHTML = text"
    end
  end

  def test_pan_server_serves_logo_asset
    Dir.mktmpdir do |dir|
      server = build_server(dir)
      response = request(server, "GET /kward-logo.png HTTP/1.1\r\nHost: example\r\n#{auth_header}\r\n\r\n")
      headers, body = response.split("\r\n\r\n", 2)

      assert_includes headers, "HTTP/1.1 200 OK"
      assert_includes headers, "Content-Type: image/png"
      assert_equal "\x89PNG\r\n\x1A\n".b, body.byteslice(0, 8)
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

  def test_pan_server_lists_creates_renames_and_resumes_sessions
    Dir.mktmpdir do |dir|
      client = PanStreamingClient.new(["first reply"])
      server = build_server(dir, client: client)
      server.send(:start_worker)
      original_id = server.session.id

      server.enqueue_prompt("first prompt")
      wait_until { client.seen_messages.length == 1 && !server.send(:turns_pending?) }

      created = json_response(request(server, json_request("POST", "/sessions", action: "new")))
      refute_equal original_id, created.dig("session", "id")

      renamed = json_response(request(server, json_request("POST", "/sessions", action: "rename", id: created.dig("session", "id"), name: "Mobile review")))
      assert_equal "Mobile review", renamed.dig("session", "name")

      listing = json_response(request(server, "GET /sessions HTTP/1.1\r\nHost: example\r\n#{auth_header}\r\n\r\n"))
      assert_equal 2, listing.fetch("sessions").length
      assert listing.fetch("sessions").any? { |session| session["id"] == original_id && session["title"] == "first prompt" }

      resumed = json_response(request(server, json_request("POST", "/sessions", action: "resume", id: original_id)))
      assert_equal original_id, resumed.dig("session", "id")
      assert_includes server.transcript_items, { role: "user", label: "You", text: "first prompt" }
      assert_includes server.transcript_items, { role: "assistant", label: "Assistant", text: "first reply" }

      deleted = json_response(request(server, json_request("POST", "/sessions", action: "delete", id: original_id)))
      assert_equal original_id, deleted["deletedSessionId"]
      refute_equal original_id, deleted.dig("session", "id")
      refute File.exist?(resumed.dig("session", "path"))
    ensure
      stop_worker(server)
    end
  end

  def test_pan_server_uses_active_persona_label
    Dir.mktmpdir do |dir|
      server = build_server(dir, config: {
        "pan_mode" => { "username" => "kward", "password" => "secret", "host" => "127.0.0.1", "port" => 0 },
        "personas" => {
          "crew" => { "samantha" => { "label" => "Samantha", "instruction" => "Helpful." } },
          "default" => "samantha"
        }
      })
      conversation = server.instance_variable_get(:@conversation)
      conversation.messages << { role: "assistant", content: [{ type: "text", text: "Hello, captain." }] }

      assert_includes request(server, "GET / HTTP/1.1\r\nHost: example\r\n#{auth_header}\r\n\r\n"), "<strong>Samantha</strong>"
      assert_includes server.transcript_items, { role: "assistant", label: "Samantha", text: "Hello, captain." }
    end
  end

  def test_pan_server_rejects_session_changes_while_a_turn_is_pending
    Dir.mktmpdir do |dir|
      server = build_server(dir)
      server.enqueue_prompt("waiting")

      response = request(server, json_request("POST", "/sessions", action: "new"))

      assert_includes response, "HTTP/1.1 409 Conflict"
      assert_equal false, json_response(response)["ok"]
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

  def test_pan_server_broadcasts_lifecycle_hook_events
    Dir.mktmpdir do |dir|
      script = File.join(dir, "hook.rb")
      File.write(script, <<~RUBY)
        require "json"
        puts({ decision: "warn", message: "pan noticed" }.to_json)
      RUBY
      config_path = File.join(dir, "config.json")
      File.write(config_path, JSON.dump(
        "pan_mode" => { "username" => "kward", "password" => "secret", "host" => "127.0.0.1", "port" => 0 },
        "hooks" => { "turn_end" => [{ "id" => "notice", "command" => "ruby #{script}" }] }
      ))
      with_env("KWARD_CONFIG_PATH" => config_path) do
        server = build_server(dir)
        queue = Queue.new
        server.send(:subscribe, queue)
        hooks = server.send(:lifecycle_hook_manager)
        hooks.run(Kward::Hooks::Event.new(name: "turn_end", payload: { input: "hidden" }))

        message = queue.pop
        payload = JSON.parse(message[/^data: (.+)$/m, 1], symbolize_names: true)
        assert_includes message, "event: hook_event"
        assert_equal "turn_end", payload.dig(:event, :name)
        assert_equal ["input"], payload.dig(:event, :payloadKeys)
        assert_equal "warn", payload.dig(:result, :decision)
        assert_equal ["pan noticed"], payload.dig(:result, :warnings)
      ensure
        stop_worker(server)
      end
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

  class LanAddressSocket
    attr_reader :closed, :connection

    def initialize(address)
      @address = address
      @closed = false
    end

    def connect(address, port)
      @connection = [address, port]
    end

    def addr
      ["AF_INET", 0, nil, @address]
    end

    def close
      @closed = true
    end
  end

  def build_server(dir, client: PanStreamingClient.new([]), host: "127.0.0.1", udp_socket_class: UDPSocket, config: nil)
    config ||= { "pan_mode" => { "username" => "kward", "password" => "secret", "host" => host, "port" => 0 } }
    Kward::PanServer.new(client: client, working_directory: dir, config: config, config_dir: File.join(dir, ".kward"), output: StringIO.new, udp_socket_class: udp_socket_class)
  end

  def auth_header
    "Authorization: Basic #{Base64.strict_encode64("kward:secret")}"
  end

  def json_request(method, path, payload)
    body = JSON.generate(payload)
    "#{method} #{path} HTTP/1.1\r\nHost: example\r\n#{auth_header}\r\nContent-Type: application/json\r\nContent-Length: #{body.bytesize}\r\n\r\n#{body}"
  end

  def json_response(response)
    JSON.parse(response.split("\r\n\r\n", 2).last)
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
