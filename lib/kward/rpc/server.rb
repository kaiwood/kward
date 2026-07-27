require "json"
require_relative "../model/client"
require_relative "../config_files"
require_relative "../memory/manager"
require_relative "../plugin_registry"
require_relative "../transport"
require_relative "../prompts/commands"
require_relative "../tools/registry"
require_relative "../workspace_factory"
require_relative "../telemetry/logger"
require_relative "../telemetry/stats"
require_relative "auth_manager"
require_relative "config_manager"
require_relative "mcp_status"
require_relative "redactor"
require_relative "session_manager"
require_relative "plugin_chat_manager"
require_relative "transport"
require_relative "../transport/plugin_chat_gateway"

# Namespace for the Kward CLI agent runtime.
module Kward
  # JSON-RPC backend namespace used by UI clients.
  module RPC
    # JSON-RPC backend for trusted local UI clients.
    #
    # The server speaks LSP-style Content-Length framing over stdin/stdout,
    # exposes capabilities during `initialize`, redacts secrets in errors and
    # notifications, and coordinates auth, config, sessions, turns, tools,
    # memory, commands, and startup resources.
    #
    # `Server` should stay focused on protocol concerns: framing, JSON-RPC error
    # codes, method dispatch, capability reporting, and redaction at the wire
    # boundary. Delegate stateful product behavior to manager objects such as
    # `SessionManager`, `AuthManager`, and `ConfigManager`. When adding an RPC
    # feature, update dispatch, capabilities, docs, and tests together so clients
    # can trust `initialize` as the source of supported behavior.
    # @api public
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
      PROTOCOL_METHODS = ["initialize", "shutdown"].freeze
      WORKSPACE_METHODS = ["workspace/validate", "workspace/info"].freeze
      TOOL_METHODS = ["tools/list"].freeze
      MCP_METHODS = ["mcp/status"].freeze
      PROMPT_METHODS = ["prompts/list", "prompts/expand"].freeze
      SESSION_METHODS = [
        "sessions/create", "sessions/resume", "sessions/list", "sessions/rename",
        "sessions/clone", "sessions/compact", "sessions/forkMessages", "sessions/fork",
        "sessions/tree", "sessions/tree/setLabel", "sessions/tree/navigate",
        "sessions/export", "sessions/delete", "sessions/close", "sessions/transcript", "sessions/active"
      ].freeze
      TURN_METHODS = ["turns/start", "turns/cancel", "turns/status", "turns/events", "turns/list", "turns/listActive"].freeze
      PLUGIN_CHAT_METHODS = ["pluginChats/list", "pluginChats/open", "pluginChats/transcript", "pluginChats/subscribe", "pluginChats/unsubscribe", "pluginChats/turns/start", "pluginChats/turns/cancel", "pluginChats/turns/status", "pluginChats/turns/events", "pluginChats/turns/list", "pluginChats/turns/listActive"].freeze
      MODEL_METHODS = ["models/list", "models/current", "models/set", "reasoning/set", "models/refresh"].freeze
      RUNTIME_METHODS = ["runtime/state", "runtime/stats"].freeze
      RUNTIME_SETTING_METHODS = ["runtime/updateSetting", "runtime/reload"].freeze
      AUTH_METHODS = [
        "auth/status", "auth/providers", "auth/loginWithApiKey", "auth/logoutProvider",
        "auth/loginWithOAuth", "auth/startOpenAILogin", "auth/submitOpenAICode", "auth/loginStatus"
      ].freeze
      MEMORY_METHODS = [
        "memory/status", "memory/enable", "memory/disable", "memory/autoSummary/enable",
        "memory/autoSummary/disable", "memory/list", "memory/add", "memory/addCore",
        "memory/forget", "memory/promote", "memory/relax", "memory/inspect",
        "memory/why", "memory/summarize"
      ].freeze
      COMMAND_METHODS = ["commands/list", "commands/run"].freeze
      SKILL_CAPTURE_METHODS = ["skills/captureSessions", "skills/captureDraft", "skills/saveCapturedDraft"].freeze
      STARTUP_RESOURCE_METHODS = ["resources/startup"].freeze
      CONFIG_METHODS = ["config/read", "config/update"].freeze
      LOGGING_METHODS = ["logging/stats", "logging/tokenCsv"].freeze
      LIFECYCLE_HOOK_METHODS = ["hooks/logs"].freeze
      UI_METHODS = ["ui/answerQuestion"].freeze
      TOOL_APPROVAL_METHODS = ["tool/answerApproval"].freeze
      TRANSPORT_METHODS = ["transports/list", "transports/status"].freeze
      SESSION_EVENT_NOTIFICATION = "session/event"
      SESSION_UPDATED_NOTIFICATION = "session/updated"
      TURN_EVENT_NOTIFICATION = "turn/event"
      UI_QUESTION_NOTIFICATION = "ui/question"
      UI_FOOTER_NOTIFICATION = "ui/footer"
      TOOL_APPROVAL_NOTIFICATION = "tool/approvalRequested"
      HOOK_EVENT_NOTIFICATION = "hook/event"
      METHOD_GROUPS = {
        protocol: PROTOCOL_METHODS,
        workspace: WORKSPACE_METHODS,
        tools: TOOL_METHODS,
        mcp: MCP_METHODS,
        prompts: PROMPT_METHODS,
        sessions: SESSION_METHODS,
        turns: TURN_METHODS,
        plugin_chats: PLUGIN_CHAT_METHODS,
        models: MODEL_METHODS,
        runtime: RUNTIME_METHODS,
        runtime_settings: RUNTIME_SETTING_METHODS,
        auth: AUTH_METHODS,
        memory: MEMORY_METHODS,
        commands: COMMAND_METHODS,
        skill_capture: SKILL_CAPTURE_METHODS,
        startup_resources: STARTUP_RESOURCE_METHODS,
        config: CONFIG_METHODS,
        logging: LOGGING_METHODS,
        lifecycle_hooks: LIFECYCLE_HOOK_METHODS,
        ui: UI_METHODS,
        tool_approval: TOOL_APPROVAL_METHODS
      }.freeze
      RPC_METHODS = METHOD_GROUPS.values.flatten.freeze

      # Creates the RPC server and its stateful managers.
      #
      # @param input [IO] framed JSON-RPC input stream
      # @param output [IO] framed JSON-RPC output stream
      # @param error_output [IO, nil] redacted diagnostic stream
      # @param client [Client] model-provider client shared by sessions
      def initialize(input: $stdin, output: $stdout, error_output: $stderr, client: Client.new)
        @transport = Transport.new(input: input, output: output)
        @error_output = error_output
        @client = client
        @config_manager = ConfigManager.new
        @session_manager = SessionManager.new(server: self, client: client, config_manager: @config_manager)
        @plugin_chat_manager = PluginChatManager.new(
          server: self,
          client: client,
          plugin_registry_provider: -> { @session_manager.plugin_registry }
        )
        @transport_manager = Kward::Transport::Manager.new(
          registry: @session_manager.plugin_registry,
          gateway: lambda { |transport_id|
            Kward::Transport::Gateway.new(session_manager: @session_manager, transport_id: transport_id)
          },
          plugin_chat_gateway: lambda { |transport_id|
            Kward::Transport::PluginChatGateway.new(runtime: @plugin_chat_manager.runtime, transport_id: transport_id)
          },
          config_provider: ->(transport_id) { ConfigFiles.transport_config(transport_id) }
        )
        @auth_manager = AuthManager.new(server: self, config_manager: @config_manager)
        @shutdown = false
        @shutdown_complete = false
      end

      attr_reader :session_manager, :plugin_chat_manager

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
        shutdown
      end

      def shutdown
        return if @shutdown_complete

        @shutdown = true
        @transport_manager.shutdown
        @plugin_chat_manager.shutdown
        @session_manager.shutdown_sessions
        @shutdown_complete = true
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

      # Writes a redacted server diagnostic without exposing error payload data.
      #
      # @param error [Exception]
      # @return [void]
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
        when PROTOCOL_METHODS[0]
          initialize_result
        when PROTOCOL_METHODS[1]
          @shutdown = true
          { ok: true }
        when WORKSPACE_METHODS[0]
          { root: @session_manager.validate_workspace_root(params["workspaceRoot"] || Dir.pwd) }
        when WORKSPACE_METHODS[1]
          workspace_info(params["workspaceRoot"] || Dir.pwd)
        when TOOL_METHODS[0]
          @session_manager.tool_schemas(session_id: params["sessionId"])
        when MCP_METHODS[0]
          MCPStatus.new(config_manager: @config_manager).to_h
        when TRANSPORT_METHODS[0]
          { transports: @transport_manager.list }
        when TRANSPORT_METHODS[1]
          params["name"] ? @transport_manager.status(params["name"]) : { transports: @transport_manager.status }
        when PROMPT_METHODS[0]
          prompts_list
        when PROMPT_METHODS[1]
          prompts_expand(params)
        when MODEL_METHODS[0]
          models_list
        when MODEL_METHODS[1]
          models_current
        when MODEL_METHODS[2]
          models_set(params)
        when MODEL_METHODS[3]
          reasoning_set(params)
        when MODEL_METHODS[4]
          models_refresh(params)
        when RUNTIME_METHODS[0]
          @session_manager.runtime_state(session_id: params.fetch("sessionId"))
        when RUNTIME_METHODS[1]
          @session_manager.runtime_stats(session_id: params.fetch("sessionId"))
        when RUNTIME_SETTING_METHODS[0]
          runtime_update_setting(params)
        when RUNTIME_SETTING_METHODS[1]
          runtime_reload(params)
        when COMMAND_METHODS[0]
          commands_list(params)
        when COMMAND_METHODS[1]
          commands_run(params)
        when SKILL_CAPTURE_METHODS[0]
          { sessions: @session_manager.skill_capture_sessions }
        when SKILL_CAPTURE_METHODS[1]
          @session_manager.capture_skill(session_path: params.fetch("sessionPath"))
        when SKILL_CAPTURE_METHODS[2]
          @session_manager.save_captured_skill(content: params.fetch("content"), overwrite: params["overwrite"] == true)
        when STARTUP_RESOURCE_METHODS[0]
          startup_resources(params)
        when CONFIG_METHODS[0]
          { path: @config_manager.config_path, config: @config_manager.read(redacted: params.fetch("redacted", true)) }
        when CONFIG_METHODS[1]
          config_update(params)
        when LOGGING_METHODS[0]
          logging_stats(params)
        when LOGGING_METHODS[1]
          logging_token_csv(params)
        when LIFECYCLE_HOOK_METHODS[0]
          lifecycle_hook_logs(params)
        when MEMORY_METHODS[0]
          @session_manager.memory_status
        when MEMORY_METHODS[1]
          @session_manager.memory_enable
        when MEMORY_METHODS[2]
          @session_manager.memory_disable
        when MEMORY_METHODS[3]
          @session_manager.memory_auto_summary_enable
        when MEMORY_METHODS[4]
          @session_manager.memory_auto_summary_disable
        when MEMORY_METHODS[5]
          @session_manager.memory_list(include_inactive: params["includeInactive"] || false, workspace_root: params["workspaceRoot"] || Dir.pwd)
        when MEMORY_METHODS[6]
          @session_manager.memory_add(text: params.fetch("text"), scope: params["scope"], tags: params["tags"] || [])
        when MEMORY_METHODS[7]
          @session_manager.memory_add_core(text: params.fetch("text"), scope: params["scope"], tags: params["tags"] || [])
        when MEMORY_METHODS[8]
          @session_manager.memory_forget(id: params.fetch("id"))
        when MEMORY_METHODS[9]
          @session_manager.memory_promote(id: params.fetch("id"))
        when MEMORY_METHODS[10]
          @session_manager.memory_relax(id: params.fetch("id"), workspace_root: params["workspaceRoot"] || Dir.pwd)
        when MEMORY_METHODS[11]
          @session_manager.memory_inspect
        when MEMORY_METHODS[12]
          @session_manager.memory_why(session_id: params["sessionId"])
        when MEMORY_METHODS[13]
          @session_manager.memory_summarize(session_id: params.fetch("sessionId"))
        when AUTH_METHODS[0]
          @auth_manager.status
        when AUTH_METHODS[1]
          @auth_manager.providers
        when AUTH_METHODS[2]
          auth_login_with_api_key(params)
        when AUTH_METHODS[3]
          auth_logout_provider(params)
        when AUTH_METHODS[4]
          @auth_manager.login_with_oauth(provider_id: params.fetch("providerId"), timeout_seconds: params["timeoutSeconds"] || 120)
        when AUTH_METHODS[5]
          @auth_manager.start_openai_login(timeout_seconds: params["timeoutSeconds"] || 120)
        when AUTH_METHODS[6]
          @auth_manager.submit_openai_code(login_id: params.fetch("loginId"), code: params.fetch("code"))
        when AUTH_METHODS[7]
          @auth_manager.login_status(login_id: params.fetch("loginId"))
        when SESSION_METHODS[0]
          @session_manager.create_session(workspace_root: params["workspaceRoot"] || Dir.pwd, name: params["name"], resume_last: params["resumeLast"] != false)
        when SESSION_METHODS[1]
          @session_manager.resume_session(path: params.fetch("path"), workspace_root: params["workspaceRoot"])
        when SESSION_METHODS[2]
          { sessions: @session_manager.list_sessions(workspace_root: params["workspaceRoot"] || Dir.pwd, limit: params["limit"], current_session_path: params["currentSessionPath"]) }
        when SESSION_METHODS[3]
          @session_manager.rename_session(session_id: params.fetch("sessionId"), name: params["name"])
        when SESSION_METHODS[4]
          @session_manager.clone_session(session_id: params.fetch("sessionId"))
        when SESSION_METHODS[5]
          @session_manager.compact_session(session_id: params.fetch("sessionId"), custom_instructions: params["customInstructions"] || "")
        when SESSION_METHODS[6]
          @session_manager.fork_messages(session_id: params.fetch("sessionId"))
        when SESSION_METHODS[7]
          @session_manager.fork_session(session_id: params.fetch("sessionId"), entry_id: params.fetch("entryId"))
        when SESSION_METHODS[8]
          @session_manager.session_tree(session_id: params.fetch("sessionId"))
        when SESSION_METHODS[9]
          @session_manager.set_tree_label(session_id: params.fetch("sessionId"), entry_id: params.fetch("entryId"), label: params["label"])
        when SESSION_METHODS[10]
          @session_manager.navigate_tree(session_id: params.fetch("sessionId"), entry_id: params.fetch("entryId"), summarize: params["summarize"], custom_instructions: params["customInstructions"])
        when SESSION_METHODS[11]
          @session_manager.export_session(session_id: params.fetch("sessionId"), path: params["path"], format: params["format"])
        when SESSION_METHODS[12]
          @session_manager.delete_session(session_id: params.fetch("sessionId"))
        when SESSION_METHODS[13]
          @session_manager.close_session(session_id: params.fetch("sessionId"))
        when SESSION_METHODS[14]
          @session_manager.transcript(session_id: params.fetch("sessionId"))
        when SESSION_METHODS[15]
          @session_manager.active_sessions
        when TURN_METHODS[0]
          @session_manager.start_turn(
            session_id: params.fetch("sessionId"),
            input: params.fetch("input"),
            streaming_behavior: params["streamingBehavior"],
            attachments: params["attachments"] || [],
            options: params["options"] || {},
            context: params["context"]
          )
        when TURN_METHODS[1]
          @session_manager.cancel_turn(turn_id: params.fetch("turnId"))
        when TURN_METHODS[2]
          @session_manager.turn_status(turn_id: params.fetch("turnId"))
        when TURN_METHODS[3]
          @session_manager.turn_events(turn_id: params.fetch("turnId"), after_sequence: params["afterSequence"] || 0)
        when TURN_METHODS[4]
          @session_manager.list_turns(session_id: params["sessionId"])
        when TURN_METHODS[5]
          @session_manager.list_turns(session_id: params["sessionId"], active: true)
        when PLUGIN_CHAT_METHODS[0]
          @plugin_chat_manager.list
        when PLUGIN_CHAT_METHODS[1]
          @plugin_chat_manager.open(type_id: params.fetch("typeId"))
        when PLUGIN_CHAT_METHODS[2]
          @plugin_chat_manager.transcript(chat_id: params.fetch("chatId"), limit: params["limit"], before: params["before"])
        when PLUGIN_CHAT_METHODS[3]
          @plugin_chat_manager.subscribe(chat_id: params.fetch("chatId"))
        when PLUGIN_CHAT_METHODS[4]
          @plugin_chat_manager.unsubscribe(chat_id: params.fetch("chatId"))
        when PLUGIN_CHAT_METHODS[5]
          @plugin_chat_manager.start_turn(chat_id: params.fetch("chatId"), input: params.fetch("input"), attachments: params["attachments"] || [])
        when PLUGIN_CHAT_METHODS[6]
          @plugin_chat_manager.cancel_turn(turn_id: params.fetch("turnId"))
        when PLUGIN_CHAT_METHODS[7]
          @plugin_chat_manager.turn_status(turn_id: params.fetch("turnId"))
        when PLUGIN_CHAT_METHODS[8]
          @plugin_chat_manager.turn_events(turn_id: params.fetch("turnId"), after_sequence: params["afterSequence"] || 0)
        when PLUGIN_CHAT_METHODS[9]
          @plugin_chat_manager.list_turns(chat_id: params["chatId"])
        when PLUGIN_CHAT_METHODS[10]
          @plugin_chat_manager.list_turns(chat_id: params["chatId"], active: true)
        when UI_METHODS[0]
          @session_manager.answer_question(session_id: params.fetch("sessionId"), question_request_id: params.fetch("questionRequestId"), answers: params.fetch("answers"))
        when TOOL_APPROVAL_METHODS[0]
          @session_manager.answer_tool_approval(session_id: params.fetch("sessionId"), approval_request_id: params.fetch("approvalRequestId"), approved: params.fetch("approved"))
        else
          raise NoMethodError, method
        end
      end

      def initialize_result
        {
          protocolVersion: PROTOCOL_VERSION,
          serverName: "kward",
          experimental: false,
          capabilities: capabilities
        }
      end

      def capabilities
        {
          framing: "content-length",
          transcript: {
            format: "kward-transcript-v1",
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
            methods: SESSION_METHODS,
            startupResume: { supported: true, method: SESSION_METHODS[0], parameter: "resumeLast", default: session_auto_resume_enabled?, immediateTranscript: true, sessionActivePersonaLabel: true },
            list: { supported: true, source: "rpc", ancestry: true, treeFields: true },
            active: { supported: true, method: SESSION_METHODS[15] },
            fork: { supported: true, methods: SESSION_METHODS.values_at(6, 7), entryIdFormat: "entry-id", selectedMessage: "excludedFromForkComposerTextReturned" },
            compact: { supported: true, method: SESSION_METHODS[5], notification: SESSION_EVENT_NOTIFICATION, events: ["compactionStart", "compactionEnd"] },
            import: { supported: false },
            tree: { supported: true, method: SESSION_METHODS[8], labels: true, labelTimestamps: true, navigate: true, summarize: true, shape: "kward-tree-items-v1" },
            updates: { supported: false, notification: SESSION_UPDATED_NOTIFICATION },
            worktrees: { supported: false, reason: "interactiveTuiOnly" }
          },
          transports: {
            supported: true,
            methods: TRANSPORT_METHODS,
            startMode: "cliOnly",
            entries: @transport_manager.list
          },
          pluginChats: {
            supported: @plugin_chat_manager.supported_types.any?,
            methods: PLUGIN_CHAT_METHODS,
            notification: "pluginChat/event",
            subscriptions: { supported: true, methods: PLUGIN_CHAT_METHODS.values_at(3, 4), requiredForLiveEvents: true },
            attachments: { supported: true, method: PLUGIN_CHAT_METHODS[5], encoding: "base64", mimeTypes: SessionManager::RPC_IMAGE_MIME_TYPES, maxBytes: SessionManager::RPC_ATTACHMENT_MAX_BYTES },
            types: @plugin_chat_manager.supported_types.map { |type| { id: type.id, name: type.name, title: type.title, singleton: type.singleton, transport: type.transport == true ? true : nil }.compact }
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
            eventReplay: { behavior: "recent-in-memory", persisted: false, limit: SessionManager::RECENT_EVENT_LIMIT },
            options: {
              supported: true,
              method: TURN_METHODS[0],
              fields: ["provider", "model", "reasoningEffort", "allowedTools", "disabledTools", "approvalMode"],
              perTurnModel: true,
              perTurnReasoning: true,
              perTurnToolScope: true
            },
            list: { supported: true, method: TURN_METHODS[4], activeMethod: TURN_METHODS[5] },
            context: {
              supported: true,
              method: TURN_METHODS[0],
              fields: ["activeFile", "openFiles", "selection", "diagnostics"]
            }
          },
          events: {
            notification: TURN_EVENT_NOTIFICATION,
            assistantText: "assistantDelta",
            reasoning: { start: false, delta: true, boundary: true, end: false },
            modelRetry: { supported: true, event: "modelRetry" },
            steering: { supported: @session_manager.in_flight_steer_supported?, event: "turnSteered", mode: @session_manager.in_flight_steer_supported? ? "native" : "unsupported" },
            tools: { call: true, update: true, result: true, normalizedMetadata: true, diffs: true, firstChangedLine: true, changedFiles: true, workspaceGuardrails: workspace_guardrails_enabled?, focusedContext: true, contextBudgetStats: true },
            errors: true,
            sessionUpdates: false
          },
          attachments: {
            input: {
              supported: true,
              method: TURN_METHODS[0],
              encoding: "base64",
              mimeTypes: SessionManager::RPC_IMAGE_MIME_TYPES,
              maxBytes: SessionManager::RPC_ATTACHMENT_MAX_BYTES
            }
          },
          models: {
            supported: true,
            methods: MODEL_METHODS,
            fields: ["provider", "id", "name", "reasoning", "reasoningEffort", "contextWindow"],
            scopedModels: false,
            refresh: { supported: true, method: MODEL_METHODS[4], providerParameter: true }
          },
          runtime: {
            supported: true,
            methods: RUNTIME_METHODS,
            state: { supported: true },
            stats: { messageCounts: true, tokens: false, cost: false, contextUsage: true, contextUsageEstimated: true }
          },
          lifecycleHooks: {
            supported: true,
            events: Hooks::Catalog.event_names,
            decisions: Hooks::Decision::VALID_DECISIONS,
            approvals: { supported: true, via: "toolApproval", requestNotification: TOOL_APPROVAL_NOTIFICATION, answerMethod: TOOL_APPROVAL_METHODS.first },
            notifications: [HOOK_EVENT_NOTIFICATION, "hook/message"],
            methods: LIFECYCLE_HOOK_METHODS,
            auditLog: { supported: true, path: File.join(ConfigFiles.config_dir, "logs", "hooks.jsonl") },
            commandHooks: true,
            pluginHooks: true,
            workspaceHooks: { supported: true, trustRequired: true, trustCommand: "/hooks trust" },
            httpHooks: { supported: true, protocol: "jsonPost" },
            asyncHooks: { supported: true, semantics: "observeOnly" }
          },
          runtimeSettings: {
            supported: true,
            methods: RUNTIME_SETTING_METHODS,
            settings: ["defaultModel", "defaultThinkingLevel"]
          },
          auth: {
            supported: true,
            providerFormat: "kward-auth-v2",
            methods: AUTH_METHODS,
            providerCatalog: true,
            authenticationMethods: ["api_key", "oauth"],
            oauthProviders: ["openai", "anthropic"],
            unsupportedOAuthProviders: {
              copilot: "OAuth login is available only in the interactive CLI.",
              openrouter: "Official PKCE is documented, but Kward has not implemented it.",
              xai: "No official stable third-party OAuth flow is available."
            },
            apiKeyProviders: ProviderCatalog.api_key_providers.map(&:id),
            privateCredentialStorage: true,
            sanitizedStatus: true,
            logout: true
          },
          memory: { supported: true, optIn: true, defaultEnabled: false, autoSummaryDefaultEnabled: false, promptInjection: "interactive", storage: { core: "json", soft: "jsonl", events: "jsonl" }, methods: MEMORY_METHODS },
          stability: { protocol: "stable", compatibility: "additive-fields-unless-protocol-version-changes", experimentalCapabilities: [] },
          commands: { supported: true, methods: COMMAND_METHODS, method: COMMAND_METHODS[0], runMethod: COMMAND_METHODS[1], sources: ["builtin", "prompt", "skill", "plugin"], executableSources: ["builtin", "plugin"] },
          skillCapture: { supported: true, methods: SKILL_CAPTURE_METHODS, destination: "personal", source: "savedSessionActiveLeaf", reviewRequired: true, overwrite: "explicit", autoActivate: false },
          projectSkillTrust: { supported: false, trustRequired: true, reason: "RPC has no interactive trust decision bridge; project skills remain skipped unless globally enabled." },
          mcp: {
            supported: true,
            transport: "stdio",
            config: "mcpServers",
            exposes: ["tools"],
            discovery: {
              supported: true,
              methods: TOOL_METHODS + MCP_METHODS,
              toolMetadata: true,
              serverStatus: true
            },
            unsupported: ["resources", "prompts", "sampling", "streamableHttp"]
          },
          startupResources: { supported: true, method: STARTUP_RESOURCE_METHODS.first },
          starterPack: { supported: false, reason: "cliOnlyInstallCommand" },
          shell: { supported: false, reason: "interactiveTuiOnly" },
          scratchpad: { supported: false, reason: "interactiveTuiOnly" },
          extensionUi: {
            question: { supported: true, notification: UI_QUESTION_NOTIFICATION, method: UI_METHODS.first, maxQuestions: 4, multiSelect: false, preview: false },
            select: false,
            confirm: false,
            input: false,
            editor: false,
            widgets: false,
            footer: { supported: true, notification: UI_FOOTER_NOTIFICATION },
            custom: false,
            terminalInput: false
          },
          composer: {
            sessionDiff: { supported: false, reason: "interactiveComposerOnly" },
            copy: { supported: false, reason: "clientClipboardOwnedByUi" }
          },
          security: {
            workspaceMutationGuard: "none",
            toolApproval: { supported: true, defaultMode: "none", modes: ["none", "ask"], requestNotification: TOOL_APPROVAL_NOTIFICATION, answerMethod: TOOL_APPROVAL_METHODS.first },
            canRunShell: true,
            canWriteFiles: true,
            sandbox: sandbox_capabilities
          },
          export: { supported: true, formats: ["markdown", "html"], defaultFormat: "markdown" },
          logging: {
            supported: true,
            defaultEnabled: false,
            methods: LOGGING_METHODS,
            stats: { supported: true, method: LOGGING_METHODS[0], defaultRange: TelemetryStats::DEFAULT_RANGE, units: %w[minutes hours days weeks months years] },
            usageCsv: { supported: true, method: LOGGING_METHODS[1], defaultRange: TelemetryStats::DEFAULT_RANGE, buckets: %w[second minute hour day week month year] },
            config: "logging",
            envPrefix: "KWARD_LOGGING",
            directory: File.join(ConfigFiles.config_dir, "logs"),
            format: "jsonl",
            categories: ["tokens", "performance", "tools", "errors"],
            rotation: { maxBytes: TelemetryLogger::DEFAULT_MAX_BYTES, retention: "manual" },
            content: "redacted-metadata-only"
          }
        }
      end

      def sandbox_capabilities
        config = @config_manager.read(redacted: false)
        policy = ConfigFiles.sandbox_policy(Dir.pwd, config)
        runner = Sandbox::RunnerFactory.build(policy)
        runner.capabilities.to_h.merge(
          mode: policy.mode,
          network: policy.network,
          scope: "shellCommandsOnly",
          sessionPinning: false,
          oneTimeElevation: false
        )
      rescue ArgumentError => error
        {
          available: false,
          filesystemEnforced: false,
          childNetworkEnforced: false,
          backend: "invalidConfiguration",
          reason: error.message,
          scope: "shellCommandsOnly",
          sessionPinning: false,
          oneTimeElevation: false
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

      def config_update(params)
        config = @config_manager.update(params.fetch("values"))
        @session_manager.refresh_client_config
        { path: @config_manager.config_path, config: config }
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
        @session_manager.reload_plugins
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

      def lifecycle_hook_logs(params)
        limit = params.fetch("limit", 20).to_i
        limit = 20 unless limit.positive?
        limit = 200 if limit > 200
        path = File.join(ConfigFiles.config_dir, "logs", "hooks.jsonl")
        return { path: path, records: [] } unless File.file?(path)

        records = File.readlines(path, chomp: true).last(limit).filter_map do |line|
          JSON.parse(line)
        rescue JSON::ParserError
          nil
        end
        { path: path, records: records }
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
        context_items = []
        if File.exist?(ConfigFiles.config_principles_path)
          context_items << "PRINCIPLES.md"
        elsif File.exist?(ConfigFiles.config_agents_path)
          context_items << "AGENTS.md"
        end
        sections << { name: "Context", items: context_items } unless context_items.empty?
        skills = ConfigFiles.skills.map(&:name)
        prompts = ConfigFiles.prompt_templates(reserved_commands: BUILTIN_SLASH_COMMAND_NAMES).map { |template| "/#{template.command}" }
        plugins = @session_manager.plugin_commands.map { |command| "/#{command.name}" }
        sections << { name: "Skills", items: skills } unless skills.empty?
        sections << { name: "Prompts", items: prompts } unless prompts.empty?
        sections << { name: "Plugins", items: plugins } unless plugins.empty?
        { sections: sections }
      end

      def auth_login_with_api_key(params)
        result = @auth_manager.login_with_api_key(provider_id: params.fetch("providerId"), api_key: params.fetch("apiKey"), configuration: params["configuration"])
        @session_manager.refresh_client_config
        result
      end

      def auth_logout_provider(params)
        result = @auth_manager.logout_provider(provider_id: params.fetch("providerId"), auth_method: params["authMethod"])
        @session_manager.refresh_client_config
        result
      end

      def models_refresh(params)
        { models: @session_manager.refresh_models(provider: params["provider"]) }
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
        if value.is_a?(Hash)
          provider = value["provider"] || value[:provider] || @session_manager.current_model[:provider]
          model = value["model"] || value[:model] || value["id"] || value[:id]
          model = model.to_s.strip
          raise ArgumentError, "Model must be a non-empty string" if model.empty?

          return [provider, model]
        end

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

      def configured_workspace(root = Dir.pwd)
        WorkspaceFactory.build(root: root, guardrails: workspace_guardrails_enabled?, config: @config_manager.read(redacted: false))
      end

      def workspace_guardrails_enabled?
        @config_manager.workspace_guardrails_enabled?
      end

      def session_auto_resume_enabled?
        @config_manager.session_auto_resume_enabled?
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
