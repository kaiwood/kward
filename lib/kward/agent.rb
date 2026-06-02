require_relative "conversation"
require_relative "tool_registry"

module Kward
  class Agent
    def initialize(client:, tool_registry: ToolRegistry.new, conversation: Conversation.new)
      @client = client
      @tool_registry = tool_registry
      @conversation = conversation
    end

    attr_reader :conversation

    def ask(input)
      @conversation.append_user(input)
      run_turn
    end

    def run_turn
      loop do
        message = @client.chat(@conversation.messages, tools: @tool_registry.schemas)
        @conversation.append_assistant(message)

        tool_calls = message["tool_calls"] || message[:tool_calls] || []
        return safe_answer(message.fetch("content", message[:content] || "")) if tool_calls.empty?

        tool_calls.each { |tool_call| @tool_registry.dispatch(tool_call, @conversation) }
      end
    end

    private

    def safe_answer(content)
      text = content.to_s
      return text unless claims_file_edit?(text)
      return text if last_write_succeeded?
      return "write_file returned an error or declined result, so I did not successfully change the file." if @conversation.last_write_result

      "I have not changed any files. I need to use write_file successfully before claiming a file change."
    end

    def claims_file_edit?(text)
      text.match?(/\b(I|I've|I have)\s+(changed|updated|modified|edited|created|deleted|wrote)\b/i)
    end

    def last_write_succeeded?
      @conversation.last_write_result&.fetch(:content, "")&.start_with?("Wrote ")
    end
  end
end
