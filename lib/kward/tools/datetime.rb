require "time"
require_relative "base"

# Namespace for the Kward CLI agent runtime.
module Kward
  # Model-callable date and time utilities.
  module Tools
    class DateTime < Base
      OFFSET_PATTERN = /\A(?:Z|[+-](?:0\d|1[0-4]):[0-5]\d)\z/.freeze
      TIMESTAMP_OFFSET_PATTERN = /(?:Z|[+-]\d{2}:?\d{2})\z/i.freeze

      def initialize
        super(
          "datetime",
          "Get the current date and time, or add signed whole seconds to an ISO 8601 timestamp. Current time uses the host's local timezone unless a UTC offset is supplied. Arithmetic preserves the timestamp's offset; offsets do not include daylight-saving rules.",
          properties: {
            operation: {
              type: "string",
              enum: %w[current_time add_seconds],
              description: "Operation to perform."
            },
            timezone_offset: {
              type: "string",
              description: "Optional UTC offset for current_time, formatted as +HH:MM, -HH:MM, or Z."
            },
            timestamp: {
              type: "string",
              description: "ISO 8601 timestamp with an explicit UTC offset, required for add_seconds."
            },
            seconds: {
              type: "integer",
              description: "Signed whole number of seconds to add, required for add_seconds."
            }
          },
          required: ["operation"]
        )
      end

      def call(args, _conversation, cancellation: nil)
        cancellation&.raise_if_cancelled!

        case argument(args, :operation)
        when "current_time"
          current_time(args)
        when "add_seconds"
          add_seconds(args)
        else
          "Error: operation must be current_time or add_seconds"
        end
      rescue ArgumentError, RangeError, TypeError => e
        "Error: #{e.message}"
      end

      private

      def current_time(args)
        offset = argument(args, :timezone_offset)
        time = Time.now
        time = time.getlocal(validated_offset(offset)) unless offset.nil?
        "Current date/time: #{time.iso8601}"
      end

      def add_seconds(args)
        timestamp = argument(args, :timestamp)
        seconds = argument(args, :seconds)
        unless timestamp.is_a?(String) && TIMESTAMP_OFFSET_PATTERN.match?(timestamp)
          raise ArgumentError, "timestamp must be an ISO 8601 string with a UTC offset"
        end
        raise ArgumentError, "seconds must be an integer" unless seconds.is_a?(Integer)

        "Result: #{(Time.iso8601(timestamp) + seconds).iso8601}"
      end

      def validated_offset(offset)
        outside_iso_range = offset.is_a?(String) &&
          offset.start_with?("+14:", "-14:") && offset[-2, 2] != "00"
        unless offset.is_a?(String) && OFFSET_PATTERN.match?(offset) && !outside_iso_range
          raise ArgumentError, "timezone_offset must be Z or an offset between -14:00 and +14:00"
        end

        offset == "Z" ? "+00:00" : offset
      end
    end
  end
end
