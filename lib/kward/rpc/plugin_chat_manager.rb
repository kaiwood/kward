require_relative "../cancellation"
require_relative "../image_attachments"
require_relative "../plugin_chat_runtime"
require_relative "../plugin_registry"
require_relative "attachment_normalizer"
require_relative "transcript_normalizer"

# Namespace for the Kward CLI agent runtime.
module Kward
  module RPC
    # Exposes the frontend-neutral plugin chat runtime over JSON-RPC.
    class PluginChatManager
      EVENT_LIMIT = PluginChatRuntime::EVENT_LIMIT

      def initialize(server:, client: Client.new, plugin_registry_provider: nil)
        @server = server
        @runtime = PluginChatRuntime.new(client: client, plugin_registry_provider: plugin_registry_provider)
        @subscriptions = {}
        @mutex = Mutex.new
        @runtime.subscribe_events { |event| notify_event(event) }
      end

      attr_reader :runtime

      def supported_types
        @runtime.supported_types(surface: :rpc)
      end

      def list
        { chats: supported_types.map { |type| type_payload(type) } }
      end

      def open(type_id:)
        chat = @runtime.open(type_id: type_id, surface: :rpc, scope_key: "owner")
        payload = chat_payload(chat)
        return payload if chat.driver.respond_to?(:transcript_page)

        payload.merge(messages: TranscriptNormalizer.new(chat.driver.messages).normalize)
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
        turn = @runtime.start_turn(
          chat_id: chat.id,
          input: @runtime.input_with_attachments(input, normalized_attachments),
          display_input: input.to_s
        )
        turn_payload(turn)
      end

      def cancel_turn(turn_id:)
        turn_payload(@runtime.cancel_turn(turn_id: turn_id))
      end

      def turn_status(turn_id:)
        turn_payload(@runtime.turn_status(turn_id: turn_id))
      end

      def turn_events(turn_id:, after_sequence: 0)
        turn = @runtime.turn_status(turn_id: turn_id)
        {
          turn: turn_payload(turn),
          events: @runtime.turn_events(turn_id: turn_id, after_sequence: after_sequence)
        }
      end

      def list_turns(chat_id: nil, active: false)
        { turns: @runtime.list_turns(chat_id: chat_id, active: active).map { |turn| turn_payload(turn) } }
      end

      def shutdown
        @runtime.shutdown
      end

      private

      def fetch_chat(chat_id)
        return @runtime.chat(chat_id) if @runtime.chat(chat_id)

        chat_id = chat_id.to_s
        type = supported_types.find { |entry| chat_id == entry.id || chat_id.start_with?("#{entry.id}:") }
        raise ArgumentError, "Unknown plugin chat: #{chat_id}" unless type

        chat = @runtime.open(type_id: type.id, surface: :rpc, scope_key: "owner")
        raise ArgumentError, "Unknown plugin chat: #{chat_id}" unless chat.id == chat_id

        chat
      end

      def notify_event(event)
        subscribed = @mutex.synchronize { @subscriptions[event[:chatId]] }
        @server.notify("pluginChat/event", event) if subscribed
      end

      def type_payload(type)
        {
          id: type.id,
          name: type.name,
          title: type.title,
          singleton: type.singleton,
          transport: type.transport == true ? true : nil
        }.compact
      end

      def transcript_page(driver, limit:, before:)
        return { messages: driver.messages, has_more: false } unless limit && driver.respond_to?(:transcript_page)

        driver.transcript_page(limit: limit, before: before)
      end

      def chat_payload(chat)
        type_payload(chat.type).merge(
          id: chat.id,
          subscribed: @mutex.synchronize { @subscriptions[chat.id] == true }
        )
      end

      def turn_payload(turn)
        turn.mutex.synchronize do
          {
            id: turn.id,
            chatId: turn.chat_id,
            status: turn.status,
            createdAt: turn.created_at,
            startedAt: turn.started_at,
            finishedAt: turn.finished_at,
            error: turn.error
          }.compact
        end
      end
    end
  end
end
