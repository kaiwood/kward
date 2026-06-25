# Namespace for the Kward CLI agent runtime.
module Kward
  # Tracks approximate context bytes saved by tool budgeting during one process.
  class ContextBudgetMeter
    Snapshot = Struct.new(:calls, :original_bytes, :returned_bytes, :saved_bytes, :tool_breakdown, keyword_init: true)

    def initialize
      @mutex = Mutex.new
      @calls = 0
      @original_bytes = 0
      @returned_bytes = 0
      @tool_breakdown = Hash.new { |hash, key| hash[key] = { calls: 0, originalBytes: 0, returnedBytes: 0, savedBytes: 0 } }
    end

    def record(tool_name:, original_bytes:, returned_bytes:)
      original_bytes = original_bytes.to_i
      returned_bytes = returned_bytes.to_i
      saved_bytes = [original_bytes - returned_bytes, 0].max
      @mutex.synchronize do
        @calls += 1
        @original_bytes += original_bytes
        @returned_bytes += returned_bytes
        entry = @tool_breakdown[tool_name.to_s]
        entry[:calls] += 1
        entry[:originalBytes] += original_bytes
        entry[:returnedBytes] += returned_bytes
        entry[:savedBytes] += saved_bytes
      end
      saved_bytes
    end

    def snapshot
      @mutex.synchronize do
        Snapshot.new(
          calls: @calls,
          original_bytes: @original_bytes,
          returned_bytes: @returned_bytes,
          saved_bytes: [@original_bytes - @returned_bytes, 0].max,
          tool_breakdown: @tool_breakdown.transform_values(&:dup)
        )
      end
    end
  end
end
