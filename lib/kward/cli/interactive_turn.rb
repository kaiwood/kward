# Namespace for the Kward CLI agent runtime.
module Kward
  # Command-line frontend that coordinates terminal interaction, sessions, tools, and model turns.
  class CLI
    # Interactive turn loop helpers for streaming, cancellation, and queued user input.
    module InteractiveTurn
      private

      def run_interactive_turn(agent, input, display_input: nil)
        stop_live_worker_view if respond_to?(:stop_live_worker_view, true)
        prepare_memory_context(agent.conversation, input) if agent.respond_to?(:conversation)
        print_user_transcript(input, display_input: display_input) if prompt_interface?
        return run_blocking_interactive_turn(agent, input, display_input: display_input) unless prompt_interface?

        queued_inputs = []
        cancellation = Cancellation.new
        cancelled = false
        steering = steering_supported? ? Steering.new : nil
        event_queue = Queue.new
        stream_state = {
          streamed: false,
          last_flush: monotonic_now,
          stream_block_open: false,
          markdown_streams: {},
          defer_assistant_streaming: defer_assistant_streaming?(agent)
        }
        markdown_chunks = []
        answer = nil
        error = nil
        @prompt.begin_busy_input("You>") if @prompt.respond_to?(:begin_busy_input)

        worker = Thread.new do
          options = agent_display_options(display_input)
          options[:cancellation] = cancellation
          options[:steering] = steering if steering
          answer = agent.ask(input, **options) do |event|
            event_queue << event
          end
        rescue StandardError => e
          error = e
        end
        worker.report_on_exception = false

        while worker.alive?
          begin
            poll_result = collect_busy_input(queued_inputs, steering, agent)
            sleep 0.01
          rescue Interrupt
            poll_result = PromptInterface::CANCEL_INPUT
          end
          if poll_result == PromptInterface::CANCEL_INPUT && !cancelled
            cancelled = true
            cancellation.cancel!
            worker.raise(Cancellation::CancelledError, "cancelled") if worker.alive?
          end
          if busy_replacement_agent?
            discard_interactive_events(event_queue, markdown_chunks, stream_state)
          else
            drain_interactive_events(event_queue, markdown_chunks, stream_state, agent)
          end
        end
        begin
          worker.join
        rescue Cancellation::CancelledError => e
          error ||= e
        end
        drain_busy_input(queued_inputs, nil) unless cancelled
        if busy_replacement_agent?
          discard_interactive_events(event_queue, markdown_chunks, stream_state, force: true)
        else
          drain_interactive_events(event_queue, markdown_chunks, stream_state, agent, force: true)
        end
        raise error if error && !error.is_a?(Cancellation::CancelledError) && !busy_replacement_agent?

        @prompt.say("\n#{colored(assistant_output_prompt, :green, :bold)} #{render_markdown_transcript(answer)}\n") unless cancelled || busy_replacement_agent? || stream_state[:streamed] || answer.to_s.empty?
        persist_memory_state(agent.conversation) if agent.respond_to?(:conversation)
        auto_summarize_memory(agent.conversation) if agent.respond_to?(:conversation) && queued_inputs.empty? && !cancelled
        queued_inputs
      ensure
        @prompt.finish_busy_input if @prompt.respond_to?(:finish_busy_input)
      end

      def drain_interactive_events(event_queue, markdown_chunks, stream_state, agent = nil, force: false)
        drained = 0
        loop do
          break if !force && drained >= INTERACTIVE_EVENT_DRAIN_LIMIT

          event = event_queue.pop(true)
          drained += 1
          notify_plugin_transcript_event(event, agent.respond_to?(:conversation) ? agent.conversation : nil)
          handle_interactive_event(event, markdown_chunks, stream_state)
        rescue ThreadError
          break
        end

        flush_interactive_markdown_deltas(markdown_chunks, stream_state, force: force)
      end

      def discard_interactive_events(event_queue, markdown_chunks, stream_state, force: false)
        drained = 0
        loop do
          break if !force && drained >= INTERACTIVE_EVENT_DRAIN_LIMIT

          event_queue.pop(true)
          drained += 1
        rescue ThreadError
          break
        end
        markdown_chunks.clear
        finish_stream_block if stream_state[:stream_block_open]
        stream_state[:stream_block_open] = false
      end

      def handle_interactive_event(event, markdown_chunks, stream_state)
        case event
        when Events::ReasoningDelta
          stream_state[:streamed] = true
          append_markdown_delta(markdown_chunks, "Reasoning", event.delta)
        when Events::AssistantDelta
          stream_state[:streamed] = true
          append_markdown_delta(markdown_chunks, "Assistant", event.delta)
        when Events::Steering
          finish_interactive_markdown_deltas(markdown_chunks, stream_state)
          print_user_transcript(event.input)
        when Events::SteeringApplied
          @prompt.clear_steered_count if @prompt.respond_to?(:clear_steered_count)
        when Events::Retry
          stream_state[:streamed] = true
          finish_interactive_markdown_deltas(markdown_chunks, stream_state)
          print_retry(event)
        when Events::ToolCall
          stream_state[:streamed] = true
          finish_interactive_markdown_deltas(markdown_chunks, stream_state)
        when Events::ToolResult
          stream_state[:streamed] = true
          finish_interactive_markdown_deltas(markdown_chunks, stream_state)
          update_session_diff(event.content, tool_call: event.tool_call)
          print_tool_result(event.tool_call, event.content, line_limit: INTERACTIVE_TOOL_OUTPUT_LINE_LIMIT)
        end
      end

      def flush_interactive_markdown_deltas(markdown_chunks, stream_state, force: false)
        if force
          finish_interactive_markdown_deltas(markdown_chunks, stream_state)
          return
        end
        return if markdown_chunks.empty?
        return unless monotonic_now - stream_state[:last_flush] >= STREAM_RENDER_INTERVAL

        chunks_to_flush = markdown_chunks
        if stream_state[:defer_assistant_streaming]
          chunks_to_flush, delayed_chunks = split_deferred_assistant_entries(markdown_chunks)
          return if chunks_to_flush.empty?

          markdown_chunks.replace(delayed_chunks)
        end

        stream_state[:stream_block_open] = true if flush_markdown_deltas(chunks_to_flush, finish: false, streams: stream_state[:markdown_streams])
        stream_state[:last_flush] = monotonic_now
      end

      def finish_interactive_markdown_deltas(markdown_chunks, stream_state)
        wrote = flush_markdown_deltas(markdown_chunks, streams: stream_state[:markdown_streams])
        finish_stream_block if stream_state[:stream_block_open] && !wrote
        stream_state[:stream_block_open] = false
        stream_state[:last_flush] = monotonic_now
      end

      def split_deferred_assistant_entries(markdown_chunks)
        markdown_chunks.partition { |label, _content| label != "Assistant" }
      end

      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def collect_queued_input(queued_inputs)
        collect_busy_input(queued_inputs, nil)
      end

      def collect_busy_input(queued_inputs, steering, agent = nil)
        return nil if @prompt.respond_to?(:modal_active?) && @prompt.modal_active?

        poll_result = @prompt.poll_input
        case poll_result
        when String
          return poll_result if handle_busy_worker_input(poll_result, agent, queued_inputs)

          if steering && !poll_result.strip.empty?
            begin
              steering.submit(poll_result)
              @prompt.set_steered_count(1) if @prompt.respond_to?(:set_steered_count)
            rescue StandardError
              queued_inputs << poll_result
              @prompt.set_queued_count(queued_inputs.length) if @prompt.respond_to?(:set_queued_count)
            end
          else
            queued_inputs << poll_result unless poll_result.strip.empty?
            @prompt.set_queued_count(queued_inputs.length) if @prompt.respond_to?(:set_queued_count)
          end
        when PromptInterface::EXIT_INPUT
          queued_inputs << "/exit"
          @prompt.set_queued_count(queued_inputs.length) if @prompt.respond_to?(:set_queued_count)
        end
        poll_result
      end

      def drain_queued_input(queued_inputs)
        drain_busy_input(queued_inputs, nil)
      end

      def drain_busy_input(queued_inputs, steering, agent = nil)
        deadline = Time.now + 0.15
        loop do
          poll_result = collect_busy_input(queued_inputs, steering, agent)
          break if Time.now > deadline && poll_result.nil?

          sleep 0.01
        end
      end

      def handle_busy_worker_input(input, agent, queued_inputs)
        return false unless agent

        command = input.to_s.strip
        return false unless command == "/workers" || command.start_with?("/workers ")

        _handled, replacement_agent = handle_local_slash_command(command, agent, @session_store)
        @busy_replacement_agent = replacement_agent if replacement_agent?(replacement_agent)
        restore_busy_input_prompt
        true
      rescue StandardError => e
        runtime_output("Error: #{e.message}")
        restore_busy_input_prompt
        true
      end

      def replacement_agent?(object)
        object.respond_to?(:conversation) && object.respond_to?(:ask)
      end

      def busy_replacement_agent?
        replacement_agent?(@busy_replacement_agent)
      end

      def restore_busy_input_prompt
        return unless @prompt.respond_to?(:begin_busy_input)
        return if @prompt.respond_to?(:modal_active?) && @prompt.modal_active?

        @prompt.begin_busy_input("You>")
      end

      def steering_supported?
        @client.respond_to?(:supports_in_flight_steer?) && @client.supports_in_flight_steer?
      end

      def defer_assistant_streaming?(agent)
        return false unless agent.respond_to?(:conversation)

        conversation = agent.conversation
        model = conversation.respond_to?(:model) && conversation.model ? conversation.model : current_model_id
        ModelInfo.reasoning_supported?(current_model_provider, model)
      end

      def run_blocking_interactive_turn(agent, input, display_input: nil)
        streamed = false
        markdown_chunks = []
        answer = agent.ask(input, **agent_display_options(display_input)) do |event|
          streamed = true if render_blocking_turn_event(event, markdown_chunks, tool_line_limit: INTERACTIVE_TOOL_OUTPUT_LINE_LIMIT)
        end
        flush_markdown_deltas(markdown_chunks) if streamed
        @prompt.say("\n#{colored(assistant_output_prompt, :green, :bold)} #{render_markdown_transcript(answer)}\n") unless streamed || answer.to_s.empty?
        persist_memory_state(agent.conversation) if agent.respond_to?(:conversation)
        auto_summarize_memory(agent.conversation) if agent.respond_to?(:conversation)
        []
      end

      def agent_display_options(display_input)
        display_input.nil? ? {} : { display_input: display_input }
      end

    end
  end
end
