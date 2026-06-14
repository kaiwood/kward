require "json"
require_relative "tools/tool_call"

# Namespace for the Kward CLI agent runtime.
module Kward
  # Formats persisted tool calls for compact session tree rows.
  #
  # Both the terminal session tree and the RPC session tree need the same short
  # labels for tool result nodes. Keeping that display rule here prevents the two
  # frontends from drifting while leaving each frontend free to render its own
  # tree prefixes and wire payloads.
  module SessionTreeToolDisplay
    module_function

    # Returns a concise bracketed label for a tool call.
    #
    # @param tool_call [Hash] OpenAI/Codex-style tool call hash
    # @return [String] label such as `[read: README.md:2-4]`
    def label(tool_call)
      name = ToolCall.display_name(tool_call)
      args = ToolCall.arguments(tool_call)
      case name
      when "read"
        read_label(args)
      when "write", "edit"
        path = args["path"] || args[:path] || args["file_path"] || args[:file_path]
        "[#{name}: #{path}]"
      when "bash"
        command = (args["command"] || args[:command]).to_s.gsub(/[\n\t]/, " ").strip
        "[bash: #{truncate(command, 50)}]"
      else
        serialized = JSON.dump(args)
        "[#{name}: #{truncate(serialized, 40)}]"
      end
    end

    def read_label(args)
      path = args["path"] || args[:path] || args["file_path"] || args[:file_path]
      offset = args["offset"] || args[:offset]
      limit = args["limit"] || args[:limit]
      display = path.to_s
      if offset || limit
        start_line = offset || 1
        end_line = limit ? start_line.to_i + limit.to_i - 1 : nil
        display += ":#{start_line}#{end_line ? "-#{end_line}" : ""}"
      end
      "[read: #{display}]"
    end
    private_class_method :read_label

    def truncate(text, length)
      text.length > length ? "#{text.slice(0, length)}..." : text
    end
    private_class_method :truncate
  end
end
