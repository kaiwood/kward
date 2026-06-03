require "securerandom"

module Kward
  module RPC
    class PromptBridge
      def initialize(server:, session_id:)
        @server = server
        @session_id = session_id
        @mutex = Mutex.new
        @condition = ConditionVariable.new
        @answers = {}
      end

      def ask_user_question(questions)
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
    end
  end
end
