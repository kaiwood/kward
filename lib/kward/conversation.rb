require "set"
require_relative "image_attachments"
require_relative "prompts"

module Kward
  class Conversation
    attr_reader :messages, :read_paths
    attr_accessor :on_append, :on_compact

    def initialize(system_message: Prompts.system_message, messages: [], read_paths: [], on_append: nil, on_compact: nil)
      @messages = []
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

    def mark_read(path)
      @read_paths << path
    end

    def compact!(summary, compaction_summary: false)
      message = if compaction_summary
                  { role: "compactionSummary", summary: summary.to_s }
                else
                  { role: "assistant", content: summary.to_s }
                end
      @messages = @messages.select { |item| message_role(item) == "system" }
      @messages << message
      @read_paths.clear
      @on_compact&.call(message)
      message
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

    def append_message(message)
      @messages << message
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
