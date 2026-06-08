require_relative "base"

module Kward
  module Tools
    class CodeSearch < Base
      def initialize(code_search:)
        @code_search = code_search
        super(
          "code_search",
          "Find package source repos, cache public GitHub repos, and search or read bounded source snippets.",
          properties: {
            action: {
              type: "string",
              enum: %w[package_search github_search repo_clone repo_search repo_read list_cache refresh_cache clear_cache],
              description: "Operation to perform."
            },
            ecosystem: {
              type: "string",
              enum: %w[rubygems npm pypi crates go ruby gem python rust crates.io],
              description: "Package ecosystem."
            },
            package: {
              type: "string",
              description: "Package name."
            },
            query: {
              type: "string",
              description: "Search query."
            },
            repo: {
              type: "string",
              description: "GitHub URL or owner/name."
            },
            path: {
              type: "string",
              description: "Repo-relative file path."
            },
            start_line: {
              type: "integer",
              description: "1-indexed start line."
            },
            line_count: {
              type: "integer",
              description: "Line count; capped."
            },
            max_results: {
              type: "integer",
              description: "Max results; capped at 50."
            },
            context_lines: {
              type: "integer",
              description: "Context lines; capped at 5."
            }
          },
          required: ["action"]
        )
      end

      def call(args, _conversation, cancellation: nil)
        cancellation&.raise_if_cancelled!
        @code_search.call(args)
      end
    end
  end
end
