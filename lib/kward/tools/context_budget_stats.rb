require_relative "base"

# Namespace for the Kward CLI agent runtime.
module Kward
  # Model-callable tool wrappers and their argument schemas.
  module Tools
    # Reports approximate context budget savings for the current process.
    class ContextBudgetStats < Base
      def initialize(context_budget_meter: nil)
        @context_budget_meter = context_budget_meter
        super(
          "context_budget_stats",
          "Return approximate per-session context budget savings from tool output compaction and deduplication.",
          properties: {},
          required: []
        )
      end

      def call(_args, conversation, cancellation: nil)
        cancellation&.raise_if_cancelled!
        meter = conversation.respond_to?(:context_budget_meter) ? conversation.context_budget_meter : @context_budget_meter
        return "Error: context budget stats are unavailable" unless meter

        snapshot = meter.snapshot
        lines = [
          "# Context budget stats",
          "- Calls: #{snapshot.calls}",
          "- Original bytes: #{snapshot.original_bytes}",
          "- Returned bytes: #{snapshot.returned_bytes}",
          "- Saved bytes: #{snapshot.saved_bytes}",
          "- Estimated tokens saved: #{estimated_tokens(snapshot.saved_bytes)}"
        ]
        lines.concat(tool_breakdown_lines(snapshot.tool_breakdown))
        lines.join("\n")
      end

      private

      def tool_breakdown_lines(tool_breakdown)
        return [] if tool_breakdown.empty?

        lines = ["", "## By tool"]
        tool_breakdown.sort_by { |tool, data| [-data[:savedBytes], tool] }.each do |tool, data|
          lines << "- #{tool}: #{data[:calls]} call(s), #{data[:savedBytes]} bytes saved, #{data[:returnedBytes]}/#{data[:originalBytes]} bytes returned"
        end
        lines
      end

      def estimated_tokens(bytes)
        (bytes.to_i / 4.0).ceil
      end
    end
  end
end
