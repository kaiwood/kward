require "time"
require_relative "tool_metadata"

# Namespace for the Kward CLI agent runtime.
module Kward
  # JSON-RPC backend namespace used by UI clients.
  module RPC
    # Converts tool calls and results into RPC event payloads.
    class ToolEventNormalizer
      def initialize(tool_call, content: nil)
        @tool_call = tool_call
        @content = content
        @fields = ToolMetadata.normalized_tool_fields(@tool_call)
      end

      def call_payload
        {
          toolCallId: @fields[:toolCallId],
          toolName: @fields[:toolName],
          args: @fields[:args]
        }.compact
      end

      def result_payload
        call_payload.merge(
          content: @content,
          result: normalized_result
        )
      end

      def execution_record(timestamp: Time.now.utc.iso8601(3))
        result = normalized_result
        {
          type: "tool_execution_end",
          timestamp: timestamp,
          toolCallId: @fields[:toolCallId],
          toolName: @fields[:toolName],
          args: @fields[:args],
          result: result,
          isError: result[:isError]
        }
      end

      private

      def normalized_result
        text = @content.to_s
        is_error = ToolMetadata.error_result?(text)
        result = { content: text, isError: is_error, images: [] }
        unless is_error
          if mutation_tool?
            diff = ToolMetadata.extract_unified_diff(text)
            result[:diff] = diff if diff
          end

          files = changed_files
          result[:changedFiles] = files if files.any?
        end
        result
      end

      def changed_files
        return [] unless mutation_tool?

        path = @fields.dig(:args, :path)
        path.to_s.empty? ? [] : [path]
      end

      def mutation_tool?
        ["edit", "write"].include?(@fields[:toolName])
      end
    end
  end
end
