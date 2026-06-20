# Namespace for the Kward CLI agent runtime.
module Kward
  # Model-callable tool wrappers and their argument schemas.
  module Tools
    # Base class for model-callable tools and their JSON schemas.
    class Base
      # @return [String] function name exposed to the model
      attr_reader :name

      # Creates a tool schema definition shared by all concrete tool wrappers.
      def initialize(name, description, properties: {}, required: [])
        @name = name
        @description = description
        @properties = properties
        @required = required
      end

      # Returns the strict JSON schema advertised to model providers.
      def schema
        {
          type: "function",
          function: {
            name: @name,
            description: @description,
            parameters: {
              type: "object",
              properties: sorted_properties,
              required: @required.sort,
              additionalProperties: false
            }
          }
        }
      end

      private

      def sorted_properties
        @properties.keys.sort_by(&:to_s).each_with_object({}) do |key, result|
          result[key] = @properties[key]
        end
      end

      # Reads a tool argument while accepting symbol or string keys from restored calls.
      def argument(args, key, default = nil)
        return args[key] if args.key?(key)
        return args[key.to_s] if args.key?(key.to_s)

        default
      end

      # Detects successful AGENTS.md writes so callers can refresh prompt context.
      def agents_file_changed?(workspace, path, result)
        result.to_s.start_with?("Wrote ", "Edited ") && File.basename(path.to_s) == "AGENTS.md" && workspace.resolved_path(path) == File.join(workspace.root.to_s, "AGENTS.md")
      rescue StandardError
        false
      end
    end
  end
end
