require "securerandom"
require_relative "../message_access"

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
        @pending_requests = {}
      end

      def ask_user_question(questions, cancellation: nil)
        questions = validate_questions(questions)
        request_id = SecureRandom.uuid
        @mutex.synchronize { @pending_requests[request_id] = true }
        cancellation&.on_cancel { cancel_request(request_id) }
        unless cancellation&.cancelled?
          @server.notify("ui/question", {
            sessionId: @session_id,
            questionRequestId: request_id,
            questions: questions
          })
        end

        @mutex.synchronize do
          @condition.wait(@mutex) until @answers.key?(request_id)
          answer = @answers.delete(request_id)
          @pending_requests.delete(request_id)
          return nil if answer.nil?

          answer
        end
      end

      def answer(request_id, answers)
        @mutex.synchronize do
          request_id = request_id.to_s
          return unless @pending_requests.key?(request_id)
          return if @answers.key?(request_id)

          @answers[request_id] = normalize_answers(answers)
          @condition.broadcast
        end
      end

      def cancel_request(request_id)
        @mutex.synchronize do
          request_id = request_id.to_s
          return unless @pending_requests.key?(request_id)
          return if @answers.key?(request_id)

          @answers[request_id] = nil
          @condition.broadcast
        end
      end

      private

      def normalize_answers(answers)
        return nil if answers.nil?
        return answers unless answers.is_a?(Array)

        answers.map do |answer|
          next answer unless answer.is_a?(Hash)

          { question: MessageAccess.value(answer, :question).to_s, answer: MessageAccess.value(answer, :answer).to_s }
        end
      end

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

        options = MessageAccess.value(question, :options)
        raise ArgumentError, "question #{index + 1} options must be an array" unless options.is_a?(Array)
        unless options.length.between?(MIN_OPTIONS, MAX_OPTIONS)
          raise ArgumentError, "question #{index + 1} requires 2-4 options"
        end
        raise ArgumentError, "question #{index + 1} multiSelect is unsupported" if MessageAccess.value(question, :multiSelect) == true
        raise ArgumentError, "question #{index + 1} preview is unsupported" if options.any? { |option| option.is_a?(Hash) && MessageAccess.value(option, :preview) }
      end
    end
  end
end
