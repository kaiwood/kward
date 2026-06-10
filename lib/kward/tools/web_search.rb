require_relative "base"

module Kward
  module Tools
    class WebSearch < Base
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
              enum: %w[auto exa perplexity gemini legacy duckduckgo],
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

      def call(args, _conversation, cancellation: nil)
        @web_search.search(args)
      end
    end
  end
end
