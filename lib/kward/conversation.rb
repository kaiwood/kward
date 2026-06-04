require "set"
require_relative "image_attachments"
require_relative "prompts"

module Kward
  class Conversation
    DEFAULT_SYSTEM_MESSAGE = Object.new.freeze

    attr_reader :messages, :read_paths, :workspace_root, :compaction_system_message
    attr_accessor :on_append, :on_compact

    def initialize(system_message: DEFAULT_SYSTEM_MESSAGE, messages: [], read_paths: [], on_append: nil, on_compact: nil, workspace_root: Dir.pwd, compaction_system_message: DEFAULT_SYSTEM_MESSAGE)
      @workspace_root = ConfigFiles.canonical_workspace_root(workspace_root)
      @messages = []
      if system_message.equal?(DEFAULT_SYSTEM_MESSAGE)
        system_message = messages.any? { |message| message_role(message) == "system" } ? nil : Prompts.system_message(workspace_root: @workspace_root)
      end
      @system_message_enabled = !!(system_message || messages.find { |message| message_role(message) == "system" })
      if compaction_system_message.equal?(DEFAULT_SYSTEM_MESSAGE)
        compaction_system_message = @system_message_enabled ? Prompts.system_message(workspace_root: @workspace_root, include_workspace_personality: false) : nil
      end
      @compaction_system_message = compaction_system_message
      @workspace_agents_mtime = workspace_agents_mtime
      @last_entry_compaction = false
      @messages << system_message unless system_message.nil?
      @messages.concat(messages)
      @read_paths = Set.new(read_paths)
      @on_append = on_append
      @on_compact = on_compact
    end

    def append_user(content)
      content = ImageAttachments.content_from_text(content) unless content.is_a?(Array)
      append_message({ role: "user", content: content })
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

    def refresh_system_message!
      return nil unless @system_message_enabled

      replacement = Prompts.system_message(workspace_root: @workspace_root)
      index = @messages.index { |message| message_role(message) == "system" }
      index ? @messages[index] = replacement : @messages.unshift(replacement)
      @compaction_system_message = Prompts.system_message(workspace_root: @workspace_root, include_workspace_personality: false)
      @workspace_agents_mtime = workspace_agents_mtime
      replacement
    end

    def refresh_system_message_if_workspace_agents_changed!
      refresh_system_message! if @system_message_enabled && workspace_agents_mtime != @workspace_agents_mtime
    end

    def mark_read(path)
      @read_paths << path
    end

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
      @messages = @messages.select { |item| message_role(item) == "system" }
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

    def last_write_result
      @messages.select { |message| message_role(message) == "tool" && message_name(message) == "write_file" }.last
    end

    def last_file_change_result
      @messages.select do |message|
        message_role(message) == "tool" && ["write_file", "edit_file"].include?(message_name(message))
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

    def message_role(message)
      message[:role] || message["role"]
    end

    def message_name(message)
      message[:name] || message["name"]
    end
  end
end
