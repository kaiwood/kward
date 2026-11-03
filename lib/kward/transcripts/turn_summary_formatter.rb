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
        details = %i[input_tokens output_tokens].filter_map do |field|
          count = MessageAccess.value(usage, field)
          "#{field == :input_tokens ? 'Input' : 'Output'} #{number(count)}" unless count.nil?
        end
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
