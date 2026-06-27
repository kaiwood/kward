# Namespace for the Kward CLI agent runtime.
module Kward
  # Interactive terminal UI used by the CLI frontend.
  class PromptInterface
    # Incremental search state and operations for editor buffers.
    class EditorSearch
      attr_reader :query, :direction

      def initialize(direction: :forward)
        @active = false
        @query = +""
        @direction = direction
      end

      def active?
        @active == true
      end

      def begin(direction = :forward)
        @active = true
        @direction = direction
        @query = +""
        status_prefix
      end

      def cancel
        @active = false
        "Search cancelled"
      end

      def append(text)
        @query << text.to_s
        "#{status_prefix} #{@query}"
      end

      def delete_character
        @query = @query[0...-1].to_s
        "#{status_prefix} #{@query}"
      end

      def confirm(buffer:, cursor:)
        confirmed_query = @query.to_s
        @active = false
        return { status: "Search cancelled", found: false } if confirmed_query.empty?

        repeat(buffer: buffer, cursor: cursor, direction: @direction, query: confirmed_query)
      end

      def repeat(buffer:, cursor:, direction: @direction, query: @query)
        query = query.to_s
        return { status: "No previous search", found: false } if query.empty?

        @query = query
        @direction = direction
        index = if direction == :backward
          search_from = cursor.positive? ? cursor - 1 : buffer.length
          buffer.rindex(query, search_from) || buffer.rindex(query)
        else
          buffer.index(query, cursor + 1) || buffer.index(query)
        end

        if index
          { cursor: index, status: "Found: #{query}", found: true }
        else
          { status: "No match: #{query}", found: false }
        end
      end

      private

      def status_prefix
        @direction == :backward ? "Search backward:" : "Search:"
      end
    end
  end
end
