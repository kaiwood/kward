require "set"
require_relative "prompts"

module Kward
  class Conversation
    attr_reader :messages, :read_paths

    def initialize(system_message: SYSTEM_MESSAGE)
      @messages = [system_message]
      @read_paths = Set.new
    end

    def append_user(content)
      @messages << { role: "user", content: content }
    end

    def append_assistant(message)
      message = { role: "assistant", content: message } if message.is_a?(String)
      @messages << message
    end

    def append_tool(tool_call_id:, name:, content:)
      @messages << {
        role: "tool",
        tool_call_id: tool_call_id,
        name: name,
        content: content
      }
    end

    def mark_read(path)
      @read_paths << path
    end

    def last_write_result
      @messages.select { |message| message[:role] == "tool" && message[:name] == "write_file" }.last
    end

    def last_file_change_result
      @messages.select do |message|
        message[:role] == "tool" && ["write_file", "edit_file"].include?(message[:name])
      end.last
    end
  end
end
