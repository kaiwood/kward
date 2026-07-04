# Namespace for the Kward CLI agent runtime.
module Kward
  # Interactive terminal UI used by the CLI frontend.
  class PromptInterface
    # Incremental search state and operations for editor buffers.
    class EditorSearch
      attr_reader :query, :direction

      def self.match_ranges(text, query, base_offset: 0)
        query = query.to_s
        return [] if query.empty?

        haystack, needle = normalized_pair(text.to_s, query)
        ranges = []
        start = 0
        while (index = haystack.index(needle, start))
          ranges << [base_offset + index, base_offset + index + query.length]
          start = index + [query.length, 1].max
        end
        ranges
      end

      def self.normalized_pair(buffer, query)
        return [buffer, query] if case_sensitive?(query)

        [buffer.downcase, query.downcase]
      end

      def self.case_sensitive?(query)
        query.to_s.match?(/[[:upper:]]/)
      end

      def initialize(direction: :forward)
        @active = false
        @query = +""
        @direction = direction
        @origin_cursor = nil
        @current_match = nil
      end

      def active?
        @active == true
      end

      def begin(direction = :forward, cursor: nil)
        @active = true
        @direction = direction
        @query = +""
        @origin_cursor = cursor
        @current_match = nil
        status_prefix
      end

      def cancel(restore_cursor: true)
        @active = false
        cursor = @origin_cursor if restore_cursor
        @origin_cursor = nil
        @current_match = nil
        { cursor: cursor, status: "Search cancelled", found: false }
      end

      def append(text, buffer:, cursor:)
        @query << text.to_s
        live_result(buffer: buffer, cursor: cursor)
      end

      def delete_character(buffer:, cursor:)
        @query = @query[0...-1].to_s
        live_result(buffer: buffer, cursor: cursor)
      end

      def confirm(buffer:, cursor:)
        confirmed_query = @query.to_s
        @active = false
        @origin_cursor = nil
        return { status: "Search cancelled", found: false } if confirmed_query.empty?

        if @current_match
          return { cursor: @current_match, status: "Found: #{confirmed_query}", found: true }
        end

        repeat(buffer: buffer, cursor: cursor, direction: @direction, query: confirmed_query)
      ensure
        @current_match = nil
      end

      def repeat(buffer:, cursor:, direction: @direction, query: @query)
        query = query.to_s
        return { status: "No previous search", found: false } if query.empty?

        @query = query
        @direction = direction
        index = find_match(buffer, query, cursor, direction)

        if index
          { cursor: index, status: "Found: #{query}", found: true }
        else
          { status: "No match: #{query}", found: false }
        end
      end

      private

      def live_result(buffer:, cursor:)
        return { cursor: @origin_cursor, status: status_prefix, found: false } if @query.empty?

        @origin_cursor = cursor if @origin_cursor.nil?
        index = find_match(buffer, @query, @origin_cursor, @direction)
        @current_match = index
        if index
          { cursor: index, status: "#{status_prefix} #{@query}", found: true }
        else
          { cursor: @origin_cursor, status: "No match: #{@query}", found: false }
        end
      end

      def find_match(buffer, query, cursor, direction)
        haystack, needle = self.class.normalized_pair(buffer.to_s, query.to_s)
        cursor = cursor.to_i
        if direction == :backward
          search_from = cursor.positive? ? cursor - 1 : haystack.length
          haystack.rindex(needle, search_from) || haystack.rindex(needle)
        else
          haystack.index(needle, cursor + 1) || haystack.index(needle)
        end
      end

      def status_prefix
        @direction == :backward ? "Search backward:" : "Search:"
      end
    end
  end
end
