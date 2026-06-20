require_relative "base"

# Namespace for the Kward CLI agent runtime.
module Kward
  # Model-callable tool wrappers and their argument schemas.
  module Tools
    # Retrieves original tool outputs that were compacted out of model context.
    class RetrieveToolOutput < Base
      DEFAULT_LIMIT = 120

      # Builds the retrieval tool schema.
      def initialize
        super(
          "retrieve_tool_output",
          "Retrieve original output from a compacted previous tool result.",
          properties: {
            id: { type: "string", description: "Tool output id, for example toolout_abc123." },
            query: { type: "string", description: "Optional case-insensitive text search within the original output." },
            offset: { type: "integer", description: "1-indexed line offset for returned output." },
            limit: { type: "integer", description: "Maximum lines to return; default 120." }
          },
          required: ["id"]
        )
      end

      # Executes retrieval from the active conversation artifact store.
      def call(args, conversation, cancellation: nil)
        cancellation&.raise_if_cancelled!
        id = argument(args, :id, "").to_s
        return "Error: id is required" if id.empty?

        artifact = conversation.tool_output_artifacts[id]
        return "Error: unknown tool output id: #{id}" unless artifact

        content = artifact[:content].to_s
        query = argument(args, :query, "").to_s
        lines = query.empty? ? content.split("\n", -1) : matching_lines(content, query)
        return "No matching lines for #{query.inspect} in #{id}." if lines.empty?

        slice_lines(id, lines, offset: argument(args, :offset), limit: argument(args, :limit), query: query)
      end

      private

      def matching_lines(content, query)
        needle = query.downcase
        content.split("\n", -1).each_with_index.filter_map do |line, index|
          next unless line.downcase.include?(needle)

          "#{index + 1}: #{line}"
        end
      end

      def slice_lines(id, lines, offset:, limit:, query:)
        start_index = [offset.to_i - 1, 0].max
        return "Error: offset #{offset} is beyond output (#{lines.length} lines total)" if start_index >= lines.length

        line_limit = limit.to_i.positive? ? limit.to_i : DEFAULT_LIMIT
        selected = lines[start_index, line_limit] || []
        header = "[Retrieved tool output #{id}"
        header << " matching #{query.inspect}" unless query.empty?
        header << ": lines #{start_index + 1}-#{start_index + selected.length} of #{lines.length}]"
        output = "#{header}\n#{selected.join("\n")}".rstrip
        if start_index + selected.length < lines.length
          output << "\n\n[#{lines.length - start_index - selected.length} more lines. Use offset=#{start_index + selected.length + 1} to continue.]"
        end
        output
      end
    end
  end
end
