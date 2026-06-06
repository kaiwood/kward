require_relative "base"

module Kward
  module Tools
    class AskUserQuestion < Base
      def initialize(prompt:)
        @prompt = prompt
        super(
          "ask_user_question",
          "Ask the user one to four structured clarification questions in interactive mode. Supports single-select choices and custom typed answers.",
          properties: {
            questions: {
              type: "array",
              minItems: 1,
              maxItems: 4,
              items: {
                type: "object",
                properties: {
                  question: { type: "string", description: "The question to ask." },
                  header: { type: "string", description: "Short label shown in the overlay." },
                  options: {
                    type: "array",
                    minItems: 2,
                    maxItems: 4,
                    items: {
                      type: "object",
                      properties: {
                        label: { type: "string", description: "Choice label." },
                        description: { type: "string", description: "Choice explanation." }
                      },
                      required: ["label", "description"],
                      additionalProperties: false
                    }
                  }
                },
                required: ["question", "header", "options"],
                additionalProperties: false
              }
            }
          },
          required: ["questions"]
        )
      end

      def call(args, _conversation, cancellation: nil)
        return "Error: ask_user_question requires interactive prompt support." unless @prompt.respond_to?(:ask_user_question)

        questions = validated_questions(args)
        return questions if questions.is_a?(String)

        answers = prompt_ask_user_question(questions, cancellation: cancellation)
        return "Cancelled." if answers.nil?

        answers.map { |answer| "#{answer[:question]}: #{answer[:answer]}" }.join("\n")
      end

      private

      def prompt_ask_user_question(questions, cancellation: nil)
        method = @prompt.method(:ask_user_question)
        supports_cancellation = method.parameters.any? do |type, name|
          type == :keyrest || (type == :key && name == :cancellation) || (type == :keyreq && name == :cancellation)
        end
        return @prompt.ask_user_question(questions, cancellation: cancellation) if supports_cancellation

        @prompt.ask_user_question(questions)
      end

      def validated_questions(args)
        questions = argument(args, :questions)
        return "Error: ask_user_question requires questions." unless questions.is_a?(Array)
        return "Error: ask_user_question requires 1 to 4 questions." unless questions.length.between?(1, 4)

        questions.map.with_index(1) do |question, index|
          return "Error: question #{index} must be an object." unless question.respond_to?(:key?)
          return "Error: question #{index} uses unsupported multiSelect." if question.key?("multiSelect") || question.key?(:multiSelect)

          text = question_value(question, :question).to_s.strip
          header = question_value(question, :header).to_s.strip
          options = question_value(question, :options)
          return "Error: question #{index} requires question and header." if text.empty? || header.empty?
          return "Error: question #{index} requires 2 to 4 options." unless options.is_a?(Array) && options.length.between?(2, 4)

          normalized_options = options.map.with_index(1) do |option, option_index|
            return "Error: question #{index} option #{option_index} must be an object." unless option.respond_to?(:key?)
            return "Error: question #{index} option #{option_index} uses unsupported preview." if option.key?("preview") || option.key?(:preview)

            label = question_value(option, :label).to_s.strip
            description = question_value(option, :description).to_s.strip
            return "Error: question #{index} option #{option_index} requires label and description." if label.empty? || description.empty?

            { label: label, description: description }
          end

          { question: text, header: header, options: normalized_options }
        end
      end

      def question_value(object, key)
        return object[key] if object.key?(key)
        return object[key.to_s] if object.key?(key.to_s)

        nil
      end
    end
  end
end
