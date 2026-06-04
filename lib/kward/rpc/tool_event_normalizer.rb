require "json"
require_relative "../workspace"

module Kward
  module RPC
    class ToolEventNormalizer
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

      def initialize(tool_call, content: nil)
        @tool_call = tool_call
        @content = content
        @fields = normalized_tool_fields
      end

      def call_payload(legacy_tool: nil)
        {
          toolCall: @tool_call,
          rawToolCall: @tool_call,
          tool: legacy_tool,
          toolCallId: @fields[:toolCallId],
          toolName: @fields[:toolName],
          args: @fields[:args]
        }.compact
      end

      def result_payload(legacy_tool: nil)
        call_payload(legacy_tool: legacy_tool).merge(
          content: @content,
          result: normalized_result
        )
      end

      private

      def normalized_tool_fields
        function = value(@tool_call, :function) || {}
        raw_name = value(function, :name)
        args = parse_tool_arguments(value(function, :arguments))
        {
          toolCallId: value(@tool_call, :id),
          toolName: normalize_tool_name(raw_name) || raw_name,
          args: normalize_tool_args(raw_name, args)
        }.compact
      end

      def normalized_result
        text = @content.to_s
        is_error = tool_result_error?(text)
        result = { content: text, isError: is_error, images: [] }
        unless is_error
          diff = extract_unified_diff(text)
          result[:diff] = diff if diff

          files = changed_files
          result[:changedFiles] = files if files.any?
        end
        result
      end

      def normalize_tool_name(name)
        TOOL_NAME_MAP[name.to_s]
      end

      def normalize_tool_args(name, args)
        case name.to_s
        when "edit_file", "edit"
          normalize_edit_args(args)
        when "write_file", "write"
          normalize_write_args(args)
        when "run_shell_command", "bash"
          normalize_bash_args(args)
        else
          camelize_tool_args(args)
        end
      end

      def normalize_edit_args(args)
        result = {}
        path = value(args, :path)
        result[:path] = path if path
        edits = Array(value(args, :edits)).filter_map do |edit|
          next unless edit.is_a?(Hash)

          {
            oldText: value(edit, :oldText) || value(edit, :old_text),
            newText: value(edit, :newText) || value(edit, :new_text)
          }.compact
        end
        result[:edits] = edits if edits.any?
        result
      end

      def normalize_write_args(args)
        result = {}
        path = value(args, :path)
        content = value(args, :content)
        result[:path] = path if path
        result[:content] = content if content
        result
      end

      def normalize_bash_args(args)
        result = {}
        command = value(args, :command)
        timeout = value(args, :timeout) || value(args, :timeout_seconds) || Workspace::DEFAULT_COMMAND_TIMEOUT_SECONDS
        result[:command] = command if command
        result[:timeout] = timeout if timeout
        result
      end

      def camelize_tool_args(args)
        return {} unless args.is_a?(Hash)

        args.each_with_object({}) do |(key, item), result|
          result[camelize_key(key)] = camelize_tool_arg_value(item)
        end
      end

      def camelize_tool_arg_value(item)
        case item
        when Hash
          camelize_tool_args(item)
        when Array
          item.map { |entry| camelize_tool_arg_value(entry) }
        else
          item
        end
      end

      def camelize_key(key)
        key.to_s.gsub(/_([a-z])/) { Regexp.last_match(1).upcase }.to_sym
      end

      def tool_result_error?(text)
        text.start_with?("Error:", "Declined:", "Cancelled.")
      end

      def extract_unified_diff(text)
        index = text.index(/^--- /)
        index ? text[index..] : nil
      end

      def changed_files
        return [] unless ["edit", "write"].include?(@fields[:toolName])

        path = @fields.dig(:args, :path)
        path.to_s.empty? ? [] : [path]
      end

      def parse_tool_arguments(arguments)
        return {} if arguments.nil? || (arguments.respond_to?(:empty?) && arguments.empty?)
        return arguments if arguments.is_a?(Hash)

        JSON.parse(arguments.to_s)
      rescue JSON::ParserError
        {}
      end

      def value(object, key)
        return nil unless object.respond_to?(:key?)
        return object[key] if object.key?(key)
        return object[key.to_s] if object.key?(key.to_s)

        nil
      end
    end
  end
end
