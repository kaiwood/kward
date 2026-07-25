# Namespace for the Kward CLI agent runtime.
module Kward
  # JSON-RPC backend namespace used by UI clients.
  module RPC
    # Redacts sensitive configuration values before RPC responses.
    module Redactor
      SECRET_KEYS = /(?:token|secret|api[_-]?key|authorization|password|credential)/i

      module_function

      def redact(value)
        case value
        when Hash
          value.each_with_object({}) do |(key, item), result|
            if token_count_key?(key.to_s) && item.is_a?(Numeric)
              result[key] = item
            elsif secret_key?(key)
              result[key] = "[REDACTED]"
            else
              result[key] = redact(item)
            end
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

      def secret_key?(key)
        text = key.to_s
        return false if ["apiKeyProviders", "privateCredentialStorage", "storedCredentialType"].include?(text)

        text.match?(SECRET_KEYS)
      end

      def token_count_key?(key)
        key.match?(/\A(?:input|output|cache_read|cache_write|total)_tokens\z/) || key == "estimated"
      end
    end
  end
end
