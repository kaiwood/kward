require_relative "../text_boundary"
require_relative "../text_matcher"
require_relative "../terminal_text"

# Namespace for the Kward CLI agent runtime.
module Kward
  # Interactive terminal UI used by the CLI frontend.
  class PromptInterface
    # Mutable text, cursor, history, and overlay state for the composer.
    class ComposerState
      # @return [String] editable text currently shown in the composer
      attr_accessor :input
      # @return [Integer] cursor offset into `input`
      attr_accessor :cursor
      # @return [String] most recently killed text available for yank
      attr_accessor :kill_buffer
      # @return [Integer, nil] active history index while navigating history
      attr_accessor :history_index
      # @return [String, nil] draft restored after leaving history navigation
      attr_accessor :history_draft
      # @return [String, nil] text queued for the next composer prompt
      attr_accessor :prefill_input
      # @return [String, nil] query typed while searching history
      attr_accessor :history_search_query
      # @return [String, nil] draft restored after canceling history search
      attr_accessor :history_search_draft
      # @return [Integer] active selection index while searching history
      attr_accessor :history_search_index
      # @return [Array<Hash>] pending image/file attachments submitted with the next turn
      attr_reader :attachments
      # @return [Array<String>] submitted input history
      attr_reader :history

      def initialize
        @input = +""
        @cursor = 0
        @attachments = []
        @kill_buffer = ""
        @history = []
        @history_index = nil
        @history_draft = nil
        @prefill_input = nil
        @history_search_query = nil
        @history_search_draft = nil
        @history_search_index = 0
        @history_search_matches_query = nil
        @history_search_matches = nil
      end

      # Removes all pending attachments without changing text input.
      def clear_attachments
        @attachments.clear
      end

      # Adds one attachment unless its source is already pending.
      def add_attachment(attachment)
        return false unless attachment.respond_to?(:key?)

        source = attachment[:source_text] || attachment["source_text"] || attachment[:original_path] || attachment["original_path"]
        return false if source.to_s.empty?
        return false if @attachments.any? { |item| (item[:source_text] || item["source_text"]).to_s == source.to_s }

        @attachments << attachment
        true
      end

      # Removes the most recently added attachment.
      def remove_last_attachment
        return false if @attachments.empty?

        @attachments.pop
        true
      end

      # Inserts text at the cursor and advances by the inserted length.
      def insert_string(string)
        return if string.empty?

        @input = @input[0...@cursor] + string + @input[@cursor..]
        @cursor += string.length
      end

      # Deletes one grapheme before the cursor.
      def delete_before_cursor
        return false if @cursor.zero?

        previous = TerminalText.previous_grapheme_boundary(@input, @cursor)
        @input = @input[0...previous] + @input[@cursor..]
        @cursor = previous
        true
      end

      # Deletes one grapheme at the cursor without moving it.
      def delete_at_cursor
        return false unless @cursor < @input.length

        following = TerminalText.next_grapheme_boundary(@input, @cursor)
        @input = @input[0...@cursor] + @input[following..]
        true
      end

      # Moves the cursor one grapheme left when possible.
      def move_cursor_left
        @cursor = TerminalText.previous_grapheme_boundary(@input, @cursor) if @cursor.positive?
      end

      # Moves the cursor one grapheme right when possible.
      def move_cursor_right
        @cursor = TerminalText.next_grapheme_boundary(@input, @cursor) if @cursor < @input.length
      end

      # Moves the cursor to the beginning of the input buffer.
      def move_to_start_of_line
        @cursor = 0
      end

      # Moves the cursor to the end of the input buffer.
      def move_to_end_of_line
        @cursor = @input.length
      end

      # Moves the cursor to the previous word boundary.
      def move_to_previous_word
        @cursor = TextBoundary.previous_word_boundary(@input, @cursor)
      end

      # Moves the cursor to the next word boundary.
      def move_to_next_word
        @cursor = TextBoundary.next_word_boundary(@input, @cursor)
      end

      # Kills the word before the cursor into `kill_buffer`.
      def delete_word_before_cursor
        kill_range(TextBoundary.previous_word_boundary(@input, @cursor), @cursor)
      end

      # Kills the word after the cursor into `kill_buffer`.
      def delete_word_after_cursor
        kill_range(@cursor, TextBoundary.next_word_boundary(@input, @cursor))
      end

      # Kills all text before the cursor into `kill_buffer`.
      def kill_line_before_cursor
        kill_range(0, @cursor)
      end

      # Kills all text after the cursor into `kill_buffer`.
      def kill_line_after_cursor
        kill_range(@cursor, @input.length)
      end

      # Removes a range, stores it in `kill_buffer`, and moves the cursor to the start.
      def kill_range(start_index, end_index)
        return false if start_index == end_index

        @kill_buffer = @input[start_index...end_index].to_s
        @input = @input[0...start_index].to_s + @input[end_index..].to_s
        @cursor = start_index
        true
      end

      # Inserts the last killed text at the cursor.
      def yank_kill_buffer
        insert_string(@kill_buffer.to_s) unless @kill_buffer.to_s.empty?
      end

      # Replaces the full input buffer and places the cursor at the end.
      def replace_input(value)
        @input = value.to_s
        @cursor = @input.length
      end

      # Returns `[lines, row, column]` for cursor-aware multi-line layout.
      def lines_and_cursor
        lines = @input.split("\n", -1)
        before_cursor = @input[0...@cursor]
        row = before_cursor.count("\n")
        line_start = before_cursor.rindex("\n")
        column = line_start ? before_cursor.length - line_start - 1 : before_cursor.length
        [lines.empty? ? [""] : lines, row, column]
      end

      # Replaces the in-memory history list with persisted entries.
      def load_history(values)
        @history = Array(values).map(&:to_s).reject { |value| value.strip.empty? }
        reset_history_navigation
        reset_history_search
        invalidate_history_search_matches
      end

      # Stores a submitted input unless it is blank or duplicates the previous entry.
      def add_history(value)
        stripped = value.to_s.strip
        return false if stripped.empty?
        return false if @history.last == value

        @history << value
        invalidate_history_search_matches
        true
      end

      # Replaces input with the previous history entry, preserving the draft first.
      def recall_previous_history
        return if @history.empty?

        @history_draft = @input if @history_index.nil?
        @history_index = @history_index.nil? ? @history.length - 1 : [@history_index - 1, 0].max
        replace_input(@history[@history_index])
      end

      # Replaces input with the next history entry or restores the saved draft.
      def recall_next_history
        return if @history_index.nil?

        if @history_index < @history.length - 1
          @history_index += 1
          replace_input(@history[@history_index])
        else
          replace_input(@history_draft || "")
          reset_history_navigation
        end
      end

      # Leaves history navigation and clears the saved draft/index state.
      def reset_history_navigation
        @history_index = nil
        @history_draft = nil
      end

      def start_history_search
        @history_search_draft = @input if @history_search_query.nil?
        @history_search_query = @input.to_s
        @history_search_index = 0
        replace_input(@history_search_query)
      end

      def history_search_active?
        !@history_search_query.nil?
      end

      def update_history_search_query(value)
        @history_search_query = value.to_s
        @history_search_index = 0
        replace_input(@history_search_query)
      end

      def history_search_matches
        query = @history_search_query.to_s.downcase
        return @history_search_matches if @history_search_matches_query == query && @history_search_matches

        pattern = TextMatcher.subsequence_pattern(query)
        @history_search_matches_query = query
        @history_search_matches = @history.reverse.select do |value|
          TextMatcher.subsequence?(value.downcase, query, pattern)
        end
      end

      def selected_history_search_match
        matches = history_search_matches
        return nil if matches.empty?

        matches[[@history_search_index, matches.length - 1].min]
      end

      def select_previous_history_search_match
        @history_search_index = [@history_search_index - 1, 0].max
      end

      def select_next_history_search_match
        matches = history_search_matches
        return if matches.empty?

        @history_search_index = [@history_search_index + 1, matches.length - 1].min
      end

      def accept_history_search
        match = selected_history_search_match
        replace_input(match) if match
        reset_history_search
      end

      def cancel_history_search
        replace_input(@history_search_draft.to_s)
        reset_history_search
      end

      def reset_history_search
        @history_search_query = nil
        @history_search_draft = nil
        @history_search_index = 0
      end

      def invalidate_history_search_matches
        @history_search_matches_query = nil
        @history_search_matches = nil
      end
    end
  end
end
