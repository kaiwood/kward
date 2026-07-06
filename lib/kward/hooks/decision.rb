# Namespace for the Kward CLI agent runtime.
module Kward
  module Hooks
    # Normalized result returned by lifecycle hooks.
    class Decision
      VALID_DECISIONS = %w[allow deny ask modify warn retry defer].freeze

      attr_reader :decision, :message, :payload, :metadata

      def initialize(decision:, message: nil, payload: nil, metadata: nil)
        @decision = decision.to_s
        raise ArgumentError, "Unknown hook decision: #{@decision}" unless VALID_DECISIONS.include?(@decision)

        @message = message&.to_s
        @payload = payload || {}
        @metadata = metadata || {}
      end

      def self.allow(message = nil, metadata: nil)
        new(decision: "allow", message: message, metadata: metadata)
      end

      def self.deny(message = nil, metadata: nil)
        new(decision: "deny", message: message, metadata: metadata)
      end

      def self.ask(message = nil, metadata: nil)
        new(decision: "ask", message: message, metadata: metadata)
      end

      def self.modify(payload, message: nil, metadata: nil)
        new(decision: "modify", message: message, payload: payload, metadata: metadata)
      end

      def self.warn(message = nil, metadata: nil)
        new(decision: "warn", message: message, metadata: metadata)
      end

      def self.retry(message = nil, payload: nil, metadata: nil)
        new(decision: "retry", message: message, payload: payload, metadata: metadata)
      end

      def self.defer(message = nil, payload: nil, metadata: nil)
        new(decision: "defer", message: message, payload: payload, metadata: metadata)
      end

      def self.normalize(value)
        case value
        when nil
          allow
        when Decision
          value
        when String, Symbol
          new(decision: value)
        when Hash
          new(
            decision: value[:decision] || value["decision"] || "allow",
            message: value[:message] || value["message"],
            payload: value[:payload] || value["payload"],
            metadata: value[:metadata] || value["metadata"]
          )
        else
          raise ArgumentError, "Invalid hook decision: #{value.inspect}"
        end
      end

      def allow?
        decision == "allow"
      end

      def deny?
        decision == "deny"
      end

      def ask?
        decision == "ask"
      end

      def modify?
        decision == "modify"
      end

      def warning?
        decision == "warn"
      end

      def blocking?
        deny? || ask?
      end

      def to_h
        {
          decision: decision,
          message: message,
          payload: payload,
          metadata: metadata
        }
      end
    end
  end
end
