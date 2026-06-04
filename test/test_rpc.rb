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
    capabilities = messages[0]["result"]["capabilities"]
    assert_equal "content-length", capabilities["framing"]

    detailed_groups = %w[transcript sessions turns events attachments models runtimeSettings auth commands startupResources extensionUi security export]
    detailed_groups.each { |group| assert capabilities.key?(group), "missing capability group #{group}" }

    assert_equal "tauren-transcript-v1", capabilities["transcript"]["format"]
    assert_equal true, capabilities["transcript"]["messagesNormalized"]
    assert_equal false, capabilities["transcript"]["supportsCompactionSummaries"]
    assert_equal "explicit", capabilities["sessions"]["mode"]
    assert_equal "jsonl", capabilities["sessions"]["persistence"]
    assert_equal ["sessions/create", "sessions/resume", "sessions/list", "sessions/rename", "sessions/clone", "sessions/export", "sessions/transcript"], capabilities["sessions"]["methods"]
    assert_equal true, capabilities["sessions"]["list"]["supported"]
    assert_equal false, capabilities["sessions"]["fork"]["supported"]
    assert_equal false, capabilities["sessions"]["compact"]["supported"]
    assert_equal false, capabilities["sessions"]["import"]["supported"]
    assert_equal false, capabilities["sessions"]["tree"]["supported"]
    assert_equal false, capabilities["sessions"]["updates"]["supported"]
    assert_equal "async", capabilities["turns"]["mode"]
    assert_equal 1, capabilities["turns"]["perSessionConcurrency"]
    assert_equal "unsupported", capabilities["turns"]["busyInput"]["steer"]
    assert_equal "best-effort", capabilities["turns"]["cancellation"]["behavior"]
    assert_equal false, capabilities["turns"]["eventReplay"]["persisted"]
    assert_equal 1000, capabilities["turns"]["eventReplay"]["limit"]
    assert_equal "turn/event", capabilities["events"]["notification"]
    assert_equal true, capabilities["events"]["tools"]["normalizedMetadata"]
    assert_equal false, capabilities["events"]["tools"]["diffs"]
    assert_equal false, capabilities["events"]["sessionUpdates"]
    assert_equal false, capabilities["attachments"]["input"]["supported"]
    assert_equal ["image/png", "image/jpeg", "image/gif", "image/webp"], capabilities["attachments"]["input"]["mimeTypes"]
    assert_equal 10_485_760, capabilities["attachments"]["input"]["maxBytes"]
    assert_includes capabilities["models"]["methods"], "models/set"
    assert_equal false, capabilities["models"]["scopedModels"]
    assert_equal false, capabilities["runtimeSettings"]["supported"]
    assert_equal true, capabilities["auth"]["supported"]
    assert_equal "tauren-auth-v1", capabilities["auth"]["providerFormat"]
    assert_equal ["openai"], capabilities["auth"]["oauthProviders"]
    assert_equal false, capabilities["auth"]["logout"]
    assert_equal false, capabilities["commands"]["supported"]
    assert_equal false, capabilities["startupResources"]["supported"]
    assert_equal true, capabilities["extensionUi"]["question"]["supported"]
    assert_equal false, capabilities["extensionUi"]["question"]["multiSelect"]
    assert_equal false, capabilities["extensionUi"]["question"]["preview"]
    assert_equal false, capabilities["extensionUi"]["select"]
    assert_equal "none", capabilities["security"]["workspaceMutationGuard"]
    assert_equal "none", capabilities["security"]["toolApproval"]
    assert_equal ["markdown", "html"], capabilities["export"]["formats"]

    assert_equal true, capabilities["asyncTurns"]
    assert_equal "explicit", capabilities["session"]["mode"]
    assert_equal true, capabilities["config"]["supported"]
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

  def test_model_rpc_methods_read_and_update_config
    Dir.mktmpdir do |config_dir|
      config_path = File.join(config_dir, "config.json")
      client = ReloadableFakeClient.new([], config_path)
      messages = run_rpc([
        { jsonrpc: "2.0", id: 1, method: "models/current" },
        { jsonrpc: "2.0", id: 2, method: "models/list" },
        { jsonrpc: "2.0", id: 3, method: "models/set", params: { model: "new-openai-model" } },
        { jsonrpc: "2.0", id: 4, method: "reasoning/set", params: { effort: "high" } },
        { jsonrpc: "2.0", id: 5, method: "shutdown" }
      ], client: client, env: { "KWARD_CONFIG_PATH" => config_path })

      assert_equal "Codex", messages[0]["result"]["provider"]
      assert_equal "fake-model", messages[0]["result"]["model"]
      assert_equal "fake-model", messages[1]["result"]["models"].find { |model| model["provider"] == "Codex" }["id"]
      assert_equal "new-openai-model", messages[2]["result"]["model"]
      assert_equal "high", messages[3]["result"]["reasoningEffort"]
      assert_equal 2, client.reload_count

      config = JSON.parse(File.read(config_path))
      assert_equal "new-openai-model", config["openai_model"]
      assert_equal "high", config["openai_reasoning_effort"]
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

  def test_session_export_supports_markdown_default_and_html
    Dir.mktmpdir do |config_dir|
      manager = Kward::RPC::SessionManager.new(server: RecordingServer.new, client: FakeClient.new([]), config_dir: config_dir)
      session = manager.create_session(workspace_root: Dir.pwd)
      rpc_session = manager.send(:fetch_session, session[:id])
      rpc_session.conversation.append_user("hello <world>")
      rpc_session.conversation.append_assistant("reply")

      markdown = manager.export_session(session_id: session[:id])
      html = manager.export_session(session_id: session[:id], path: File.join(Dir.pwd, "tmp-rpc-export.html"), format: "html")

      assert_equal "markdown", markdown[:format]
      assert_equal ".md", File.extname(markdown[:path])
      assert_includes File.read(markdown[:path]), "## User\n\nhello <world>"
      assert_equal "html", html[:format]
      html_content = File.read(html[:path])
      assert_includes html_content, "<!doctype html>"
      assert_includes html_content, "hello &lt;world&gt;"
    ensure
      File.delete(markdown[:path]) if markdown && File.exist?(markdown[:path])
      File.delete(File.join(Dir.pwd, "tmp-rpc-export.html")) if File.exist?(File.join(Dir.pwd, "tmp-rpc-export.html"))
    end
  end

  def test_tool_events_include_normalized_metadata
    Dir.mktmpdir do |config_dir|
      workspace_root = Dir.mktmpdir
      path = File.join(workspace_root, "test.txt")
      File.write(path, "old one\nold two\n")
      edit_file_args = {
        path: "test.txt",
        edits: [
          { old_text: "old one", new_text: "new one" },
          { old_text: "old two", new_text: "new two" }
        ]
      }
      responses = [
        assistant_tool_call("read_file", { path: "test.txt" }),
        assistant_tool_call("edit_file", edit_file_args),
        { "role" => "assistant", "content" => "done" }
      ]
      manager = Kward::RPC::SessionManager.new(server: RecordingServer.new, client: FakeClient.new(responses), config_dir: config_dir)
      session = manager.create_session(workspace_root: workspace_root)
      turn = manager.start_turn(session_id: session[:id], input: "edit")

      wait_until { manager.turn_status(turn_id: turn[:id])[:status] == "completed" }

      tool_events = manager.turn_events(turn_id: turn[:id])[:events].select { |event| ["toolCall", "toolResult"].include?(event[:type]) && event[:payload][:tool]&.dig(:kind) == "edit" }
      assert_equal 2, tool_events.length
      tool_events.each do |tool_event|
        assert_equal "test.txt", tool_event[:payload][:tool][:path]
        assert_equal "old one", tool_event[:payload][:tool][:oldText]
        assert_equal "new one", tool_event[:payload][:tool][:newText]
        assert_equal [
          { oldText: "old one", newText: "new one" },
          { oldText: "old two", newText: "new two" }
        ], tool_event[:payload][:tool][:edits]
      end
    ensure
      FileUtils.remove_entry(workspace_root) if workspace_root && File.exist?(workspace_root)
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

  class ReloadableFakeClient < FakeClient
    attr_reader :reload_count

    def initialize(responses, config_path)
      super(responses)
      @config_path = config_path
      @reload_count = 0
    end

    def current_model
      config["openai_model"] || super
    end

    def current_reasoning_effort
      config["openai_reasoning_effort"] || super
    end

    def reload_config
      @reload_count += 1
    end

    private

    def config
      return {} unless File.exist?(@config_path)

      JSON.parse(File.read(@config_path))
    end
  end
end
