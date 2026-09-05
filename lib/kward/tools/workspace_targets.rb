# Namespace for the Kward CLI agent runtime.
module Kward
  # Model-callable tool wrappers and their argument schemas.
  module Tools
    # Resolves a small host-scoped set of workspace roles for local tools.
    # Target names are supplied by trusted runtime orchestration, never by the
    # model, so selecting a target cannot escape into an arbitrary filesystem
    # path.
    class WorkspaceTargets
      ACTIVE = "active"

      def initialize(active:, targets: {})
        @workspaces = { ACTIVE => active }
        targets.each do |name, workspace|
          name = name.to_s
          raise ArgumentError, "Workspace target name is required" if name.empty?
          raise ArgumentError, "Workspace target #{ACTIVE.inspect} is reserved" if name == ACTIVE

          @workspaces[name] = workspace
        end
        @workspaces.freeze
      end

      def workspace_for(args)
        @workspaces.fetch(target_name(args)) do |name|
          raise ArgumentError, "Unknown workspace target: #{name}"
        end
      end

      def target_name(args)
        value = if args.respond_to?(:key?)
                  args[:target] || args["target"]
                end
        value.to_s.empty? ? ACTIVE : value.to_s
      end

      def valid?(args)
        @workspaces.key?(target_name(args))
      end

      def properties(properties)
        return properties if @workspaces.length == 1

        properties.merge(
          target: {
            type: "string",
            enum: @workspaces.keys,
            description: "Workspace role. Defaults to active; origin is the host repository worktree."
          }
        )
      end

      def without_target(args)
        args.reject { |key, _value| key.to_s == "target" }
      end
    end
  end
end
