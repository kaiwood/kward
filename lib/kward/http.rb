require_relative "version"

# Namespace for the Kward CLI agent runtime.
module Kward
  # Shared HTTP request headers for Kward-owned network traffic.
  module Http
    module_function

    def user_agent
      "Kward/#{VERSION}"
    end

    def apply_user_agent(request)
      request["User-Agent"] = user_agent
      request
    end
  end
end
