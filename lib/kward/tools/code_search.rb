require_relative "base"

# Namespace for the Kward CLI agent runtime.
module Kward
  # Model-callable tool wrappers and their argument schemas.
  module Tools
    # Package lookup and GitHub repository cache/search implementation.
    class CodeSearch < Base
      # Builds the tool schema and stores the execution dependency.
      def initialize(code_search:)
        @code_search = code_search
        super(
          "code_search",
          "Find package repos, cache GitHub repos, and search/read bounded snippets.",
          properties: {
            action: {
              type: "string",
              enum: %w[package_search github_search repo_clone repo_search repo_read list_cache refresh_cache clear_cache],
              description: "Operation."
            },
            ecosystem: {
              type: "string",
              enum: %w[rubygems npm pypi crates go],
              description: "Package ecosystem."
            },
            package: {
              type: "string",
              description: "Package."
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
              description: "Repo-relative path; inferred from GitHub blob URLs when omitted."
            },
            ref: {
              type: "string",
              description: "Git branch, tag, or commit; inferred from GitHub blob URLs when omitted."
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

      # Executes the tool and returns model-facing output text.
      def call(args, _conversation, cancellation: nil)
        cancellation&.raise_if_cancelled!
        @code_search.call(args)
      end
    end
  end
end
