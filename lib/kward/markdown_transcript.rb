require_relative "message_access"

module Kward
  class MarkdownTranscript
    def initialize(conversation)
      @conversation = conversation
    end

    def render
      lines = ["# Kward Session", ""]
      @conversation.messages.each do |message|
        role = MessageAccess.role(message)
        next if role == "system"

        lines << "## #{role.to_s.capitalize}"
        name = MessageAccess.name(message)
        lines << "Tool: `#{name}`" if role == "tool" && name
        lines << ""
        lines << markdown_content(message_markdown_content(message, role))
        lines << ""
      end
      lines.join("\n")
    end

    private

    def message_markdown_content(message, role)
      if role == "compactionSummary"
        MessageAccess.value(message, :summary)
      elsif role == "user"
        message_display_text(message)
      else
        MessageAccess.content(message)
      end
    end

    def message_display_text(message)
      display_content = MessageAccess.value(message, :display_content) || MessageAccess.value(message, :displayContent)
      return display_content.to_s unless display_content.nil?

      markdown_content(MessageAccess.content(message))
    end

    def markdown_content(content)
      case content
      when Array
        content.filter_map { |part| markdown_content_part(part) }.join("\n")
      else
        content.to_s
      end
    end

    def markdown_content_part(part)
      return part.to_s unless part.respond_to?(:key?)

      type = MessageAccess.value(part, :type).to_s
      case type
      when "text"
        MessageAccess.value(part, :text)
      when "image"
        path = MessageAccess.value(part, :path)
        media_type = MessageAccess.value(part, :mimeType) || MessageAccess.value(part, :media_type) || "image"
        "[#{media_type}#{path ? ": #{path}" : ""}]"
      when "thinking", "reasoning"
        thinking = MessageAccess.value(part, :thinking) || MessageAccess.value(part, :reasoning) || MessageAccess.value(part, :text)
        thinking.to_s.empty? ? nil : "Reasoning:\n#{thinking}"
      else
        MessageAccess.value(part, :text)
      end
    end
  end
end
