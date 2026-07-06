require "securerandom"
require "thread"
require "time"
require_relative "../agent"
require_relative "../cancellation"
require_relative "../model/client"
require_relative "../compactor"
require_relative "../config_files"
require_relative "../model/context_usage"
require_relative "../conversation"
require_relative "../events"
require_relative "../export_path"
require_relative "../memory/manager"
require_relative "../message_access"
require_relative "../message_text"
require_relative "../session_tree_tool_display"
require_relative "../model/model_info"
require_relative "../plugin_registry"
require_relative "../prompts/commands"
require_relative "../session_store"
require_relative "../session_naming"
require_relative "../session_trash"
require_relative "../steering"
require_relative "../tools/tool_call"
require_relative "../tools/registry"
require_relative "../transcript_export"
require_relative "../workspace"
require_relative "attachment_normalizer"
require_relative "config_manager"
require_relative "memory_methods"
require_relative "prompt_bridge"
require_relative "runtime_payloads"
require_relative "session_metrics"
require_relative "session_tree"
require_relative "session_tree_rows"
require_relative "tool_event_normalizer"
require_relative "transcript_normalizer"

# Namespace for the Kward CLI agent runtime.
module Kward
  # JSON-RPC backend namespace used by UI clients.
  module RPC
    # Owns RPC-visible session lifecycle, async turn queues, and frontend events.
    #
    # `Server` handles JSON-RPC framing/dispatch; `SessionManager` handles the
    # product state behind those methods. It creates/resumes `SessionStore`
    # sessions, builds agents with RPC prompt bridges, serializes turn events for
    # clients, coordinates cancellation and follow-up queues, and integrates
    # memory/plugin hooks for RPC sessions.
    #
    # Keep JSON-RPC wire shape normalization in the `RPC::*Normalizer` classes,
    # persistence in `SessionStore`, and model/tool behavior in `Agent` and
    # `ToolRegistry`. This class should coordinate those pieces rather than own
    # their low-level mechanics.
    class SessionManager
      include MemoryMethods

      RECENT_EVENT_LIMIT = 1_000
      RPC_ATTACHMENT_MAX_BYTES = AttachmentNormalizer::MAX_BYTES
      RPC_IMAGE_MIME_TYPES = AttachmentNormalizer::IMAGE_MIME_TYPES
      STREAMING_BEHAVIORS = ["newTurn", "followUp", "steer"].freeze
      FOOTER_REFRESH_INTERVAL = 1.0
      WORKER_STOP = Object.new.freeze

      RpcSession = Struct.new(:id, :workspace_root, :store, :session, :conversation, :agent, :tool_registry, :prompt, :plugin_output, :queue, :worker, :running_turn_id, :footer_worker, :last_footer_text, keyword_init: true)
      Turn = Struct.new(:id, :session_id, :input, :display_input, :status, :cancel_requested, :cancellation, :created_at, :started_at, :finished_at, :events, :next_sequence, :error, :streaming_behavior, :plugin_command_name, :plugin_arguments, :steering, :options, :tool_registry, keyword_init: true)

      # Creates an object for RPC session lifecycle and turn coordination.
      def initialize(
        server:,
        client: Client.new,
        config_dir: ConfigFiles.config_dir,
        config_manager: ConfigManager.new(config_path: File.join(config_dir, "config.json")),
        context_usage: ContextUsage.new,
        session_trash: SessionTrash.new
      )
        @server = server
        @client = client
        @config_dir = config_dir
        @config_manager = config_manager
        @context_usage = context_usage
        @session_metrics = SessionMetrics.new(context_usage: context_usage)
        @session_trash = session_trash
        @sessions = {}
        @turns = {}
        @mutex = Mutex.new
      end

      # Creates a new RPC session or resumes the remembered session when allowed.
      #
      # Returns the normalized session payload expected by RPC clients. The RPC
      # session id is separate from the persisted session id so one persisted file
      # can be closed and reopened by different client connections.
      def create_session(workspace_root: Dir.pwd, name: nil, resume_last: false)
        workspace_root = validate_workspace_root(workspace_root)
        store = SessionStore.new(config_dir: @config_dir, cwd: workspace_root)
        if resume_last && session_auto_resume_enabled? && name.to_s.strip.empty?
          path = store.remembered_last_session_path
          return resume_session(path: path, workspace_root: workspace_root, include_transcript: true) if path
        end

        conversation = new_conversation(workspace_root: workspace_root)
        session = store.create(provider: conversation.provider, model: conversation.model, reasoning_effort: conversation.reasoning_effort)
        session.rename(name) unless name.to_s.strip.empty?
        session.attach(conversation)
        rpc_session = build_rpc_session(store, session, conversation, workspace_root)
        remember_session(rpc_session)
        cleanup_other_unused_sessions(rpc_session)
        emit_footer_update(rpc_session)
        session_payload(rpc_session)
      end

      def resume_session(path:, workspace_root: nil, include_transcript: false)
        root = validate_workspace_root(workspace_root || Dir.pwd)
        store = SessionStore.new(config_dir: @config_dir, cwd: root)
        location = store.session_location(path)
        root = validate_workspace_root(location[:cwd])
        store = SessionStore.new(config_dir: @config_dir, cwd: root)
        session, conversation = store.load(
          location[:path],
          workspace: configured_workspace(root),
          provider: current_model[:provider],
          model: current_model_id,
          reasoning_effort: current_reasoning_effort
        )
        rpc_session = build_rpc_session(store, session, conversation, root)
        remember_session(rpc_session)
        cleanup_other_unused_sessions(rpc_session)
        emit_footer_update(rpc_session)
        payload = session_payload(rpc_session)
        payload[:messages] = TranscriptNormalizer.new(rpc_session.conversation.messages).normalize if include_transcript
        payload[:resumed] = true
        payload
      end

      def list_sessions(workspace_root: Dir.pwd, limit: nil, current_session_path: nil)
        root = validate_workspace_root(workspace_root)
        store = SessionStore.new(config_dir: @config_dir, cwd: root)
        requested_limit = limit.to_i if limit
        requested_limit = nil unless requested_limit&.positive?
        store.recent(limit: requested_limit, keep_empty_path: current_session_path)
             .map { |info| session_info_payload(info, workspace_root: root) }
      end

      # Renames the persisted session attached to an RPC session id.
      def rename_session(session_id:, name:)
        rpc_session = fetch_session(session_id)
        rpc_session.session.rename(name)
        session_payload(rpc_session)
      end

      # Creates an independent copy of the current conversation branch.
      def clone_session(session_id:)
        source = fetch_session(session_id)
        session, conversation = source.store.create_independent_from_conversation(source.conversation, parent_session: source.session)
        rpc_session = build_rpc_session(source.store, session, conversation, source.workspace_root)
        remember_session(rpc_session)
        cleanup_other_unused_sessions(rpc_session)
        emit_footer_update(rpc_session)
        session_payload(rpc_session)
      end

      # Compacts an RPC session and emits start/end events for UI progress.
      def compact_session(session_id:, custom_instructions: "")
        rpc_session = fetch_session(session_id)
        emit_session_event(rpc_session, "compactionStart", {})
        result = Compactor.new(conversation: rpc_session.conversation, client: @client, settings: compaction_settings).compact(custom_instructions: custom_instructions)
        payload = {
          summary: result.summary,
          firstKeptEntryId: result.first_kept_entry_id,
          tokensBefore: result.tokens_before,
          details: result.details
        }.compact
        emit_session_event(rpc_session, "compactionEnd", { result: payload, aborted: false, willRetry: false, errorMessage: nil })
        payload
      rescue StandardError => e
        emit_session_event(rpc_session, "compactionEnd", { result: nil, aborted: true, willRetry: false, errorMessage: e.message }) if rpc_session
        raise e
      end

      # Lists user-message entries that can be used as fork points.
      def fork_messages(session_id:)
        rpc_session = fetch_session(session_id)
        {
          messages: session_tree_helper(rpc_session).entries.filter_map do |record|
            message = record["message"]
            next unless message.is_a?(Hash) && message_role(message) == "user"

            { entryId: record["id"], text: display_message_text(message) }
          end
        }
      end

      # Creates a new session from history before the selected user message.
      def fork_session(session_id:, entry_id:)
        source = fetch_session(session_id)
        tree = session_tree_helper(source)
        entries = tree.entries
        resolved_entry_id = tree.resolve_entry_id(entry_id, entries: entries)
        selected_index = entries.index { |record| record["id"].to_s == resolved_entry_id.to_s }
        selected = selected_index && entries[selected_index]
        raise ArgumentError, "Unknown fork entryId: #{entry_id}" unless selected

        message = selected["message"]
        raise ArgumentError, "Entry is not forkable: #{entry_id}" unless message.is_a?(Hash) && message_role(message) == "user"

        session, conversation = source.store.create_independent_from_messages(
          entries[0...selected_index].filter_map { |record| record["message"] },
          provider: source.conversation.provider,
          model: source.conversation.model,
          reasoning_effort: source.conversation.reasoning_effort,
          parent_session: source.session
        )

        rpc_session = build_rpc_session(source.store, session, conversation, source.workspace_root)
        remember_session(rpc_session)
        cleanup_other_unused_sessions(rpc_session)
        {
          session: session_payload(rpc_session),
          text: full_message_text(message),
          cancelled: false
        }
      end

      # Returns the flattened session tree rows consumed by RPC clients.
      def session_tree(session_id:)
        rpc_session = fetch_session(session_id)
        { items: flatten_session_tree(rpc_session) }
      end

      # Persists a label override for one tree entry.
      def set_tree_label(session_id:, entry_id:, label: nil)
        rpc_session = fetch_session(session_id)
        rpc_session.session.append_label_change(entry_id, label)
        { ok: true }
      end

      # Moves the active branch to a tree entry, optionally summarizing abandoned history.
      def navigate_tree(session_id:, entry_id:, summarize: false, custom_instructions: nil)
        rpc_session = fetch_session(session_id)
        tree = session_tree_helper(rpc_session)
        entries = tree.entries
        resolved_entry_id = tree.resolve_entry_id(entry_id, entries: entries)
        entry = rpc_session.store.session_entry(rpc_session.session.path, resolved_entry_id)
        raise ArgumentError, "Unknown tree entryId: #{entry_id}" unless entry

        raise ArgumentError, "Tree entry is not selectable: #{entry_id}" unless tree.selectable_entry?(entry)

        message = entry["message"]
        user_entry = tree.user_entry?(entry)
        target_leaf = user_entry ? entry["parentId"] : entry["id"]
        editor_text = user_entry ? full_message_text(message) : nil
        previous_leaf = rpc_session.session.leaf_id

        if summarize
          summary = summarize_branch(rpc_session, from_id: previous_leaf, to_id: target_leaf, custom_instructions: custom_instructions)
          target_leaf = rpc_session.session.append_branch_summary(target_leaf, from_id: previous_leaf, summary: summary, details: {})
        elsif target_leaf
          rpc_session.session.branch(target_leaf)
        end

        reload_rpc_session(rpc_session)
        {
          session: session_payload(rpc_session),
          editorText: editor_text,
          cancelled: false,
          aborted: false
        }.compact
      end

      # Exports the current transcript in markdown or JSON format.
      def export_session(session_id:, path: nil, format: nil)
        rpc_session = fetch_session(session_id)
        format = export_format(format)
        path = export_path(rpc_session, path, format)
        content = export_content(rpc_session.conversation, format)
        File.write(path, content)
        { path: path, format: format }
      end

      # Deletes the backing session file through the configured trash strategy.
      def delete_session(session_id:)
        rpc_session = fetch_session(session_id)
        path = rpc_session.session.path
        close_rpc_session(rpc_session, delete_unused: false)
        deleted = @session_trash.delete(path)
        { deleted: deleted, path: path }
      end

      # Stops workers and removes an RPC session from the live session map.
      def close_session(session_id:)
        rpc_session = fetch_session(session_id)
        close_rpc_session(rpc_session)
        { closed: true }
      end

      # Closes idle empty sessions left behind by UI lifecycle transitions.
      def cleanup_unused_sessions
        rpc_sessions = @mutex.synchronize { @sessions.values.dup }
        rpc_sessions.reverse_each do |rpc_session|
          next unless session_idle?(rpc_session)
          next unless rpc_session.session.respond_to?(:delete_if_unused)
          next unless rpc_session.session.delete_if_unused

          remove_live_session(rpc_session)
        end
        { closed: true }
      end

      # Stops all live RPC session workers during server shutdown.
      def shutdown_sessions
        rpc_sessions = @mutex.synchronize { @sessions.values.dup }
        rpc_sessions.reverse_each { |rpc_session| close_rpc_session(rpc_session) if session_idle?(rpc_session) }
        { closed: true }
      end

      # Returns the normalized transcript for the active RPC session.
      def transcript(session_id:)
        rpc_session = fetch_session(session_id)
        { session: session_payload(rpc_session), messages: TranscriptNormalizer.new(rpc_session.conversation.messages).normalize }
      end

      # Queues or starts an async model turn for an RPC session.
      #
      # `streaming_behavior` controls busy-session behavior: create a new turn,
      # queue a follow-up, or steer the running turn when the active provider
      # supports native steering. The returned turn id is used for status,
      # cancellation, and event replay.
      def start_turn(session_id:, input:, streaming_behavior: nil, attachments: [], options: {})
        rpc_session = fetch_session(session_id)
        normalized_options = normalize_turn_options(options)
        normalized_attachments = normalize_attachments(attachments)
        plugin_command, plugin_arguments = plugin_command_turn(input, normalized_attachments)
        display_input = input.to_s if input.is_a?(String)
        content = plugin_command ? input.to_s : user_turn_content(expand_prompt_input(input), normalized_attachments)
        streaming_behavior = validate_streaming_behavior(default_streaming_behavior(rpc_session, streaming_behavior), rpc_session: rpc_session)
        if streaming_behavior == "steer"
          return steer_running_turn(rpc_session, content)
        end
        turn = Turn.new(
          id: SecureRandom.uuid,
          session_id: rpc_session.id,
          input: content,
          display_input: display_input,
          status: "queued",
          cancel_requested: false,
          cancellation: Cancellation.new,
          created_at: now,
          events: [],
          next_sequence: 1,
          streaming_behavior: streaming_behavior,
          plugin_command_name: plugin_command&.name,
          plugin_arguments: plugin_arguments,
          options: normalized_options,
          tool_registry: scoped_tool_registry(rpc_session, normalized_options)
        )
        @mutex.synchronize { @turns[turn.id] = turn }
        rpc_session.queue << turn.id
        ensure_worker(rpc_session)
        emit_turn_event(turn, "turnQueued", { status: "queued" })
        turn_payload(turn)
      end

      def cancel_turn(turn_id:)
        turn = fetch_turn(turn_id)
        turn.cancel_requested = true
        turn.cancellation&.cancel!
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

      def run_command(session_id:, command:, arguments: "")
        name = command.to_s.delete_prefix("/")
        return { ok: false, error: "unsupported", reason: "clientClipboardOwnedByUi" } if name == "copy"

        run_plugin_command(session_id: session_id, command: name, arguments: arguments)
      end

      def run_plugin_command(session_id:, command:, arguments: "")
        rpc_session = fetch_session(session_id)
        command = plugin_registry.command_for(command.to_s.delete_prefix("/")) || raise(ArgumentError, "Unknown plugin command: #{command}")
        output = []
        context = plugin_context(rpc_session, args: arguments.to_s, say_callback: lambda { |message| output << message.to_s })
        result = command.handler.call(arguments.to_s, context)
        output = rpc_session.plugin_output.shift(rpc_session.plugin_output.length) + output
        { command: command.name, output: output, result: result.nil? ? nil : result.to_s }
      end

      def plugin_commands
        plugin_registry.commands
      end

      def available_models
        models = @client.respond_to?(:available_models) ? Array(@client.available_models) : []
        normalized = models.map { |model| normalize_model(model) }
        current = current_model
        normalized << current if normalized.none? { |model| model[:provider] == current[:provider] && model[:id] == current[:id] }
        normalized
      end

      def current_model
        provider = @client.respond_to?(:current_provider) ? @client.current_provider : nil
        model = @client.respond_to?(:current_model) ? @client.current_model : nil
        context_window = @client.respond_to?(:current_context_window) ? @client.current_context_window : nil
        normalize_model(provider: provider, id: model, model: model, contextWindow: context_window, current: true)
      end

      def session_model(rpc_session)
        current = current_model
        provider = rpc_session.conversation.provider || current[:provider]
        model = rpc_session.conversation.model || current[:id]
        reasoning_effort = rpc_session.conversation.reasoning_effort || current_reasoning_effort
        reasoning_effort = nil unless ModelInfo.reasoning_supported?(provider, model)
        context_window = context_window_for(provider, model)
        normalize_model(
          provider: provider,
          id: model,
          model: model,
          reasoningEffort: reasoning_effort,
          contextWindow: context_window,
          current: true
        )
      end

      def in_flight_steer_supported?
        supports_in_flight_steer?
      end

      def runtime_state(session_id:)
        rpc_session = fetch_session(session_id)
        model = session_model(rpc_session)
        compaction_settings = self.compaction_settings
        auto_compaction_reserve_tokens = compaction_reserve_tokens(
          context_window: model[:contextWindow],
          compaction_settings: compaction_settings
        )
        session = session_payload(rpc_session)
        RuntimePayloads.state(
          session: session,
          model: model,
          streaming: streaming?(rpc_session),
          steering_supported: supports_in_flight_steer?,
          auto_compaction_reserve_tokens: auto_compaction_reserve_tokens,
          active_persona_label: active_persona_label(rpc_session),
          message_count: @session_metrics.message_count(rpc_session.conversation),
          pending_count: pending_turn_count(rpc_session.id),
          compaction_enabled: compaction_settings.enabled,
          workspace_guardrails_enabled: workspace_guardrails_enabled?
        )
      end

      def runtime_stats(session_id:)
        rpc_session = fetch_session(session_id)
        session = session_payload(rpc_session)
        counts = @session_metrics.message_stats(rpc_session.conversation)
        model = session_model(rpc_session)
        compaction_settings = self.compaction_settings
        auto_compaction_reserve_tokens = compaction_reserve_tokens(
          context_window: model[:contextWindow],
          compaction_settings: compaction_settings
        )
        RuntimePayloads.stats(
          session: session,
          counts: counts,
          model: model,
          auto_compaction_reserve_tokens: auto_compaction_reserve_tokens,
          context_usage: @session_metrics.context_usage(rpc_session, model, client: @client),
          compaction_enabled: compaction_settings.enabled
        )
      end

      def refresh_client_config
        @client.reload_config if @client.respond_to?(:reload_config)
        refresh_session_runtime_contexts
        refresh_session_tool_registries
      end

      def reload_plugins
        registry = PluginRegistry.load(reserved_commands: reserved_plugin_command_names)
        sessions = @mutex.synchronize do
          @plugin_registry = registry
          @sessions.values
        end
        sessions.each do |rpc_session|
          rpc_session.conversation.plugin_registry = registry if rpc_session.conversation.respond_to?(:plugin_registry=)
          rpc_session.conversation.refresh_system_message! if rpc_session.conversation.respond_to?(:refresh_system_message!)
          if registry.footer_renderer
            start_footer_worker(rpc_session)
            emit_footer_update(rpc_session)
          else
            stop_footer_worker(rpc_session)
            clear_footer_update(rpc_session)
          end
        end
      end

      def session_payload(rpc_session)
        RuntimePayloads.session(
          rpc_session,
          modified_at: session_modified_at(rpc_session.session),
          active_persona_label: active_persona_label(rpc_session)
        )
      end

      def session_modified_at(session)
        File.exist?(session.path) ? File.mtime(session.path) : nil
      end

      def validate_workspace_root(root)
        expanded = File.expand_path(root.to_s.empty? ? Dir.pwd : root.to_s)
        raise "Workspace root is not an existing directory: #{expanded}" unless File.directory?(expanded)

        File.realpath(expanded)
      end

      private

      def new_conversation(workspace_root: Dir.pwd)
        Conversation.new(
          workspace_root: workspace_root,
          provider: (@client.current_provider if @client.respond_to?(:current_provider)),
          model: (@client.current_model if @client.respond_to?(:current_model)),
          reasoning_effort: (@client.current_reasoning_effort if @client.respond_to?(:current_reasoning_effort)),
          plugin_registry: plugin_registry
        )
      end

      def refresh_session_runtime_contexts
        provider = current_model[:provider]
        model = current_model_id
        reasoning_effort = current_reasoning_effort
        sessions = @mutex.synchronize { @sessions.values }
        sessions.each do |rpc_session|
          conversation = rpc_session.conversation
          runtime_changed = [conversation.provider, conversation.model, conversation.reasoning_effort] != [provider, model, reasoning_effort]
          conversation.update_runtime_context!(provider: provider, model: model, reasoning_effort: reasoning_effort)
          conversation.persist_runtime_context! if runtime_changed
        end
      end

      def refresh_session_tool_registries
        sessions = @mutex.synchronize { @sessions.values }
        sessions.each { |rpc_session| rebuild_session_tools(rpc_session) }
      end

      def rebuild_session_tools(rpc_session)
        tool_registry = build_tool_registry(rpc_session.workspace_root, rpc_session.prompt)
        rpc_session.tool_registry = tool_registry
        rpc_session.agent = Agent.new(
          client: @client,
          tool_registry: tool_registry,
          conversation: rpc_session.conversation
        )
      end

      def compaction_settings
        Kward::Compaction::Settings.from_config(ConfigFiles.read_config(config_path))
      rescue StandardError
        Kward::Compaction::Settings.new
      end

      def compaction_reserve_tokens(context_window:, compaction_settings:)
        return nil unless compaction_settings&.enabled
        return nil unless context_window

        Kward::Compactor.auto_compaction_reserve_tokens(
          context_window: context_window,
          configured_reserve_tokens: compaction_settings&.reserve_tokens
        )
      end

      def current_model_id
        @client.respond_to?(:current_model) ? @client.current_model : ModelInfo::DEFAULT_OPENAI_MODEL
      end

      def current_reasoning_effort
        @client.respond_to?(:current_reasoning_effort) ? @client.current_reasoning_effort : ModelInfo::DEFAULT_REASONING_EFFORT
      end

      def normalize_model(model)
        unless model.key?(:contextWindow) || model.key?("contextWindow")
          provider = model[:provider] || model["provider"]
          id = model[:id] || model["id"] || model[:model] || model["model"]
          model = model.merge(contextWindow: context_window_for(provider, id))
        end
        ModelInfo.normalize(
          model,
          current_provider: (@client.current_provider if @client.respond_to?(:current_provider)),
          current_model: (@client.current_model if @client.respond_to?(:current_model)),
          current_reasoning_effort: (@client.current_reasoning_effort if @client.respond_to?(:current_reasoning_effort))
        )
      end

      def context_window_for(provider, model)
        provider = ModelInfo.provider_label(provider)
        return @client.context_window(provider, model) if @client.respond_to?(:context_window) && @client.method(:context_window).arity != 0

        if @client.respond_to?(:current_context_window) && @client.respond_to?(:current_provider) && @client.respond_to?(:current_model)
          return @client.current_context_window if provider == @client.current_provider && model == @client.current_model
        end

        ModelInfo.context_window(provider, model)
      end

      def active_persona_label(rpc_session)
        ConfigFiles.active_persona_label(
          workspace_root: rpc_session.workspace_root,
          model: rpc_session.conversation.model
        ) || "Assistant"
      end

      def streaming?(rpc_session)
        turn_id = rpc_session.running_turn_id
        return false unless turn_id

        @mutex.synchronize { @turns[turn_id]&.status == "running" }
      end

      def pending_turn_count(session_id)
        @mutex.synchronize do
          @turns.values.count { |turn| turn.session_id == session_id && ["queued", "running"].include?(turn.status) }
        end
      end

      def session_idle?(rpc_session)
        pending_turn_count(rpc_session.id).zero?
      end

      def tool_calls(message)
        MessageAccess.tool_calls(message)
      end

      def message_role(message)
        MessageAccess.role(message)
      end

      def session_tree_helper(rpc_session)
        SessionTree.new(rpc_session)
      end

      def reload_rpc_session(rpc_session)
        session, conversation = rpc_session.store.load(
          rpc_session.session.path,
          workspace: configured_workspace(rpc_session.workspace_root),
          provider: current_model[:provider],
          model: current_model_id,
          reasoning_effort: current_reasoning_effort
        )
        conversation.plugin_registry ||= plugin_registry if conversation.respond_to?(:plugin_registry)
        rpc_session.session = session
        rpc_session.conversation = conversation
        rebuild_session_tools(rpc_session)
        emit_footer_update(rpc_session)
      end

      def flatten_session_tree(rpc_session)
        roots = rpc_session.store.session_tree(rpc_session.session.path)
        current_leaf = rpc_session.session.leaf_id || rpc_session.store.current_leaf(rpc_session.session.path)
        tree = session_tree_helper(rpc_session)
        SessionTreeRows.new(
          roots: roots,
          current_leaf: current_leaf,
          selectable: ->(entry) { tree.selectable_entry?(entry) }
        ).rows
      end

      def summarize_branch(rpc_session, from_id:, to_id:, custom_instructions: nil)
        tree = session_tree_helper(rpc_session)
        entries = tree.entries
        active = tree.active_path_ids(entries, from_id)
        target = tree.active_path_ids(entries, to_id)
        target_lookup = target.to_h { |id| [id, true] }
        abandoned = active.reject { |id| target_lookup[id] }
        messages = entries.select { |entry| abandoned.include?(entry["id"].to_s) }.filter_map { |entry| entry["message"] }
        source_text = messages.map { |message| "#{message_role(message)}: #{full_message_text(message)}" }.join("\n\n")
        prompt = [
          { role: "system", content: "Summarize the abandoned conversation branch concisely for future context." },
          { role: "user", content: [custom_instructions.to_s.strip, source_text].reject(&:empty?).join("\n\n") }
        ]
        response = @client.chat(prompt, tools: [])
        text = full_message_text(response)
        text.empty? ? "Branch summary unavailable." : text
      end

      def display_message_text(message)
        truncate_tree_text(full_message_text(message))
      end

      def truncate_tree_text(text)
        normalized = text.to_s.gsub(/\s+/, " ").strip
        normalized.length > 120 ? "#{normalized.slice(0, 117)}..." : normalized
      end

      def full_message_text(message)
        MessageText.full_text(message)
      end

      def supports_in_flight_steer?
        @client.respond_to?(:supports_in_flight_steer?) && @client.supports_in_flight_steer?
      end

      def default_streaming_behavior(rpc_session, streaming_behavior)
        behavior = streaming_behavior.to_s
        return behavior unless behavior.empty?
        return "steer" if supports_in_flight_steer? && streaming?(rpc_session)

        "newTurn"
      end

      def validate_streaming_behavior(streaming_behavior, rpc_session: nil)
        behavior = streaming_behavior.to_s.empty? ? "newTurn" : streaming_behavior.to_s
        raise ArgumentError, "Unsupported streamingBehavior: #{behavior}" unless STREAMING_BEHAVIORS.include?(behavior)
        raise ArgumentError, "Unsupported streamingBehavior: steer" if behavior == "steer" && !supports_in_flight_steer?
        raise ArgumentError, "Unsupported streamingBehavior: steer" if behavior == "steer" && (!rpc_session || !streaming?(rpc_session))

        behavior
      end

      def user_turn_content(input, attachments)
        return input.to_s if attachments.empty?

        [{ type: "text", text: input.to_s }] + attachments
      end

      def expand_prompt_input(input)
        return input unless input.is_a?(String)

        PromptCommands.expand(input) || input
      end

      def plugin_command_turn(input, attachments)
        return [nil, ""] unless input.is_a?(String)
        return [nil, ""] unless attachments.empty?

        command, arguments = PromptCommands.parse(input)
        return [nil, ""] unless command

        [plugin_registry.command_for(command), arguments]
      end

      def normalize_attachments(attachments)
        AttachmentNormalizer.new(max_bytes: RPC_ATTACHMENT_MAX_BYTES, mime_types: RPC_IMAGE_MIME_TYPES).normalize(attachments)
      end

      def normalize_turn_options(options)
        options = {} if options.nil?
        raise ArgumentError, "turn options must be an object" unless options.is_a?(Hash)

        provider = option_value(options, "provider")
        model = option_value(options, "model")
        model = option_value(model, "id") || option_value(model, "model") if model.is_a?(Hash)
        reasoning = option_value(options, "reasoningEffort") || option_value(options, "reasoning")
        allowed_tools = option_array(options, "allowedTools")
        disabled_tools = option_array(options, "disabledTools")
        raise ArgumentError, "allowedTools and disabledTools cannot both be set" if allowed_tools && disabled_tools

        {
          provider: blank_to_nil(provider),
          model: blank_to_nil(model),
          reasoning: blank_to_nil(reasoning),
          allowed_tools: allowed_tools,
          disabled_tools: disabled_tools
        }.compact
      end

      def option_value(hash, key)
        hash[key] || hash[key.to_sym]
      end

      def option_array(hash, key)
        value = option_value(hash, key)
        return nil if value.nil?
        raise ArgumentError, "#{key} must be an array" unless value.is_a?(Array)

        value.map(&:to_s).reject(&:empty?)
      end

      def blank_to_nil(value)
        value = value.to_s if value.is_a?(Symbol)
        value.to_s.empty? ? nil : value
      end

      def scoped_tool_registry(rpc_session, options)
        names = scoped_tool_names(rpc_session, options)
        return nil unless names

        build_tool_registry(rpc_session.workspace_root, rpc_session.prompt, allowed_tool_names: names)
      end

      def scoped_tool_names(rpc_session, options)
        return options[:allowed_tools] if options[:allowed_tools]
        return nil unless options[:disabled_tools]

        disabled = options[:disabled_tools].to_h { |name| [name, true] }
        rpc_session.tool_registry.schemas.filter_map do |schema|
          name = schema.dig(:function, :name) || schema.dig("function", "name")
          name unless disabled[name]
        end
      end

      def plugin_registry
        @plugin_registry ||= PluginRegistry.load(reserved_commands: reserved_plugin_command_names)
      end

      def reserved_plugin_command_names
        PromptCommands::BUILTIN_RESERVED_COMMAND_NAMES + ConfigFiles.prompt_templates(reserved_commands: PromptCommands::BUILTIN_RESERVED_COMMAND_NAMES).map(&:command)
      end

      # Wires together the per-RPC-session runtime objects.
      #
      # This is the RPC counterpart to the CLI interactive setup: attach plugin
      # context, create a prompt bridge for UI questions/footer output, advertise
      # tools with the workspace guardrail policy, and build the shared `Agent`.
      def build_rpc_session(store, session, conversation, workspace_root)
        conversation.plugin_registry ||= plugin_registry if conversation.respond_to?(:plugin_registry)
        id = SecureRandom.uuid
        prompt = PromptBridge.new(server: @server, session_id: id)
        tool_registry = build_tool_registry(workspace_root, prompt)
        agent = Agent.new(
          client: @client,
          tool_registry: tool_registry,
          conversation: conversation
        )
        RpcSession.new(
          id: id,
          workspace_root: workspace_root,
          store: store,
          session: session,
          conversation: conversation,
          agent: agent,
          tool_registry: tool_registry,
          prompt: prompt,
          plugin_output: [],
          queue: Queue.new,
          worker: nil,
          running_turn_id: nil
        )
      end

      def build_tool_registry(workspace_root, prompt, allowed_tool_names: nil)
        ToolRegistry.new(workspace: configured_workspace(workspace_root), prompt: prompt, allowed_tool_names: allowed_tool_names)
      end

      def configured_workspace(root)
        Workspace.new(root: root, guardrails: workspace_guardrails_enabled?)
      end

      def workspace_guardrails_enabled?
        @config_manager.workspace_guardrails_enabled?
      end

      def session_auto_resume_enabled?
        @config_manager.session_auto_resume_enabled?
      end

      def config_path
        File.join(@config_dir, "config.json")
      end

      def remember_session(rpc_session)
        @mutex.synchronize { @sessions[rpc_session.id] = rpc_session }
        rpc_session.store.remember_last_session(rpc_session.session) if rpc_session.store.respond_to?(:remember_last_session)
        start_footer_worker(rpc_session)
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

      def close_rpc_session(rpc_session, delete_unused: true)
        remove_live_session(rpc_session)
        rpc_session.session.delete_if_unused if delete_unused && rpc_session.session.respond_to?(:delete_if_unused)
      end

      def cleanup_other_unused_sessions(current_session)
        rpc_sessions = @mutex.synchronize { @sessions.values.dup }
        rpc_sessions.each do |rpc_session|
          next if rpc_session.id == current_session.id
          next if rpc_session.session.path == current_session.session.path
          next unless session_idle?(rpc_session)
          next unless rpc_session.session.respond_to?(:delete_if_unused)
          next unless rpc_session.session.delete_if_unused

          remove_live_session(rpc_session)
        end
      end

      def remove_live_session(rpc_session)
        @mutex.synchronize { @sessions.delete(rpc_session.id) }
        stop_worker(rpc_session)
        stop_footer_worker(rpc_session)
      end

      def stop_worker(rpc_session)
        worker = rpc_session.worker
        return unless worker&.alive?
        return if worker == Thread.current

        rpc_session.queue << WORKER_STOP
      end

      def start_footer_worker(rpc_session)
        return unless plugin_registry.footer_renderer
        return if rpc_session.footer_worker&.alive?

        rpc_session.footer_worker = Thread.new do
          loop do
            sleep FOOTER_REFRESH_INTERVAL
            break unless @mutex.synchronize { @sessions[rpc_session.id] == rpc_session }

            emit_footer_update(rpc_session)
          end
        rescue StandardError => e
          @server.log_error(e)
        ensure
          rpc_session.footer_worker = nil if rpc_session.footer_worker == Thread.current
        end
      end

      def stop_footer_worker(rpc_session)
        worker = rpc_session.footer_worker
        rpc_session.footer_worker = nil
        return unless worker&.alive?
        return if worker == Thread.current

        worker.kill
        worker.join(0.1)
      end

      def worker_loop(rpc_session)
        loop do
          turn_id = rpc_session.queue.pop
          break if turn_id.equal?(WORKER_STOP)

          begin
            turn = fetch_turn(turn_id)
            next if turn.status == "canceled"

            run_turn(rpc_session, turn)
          rescue StandardError => e
            @server.log_error(e)
          end
        end
      ensure
        rpc_session.worker = nil if rpc_session.worker == Thread.current
      end

      # Executes one queued turn and emits normalized RPC events.
      #
      # This method is intentionally the only place that calls `Agent#ask` for RPC
      # turns. Keep event translation near this boundary so CLI rendering and RPC
      # protocol details do not leak into `Agent`.
      def run_turn(rpc_session, turn)
        rpc_session.running_turn_id = turn.id
        turn.steering = build_steering(turn) if supports_in_flight_steer? && !turn.plugin_command_name
        turn.status = "running"
        turn.started_at = now
        emit_turn_event(turn, "turnStarted", { status: "running" })

        if turn.cancel_requested
          finish_turn(turn, "canceled")
          return
        end

        if turn.plugin_command_name
          run_plugin_turn(rpc_session, turn)
        else
          auto_name_session(rpc_session, turn.display_input || turn.input)
          prepare_memory_context(rpc_session.conversation, turn.input)
          rpc_session.agent.ask(turn.input, display_input: turn_display_input(turn), cancellation: turn.cancellation, steering: turn.steering, options: turn.options || {}, tool_registry: turn.tool_registry) do |event|
            next if turn.cancel_requested

            notify_plugin_transcript_event(rpc_session, event)
            handle_agent_event(turn, event)
          end
          persist_memory_state(rpc_session)
          finish_turn(turn, turn.cancel_requested ? "canceled" : "completed")
        end
      rescue Cancellation::CancelledError
        finish_turn(turn, "canceled")
      rescue StandardError => e
        turn.error = turn_error_payload(e)
        emit_turn_event(turn, "error", turn.error)
        finish_turn(turn, "failed")
      ensure
        turn.steering = nil
        rpc_session.running_turn_id = nil
      end

      def build_steering(_turn)
        Steering.new
      end

      def auto_name_session(rpc_session, input)
        return unless rpc_session.session.name.to_s.strip.empty?

        name = default_session_name(input)
        rpc_session.session.rename(name) unless name.empty?
      end

      def default_session_name(input)
        SessionNaming.default_name(input)
      end

      def turn_display_input(turn)
        return nil if turn.display_input.nil?
        return nil if turn.display_input == turn.input

        turn.display_input
      end

      def prepare_memory_context(conversation, input)
        manager = memory_manager
        retrieval = manager.retrieve_relevant(input: input, workspace_root: conversation.workspace_root)
        conversation.last_memory_retrieval = retrieval
        conversation.memory_context = manager.memory_block(retrieval)
        conversation.refresh_system_message!
      rescue StandardError => e
        @server.log_error(e)
        nil
      end

      def persist_memory_state(rpc_session)
        rpc_session.session.update_memory_state(session_memories: rpc_session.conversation.session_memories, last_retrieval: rpc_session.conversation.last_memory_retrieval)
      rescue StandardError
        nil
      end

      def steer_running_turn(rpc_session, input)
        turn_id = rpc_session.running_turn_id
        turn = turn_id && fetch_turn(turn_id)
        raise ArgumentError, "Unsupported streamingBehavior: steer" unless turn&.status == "running" && turn.steering

        turn.steering.submit(input)
        turn_payload(turn)
      end

      def plugin_context(rpc_session, args: nil, say_callback:)
        PluginRegistry::Context.new(
          conversation: rpc_session.conversation,
          args: args,
          session: rpc_session.session,
          workspace_root: rpc_session.workspace_root,
          say_callback: say_callback
        )
      end

      def run_plugin_turn(rpc_session, turn)
        turn.cancellation&.raise_if_cancelled!
        command = plugin_registry.command_for(turn.plugin_command_name) || raise(ArgumentError, "Unknown plugin command: #{turn.plugin_command_name}")
        output = []
        context = plugin_context(rpc_session, args: turn.plugin_arguments.to_s, say_callback: lambda { |message| output << message.to_s })
        result = command.handler.call(turn.plugin_arguments.to_s, context)
        answer = (output + [result]).compact.map(&:to_s).reject(&:empty?).join("\n")
        unless answer.empty?
          emit_turn_event(turn, "assistantDelta", { delta: answer })
          emit_turn_event(turn, "answer", { content: answer })
        end
        finish_turn(turn, turn.cancel_requested ? "canceled" : "completed")
      end

      def notify_plugin_transcript_event(rpc_session, event)
        return if plugin_registry.transcript_event_handlers.empty?

        context = plugin_context(rpc_session, say_callback: lambda { |message| rpc_session.plugin_output << message.to_s })
        plugin_registry.notify_transcript_event(event, context)
      end

      def handle_agent_event(turn, event)
        case event
        when Events::ReasoningDelta
          emit_turn_event(turn, "reasoningDelta", { delta: event.delta })
        when Events::AssistantDelta
          emit_turn_event(turn, "assistantDelta", { delta: event.delta })
        when Events::AssistantMessage
          emit_turn_event(turn, "assistantMessage", { message: event.message })
        when Events::Retry
          emit_turn_event(turn, "modelRetry", retry_event_payload(event))
        when Events::Steering
          emit_turn_event(turn, "turnSteered", { input: event.input, createdAt: event.created_at })
        when Events::SteeringApplied
          emit_turn_event(turn, "steeringApplied", { count: event.count })
        when Events::ToolCall
          emit_turn_event(turn, "toolCall", normalized_tool_event_payload(event.tool_call))
        when Events::ToolResult
          emit_turn_event(turn, "toolResult", normalized_tool_result_event_payload(event.tool_call, event.content))
        when Events::Answer
          emit_turn_event(turn, "answer", { content: event.content })
        end
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

      def finish_turn(turn, status)
        return if ["completed", "failed", "canceled"].include?(turn.status)

        turn.status = status
        turn.finished_at = now
        emit_turn_event(turn, "turnFinished", { status: status, error: turn.error })
        rpc_session = @mutex.synchronize { @sessions[turn.session_id] }
        emit_footer_update(rpc_session) if rpc_session
      end

      def emit_footer_update(rpc_session)
        renderer = plugin_registry.footer_renderer
        return clear_footer_update(rpc_session) unless renderer

        text = begin
          context = plugin_context(rpc_session, say_callback: lambda { |message| rpc_session.plugin_output << message.to_s })
          renderer.call(context).to_s.gsub(/\s+/, " ").strip
        rescue StandardError => e
          warn "Warning: Kward plugin footer error: #{e.message}"
          ""
        end
        return if rpc_session.last_footer_text == text

        rpc_session.last_footer_text = text
        @server.notify("ui/footer", { sessionId: rpc_session.id, text: text })
      end

      def clear_footer_update(rpc_session)
        return if rpc_session.last_footer_text.to_s.empty?

        rpc_session.last_footer_text = ""
        @server.notify("ui/footer", { sessionId: rpc_session.id, text: "" })
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

      def emit_session_event(rpc_session, type, payload)
        @server.notify("session/event", {
          timestamp: now,
          sessionId: rpc_session.id,
          type: type,
          payload: payload
        })
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

      def session_info_payload(info, workspace_root:)
        cwd = info.cwd.to_s.empty? ? workspace_root : info.cwd
        {
          id: info.id,
          path: File.expand_path(info.path),
          cwd: cwd,
          workspaceRoot: workspace_root,
          createdAt: info.created_at&.utc&.iso8601(3),
          modifiedAt: info.modified_at&.utc&.iso8601(3),
          name: info.name,
          firstMessage: info.first_message.to_s,
          messageCount: info.message_count.to_i,
          provider: info.provider,
          model: info.model,
          reasoningEffort: info.reasoning_effort,
          parentId: info.parent_id,
          parentPath: info.parent_path,
          depth: info.depth.to_i,
          isLast: info.is_last,
          ancestorContinues: Array(info.ancestor_continues)
        }
      end

      def export_path(rpc_session, path, format)
        extension = format == "html" ? ".html" : ".md"
        default_path = rpc_session.session.path.sub(/\.jsonl\z/, extension)
        ExportPath.resolve(path, workspace_root: rpc_session.workspace_root, default_path: default_path, session_dir: rpc_session.store.session_dir)
      end

      def export_format(format)
        TranscriptExport.format(format)
      end

      def export_content(conversation, format)
        TranscriptExport.content(conversation, format: format)
      end

      def normalized_tool_event_payload(tool_call)
        ToolEventNormalizer.new(tool_call).call_payload
      end

      def normalized_tool_result_event_payload(tool_call, content)
        ToolEventNormalizer.new(tool_call, content: content).result_payload
      end

      def turn_error_payload(error)
        {
          message: error.message,
          code: error.class.name,
          fatal: false
        }
      end


      def now
        Time.now.utc.iso8601(3)
      end
    end
  end
end
