module Kward
  module RPC
    module Redactor
      SECRET_KEYS = /(?:token|secret|api[_-]?key|authorization|password|credential)/i

      module_function

      def redact(value)
        case value
        when Hash
          value.each_with_object({}) do |(key, item), result|
            result[key] = key.to_s.match?(SECRET_KEYS) ? "[REDACTED]" : redact(item)
          end
        when Array
          value.map { |item| redact(item) }
        when String
          redact_string(value)
        else
          value
        end
      end

      def redact_string(value)
        value
          .gsub(/Bearer\s+[^\s"']+/i, "Bearer [REDACTED]")
          .gsub(/(sk-[A-Za-z0-9_-]{8,})/, "[REDACTED]")
      end
    end
  end
end
