require "base64"
require "thread"
require_relative "../plugins/chat_runtime"

module Kward
  module Transport
    # Adapts the shared plugin-chat runtime to the transport host contract.
    class PluginChatGateway
      POLL_INTERVAL = 0.05
      TERMINAL_STATUSES = %w[completed canceled failed].freeze
      IMAGE_MIME_TYPES = %w[image/png image/jpeg image/gif image/webp].freeze

      def initialize(runtime:, transport_id:, poll_interval: POLL_INTERVAL)
        @runtime = runtime
        @transport_id = transport_id.to_s
        @poll_interval = poll_interval
        @subscriptions = []
        @mutex = Mutex.new
      end

      def resolve_transport_chat(transport_id:, type_id:, conversation:, actor:, scope_key:, descriptor: {}, workspace_root: nil)
        validate_transport_id!(transport_id)
        validate_conversation!(conversation)
        validate_actor!(actor)
        chat = @runtime.open(
          type_id: type_id,
          surface: :transport,
          scope_key: scope_key,
          descriptor: transport_descriptor(conversation, actor, descriptor),
          workspace_root: workspace_root || Dir.pwd
        )
        Host::PluginChatHandle.new(
          id: chat.id,
          type_id: chat.type.id,
          scope_key: chat.scope_key,
          name: chat.type.title
        )
      end

      def start_transport_plugin_chat_turn(chat_id:, actor:, input:, attachments: [], streaming_behavior: nil, execution_profile: nil)
        if execution_profile && !execution_profile.attachments && !Array(attachments).empty?
          raise ArgumentError, "transport execution profile does not allow attachments"
        end
        unless streaming_behavior.nil? || %i[aggregate none].include?(streaming_behavior.to_sym)
          raise ArgumentError, "plugin chat turns do not support #{streaming_behavior} streaming"
        end

        turn = @runtime.start_turn(
          chat_id: chat_id,
          input: @runtime.input_with_attachments(input, normalize_attachments(attachments)),
          display_input: input.to_s,
          context: { actor: actor }
        )
        Host::PluginChatTurnHandle.new(id: turn.id, chat_id: turn.chat_id)
      end

      def transport_plugin_chat_transcript(chat_id:)
        chat = fetch_chat(chat_id)
        { messages: chat.driver.messages }
      end

      def transport_plugin_chat_turn_events(turn_id:, after: nil)
        @runtime.turn_events(turn_id: turn_id, after_sequence: after.to_i).map do |event|
          Transport.turn_event(
            type: event.fetch(:type),
            session_id: event.fetch(:chatId),
            turn_id: event.fetch(:turnId),
            sequence: event.fetch(:sequence),
            payload: event.fetch(:payload, {})
          )
        end
      end

      def transport_plugin_chat_turn_status(turn_id:)
        turn_payload(@runtime.turn_status(turn_id: turn_id))
      end

      def cancel_transport_plugin_chat_turn(turn_id:)
        @runtime.cancel_turn(turn_id: turn_id)
        nil
      end

      def subscribe_transport_plugin_chat_turn(turn_id:, after: nil)
        cursor = after.to_i
        thread = Thread.new do
          loop do
            events = transport_plugin_chat_turn_events(turn_id: turn_id, after: cursor)
            events.each do |event|
              cursor = event.sequence
              yield event
            end
            status = transport_plugin_chat_turn_status(turn_id: turn_id)
            break if TERMINAL_STATUSES.include?(status[:status].to_s)

            sleep @poll_interval
          end
        rescue StandardError
          nil
        end
        @mutex.synchronize { @subscriptions << thread }
        thread
      end

      def shutdown
        subscriptions = @mutex.synchronize do
          current = @subscriptions
          @subscriptions = []
          current
        end
        subscriptions.each(&:kill)
        subscriptions.each(&:join)
        nil
      end

      private

      def validate_transport_id!(transport_id)
        return if transport_id.to_s == @transport_id

        raise ArgumentError, "transport id does not match plugin chat gateway"
      end

      def validate_conversation!(conversation)
        unless conversation.is_a?(ConversationKey)
          raise ArgumentError, "conversation must be a Transport::ConversationKey"
        end
        return if conversation.transport_id == @transport_id

        raise ArgumentError, "conversation transport does not match plugin chat gateway"
      end

      def validate_actor!(actor)
        return if actor.is_a?(Actor)

        raise ArgumentError, "actor must be a Transport::Actor"
      end

      def fetch_chat(chat_id)
        @runtime.chat(chat_id) || raise(ArgumentError, "Unknown plugin chat: #{chat_id}")
      end

      def transport_descriptor(conversation, actor, descriptor)
        {
          "kind" => "transport",
          "transport_id" => @transport_id,
          "conversation" => conversation.to_h,
          "actor" => actor.to_h
        }.merge(descriptor.transform_keys(&:to_s))
      end

      def normalize_attachments(attachments)
        Array(attachments).map do |attachment|
          unless attachment.is_a?(Attachment)
            raise ArgumentError, "transport attachment must be a Transport::Attachment"
          end
          if attachment.url
            raise ArgumentError, "plugin chat attachment URLs are not supported"
          end
          unless IMAGE_MIME_TYPES.include?(attachment.mime_type.to_s.downcase)
            raise ArgumentError, "unsupported plugin chat attachment MIME type: #{attachment.mime_type}"
          end

          {
            mimeType: attachment.mime_type,
            data: Base64.strict_encode64(attachment.data),
            alt: attachment.name
          }.compact
        end
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
