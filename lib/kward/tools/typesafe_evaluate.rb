require "json"
require_relative "base"
require_relative "../model/typesafe_client"

module Kward
  module Tools
    # Evaluates bounded state with TypeSafe's typed decision model.
    class TypeSafeEvaluate < Base
      def initialize(client: TypeSafeClient.new)
        @client = client
        super(
          "typesafe_evaluate",
          "Evaluate text with TypeSafe and return typed decisions, probabilities, and confidence. Use for classification, scoring, routing, or verification; this does not generate text.",
          properties: {
            state: {
              type: "string",
              description: "The text or structured state to evaluate; do not include secrets unless explicitly requested."
            },
            model: {
              type: "string",
              description: "TypeSafe model ID or alias; defaults to jev-latest."
            },
            questions: {
              type: "object",
              description: "Named typed questions. Each value must be a noul, choice, or score question.",
              additionalProperties: {
                type: "object",
                properties: {
                  type: { type: "string", enum: %w[noul choice score] },
                  instructions: { type: "string" },
                  criteria: { type: ["object", "array"] }
                },
                required: %w[type instructions],
                additionalProperties: false
              }
            }
          },
          required: %w[state questions]
        )
      end

      def call(args, _conversation, cancellation: nil)
        state = argument(args, "state").to_s
        questions = argument(args, "questions")
        error = validate(state, questions)
        return "Error: #{error}" if error

        response = @client.evaluate(
          state: state,
          questions: questions,
          model: argument(args, "model") || TypeSafeClient::DEFAULT_MODEL,
          cancellation: cancellation
        )
        JSON.pretty_generate(response)
      rescue TypeSafeClient::RequestError => e
        "Error: #{e.message}"
      rescue JSON::GeneratorError, TypeError => e
        "Error: invalid TypeSafe response: #{e.message}"
      end

      private

      def validate(state, questions)
        return "state must be a non-empty string" if state.empty?
        return "state exceeds #{TypeSafeClient::MAX_STATE_BYTES} bytes" if state.bytesize > TypeSafeClient::MAX_STATE_BYTES
        return "questions must be an object" unless questions.is_a?(Hash)
        return "questions must contain 1-#{TypeSafeClient::MAX_QUESTIONS} entries" if questions.empty? || questions.length > TypeSafeClient::MAX_QUESTIONS

        questions.each do |name, question|
          return "question names must be non-empty strings" unless name.is_a?(String) && !name.empty?
          return "question #{name.inspect} must be an object" unless question.is_a?(Hash)
          type = argument(question, "type").to_s
          return "question #{name.inspect} has unsupported type" unless %w[noul choice score].include?(type)
          return "question #{name.inspect} needs instructions" if argument(question, "instructions").to_s.empty?
          return "question #{name.inspect} needs criteria" if %w[choice score].include?(type) && !argument(question, "criteria")
        end
        nil
      end
    end
  end
end
