require "json"
require_relative "../model/client"
require_relative "../config_files"
require_relative "../memory/manager"
require_relative "../plugin_registry"
require_relative "../prompt_commands"
require_relative "../tool_registry"
require_relative "../workspace"
require_relative "../telemetry_logger"
require_relative "../telemetry_stats"
require_relative "auth_manager"
require_relative "config_manager"
require_relative "redactor"
require_relative "session_manager"
require_relative "transport"

module Kward
  module RPC
    # Experimental JSON-RPC backend for UI clients.
    #
    # The server speaks LSP-style Content-Length framing over stdin/stdout,
    # exposes capabilities during `initialize`, redacts secrets in errors and
    # notifications, and coordinates auth, config, sessions, turns, tools,
    # memory, commands, and startup resources.
    class Server
      PROTOCOL_VERSION = 1
      JSONRPC_VERSION = "2.0"
      BUILTIN_SLASH_COMMAND_NAMES = PromptCommands::BUILTIN_RESERVED_COMMAND_NAMES

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
        @config_manager = ConfigManager.new
        @auth_manager = AuthManager.new(server: self, config_manager: @config_manager)
        @shutdown = false
      end

      # Reads framed JSON-RPC messages until shutdown or EOF.
      #
      # @return [void]
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
      ensure
        @session_manager.cleanup_unused_sessions
      end

      # Sends a redacted JSON-RPC notification to the client.
      #
      # @param method [String] notification method name
      # @param params [Hash] notification params
      def notify(method, params = {})
        @transport.write_message({ jsonrpc: JSONRPC_VERSION, method: method, params: Redactor.redact(params) })
      end

      # Builds redacted diagnostics suitable for JSON-RPC error data.
      #
      # @param error [Exception]
      # @return [Hash]
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
        when "openrouter/catalog"
          openrouter_catalog
        when "models/current"
          models_current
        when "models/set"
          models_set(params)
        when "reasoning/set"
          reasoning_set(params)
        when "runtime/state"
          @session_manager.runtime_state(session_id: params.fetch("sessionId"))
        when "runtime/stats"
          @session_manager.runtime_stats(session_id: params.fetch("sessionId"))
        when "runtime/updateSetting"
          runtime_update_setting(params)
        when "runtime/reload"
          runtime_reload(params)
        when "commands/list"
          commands_list(params)
        when "commands/run"
          commands_run(params)
        when "resources/startup"
          startup_resources(params)
        when "config/read"
          { path: @config_manager.config_path, config: @config_manager.read(redacted: params.fetch("redacted", true)) }
        when "config/update"
          { path: @config_manager.config_path, config: @config_manager.update(params.fetch("values")) }
        when "logging/stats"
          logging_stats(params)
        when "logging/tokenCsv"
          logging_token_csv(params)
        when "memory/status"
          @session_manager.memory_status
        when "memory/enable"
          @session_manager.memory_enable
        when "memory/disable"
          @session_manager.memory_disable
        when "memory/autoSummary/enable"
          @session_manager.memory_auto_summary_enable
        when "memory/autoSummary/disable"
          @session_manager.memory_auto_summary_disable
        when "memory/list"
          @session_manager.memory_list(include_inactive: params["includeInactive"] || false)
        when "memory/add"
          @session_manager.memory_add(text: params.fetch("text"), scope: params["scope"], tags: params["tags"] || [])
        when "memory/addCore"
          @session_manager.memory_add_core(text: params.fetch("text"), scope: params["scope"], tags: params["tags"] || [])
        when "memory/forget"
          @session_manager.memory_forget(id: params.fetch("id"))
        when "memory/promote"
          @session_manager.memory_promote(id: params.fetch("id"))
        when "memory/inspect"
          @session_manager.memory_inspect
        when "memory/why"
          @session_manager.memory_why(session_id: params["sessionId"])
        when "memory/summarize"
          @session_manager.memory_summarize(session_id: params.fetch("sessionId"))
        when "auth/status"
          @auth_manager.status
        when "auth/providers"
          @auth_manager.providers
        when "auth/loginWithApiKey"
          auth_login_with_api_key(params)
        when "auth/logoutProvider"
          auth_logout_provider(params)
        when "auth/loginWithOAuth"
          @auth_manager.login_with_oauth(provider_id: params.fetch("providerId"), timeout_seconds: params["timeoutSeconds"] || 120)
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
        when "sessions/compact"
          @session_manager.compact_session(session_id: params.fetch("sessionId"), custom_instructions: params["customInstructions"] || "")
        when "sessions/forkMessages"
          @session_manager.fork_messages(session_id: params.fetch("sessionId"))
        when "sessions/fork"
          @session_manager.fork_session(session_id: params.fetch("sessionId"), entry_id: params.fetch("entryId"))
        when "sessions/export"
          @session_manager.export_session(session_id: params.fetch("sessionId"), path: params["path"], format: params["format"])
        when "sessions/delete"
          @session_manager.delete_session(session_id: params.fetch("sessionId"))
        when "sessions/close"
          @session_manager.close_session(session_id: params.fetch("sessionId"))
        when "sessions/transcript"
          @session_manager.transcript(session_id: params.fetch("sessionId"))
        when "turns/start"
          @session_manager.start_turn(
            session_id: params.fetch("sessionId"),
            input: params.fetch("input"),
            streaming_behavior: params["streamingBehavior"],
            attachments: params["attachments"] || []
          )
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
          capabilities: capabilities
        }
      end

      def capabilities
        {
          framing: "content-length",
          asyncTurns: true,
          turnCancellation: "best-effort",
          turnEventReplay: true,
          uiQuestions: true,
          authLogin: true,
          configUpdate: true,
          transcript: {
            format: "tauren-transcript-v1",
            messagesNormalized: true,
            supportsImages: true,
            supportsToolCalls: true,
            supportsToolResults: true,
            supportsCompactionSummaries: true,
            supportsReasoningRestore: true
          },
          sessions: {
            mode: "explicit",
            persistence: "jsonl",
            methods: ["sessions/create", "sessions/resume", "sessions/list", "sessions/rename", "sessions/clone", "sessions/compact", "sessions/forkMessages", "sessions/fork", "sessions/export", "sessions/delete", "sessions/close", "sessions/transcript"],
            list: { supported: true, source: "rpc", ancestry: true, treeFields: true },
            fork: { supported: true, methods: ["sessions/forkMessages", "sessions/fork"], entryIdFormat: "message-index", selectedMessage: "excludedFromForkComposerTextReturned" },
            compact: { supported: true, method: "sessions/compact", notification: "session/event", events: ["compactionStart", "compactionEnd"] },
            import: { supported: false },
            tree: { supported: false, labels: false, navigate: false, summarize: false },
            updates: { supported: false, notification: "session/updated" }
          },
          turns: {
            mode: "async",
            perSessionConcurrency: 1,
            busyInput: {
              steer: @session_manager.in_flight_steer_supported? ? "native" : "unsupported",
              followUp: "queue",
              defaultWhenIdle: "newTurn",
              defaultWhenBusy: @session_manager.in_flight_steer_supported? ? "steer" : "followUp"
            },
            cancellation: {
              behavior: "best-effort",
              queuedTurns: "cancel-before-run",
              runningTurns: "stop-emitting-events-when-possible"
            },
            eventReplay: { behavior: "recent-in-memory", persisted: false, limit: SessionManager::RECENT_EVENT_LIMIT }
          },
          events: {
            notification: "turn/event",
            assistantText: "assistantDelta",
            reasoning: { start: false, delta: true, end: false },
            modelRetry: { supported: true, event: "modelRetry" },
            steering: { supported: @session_manager.in_flight_steer_supported?, event: "turnSteered", mode: @session_manager.in_flight_steer_supported? ? "native" : "unsupported" },
            tools: { call: true, update: false, result: true, normalizedMetadata: true, diffs: true, changedFiles: false },
            errors: true,
            sessionUpdates: false
          },
          attachments: {
            input: {
              supported: true,
              method: "turns/start",
              encoding: "base64",
              mimeTypes: SessionManager::RPC_IMAGE_MIME_TYPES,
              maxBytes: SessionManager::RPC_ATTACHMENT_MAX_BYTES
            }
          },
          models: {
            supported: true,
            methods: ["models/list", "models/current", "models/set", "reasoning/set", "openrouter/catalog"],
            fields: ["provider", "id", "name", "reasoning", "reasoningEffort", "contextWindow"],
            scopedModels: false
          },
          runtime: {
            supported: true,
            methods: ["runtime/state", "runtime/stats"],
            state: { supported: true },
            stats: { messageCounts: true, tokens: false, cost: false, contextUsage: true, contextUsageEstimated: true }
          },
          runtimeSettings: {
            supported: true,
            methods: ["runtime/updateSetting", "runtime/reload"],
            settings: ["defaultModel", "defaultThinkingLevel"]
          },
          auth: {
            supported: true,
            providerFormat: "tauren-auth-v1",
            methods: ["auth/status", "auth/providers", "auth/loginWithApiKey", "auth/logoutProvider", "auth/loginWithOAuth", "auth/startOpenAILogin", "auth/submitOpenAICode", "auth/loginStatus"],
            oauthProviders: ["openai", "github"],
            unsupportedOAuthProviders: { github: "CLI-only GitHub login for Copilot scaffolding; RPC login is not implemented yet." },
            apiKeyProviders: ["openrouter"],
            logout: true
          },
          memory: { supported: true, optIn: true, defaultEnabled: false, autoSummaryDefaultEnabled: false, promptInjection: "interactive", storage: { core: "json", soft: "jsonl", events: "jsonl" }, methods: ["memory/status", "memory/enable", "memory/disable", "memory/autoSummary/enable", "memory/autoSummary/disable", "memory/list", "memory/add", "memory/addCore", "memory/forget", "memory/promote", "memory/inspect", "memory/why", "memory/summarize"] },
          commands: { supported: true, methods: ["commands/list", "commands/run"], method: "commands/list", runMethod: "commands/run", sources: ["builtin", "prompt", "skill", "plugin"], executableSources: ["builtin", "plugin"] },
          startupResources: { supported: true, method: "resources/startup" },
          extensionUi: {
            question: { supported: true, notification: "ui/question", method: "ui/answerQuestion", maxQuestions: 4, multiSelect: false, preview: false },
            select: false,
            confirm: false,
            input: false,
            editor: false,
            widgets: false,
            footer: false,
            custom: false,
            terminalInput: false
          },
          composer: {
            sessionDiff: { supported: false, reason: "interactiveComposerOnly" },
            copy: { supported: false, reason: "clientClipboardOwnedByUi" }
          },
          security: {
            workspaceMutationGuard: "none",
            toolApproval: "none",
            canRunShell: true,
            canWriteFiles: true
          },
          export: { supported: true, formats: ["markdown", "html"], defaultFormat: "markdown" },
          logging: {
            supported: true,
            defaultEnabled: false,
            methods: ["logging/stats", "logging/tokenCsv"],
            stats: { supported: true, method: "logging/stats", defaultRange: TelemetryStats::DEFAULT_RANGE, units: %w[minutes hours days weeks months years] },
            usageCsv: { supported: true, method: "logging/tokenCsv", defaultRange: TelemetryStats::DEFAULT_RANGE, buckets: %w[second minute hour day week month year] },
            config: "logging",
            envPrefix: "KWARD_LOGGING",
            directory: File.join(ConfigFiles.config_dir, "logs"),
            format: "jsonl",
            categories: ["tokens", "performance", "tools", "errors"],
            rotation: { maxBytes: TelemetryLogger::DEFAULT_MAX_BYTES, retention: "manual" },
            content: "redacted-metadata-only"
          },
          session: { mode: "explicit", persistence: "jsonl" },
          cancellation: { behavior: "best-effort", queuedTurns: "cancel-before-run", runningTurns: "stop-emitting-events-when-possible" },
          eventReplay: { behavior: "recent-in-memory", persisted: false, limit: SessionManager::RECENT_EVENT_LIMIT },
          uiQuestion: { supported: true, method: "ui/answerQuestion", notification: "ui/question", maxQuestions: 4, multiSelect: false },
          prompts: { supported: true, methods: ["prompts/list", "prompts/expand"] },
          skills: { supported: true, tool: "read_skill" },
          tools: { supported: true, method: "tools/list", eventMetadata: true },
          config: { supported: true, methods: ["config/read", "config/update"] }
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

      def openrouter_catalog
        { models: @session_manager.openrouter_catalog }
      end

      def runtime_update_setting(params)
        session_id = params.fetch("sessionId")
        @session_manager.runtime_state(session_id: session_id)
        setting_id = params.fetch("settingId").to_s
        value = params.fetch("value")
        case setting_id
        when "defaultModel"
          provider, model = provider_model_from(value)
          @config_manager.set_model(model, provider: provider)
        when "defaultThinkingLevel"
          @config_manager.set_reasoning_effort(value, provider: @session_manager.current_model[:provider])
        else
          raise ArgumentError, "Unsupported runtime setting: #{setting_id}"
        end
        @session_manager.refresh_client_config
        { applied: "live", message: runtime_setting_message(setting_id) }
      end

      def runtime_reload(params)
        @session_manager.runtime_state(session_id: params.fetch("sessionId"))
        @session_manager.refresh_client_config
        { ok: true, message: "Resources reloaded." }
      end

      def logging_stats(params)
        TelemetryStats.new.collect(params["range"].to_s).to_h
      rescue ArgumentError => e
        raise ArgumentError, e.message == TelemetryStats::USAGE ? e.message : "#{e.message} #{TelemetryStats::USAGE}"
      end

      def logging_token_csv(params)
        { csv: TelemetryStats.new.token_usage_csv(params["range"].to_s, bucket: params["bucket"]) }
      rescue ArgumentError => e
        raise ArgumentError, e.message == TelemetryStats::USAGE ? e.message : "#{e.message} #{TelemetryStats::USAGE}"
      end

      def commands_list(params)
        @session_manager.runtime_state(session_id: params.fetch("sessionId"))
        prompts = ConfigFiles.prompt_templates(reserved_commands: BUILTIN_SLASH_COMMAND_NAMES).map do |template|
          {
            name: template.command,
            description: template.description,
            source: "prompt",
            location: template.path,
            path: template.path,
            sourceInfo: {}
          }
        end
        skills = ConfigFiles.skills.map do |skill|
          {
            name: "skill:#{skill.name}",
            description: skill.description,
            source: "skill",
            path: skill.path
          }
        end
        builtins = [
          {
            name: "crew",
            description: "Query all active personas and summarize the crew.",
            argumentHint: "",
            source: "builtin",
            executable: true
          },
          {
            name: "copy",
            description: "CLI-only clipboard copy; RPC clients own their clipboard.",
            argumentHint: "[last|transcript]",
            source: "builtin",
            executable: false,
            unsupported: true,
            reason: "clientClipboardOwnedByUi"
          }
        ]
        plugins = @session_manager.plugin_commands.map do |command|
          {
            name: command.name,
            description: command.description,
            argumentHint: command.argument_hint,
            source: "plugin",
            path: command.path,
            executable: true
          }
        end
        { commands: builtins + prompts + skills + plugins }
      end

      def commands_run(params)
        @session_manager.run_command(
          session_id: params.fetch("sessionId"),
          command: params.fetch("name"),
          arguments: params["arguments"] || ""
        )
      end

      def startup_resources(params)
        @session_manager.runtime_state(session_id: params.fetch("sessionId"))
        sections = []
        agents_path = File.join(ConfigFiles.config_dir, "AGENTS.md")
        sections << { name: "Context", items: ["AGENTS.md"] } if File.exist?(agents_path)
        skills = ConfigFiles.skills.map(&:name)
        prompts = ConfigFiles.prompt_templates(reserved_commands: BUILTIN_SLASH_COMMAND_NAMES).map { |template| "/#{template.command}" }
        plugins = @session_manager.plugin_commands.map { |command| "/#{command.name}" }
        sections << { name: "Skills", items: skills } unless skills.empty?
        sections << { name: "Prompts", items: prompts } unless prompts.empty?
        sections << { name: "Plugins", items: plugins } unless plugins.empty?
        { sections: sections }
      end

      def auth_login_with_api_key(params)
        result = @auth_manager.login_with_api_key(provider_id: params.fetch("providerId"), api_key: params.fetch("apiKey"))
        @session_manager.refresh_client_config
        result
      end

      def auth_logout_provider(params)
        result = @auth_manager.logout_provider(provider_id: params.fetch("providerId"))
        @session_manager.refresh_client_config
        result
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
        provider = params["provider"] || @session_manager.current_model[:provider]
        @config_manager.set_reasoning_effort(params.fetch("effort"), provider: provider)
        @session_manager.refresh_client_config
        @session_manager.current_model
      end

      def provider_model_from(value)
        text = value.to_s.strip
        raise ArgumentError, "Model must be a non-empty string" if text.empty?

        provider, model = text.split("/", 2)
        if model.to_s.empty?
          [@session_manager.current_model[:provider], text]
        else
          [provider, model]
        end
      end

      def runtime_setting_message(setting_id)
        case setting_id
        when "defaultModel"
          "Model updated for this session."
        when "defaultThinkingLevel"
          "Thinking level updated for this session."
        end
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
