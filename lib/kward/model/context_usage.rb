require "json"
require_relative "../message_access"

# Namespace for the Kward CLI agent runtime.
module Kward
  # Estimates provider context usage and compaction pressure.
  class ContextUsage
    def initialize(token_counter: TiktokenTokenCounter.new)
      @token_counter = token_counter
    end

    def call(provider:, model:, context_window:, context_parts:)
      return nil unless context_window

      parts = redact_image_data(stringify_top_level_keys(context_parts || {}))
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

    def redact_image_data(value)
      case value
      when Hash
        value.each_with_object({}) do |(key, item), result|
          result[key] = image_data_key?(key) ? "[image omitted from token estimate]" : redact_image_data(item)
        end
      when Array
        value.map { |item| redact_image_data(item) }
      else
        value
      end
    end

    def image_data_key?(key)
      ["data", "image_url"].include?(key.to_s)
    end

    def stringify_top_level_keys(value)
      return value unless value.is_a?(Hash)

      value.each_with_object({}) { |(key, item), result| result[key.to_s] = item }
    end
  end

  # Structured context usage result returned to frontends.
  class TiktokenTokenCounter
    def count(text, model:)
      text = text.to_s
      tokenizer = encoding(model)
      return rough_count(text) unless tokenizer.respond_to?(:encode)

      tokenizer.encode(text).length
    rescue StandardError
      rough_count(text)
    end

    private

    def encoding(model)
      require "tiktoken_ruby"

      Tiktoken.encoding_for_model(model.to_s) || Tiktoken.get_encoding(encoding_name_for_model(model))
    rescue StandardError
      Tiktoken.get_encoding(encoding_name_for_model(model)) if defined?(Tiktoken)
    end

    def rough_count(text)
      [(text.length / 4.0).ceil, 1].max
    end

    def encoding_name_for_model(model)
      id = model.to_s
      return "o200k_base" if id.start_with?("gpt-5", "gpt-4.1", "gpt-4o", "o3", "o4")
      return "cl100k_base" if id.start_with?("gpt-4", "gpt-3.5")

      "o200k_base"
    end
  end
end
