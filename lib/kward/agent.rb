require_relative "cancellation"
require_relative "chat_invocation"
require_relative "compactor"
require_relative "context_overflow"
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

    def ask(input, on_reasoning_delta: nil, on_retry: nil, cancellation: nil, &block)
      cancellation&.raise_if_cancelled!
      @conversation.refresh_system_message_if_workspace_agents_changed!
      @conversation.append_user(input)
      auto_compact_if_needed
      run_turn(on_reasoning_delta: on_reasoning_delta, on_retry: on_retry, cancellation: cancellation, &block)
    end

    def run_turn(on_reasoning_delta: nil, on_retry: nil, cancellation: nil)
      overflow_retried = false
      loop do
        cancellation&.raise_if_cancelled!
        begin
          message = chat(on_reasoning_delta: on_reasoning_delta, on_retry: on_retry, cancellation: cancellation) do |event|
            yield event if block_given?
          end
        rescue StandardError => e
          raise if cancellation&.cancelled?
          raise unless !overflow_retried && ContextOverflow.error?(e) && compact_after_context_overflow(e)

          overflow_retried = true
          next
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

    def compact_after_context_overflow(error)
      settings = Compaction::Settings.from_config
      return nil unless settings.enabled

      Compactor.new(conversation: @conversation, client: @client, settings: settings).compact(
        custom_instructions: "The previous model request exceeded the context window. Preserve the current task state and critical details needed to retry."
      )
    rescue Compaction::NothingToCompact, Compaction::AlreadyCompacted, StandardError => compaction_error
      warn "Context overflow recovery failed: #{compaction_error.message}; original error: #{error.message}"
      nil
    end

    def chat(on_reasoning_delta: nil, on_retry: nil, cancellation: nil)
      reasoning_delta = lambda do |delta|
        cancellation&.raise_if_cancelled!
        on_reasoning_delta&.call(delta)
        yield Events::ReasoningDelta.new(delta: delta) if block_given?
      end
      assistant_delta = lambda do |delta|
        cancellation&.raise_if_cancelled!
        yield Events::AssistantDelta.new(delta: delta) if block_given?
      end
      retry_callback = lambda do |retry_info|
        cancellation&.raise_if_cancelled!
        event = Events::Retry.new(**retry_info)
        on_retry&.call(event)
        yield event if block_given?
      end
      ChatInvocation.call(
        @client,
        @conversation.messages,
        {
          tools: @tool_registry.schemas,
          on_reasoning_delta: reasoning_delta,
          on_assistant_delta: assistant_delta,
          on_retry: retry_callback,
          cancellation: cancellation
        }
      )
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
