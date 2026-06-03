require "set"
require_relative "image_attachments"
require_relative "prompts"

module Kward
  class Conversation
    attr_reader :messages, :read_paths
    attr_accessor :on_append

    def initialize(system_message: Prompts.system_message, messages: [], read_paths: [], on_append: nil)
      @messages = []
      @messages << system_message unless system_message.nil?
      @messages.concat(messages)
      @read_paths = Set.new(read_paths)
      @on_append = on_append
    end

    def append_user(content)
      append_message({ role: "user", content: ImageAttachments.content_from_text(content) })
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
