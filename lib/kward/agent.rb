require_relative "cancellation"
require_relative "model/chat_invocation"
require_relative "compactor"
require_relative "model/context_overflow"
require_relative "conversation"
require_relative "events"
require_relative "deep_copy"
require_relative "hooks"
require_relative "message_access"
require_relative "steering"
require_relative "telemetry/logger"
require_relative "tools/registry"
require_relative "tools/tool_call"

# Namespace for the Kward CLI agent runtime.
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
    def initialize(client:, tool_registry: ToolRegistry.new, conversation: Conversation.new, telemetry_logger: TelemetryLogger.new, hook_manager: nil, hook_context: nil)
      @client = client
      @tool_registry = tool_registry
      @conversation = conversation
      @telemetry_logger = telemetry_logger
      @hook_manager = hook_manager
      @hook_context = hook_context
    end

    attr_reader :conversation, :tool_registry

    # Adds a user message, compacts context when needed, and runs the turn.
    #
    # @param input [String] text sent to the model
    # @param display_input [String, nil] alternate text kept for transcripts
    # @yieldparam event [Object] streamed turn event for frontends
    # @return [String] final assistant answer
    def ask(input, display_input: nil, on_reasoning_delta: nil, on_retry: nil, cancellation: nil, steering: nil, options: {}, tool_registry: nil, &block)
      started_at = @telemetry_logger.monotonic_now
      status = "completed"
      error = nil
      cancellation&.raise_if_cancelled!
      turn_start = run_hook("turn_start", payload: { input: input, display_input: display_input })
      return hook_denied_answer(turn_start) if turn_start.denied?

      input = turn_start.payload[:input] || turn_start.payload["input"] || input
      display_input = turn_start.payload[:display_input] || turn_start.payload["display_input"] || display_input
      @conversation.refresh_system_message_if_workspace_agents_changed!
      @conversation.append_user(input, display_content: display_input)
      run_hook("turn_context_build_before", payload: { message_count: @conversation.messages.length })
      auto_compact_if_needed
      run_hook("turn_context_build_after", payload: { message_count: @conversation.messages.length })
      answer = run_turn(on_reasoning_delta: on_reasoning_delta, on_retry: on_retry, cancellation: cancellation, steering: steering, options: options, tool_registry: tool_registry, &block)
      run_hook("turn_end", payload: { input: input, answer: answer })
      answer
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
    def run_turn(on_reasoning_delta: nil, on_retry: nil, cancellation: nil, steering: nil, options: {}, tool_registry: nil)
      overflow_retried = false
      steering_state = build_steering_state(steering) do |event|
        yield event if block_given?
      end
      loop do
        cancellation&.raise_if_cancelled!
        begin
          message = chat(on_reasoning_delta: on_reasoning_delta, on_retry: on_retry, cancellation: cancellation, steering: steering, options: options, tool_registry: tool_registry) do |event|
            yield event if block_given?
          end
        rescue StandardError => e
          raise if cancellation&.cancelled?
          raise unless !overflow_retried && ContextOverflow.error?(e) && compact_after_context_overflow(e)

          overflow_retried = true
          next
        end
        update_conversation_runtime(message)
        yield Events::AssistantMessage.new(message: message) if block_given?
        @conversation.append_assistant(message)
        steered_after_message = append_steering_events(steering_state)
        yield Events::SteeringApplied.new(count: steered_after_message) if block_given? && steered_after_message.positive?

        tool_calls = MessageAccess.tool_calls(message)
        if tool_calls.empty?
          next if steered_after_message.positive?

          answer = safe_answer(MessageAccess.content(message).to_s)
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
            content = (tool_registry || @tool_registry).dispatch(tool_call, @conversation, cancellation: cancellation)
          rescue StandardError => e
            status = "failed"
            error = e
            raise e
          ensure
            log_tool(tool_call, content: content, duration_ms: @telemetry_logger.duration_ms(tool_started_at), status: status, error: error)
          end
          cancellation&.raise_if_cancelled!
          if block_given?
            elapsed_ms = @telemetry_logger.duration_ms(tool_started_at)
            yield Events::ToolUpdate.new(tool_call: tool_call, content: content, elapsed_ms: elapsed_ms)
            yield Events::ToolResult.new(tool_call: tool_call, content: content)
          end
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
        "tool_name" => ToolCall.name(tool_call),
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

    def chat(on_reasoning_delta: nil, on_retry: nil, cancellation: nil, steering: nil, options: {}, tool_registry: nil)
      reasoning_delta = lambda do |delta|
        cancellation&.raise_if_cancelled!
        on_reasoning_delta&.call(delta)
        yield Events::ReasoningDelta.new(delta: delta) if block_given?
      end
      reasoning_boundary = lambda do
        cancellation&.raise_if_cancelled!
        yield Events::ReasoningBoundary.new if block_given?
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
      registry = tool_registry || @tool_registry
      request = {
        messages: @conversation.context_messages,
        tools: registry.schemas,
        provider: options[:provider] || @conversation.provider,
        model: options[:model] || @conversation.model,
        reasoning: options[:reasoning] || @conversation.reasoning_effort
      }
      before = run_hook("model_request_before", payload: request)
      request = DeepCopy.merge(request, before.payload) if before.decision.modify?
      return { "role" => "assistant", "content" => hook_denied_answer(before) } if before.denied?

      run_hook("turn_model_request_before", payload: request)
      response = ChatInvocation.call(
        @client,
        request[:messages] || request["messages"],
        {
          tools: request[:tools] || request["tools"],
          on_reasoning_delta: reasoning_delta,
          on_reasoning_boundary: reasoning_boundary,
          on_assistant_delta: assistant_delta,
          on_retry: retry_callback,
          cancellation: cancellation,
          steering: steering,
          provider: request[:provider] || request["provider"],
          model: request[:model] || request["model"],
          reasoning: request[:reasoning] || request["reasoning"]
        }
      )
      run_hook("model_response_after_parse", payload: { message: response })
      run_hook("turn_model_response_complete", payload: { message: response })
      response
    end

    def update_conversation_runtime(message)
      return unless message.is_a?(Hash)

      provider = message["provider"] || message[:provider]
      model = message["model"] || message[:model]
      return if provider.to_s.empty? || model.to_s.empty?

      @conversation.update_runtime_context!(provider: provider, model: model, reasoning_effort: @conversation.reasoning_effort)
      @conversation.persist_runtime_context!
    end

    def safe_answer(content)
      text = content.to_s
      return text unless claims_file_edit?(text)
      return text if last_file_change_succeeded?
      return "The file change tool returned an error or declined result, so I did not successfully change the file." if @conversation.last_file_change_result

      "I have not changed any files. I need to use write_file or edit_file successfully before claiming a file change."
    end

    def run_hook(name, payload: {})
      return Hooks::Manager::Result.new(event: nil, decision: Hooks::Decision.allow, decisions: [], warnings: [], messages: [], payload: payload) unless @hook_manager

      @hook_manager.run(Hooks::Event.new(
        name: name,
        session: { id: @conversation.respond_to?(:session_id) ? @conversation.session_id : nil },
        workspace: { root: @conversation.respond_to?(:workspace_root) ? @conversation.workspace_root : nil },
        agent: {
          provider: @conversation.provider,
          model: @conversation.model,
          reasoning: @conversation.reasoning_effort
        },
        payload: payload
      ), context: @hook_context)
    end

    def hook_denied_answer(result)
      "Declined: #{result.decision.message || "lifecycle hook denied the operation"}"
    end

    def claims_file_edit?(text)
      text.match?(/\b(?:I|I've|I have)\s+(?:changed|updated|modified|edited|created|deleted|wrote)\s+(?:the\s+)?(?:file|files|[\w.\/-]+\.[\w-]+)\b/i)
    end

    def last_file_change_succeeded?
      result = @conversation.last_file_change_result
      content = result&.fetch(:content, nil) || result&.fetch("content", "")
      content&.start_with?("Wrote ", "Edited ")
    end
  end
end
