# Namespace for the Kward CLI agent runtime.
module Kward
  # Shared path containment predicate for local filesystem guardrails.
  module PathGuard
    module_function

    def inside?(path, root)
      path = path.to_s
      root = root.to_s
      path == root || path.start_with?(root + File::SEPARATOR)
    end
  end
end
