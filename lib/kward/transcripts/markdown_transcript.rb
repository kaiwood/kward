require_relative "../message_access"
require_relative "../message_text"

# Namespace for the Kward CLI agent runtime.
module Kward
  # Markdown renderer for conversation transcripts.
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
      return MessageText.full_text(message) unless MessageAccess.display_content(message).nil?

      content = MessageAccess.content(message)
      content.is_a?(Array) ? markdown_content(content) : MessageText.full_text(message)
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
