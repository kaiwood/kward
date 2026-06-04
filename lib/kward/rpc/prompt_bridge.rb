require "securerandom"

module Kward
  module RPC
    class PromptBridge
      MIN_QUESTIONS = 1
      MAX_QUESTIONS = 4
      MIN_OPTIONS = 2
      MAX_OPTIONS = 4

      def initialize(server:, session_id:)
        @server = server
        @session_id = session_id
        @mutex = Mutex.new
        @condition = ConditionVariable.new
        @answers = {}
      end

      def ask_user_question(questions)
        questions = validate_questions(questions)
        request_id = SecureRandom.uuid
        @server.notify("ui/question", {
          sessionId: @session_id,
          questionRequestId: request_id,
          questions: questions
        })

        @mutex.synchronize do
          @condition.wait(@mutex) until @answers.key?(request_id)
          answer = @answers.delete(request_id)
          return nil if answer.nil?

          answer
        end
      end

      def answer(request_id, answers)
        @mutex.synchronize do
          @answers[request_id.to_s] = answers
          @condition.broadcast
        end
      end

      private

      def validate_questions(questions)
        raise ArgumentError, "questions must be an array" unless questions.is_a?(Array)
        unless questions.length.between?(MIN_QUESTIONS, MAX_QUESTIONS)
          raise ArgumentError, "ui/question requires 1-4 questions"
        end

        questions.each_with_index do |question, index|
          validate_question(question, index)
        end
        questions
      end

      def validate_question(question, index)
        raise ArgumentError, "question #{index + 1} must be an object" unless question.is_a?(Hash)

        options = value(question, :options)
        raise ArgumentError, "question #{index + 1} options must be an array" unless options.is_a?(Array)
        unless options.length.between?(MIN_OPTIONS, MAX_OPTIONS)
          raise ArgumentError, "question #{index + 1} requires 2-4 options"
        end
        raise ArgumentError, "question #{index + 1} multiSelect is unsupported" if value(question, :multiSelect) == true
        raise ArgumentError, "question #{index + 1} preview is unsupported" if options.any? { |option| option.is_a?(Hash) && value(option, :preview) }
      end

      def value(object, key)
        return nil unless object.respond_to?(:key?)
        return object[key] if object.key?(key)
        return object[key.to_s] if object.key?(key.to_s)

        nil
      end
    end
  end
end
