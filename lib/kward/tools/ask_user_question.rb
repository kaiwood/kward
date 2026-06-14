require_relative "../question_contract"
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
        QuestionContract.normalize_questions(argument(args, :questions))
      rescue ArgumentError => e
        "Error: #{tool_error_message(e.message)}."
      end

      def tool_error_message(message)
        case message
        when "questions must be an array"
          "ask_user_question requires questions"
        when "ui/question requires 1-4 questions"
          "ask_user_question requires 1 to 4 questions"
        else
          message.gsub("2-4", "2 to 4")
                 .gsub("multiSelect is unsupported", "uses unsupported multiSelect")
                 .gsub("preview is unsupported", "uses unsupported preview")
        end
      end
    end
  end
end
