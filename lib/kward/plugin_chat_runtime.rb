require "digest"
require "securerandom"
require "thread"
require_relative "cancellation"
require_relative "events"
require_relative "image_attachments"
require_relative "message_access"
require_relative "plugin_registry"
require_relative "tab_driver"
require_relative "tools/tool_call"

# Frontend-neutral runtime for trusted plugin-owned conversational drivers.
module Kward
  # Coordinates plugin chat drivers without depending on RPC or the terminal UI.
  # Frontends use this runtime for queuing, cancellation, event replay, and
  # transcript access while the plugin remains responsible for its own storage,
  # model settings, and domain behavior.
  class PluginChatRuntime
    EVENT_LIMIT = 1_000
    WORKER_STOP = Object.new.freeze

    Chat = Struct.new(
      :id,
      :type,
      :driver,
      :queue,
      :worker,
      :running_turn_id,
      :scope_key,
      :descriptor,
      :workspace_root,
      keyword_init: true
    )
    Turn = Struct.new(
      :id,
      :chat_id,
      :input,
      :display_input,
      :context,
      :status,
      :cancellation,
      :created_at,
      :started_at,
      :finished_at,
      :events,
      :next_sequence,
      :error,
      :mutex,
      keyword_init: true
    )

    def initialize(client:, plugin_registry_provider: nil, message_normalizer: nil)
      @client = client
      @plugin_registry_provider = plugin_registry_provider
      @message_normalizer = message_normalizer
      @chats = {}
      @turns = {}
      @event_listeners = []
      @mutex = Mutex.new
    end

    def supported_types(surface: :rpc)
      case surface.to_sym
      when :rpc
        plugin_registry.tab_types.select(&:rpc)
      when :transport
        plugin_registry.transport_tab_types
      else
        raise ArgumentError, "Unknown plugin chat surface: #{surface}"
      end
    end

    def subscribe_events(&block)
      raise ArgumentError, "plugin chat event subscription requires a block" unless block

      @mutex.synchronize { @event_listeners << block }
      block
    end

    def open(type_id:, surface: :rpc, scope_key: nil, descriptor: {}, workspace_root: Dir.pwd)
      type = supported_types(surface: surface).find { |entry| entry.id == type_id.to_s }
      raise ArgumentError, "Unknown #{surface} plugin chat: #{type_id}" unless type

      chat_for(type, scope_key: scope_key, descriptor: descriptor, workspace_root: workspace_root)
    end

    def chat(chat_id)
      @mutex.synchronize { @chats[chat_id.to_s] }
    end

    def start_turn(chat_id:, input:, display_input: nil, context: nil)
      chat = fetch_chat(chat_id)
      turn = Turn.new(
        id: SecureRandom.uuid,
        chat_id: chat.id,
        input: input,
        display_input: display_input.nil? ? input.to_s : display_input.to_s,
        context: context || {},
        status: "queued",
        cancellation: Cancellation.new,
        created_at: Time.now.utc.iso8601(3),
        events: [],
        next_sequence: 1,
        mutex: Mutex.new
      )
      @mutex.synchronize { @turns[turn.id] = turn }
      chat.queue << turn.id
      ensure_worker(chat)
      emit_event(turn, "turnQueued", { status: "queued" })
      turn
    end

    def cancel_turn(turn_id:)
      turn = fetch_turn(turn_id)
      queued = turn.mutex.synchronize do
        turn.cancellation.cancel!
        turn.status == "queued"
      end
      emit_event(turn, "turnCancelRequested", {})
      finish_turn(turn, "canceled") if queued
      turn
    end

    def turn_status(turn_id:)
      fetch_turn(turn_id)
    end

    def turn_events(turn_id:, after_sequence: 0)
      turn = fetch_turn(turn_id)
      turn.mutex.synchronize do
        turn.events.select { |event| event[:sequence].to_i > after_sequence.to_i }
      end
    end

    def list_turns(chat_id: nil, active: false)
      turns = @mutex.synchronize { @turns.values.dup }
      turns.select! { |turn| turn.chat_id == chat_id.to_s } if chat_id
      turns.select! { |turn| %w[queued running].include?(turn.status) } if active
      turns
    end

    def shutdown
      chats = @mutex.synchronize { @chats.values.dup }
      chats.each do |chat|
        chat.queue << WORKER_STOP if chat.worker&.alive?
        chat.worker&.join(0.2)
      end
      nil
    end

    # Converts normalized image attachment hashes into the input shape accepted
    # by plugin chat drivers. RPC and transport frontends can normalize their
    # own boundary formats before calling this helper.
    def input_with_attachments(input, attachments)
      attachments = Array(attachments)
      return input.to_s if attachments.empty?

      [{ type: "text", text: input.to_s }] + attachments.map do |attachment|
        {
          type: "image",
          media_type: attachment.fetch(:mimeType) { attachment.fetch("mimeType") },
          data: attachment.fetch(:data) { attachment.fetch("data") },
          alt: attachment[:alt] || attachment["alt"]
        }.compact
      end
    end

    private

    def plugin_registry
      return @plugin_registry_provider.call if @plugin_registry_provider

      @plugin_registry ||= PluginRegistry.load
    end

    def chat_for(type, scope_key:, descriptor:, workspace_root:)
      scope_key = normalize_scope_key(scope_key)
      chat_id = chat_id_for(type, scope_key)
      @mutex.synchronize do
        @chats[chat_id] ||= begin
          descriptor = {
            "kind" => "plugin",
            "plugin_tab_type" => type.id,
            "label" => type.title,
            "scope_key" => scope_key
          }.merge(descriptor.transform_keys(&:to_s))
          host = PluginTabHost.new(client: @client, workspace_root: workspace_root)
          driver = type.handler.call(host, descriptor)
          raise "Plugin chat #{type.id.inspect} did not return a tab driver." unless driver

          Chat.new(
            id: chat_id,
            type: type,
            driver: driver,
            queue: Queue.new,
            scope_key: scope_key,
            descriptor: descriptor,
            workspace_root: workspace_root
          )
        end
      end
    end

    def normalize_scope_key(scope_key)
      value = scope_key.to_s
      value.empty? ? "default" : value
    end

    def chat_id_for(type, scope_key)
      return type.id if type.singleton == :global
      return type.id if scope_key == "default"

      "#{type.id}:#{Digest::SHA256.hexdigest(scope_key)[0, 16]}"
    end

    def fetch_chat(chat_id)
      chat(chat_id) || raise(ArgumentError, "Unknown plugin chat: #{chat_id}")
    end

    def fetch_turn(turn_id)
      @mutex.synchronize { @turns[turn_id.to_s] } || raise(ArgumentError, "Unknown plugin chat turn: #{turn_id}")
    end

    def ensure_worker(chat)
      return if chat.worker&.alive?

      chat.worker = Thread.new do
        loop do
          turn_id = chat.queue.pop
          break if turn_id.equal?(WORKER_STOP)

          turn = fetch_turn(turn_id)
          run_turn(chat, turn) unless turn.cancellation.cancelled?
        end
      end
      chat.worker.report_on_exception = false
    end

    def run_turn(chat, turn)
      turn.mutex.synchronize do
        return if terminal?(turn)

        turn.status = "running"
        turn.started_at = Time.now.utc.iso8601(3)
      end
      chat.running_turn_id = turn.id
      emit_event(turn, "turnStarted", { status: "running" })
      submit_options = {
        display_input: turn.display_input,
        cancellation: turn.cancellation
      }
      if !turn.context.empty? && accepts_context?(chat.driver)
        submit_options[:context] = turn.context
      end
      chat.driver.submit(turn.input, **submit_options) do |event|
        handle_driver_event(chat, turn, event)
      end
      finish_turn(turn, turn.cancellation.cancelled? ? "canceled" : "completed")
    rescue Cancellation::CancelledError
      finish_turn(turn, "canceled")
    rescue StandardError => e
      turn.mutex.synchronize { turn.error = { message: e.message, code: e.class.name, fatal: false } }
      finish_turn(turn, "failed")
    ensure
      chat.running_turn_id = nil if chat.running_turn_id == turn.id
    end

    def accepts_context?(driver)
      driver.method(:submit).parameters.any? do |kind, name|
        kind == :keyrest || ((kind == :key || kind == :keyreq) && name == :context)
      end
    end

    def handle_driver_event(chat, turn, event)
      notify_plugin_tab_transcript_event(chat, event) if chat.type.transcript_events

      type, payload = case event
      when Events::ReasoningDelta then ["reasoningDelta", { delta: event.delta }]
      when Events::ReasoningBoundary then ["reasoningBoundary", {}]
      when Events::AssistantDelta then ["assistantDelta", { delta: event.delta }]
      when Events::AssistantMessage then ["assistantMessage", { message: normalized_assistant_message(event.message) }]
      when Events::Retry then ["modelRetry", retry_event_payload(event)]
      when Events::ToolCall then ["toolCall", tool_call_payload(event.tool_call)]
      when Events::ToolResult then ["toolResult", tool_result_payload(event.tool_call, event.content)]
      when Events::Answer then ["answer", { content: event.content }]
      end
      emit_event(turn, type, payload) if type
    end

    def notify_plugin_tab_transcript_event(chat, event)
      return if plugin_registry.transcript_event_handlers.empty?

      context = PluginRegistry::Context.new(conversation: chat.driver, workspace_root: chat.workspace_root)
      plugin_registry.notify_transcript_event(event, context)
    end

    def normalized_assistant_message(message)
      @message_normalizer ? @message_normalizer.call(message) : message
    end

    def retry_event_payload(event)
      {
        provider: event.provider,
        model: event.model,
        attempt: event.attempt,
        maxAttempts: event.max_attempts,
        delaySeconds: event.delay_seconds,
        error: event.error,
        requestBytes: event.request_bytes
      }.compact
    end

    def tool_call_payload(tool_call)
      {
        toolCallId: ToolCall.id(tool_call),
        toolName: ToolCall.name(tool_call),
        args: ToolCall.parse_arguments(ToolCall.raw_arguments(tool_call))
      }.compact
    end

    def tool_result_payload(tool_call, content)
      {
        toolCallId: ToolCall.id(tool_call),
        toolName: ToolCall.name(tool_call),
        result: {
          content: content.to_s,
          isError: content.to_s.start_with?("Unknown", "Invalid", "Research tool failed")
        }
      }.compact
    end

    def finish_turn(turn, status)
      event = turn.mutex.synchronize do
        next nil if terminal?(turn)

        turn.status = status
        turn.finished_at = Time.now.utc.iso8601(3)
        append_event(turn, "turnFinished", { status: status, error: turn.error }.compact)
      end
      notify_event(event) if event
    end

    def emit_event(turn, type, payload)
      event = turn.mutex.synchronize { append_event(turn, type, payload) }
      notify_event(event)
    end

    def append_event(turn, type, payload)
      event = {
        sequence: turn.next_sequence,
        timestamp: Time.now.utc.iso8601(3),
        chatId: turn.chat_id,
        turnId: turn.id,
        type: type,
        payload: payload
      }
      turn.next_sequence += 1
      turn.events << event
      turn.events.shift while turn.events.length > EVENT_LIMIT
      event
    end

    def notify_event(event)
      listeners = @mutex.synchronize { @event_listeners.dup }
      listeners.each do |listener|
        listener.call(event)
      rescue StandardError
        nil
      end
    end

    def terminal?(turn)
      %w[completed failed canceled].include?(turn.status)
    end
  end
end
