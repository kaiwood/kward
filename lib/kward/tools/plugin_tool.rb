require_relative "base"

# Namespace for the Kward CLI agent runtime.
module Kward
  # Model-callable tool wrappers and their argument schemas.
  module Tools
    # Adapts a trusted plugin tool registration to the normal tool interface.
    class PluginTool < Base
      attr_reader :plugin_path

      def initialize(registration:, context_factory:)
        @description = registration.description
        @parameters = registration.schema
        @plugin_path = registration.path
        @handler = registration.handler
        @context_factory = context_factory
        super(registration.name, registration.description)
      end

      # Returns the strict JSON schema declared by the plugin.
      def schema
        {
          type: "function",
          function: {
            name: name,
            description: @description,
            parameters: @parameters
          }
        }
      end

      # Executes trusted plugin code with parsed model arguments and scoped context.
      def call(args, conversation, cancellation: nil)
        context = @context_factory.call(conversation, cancellation)
        result = @handler.call(args, context)
        cancellation&.raise_if_cancelled!
        result.to_s
      end
    end
  end
end
