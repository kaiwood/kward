require_relative "../message_access"
require_relative "../tools/tool_call"
require_relative "tool_metadata"

# Namespace for the Kward CLI agent runtime.
module Kward
  # JSON-RPC backend namespace used by UI clients.
  module RPC
    # Normalizes Kward transcript messages into frontend-neutral RPC payloads.
    class TranscriptNormalizer
      IMAGE_MIME_TYPES = ["image/png", "image/jpeg", "image/gif", "image/webp"].freeze
      THINKING_CONTENT_TYPES = ["thinking", "reasoning"].freeze

      def initialize(messages)
        @messages = Array(messages)
        @tool_calls_by_id = {}
      end

      def normalize
        @messages.filter_map { |message| normalize_message(message) }
      end

      private

      def normalize_message(message)
        return nil unless message.is_a?(Hash)

        case MessageAccess.role(message).to_s
        when "system"
          nil
        when "user"
          normalize_user_message(message)
        when "assistant"
          normalize_assistant_message(message)
        when "tool"
          normalize_tool_result_message(message)
        when "toolResult"
          normalize_tool_result_message(message)
        when "compactionSummary"
          normalize_compaction_summary(message)
        when "branchSummary", "custom"
          message
        else
          nil
        end
      end

      def normalize_compaction_summary(message)
        summary = MessageAccess.summary(message) || MessageAccess.content(message)
        result = { role: "compactionSummary", summary: summary.to_s }
        tokens_before = ToolCall.value(message, :tokensBefore) || ToolCall.value(message, :tokens_before)
        result[:tokensBefore] = tokens_before if tokens_before
        result
      end

      def normalize_user_message(message)
        {
          role: "user",
          content: normalize_content(MessageAccess.content(message))
        }
      end

      def normalize_assistant_message(message)
        content = reasoning_first_content(normalize_content(MessageAccess.content(message), preserve_thinking: true))
        content = response_item_content(message) if text_content_empty?(content)
        reasoning = normalize_reasoning_summary(message)
        content.unshift(reasoning) if reasoning && !thinking_content?(content)
        tool_calls(message).each do |tool_call|
          normalized_tool_call = normalize_tool_call(tool_call)
          next unless normalized_tool_call

          @tool_calls_by_id[normalized_tool_call[:id]] = normalized_tool_call if normalized_tool_call[:id]
          content << normalized_tool_call
        end

        result = { role: "assistant", content: content }
        error_message = ToolCall.value(message, :errorMessage) || ToolCall.value(message, :error_message)
        result[:errorMessage] = error_message unless error_message.to_s.empty?
        result
      end

      def normalize_tool_result_message(message)
        tool_call_id = ToolCall.value(message, :toolCallId) || ToolCall.value(message, :tool_call_id)
        matching_call = @tool_calls_by_id[tool_call_id]
        raw_name = ToolCall.value(message, :toolName) || ToolCall.value(message, :tool_name) || ToolCall.value(message, :name)
        tool_name = normalize_tool_name(raw_name) || raw_name || matching_call&.dig(:name)
        content = normalize_content(MessageAccess.content(message))

        result = {
          role: "toolResult",
          toolCallId: tool_call_id,
          isError: error_tool_result?(message, content),
          content: content
        }.compact
        result[:toolName] = tool_name if tool_name

        details = tool_result_details(message, matching_call, content)
        result[:details] = details unless details.empty?
        result
      end

      def normalize_tool_call(tool_call)
        return nil unless tool_call.is_a?(Hash)

        raw_name = ToolCall.name(tool_call)
        {
          type: "toolCall",
          id: ToolCall.id(tool_call),
          name: normalize_tool_name(raw_name) || raw_name,
          arguments: ToolMetadata.normalize_tool_args(raw_name, ToolCall.parse_arguments(ToolCall.raw_arguments(tool_call)))
        }.compact
      end

      def normalize_content(content, preserve_thinking: false)
        case content
        when Array
          content.filter_map { |part| normalize_content_part(part, preserve_thinking: preserve_thinking) }
        when nil
          []
        else
          [{ type: "text", text: content.to_s }]
        end
      end

      def normalize_content_part(part, preserve_thinking: false)
        return { type: "text", text: part.to_s } unless part.is_a?(Hash)

        type = ToolCall.value(part, :type).to_s
        case type
        when "text"
          text = ToolCall.value(part, :text)
          text.nil? ? nil : { type: "text", text: text.to_s }
        when "image"
          normalize_image_part(part)
        when "toolCall"
          normalize_existing_tool_call_part(part)
        when *THINKING_CONTENT_TYPES
          preserve_thinking ? normalize_thinking_part(part) : normalize_unknown_content_part(part)
        else
          normalize_unknown_content_part(part)
        end
      end

      def normalize_unknown_content_part(part)
        text = ToolCall.value(part, :text)
        text.nil? ? nil : { type: "text", text: text.to_s }
      end

      def normalize_thinking_part(part)
        thinking = ToolCall.value(part, :thinking) || ToolCall.value(part, :reasoning) || ToolCall.value(part, :text)
        thinking.nil? ? nil : { type: "thinking", thinking: thinking.to_s }
      end

      def normalize_reasoning_summary(message)
        summary = ToolCall.value(message, :reasoning_summary) || ToolCall.value(message, :reasoningSummary)
        summary.to_s.empty? ? nil : { type: "thinking", thinking: summary.to_s }
      end

      def response_item_content(message)
        response_items(message).filter_map do |item|
          next unless item.is_a?(Hash)

          case ToolCall.value(item, :type).to_s
          when "reasoning"
            thinking = reasoning_item_text(item)
            { type: "thinking", thinking: thinking } unless thinking.empty?
          when "message"
            next if ToolCall.value(item, :phase).to_s == "commentary"

            text = response_message_item_text(item)
            { type: "text", text: text } unless text.empty?
          end
        end
      end

      def response_items(message)
        MessageAccess.response_items(message)
      end

      def reasoning_item_text(item)
        summary = ToolCall.value(item, :summary)
        content = ToolCall.value(item, :content)
        response_text_parts(summary).empty? ? response_text_parts(content).join("\n\n") : response_text_parts(summary).join("\n\n")
      end

      def response_message_item_text(item)
        response_text_parts(ToolCall.value(item, :content)).join
      end

      def response_text_parts(parts)
        Array(parts).filter_map do |part|
          next unless part.is_a?(Hash)

          ToolCall.value(part, :text) || ToolCall.value(part, :refusal)
        end.map(&:to_s)
      end

      def text_content_empty?(content)
        Array(content).all? do |part|
          !part.is_a?(Hash) || !["text", "thinking"].include?(ToolCall.value(part, :type).to_s) || ToolCall.value(part, :text).to_s.empty? && ToolCall.value(part, :thinking).to_s.empty?
        end
      end

      def thinking_content?(content)
        content.any? { |part| thinking_content_part?(part) }
      end

      def reasoning_first_content(content)
        thinking, other = content.partition { |part| thinking_content_part?(part) }
        thinking.empty? ? content : thinking + other
      end

      def thinking_content_part?(part)
        part.is_a?(Hash) && ToolCall.value(part, :type) == "thinking"
      end

      def normalize_image_part(part)
        mime_type = ToolCall.value(part, :mimeType) || ToolCall.value(part, :mime_type) || ToolCall.value(part, :media_type)
        mime_type = normalize_mime_type(mime_type)
        return nil unless IMAGE_MIME_TYPES.include?(mime_type)

        data = ToolCall.value(part, :data)
        return nil if data.to_s.empty?

        result = { type: "image", data: data, mimeType: mime_type }
        alt = ToolCall.value(part, :alt) || image_alt_from_path(ToolCall.value(part, :path))
        result[:alt] = alt unless alt.to_s.empty?
        result
      end

      def normalize_existing_tool_call_part(part)
        raw_name = ToolCall.value(part, :name)
        arguments = ToolCall.value(part, :arguments) || {}
        {
          type: "toolCall",
          id: ToolCall.value(part, :id),
          name: normalize_tool_name(raw_name) || raw_name,
          arguments: ToolMetadata.normalize_tool_args(raw_name, ToolCall.parse_arguments(arguments))
        }.compact
      end

      def tool_result_details(message, matching_call, content)
        explicit_details = ToolCall.value(message, :details)
        details = explicit_details.is_a?(Hash) ? safe_details(explicit_details) : {}
        text = content_text(content)

        diff = details[:diff] || details["diff"] || ToolMetadata.extract_unified_diff(text)
        details[:diff] = diff if diff

        changed_files = details[:changedFiles] || details["changedFiles"] || ToolMetadata.changed_files_from_result(text, matching_call)
        details[:changedFiles] = changed_files if changed_files && !changed_files.empty?

        details
      end

      def safe_details(details)
        allowed = {}
        diff = ToolCall.value(details, :diff)
        allowed[:diff] = diff if diff
        changed_files = ToolCall.value(details, :changedFiles) || ToolCall.value(details, :changed_files)
        allowed[:changedFiles] = changed_files if changed_files.is_a?(Array)
        allowed
      end

      def error_tool_result?(message, content)
        return ToolCall.value(message, :isError) if has_key?(message, :isError)
        return ToolCall.value(message, :is_error) if has_key?(message, :is_error)

        ToolMetadata.error_result?(content_text(content))
      end

      def content_text(content)
        Array(content).filter_map do |part|
          part[:text] || part["text"] if part.is_a?(Hash)
        end.join("\n")
      end

      def tool_calls(message)
        MessageAccess.tool_calls(message)
      end

      def normalize_tool_name(name)
        ToolMetadata.normalize_tool_name(name)
      end

      def normalize_mime_type(mime_type)
        mime_type.to_s.downcase.sub("image/jpg", "image/jpeg")
      end

      def image_alt_from_path(path)
        path ? File.basename(path.to_s) : nil
      end

      def has_key?(object, key)
        object.respond_to?(:key?) && (object.key?(key) || object.key?(key.to_s))
      end
    end
  end
end
