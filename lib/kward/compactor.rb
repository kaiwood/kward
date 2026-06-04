require "json"

module Kward
  class Compactor
    Result = Struct.new(:summary, :old_message_count, :new_message_count, keyword_init: true)
    NothingToCompact = Class.new(ArgumentError)
    EmptySummary = Class.new(StandardError)

    def initialize(conversation:, client:, tool_result_summarizer: nil)
      @conversation = conversation
      @client = client
      @tool_result_summarizer = tool_result_summarizer
    end

    def compactable?
      compactable_messages.any?
    end

    def compact(custom_instructions: "", compaction_summary: true)
      old_count = @conversation.messages.length
      raise NothingToCompact, "Nothing to compact yet." unless compactable?

      message = chat(compaction_messages(custom_instructions))
      summary = message_content_text(message_content(message)).strip
      raise EmptySummary, "Compaction produced an empty summary; context was not changed." if summary.empty?

      @conversation.compact!(summary, compaction_summary: compaction_summary)
      Result.new(summary: summary, old_message_count: old_count, new_message_count: @conversation.messages.length)
    end

    def compaction_messages(custom_instructions = "")
      system_message = @conversation.messages.find { |message| message_role(message) == "system" }
      messages = []
      messages << system_message if system_message
      messages << {
        role: "user",
        content: compaction_prompt(compaction_transcript, custom_instructions)
      }
      messages
    end

    private

    def chat(messages)
      @client.chat(messages, tools: [])
    rescue ArgumentError => e
      raise unless e.message.include?("tools")

      @client.chat(messages)
    end

    def compactable_messages
      @conversation.messages.reject { |message| message_role(message) == "system" }
    end

    def compaction_prompt(transcript, custom_instructions)
      guidance = custom_instructions.to_s.strip
      lines = [
        "Compact the conversation transcript below into a concise continuation summary for a coding agent.",
        "Preserve goals, user preferences, constraints, decisions, completed work, relevant files inspected or changed, blockers, and pending tasks.",
        "Mention tool results only when they are needed to continue the work.",
        "Do not invent facts. Write in a form that can replace the prior conversation history."
      ]
      lines << "Additional user instructions for compaction: #{guidance}" unless guidance.empty?
      lines << ""
      lines << "Transcript:"
      lines << transcript
      lines.join("\n")
    end

    def compaction_transcript
      tool_calls_by_id = {}
      compactable_messages.map do |message|
        role = message_role(message).to_s
        case role
        when "assistant"
          parts = []
          reasoning = message_reasoning(message)
          parts << "Reasoning: #{reasoning}" unless reasoning.empty?
          content = message_content_text(message_content(message))
          parts << content unless content.empty?
          message_tool_calls(message).each do |tool_call|
            tool_calls_by_id[tool_call_id(tool_call)] = tool_call
            parts << "Tool call: #{tool_command(tool_call)}"
          end
          transcript_entry("assistant", parts.join("\n"))
        when "tool"
          tool_call = tool_calls_by_id[message_tool_call_id(message)] || synthetic_tool_call(message_name(message), message_tool_call_id(message))
          transcript_entry("tool #{message_name(message)}", tool_result_summary(tool_call, message_content(message).to_s))
        else
          transcript_entry(role, message_content_text(message_content(message)))
        end
      end.join("\n\n")
    end

    def transcript_entry(role, content)
      "#{role}:\n#{content}"
    end

    def tool_result_summary(tool_call, content)
      return @tool_result_summarizer.call(tool_call, content) if @tool_result_summarizer

      name = tool_call_name(tool_call)
      text = content.to_s
      return "#{name}: #{text}" if text.length <= 2_000

      "#{name}: #{text[0, 2_000]}\n...[truncated #{text.length - 2_000} bytes]"
    end

    def message_reasoning(message)
      direct = message["reasoning_summary"] || message[:reasoning_summary]
      return direct.to_s unless direct.to_s.empty?

      content = message_content(message)
      return "" unless content.is_a?(Array)

      content.filter_map do |part|
        type = part["type"] || part[:type]
        next unless ["thinking", "reasoning"].include?(type)

        part["thinking"] || part[:thinking] || part["text"] || part[:text]
      end.join("\n")
    end

    def message_content_text(content)
      case content
      when Array
        content.filter_map do |part|
          type = part["type"] || part[:type]
          if type == "text"
            part["text"] || part[:text]
          elsif type == "image"
            path = part["path"] || part[:path]
            media_type = part["media_type"] || part[:media_type] || part["mimeType"] || part[:mimeType] || "image"
            "[#{media_type}#{path ? ": #{path}" : ""}]"
          end
        end.join("\n")
      else
        content.to_s
      end
    end

    def synthetic_tool_call(name, id)
      {
        "id" => id || "restored_tool",
        "type" => "function",
        "function" => { "name" => name || "tool", "arguments" => "{}" }
      }
    end

    def message_role(message)
      return nil unless message.is_a?(Hash)

      message["role"] || message[:role]
    end

    def message_content(message)
      return nil unless message.is_a?(Hash)

      message["content"] || message[:content]
    end

    def message_name(message)
      message["name"] || message[:name]
    end

    def message_tool_call_id(message)
      message["tool_call_id"] || message[:tool_call_id]
    end

    def message_tool_calls(message)
      value = message["tool_calls"] || message[:tool_calls]
      value.is_a?(Array) ? value : []
    end

    def tool_call_id(tool_call)
      tool_call["id"] || tool_call[:id]
    end

    def tool_call_name(tool_call)
      function = tool_call["function"] || tool_call[:function] || {}
      function["name"] || function[:name] || "unknown_tool"
    end

    def tool_call_args(tool_call)
      function = tool_call["function"] || tool_call[:function] || {}
      parse_tool_arguments(function["arguments"] || function[:arguments])
    end

    def tool_command(tool_call)
      name = tool_call_name(tool_call)
      args = tool_call_args(tool_call)

      if name == "run_shell_command"
        args["command"] || args[:command] || ""
      elsif args.empty?
        name.to_s
      else
        "#{name} #{JSON.dump(args)}"
      end
    end

    def parse_tool_arguments(arguments)
      return {} if arguments.nil? || arguments.empty?
      return arguments if arguments.is_a?(Hash)

      JSON.parse(arguments)
    rescue JSON::ParserError
      {}
    end
  end
end
