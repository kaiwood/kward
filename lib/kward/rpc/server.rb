require "json"
require_relative "../client"
require_relative "../config_files"
require_relative "../tool_registry"
require_relative "../workspace"
require_relative "auth_manager"
require_relative "config_manager"
require_relative "redactor"
require_relative "session_manager"
require_relative "transport"

module Kward
  module RPC
    class Server
      PROTOCOL_VERSION = 1
      JSONRPC_VERSION = "2.0"
      BUILTIN_SLASH_COMMAND_NAMES = %w[exit quit new resume name clone export redraw status].freeze

      ERROR_CODES = {
        parse_error: -32_700,
        invalid_request: -32_600,
        method_not_found: -32_601,
        invalid_params: -32_602,
        internal_error: -32_603
      }.freeze

      def initialize(input: $stdin, output: $stdout, error_output: $stderr, client: Client.new)
        @transport = Transport.new(input: input, output: output)
        @error_output = error_output
        @session_manager = SessionManager.new(server: self, client: client)
        @auth_manager = AuthManager.new(server: self)
        @config_manager = ConfigManager.new
        @shutdown = false
      end

      def run
        until @shutdown
          begin
            message = @transport.read_message
            break unless message

            handle_message(message)
          rescue JSON::ParserError => e
            write_error(nil, ERROR_CODES[:parse_error], "Parse error", e)
          rescue StandardError => e
            write_error(nil, ERROR_CODES[:invalid_request], e.message, e)
          end
        end
      end

      def notify(method, params = {})
        @transport.write_message({ jsonrpc: JSONRPC_VERSION, method: method, params: Redactor.redact(params) })
      end

      def error_payload(error)
        Redactor.redact({
          code: error.class.name,
          message: error.message,
          backtrace: Array(error.backtrace).first(8)
        })
      end

      def log_error(error)
        @error_output.puts("Kward RPC error: #{Redactor.redact_string(error.message)}") if @error_output
      end

      private

      def handle_message(message)
        unless message.is_a?(Hash) && (message["jsonrpc"] == JSONRPC_VERSION || message[:jsonrpc] == JSONRPC_VERSION)
          write_error(message_id(message), ERROR_CODES[:invalid_request], "Invalid Request")
          return
        end

        id = message_id(message)
        method = message["method"] || message[:method]
        params = message["params"] || message[:params] || {}

        unless method.is_a?(String) && !method.empty?
          write_error(id, ERROR_CODES[:invalid_request], "Invalid Request") if id
          return
        end

        if id.nil?
          dispatch(method, params)
        else
          result = dispatch(method, params)
          write_result(id, result)
        end
      rescue NoMethodError => e
        write_error(id, ERROR_CODES[:method_not_found], "Method not found: #{method}", e) if id
      rescue ArgumentError => e
        write_error(id, ERROR_CODES[:invalid_params], e.message, e) if id
      rescue StandardError => e
        write_error(id, ERROR_CODES[:internal_error], e.message, e) if id
      end

      def dispatch(method, params)
        params = stringify_keys(params || {})
        case method
        when "initialize"
          initialize_result
        when "shutdown"
          @shutdown = true
          { ok: true }
        when "workspace/validate"
          { root: @session_manager.validate_workspace_root(params["workspaceRoot"] || Dir.pwd) }
        when "workspace/info"
          workspace_info(params["workspaceRoot"] || Dir.pwd)
        when "tools/list"
          { tools: ToolRegistry.new.schemas }
        when "prompts/list"
          prompts_list
        when "prompts/expand"
          prompts_expand(params)
        when "models/list"
          models_list
        when "models/current"
          models_current
        when "models/set"
          models_set(params)
        when "reasoning/set"
          reasoning_set(params)
        when "config/read"
          { path: @config_manager.config_path, config: @config_manager.read(redacted: params.fetch("redacted", true)) }
        when "config/update"
          { path: @config_manager.config_path, config: @config_manager.update(params.fetch("values")) }
        when "auth/status"
          @auth_manager.status
        when "auth/startOpenAILogin"
          @auth_manager.start_openai_login(timeout_seconds: params["timeoutSeconds"] || 120)
        when "auth/submitOpenAICode"
          @auth_manager.submit_openai_code(login_id: params.fetch("loginId"), code: params.fetch("code"))
        when "auth/loginStatus"
          @auth_manager.login_status(login_id: params.fetch("loginId"))
        when "sessions/create"
          @session_manager.create_session(workspace_root: params["workspaceRoot"] || Dir.pwd, name: params["name"])
        when "sessions/resume"
          @session_manager.resume_session(path: params.fetch("path"), workspace_root: params["workspaceRoot"])
        when "sessions/list"
          { sessions: @session_manager.list_sessions(workspace_root: params["workspaceRoot"] || Dir.pwd, limit: params["limit"] || 20) }
        when "sessions/rename"
          @session_manager.rename_session(session_id: params.fetch("sessionId"), name: params["name"])
        when "sessions/clone"
          @session_manager.clone_session(session_id: params.fetch("sessionId"))
        when "sessions/export"
          @session_manager.export_session(session_id: params.fetch("sessionId"), path: params["path"], format: params["format"])
        when "sessions/delete"
          @session_manager.delete_session(session_id: params.fetch("sessionId"))
        when "sessions/close"
          @session_manager.close_session(session_id: params.fetch("sessionId"))
        when "sessions/transcript"
          @session_manager.transcript(session_id: params.fetch("sessionId"))
        when "turns/start"
          @session_manager.start_turn(session_id: params.fetch("sessionId"), input: params.fetch("input"))
        when "turns/cancel"
          @session_manager.cancel_turn(turn_id: params.fetch("turnId"))
        when "turns/status"
          @session_manager.turn_status(turn_id: params.fetch("turnId"))
        when "turns/events"
          @session_manager.turn_events(turn_id: params.fetch("turnId"), after_sequence: params["afterSequence"] || 0)
        when "ui/answerQuestion"
          @session_manager.answer_question(session_id: params.fetch("sessionId"), question_request_id: params.fetch("questionRequestId"), answers: params.fetch("answers"))
        else
          raise NoMethodError, method
        end
      end

      def initialize_result
        {
          protocolVersion: PROTOCOL_VERSION,
          serverName: "kward",
          experimental: true,
          capabilities: {
            framing: "content-length",
            sessions: true,
            asyncTurns: true,
            turnCancellation: "best-effort",
            turnEventReplay: true,
            uiQuestions: true,
            authLogin: true,
            configUpdate: true,
            session: { mode: "explicit", persistence: "jsonl" },
            turns: { mode: "async", perSessionConcurrency: 1 },
            cancellation: { behavior: "best-effort", queuedTurns: "cancel-before-run", runningTurns: "stop-emitting-events-when-possible" },
            eventReplay: { behavior: "recent-in-memory", persisted: false, limit: SessionManager::RECENT_EVENT_LIMIT },
            uiQuestion: { supported: true, method: "ui/answerQuestion", notification: "ui/question", maxQuestions: 4, multiSelect: false },
            prompts: { supported: true, methods: ["prompts/list", "prompts/expand"] },
            skills: { supported: true, tool: "read_skill" },
            tools: { supported: true, method: "tools/list", eventMetadata: true },
            models: { supported: true, methods: ["models/list", "models/current", "models/set", "reasoning/set"] },
            auth: { supported: true, methods: ["auth/status", "auth/startOpenAILogin", "auth/submitOpenAICode", "auth/loginStatus"] },
            config: { supported: true, methods: ["config/read", "config/update"] },
            export: { supported: true, formats: ["markdown", "html"], defaultFormat: "markdown" }
          }
        }
      end

      def workspace_info(root)
        root = @session_manager.validate_workspace_root(root)
        { root: root, basename: File.basename(root), writable: File.writable?(root) }
      end

      def prompts_list
        templates = ConfigFiles.prompt_templates(reserved_commands: BUILTIN_SLASH_COMMAND_NAMES)
        {
          prompts: templates.map do |template|
            {
              command: template.command,
              description: template.description,
              argumentHint: template.argument_hint,
              path: template.path
            }
          end
        }
      end

      def prompts_expand(params)
        command = params.fetch("command").to_s.delete_prefix("/")
        template = ConfigFiles.prompt_templates(reserved_commands: BUILTIN_SLASH_COMMAND_NAMES).find { |candidate| candidate.command == command }
        raise "Unknown prompt template: #{command}" unless template

        { command: command, text: template.expand(params["arguments"].to_s) }
      end

      def models_list
        { models: @session_manager.available_models }
      end

      def models_current
        @session_manager.current_model
      end

      def models_set(params)
        provider = params["provider"] || @session_manager.current_model[:provider]
        @config_manager.set_model(params.fetch("model"), provider: provider)
        @session_manager.refresh_client_config
        @session_manager.current_model
      end

      def reasoning_set(params)
        @config_manager.set_reasoning_effort(params.fetch("effort"))
        @session_manager.refresh_client_config
        @session_manager.current_model
      end

      def write_result(id, result)
        @transport.write_message({ jsonrpc: JSONRPC_VERSION, id: id, result: Redactor.redact(result) })
      end

      def write_error(id, code, message, exception = nil)
        error = { code: code, message: Redactor.redact_string(message.to_s) }
        error[:data] = error_payload(exception) if exception
        @transport.write_message({ jsonrpc: JSONRPC_VERSION, id: id, error: error })
      end

      def message_id(message)
        return nil unless message.is_a?(Hash)

        message.key?("id") ? message["id"] : message[:id]
      end

      def stringify_keys(value)
        case value
        when Hash
          value.each_with_object({}) { |(key, item), result| result[key.to_s] = stringify_keys(item) }
        when Array
          value.map { |item| stringify_keys(item) }
        else
          value
        end
      end
    end
  end
end
