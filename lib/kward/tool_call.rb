require "json"

module Kward
  module ToolCall
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

    module_function

    def id(tool_call)
      value(tool_call, :id)
    end

    def name(tool_call)
      value(function(tool_call), :name)
    end

    def display_name(tool_call)
      raw_name = name(tool_call)
      normalized_name(raw_name) || raw_name || "unknown_tool"
    end

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

    def parse_arguments(arguments)
      return {} if arguments.nil? || (arguments.respond_to?(:empty?) && arguments.empty?)
      return arguments if arguments.is_a?(Hash)

      JSON.parse(arguments.to_s)
    rescue JSON::ParserError
      {}
    end

    def camelize_args(args)
      return {} unless args.is_a?(Hash)

      args.each_with_object({}) do |(key, item), result|
        result[camelize_key(key)] = camelize_value(item)
      end
    end

    def value(object, key)
      return nil unless object.respond_to?(:key?)
      return object[key] if object.key?(key)
      return object[key.to_s] if object.key?(key.to_s)

      nil
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
