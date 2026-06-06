module Kward
  module Tools
    class Base
      attr_reader :name

      def initialize(name, description, properties: {}, required: [])
        @name = name
        @description = description
        @properties = properties
        @required = required
      end

      def schema
        {
          type: "function",
          function: {
            name: @name,
            description: @description,
            parameters: {
              type: "object",
              properties: @properties,
              required: @required,
              additionalProperties: false
            }
          }
        }
      end

      private

      def argument(args, key, default = nil)
        return args[key] if args.key?(key)
        return args[key.to_s] if args.key?(key.to_s)

        default
      end

      def agents_file_changed?(workspace, path, result)
        result.to_s.start_with?("Wrote ", "Edited ") && File.basename(path.to_s) == "AGENTS.md" && workspace.resolved_path(path) == File.join(workspace.root.to_s, "AGENTS.md")
      rescue StandardError
        false
      end
    end
  end
end
