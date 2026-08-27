require "json"
require_relative "../message_access"
require_relative "../tools/tool_call"

# Namespace for the Kward CLI agent runtime.
module Kward
  # Conversation compaction settings, planning, and summary generation.
  module Compaction
    # Estimates transcript token usage from messages and provider usage metadata.
    class TokenEstimator
      def estimate_tokens(text)
        (text.to_s.length / 4.0).ceil
      end

      def messages_tokens(messages)
        Array(messages).sum { |message| message_tokens(message) }
      end

      def context_tokens(messages)
        messages = Array(messages)
        usage_info = last_assistant_usage_info(messages)
        return messages_tokens(messages) unless usage_info

        usage_tokens = usage_tokens(usage_info[:usage])
        trailing_tokens = messages[(usage_info[:index] + 1)..].to_a.sum { |message| message_tokens(message) }
        usage_tokens + trailing_tokens
      end

      def message_tokens(message)
        role = value(message, :role)
        parts = [role]
        if role.to_s == "compactionSummary"
          parts << value(message, :summary)
        elsif response_items(message).empty?
          parts << content_text(value(message, :content))
          parts << value(message, :reasoning_summary)
          tool_calls(message).each do |tool_call|
            parts << tool_call_name(tool_call)
            parts << tool_call_arguments(tool_call)
          end
        else
          parts << JSON.generate(response_items(message))
        end
        parts << value(message, :tool_call_id)
        parts << value(message, :name)
        estimate_tokens(parts.compact.join("\n"))
      end

      private

      def content_text(content)
        return content.to_s unless content.is_a?(Array)

        content.filter_map do |part|
          type = value(part, :type)
          if type == "text"
            value(part, :text)
          elsif type == "image"
            path = value(part, :path)
            media_type = value(part, :media_type) || value(part, :mimeType) || "image"
            "[#{media_type}#{path ? ": #{path}" : ""}]"
          end
        end.join("\n")
      end

      def tool_calls(message)
        MessageAccess.tool_calls(message)
      end

      def response_items(message)
        MessageAccess.response_items(message)
      end

      def tool_call_name(tool_call)
        ToolCall.name(tool_call)
      end

      def tool_call_arguments(tool_call)
        arguments = ToolCall.raw_arguments(tool_call)
        arguments.is_a?(Hash) ? JSON.dump(arguments) : arguments.to_s
      end

      def last_assistant_usage_info(messages)
        messages.each_with_index.reverse_each do |message, index|
          next unless value(message, :role).to_s == "assistant"

          usage = value(message, :usage)
          tokens = usage_tokens(usage)
          return { usage: usage, index: index } if tokens.positive?
        end
        nil
      end

      def usage_tokens(usage)
        return 0 unless usage.respond_to?(:key?)

        total = usage_value(usage, :total_tokens, "totalTokens")
        return total if total.positive?

        usage_value(usage, :input_tokens, "input", "prompt_tokens") +
          usage_value(usage, :output_tokens, "output", "completion_tokens") +
          usage_value(usage, :cache_read_tokens, "cacheRead", "cacheReadTokens", "cache_read", "cached_tokens") +
          usage_value(usage, :cache_write_tokens, "cacheWrite", "cacheWriteTokens", "cache_write")
      end

      def usage_value(usage, *keys)
        key = keys.find { |candidate| usage.key?(candidate) || usage.key?(candidate.to_s) }
        return 0 unless key

        (usage[key] || usage[key.to_s]).to_i
      end

      def value(object, key)
        ToolCall.value(object, key)
      end
    end
  end
end
