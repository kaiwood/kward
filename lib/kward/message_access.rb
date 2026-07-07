# Namespace for the Kward CLI agent runtime.
module Kward
  # Compatibility reader for persisted conversation message hashes.
  #
  # Kward stores transcript entries as plain hashes because model payloads,
  # JSONL sessions, plugins, and RPC normalizers all need to pass them around
  # without framework objects. Restored sessions may contain either symbol keys,
  # string keys, or camelCase aliases. `MessageAccess` centralizes those lookup
  # rules so callers do not grow one-off compatibility branches.
  module MessageAccess
    module_function

    # Reads a field from a hash-like object using symbol or string keys.
    #
    # @param object [#key?, nil] hash-like object to read
    # @param key [String, Symbol] canonical field name
    # @return [Object, nil] stored value when present
    def value(object, key)
      return nil unless object.respond_to?(:key?)
      return object[key] if object.key?(key)
      return object[key.to_s] if object.key?(key.to_s)

      nil
    end

    # @return [String, nil] message role such as `user`, `assistant`, or `tool`
    def role(message)
      value(message, :role)
    end

    # @return [Object, nil] raw message content
    def content(message)
      value(message, :content)
    end

    # @return [String, nil] UI-facing content preserved separately from model input
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

    # @return [Array<Hash>] assistant tool calls, or an empty array
    def tool_calls(message)
      calls = value(message, :tool_calls) || value(message, :toolCalls)
      calls.is_a?(Array) ? calls : []
    end

    # @return [Array<Hash>] provider-native Responses output items, or an empty array
    def response_items(message)
      items = value(message, :response_items) || value(message, :responseItems)
      items.is_a?(Array) ? items : []
    end
  end
end
