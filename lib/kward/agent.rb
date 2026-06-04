require_relative "cancellation"
require_relative "compactor"
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

    def ask(input, on_reasoning_delta: nil, cancellation: nil, &block)
      cancellation&.raise_if_cancelled!
      @conversation.refresh_system_message_if_workspace_agents_changed!
      @conversation.append_user(input)
      auto_compact_if_needed
      run_turn(on_reasoning_delta: on_reasoning_delta, cancellation: cancellation, &block)
    end

    def run_turn(on_reasoning_delta: nil, cancellation: nil)
      loop do
        cancellation&.raise_if_cancelled!
        message = chat(on_reasoning_delta: on_reasoning_delta, cancellation: cancellation) do |event|
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
          cancellation&.raise_if_cancelled!
          yield Events::ToolCall.new(tool_call: tool_call) if block_given?
          content = @tool_registry.dispatch(tool_call, @conversation, cancellation: cancellation)
          cancellation&.raise_if_cancelled!
          yield Events::ToolResult.new(tool_call: tool_call, content: content) if block_given?
        end
      end
    end

    private

    def auto_compact_if_needed
      context_window = @client.current_context_window if @client.respond_to?(:current_context_window)
      Compactor.new(conversation: @conversation, client: @client).auto_compact_if_needed(context_window: context_window)
    rescue StandardError => e
      warn "Auto-compaction failed: #{e.message}"
      nil
    end

    def chat(on_reasoning_delta: nil, cancellation: nil)
      reasoning_delta = lambda do |delta|
        cancellation&.raise_if_cancelled!
        on_reasoning_delta&.call(delta)
        yield Events::ReasoningDelta.new(delta: delta) if block_given?
      end
      assistant_delta = lambda do |delta|
        cancellation&.raise_if_cancelled!
        yield Events::AssistantDelta.new(delta: delta) if block_given?
      end
      @client.chat(@conversation.messages, tools: @tool_registry.schemas, on_reasoning_delta: reasoning_delta, on_assistant_delta: assistant_delta, cancellation: cancellation)
    rescue ArgumentError => e
      raise unless e.message.include?("on_reasoning_delta") || e.message.include?("on_assistant_delta") || e.message.include?("cancellation")

      begin
        @client.chat(@conversation.messages, tools: @tool_registry.schemas, on_reasoning_delta: reasoning_delta, on_assistant_delta: assistant_delta)
      rescue ArgumentError => retry_error
        raise unless retry_error.message.include?("on_reasoning_delta") || retry_error.message.include?("on_assistant_delta")

        @client.chat(@conversation.messages, tools: @tool_registry.schemas)
      end
    end

    def safe_answer(content)
      text = content.to_s
      return text unless claims_file_edit?(text)
      return text if last_file_change_succeeded?
      return "The file change tool returned an error or declined result, so I did not successfully change the file." if @conversation.last_file_change_result

      "I have not changed any files. I need to use write_file or edit_file successfully before claiming a file change."
    end

    def claims_file_edit?(text)
      text.match?(/\b(I|I've|I have)\s+(changed|updated|modified|edited|created|deleted|wrote)\b/i)
    end

    def last_file_change_succeeded?
      result = @conversation.last_file_change_result
      content = result&.fetch(:content, nil) || result&.fetch("content", "")
      content&.start_with?("Wrote ", "Edited ")
    end
  end
end
