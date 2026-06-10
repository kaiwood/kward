require "base64"
require "cgi"
require "securerandom"
require "thread"
require "time"
require_relative "../agent"
require_relative "../cancellation"
require_relative "../model/client"
require_relative "../compactor"
require_relative "../config_files"
require_relative "../context_usage"
require_relative "../conversation"
require_relative "../crew_reporter"
require_relative "../events"
require_relative "../markdown_transcript"
require_relative "../model_info"
require_relative "../plugin_registry"
require_relative "../prompt_commands"
require_relative "../session_store"
require_relative "../steering"
require_relative "../tool_call"
require_relative "../tool_registry"
require_relative "../workspace"
require_relative "prompt_bridge"
require_relative "tool_event_normalizer"
require_relative "transcript_normalizer"

module Kward
  module RPC
    class SessionManager
      RECENT_EVENT_LIMIT = 1_000
      RPC_ATTACHMENT_MAX_BYTES = 10 * 1024 * 1024
      RPC_IMAGE_MIME_TYPES = ["image/png", "image/jpeg", "image/gif", "image/webp"].freeze
      STREAMING_BEHAVIORS = ["newTurn", "followUp", "steer"].freeze
      WORKER_STOP = Object.new.freeze

      RpcSession = Struct.new(:id, :workspace_root, :store, :session, :conversation, :agent, :tool_registry, :prompt, :plugin_output, :queue, :worker, :running_turn_id, keyword_init: true)
      Turn = Struct.new(:id, :session_id, :input, :status, :cancel_requested, :cancellation, :created_at, :started_at, :finished_at, :events, :next_sequence, :error, :streaming_behavior, :plugin_command_name, :plugin_arguments, :steering, keyword_init: true)

      def initialize(server:, client: Client.new, config_dir: ConfigFiles.config_dir, context_usage: ContextUsage.new)
        @server = server
        @client = client
        @config_dir = config_dir
        @context_usage = context_usage
        @sessions = {}
        @turns = {}
        @mutex = Mutex.new
      end

      def create_session(workspace_root: Dir.pwd, name: nil)
        workspace_root = validate_workspace_root(workspace_root)
        store = SessionStore.new(config_dir: @config_dir, cwd: workspace_root)
        conversation = new_conversation(workspace_root: workspace_root)
        session = store.create(model: conversation.model, reasoning_effort: conversation.reasoning_effort)
        session.rename(name) unless name.to_s.strip.empty?
        session.attach(conversation)
        rpc_session = build_rpc_session(store, session, conversation, workspace_root)
        remember_session(rpc_session)
        cleanup_other_unused_sessions(rpc_session)
        session_payload(rpc_session)
      end

      def resume_session(path:, workspace_root: nil)
        root = validate_workspace_root(workspace_root || Dir.pwd)
        store = SessionStore.new(config_dir: @config_dir, cwd: root)
        location = store.session_location(path)
        root = validate_workspace_root(location[:cwd])
        store = SessionStore.new(config_dir: @config_dir, cwd: root)
        session, conversation = store.load(
          location[:path],
          workspace: Workspace.new(root: root),
          model: current_model_id,
          reasoning_effort: current_reasoning_effort
        )
        rpc_session = build_rpc_session(store, session, conversation, root)
        remember_session(rpc_session)
        cleanup_other_unused_sessions(rpc_session)
        session_payload(rpc_session)
      end

      def list_sessions(workspace_root: Dir.pwd, limit: 20)
        root = validate_workspace_root(workspace_root)
        store = SessionStore.new(config_dir: @config_dir, cwd: root)
        limit = limit.to_i <= 0 ? 20 : limit.to_i
        store.recent_tree(limit: limit + active_session_count(root))
             .reject { |info| active_empty_unnamed_session_info?(info, root) }
             .first(limit)
             .map { |info| session_info_payload(info, workspace_root: root) }
      end

      def rename_session(session_id:, name:)
        rpc_session = fetch_session(session_id)
        rpc_session.session.rename(name)
        session_payload(rpc_session)
      end

      def clone_session(session_id:)
        source = fetch_session(session_id)
        session, conversation = source.store.create_independent_from_conversation(source.conversation, parent_session: source.session)
        rpc_session = build_rpc_session(source.store, session, conversation, source.workspace_root)
        remember_session(rpc_session)
        cleanup_other_unused_sessions(rpc_session)
        session_payload(rpc_session)
      end

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

      def fork_messages(session_id:)
        rpc_session = fetch_session(session_id)
        {
          messages: entry_messages(rpc_session.conversation).each_with_index.filter_map do |message, index|
            next unless message_role(message) == "user"

            { entryId: entry_id(index), text: display_message_text(message) }
          end
        }
      end

      def fork_session(session_id:, entry_id:)
        source = fetch_session(session_id)
        index = entry_index(entry_id)
        messages = entry_messages(source.conversation)
        selected = messages[index] || raise(ArgumentError, "Unknown fork entryId: #{entry_id}")
        raise ArgumentError, "Entry is not forkable: #{entry_id}" unless message_role(selected) == "user"

        session, conversation = source.store.create_independent_from_messages(
          messages[0...index],
          model: source.conversation.model,
          reasoning_effort: source.conversation.reasoning_effort,
          parent_session: source.session
        )

        # ensure forked sessions retain the original persona context
        rpc_session = build_rpc_session(source.store, session, conversation, source.workspace_root)
        remember_session(rpc_session)
        cleanup_other_unused_sessions(rpc_session)
        {
          session: session_payload(rpc_session),
          text: full_message_text(selected),
          cancelled: false
        }
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
        close_rpc_session(rpc_session)
        { closed: true }
      end

      def cleanup_unused_sessions
        rpc_sessions = @mutex.synchronize { @sessions.values.dup }
        rpc_sessions.reverse_each do |rpc_session|
          next unless session_idle?(rpc_session)

          close_rpc_session(rpc_session)
        end
        { closed: true }
      end

      def transcript(session_id:)
        rpc_session = fetch_session(session_id)
        { session: session_payload(rpc_session), messages: TranscriptNormalizer.new(rpc_session.conversation.messages).normalize }
      end

      def start_turn(session_id:, input:, streaming_behavior: nil, attachments: [])
        rpc_session = fetch_session(session_id)
        normalized_attachments = normalize_attachments(attachments)
        plugin_command, plugin_arguments = plugin_command_turn(input, normalized_attachments)
        content = plugin_command ? input.to_s : user_turn_content(expand_prompt_input(input), normalized_attachments)
        streaming_behavior = validate_streaming_behavior(default_streaming_behavior(rpc_session, streaming_behavior), rpc_session: rpc_session)
        if streaming_behavior == "steer"
          steered_turn = steer_running_turn(rpc_session, content)
          return steered_turn if steered_turn

          streaming_behavior = "followUp"
        end
        turn = Turn.new(
          id: SecureRandom.uuid,
          session_id: rpc_session.id,
          input: content,
          status: "queued",
          cancel_requested: false,
          cancellation: Cancellation.new,
          created_at: now,
          events: [],
          next_sequence: 1,
          streaming_behavior: streaming_behavior,
          plugin_command_name: plugin_command&.name,
          plugin_arguments: plugin_arguments
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
        return run_crew_command(session_id: session_id, arguments: arguments) if name == "crew"

        run_plugin_command(session_id: session_id, command: name, arguments: arguments)
      end

      def run_crew_command(session_id:, arguments: "")
        rpc_session = fetch_session(session_id)
        report = CrewReporter.new(
          client: @client,
          workspace_root: rpc_session.workspace_root,
          model: current_model_id,
          reasoning_effort: current_reasoning_effort,
          config: ConfigFiles.read_config
        ).report(instructions: arguments.to_s)
        { command: "crew", output: [report.output], result: report.output, personas: report.personas || [], status: report.status.to_s }
      end

      def run_plugin_command(session_id:, command:, arguments: "")
        rpc_session = fetch_session(session_id)
        command = plugin_registry.command_for(command.to_s.delete_prefix("/")) || raise(ArgumentError, "Unknown plugin command: #{command}")
        output = []
        context = PluginRegistry::Context.new(
          conversation: rpc_session.conversation,
          args: arguments.to_s,
          session: rpc_session.session,
          workspace_root: rpc_session.workspace_root,
          say_callback: lambda { |message| output << message.to_s }
        )
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

      def in_flight_steer_supported?
        supports_in_flight_steer?
      end

      def runtime_state(session_id:)
        rpc_session = fetch_session(session_id)
        model = current_model
        session = session_payload(rpc_session)
        pending_count = pending_turn_count(rpc_session.id)
        {
          model: model,
          thinkingLevel: model[:reasoningEffort],
          isStreaming: streaming?(rpc_session),
          isCompacting: false,
          steeringMode: supports_in_flight_steer? ? "in-flight" : "one-at-a-time",
          followUpMode: "one-at-a-time",
          sessionFile: session[:path],
          sessionId: session[:persistentId],
          rpcSessionId: session[:id],
          persistentSessionId: session[:persistentId],
          sessionName: session[:name],
          autoCompactionEnabled: compaction_settings.enabled,
          autoRetryEnabled: false,
          defaultProvider: model[:provider],
          defaultModel: default_model_label(model),
          defaultThinkingLevel: model[:reasoningEffort],
          hideThinkingBlock: false,
          quietStartup: false,
          transport: "kward-rpc",
          imageAutoResize: false,
          blockImages: false,
          enabledModels: [],
          enableSkillCommands: true,
          messageCount: message_count(rpc_session.conversation),
          pendingMessageCount: pending_count
        }.compact
      end

      def runtime_stats(session_id:)
        rpc_session = fetch_session(session_id)
        session = session_payload(rpc_session)
        counts = message_stats(rpc_session.conversation)
        model = current_model
        {
          sessionFile: session[:path],
          sessionId: session[:persistentId],
          rpcSessionId: session[:id],
          persistentSessionId: session[:persistentId],
          sessionName: session[:name],
          userMessages: counts[:userMessages],
          assistantMessages: counts[:assistantMessages],
          toolCalls: counts[:toolCalls],
          toolResults: counts[:toolResults],
          totalMessages: counts[:totalMessages],
          usingSubscription: model[:provider] == "Codex",
          autoCompactionEnabled: compaction_settings.enabled,
          contextUsage: context_usage(rpc_session, model)
        }.compact
      end

      def refresh_client_config
        @client.reload_config if @client.respond_to?(:reload_config)
        refresh_session_runtime_contexts
      end

      def session_payload(rpc_session)
        {
          id: rpc_session.id,
          persistentId: rpc_session.session.id,
          path: rpc_session.session.path,
          workspaceRoot: rpc_session.workspace_root,
          cwd: rpc_session.session.cwd.to_s.empty? ? rpc_session.workspace_root : rpc_session.session.cwd,
          name: rpc_session.session.name,
          createdAt: rpc_session.session.created_at&.utc&.iso8601(3),
          modifiedAt: session_modified_at(rpc_session.session)&.utc&.iso8601(3),
          parentId: rpc_session.session.parent_id,
          parentPath: rpc_session.session.parent_path
        }
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
          model: (@client.current_model if @client.respond_to?(:current_model)),
          reasoning_effort: (@client.current_reasoning_effort if @client.respond_to?(:current_reasoning_effort))
        )
      end

      def refresh_session_runtime_contexts
        model = current_model_id
        reasoning_effort = current_reasoning_effort
        sessions = @mutex.synchronize { @sessions.values }
        sessions.each do |rpc_session|
          rpc_session.conversation.update_runtime_context!(model: model, reasoning_effort: reasoning_effort)
          rpc_session.session.update_runtime(model: model, reasoning_effort: reasoning_effort)
        end
      end

      def compaction_settings
        path = File.join(@config_dir, "config.json")
        Kward::Compaction::Settings.from_config(ConfigFiles.read_config(path))
      rescue StandardError
        Kward::Compaction::Settings.new
      end

      def current_model_id
        @client.respond_to?(:current_model) ? @client.current_model : ModelInfo::DEFAULT_OPENAI_MODEL
      end

      def current_reasoning_effort
        @client.respond_to?(:current_reasoning_effort) ? @client.current_reasoning_effort : ModelInfo::DEFAULT_REASONING_EFFORT
      end

      def normalize_model(model)
        ModelInfo.normalize(
          model,
          current_provider: (@client.current_provider if @client.respond_to?(:current_provider)),
          current_model: (@client.current_model if @client.respond_to?(:current_model)),
          current_reasoning_effort: (@client.current_reasoning_effort if @client.respond_to?(:current_reasoning_effort))
        )
      end

      def default_model_label(model)
        return nil if model[:provider].to_s.empty? || model[:id].to_s.empty?

        "#{model[:provider]}/#{model[:id]}"
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

      def active_session_count(workspace_root)
        @mutex.synchronize { @sessions.values.count { |rpc_session| rpc_session.workspace_root == workspace_root } }
      end

      def active_empty_unnamed_session_info?(info, workspace_root)
        rpc_sessions = @mutex.synchronize { @sessions.values.dup }
        rpc_sessions.any? do |rpc_session|
          rpc_session.workspace_root == workspace_root &&
            File.expand_path(rpc_session.session.path) == File.expand_path(info.path) &&
            session_idle?(rpc_session) &&
            info.name.to_s.strip.empty? &&
            info.message_count.to_i.zero?
        end
      end

      def message_count(conversation)
        conversation.messages.count { |message| message_role(message) != "system" }
      end

      def context_usage(rpc_session, model)
        context_parts = if @client.respond_to?(:current_context_parts)
                          @client.current_context_parts(rpc_session.conversation.messages, rpc_session.tool_registry.schemas)
                        else
                          { provider: model[:provider], model: model[:id], messages: rpc_session.conversation.messages, tools: rpc_session.tool_registry.schemas }
                        end
        @context_usage.call(
          provider: model[:provider],
          model: model[:id],
          context_window: model[:contextWindow],
          context_parts: context_parts
        )
      end

      def message_stats(conversation)
        conversation.messages.each_with_object({ userMessages: 0, assistantMessages: 0, toolCalls: 0, toolResults: 0, totalMessages: 0 }) do |message, counts|
          role = message_role(message)
          next if role == "system"

          counts[:totalMessages] += 1
          case role
          when "user"
            counts[:userMessages] += 1
          when "assistant"
            counts[:assistantMessages] += 1
            counts[:toolCalls] += tool_calls(message).length
          when "tool", "toolResult"
            counts[:toolResults] += 1
          end
        end
      end

      def tool_calls(message)
        calls = message["tool_calls"] || message[:tool_calls]
        calls.is_a?(Array) ? calls : []
      end

      def message_role(message)
        message["role"] || message[:role]
      end

      def entry_messages(conversation)
        conversation.messages.reject { |message| message_role(message) == "system" }
      end

      def entry_id(index)
        "message:#{index}"
      end

      def entry_index(entry_id)
        match = entry_id.to_s.match(/\Amessage:(\d+)\z/)
        raise ArgumentError, "Invalid entryId: #{entry_id}" unless match

        match[1].to_i
      end

      def display_message_text(message)
        full_message_text(message).gsub(/\s+/, " ").strip.slice(0, 120).to_s
      end

      def full_message_text(message)
        content = message["content"] || message[:content]
        text = if content.is_a?(Array)
                 content.filter_map { |part| part["text"] || part[:text] }.join("\n")
               else
                 content.to_s
               end
        text.strip
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
        return [] if attachments.nil?
        raise ArgumentError, "attachments must be an array" unless attachments.is_a?(Array)

        attachments.map { |attachment| normalize_attachment(attachment) }
      end

      def normalize_attachment(attachment)
        raise ArgumentError, "attachment must be an object" unless attachment.is_a?(Hash)

        type = value(attachment, :type).to_s
        raise ArgumentError, "Unsupported attachment type: #{type.empty? ? "unknown" : type}" unless type == "image"

        mime_type = normalize_attachment_mime_type(value(attachment, :mimeType) || value(attachment, :mime_type) || value(attachment, :media_type))
        raise ArgumentError, "Unsupported image MIME type: #{mime_type.empty? ? "unknown" : mime_type}" unless RPC_IMAGE_MIME_TYPES.include?(mime_type)

        data = value(attachment, :data).to_s
        raise ArgumentError, "Image attachment data must be valid base64" if data.empty?
        raise ArgumentError, "Image attachment data must be raw base64" if data.start_with?("data:")
        declared_size = value(attachment, :sizeBytes) || value(attachment, :size_bytes)
        raise ArgumentError, "Image attachment is too large" if declared_size && declared_size.to_i > RPC_ATTACHMENT_MAX_BYTES

        decoded_size = Base64.strict_decode64(data).bytesize
        raise ArgumentError, "Image attachment is too large" if decoded_size > RPC_ATTACHMENT_MAX_BYTES

        result = { type: "image", data: data, mimeType: mime_type }
        name = value(attachment, :name)
        result[:alt] = name.to_s unless name.to_s.empty?
        result
      rescue ArgumentError => e
        raise e if e.message.start_with?("Unsupported", "Image attachment", "attachment")

        raise ArgumentError, "Image attachment data must be valid base64"
      end

      def normalize_attachment_mime_type(mime_type)
        mime_type.to_s.downcase
      end

      def value(object, key)
        return nil unless object.respond_to?(:key?)
        return object[key] if object.key?(key)
        return object[key.to_s] if object.key?(key.to_s)

        nil
      end

      def plugin_registry
        @plugin_registry ||= PluginRegistry.load(reserved_commands: reserved_plugin_command_names)
      end

      def reserved_plugin_command_names
        PromptCommands::BUILTIN_RESERVED_COMMAND_NAMES + ConfigFiles.prompt_templates(reserved_commands: PromptCommands::BUILTIN_RESERVED_COMMAND_NAMES).map(&:command)
      end

      def build_rpc_session(store, session, conversation, workspace_root)
        id = SecureRandom.uuid
        prompt = PromptBridge.new(server: @server, session_id: id)
        workspace = Workspace.new(root: workspace_root)
        tool_registry = ToolRegistry.new(workspace: workspace, prompt: prompt)
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

      def close_rpc_session(rpc_session)
        @mutex.synchronize { @sessions.delete(rpc_session.id) }
        stop_worker(rpc_session)
        rpc_session.session.delete_if_unused if rpc_session.session.respond_to?(:delete_if_unused)
      end

      def cleanup_other_unused_sessions(current_session)
        rpc_sessions = @mutex.synchronize { @sessions.values.dup }
        rpc_sessions.each do |rpc_session|
          next if rpc_session.id == current_session.id
          next if rpc_session.session.path == current_session.session.path
          next unless session_idle?(rpc_session)
          next unless rpc_session.session.respond_to?(:delete_if_unused)
          next unless rpc_session.session.delete_if_unused

          @mutex.synchronize { @sessions.delete(rpc_session.id) }
          stop_worker(rpc_session)
        end
      end

      def stop_worker(rpc_session)
        worker = rpc_session.worker
        return unless worker&.alive?
        return if worker == Thread.current

        rpc_session.queue << WORKER_STOP
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
          rpc_session.agent.ask(turn.input, cancellation: turn.cancellation, steering: turn.steering) do |event|
            next if turn.cancel_requested

            notify_plugin_transcript_event(rpc_session, event)
            handle_agent_event(turn, event)
          end
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

      def steer_running_turn(rpc_session, input)
        turn_id = rpc_session.running_turn_id
        turn = turn_id && fetch_turn(turn_id)
        raise ArgumentError, "Unsupported streamingBehavior: steer" unless turn&.status == "running" && turn.steering

        turn.steering.submit(input)
        turn_payload(turn)
      rescue StandardError
        nil
      end

      def run_plugin_turn(rpc_session, turn)
        turn.cancellation&.raise_if_cancelled!
        command = plugin_registry.command_for(turn.plugin_command_name) || raise(ArgumentError, "Unknown plugin command: #{turn.plugin_command_name}")
        output = []
        context = PluginRegistry::Context.new(
          conversation: rpc_session.conversation,
          args: turn.plugin_arguments.to_s,
          session: rpc_session.session,
          workspace_root: rpc_session.workspace_root,
          say_callback: lambda { |message| output << message.to_s }
        )
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

        context = PluginRegistry::Context.new(
          conversation: rpc_session.conversation,
          session: rpc_session.session,
          workspace_root: rpc_session.workspace_root,
          say_callback: lambda { |message| rpc_session.plugin_output << message.to_s }
        )
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
          parentId: info.parent_id,
          parentPath: info.parent_path,
          depth: info.depth.to_i,
          isLast: info.is_last,
          ancestorContinues: Array(info.ancestor_continues)
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
        markdown = MarkdownTranscript.new(conversation).render
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

      def normalized_tool_event_payload(tool_call)
        ToolEventNormalizer.new(tool_call).call_payload(legacy_tool: tool_metadata(tool_call))
      end

      def normalized_tool_result_event_payload(tool_call, content)
        ToolEventNormalizer.new(tool_call, content: content).result_payload(legacy_tool: tool_metadata(tool_call))
      end

      def turn_error_payload(error)
        {
          message: error.message,
          code: error.class.name,
          fatal: false
        }
      end

      def tool_metadata(tool_call)
        name = ToolCall.name(tool_call)
        args = ToolCall.arguments(tool_call)

        case name
        when "edit_file"
          edits = Array(args["edits"] || args[:edits]).map do |edit|
            {
              oldText: edit["old_text"] || edit[:old_text],
              newText: edit["new_text"] || edit[:new_text]
            }.compact
          end
          first_edit = edits.first || {}
          {
            kind: "edit",
            path: args["path"] || args[:path],
            edits: edits,
            oldText: first_edit[:oldText],
            newText: first_edit[:newText]
          }.compact
        when "write_file"
          { kind: "write", path: args["path"] || args[:path] }.compact
        when "run_shell_command"
          { kind: "shell", command: args["command"] || args[:command] }.compact
        else
          nil
        end
      end


      def now
        Time.now.utc.iso8601(3)
      end
    end
  end
end
