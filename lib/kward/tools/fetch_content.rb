require_relative "base"
require_relative "search/web_fetch"

# Namespace for the Kward CLI agent runtime.
module Kward
  # Model-callable tool wrappers and their argument schemas.
  module Tools
    # Fetches a specific URL and extracts readable page content.
    class FetchContent < Base
      # Builds the tool schema and stores the execution dependency.
      def initialize(web_fetch:)
        @web_fetch = web_fetch
        super(
          "fetch_content",
          "Fetch a specific URL and extract readable bounded content.",
          properties: {
            url: {
              type: "string",
              description: "HTTP or HTTPS URL to fetch."
            },
            max_bytes: {
              type: "integer",
              description: "Maximum returned content bytes; default 16384, max 131072."
            },
            extract: {
              type: "string",
              enum: %w[auto text markdown],
              description: "Extraction mode; default auto."
            }
          },
          required: ["url"]
        )
      end

      # Executes the tool and returns model-facing output text.
      def call(args, _conversation, cancellation: nil)
        @web_fetch.fetch_content(args)
      end
    end
  end
end
