require "json"
require_relative "../message_access"

# Namespace for the Kward CLI agent runtime.
module Kward
  # Reads and normalizes model tool-call hashes.
  #
  # Tool calls arrive from several providers and may be restored from session
  # files. This module keeps provider/string/symbol compatibility in one place
  # and exposes small helpers used by the agent loop, tool registry, transcript
  # formatters, and RPC event normalizers.
  module ToolCall
    TOOL_NAME_MAP = {
      "read_file" => "read",
      "edit_file" => "edit",
      "write_file" => "write",
      "run_shell_command" => "bash",
      "list_directory" => "list_directory",
      "code_search" => "code_search",
      "summarize_file_structure" => "summarize_file_structure",
      "retrieve_tool_output" => "retrieve_tool_output",
      "web_search" => "web_search",
      "fetch_content" => "fetch_content",
      "fetch_raw" => "fetch_raw",
      "read_skill" => "read_skill",
      "ask_user_question" => "ask_user_question"
    }.freeze

    module_function

    # @return [String, nil] provider tool-call id
    def id(tool_call)
      value(tool_call, :id)
    end

    # @return [String, nil] requested tool/function name
    def name(tool_call)
      value(function(tool_call), :name)
    end

    # Returns the short name used in compact UI labels.
    #
    # @return [String] display label such as `read`, `edit`, or `bash`
    def display_name(tool_call)
      raw_name = name(tool_call)
      normalized_name(raw_name) || raw_name || "unknown_tool"
    end

    # Parses the requested tool arguments.
    #
    # @return [Hash] decoded argument object, or an empty hash for invalid JSON
    def arguments(tool_call)
      parse_arguments(raw_arguments(tool_call))
    end

    def raw_arguments(tool_call)
      value(function(tool_call), :arguments)
    end

    def function(tool_call)
      value(tool_call, :function) || {}
    end

    def normalized_name(name)
      TOOL_NAME_MAP[name.to_s]
    end

    # Converts provider argument payloads into hashes.
    #
    # Providers normally send JSON strings, while tests and compatibility callers
    # may pass hashes directly.
    def parse_arguments(arguments)
      return {} if arguments.nil? || (arguments.respond_to?(:empty?) && arguments.empty?)
      return arguments if arguments.is_a?(Hash)

      JSON.parse(arguments.to_s)
    rescue JSON::ParserError
      {}
    end

    # Recursively converts snake_case hash keys to camelCase symbols.
    #
    # @return [Hash] camelized copy of `args`
    def camelize_args(args)
      return {} unless args.is_a?(Hash)

      args.each_with_object({}) do |(key, item), result|
        result[camelize_key(key)] = camelize_value(item)
      end
    end

    def value(object, key)
      MessageAccess.value(object, key)
    end

    def camelize_value(item)
      case item
      when Hash
        camelize_args(item)
      when Array
        item.map { |entry| camelize_value(entry) }
      else
        item
      end
    end

    def camelize_key(key)
      key.to_s.gsub(/_([a-z])/) { Regexp.last_match(1).upcase }.to_sym
    end
  end
end
