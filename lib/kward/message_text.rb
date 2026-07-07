require_relative "message_access"

# Namespace for the Kward CLI agent runtime.
module Kward
  # Builds user-visible plain text from persisted conversation messages.
  #
  # Conversations may store one value for the model and another value for the UI.
  # Prompt templates, for example, keep expanded instructions in `content` while
  # preserving the submitted slash command in `display_content`. This helper keeps
  # tree navigation, forks, copy/export features, and RPC payloads aligned on the
  # same visible text rules.
  module MessageText
    module_function

    # Returns the plain text a user should see or edit for a message.
    #
    # User messages prefer `display_content`/`displayContent` when present. Other
    # messages, and user messages without display text, are reduced from their
    # stored content. Array content contributes only textual parts so image and
    # tool-call blocks do not leak implementation details into editable text.
    #
    # @param message [Hash] persisted conversation message
    # @return [String] stripped visible text
    def full_text(message)
      display_content = MessageAccess.display_content(message)
      return display_content.to_s.strip unless display_content.nil?

      content_text(MessageAccess.content(message)).strip
    end

    # Returns compact one-line text for session tree and list previews.
    #
    # @param message [Hash] persisted conversation message
    # @param length [Integer] maximum preview length
    # @return [String] whitespace-normalized text, truncated with ellipsis
    def preview(message, length: 120)
      text = if MessageAccess.role(message) == "compactionSummary"
               MessageAccess.summary(message).to_s
             else
               full_text(message)
             end
      truncate_preview(text, length: length)
    end

    # Converts message content into plain text without applying display-content
    # overrides.
    #
    # @param content [String, Array<Hash>, nil] message content field
    # @return [String] textual content joined with newlines
    def content_text(content)
      case content
      when Array
        content.filter_map { |part| MessageAccess.value(part, :text) }.join("\n")
      else
        content.to_s
      end
    end

    def truncate_preview(text, length: 120)
      normalized = text.to_s.gsub(/\s+/, " ").strip
      normalized.length > length ? "#{normalized.slice(0, length - 3)}..." : normalized
    end
  end
end
