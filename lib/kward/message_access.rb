module Kward
  module MessageAccess
    module_function

    def value(object, key)
      return nil unless object.respond_to?(:key?)
      return object[key] if object.key?(key)
      return object[key.to_s] if object.key?(key.to_s)

      nil
    end

    def role(message)
      value(message, :role)
    end

    def content(message)
      value(message, :content)
    end

    def display_content(message)
      value(message, :display_content) || value(message, :displayContent)
    end

    def summary(message)
      value(message, :summary)
    end

    def name(message)
      value(message, :name)
    end

    def tool_call_id(message)
      value(message, :tool_call_id) || value(message, :toolCallId)
    end

    def tool_name(message)
      value(message, :name) || value(message, :toolName)
    end

    def tool_calls(message)
      calls = value(message, :tool_calls) || value(message, :toolCalls)
      calls.is_a?(Array) ? calls : []
    end
  end
end
