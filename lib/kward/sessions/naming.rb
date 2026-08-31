# Namespace for the Kward CLI agent runtime.
module Kward
  # Shared session-name formatting for CLI and RPC session auto-naming.
  module SessionNaming
    module_function

    def default_name(input)
      input.to_s.gsub(/\s+/, " ").strip.slice(0, 120).to_s
    end
  end
end
