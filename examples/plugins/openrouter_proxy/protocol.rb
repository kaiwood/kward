require "securerandom"

module Kward
  module OpenRouterProxy
    Request = Struct.new(:model_id, :model, :input, :instructions, :text, :max_output_tokens, :stream, keyword_init: true)

    class RequestError < StandardError
      attr_reader :status

      def initialize(message, status: 400)
        @status = status
        super(message)
      end
    end

    class Protocol
      REQUEST_KEYS = %w[model messages stream response_format max_tokens].freeze
      MESSAGE_ROLES = %w[system user assistant].freeze

      def initialize(model_map:)
        raise ArgumentError, "model_map must be an object" unless model_map.is_a?(Hash)

        @model_map = model_map.each_with_object({}) do |(client_model, codex_model), mapped|
          next unless client_model.is_a?(String) && !client_model.empty?
          next unless codex_model.is_a?(String) && !codex_model.empty?

          mapped[client_model] = codex_model
        end.freeze
      end

      def parse_request(value)
        raise RequestError, "Request body must be an object" unless value.is_a?(Hash)

        unsupported = value.keys.map(&:to_s) - REQUEST_KEYS
        raise RequestError, "Unsupported request fields: #{unsupported.join(', ')}" unless unsupported.empty?

        model_id = value["model"]
        raise RequestError, "A model is required" unless model_id.is_a?(String) && !model_id.empty?

        model = @model_map[model_id]
        raise RequestError, "Model is not configured" unless model

        messages = value["messages"]
        raise RequestError, "Messages must be a non-empty array" unless messages.is_a?(Array) && !messages.empty?

        stream = value.fetch("stream", false)
        raise RequestError, "stream must be a boolean" unless [true, false].include?(stream)

        instructions, input = split_messages(messages)
        raise RequestError, "At least one non-system message is required" if input.empty?

        text = responses_text_format(value["response_format"])
        max_output_tokens = positive_integer(value["max_tokens"], "max_tokens") if value.key?("max_tokens")

        Request.new(
          model_id: model_id,
          model: model,
          input: input,
          instructions: instructions,
          text: text,
          max_output_tokens: max_output_tokens,
          stream: stream
        )
      end

      def responses_request(request)
        result = { model: request.model, input: request.input }
        result[:instructions] = request.instructions unless request.instructions.nil?
        result[:text] = request.text unless request.text.nil?
        result[:max_output_tokens] = request.max_output_tokens if request.max_output_tokens
        result
      end

      def stream_state(request)
        { id: "chatcmpl-#{SecureRandom.hex(12)}", created: Time.now.to_i, model: request.model_id, terminal: false }
      end

      def stream_start_chunk(state)
        chat_chunk(state, delta: { role: "assistant" })
      end

      def stream_chunks(state, event)
        return [] if state[:terminal]

        case event["type"]
        when "response.output_text.delta"
          return [] unless event["delta"].is_a?(String)

          [chat_chunk(state, delta: { content: event["delta"] })]
        when "response.completed"
          state[:terminal] = true
          response = event["response"].is_a?(Hash) ? event["response"] : {}
          chunks = [chat_chunk(state, delta: {}, finish_reason: "stop")]
          chunks << chat_chunk(state, delta: {}, finish_reason: "stop", usage: chat_usage(response["usage"])) if response["usage"].is_a?(Hash)
          chunks
        when "response.failed", "response.incomplete"
          state[:terminal] = true
          [chat_chunk(state, delta: {}, finish_reason: "error", error: { code: "server_error", message: "Codex response did not complete" })]
        else
          []
        end
      end

      def chat_completion(request, events)
        terminal = events.reverse.find { |event| %w[response.completed response.failed response.incomplete].include?(event["type"]) }
        raise RequestError.new("Codex did not complete the response", status: 502) unless terminal&.fetch("type") == "response.completed"

        response = terminal["response"].is_a?(Hash) ? terminal["response"] : {}
        output_text = events.filter_map do |event|
          event["delta"] if event["type"] == "response.output_text.delta" && event["delta"].is_a?(String)
        end.join
        output_text = response_output_text(response) if output_text.empty?

        result = {
          id: response["id"] ? "chatcmpl-#{response['id']}" : "chatcmpl-#{SecureRandom.hex(12)}",
          object: "chat.completion",
          created: Time.now.to_i,
          model: request.model_id,
          choices: [{ index: 0, message: { role: "assistant", content: output_text }, finish_reason: "stop" }]
        }
        result[:usage] = chat_usage(response["usage"]) if response["usage"].is_a?(Hash)
        result
      end

      private

      def split_messages(messages)
        instructions = []
        input = messages.map.with_index do |message, index|
          unless message.is_a?(Hash) && MESSAGE_ROLES.include?(message["role"]) && message["content"].is_a?(String)
            raise RequestError, "Message #{index} must have a supported role and string content"
          end

          if message["role"] == "system"
            instructions << message["content"]
            nil
          else
            { role: message["role"], content: message["content"] }
          end
        end.compact
        [instructions.empty? ? nil : instructions.join("\n\n"), input]
      end

      def responses_text_format(value)
        return nil if value.nil?
        raise RequestError, "response_format must be an object" unless value.is_a?(Hash)
        raise RequestError, "Only json_schema response_format is supported" unless value["type"] == "json_schema"

        schema_format = value["json_schema"]
        unless schema_format.is_a?(Hash) && schema_format["schema"].is_a?(Hash)
          raise RequestError, "response_format.json_schema.schema must be an object"
        end

        format = {
          type: "json_schema",
          name: schema_format["name"].to_s.empty? ? "response" : schema_format["name"].to_s,
          schema: schema_format["schema"],
          strict: schema_format.fetch("strict", true)
        }
        raise RequestError, "response_format.json_schema.strict must be a boolean" unless [true, false].include?(format[:strict])

        { format: format }
      end

      def positive_integer(value, name)
        raise RequestError, "#{name} must be a positive integer" unless value.is_a?(Integer) && value.positive?

        value
      end

      def chat_chunk(state, delta:, finish_reason: nil, usage: nil, error: nil)
        chunk = {
          id: state[:id],
          object: "chat.completion.chunk",
          created: state[:created],
          model: state[:model],
          choices: [{ index: 0, delta: delta, finish_reason: finish_reason }]
        }
        chunk[:usage] = usage if usage
        chunk[:error] = error if error
        chunk
      end

      def response_output_text(response)
        Array(response["output"]).filter_map do |item|
          next unless item.is_a?(Hash) && item["type"] == "message"

          Array(item["content"]).filter_map do |part|
            part["text"] if part.is_a?(Hash) && part["type"] == "output_text"
          end.join
        end.join
      end

      def chat_usage(usage)
        input = usage["input_tokens"].to_i
        output = usage["output_tokens"].to_i
        { prompt_tokens: input, completion_tokens: output, total_tokens: usage["total_tokens"].to_i.positive? ? usage["total_tokens"].to_i : input + output }
      end
    end
  end
end
