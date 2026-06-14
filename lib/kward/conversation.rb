require "set"
require_relative "image_attachments"
require_relative "message_access"
require_relative "plugin_registry"
require_relative "prompts"

# Namespace for the Kward CLI agent runtime.
module Kward
  # Mutable transcript and runtime context for one agent session.
  #
  # `Conversation` owns message ordering, system prompt refresh, read-before-write
  # state, memory prompt context, and persistence hooks. It intentionally stores
  # plain hashes because provider payload builders, session JSONL files, and RPC
  # normalizers all share the same transcript shape. Use `MessageAccess` when
  # reading messages so symbol/string key and legacy field compatibility stays in
  # one place.
  #
  # Frontends should not mutate `messages` directly after attaching a
  # `SessionStore::Session`; use append/compact helpers so persistence callbacks
  # run and session trees stay consistent.
  class Conversation
    DEFAULT_SYSTEM_MESSAGE = Object.new.freeze

    # @return [Array<Hash>] ordered transcript entries sent to providers and persisted in sessions
    attr_reader :messages
    # @return [Set<String>] resolved paths read by file tools during the active context
    attr_reader :read_paths
    # @return [String] canonical workspace root used for prompts and file guardrails
    attr_reader :workspace_root
    # @return [Hash, nil] system prompt used when summarizing old context
    attr_reader :compaction_system_message
    # @return [String, nil] provider captured for session/runtime prompts
    attr_reader :provider
    # @return [String, nil] model id captured for session/runtime prompts
    attr_reader :model
    # @return [String, nil] reasoning effort captured for session/runtime prompts
    attr_reader :reasoning_effort
    # @return [Array<Hash>] memories scoped to this conversation session
    attr_reader :session_memories
    # @return [Proc, nil] persistence callback invoked after appending a message
    attr_accessor :on_append
    # @return [Proc, nil] persistence callback invoked after compaction replaces history
    attr_accessor :on_compact
    # @return [Proc, nil] callback invoked when a tool execution record should be persisted
    attr_accessor :on_tool_execution
    # @return [Proc, nil] callback invoked when runtime metadata should be persisted
    attr_accessor :on_runtime_update
    # @return [String, nil] memory prompt context injected into refreshed system messages
    attr_accessor :memory_context
    # @return [Hash, nil] metadata for the last memory retrieval attached to the session
    attr_accessor :last_memory_retrieval
    # @return [PluginRegistry, nil] registry used to collect plugin prompt context
    attr_accessor :plugin_registry

    def initialize(system_message: DEFAULT_SYSTEM_MESSAGE, messages: [], read_paths: [], on_append: nil, on_compact: nil, on_tool_execution: nil, on_runtime_update: nil, workspace_root: Dir.pwd, compaction_system_message: DEFAULT_SYSTEM_MESSAGE, provider: nil, model: nil, reasoning_effort: nil, memory_context: nil, session_memories: [], last_memory_retrieval: nil, plugin_registry: nil)
      @workspace_root = ConfigFiles.canonical_workspace_root(workspace_root)
      @provider = provider
      @model = model
      @reasoning_effort = reasoning_effort
      @plugin_registry = plugin_registry
      @messages = []
      if system_message.equal?(DEFAULT_SYSTEM_MESSAGE)
        system_message = messages.any? { |message| MessageAccess.role(message) == "system" } ? nil : Prompts.system_message(workspace_root: @workspace_root, model: @model, reasoning_effort: @reasoning_effort, memory_context: memory_context, plugin_context: plugin_prompt_context)
      end
      @system_message_enabled = !!(system_message || messages.find { |message| MessageAccess.role(message) == "system" })
      if compaction_system_message.equal?(DEFAULT_SYSTEM_MESSAGE)
        compaction_system_message = @system_message_enabled ? Prompts.system_message(workspace_root: @workspace_root, include_workspace_personality: false, model: @model, reasoning_effort: @reasoning_effort) : nil
      end
      @compaction_system_message = compaction_system_message
      @workspace_agents_mtime = workspace_agents_mtime
      @last_entry_compaction = false
      @memory_context = memory_context
      @session_memories = Array(session_memories)
      @last_memory_retrieval = last_memory_retrieval
      @messages << system_message unless system_message.nil?
      @messages.concat(messages)
      @read_paths = Set.new(read_paths)
      @on_append = on_append
      @on_compact = on_compact
      @on_tool_execution = on_tool_execution
      @on_runtime_update = on_runtime_update
    end

    # Appends a user message and normalizes image attachment syntax.
    #
    # `display_content` is transcript/UI text for cases where the model input is
    # expanded, decorated, or contains encoded attachment content.
    def append_user(content, display_content: nil)
      content = ImageAttachments.content_from_text(content) unless content.is_a?(Array)
      message = { role: "user", content: content }
      message[:display_content] = display_content.to_s unless display_content.nil?
      append_message(message)
    end

    def append_assistant(message)
      message = { role: "assistant", content: message } if message.is_a?(String)
      append_message(message)
    end

    def append_tool(tool_call_id:, name:, content:)
      append_message({
        role: "tool",
        tool_call_id: tool_call_id,
        name: name,
        content: content
      })
    end

    def append_tool_execution(tool_call:, content:)
      @on_tool_execution&.call(tool_call, content)
    end

    # Rebuilds the system message from current config, memory, plugins, and
    # workspace AGENTS.md state.
    #
    # Conversations created with `system_message: nil` keep system prompts
    # disabled; this preserves tests, compaction summaries, and imported
    # transcripts that intentionally do not include runtime instructions.
    def refresh_system_message!
      return nil unless @system_message_enabled

      replacement = Prompts.system_message(workspace_root: @workspace_root, model: @model, reasoning_effort: @reasoning_effort, memory_context: @memory_context, plugin_context: plugin_prompt_context)
      index = @messages.index { |message| MessageAccess.role(message) == "system" }
      index ? @messages[index] = replacement : @messages.unshift(replacement)
      @compaction_system_message = Prompts.system_message(workspace_root: @workspace_root, include_workspace_personality: false, model: @model, reasoning_effort: @reasoning_effort)
      @workspace_agents_mtime = workspace_agents_mtime
      replacement
    end

    def update_runtime_context!(provider: nil, model:, reasoning_effort:)
      @provider = provider unless provider.to_s.empty?
      @model = model
      @reasoning_effort = reasoning_effort
      refresh_system_message!
    end

    def persist_runtime_context!
      @on_runtime_update&.call(provider: @provider, model: @model, reasoning_effort: @reasoning_effort)
    end

    def refresh_system_message_if_workspace_agents_changed!
      refresh_system_message! if @system_message_enabled && workspace_agents_mtime != @workspace_agents_mtime
    end

    def mark_read(path)
      @read_paths << path
    end

    def plugin_prompt_context
      return nil unless plugin_registry

      context = PluginRegistry::Context.new(conversation: self, workspace_root: @workspace_root)
      plugin_registry.prompt_context(context)
    end

    # Replaces most transcript entries with a compaction summary and optional
    # recent messages to keep.
    #
    # Compaction clears read-before-write state because file contents observed
    # before the summary may no longer be represented exactly in the active
    # context. Callers that need file mutation after compaction should read files
    # again through the normal tools.
    def compact!(summary, compaction_summary: false, first_kept_entry_id: nil, tokens_before: nil, from_hook: false, details: {}, keep_messages: [])
      message = if compaction_summary
                  { role: "compactionSummary", summary: summary.to_s }
                else
                  { role: "assistant", content: summary.to_s }
                end
      if compaction_summary
        message[:first_kept_entry_id] = first_kept_entry_id if first_kept_entry_id
        message[:tokens_before] = tokens_before if tokens_before
        message[:from_hook] = from_hook
        message[:details] = details || {}
      end
      @messages = @messages.select { |item| MessageAccess.role(item) == "system" }
      @messages << message
      @messages.concat(Array(keep_messages))
      @read_paths.clear
      @last_entry_compaction = true
      @on_compact&.call(message)
      message
    end

    def last_entry_compaction?
      @last_entry_compaction
    end

    def mark_last_entry_compaction!
      @last_entry_compaction = true
    end

    def last_file_change_result
      @messages.select do |message|
        MessageAccess.role(message) == "tool" && ["write_file", "edit_file"].include?(MessageAccess.name(message))
      end.last
    end

    private

    def workspace_agents_mtime
      path = File.join(@workspace_root, "AGENTS.md")
      File.exist?(path) ? File.mtime(path) : nil
    end

    def append_message(message)
      @messages << message
      @last_entry_compaction = false
      @on_append&.call(message)
      message
    end

  end
end
