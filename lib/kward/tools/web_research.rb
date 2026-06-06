require_relative "base"

module Kward
  module Tools
    class WebResearch < Base
      def initialize(web_research:)
        @web_research = web_research
        super(
          "web_research",
          "Search the live web when web research is enabled or configured. Auto mode uses Exa first, optional model-backed providers only when allowed, then legacy DuckDuckGo/SearXNG.",
          properties: {
            queries: {
              type: "array",
              description: "One to four distinct web research queries. Prefer varied angles over near-duplicates.",
              items: { type: "string" },
              minItems: 1,
              maxItems: 4
            },
            max_results: {
              type: "integer",
              description: "Optional maximum results per query. Defaults to 5 and is capped at 20."
            },
            provider: {
              type: "string",
              enum: %w[auto exa perplexity gemini legacy duckduckgo],
              description: "Optional provider override. Defaults to auto."
            },
            recency_filter: {
              type: "string",
              enum: %w[day week month year],
              description: "Optional recency filter."
            },
            domain_filter: {
              type: "array",
              description: "Optional domains to include, or prefix with '-' to exclude.",
              items: { type: "string" }
            }
          },
          required: ["queries"]
        )
      end

      def call(args, _conversation, cancellation: nil)
        @web_research.search(args)
      end
    end
  end
end
