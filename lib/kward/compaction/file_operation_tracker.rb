require_relative "../message_access"
require_relative "../tools/tool_call"

module Kward
  module Compaction
    class FileOperationTracker
      def call(messages, previous_details: {})
        read_files = Array(path_values(previous_details, "read_files", :read_files))
        modified_files = Array(path_values(previous_details, "modified_files", :modified_files))

        Array(messages).each do |message|
          next unless MessageAccess.role(message) == "assistant"

          MessageAccess.tool_calls(message).each do |tool_call|
            name = ToolCall.name(tool_call)
            args = ToolCall.arguments(tool_call)
            path = args["path"] || args[:path]
            case name
            when "read_file"
              read_files << path if path
            when "write_file", "edit_file"
              modified_files << path if path
            end
          end
        end

        {
          read_files: sorted_paths(read_files),
          modified_files: sorted_paths(modified_files)
        }
      end

      private

      def sorted_paths(paths)
        paths.map(&:to_s).reject(&:empty?).uniq.sort
      end

      def path_values(hash, string_key, symbol_key)
        return [] unless hash.respond_to?(:key?)

        hash[string_key] || hash[symbol_key] || []
      end
    end
  end
end
