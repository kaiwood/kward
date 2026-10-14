require "securerandom"
require_relative "../model/client"

module Kward
  # Adapts Kward's normal Codex provider stream to the plugin Responses event
  # contract without exposing the configured credentials.
  class PluginCodexResponses
    class AuthenticationError < StandardError; end

    class RequestError < StandardError
      attr_reader :status

      def initialize(status)
        @status = status.to_i
        super("Codex request failed (HTTP #{@status})")
      end
    end

    def initialize(client: Kward::Client.new)
      @client = client
    end

    # Streams Kward Codex events using the normal configured Codex credentials
    # and endpoint, translating them to Responses-shaped events for plugins.
    def stream(model:, input:, instructions: nil, text: nil, max_output_tokens: nil, cancellation: nil)
      messages = input_messages(input, instructions)
      output_text = +""
      emit_text = lambda do |delta|
        next unless delta.is_a?(String) && !delta.empty?

        output_text << delta
        yield "type" => "response.output_text.delta", "delta" => delta
      end

      result = @client.chat(
        messages,
        provider: "codex",
        provider_required: true,
        model: model,
        max_tokens: max_output_tokens,
        text_format: text,
        cancellation: cancellation,
        on_assistant_delta: emit_text
      )
      emit_text.call(result["content"]) if output_text.empty? && result["content"].is_a?(String)
      yield "type" => "response.completed", "response" => { "id" => "codex-#{SecureRandom.hex(12)}", "usage" => result["usage"] }
      nil
    rescue Kward::Client::AuthenticationError => error
      raise AuthenticationError, error.message
    rescue Kward::Client::RequestError => error
      raise RequestError, error.code
    end

    private

    def input_messages(input, instructions)
      raise ArgumentError, "Codex input must be an array of messages" unless input.is_a?(Array)

      messages = []
      messages << { role: "system", content: instructions } if instructions.is_a?(String) && !instructions.empty?
      input.each_with_index do |item, index|
        role = item["role"] || item[:role] if item.is_a?(Hash)
        content = item.key?("content") ? item["content"] : item[:content] if item.is_a?(Hash)
        unless %w[user assistant].include?(role) && content.is_a?(String)
          raise ArgumentError, "Codex input message #{index} must have a supported role and string content"
        end

        messages << { role: role, content: content }
      end
      messages
    end
  end
end
