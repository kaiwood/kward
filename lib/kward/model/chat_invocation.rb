# Namespace for the Kward CLI agent runtime.
module Kward
  # Thin adapter that invokes the configured model client.
  module ChatInvocation
    module_function

    KEYWORD_PARAMETER_TYPES = [:key, :keyreq].freeze

    def call(client, messages, keywords)
      client.chat(messages, **supported_keywords(client, keywords))
    end

    def supported_keywords(client, keywords)
      parameters = client.method(:chat).parameters
      return keywords if parameters.any? { |type, _name| type == :keyrest }

      supported = parameters.each_with_object({}) do |(type, name), names|
        names[name] = true if KEYWORD_PARAMETER_TYPES.include?(type)
      end
      keywords.select { |name, _value| supported.key?(name) }
    rescue NameError
      keywords
    end
  end
end
