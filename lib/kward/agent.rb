require_relative "cancellation"
require_relative "model/chat_invocation"
require_relative "compactor"
require_relative "model/context_overflow"
require_relative "conversation"
require_relative "events"
require_relative "steering"
require_relative "telemetry/logger"
require_relative "tools/registry"

module Kward
  # Runs model turns, handles context compaction, dispatches tool calls, and
  # streams high-level events back to CLI and RPC callers.
  #
  # `Agent` is the main turn orchestrator. It should know what a turn means:
  # append the user's input, call the model, persist assistant/tool messages,
  # retry once after recoverable context overflow, apply in-flight steering, and
  # emit frontend-neutral `Events::*` objects. It should not know terminal or RPC
  # rendering details; callers translate events into their own UI protocol.
  #
  # Tool implementations own local side effects. `Client` owns provider HTTP
  # details. `Conversation` owns transcript state. Keep future changes in the
  # lowest layer that owns the behavior, and use `Agent` only for cross-step turn
  # coordination.
  class Agent
    def initialize(client:, tool_registry: ToolRegistry.new, conversation: Conversation.new, telemetry_logger: TelemetryLogger.new)
      @client = client
      @tool_registry = tool_registry
      @conversation = conversation
      @telemetry_logger = telemetry_logger
    end

    attr_reader :conversation

    # Adds a user message, compacts context when needed, and runs the turn.
    #
    # @param input [String] text sent to the model
    # @param display_input [String, nil] alternate text kept for transcripts
    # @yieldparam event [Object] streamed turn event for frontends
    # @return [String] final assistant answer
    def ask(input, display_input: nil, on_reasoning_delta: nil, on_retry: nil, cancellation: nil, steering: nil, &block)
      started_at = @telemetry_logger.monotonic_now
      status = "completed"
      error = nil
      cancellation&.raise_if_cancelled!
      @conversation.refresh_system_message_if_workspace_agents_changed!
      @conversation.append_user(input, display_content: display_input)
      auto_compact_if_needed
      run_turn(on_reasoning_delta: on_reasoning_delta, on_retry: on_retry, cancellation: cancellation, steering: steering, &block)
    rescue StandardError => e
      status = "failed"
      error = e
      raise e
    ensure
      log_turn(duration_ms: @telemetry_logger.duration_ms(started_at), status: status, error: error)
    end

    # Runs model calls until the assistant returns an answer without pending
    # tool calls, including tool dispatch and one context-overflow retry.
    #
    # @yieldparam event [Object] streamed turn event for frontends
    # @return [String] final assistant answer
    def run_turn(on_reasoning_delta: nil, on_retry: nil, cancellation: nil, steering: nil)
      overflow_retried = false
      steering_state = build_steering_state(steering) do |event|
        yield event if block_given?
      end
      loop do
        cancellation&.raise_if_cancelled!
        begin
          message = chat(on_reasoning_delta: on_reasoning_delta, on_retry: on_retry, cancellation: cancellation, steering: steering) do |event|
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
        steered_after_message = append_steering_events(steering_state)
        yield Events::SteeringApplied.new(count: steered_after_message) if block_given? && steered_after_message.positive?

        tool_calls = message["tool_calls"] || message[:tool_calls] || []
        if tool_calls.empty?
          next if steered_after_message.positive?

          answer = safe_answer(message.fetch("content", message[:content] || ""))
          yield Events::Answer.new(content: answer) if block_given?
          return answer
        end

        tool_calls.each do |tool_call|
          cancellation&.raise_if_cancelled!
          yield Events::ToolCall.new(tool_call: tool_call) if block_given?
          tool_started_at = @telemetry_logger.monotonic_now
          content = nil
          status = "completed"
          error = nil
          begin
            content = @tool_registry.dispatch(tool_call, @conversation, cancellation: cancellation)
          rescue StandardError => e
            status = "failed"
            error = e
            raise e
          ensure
            log_tool(tool_call, content: content, duration_ms: @telemetry_logger.duration_ms(tool_started_at), status: status, error: error)
          end
          cancellation&.raise_if_cancelled!
          yield Events::ToolResult.new(tool_call: tool_call, content: content) if block_given?
        end
        steered_after_tools = append_steering_events(steering_state)
        yield Events::SteeringApplied.new(count: steered_after_tools) if block_given? && steered_after_tools.positive?
      end
    ensure
      steering_state&.fetch(:unsubscribe)&.call
    end

    private

    def build_steering_state(steering)
      return nil unless steering

      state = { events: [], appended: 0, mutex: Mutex.new, unsubscribe: nil }
      state[:unsubscribe] = steering.on_submit do |steering_event|
        state[:mutex].synchronize { state[:events] << steering_event }
        yield Events::Steering.new(input: steering_event.input, created_at: steering_event.created_at)
      end
      state
    end

    def append_steering_events(state)
      return 0 unless state

      events = state[:mutex].synchronize do
        state[:events][state[:appended]..] || []
      end
      events.each do |event|
        @conversation.append_user(event.input)
      end
      state[:mutex].synchronize { state[:appended] += events.length }
      events.length
    end

    def log_turn(duration_ms:, status:, error:)
      payload = { "duration_ms" => duration_ms, "status" => status }
      @telemetry_logger.log("performance", "turn", payload)
      log_error("turn_error", error, payload) if error
    end

    def log_tool(tool_call, content:, duration_ms:, status:, error:)
      payload = {
        "tool_name" => tool_name(tool_call),
        "duration_ms" => duration_ms,
        "status" => status,
        "result_bytes" => content.to_s.bytesize
      }
      @telemetry_logger.log("tools", "tool_call", payload)
      @telemetry_logger.log("performance", "tool_call", payload)
      log_error("tool_error", error, payload) if error
    end

    def log_error(event, error, payload = {})
      return unless error

      @telemetry_logger.log("errors", event, payload.merge(TelemetryLogger.error_payload(error)))
    end

    def tool_name(tool_call)
      function = tool_call["function"] || tool_call[:function] || {}
      function["name"] || function[:name]
    end

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

    def chat(on_reasoning_delta: nil, on_retry: nil, cancellation: nil, steering: nil)
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
          cancellation: cancellation,
          steering: steering
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
