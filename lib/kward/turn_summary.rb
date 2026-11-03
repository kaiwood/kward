require_relative "message_access"

module Kward
  # Collects reported usage for the main agent loop, independently of compaction
  # and other auxiliary model calls. Missing usage is never treated as zero.
  class TurnSummary
    TOKEN_FIELDS = %w[input_tokens output_tokens total_tokens cache_read_tokens cache_write_tokens reasoning_tokens].freeze

    def initialize
      @model_requests = 0
      @tool_calls = 0
      @reported_requests = 0
      @usage = {}
      @field_requests = Hash.new(0)
      @estimated = false
      @retried = false
    end

    def model_request
      @model_requests += 1
    end

    def tool_call
      @tool_calls += 1
    end

    def retry
      @retried = true
    end

    def record(message)
      usage = MessageAccess.value(message, :usage)
      return unless usage.is_a?(Hash)

      total = MessageAccess.value(usage, :total_tokens)
      @reported_requests += 1 if total.is_a?(Numeric) && total >= 0
      TOKEN_FIELDS.each do |field|
        value = MessageAccess.value(usage, field.to_sym)
        next unless value.is_a?(Numeric) && value >= 0

        @usage[field] = @usage.fetch(field, 0) + value
        @field_requests[field] += 1
      end
      @estimated ||= MessageAccess.value(usage, :estimated) == true
    end

    def finish(status:, elapsed_ms:)
      usage_status = if @reported_requests.zero?
        "unavailable"
      elsif @reported_requests == @model_requests && !@retried
        "complete"
      else
        "partial"
      end
      usage = @usage.merge("estimated" => @estimated)
      partial_fields = @usage.keys.reject { |field| @field_requests[field] == @model_requests && !@retried }
      usage["partial_fields"] = partial_fields unless partial_fields.empty?
      {
        "status" => status,
        "elapsedMs" => elapsed_ms,
        "modelRequests" => @model_requests,
        "toolCalls" => @tool_calls,
        "usageStatus" => usage_status,
        "usage" => @usage.empty? ? nil : usage
      }
    end
  end
end
