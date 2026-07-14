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

  class PagedDriver < Driver
    def transcript_page(limit:, before: nil)
      messages = [
        { role: "user", content: "older", timestamp: "2026-07-12T12:00:00.000Z" },
        { role: "assistant", content: "newer", timestamp: "2026-07-13T12:00:00.000Z" }
      ]
      page = before ? messages.first(1) : messages.last(limit)
      { messages: page, has_more: !before, next_before: before ? nil : messages.first[:timestamp] }
    end
  end

  class << self
    attr_accessor :plugin_events
  end

  class RetryingDriver < Driver
    def submit(input, display_input:, cancellation:)
      yield Kward::Events::Retry.new(provider: "Codex", model: "test-model", attempt: 2, max_attempts: 3, delay_seconds: 1, error: "Codex request failed: 503 upstream", request_bytes: 123)
      super
    end
  end

  def test_returns_a_bounded_plugin_transcript_page_when_the_driver_supports_paging
    manager = nil
    Dir.mktmpdir do |home|
      write_plugin(home, driver: "PagedDriver")
      with_env("HOME" => home) do
        manager = Kward::RPC::PluginChatManager.new(server: RecordingServer.new)
        first_page = manager.transcript(chat_id: "test.chat", limit: 1)

        assert_equal ["newer"], first_page[:messages].map { |message| message[:content].first[:text] }
        assert_equal true, first_page[:hasMore]
        assert_equal "2026-07-12T12:00:00.000Z", first_page[:nextBefore]

        earlier_page = manager.transcript(chat_id: "test.chat", limit: 1, before: first_page[:nextBefore])
        assert_equal ["older"], earlier_page[:messages].map { |message| message[:content].first[:text] }
        assert_equal false, earlier_page[:hasMore]
      end
    end
  ensure
    manager&.shutdown
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

  def test_opted_in_plugin_chat_notifies_transcript_observers
    manager = nil
    Dir.mktmpdir do |home|
      write_plugin(home, transcript_events: true, observe_events: true)
      with_env("HOME" => home) do
        manager = Kward::RPC::PluginChatManager.new(server: RecordingServer.new)
        turn = manager.start_turn(chat_id: "test.chat", input: "hello")
        wait_until { manager.turn_status(turn_id: turn[:id])[:status] == "completed" }

        assert_equal %w[assistant_delta answer], self.class.plugin_events
      end
    end
  ensure
    manager&.shutdown
  end

  def test_plugin_chat_does_not_notify_transcript_observers_without_opt_in
    manager = nil
    Dir.mktmpdir do |home|
      write_plugin(home, observe_events: true)
      with_env("HOME" => home) do
        manager = Kward::RPC::PluginChatManager.new(server: RecordingServer.new)
        turn = manager.start_turn(chat_id: "test.chat", input: "hello")
        wait_until { manager.turn_status(turn_id: turn[:id])[:status] == "completed" }

        assert_empty self.class.plugin_events
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

  def write_plugin(home, driver: "Driver", transcript_events: false, observe_events: false)
    plugins = File.join(home, ".kward", "plugins")
    FileUtils.mkdir_p(plugins)
    self.class.plugin_events = []
    observer = if observe_events
      <<~RUBY

          plugin.on_transcript_event do |event, _ctx|
            TestRPCPluginChatManager.plugin_events << event.type
          end
      RUBY
    else
      ""
    end
    File.write(File.join(plugins, "chat.rb"), <<~RUBY)
      Kward.plugin do |plugin|
        plugin.tab_type "test-chat", id: "test.chat", title: "Test Chat", singleton: :global, rpc: true, transcript_events: #{transcript_events} do |_host, descriptor|
          TestRPCPluginChatManager::#{driver}.new(descriptor)
        end#{observer}
      end
    RUBY
  end
end
