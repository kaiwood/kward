require "securerandom"
require "thread"
require_relative "../cancellation"
require_relative "../events"
require_relative "../image_attachments"
require_relative "../message_access"
require_relative "../plugin_registry"
require_relative "../tools/tool_call"
require_relative "../tab_driver"
require_relative "attachment_normalizer"
require_relative "transcript_normalizer"

# Namespace for the Kward CLI agent runtime.
module Kward
  module RPC
    # Coordinates optional RPC access to plugin-owned conversational runtimes.
    # Unlike SessionManager, this manager never creates workspace sessions,
    # agents, or tool registries: each plugin driver owns its chat and storage.
    class PluginChatManager
      EVENT_LIMIT = 1_000
      WORKER_STOP = Object.new.freeze

      Chat = Struct.new(:id, :type, :driver, :queue, :worker, :running_turn_id, keyword_init: true)
      Turn = Struct.new(:id, :chat_id, :input, :display_input, :status, :cancellation, :created_at, :started_at, :finished_at, :events, :next_sequence, :error, :mutex, keyword_init: true)

      def initialize(server:, client: Client.new)
        @server = server
        @client = client
        @chats = {}
        @turns = {}
        @subscriptions = {}
        @mutex = Mutex.new
      end

      def supported_types
        plugin_registry.tab_types.select(&:rpc)
      end

      def list
        { chats: supported_types.map { |type| type_payload(type) } }
      end

      def open(type_id:)
        type = supported_types.find { |entry| entry.id == type_id.to_s } || raise(ArgumentError, "Unknown RPC plugin chat: #{type_id}")
        chat = chat_for(type)
        return chat_payload(chat) if chat.driver.respond_to?(:transcript_page)

        chat_payload(chat).merge(messages: TranscriptNormalizer.new(chat.driver.messages).normalize)
      end

      def transcript(chat_id:, limit: nil, before: nil)
        chat = fetch_chat(chat_id)
        page = transcript_page(chat.driver, limit: limit, before: before)
        {
          chat: chat_payload(chat),
          messages: TranscriptNormalizer.new(page.fetch(:messages)).normalize,
          hasMore: page.fetch(:has_more),
          nextBefore: page[:next_before]
        }.compact
      end

      def subscribe(chat_id:)
        chat = fetch_chat(chat_id)
        @mutex.synchronize { @subscriptions[chat.id] = true }
        { chat: chat_payload(chat), subscribed: true }
      end

      def unsubscribe(chat_id:)
        chat = fetch_chat(chat_id)
        @mutex.synchronize { @subscriptions.delete(chat.id) }
        { chat: chat_payload(chat), subscribed: false }
      end

      def start_turn(chat_id:, input:, attachments: [])
        chat = fetch_chat(chat_id)
        normalized_attachments = AttachmentNormalizer.new.normalize(attachments)
        turn = Turn.new(
          id: SecureRandom.uuid,
          chat_id: chat.id,
          input: input_with_attachments(input, normalized_attachments),
          display_input: input.to_s,
          status: "queued",
          cancellation: Cancellation.new,
          created_at: Time.now.utc.iso8601(3),
          events: [],
          next_sequence: 1,
          mutex: Mutex.new
        )
        @mutex.synchronize { @turns[turn.id] = turn }
        chat.queue << turn.id
        ensure_worker(chat)
        emit_event(turn, "turnQueued", { status: "queued" })
        turn_payload(turn)
      end

      def cancel_turn(turn_id:)
        turn = fetch_turn(turn_id)
        queued = turn.mutex.synchronize do
          turn.cancellation.cancel!
          turn.status == "queued"
        end
        emit_event(turn, "turnCancelRequested", {})
        finish_turn(turn, "canceled") if queued
        turn_payload(turn)
      end

      def turn_status(turn_id:)
        turn_payload(fetch_turn(turn_id))
      end

      def turn_events(turn_id:, after_sequence: 0)
        turn = fetch_turn(turn_id)
        events = turn.mutex.synchronize { turn.events.select { |event| event[:sequence].to_i > after_sequence.to_i } }
        { turn: turn_payload(turn), events: events }
      end

      def list_turns(chat_id: nil, active: false)
        turns = @mutex.synchronize { @turns.values.dup }
        turns.select! { |turn| turn.chat_id == chat_id.to_s } if chat_id
        turns.select! { |turn| %w[queued running].include?(turn.status) } if active
        { turns: turns.map { |turn| turn_payload(turn) } }
      end

      def shutdown
        chats = @mutex.synchronize { @chats.values.dup }
        chats.each do |chat|
          chat.queue << WORKER_STOP if chat.worker&.alive?
          chat.worker&.join(0.2)
        end
      end

      private

      def plugin_registry
        @plugin_registry ||= PluginRegistry.load
      end

      def chat_for(type)
        @mutex.synchronize do
          @chats[type.id] ||= begin
            descriptor = { "kind" => "plugin", "plugin_tab_type" => type.id, "label" => type.title }
            driver = type.handler.call(PluginTabHost.new(client: @client, workspace_root: Dir.pwd), descriptor)
            raise "Plugin chat #{type.id.inspect} did not return a tab driver." unless driver

            Chat.new(id: type.id, type: type, driver: driver, queue: Queue.new)
          end
        end
      end

      def fetch_chat(chat_id)
        @mutex.synchronize { @chats[chat_id.to_s] } || open(type_id: chat_id).then { @mutex.synchronize { @chats[chat_id.to_s] } }
      end

      def fetch_turn(turn_id)
        @mutex.synchronize { @turns[turn_id.to_s] } || raise(ArgumentError, "Unknown plugin chat turn: #{turn_id}")
      end

      def ensure_worker(chat)
        return if chat.worker&.alive?

        chat.worker = Thread.new do
          loop do
            turn_id = chat.queue.pop
            break if turn_id.equal?(WORKER_STOP)

            turn = fetch_turn(turn_id)
            run_turn(chat, turn) unless turn.cancellation.cancelled?
          end
        end
        chat.worker.report_on_exception = false
      end

      def run_turn(chat, turn)
        turn.mutex.synchronize do
          return if terminal?(turn)

          turn.status = "running"
          turn.started_at = Time.now.utc.iso8601(3)
        end
        chat.running_turn_id = turn.id
        emit_event(turn, "turnStarted", { status: "running" })
        chat.driver.submit(turn.input, display_input: turn.display_input, cancellation: turn.cancellation) do |event|
          handle_driver_event(chat, turn, event)
        end
        finish_turn(turn, turn.cancellation.cancelled? ? "canceled" : "completed")
      rescue Cancellation::CancelledError
        finish_turn(turn, "canceled")
      rescue StandardError => e
        turn.mutex.synchronize { turn.error = { message: e.message, code: e.class.name, fatal: false } }
        finish_turn(turn, "failed")
      ensure
        chat.running_turn_id = nil if chat.running_turn_id == turn.id
      end

      def handle_driver_event(chat, turn, event)
        notify_plugin_tab_transcript_event(chat, event) if chat.type.transcript_events

        type, payload = case event
        when Events::ReasoningDelta then ["reasoningDelta", { delta: event.delta }]
        when Events::ReasoningBoundary then ["reasoningBoundary", {}]
        when Events::AssistantDelta then ["assistantDelta", { delta: event.delta }]
        when Events::AssistantMessage then ["assistantMessage", { message: TranscriptNormalizer.new([event.message]).normalize.first }]
        when Events::Retry then ["modelRetry", retry_event_payload(event)]
        when Events::ToolCall then ["toolCall", tool_call_payload(event.tool_call)]
        when Events::ToolResult then ["toolResult", tool_result_payload(event.tool_call, event.content)]
        when Events::Answer then ["answer", { content: event.content }]
        end
        emit_event(turn, type, payload) if type
      end

      def notify_plugin_tab_transcript_event(chat, event)
        return if plugin_registry.transcript_event_handlers.empty?

        context = PluginRegistry::Context.new(conversation: chat.driver, workspace_root: Dir.pwd)
        plugin_registry.notify_transcript_event(event, context)
      end

      def retry_event_payload(event)
        { provider: event.provider, model: event.model, attempt: event.attempt, maxAttempts: event.max_attempts, delaySeconds: event.delay_seconds, error: event.error, requestBytes: event.request_bytes }.compact
      end

      def tool_call_payload(tool_call)
        { toolCallId: ToolCall.id(tool_call), toolName: ToolCall.name(tool_call), args: ToolCall.parse_arguments(ToolCall.raw_arguments(tool_call)) }.compact
      end

      def tool_result_payload(tool_call, content)
        { toolCallId: ToolCall.id(tool_call), toolName: ToolCall.name(tool_call), result: { content: content.to_s, isError: content.to_s.start_with?("Unknown", "Invalid", "Research tool failed") } }.compact
      end

      def finish_turn(turn, status)
        event = turn.mutex.synchronize do
          next nil if terminal?(turn)

          turn.status = status
          turn.finished_at = Time.now.utc.iso8601(3)
          append_event(turn, "turnFinished", { status: status, error: turn.error }.compact)
        end
        notify_event(event) if event
      end

      def emit_event(turn, type, payload)
        event = turn.mutex.synchronize { append_event(turn, type, payload) }
        notify_event(event)
      end

      def append_event(turn, type, payload)
        event = {
          sequence: turn.next_sequence,
          timestamp: Time.now.utc.iso8601(3),
          chatId: turn.chat_id,
          turnId: turn.id,
          type: type,
          payload: payload
        }
        turn.next_sequence += 1
        turn.events << event
        turn.events.shift while turn.events.length > EVENT_LIMIT
        event
      end

      def notify_event(event)
        subscribed = @mutex.synchronize { @subscriptions[event[:chatId]] }
        @server.notify("pluginChat/event", event) if subscribed
      end

      def input_with_attachments(input, attachments)
        return input.to_s if attachments.empty?

        [{ type: "text", text: input.to_s }] + attachments.map do |attachment|
          { type: "image", media_type: attachment[:mimeType], data: attachment[:data], alt: attachment[:alt] }
        end
      end

      def terminal?(turn)
        %w[completed failed canceled].include?(turn.status)
      end

      def type_payload(type)
        { id: type.id, name: type.name, title: type.title, singleton: type.singleton }.compact
      end

      def transcript_page(driver, limit:, before:)
        return { messages: driver.messages, has_more: false } unless limit && driver.respond_to?(:transcript_page)

        driver.transcript_page(limit: limit, before: before)
      end

      def chat_payload(chat)
        type_payload(chat.type).merge(id: chat.id, subscribed: @mutex.synchronize { @subscriptions[chat.id] == true })
      end

      def turn_payload(turn)
        turn.mutex.synchronize do
          { id: turn.id, chatId: turn.chat_id, status: turn.status, createdAt: turn.created_at, startedAt: turn.started_at, finishedAt: turn.finished_at, error: turn.error }.compact
        end
      end
    end
  end
end
