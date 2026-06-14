require "base64"
require_relative "../tools/tool_call"

# Namespace for the Kward CLI agent runtime.
module Kward
  # JSON-RPC backend namespace used by UI clients.
  module RPC
    # Validates and normalizes RPC image attachments.
    class AttachmentNormalizer
      IMAGE_MIME_TYPES = ["image/png", "image/jpeg", "image/gif", "image/webp"].freeze
      MAX_BYTES = 10 * 1024 * 1024

      def initialize(max_bytes: MAX_BYTES, mime_types: IMAGE_MIME_TYPES)
        @max_bytes = max_bytes
        @mime_types = mime_types
      end

      def normalize(attachments)
        return [] if attachments.nil?
        raise ArgumentError, "attachments must be an array" unless attachments.is_a?(Array)

        attachments.map { |attachment| normalize_attachment(attachment) }
      end

      private

      def normalize_attachment(attachment)
        raise ArgumentError, "attachment must be an object" unless attachment.is_a?(Hash)

        type = ToolCall.value(attachment, :type).to_s
        raise ArgumentError, "Unsupported attachment type: #{type.empty? ? "unknown" : type}" unless type == "image"

        mime_type = normalize_mime_type(ToolCall.value(attachment, :mimeType) || ToolCall.value(attachment, :mime_type) || ToolCall.value(attachment, :media_type))
        raise ArgumentError, "Unsupported image MIME type: #{mime_type.empty? ? "unknown" : mime_type}" unless @mime_types.include?(mime_type)

        data = ToolCall.value(attachment, :data).to_s
        raise ArgumentError, "Image attachment data must be valid base64" if data.empty?
        raise ArgumentError, "Image attachment data must be raw base64" if data.start_with?("data:")
        declared_size = ToolCall.value(attachment, :sizeBytes) || ToolCall.value(attachment, :size_bytes)
        raise ArgumentError, "Image attachment is too large" if declared_size && declared_size.to_i > @max_bytes

        decoded_size = Base64.strict_decode64(data).bytesize
        raise ArgumentError, "Image attachment is too large" if decoded_size > @max_bytes

        result = { type: "image", data: data, mimeType: mime_type }
        name = ToolCall.value(attachment, :name)
        result[:alt] = name.to_s unless name.to_s.empty?
        result
      rescue ArgumentError => e
        raise e if e.message.start_with?("Unsupported", "Image attachment", "attachment")

        raise ArgumentError, "Image attachment data must be valid base64"
      end

      def normalize_mime_type(mime_type)
        mime_type.to_s.downcase
      end
    end
  end
end
