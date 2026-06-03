require_relative "test_helper"
require_relative "../lib/kward/rpc/server"
require_relative "../lib/kward/rpc/session_manager"
require_relative "../lib/kward/rpc/transport"

class TestRPC < KwardTestCase
  def framed(message)
    body = JSON.generate(message)
    "Content-Length: #{body.bytesize}\r\n\r\n#{body}"
  end

  def read_framed_messages(output)
    input = StringIO.new(output.string)
    messages = []
    loop do
      message = Kward::RPC::Transport.new(input: input, output: StringIO.new).read_message
      break unless message

      messages << message
    end
    messages
  end

  def run_rpc(messages, client: FakeClient.new([]), env: {})
    input = StringIO.new(messages.map { |message| framed(message) }.join)
    output = StringIO.new
    with_env(env) do
      Kward::RPC::Server.new(input: input, output: output, error_output: StringIO.new, client: client).run
    end
    read_framed_messages(output)
  end

  def test_transport_reads_and_writes_content_length_messages
    input = StringIO.new(framed({ jsonrpc: "2.0", id: 1, method: "initialize" }))
    output = StringIO.new
    transport = Kward::RPC::Transport.new(input: input, output: output)

    assert_equal({ "jsonrpc" => "2.0", "id" => 1, "method" => "initialize" }, transport.read_message)
    transport.write_message(jsonrpc: "2.0", id: 1, result: { ok: true })

    assert_equal({ "jsonrpc" => "2.0", "id" => 1, "result" => { "ok" => true } }, read_framed_messages(output).first)
  end

  def test_initialize_and_shutdown
    messages = run_rpc([
      { jsonrpc: "2.0", id: 1, method: "initialize" },
      { jsonrpc: "2.0", id: 2, method: "shutdown" }
    ])

    assert_equal 1, messages[0]["result"]["protocolVersion"]
    assert_equal "content-length", messages[0]["result"]["capabilities"]["framing"]
    assert_equal true, messages[1]["result"]["ok"]
  end

  def test_session_manager_turn_events_complete_and_replay
    Dir.mktmpdir do |config_dir|
      server = RecordingServer.new
      manager = Kward::RPC::SessionManager.new(server: server, client: MarkdownStreamingClient.new(["reply"]), config_dir: config_dir)
      session = manager.create_session(workspace_root: Dir.pwd)
      turn = manager.start_turn(session_id: session[:id], input: "hello")

      wait_until { manager.turn_status(turn_id: turn[:id])[:status] == "completed" }

      events = manager.turn_events(turn_id: turn[:id], after_sequence: 0)[:events]
      assert events.any? { |event| event[:type] == "assistantDelta" && event[:payload][:delta] == "reply" }
      assert events.any? { |event| event[:type] == "answer" && event[:payload][:content] == "reply" }
      assert_equal "completed", manager.turn_status(turn_id: turn[:id])[:status]
      assert server.notifications.any? { |notification| notification[:method] == "turn/event" }
    end
  end

  def test_session_manager_queues_turns_per_session
    Dir.mktmpdir do |config_dir|
      server = RecordingServer.new
      client = RecordingClient.new(["one", "two"])
      manager = Kward::RPC::SessionManager.new(server: server, client: client, config_dir: config_dir)
      session = manager.create_session(workspace_root: Dir.pwd)
      first = manager.start_turn(session_id: session[:id], input: "first")
      second = manager.start_turn(session_id: session[:id], input: "second")

      wait_until { manager.turn_status(turn_id: second[:id])[:status] == "completed" }

      assert_equal "first", client.seen_messages[0][1][:content]
      assert_equal "second", client.seen_messages[1][3][:content]
      assert_equal "completed", manager.turn_status(turn_id: first[:id])[:status]
      assert_equal "completed", manager.turn_status(turn_id: second[:id])[:status]
    end
  end

  def test_cancel_queued_turn_is_best_effort
    Dir.mktmpdir do |config_dir|
      server = RecordingServer.new
      manager = Kward::RPC::SessionManager.new(server: server, client: SlowClient.new, config_dir: config_dir)
      session = manager.create_session(workspace_root: Dir.pwd)
      first = manager.start_turn(session_id: session[:id], input: "first")
      second = manager.start_turn(session_id: session[:id], input: "second")

      manager.cancel_turn(turn_id: second[:id])

      assert_equal "canceled", manager.turn_status(turn_id: second[:id])[:status]
      assert_equal true, manager.turn_status(turn_id: second[:id])[:cancelRequested]
      wait_until { manager.turn_status(turn_id: first[:id])[:status] == "completed" }
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

  def test_prompt_bridge_brokers_questions_to_rpc_ui
    server = RecordingServer.new
    bridge = Kward::RPC::PromptBridge.new(server: server, session_id: "session-1")
    answer_thread = Thread.new do
      wait_until { server.notifications.any? }
      params = server.notifications.first[:params]
      bridge.answer(params[:questionRequestId], [{ question: "Continue?", answer: "Yes" }])
    end

    answers = bridge.ask_user_question([question_args("Continue?")])

    assert_equal [{ question: "Continue?", answer: "Yes" }], answers
    assert_equal "ui/question", server.notifications.first[:method]
  ensure
    answer_thread&.join
  end

  def wait_until(timeout: 2)
    deadline = Time.now + timeout
    until yield
      raise "timed out" if Time.now > deadline

      sleep 0.01
    end
  end

  class RecordingServer
    attr_reader :notifications

    def initialize
      @notifications = []
    end

    def notify(method, params = {})
      @notifications << { method: method, params: params }
    end

    def error_payload(error)
      { code: error.class.name, message: error.message }
    end

    def log_error(error)
      raise error
    end
  end

  class SlowClient
    def chat(_messages, tools: [], on_assistant_delta: nil)
      sleep 0.1
      on_assistant_delta&.call("slow")
      { "role" => "assistant", "content" => "slow" }
    end
  end
end
