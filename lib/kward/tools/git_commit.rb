require_relative "base"

# Namespace for model-callable tool wrappers.
module Kward
  module Tools
    # Tool wrapper for the trusted host-side Git commit operation.
    class GitCommit < Base
      def initialize(committer:)
        @committer = committer
        super(
          "git_commit",
          "Stage and commit changes in the active worktree. Omit paths to include all current changes.",
          properties: {
            message: { type: "string", description: "Commit message." },
            paths: { type: "array", items: { type: "string" }, description: "Optional workspace-relative paths to include." }
          },
          required: ["message"]
        )
      end

      def call(args, _conversation, cancellation: nil)
        cancellation&.raise_if_cancelled!
        message = argument(args, :message, "").to_s
        paths = argument(args, :paths, nil)
        return "Error: commit message is required" if message.strip.empty?
        return "Error: paths must be an array" unless paths.nil? || paths.is_a?(Array)
        return "Error: paths must contain strings" if paths && paths.any? { |path| !path.is_a?(String) }

        paths = nil if paths&.empty?
        result = @committer.call(message: message, paths: paths)
        output = result[:output].to_s.strip
        return "Git commit succeeded\n#{output}" if result[:success]

        failure = output.empty? ? "Git commit failed." : "Git commit failed.\n#{output}"
        "Error: #{failure}"
      end
    end
  end
end
