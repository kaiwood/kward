# Namespace for the Kward CLI agent runtime.
module Kward
  # Interactive terminal UI used by the CLI frontend.
  class PromptInterface
    # Auto-close pair behavior for the built-in composer file editor.
    module EditorAutoClosePairs
      AUTO_CLOSE_PAIRS = {
        "(" => ")",
        "[" => "]",
        "{" => "}",
        "\"" => "\"",
        "'" => "'",
        "`" => "`"
      }.freeze
      AUTO_CLOSE_OPENERS = AUTO_CLOSE_PAIRS.keys.freeze
      AUTO_CLOSE_CLOSERS = AUTO_CLOSE_PAIRS.values.uniq.freeze
      AUTO_CLOSE_QUOTES = ["\"", "'", "`"].freeze
      WORD_CHARACTER = /[[:alnum:]_]/.freeze

      private

      def editor_insert_printable_with_pairs(text)
        text = text.to_s
        return false unless current_editor_auto_close_pairs?
        return false unless text.length == 1

        if @editor_state.selection_active? && AUTO_CLOSE_PAIRS.key?(text)
          editor_insert_auto_close_pair(text, AUTO_CLOSE_PAIRS.fetch(text))
          return true
        end

        if AUTO_CLOSE_CLOSERS.include?(text) && editor_next_character == text
          @editor_state.move_right
          return true
        end

        if AUTO_CLOSE_PAIRS.key?(text)
          return false if editor_quote_pair?(text) && editor_quote_inside_word?

          editor_insert_auto_close_pair(text, AUTO_CLOSE_PAIRS.fetch(text))
          return true
        end

        false
      end

      def editor_delete_auto_close_pair_before_cursor
        return false unless current_editor_auto_close_pairs?

        opener = editor_previous_character
        closer = editor_next_character
        return false unless opener && closer
        return false unless AUTO_CLOSE_PAIRS[opener] == closer

        @editor_state.replace_range(@editor_state.cursor - 1, @editor_state.cursor + 1, "")
        true
      end

      def current_editor_auto_close_pairs?
        return @editor_auto_close_pairs_source.call != false if @editor_auto_close_pairs_source.respond_to?(:call)

        @editor_auto_close_pairs != false
      rescue StandardError
        @editor_auto_close_pairs != false
      end

      def editor_insert_auto_close_pair(opener, closer)
        range = editor_auto_close_pair_range(opener)
        if range
          selected = @editor_state.buffer[range[0]...range[1]].to_s
          @editor_state.replace_range(range[0], range[1], "#{opener}#{selected}#{closer}")
          @editor_state.cursor = range[1] + opener.length + closer.length
          @editor_state.clear_selection
          return
        end

        @editor_state.insert("#{opener}#{closer}")
        @editor_state.move_left
      end

      def editor_auto_close_pair_range(opener)
        range = @editor_state.selection_range
        return nil unless range
        return range unless editor_quote_pair?(opener)
        return range if @editor_state.vibe?

        editor_quote_selection_range(range)
      end

      def editor_quote_selection_range(range)
        start_index, end_index = range
        return range unless editor_word_character?(@editor_state.buffer[(end_index - 1)...end_index])
        return range unless editor_word_character?(@editor_state.buffer[end_index...(end_index + 1)])
        return range if editor_word_character?(@editor_state.buffer[(start_index - 1)...start_index])
        return range if editor_word_character?(@editor_state.buffer[(end_index + 1)...(end_index + 2)])

        [start_index, end_index + 1]
      end

      def editor_quote_pair?(text)
        AUTO_CLOSE_QUOTES.include?(text)
      end

      def editor_quote_inside_word?
        editor_word_character?(editor_previous_character) || editor_word_character?(editor_next_character)
      end

      def editor_previous_character
        return nil if @editor_state.cursor.zero?

        @editor_state.buffer[(@editor_state.cursor - 1)...@editor_state.cursor]
      end

      def editor_next_character
        @editor_state.buffer[@editor_state.cursor...(@editor_state.cursor + 1)]
      end

      def editor_word_character?(character)
        character.to_s.match?(WORD_CHARACTER)
      end
    end
  end
end
