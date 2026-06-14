require "securerandom"
require_relative "../message_access"
require_relative "../question_contract"

# Namespace for the Kward CLI agent runtime.
module Kward
  # JSON-RPC backend namespace used by UI clients.
  module RPC
    # RPC prompt bridge for structured user questions.
    class PromptBridge
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
        QuestionContract.normalize_questions(questions)
      end
    end
  end
end
