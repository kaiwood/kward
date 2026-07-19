require "base64"
require "erb"
require "json"
require "socket"
require "thread"
require "time"
require "uri"
require_relative "../agent"
require_relative "../config_files"
require_relative "../events"
require_relative "../model/retry_message"
require_relative "../plugin_registry"
require_relative "../prompts/commands"
require_relative "../rpc/transcript_normalizer"
require_relative "../session_store"
require_relative "../session_trash"
require_relative "../tools/tool_call"
require_relative "../tools/registry"
require_relative "../version"
require_relative "../workspace_factory"

# Namespace for the Kward CLI agent runtime.
module Kward
  # Local HTTP server for the mobile-friendly Pan web UI.
  class PanServer
    DEFAULT_HOST = "0.0.0.0"
    DEFAULT_PORT = 8765
    MAX_REQUEST_BODY_BYTES = 64 * 1024
    ROUTING_PROBE_ADDRESS = "8.8.8.8"
    ROUTING_PROBE_PORT = 80

    def initialize(client:, working_directory:, config: ConfigFiles.read_config, config_dir: ConfigFiles.config_dir, output: $stderr, udp_socket_class: UDPSocket)
      @client = client
      @output = output
      @udp_socket_class = udp_socket_class
      @workspace = WorkspaceFactory.build(
        root: working_directory,
        guardrails: ConfigFiles.workspace_guardrails_enabled?(config),
        config: config
      )
      @full_config = config
      @config = pan_config(config)
      @host = @config.fetch("host", DEFAULT_HOST).to_s
      @port = positive_port(@config.fetch("port", DEFAULT_PORT))
      @username = @config["username"].to_s
      @password = @config["password"].to_s
      raise "Pan mode requires pan_mode.username and pan_mode.password in #{ConfigFiles.config_path}" if @username.empty? || @password.empty?

      @session_store = SessionStore.new(config_dir: config_dir, cwd: @workspace.root.to_s)
      @session = @session_store.create(
        provider: (@client.current_provider if @client.respond_to?(:current_provider)),
        model: (@client.current_model if @client.respond_to?(:current_model)),
        reasoning_effort: (@client.current_reasoning_effort if @client.respond_to?(:current_reasoning_effort))
      )
      @conversation = new_conversation
      @session.attach(@conversation)
      @agent = build_agent
      @prompt_queue = Queue.new
      @subscribers = []
      @subscribers_mutex = Mutex.new
      @worker_started = false
      @active = false
      @pending_turns = 0
      @state_mutex = Mutex.new
      @session_mutex = Mutex.new
    end

    attr_reader :host, :port, :session, :workspace

    def run
      start_worker
      @server = TCPServer.new(@host, @port)
      actual_port = @server.addr[1]
      @output.puts "Kward pan mode listening on http://#{display_host}:#{actual_port}"
      @output.puts "Workspace: #{@workspace.root}"
      @output.puts "Session: #{@session.path}"

      loop do
        socket = @server.accept
        Thread.new(socket) { |client_socket| handle_client(client_socket) }
      end
    rescue Interrupt
      @output.puts "\nPan mode stopped."
    ensure
      stop
    end

    def stop
      @server&.close unless @server&.closed?
    rescue IOError
      nil
    end

    def enqueue_prompt(prompt)
      text = prompt.to_s
      return { ok: false, error: "Prompt is required" } if text.strip.empty?

      @session_mutex.synchronize do
        queued_at = Time.now.utc.iso8601(3)
        @state_mutex.synchronize { @pending_turns += 1 }
        @prompt_queue << { prompt: text, queued_at: queued_at }
      end
      broadcast("queue", queue_payload)
      { ok: true, queued: @prompt_queue.size, active: active? }
    end

    def transcript_items
      RPC::TranscriptNormalizer.new(@conversation.messages).normalize.flat_map { |message| pan_transcript_items(message) }
    end

    private

    def new_conversation
      Conversation.new(
        workspace_root: @workspace.root.to_s,
        provider: (@client.current_provider if @client.respond_to?(:current_provider)),
        model: (@client.current_model if @client.respond_to?(:current_model)),
        reasoning_effort: (@client.current_reasoning_effort if @client.respond_to?(:current_reasoning_effort))
      )
    end

    def build_agent
      hook_context = lifecycle_hook_context
      hook_manager = lifecycle_hook_manager
      Agent.new(
        client: @client,
        tool_registry: ToolRegistry.new(workspace: @workspace, ask_user_question_enabled: false, hook_manager: hook_manager, hook_context: hook_context),
        conversation: @conversation,
        hook_manager: hook_manager,
        hook_context: hook_context
      )
    end

    def lifecycle_hook_manager
      manager = Hooks::ConfigLoader.new(ConfigFiles.lifecycle_hooks_config(@workspace.root)).manager
      manager.on_result = method(:broadcast_lifecycle_hook_event)
      plugin_registry.hook_handlers.each do |hook|
        manager.register(hook.event, id: hook.id, source: hook.path, order: hook.order, match: hook.match, failure_policy: hook.failure_policy) do |event, context|
          hook.handler.call(event, context)
        end
      end
      manager
    end

    def broadcast_lifecycle_hook_event(event, result)
      broadcast("hook_event", {
        event: {
          id: event.id,
          name: event.name,
          phase: event.phase,
          timestamp: event.timestamp.iso8601,
          payloadKeys: event.payload.keys.map(&:to_s).sort
        },
        result: {
          decision: result.decision.decision,
          warnings: result.warnings,
          messages: result.messages,
          decisionCount: result.decisions.length
        }
      })
    end

    def lifecycle_hook_context
      PluginRegistry::Context.new(
        conversation: @conversation,
        args: "",
        session: @session,
        workspace_root: @workspace.root.to_s,
        say_callback: lambda { |message| broadcast("hook_message", { message: message.to_s }) }
      )
    end

    def plugin_registry
      @plugin_registry ||= PluginRegistry.load(reserved_commands: PromptCommands::BUILTIN_RESERVED_COMMAND_NAMES)
    end

    def start_worker
      return if @worker_started

      @worker_started = true
      @worker_thread = Thread.new do
        loop do
          item = @prompt_queue.pop
          run_prompt(item[:prompt])
        end
      end
    end

    def run_prompt(prompt)
      set_active(true)
      broadcast("user", { text: prompt })
      broadcast("turn_started", queue_payload)
      @agent.ask(prompt) do |event|
        case event
        when Events::ReasoningDelta
          broadcast("reasoning_delta", { delta: event.delta.to_s })
        when Events::ReasoningBoundary
          broadcast("reasoning_boundary", {})
        when Events::AssistantDelta
          broadcast("assistant_delta", { delta: event.delta.to_s })
        when Events::Retry
          broadcast("retry", { message: retry_message(event) })
        when Events::ToolCall
          broadcast("tool_call", tool_call_payload(event.tool_call))
        when Events::ToolResult
          broadcast("tool_result", tool_result_payload(event.tool_call, event.content))
        when Events::Answer
          broadcast("answer", { content: event.content.to_s })
        end
      end
      broadcast("turn_finished", queue_payload.merge(status: "completed"))
    rescue StandardError => e
      broadcast("error", { message: e.message })
      broadcast("turn_finished", queue_payload.merge(status: "failed"))
    ensure
      @state_mutex.synchronize do
        @active = false
        @pending_turns -= 1 if @pending_turns.positive?
      end
      broadcast("queue", queue_payload)
    end

    def handle_client(socket)
      request = read_request(socket)
      return unless request

      unless authorized?(request[:headers])
        write_response(socket, 401, { "WWW-Authenticate" => 'Basic realm="Kward pan mode"' }, "Unauthorized\n")
        return
      end

      case [request[:method], request[:path]]
      when ["GET", "/"]
        write_response(socket, 200, { "Content-Type" => "text/html; charset=utf-8" }, render_index)
      when ["GET", "/kward-logo.png"]
        write_response(socket, 200, { "Content-Type" => "image/png", "Cache-Control" => "public, max-age=86400" }, File.binread(File.join(__dir__, "kward_logo.png")))
      when ["GET", "/transcript"]
        write_json(socket, 200, transcript: transcript_items, session: active_session_payload, workspace: @workspace.root.to_s)
      when ["GET", "/sessions"]
        write_json(socket, 200, sessions: session_payloads, activeSessionId: @session.id)
      when ["GET", "/events"]
        stream_events(socket)
      when ["POST", "/turn"]
        handle_turn(socket, request[:body], request[:headers])
      when ["POST", "/sessions"]
        handle_session_action(socket, request[:body], request[:headers])
      else
        write_response(socket, 404, { "Content-Type" => "text/plain; charset=utf-8" }, "Not found\n")
      end
    rescue StandardError => e
      write_response(socket, 500, { "Content-Type" => "text/plain; charset=utf-8" }, "Error: #{e.message}\n") rescue nil
    ensure
      socket.close unless socket.closed?
    end

    def read_request(socket)
      request_line = socket.gets
      return nil unless request_line

      method, target, = request_line.split(" ", 3)
      headers = {}
      while (line = socket.gets)
        line = line.chomp
        break if line.empty?

        name, value = line.split(":", 2)
        headers[name.downcase] = value.to_s.strip if name
      end

      length = headers.fetch("content-length", "0").to_i
      raise "Request body too large" if length > MAX_REQUEST_BODY_BYTES

      body = length.positive? ? socket.read(length).to_s : ""
      path = URI.parse(target.to_s).path
      { method: method.to_s.upcase, path: path, headers: headers, body: body }
    end

    def authorized?(headers)
      value = headers["authorization"].to_s
      return false unless value.start_with?("Basic ")

      expected = Base64.strict_encode64("#{@username}:#{@password}")
      secure_compare(value.delete_prefix("Basic "), expected)
    end

    def secure_compare(left, right)
      left = left.to_s
      right = right.to_s
      return false unless left.bytesize == right.bytesize

      left.bytes.zip(right.bytes).reduce(0) { |memo, pair| memo | (pair[0] ^ pair[1]) }.zero?
    end

    def handle_turn(socket, body, headers)
      return write_json(socket, 415, ok: false, error: "Content-Type must be application/json") unless json_request?(headers)

      params = JSON.parse(body.empty? ? "{}" : body)
      result = enqueue_prompt(params["prompt"])
      status = result[:ok] ? 202 : 422
      write_json(socket, status, result)
    rescue JSON::ParserError
      write_json(socket, 400, ok: false, error: "Invalid JSON")
    end

    def handle_session_action(socket, body, headers)
      return write_json(socket, 415, ok: false, error: "Content-Type must be application/json") unless json_request?(headers)

      params = JSON.parse(body.empty? ? "{}" : body)
      result = update_session(params)
      write_json(socket, result.delete(:status), result)
    rescue JSON::ParserError
      write_json(socket, 400, ok: false, error: "Invalid JSON")
    end

    def update_session(params)
      return { status: 409, ok: false, error: "Wait for queued turns to finish before changing sessions" } if turns_pending?

      result = @session_mutex.synchronize do
        return { status: 409, ok: false, error: "Wait for queued turns to finish before changing sessions" } if turns_pending?

        case params["action"]
        when "new" then create_session
        when "resume" then resume_session(params["id"])
        when "rename" then rename_session(params["id"], params["name"])
        when "delete" then delete_session(params["id"])
        else { status: 422, ok: false, error: "Unknown session action" }
        end
      end
      broadcast("session_changed", result[:session]) if result[:ok] && result[:session]
      result
    rescue StandardError => e
      { status: 422, ok: false, error: e.message }
    end

    def create_session
      previous = @session
      session = @session_store.create(
        provider: (@client.current_provider if @client.respond_to?(:current_provider)),
        model: (@client.current_model if @client.respond_to?(:current_model)),
        reasoning_effort: (@client.current_reasoning_effort if @client.respond_to?(:current_reasoning_effort))
      )
      conversation = new_conversation
      session.attach(conversation)
      activate_session(session, conversation)
      previous.delete_if_unused
      { status: 200, ok: true, session: active_session_payload }
    end

    def resume_session(id)
      info = find_session(id)
      return { status: 404, ok: false, error: "Session not found" } unless info
      return { status: 200, ok: true, session: active_session_payload } if info.id == @session.id

      previous = @session
      session, conversation = @session_store.load(
        info.path,
        workspace: @workspace,
        provider: (@client.current_provider if @client.respond_to?(:current_provider)),
        model: (@client.current_model if @client.respond_to?(:current_model)),
        reasoning_effort: (@client.current_reasoning_effort if @client.respond_to?(:current_reasoning_effort))
      )
      activate_session(session, conversation)
      previous.delete_if_unused
      { status: 200, ok: true, session: active_session_payload }
    end

    def rename_session(id, name)
      clean_name = name.to_s.strip
      return { status: 422, ok: false, error: "Session name is too long" } if clean_name.length > 120

      target = id.to_s == @session.id ? @session : find_session(id)
      return { status: 404, ok: false, error: "Session not found" } unless target

      session = target.respond_to?(:rename) ? target : @session_store.load(target.path, workspace: @workspace).first
      session.rename(clean_name)
      @session.name = session.name if session.id == @session.id
      { status: 200, ok: true, session: session_payload(session) }
    end

    def delete_session(id)
      if id.to_s == @session.id
        deleted_id = @session.id
        deleted_path = @session.path
        create_session
        SessionTrash.new.delete(deleted_path)
        return { status: 200, ok: true, deletedSessionId: deleted_id, session: active_session_payload }
      end

      info = find_session(id)
      return { status: 404, ok: false, error: "Session not found" } unless info

      SessionTrash.new.delete(info.path)
      { status: 200, ok: true, deletedSessionId: info.id }
    end

    def activate_session(session, conversation)
      @session = session
      @conversation = conversation
      @agent = build_agent
      @session_store.remember_last_session(session)
    end

    def find_session(id)
      session_infos.find { |info| info.id.to_s == id.to_s }
    end

    def session_infos
      @session_store.recent(limit: 50, keep_empty_path: @session.path)
    end

    def session_payloads
      sessions = session_infos.map { |info| session_payload(info) }
      sessions.unshift(active_session_payload) unless sessions.any? { |item| item[:id] == @session.id }
      sessions.sort_by { |item| item[:modifiedAt].to_s }.reverse
    end

    def active_session_payload
      info = session_infos.find { |item| item.id == @session.id }
      return session_payload(info).merge(active: true, path: @session.path) if info

      session_payload(@session).merge(
        active: true,
        path: @session.path,
        modifiedAt: File.mtime(@session.path).utc.iso8601(3),
        preview: transcript_items.find { |item| item[:role] == "user" }&.fetch(:text, "") || "",
        messageCount: transcript_items.length
      )
    end

    def session_payload(session)
      name = session.name.to_s.strip
      preview = session.respond_to?(:first_message) ? session.first_message.to_s : ""
      {
        id: session.id,
        name: name.empty? ? nil : name,
        title: name.empty? ? (preview.empty? ? "New session" : preview) : name,
        preview: preview,
        createdAt: session.created_at&.utc&.iso8601(3),
        modifiedAt: (session.respond_to?(:modified_at) ? session.modified_at&.utc&.iso8601(3) : nil),
        messageCount: (session.respond_to?(:message_count) ? session.message_count.to_i : 0),
        model: (session.respond_to?(:model) ? session.model : @conversation.model),
        active: session.id == @session.id
      }
    end

    def turns_pending?
      @state_mutex.synchronize { @pending_turns.positive? }
    end

    def json_request?(headers)
      headers["content-type"].to_s.downcase.start_with?("application/json")
    end

    def stream_events(socket)
      subscriber = Queue.new
      subscribe(subscriber)
      socket.write "HTTP/1.1 200 OK\r\n"
      socket.write "Content-Type: text/event-stream\r\n"
      socket.write "Cache-Control: no-cache\r\n"
      socket.write "Connection: keep-alive\r\n\r\n"
      socket.write sse("ready", queue_payload)
      socket.flush
      loop do
        socket.write subscriber.pop
        socket.flush
      end
    rescue IOError, Errno::EPIPE, Errno::ECONNRESET
      nil
    ensure
      unsubscribe(subscriber)
    end

    def subscribe(queue)
      @subscribers_mutex.synchronize { @subscribers << queue }
    end

    def unsubscribe(queue)
      @subscribers_mutex.synchronize { @subscribers.delete(queue) }
    end

    def broadcast(event, payload)
      message = sse(event, payload)
      @subscribers_mutex.synchronize do
        @subscribers.each { |subscriber| subscriber << message }
      end
    end

    def sse(event, payload)
      "event: #{event}\ndata: #{JSON.generate(payload)}\n\n"
    end

    def write_json(socket, status, payload)
      write_response(socket, status, { "Content-Type" => "application/json; charset=utf-8" }, JSON.generate(payload))
    end

    def write_response(socket, status, headers, body)
      body = body.to_s
      socket.write "HTTP/1.1 #{status} #{reason_phrase(status)}\r\n"
      headers.each { |name, value| socket.write "#{name}: #{value}\r\n" }
      socket.write "Content-Length: #{body.bytesize}\r\n"
      socket.write "Connection: close\r\n\r\n"
      socket.write body
    end

    def render_index
      @workspace_root = @workspace.root.to_s
      @workspace_label = pan_workspace_label
      @assistant_label = assistant_label
      @session_path = @session.path
      @version = Kward::VERSION
      template = File.read(File.join(__dir__, "index.html.erb"))
      ERB.new(template).result(binding)
    end

    def assistant_label
      ConfigFiles.active_persona_label(
        workspace_root: @conversation.workspace_root,
        model: @conversation.model,
        config: @full_config
      ) || "Assistant"
    rescue StandardError
      "Assistant"
    end

    def pan_workspace_label
      root = File.expand_path(@workspace.root.to_s)
      home = Dir.home
      if root == home || root.start_with?("#{home}/")
        relative = root.delete_prefix(home).delete_prefix("/")
        return "~" if relative.empty?
        return "~/#{relative}" unless relative.include?("/")
      end

      [File.basename(File.dirname(root)), File.basename(root)].reject(&:empty?).join("/")
    rescue StandardError
      @workspace.root.to_s
    end

    def pan_config(config)
      values = config["pan_mode"]
      values.is_a?(Hash) ? values : {}
    end

    def positive_port(value)
      port = value.to_i
      port.positive? ? port : DEFAULT_PORT
    end

    def display_host
      return @host unless @host == "0.0.0.0"

      lan_address || "<lan-address>"
    end

    def lan_address
      socket = @udp_socket_class.new
      socket.connect(ROUTING_PROBE_ADDRESS, ROUTING_PROBE_PORT)
      socket.addr.last
    rescue SocketError, SystemCallError
      nil
    ensure
      socket&.close
    end

    def set_active(value)
      @state_mutex.synchronize { @active = value }
    end

    def active?
      @state_mutex.synchronize { @active }
    end

    def queue_payload
      { queued: @prompt_queue.size, active: active? }
    end

    def retry_message(event)
      RetryMessage.format(event)
    end

    def tool_call_payload(tool_call)
      { name: tool_call_name(tool_call), args: tool_call_args(tool_call) }
    end

    def tool_result_payload(tool_call, content)
      { name: tool_call_name(tool_call), content: content.to_s }
    end

    def pan_transcript_items(message)
      case message[:role] || message["role"]
      when "user"
        [{ role: "user", label: "You", text: normalized_content_text(message[:content] || message["content"]) }]
      when "assistant"
        assistant_items(message[:content] || message["content"])
      when "toolResult"
        [{ role: "tool", label: "Tool output", text: tool_result_text(message) }]
      when "compactionSummary"
        [{ role: "system", label: "Compaction summary", text: message[:summary] || message["summary"] }]
      else
        text = normalized_content_text(message[:content] || message["content"])
        text.empty? ? [] : [{ role: (message[:role] || message["role"]).to_s, label: message[:role] || message["role"] || "Message", text: text }]
      end
    end

    def assistant_items(content)
      Array(content).filter_map do |part|
        next unless part.is_a?(Hash)

        case part[:type] || part["type"]
        when "thinking"
          text = part[:thinking] || part["thinking"]
          text.to_s.empty? ? nil : { role: "reasoning", label: "Reasoning", text: text }
        when "text"
          text = part[:text] || part["text"]
          text.to_s.empty? ? nil : { role: "assistant", label: assistant_label, text: text }
        when "image"
          { role: "assistant", label: assistant_label, text: image_part_text(part) }
        when "toolCall"
          { role: "tool", label: "Tool", text: tool_call_part_text(part) }
        end
      end
    end

    def normalized_content_text(content)
      Array(content).filter_map do |part|
        next part.to_s unless part.is_a?(Hash)

        case part[:type] || part["type"]
        when "text"
          part[:text] || part["text"]
        when "image"
          image_part_text(part)
        when "thinking"
          part[:thinking] || part["thinking"]
        end
      end.join("\n")
    end

    def image_part_text(part)
      alt = part[:alt] || part["alt"]
      media_type = part[:mimeType] || part["mimeType"] || "image"
      "[#{media_type}#{alt.to_s.empty? ? "" : ": #{alt}"}]"
    end

    def tool_call_part_text(part)
      name = part[:name] || part["name"] || "unknown_tool"
      arguments = part[:arguments] || part["arguments"] || {}
      "#{name} #{JSON.generate(arguments)}"
    end

    def tool_result_text(message)
      name = message[:toolName] || message["toolName"] || "tool"
      content = normalized_content_text(message[:content] || message["content"])
      "#{name}: #{content}"
    end

    def tool_call_name(tool_call)
      ToolCall.name(tool_call) || "unknown_tool"
    end

    def tool_call_args(tool_call)
      ToolCall.arguments(tool_call)
    end

    def reason_phrase(status)
      case status
      when 200 then "OK"
      when 202 then "Accepted"
      when 400 then "Bad Request"
      when 401 then "Unauthorized"
      when 404 then "Not Found"
      when 409 then "Conflict"
      when 415 then "Unsupported Media Type"
      when 422 then "Unprocessable Content"
      else "Internal Server Error"
      end
    end
  end
end
