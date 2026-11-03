require_relative "../message_access"
require_relative "../terminal/text"

module Kward
  # Shared plain-text presentation for terminal and exported turn summaries.
  class TurnSummaryFormatter
    def self.render(summary, mode: "compact", width: nil)
      return "" unless summary.is_a?(Hash) && mode != "off"

      new(summary).render(mode: mode, width: width)
    end

    def initialize(summary)
      @summary = summary
    end

    def render(mode:, width:)
      status = { "completed" => "Completed", "failed" => "Failed", "canceled" => "Cancelled" }.fetch(value(:status), "Finished")
      parts = [status, format("%.1fs", value(:elapsedMs).to_f / 1_000), token_text]
      parts << count_text(value(:modelRequests), "model request") if mode == "detailed"
      parts << count_text(value(:toolCalls), "tool call")
      lines = [fit(parts, width)]
      if mode == "detailed" && usage.is_a?(Hash)
        details = [
          token_detail(:input_tokens, "Input"),
          cached_detail,
          token_detail(:output_tokens, "Output"),
          token_detail(:reasoning_tokens, "Reasoning"),
          token_detail(:cache_write_tokens, "Cache writes")
        ].compact
        lines << fit(details, width) unless details.empty?
      end
      lines.join("\n")
    end

    private

    def value(key)
      MessageAccess.value(@summary, key)
    end

    def usage
      value(:usage)
    end

    def token_text
      total = MessageAccess.value(usage, :total_tokens)
      return "tokens unavailable" if value(:usageStatus) == "unavailable" || total.nil?

      label = "#{number(total)} tokens"
      label = "~#{label}" if MessageAccess.value(usage, :estimated)
      label += " (partial)" if value(:usageStatus) == "partial"
      label
    end

    def token_detail(field, label)
      count = MessageAccess.value(usage, field)
      return if count.nil?

      text = "#{label} #{number(count)}"
      partial_field?(field) ? "#{text} (partial)" : text
    end

    def partial_field?(field)
      Array(MessageAccess.value(usage, :partial_fields)).include?(field.to_s)
    end

    def cached_detail
      text = token_detail(:cache_read_tokens, "Cached")
      return unless text

      input = MessageAccess.value(usage, :input_tokens).to_f
      cached = MessageAccess.value(usage, :cache_read_tokens).to_f
      if value(:usageStatus) == "complete" && !partial_field?(:input_tokens) && !partial_field?(:cache_read_tokens) && input.positive? && cached <= input
        text += format(" (%.0f%%)", 100 * cached / input)
      end
      text
    end

    def number(value)
      value.to_f >= 1_000 ? format("%.1fk", value.to_f / 1_000) : value.to_i.to_s
    end

    def count_text(count, noun)
      "#{count.to_i} #{noun}#{count.to_i == 1 ? '' : 's'}"
    end

    def fit(parts, width)
      parts.pop while width && parts.length > 1 && TerminalText.width(parts.join(" · ")) > width
      parts.join(" · ")
    end
  end
end
