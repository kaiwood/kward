require "json"
require_relative "message_access"

module Kward
  class ContextUsage
    OPENAI_CONTEXT_PROVIDERS = ["Codex", "OpenAI"].freeze

    def initialize(token_counter: TiktokenTokenCounter.new)
      @token_counter = token_counter
    end

    def call(provider:, model:, context_window:, context_parts:)
      return nil unless OPENAI_CONTEXT_PROVIDERS.include?(provider.to_s)
      return nil unless context_window
      return nil if contains_image?(context_parts)

      parts = stringify_keys(context_parts || {})
      return nil unless contains_session_content?(parts)

      payload = prompt_payload(parts)
      return nil if payload.empty?

      tokens = @token_counter.count(JSON.generate(payload), model: model)
      {
        tokens: tokens,
        contextWindow: context_window,
        percent: ((tokens.to_f / context_window.to_i) * 100).round(2),
        estimated: true
      }
    rescue LoadError
      nil
    end

    private

    def prompt_payload(parts)
      payload = {}
      if parts.key?("instructions")
        payload[:instructions] = parts["instructions"]
      elsif parts.key?("messages")
        payload[:messages] = parts["messages"]
      end
      payload[:input] = parts["input"] if parts.key?("input")
      payload[:tools] = parts["tools"] if parts.key?("tools")
      payload.compact
    end

    def contains_session_content?(parts)
      input = parts["input"]
      return !input.empty? if input.is_a?(Array)
      return !input.to_s.empty? if parts.key?("input")

      messages = parts["messages"]
      return messages.any? { |message| MessageAccess.role(message) != "system" } if messages.is_a?(Array)

      false
    end

    def contains_image?(value)
      case value
      when Hash
        type = value[:type] || value["type"]
        return true if ["image", "input_image", "image_url"].include?(type.to_s)
        return true if value.key?(:image_url) || value.key?("image_url")

        value.any? { |_key, item| contains_image?(item) }
      when Array
        value.any? { |item| contains_image?(item) }
      else
        false
      end
    end

    def stringify_keys(value)
      return value unless value.is_a?(Hash)

      value.each_with_object({}) { |(key, item), result| result[key.to_s] = item }
    end
  end

  class TiktokenTokenCounter
    def count(text, model:)
      encoding(model).encode(text.to_s).length
    end

    private

    def encoding(model)
      require "tiktoken_ruby"

      Tiktoken.encoding_for_model(model.to_s)
    rescue StandardError
      Tiktoken.get_encoding(encoding_name_for_model(model))
    end

    def encoding_name_for_model(model)
      id = model.to_s
      return "o200k_base" if id.start_with?("gpt-5", "gpt-4.1", "gpt-4o", "o3", "o4")
      return "cl100k_base" if id.start_with?("gpt-4", "gpt-3.5")

      "o200k_base"
    end
  end
end
