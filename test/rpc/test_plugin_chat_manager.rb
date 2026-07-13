require_relative "test_support"
require_relative "../../lib/kward/rpc/plugin_chat_manager"

class TestRPCPluginChatManager < KwardTestCase
  include KwardRPCTestSupport

  class Driver
    attr_reader :descriptor, :messages, :inputs

    def initialize(descriptor)
      @descriptor = descriptor
      @messages = []
      @inputs = []
    end

    def submit(input, display_input:, cancellation:)
      @inputs << { input: input, display_input: display_input }
      @messages << { role: "user", content: input }
      yield Kward::Events::AssistantDelta.new(delta: "hello")
      @messages << { role: "assistant", content: "hello" }
      yield Kward::Events::Answer.new(content: "hello")
      "hello"
    end
  end

  class RetryingDriver < Driver
    def submit(input, display_input:, cancellation:)
      yield Kward::Events::Retry.new(provider: "Codex", model: "test-model", attempt: 2, max_attempts: 3, delay_seconds: 1, error: "Codex request failed: 503 upstream", request_bytes: 123)
      super
    end
  end

  def test_emits_model_retry_events
    manager = nil
    Dir.mktmpdir do |home|
      write_plugin(home, driver: "RetryingDriver")
      with_env("HOME" => home) do
        server = RecordingServer.new
        manager = Kward::RPC::PluginChatManager.new(server: server)
        manager.subscribe(chat_id: "test.chat")

        turn = manager.start_turn(chat_id: "test.chat", input: "retry")
        wait_until { manager.turn_status(turn_id: turn[:id])[:status] == "completed" }

        event = manager.turn_events(turn_id: turn[:id])[:events].find { |entry| entry[:type] == "modelRetry" }
        assert_equal "Codex", event[:payload][:provider]
        assert_equal "test-model", event[:payload][:model]
        assert_equal 2, event[:payload][:attempt]
        assert_equal 3, event[:payload][:maxAttempts]
        assert_equal 1, event[:payload][:delaySeconds]
        assert_equal "Codex request failed: 503 upstream", event[:payload][:error]
        assert_equal 123, event[:payload][:requestBytes]
      end
    end
  ensure
    manager&.shutdown
  end

  def test_exposes_opted_in_plugin_chat_and_streams_only_after_subscription
    manager = nil
    Dir.mktmpdir do |home|
      write_plugin(home)
      with_env("HOME" => home) do
        server = RecordingServer.new
        manager = Kward::RPC::PluginChatManager.new(server: server)

        assert_equal [{ id: "test.chat", name: "test-chat", title: "Test Chat", singleton: :global }], manager.list[:chats]
        opened = manager.open(type_id: "test.chat")
        assert_equal "test.chat", opened[:id]
        assert_equal [], opened[:messages]

        first_turn = manager.start_turn(chat_id: "test.chat", input: "silent")
        wait_until { manager.turn_status(turn_id: first_turn[:id])[:status] == "completed" }
        assert_empty server.notifications

        manager.subscribe(chat_id: "test.chat")
        turn = manager.start_turn(chat_id: "test.chat", input: "hello", attachments: [{ type: "image", data: Base64.strict_encode64("image"), mimeType: "image/png" }])
        wait_until { manager.turn_status(turn_id: turn[:id])[:status] == "completed" }

        events = manager.turn_events(turn_id: turn[:id])[:events]
        assert_equal %w[turnQueued turnStarted assistantDelta answer turnFinished], events.map { |event| event[:type] }
        assert_equal "pluginChat/event", server.notifications.first[:method]
        assert_equal "test.chat", server.notifications.first[:params][:chatId]
        assert_equal "hello", events.find { |event| event[:type] == "assistantDelta" }[:payload][:delta]
      end
    end
  ensure
    manager&.shutdown
  end

  private

  def write_plugin(home, driver: "Driver")
    plugins = File.join(home, ".kward", "plugins")
    FileUtils.mkdir_p(plugins)
    File.write(File.join(plugins, "chat.rb"), <<~RUBY)
      Kward.plugin do |plugin|
        plugin.tab_type "test-chat", id: "test.chat", title: "Test Chat", singleton: :global, rpc: true do |_host, descriptor|
          TestRPCPluginChatManager::#{driver}.new(descriptor)
        end
      end
    RUBY
  end
end
