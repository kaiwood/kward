require_relative "../tools/tool_call"
require_relative "../workspace"

# Namespace for the Kward CLI agent runtime.
module Kward
  # JSON-RPC backend namespace used by UI clients.
  module RPC
    # Builds compact metadata for RPC tool-call display.
    module ToolMetadata
      module_function

      def normalized_tool_fields(tool_call)
        raw_name = ToolCall.name(tool_call)
        args = ToolCall.arguments(tool_call)
        {
          toolCallId: ToolCall.id(tool_call),
          toolName: normalize_tool_name(raw_name) || raw_name,
          args: normalize_tool_args(raw_name, args)
        }.compact
      end

      def normalize_tool_name(name)
        ToolCall.normalized_name(name)
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
          ToolCall.camelize_args(args)
        end
      end

      def normalize_edit_args(args)
        result = {}
        path = ToolCall.value(args, :path)
        result[:path] = path if path
        edits = Array(ToolCall.value(args, :edits)).filter_map do |edit|
          next unless edit.is_a?(Hash)

          {
            oldText: ToolCall.value(edit, :oldText) || ToolCall.value(edit, :old_text),
            newText: ToolCall.value(edit, :newText) || ToolCall.value(edit, :new_text)
          }.compact
        end
        result[:edits] = edits if edits.any?
        result
      end

      def normalize_write_args(args)
        result = {}
        path = ToolCall.value(args, :path)
        content = ToolCall.value(args, :content)
        result[:path] = path if path
        result[:content] = content if content
        result
      end

      def normalize_bash_args(args)
        result = {}
        command = ToolCall.value(args, :command)
        timeout = ToolCall.value(args, :timeout) || ToolCall.value(args, :timeout_seconds) || Workspace::DEFAULT_COMMAND_TIMEOUT_SECONDS
        result[:command] = command if command
        result[:timeout] = timeout if timeout
        result
      end

      def extract_unified_diff(text)
        index = text.to_s.index(/^--- /)
        index ? text.to_s[index..] : nil
      end

      # Returns the first changed line in the post-edit file from a unified diff.
      # A deletion-only hunk uses the next surviving new-file line as its anchor.
      def first_changed_line(diff)
        new_line = nil

        diff.to_s.each_line do |line|
          if (match = line.match(/^@@ -\d+(?:,\d+)? \+(\d+)(?:,\d+)? @@/))
            new_line = match[1].to_i
          elsif new_line
            case line
            when /^\+[^+]/
              return new_line
            when /^-[^-]/
              return new_line
            when /^ /
              new_line += 1
            end
          end
        end

        nil
      end

      def changed_files_from_result(text, matching_call = nil)
        path = matching_call&.dig(:arguments, :path) || matching_call&.dig(:arguments, "path")
        return [path] if path

        if (match = text.to_s.match(/\A(?:Wrote \d+ bytes to|Edited)\s+([^:\n]+)/))
          [match[1].strip]
        else
          []
        end
      end

      def error_result?(text)
        text.to_s.start_with?("Error:", "Declined:", "Cancelled.")
      end
    end
  end
end
