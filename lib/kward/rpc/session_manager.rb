require "cgi"
require "securerandom"
require "thread"
require "time"
require_relative "../agent"
require_relative "../client"
require_relative "../config_files"
require_relative "../conversation"
require_relative "../events"
require_relative "../session_store"
require_relative "../tool_registry"
require_relative "../workspace"
require_relative "prompt_bridge"

module Kward
  module RPC
    class SessionManager
      RECENT_EVENT_LIMIT = 1_000

      RpcSession = Struct.new(:id, :workspace_root, :store, :session, :conversation, :agent, :prompt, :queue, :worker, :running_turn_id, keyword_init: true)
      Turn = Struct.new(:id, :session_id, :input, :status, :cancel_requested, :created_at, :started_at, :finished_at, :events, :next_sequence, :error, keyword_init: true)

      def initialize(server:, client: Client.new, config_dir: ConfigFiles.config_dir)
        @server = server
        @client = client
        @config_dir = config_dir
        @sessions = {}
        @turns = {}
        @mutex = Mutex.new
      end

      def create_session(workspace_root: Dir.pwd, name: nil)
        workspace_root = validate_workspace_root(workspace_root)
        store = SessionStore.new(config_dir: @config_dir, cwd: workspace_root)
        session = store.create
        session.rename(name) unless name.to_s.strip.empty?
        conversation = Conversation.new
        session.attach(conversation)
        rpc_session = build_rpc_session(store, session, conversation, workspace_root)
        remember_session(rpc_session)
        session_payload(rpc_session)
      end

      def resume_session(path:, workspace_root: nil)
        root = validate_workspace_root(workspace_root || Dir.pwd)
        store = SessionStore.new(config_dir: @config_dir, cwd: root)
        session, conversation = store.load(path, workspace: Workspace.new(root: root))
        root = validate_workspace_root(session.cwd) unless session.cwd.to_s.empty?
        store = SessionStore.new(config_dir: @config_dir, cwd: root)
        rpc_session = build_rpc_session(store, session, conversation, root)
        remember_session(rpc_session)
        session_payload(rpc_session)
      end

      def list_sessions(workspace_root: Dir.pwd, limit: 20)
        root = validate_workspace_root(workspace_root)
        store = SessionStore.new(config_dir: @config_dir, cwd: root)
        store.recent(limit: limit.to_i <= 0 ? 20 : limit.to_i).map { |info| session_info_payload(info) }
      end

      def rename_session(session_id:, name:)
        rpc_session = fetch_session(session_id)
        rpc_session.session.rename(name)
        session_payload(rpc_session)
      end

      def clone_session(session_id:)
        source = fetch_session(session_id)
        session = source.store.create_from_conversation(source.conversation)
        rpc_session = build_rpc_session(source.store, session, source.conversation, source.workspace_root)
        remember_session(rpc_session)
        session_payload(rpc_session)
      end

      def export_session(session_id:, path: nil, format: nil)
        rpc_session = fetch_session(session_id)
        format = export_format(format)
        path = export_path(rpc_session, path, format)
        content = export_content(rpc_session.conversation, format)
        File.write(path, content)
        { path: path, format: format }
      end

      def delete_session(session_id:)
        rpc_session = fetch_session(session_id)
        path = rpc_session.session.path
        close_session(session_id: session_id)
        File.delete(path) if File.exist?(path)
        { deleted: true, path: path }
      end

      def close_session(session_id:)
        rpc_session = fetch_session(session_id)
        @mutex.synchronize { @sessions.delete(session_id) }
        rpc_session.session.delete_if_unused if rpc_session.session.respond_to?(:delete_if_unused)
        { closed: true }
      end

      def transcript(session_id:)
        rpc_session = fetch_session(session_id)
        { session: session_payload(rpc_session), messages: rpc_session.conversation.messages }
      end

      def start_turn(session_id:, input:)
        rpc_session = fetch_session(session_id)
        turn = Turn.new(
          id: SecureRandom.uuid,
          session_id: rpc_session.id,
          input: input.to_s,
          status: "queued",
          cancel_requested: false,
          created_at: now,
          events: [],
          next_sequence: 1
        )
        @mutex.synchronize { @turns[turn.id] = turn }
        rpc_session.queue << turn.id
        ensure_worker(rpc_session)
        emit_turn_event(turn, "turnQueued", {})
        turn_payload(turn)
      end

      def cancel_turn(turn_id:)
        turn = fetch_turn(turn_id)
        turn.cancel_requested = true
        emit_turn_event(turn, "turnCancelRequested", {})
        if turn.status == "queued"
          finish_turn(turn, "canceled")
        end
        turn_payload(turn)
      end

      def turn_status(turn_id:)
        turn_payload(fetch_turn(turn_id))
      end

      def turn_events(turn_id:, after_sequence: 0)
        turn = fetch_turn(turn_id)
        after_sequence = after_sequence.to_i
        {
          turn: turn_payload(turn),
          events: turn.events.select { |event| event[:sequence].to_i > after_sequence }
        }
      end

      def answer_question(session_id:, question_request_id:, answers:)
        rpc_session = fetch_session(session_id)
        rpc_session.prompt.answer(question_request_id, answers)
        { ok: true }
      end

      def available_models
        @client.respond_to?(:available_models) ? @client.available_models : []
      end

      def current_model
        provider = @client.respond_to?(:current_provider) ? @client.current_provider : nil
        model = @client.respond_to?(:current_model) ? @client.current_model : nil
        reasoning = @client.respond_to?(:current_reasoning_effort) ? @client.current_reasoning_effort : nil
        { provider: provider, model: model, reasoningEffort: reasoning }.compact
      end

      def refresh_client_config
        @client.reload_config if @client.respond_to?(:reload_config)
      end

      def session_payload(rpc_session)
        {
          id: rpc_session.id,
          workspaceRoot: rpc_session.workspace_root,
          path: rpc_session.session.path,
          persistentId: rpc_session.session.id,
          name: rpc_session.session.name,
          createdAt: rpc_session.session.created_at&.utc&.iso8601(3)
        }
      end

      def validate_workspace_root(root)
        expanded = File.expand_path(root.to_s.empty? ? Dir.pwd : root.to_s)
        raise "Workspace root is not an existing directory: #{expanded}" unless File.directory?(expanded)

        File.realpath(expanded)
      end

      private

      def build_rpc_session(store, session, conversation, workspace_root)
        id = SecureRandom.uuid
        prompt = PromptBridge.new(server: @server, session_id: id)
        workspace = Workspace.new(root: workspace_root)
        agent = Agent.new(
          client: @client,
          tool_registry: ToolRegistry.new(workspace: workspace, prompt: prompt),
          conversation: conversation
        )
        RpcSession.new(
          id: id,
          workspace_root: workspace_root,
          store: store,
          session: session,
          conversation: conversation,
          agent: agent,
          prompt: prompt,
          queue: Queue.new,
          worker: nil,
          running_turn_id: nil
        )
      end

      def remember_session(rpc_session)
        @mutex.synchronize { @sessions[rpc_session.id] = rpc_session }
      end

      def fetch_session(session_id)
        @mutex.synchronize { @sessions[session_id.to_s] } || raise("Unknown session: #{session_id}")
      end

      def fetch_turn(turn_id)
        @mutex.synchronize { @turns[turn_id.to_s] } || raise("Unknown turn: #{turn_id}")
      end

      def ensure_worker(rpc_session)
        return if rpc_session.worker&.alive?

        rpc_session.worker = Thread.new { worker_loop(rpc_session) }
      end

      def worker_loop(rpc_session)
        loop do
          turn_id = rpc_session.queue.pop
          turn = fetch_turn(turn_id)
          next if turn.status == "canceled"

          run_turn(rpc_session, turn)
        rescue StandardError => e
          @server.log_error(e)
        end
      end

      def run_turn(rpc_session, turn)
        rpc_session.running_turn_id = turn.id
        turn.status = "running"
        turn.started_at = now
        emit_turn_event(turn, "turnStarted", {})

        if turn.cancel_requested
          finish_turn(turn, "canceled")
          return
        end

        rpc_session.agent.ask(turn.input) do |event|
          handle_agent_event(turn, event) unless turn.cancel_requested
        end
        finish_turn(turn, turn.cancel_requested ? "canceled" : "completed")
      rescue StandardError => e
        turn.error = @server.error_payload(e)
        emit_turn_event(turn, "error", turn.error)
        finish_turn(turn, "failed")
      ensure
        rpc_session.running_turn_id = nil
      end

      def handle_agent_event(turn, event)
        case event
        when Events::ReasoningDelta
          emit_turn_event(turn, "reasoningDelta", { delta: event.delta })
        when Events::AssistantDelta
          emit_turn_event(turn, "assistantDelta", { delta: event.delta })
        when Events::AssistantMessage
          emit_turn_event(turn, "assistantMessage", { message: event.message })
        when Events::ToolCall
          emit_turn_event(turn, "toolCall", { toolCall: event.tool_call, tool: tool_metadata(event.tool_call) })
        when Events::ToolResult
          emit_turn_event(turn, "toolResult", { toolCall: event.tool_call, tool: tool_metadata(event.tool_call), content: event.content })
        when Events::Answer
          emit_turn_event(turn, "answer", { content: event.content })
        end
      end

      def finish_turn(turn, status)
        return if ["completed", "failed", "canceled"].include?(turn.status)

        turn.status = status
        turn.finished_at = now
        emit_turn_event(turn, "turnFinished", { status: status, error: turn.error }.compact)
      end

      def emit_turn_event(turn, type, payload)
        event = {
          sequence: turn.next_sequence,
          timestamp: now,
          sessionId: turn.session_id,
          turnId: turn.id,
          type: type,
          payload: payload
        }
        turn.next_sequence += 1
        turn.events << event
        turn.events.shift while turn.events.length > RECENT_EVENT_LIMIT
        @server.notify("turn/event", event)
        event
      end

      def turn_payload(turn)
        {
          id: turn.id,
          sessionId: turn.session_id,
          status: turn.status,
          cancelRequested: turn.cancel_requested,
          createdAt: turn.created_at,
          startedAt: turn.started_at,
          finishedAt: turn.finished_at,
          error: turn.error
        }.compact
      end

      def session_info_payload(info)
        {
          id: info.id,
          path: info.path,
          cwd: info.cwd,
          createdAt: info.created_at&.utc&.iso8601(3),
          modifiedAt: info.modified_at&.utc&.iso8601(3),
          name: info.name,
          firstMessage: info.first_message
        }
      end

      def export_path(rpc_session, path, format)
        explicit = path.to_s.strip
        return File.expand_path(explicit, rpc_session.workspace_root) unless explicit.empty?

        extension = format == "html" ? ".html" : ".md"
        rpc_session.session.path.sub(/\.jsonl\z/, extension)
      end

      def export_format(format)
        value = format.to_s.strip.downcase
        value = "markdown" if value.empty? || value == "md"
        raise "Unsupported export format: #{format}" unless ["markdown", "html"].include?(value)

        value
      end

      def export_content(conversation, format)
        markdown = markdown_transcript(conversation)
        return markdown if format == "markdown"

        html_transcript(markdown)
      end

      def html_transcript(markdown)
        escaped = CGI.escapeHTML(markdown)
        <<~HTML
          <!doctype html>
          <html>
          <head>
            <meta charset="utf-8">
            <title>Kward Session</title>
          </head>
          <body>
          <pre>#{escaped}</pre>
          </body>
          </html>
        HTML
      end

      def tool_metadata(tool_call)
        function = tool_call["function"] || tool_call[:function] || {}
        name = function["name"] || function[:name]
        args = parse_tool_arguments(function["arguments"] || function[:arguments])

        case name
        when "edit_file"
          edit = Array(args["edits"] || args[:edits]).first || {}
          {
            kind: "edit",
            path: args["path"] || args[:path],
            oldText: edit["old_text"] || edit[:old_text],
            newText: edit["new_text"] || edit[:new_text]
          }.compact
        when "write_file"
          { kind: "write", path: args["path"] || args[:path] }.compact
        when "run_shell_command"
          { kind: "shell", command: args["command"] || args[:command] }.compact
        else
          nil
        end
      end

      def parse_tool_arguments(arguments)
        return {} if arguments.nil? || arguments.empty?
        return arguments if arguments.is_a?(Hash)

        JSON.parse(arguments)
      rescue JSON::ParserError
        {}
      end

      def markdown_transcript(conversation)
        lines = ["# Kward Session", ""]
        conversation.messages.each do |message|
          role = message["role"] || message[:role]
          next if role == "system"

          lines << "## #{role.to_s.capitalize}"
          name = message["name"] || message[:name]
          lines << "Tool: `#{name}`" if role == "tool" && name
          lines << ""
          lines << markdown_content(message["content"] || message[:content])
          lines << ""
        end
        lines.join("\n")
      end

      def markdown_content(content)
        case content
        when Array
          content.map do |part|
            text = part["text"] || part[:text]
            next text if text

            path = part["path"] || part[:path]
            media_type = part["media_type"] || part[:media_type] || "image"
            "[#{media_type}#{path ? ": #{path}" : ""}]"
          end.compact.join("\n")
        else
          content.to_s
        end
      end

      def now
        Time.now.utc.iso8601(3)
      end
    end
  end
end
