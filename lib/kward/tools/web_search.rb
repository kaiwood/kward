require_relative "base"
require_relative "search/web"

# Namespace for the Kward CLI agent runtime.
module Kward
  # Model-callable tool wrappers and their argument schemas.
  module Tools
    # Live web-search implementation with provider fallbacks.
    class WebSearch < Base
      # Builds the tool schema and stores the execution dependency.
      def initialize(web_search:)
        @web_search = web_search
        super(
          "web_search",
          "Search the live web with bounded results.",
          properties: {
            queries: {
              type: "array",
              description: "1-4 distinct queries; avoid near-duplicates.",
              items: { type: "string" },
              minItems: 1,
              maxItems: 4
            },
            max_results: {
              type: "integer",
              description: "Results per query; default 5, max 20."
            },
            provider: {
              type: "string",
              enum: Kward::WebSearch::PROVIDERS,
              description: "Provider override; default auto."
            },
            recency_filter: {
              type: "string",
              enum: %w[day week month year],
              description: "Recency filter."
            },
            domain_filter: {
              type: "array",
              description: "Domains to include; prefix '-' to exclude.",
              items: { type: "string" }
            }
          },
          required: ["queries"]
        )
      end

      # Executes the tool and returns model-facing output text.
      def call(args, _conversation, cancellation: nil)
        return @web_search.search(args) unless cancellation

        @web_search.search(args, cancellation: cancellation)
      end
    end
  end
end
