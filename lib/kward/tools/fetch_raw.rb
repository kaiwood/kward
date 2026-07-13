require_relative "base"
require_relative "search/web_fetch"

# Namespace for the Kward CLI agent runtime.
module Kward
  # Model-callable tool wrappers and their argument schemas.
  module Tools
    # Fetches bounded raw content from a specific URL.
    class FetchRaw < Base
      # Builds the tool schema and stores the execution dependency.
      def initialize(web_fetch:)
        @web_fetch = web_fetch
        super(
          "fetch_raw",
          "Fetch bounded raw content from a specific URL.",
          properties: {
            url: {
              type: "string",
              description: "HTTP or HTTPS URL to fetch."
            },
            max_bytes: {
              type: "integer",
              description: "Maximum returned content bytes; default 16384, max 131072."
            },
            accept: {
              type: "string",
              description: "Optional HTTP Accept header."
            }
          },
          required: ["url"]
        )
      end

      # Executes the tool and returns model-facing output text.
      def call(args, _conversation, cancellation: nil)
        return @web_fetch.fetch_raw(args) unless cancellation

        @web_fetch.fetch_raw(args, cancellation: cancellation)
      end
    end
  end
end
