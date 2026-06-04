require "json"

module Kward
  module RPC
    class TranscriptNormalizer
      TOOL_NAME_MAP = {
        "read_file" => "read",
        "edit_file" => "edit",
        "write_file" => "write",
        "run_shell_command" => "bash",
        "list_directory" => "list_directory",
        "web_research" => "web_research",
        "read_skill" => "read_skill",
        "ask_user_question" => "ask_user_question"
      }.freeze

      IMAGE_MIME_TYPES = ["image/png", "image/jpeg", "image/gif", "image/webp"].freeze

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
        content = normalize_content(value(message, :content))
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

        function = value(tool_call, :function) || {}
        raw_name = value(function, :name)
        id = value(tool_call, :id)
        {
          type: "toolCall",
          id: id,
          name: normalize_tool_name(raw_name) || raw_name,
          arguments: normalize_tool_arguments(raw_name, value(function, :arguments))
        }.compact
      end

      def normalize_content(content)
        case content
        when Array
          content.filter_map { |part| normalize_content_part(part) }
        when nil
          []
        else
          [{ type: "text", text: content.to_s }]
        end
      end

      def normalize_content_part(part)
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
        else
          text = value(part, :text)
          text.nil? ? nil : { type: "text", text: text.to_s }
        end
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
        index = text.index(/^--- /)
        index ? text[index..] : nil
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

        content_text(content).start_with?("Error:", "Declined:", "Cancelled.")
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
        TOOL_NAME_MAP[name.to_s]
      end

      def normalize_tool_arguments(name, arguments)
        args = parse_tool_arguments(arguments)
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
        return {} unless args.is_a?(Hash)

        args.each_with_object({}) do |(key, value), result|
          result[camelize_key(key)] = camelize_value(value)
        end
      end

      def camelize_value(value)
        case value
        when Hash
          camelize_tool_args(value)
        when Array
          value.map { |item| camelize_value(item) }
        else
          value
        end
      end

      def camelize_key(key)
        key.to_s.gsub(/_([a-z])/) { Regexp.last_match(1).upcase }.to_sym
      end

      def parse_tool_arguments(arguments)
        return {} if arguments.nil? || arguments == ""
        return arguments if arguments.is_a?(Hash)

        JSON.parse(arguments.to_s)
      rescue JSON::ParserError
        {}
      end

      def normalize_mime_type(mime_type)
        mime_type.to_s.downcase.sub("image/jpg", "image/jpeg")
      end

      def image_alt_from_path(path)
        path ? File.basename(path.to_s) : nil
      end

      def value(object, key)
        return nil unless object.respond_to?(:key?)
        return object[key] if object.key?(key)
        return object[key.to_s] if object.key?(key.to_s)

        nil
      end

      def has_key?(object, key)
        object.respond_to?(:key?) && (object.key?(key) || object.key?(key.to_s))
      end
    end
  end
end
