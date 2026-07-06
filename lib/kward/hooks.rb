require_relative "hooks/audit_log"
require_relative "hooks/catalog"
require_relative "hooks/decision"
require_relative "hooks/event"
require_relative "hooks/matcher"
require_relative "hooks/manager"
require_relative "hooks/command_handler"
require_relative "hooks/config_loader"

# Namespace for the Kward CLI agent runtime.
module Kward
  # Lifecycle hook primitives and dispatch helpers.
  module Hooks
  end
end
