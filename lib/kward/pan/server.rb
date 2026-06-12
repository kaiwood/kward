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
require_relative "../rpc/transcript_normalizer"
require_relative "../session_store"
require_relative "../tools/tool_call"
require_relative "../tools/registry"
require_relative "../workspace"

module Kward
  class PanServer
    DEFAULT_HOST = "0.0.0.0"
    DEFAULT_PORT = 8765
    MAX_REQUEST_BODY_BYTES = 64 * 1024

    def initialize(client:, working_directory:, config: ConfigFiles.read_config, config_dir: ConfigFiles.config_dir, output: $stderr)
      @client = client
      @output = output
      @workspace = Workspace.new(root: working_directory)
      @config = pan_config(config)
      @host = @config.fetch("host", DEFAULT_HOST).to_s
      @port = positive_port(@config.fetch("port", DEFAULT_PORT))
      @username = @config["username"].to_s
      @password = @config["password"].to_s
      raise "Pan mode requires pan_mode.username and pan_mode.password in #{ConfigFiles.config_path}" if @username.empty? || @password.empty?

      @session_store = SessionStore.new(config_dir: config_dir, cwd: @workspace.root.to_s)
      @session = @session_store.create
      @conversation = Conversation.new(
        workspace_root: @workspace.root.to_s,
        model: (@client.current_model if @client.respond_to?(:current_model)),
        reasoning_effort: (@client.current_reasoning_effort if @client.respond_to?(:current_reasoning_effort))
      )
      @session.attach(@conversation)
      @agent = Agent.new(
        client: @client,
        tool_registry: ToolRegistry.new(workspace: @workspace, ask_user_question_enabled: false),
        conversation: @conversation
      )
      @prompt_queue = Queue.new
      @subscribers = []
      @subscribers_mutex = Mutex.new
      @worker_started = false
      @active = false
      @state_mutex = Mutex.new
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

      queued_at = Time.now.utc.iso8601(3)
      @prompt_queue << { prompt: text, queued_at: queued_at }
      broadcast("queue", queue_payload)
      { ok: true, queued: @prompt_queue.size, active: active? }
    end

    def transcript_items
      RPC::TranscriptNormalizer.new(@conversation.messages).normalize.flat_map { |message| pan_transcript_items(message) }
    end

    private

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
      set_active(false)
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
      when ["GET", "/transcript"]
        write_json(socket, 200, transcript: transcript_items, session: { id: @session.id, path: @session.path }, workspace: @workspace.root.to_s)
      when ["GET", "/events"]
        stream_events(socket)
      when ["POST", "/turn"]
        handle_turn(socket, request[:body])
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

    def handle_turn(socket, body)
      params = JSON.parse(body.empty? ? "{}" : body)
      result = enqueue_prompt(params["prompt"])
      status = result[:ok] ? 202 : 422
      write_json(socket, status, result)
    rescue JSON::ParserError
      write_json(socket, 400, ok: false, error: "Invalid JSON")
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
      @session_path = @session.path
      template = File.read(File.join(__dir__, "index.html.erb"))
      ERB.new(template).result(binding)
    end

    def pan_config(config)
      values = config["pan_mode"] || config["panMode"]
      values.is_a?(Hash) ? values : {}
    end

    def positive_port(value)
      port = value.to_i
      port.positive? ? port : DEFAULT_PORT
    end

    def display_host
      @host == "0.0.0.0" ? "<lan-address>" : @host
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
          text.to_s.empty? ? nil : { role: "assistant", label: "Assistant", text: text }
        when "image"
          { role: "assistant", label: "Assistant", text: image_part_text(part) }
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
      when 422 then "Unprocessable Content"
      else "Internal Server Error"
      end
    end
  end
end
