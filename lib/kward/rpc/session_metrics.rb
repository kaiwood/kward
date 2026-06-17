require_relative "../message_access"

# Namespace for the Kward CLI agent runtime.
module Kward
  # JSON-RPC backend namespace used by UI clients.
  module RPC
    # Computes conversation metrics and context usage for RPC runtime payloads.
    class SessionMetrics
      def initialize(context_usage:)
        @context_usage = context_usage
      end

      def message_count(conversation)
        conversation.messages.count { |message| MessageAccess.role(message) != "system" }
      end

      def message_stats(conversation)
        conversation.messages.each_with_object(default_message_stats) do |message, counts|
          role = MessageAccess.role(message)
          next if role == "system"

          counts[:totalMessages] += 1
          case role
          when "user"
            counts[:userMessages] += 1
          when "assistant"
            counts[:assistantMessages] += 1
            counts[:toolCalls] += MessageAccess.tool_calls(message).length
          when "tool", "toolResult"
            counts[:toolResults] += 1
          end
        end
      end

      def context_usage(rpc_session, model, client:)
        context_parts = if client.respond_to?(:current_context_parts)
                          client.current_context_parts(rpc_session.conversation.context_messages, rpc_session.tool_registry.schemas)
                        else
                          {
                            provider: model[:provider],
                            model: model[:id],
                            messages: rpc_session.conversation.context_messages,
                            tools: rpc_session.tool_registry.schemas
                          }
                        end

        @context_usage.call(
          provider: model[:provider],
          model: model[:id],
          context_window: model[:contextWindow],
          context_parts: context_parts
        )
      end

      private

      def default_message_stats
        {
          userMessages: 0,
          assistantMessages: 0,
          toolCalls: 0,
          toolResults: 0,
          totalMessages: 0
        }
      end
    end
  end
end
