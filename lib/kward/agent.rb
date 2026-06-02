require_relative "conversation"
require_relative "events"
require_relative "tool_registry"

module Kward
  class Agent
    def initialize(client:, tool_registry: ToolRegistry.new, conversation: Conversation.new)
      @client = client
      @tool_registry = tool_registry
      @conversation = conversation
    end

    attr_reader :conversation

    def ask(input, on_reasoning_delta: nil, &block)
      @conversation.append_user(input)
      run_turn(on_reasoning_delta: on_reasoning_delta, &block)
    end

    def run_turn(on_reasoning_delta: nil)
      loop do
        message = chat(on_reasoning_delta: on_reasoning_delta) do |event|
          yield event if block_given?
        end
        yield Events::AssistantMessage.new(message: message) if block_given?
        @conversation.append_assistant(message)

        tool_calls = message["tool_calls"] || message[:tool_calls] || []
        if tool_calls.empty?
          answer = safe_answer(message.fetch("content", message[:content] || ""))
          yield Events::Answer.new(content: answer) if block_given?
          return answer
        end

        tool_calls.each do |tool_call|
          yield Events::ToolCall.new(tool_call: tool_call) if block_given?
          content = @tool_registry.dispatch(tool_call, @conversation)
          yield Events::ToolResult.new(tool_call: tool_call, content: content) if block_given?
        end
      end
    end

    private

    def chat(on_reasoning_delta: nil)
      reasoning_delta = lambda do |delta|
        on_reasoning_delta&.call(delta)
        yield Events::ReasoningDelta.new(delta: delta) if block_given?
      end
      assistant_delta = lambda do |delta|
        yield Events::AssistantDelta.new(delta: delta) if block_given?
      end
      @client.chat(@conversation.messages, tools: @tool_registry.schemas, on_reasoning_delta: reasoning_delta, on_assistant_delta: assistant_delta)
    rescue ArgumentError => e
      raise unless e.message.include?("on_reasoning_delta") || e.message.include?("on_assistant_delta")

      @client.chat(@conversation.messages, tools: @tool_registry.schemas)
    end

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
