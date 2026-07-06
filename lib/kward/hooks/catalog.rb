# Namespace for the Kward CLI agent runtime.
module Kward
  module Hooks
    # Known lifecycle hook events and their safety defaults.
    module Catalog
      DEFAULT_FAILURE_POLICY = "warn"
      VALID_FAILURE_POLICIES = %w[allow warn deny ask].freeze

      EventDefinition = Struct.new(:name, :failure_policy, :modifiable_fields, keyword_init: true)

      DEFINITIONS = [
        EventDefinition.new(name: "turn_start", failure_policy: "warn", modifiable_fields: %w[input display_input]),
        EventDefinition.new(name: "turn_context_build_before", failure_policy: "warn"),
        EventDefinition.new(name: "turn_context_build_after", failure_policy: "warn"),
        EventDefinition.new(name: "model_request_before", failure_policy: "warn", modifiable_fields: %w[messages tools provider model reasoning]),
        EventDefinition.new(name: "turn_model_request_before", failure_policy: "warn"),
        EventDefinition.new(name: "model_response_after_parse", failure_policy: "warn"),
        EventDefinition.new(name: "turn_model_response_complete", failure_policy: "warn"),
        EventDefinition.new(name: "turn_end", failure_policy: "warn"),
        EventDefinition.new(name: "tool_call_before", failure_policy: "deny", modifiable_fields: %w[arguments]),
        EventDefinition.new(name: "tool_call_after", failure_policy: "warn"),
        EventDefinition.new(name: "tool_call_error", failure_policy: "warn"),
        EventDefinition.new(name: "shell_command_before", failure_policy: "deny", modifiable_fields: %w[command timeout_seconds]),
        EventDefinition.new(name: "shell_command_after", failure_policy: "warn"),
        EventDefinition.new(name: "file_change_after", failure_policy: "warn")
      ].each_with_object({}) { |definition, result| result[definition.name] = definition }.freeze

      module_function

      def event_names
        DEFINITIONS.keys.sort
      end

      def definition(event_name)
        DEFINITIONS[event_name.to_s]
      end

      def known?(event_name)
        DEFINITIONS.key?(event_name.to_s)
      end

      def failure_policy(event_name, explicit_policy = nil)
        normalize_failure_policy(explicit_policy || definition(event_name)&.failure_policy || DEFAULT_FAILURE_POLICY)
      end

      def normalize_failure_policy(policy)
        value = policy.to_s
        return value if VALID_FAILURE_POLICIES.include?(value)

        raise ArgumentError, "Unknown hook failure policy: #{policy}"
      end

      def failure_decision(policy, message, metadata: nil)
        case normalize_failure_policy(policy)
        when "allow"
          Decision.allow(message, metadata: metadata)
        when "warn"
          Decision.warn(message, metadata: metadata)
        when "deny"
          Decision.deny(message, metadata: metadata)
        when "ask"
          Decision.ask(message, metadata: metadata)
        end
      end
    end
  end
end
