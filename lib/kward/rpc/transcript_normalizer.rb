require_relative "../tools/tool_call"
require_relative "tool_metadata"

module Kward
  module RPC
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

        case value(message, :role).to_s
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
        summary = value(message, :summary) || value(message, :content)
        result = { role: "compactionSummary", summary: summary.to_s }
        tokens_before = value(message, :tokensBefore) || value(message, :tokens_before)
        result[:tokensBefore] = tokens_before if tokens_before
        result
      end

      def normalize_user_message(message)
        {
          role: "user",
          content: normalize_content(value(message, :content))
        }
      end

      def normalize_assistant_message(message)
        content = reasoning_first_content(normalize_content(value(message, :content), preserve_thinking: true))
        reasoning = normalize_reasoning_summary(message)
        content.unshift(reasoning) if reasoning && !thinking_content?(content)
        tool_calls(message).each do |tool_call|
          normalized_tool_call = normalize_tool_call(tool_call)
          next unless normalized_tool_call

          @tool_calls_by_id[normalized_tool_call[:id]] = normalized_tool_call if normalized_tool_call[:id]
          content << normalized_tool_call
        end

        result = { role: "assistant", content: content }
        error_message = value(message, :errorMessage) || value(message, :error_message)
        result[:errorMessage] = error_message unless error_message.to_s.empty?
        result
      end

      def normalize_tool_result_message(message)
        tool_call_id = value(message, :toolCallId) || value(message, :tool_call_id)
        matching_call = @tool_calls_by_id[tool_call_id]
        raw_name = value(message, :toolName) || value(message, :tool_name) || value(message, :name)
        tool_name = normalize_tool_name(raw_name) || raw_name || matching_call&.dig(:name)
        content = normalize_content(value(message, :content))

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
          arguments: normalize_tool_arguments(raw_name, ToolCall.raw_arguments(tool_call))
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

        type = value(part, :type).to_s
        case type
        when "text"
          text = value(part, :text)
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
        text = value(part, :text)
        text.nil? ? nil : { type: "text", text: text.to_s }
      end

      def normalize_thinking_part(part)
        thinking = value(part, :thinking) || value(part, :reasoning) || value(part, :text)
        thinking.nil? ? nil : { type: "thinking", thinking: thinking.to_s }
      end

      def normalize_reasoning_summary(message)
        summary = value(message, :reasoning_summary) || value(message, :reasoningSummary)
        summary.to_s.empty? ? nil : { type: "thinking", thinking: summary.to_s }
      end

      def thinking_content?(content)
        content.any? { |part| thinking_content_part?(part) }
      end

      def reasoning_first_content(content)
        thinking, other = content.partition { |part| thinking_content_part?(part) }
        thinking.empty? ? content : thinking + other
      end

      def thinking_content_part?(part)
        part.is_a?(Hash) && value(part, :type) == "thinking"
      end

      def normalize_image_part(part)
        mime_type = value(part, :mimeType) || value(part, :mime_type) || value(part, :media_type)
        mime_type = normalize_mime_type(mime_type)
        return nil unless IMAGE_MIME_TYPES.include?(mime_type)

        data = value(part, :data)
        return nil if data.to_s.empty?

        result = { type: "image", data: data, mimeType: mime_type }
        alt = value(part, :alt) || image_alt_from_path(value(part, :path))
        result[:alt] = alt unless alt.to_s.empty?
        result
      end

      def normalize_existing_tool_call_part(part)
        raw_name = value(part, :name)
        arguments = value(part, :arguments) || {}
        {
          type: "toolCall",
          id: value(part, :id),
          name: normalize_tool_name(raw_name) || raw_name,
          arguments: normalize_tool_arguments(raw_name, arguments)
        }.compact
      end

      def tool_result_details(message, matching_call, content)
        explicit_details = value(message, :details)
        details = explicit_details.is_a?(Hash) ? safe_details(explicit_details) : {}
        text = content_text(content)

        diff = details[:diff] || details["diff"] || extract_unified_diff(text)
        details[:diff] = diff if diff

        changed_files = details[:changedFiles] || details["changedFiles"] || changed_files_from_result(text, matching_call)
        details[:changedFiles] = changed_files if changed_files && !changed_files.empty?

        details
      end

      def safe_details(details)
        allowed = {}
        diff = value(details, :diff)
        allowed[:diff] = diff if diff
        changed_files = value(details, :changedFiles) || value(details, :changed_files)
        allowed[:changedFiles] = changed_files if changed_files.is_a?(Array)
        allowed
      end

      def extract_unified_diff(text)
        ToolMetadata.extract_unified_diff(text)
      end

      def changed_files_from_result(text, matching_call)
        path = matching_call&.dig(:arguments, :path) || matching_call&.dig(:arguments, "path")
        return [path] if path

        if (match = text.match(/\A(?:Wrote \d+ bytes to|Edited)\s+([^:\n]+)/))
          [match[1].strip]
        else
          []
        end
      end

      def error_tool_result?(message, content)
        return value(message, :isError) if has_key?(message, :isError)
        return value(message, :is_error) if has_key?(message, :is_error)

        ToolMetadata.error_result?(content_text(content))
      end

      def content_text(content)
        Array(content).filter_map do |part|
          part[:text] || part["text"] if part.is_a?(Hash)
        end.join("\n")
      end

      def tool_calls(message)
        calls = value(message, :tool_calls) || value(message, :toolCalls)
        calls.is_a?(Array) ? calls : []
      end

      def normalize_tool_name(name)
        ToolMetadata.normalize_tool_name(name)
      end

      def normalize_tool_arguments(name, arguments)
        args = ToolCall.parse_arguments(arguments)
        case name.to_s
        when "edit_file", "edit"
          normalize_edit_args(args)
        when "run_shell_command", "bash"
          normalize_bash_args(args)
        else
          camelize_tool_args(args)
        end
      end

      def normalize_edit_args(args)
        normalized = camelize_tool_args(args)
        edits = Array(value(args, :edits)).filter_map do |edit|
          next unless edit.is_a?(Hash)

          {
            oldText: value(edit, :oldText) || value(edit, :old_text),
            newText: value(edit, :newText) || value(edit, :new_text)
          }.compact
        end
        normalized[:edits] = edits if edits.any?
        normalized
      end

      def normalize_bash_args(args)
        normalized = camelize_tool_args(args)
        timeout = value(args, :timeoutSeconds) || value(args, :timeout_seconds)
        normalized[:timeoutSeconds] = timeout if timeout
        normalized.delete(:timeout_seconds)
        normalized
      end

      def camelize_tool_args(args)
        ToolCall.camelize_args(args)
      end

      def normalize_mime_type(mime_type)
        mime_type.to_s.downcase.sub("image/jpg", "image/jpeg")
      end

      def image_alt_from_path(path)
        path ? File.basename(path.to_s) : nil
      end

      def value(object, key)
        ToolCall.value(object, key)
      end

      def has_key?(object, key)
        object.respond_to?(:key?) && (object.key?(key) || object.key?(key.to_s))
      end
    end
  end
end
