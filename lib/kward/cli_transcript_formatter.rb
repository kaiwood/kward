require "base64"
require_relative "image_attachments"
require_relative "message_access"
require_relative "message_text"

# Namespace for the Kward CLI agent runtime.
module Kward
  # Formats conversation messages for terminal transcript display.
  module CLITranscriptFormatter
    module_function

    def reasoning(message)
      reasoning_blocks(message).join("\n")
    end

    def reasoning_blocks(message)
      response_blocks = response_items(message).flat_map do |item|
        next [] unless MessageAccess.value(item, :type) == "reasoning"

        summary = response_item_text_parts(MessageAccess.value(item, :summary))
        summary.empty? ? response_item_text_parts(MessageAccess.value(item, :content)) : summary
      end
      return response_blocks unless response_blocks.empty?

      content = MessageAccess.content(message)
      if content.is_a?(Array)
        blocks = content.filter_map do |part|
          type = MessageAccess.value(part, :type)
          next unless ["thinking", "reasoning"].include?(type)

          MessageAccess.value(part, :thinking) || MessageAccess.value(part, :reasoning) || MessageAccess.value(part, :text)
        end.map(&:to_s).reject(&:empty?)
        return blocks unless blocks.empty?
      end

      direct = MessageAccess.value(message, :reasoning_summary).to_s
      direct.empty? ? [] : [direct]
    end

    def content_text(content)
      case content
      when Array
        content.filter_map { |part| content_part_text(part) }.join("\n")
      else
        content.to_s
      end
    end

    def assistant_content_text(message)
      text = content_text(MessageAccess.content(message))
      return text unless text.empty?

      response_items(message).filter_map do |item|
        next unless MessageAccess.value(item, :type) == "message"
        next if MessageAccess.value(item, :phase).to_s == "commentary"

        response_item_text(MessageAccess.value(item, :content))
      end.join
    end

    def user_display_text(message)
      display_content = MessageAccess.display_content(message)
      return display_content.to_s unless display_content.nil?

      content = MessageAccess.content(message)
      return content.to_s unless content.is_a?(Array)

      text = content.filter_map do |part|
        next unless MessageAccess.value(part, :type) == "text"

        MessageAccess.value(part, :text)
      end.join("\n")
      ImageAttachments.display_text_without_references(text, ImageAttachments.references_from_text(text).select { |reference| reference[:status] == :attached })
    end

    def user_transcript_input(message)
      content = MessageAccess.content(message)
      return content.to_s unless content.is_a?(Array)

      user_display_text(message)
    end

    def image_parts(message)
      content = MessageAccess.content(message)
      return [] unless content.is_a?(Array)

      content.select { |part| MessageAccess.value(part, :type) == "image" }
    end

    def image_references(message)
      image_parts(message).map { |part| image_part_reference(part) }
    end

    def synthetic_tool_call(name, id)
      {
        "id" => id || "restored_tool",
        "type" => "function",
        "function" => { "name" => name || "tool", "arguments" => "{}" }
      }
    end

    def full_text(message)
      MessageText.full_text(message)
    end

    def content_part_text(part)
      type = MessageAccess.value(part, :type)
      if type == "text"
        MessageAccess.value(part, :text)
      elsif type == "image"
        path = MessageAccess.value(part, :path)
        media_type = MessageAccess.value(part, :media_type) || MessageAccess.value(part, :mimeType) || "image"
        "[#{media_type}#{path ? ": #{path}" : ""}]"
      end
    end

    def response_items(message)
      MessageAccess.response_items(message)
    end

    def response_item_text(parts)
      response_item_text_parts(parts).join
    end

    def response_item_text_parts(parts)
      Array(parts).filter_map do |part|
        next unless part.is_a?(Hash)

        MessageAccess.value(part, :text) || MessageAccess.value(part, :refusal)
      end.map(&:to_s).reject(&:empty?)
    end

    def image_part_reference(part)
      data = MessageAccess.value(part, :data)
      path = MessageAccess.value(part, :path)
      media_type = MessageAccess.value(part, :media_type) || MessageAccess.value(part, :mimeType) || "image"
      {
        status: :attached,
        type: "image",
        label: path.to_s.empty? ? "pasted image" : File.basename(path),
        media_type: media_type,
        size_bytes: decoded_image_size(data),
        path: path
      }
    end

    def decoded_image_size(data)
      return nil if data.to_s.empty?

      Base64.decode64(data.to_s.gsub(/\s+/, "")).bytesize
    rescue ArgumentError
      nil
    end
  end
end
