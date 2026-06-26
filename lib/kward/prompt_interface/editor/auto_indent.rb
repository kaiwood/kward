# Namespace for the Kward CLI agent runtime.
module Kward
  # Interactive terminal UI used by the CLI frontend.
  class PromptInterface
    # Lightweight syntax-based auto-indent for the built-in composer file editor.
    module EditorAutoIndent
      C_LIKE_INDENT_LANGUAGES = %i[javascript typescript json css scss go rust java csharp c cpp swift kotlin].freeze
      PUNCTUATION_INDENT_LANGUAGES = (C_LIKE_INDENT_LANGUAGES + %i[ruby python shell lua html]).freeze
      RUBY_INDENT_KEYWORDS = %w[begin case class def do else elsif ensure for if module rescue unless until while].freeze
      SHELL_INDENT_KEYWORDS = %w[case do else elif if select then until while].freeze
      PYTHON_INDENT_KEYWORDS = %w[class def elif else except finally for if try while with].freeze
      LUA_INDENT_KEYWORDS = %w[do else elseif for function if repeat then while].freeze
      SHELL_DEDENT_KEYWORDS = %w[fi done esac].freeze
      PUNCTUATION_PAIRS = { "}" => "{", "]" => "[", ")" => "(" }.freeze
      EDITOR_TAB_SEQUENCES = ["\t", "\e[9u", "\e[9;1u", "\e[27;1;9~"].freeze
      EDITOR_SHIFT_TAB_SEQUENCES = ["\e[Z", "\e[1;2Z", "\e[9;2u", "\e[27;2;9~"].freeze

      private

      def editor_insert_newline
        return @editor_state.insert("\n") unless current_editor_auto_indent?
        return true if editor_insert_endwise_newline

        block_indent = editor_multiline_block_indent
        if block_indent
          inner_indent, closing_indent = block_indent
          @editor_state.insert("\n#{inner_indent}\n#{closing_indent}")
          @editor_state.cursor -= closing_indent.length + 1
          return
        end

        @editor_state.insert("\n#{editor_newline_indent}")
      end

      def editor_insert_printable(text)
        text = text.to_s
        return if editor_insert_printable_with_pairs(text)

        clear_editor_selection_before_edit
        return @editor_state.insert(text) unless current_editor_auto_indent?
        return @editor_state.insert(text) unless text.length == 1

        editor_reindent_for_closing_punctuation(text) if editor_closing_punctuation?(text)
        @editor_state.insert(text)
        editor_reindent_for_completed_word_closer
      end

      def editor_delete_before_cursor
        return true if editor_delete_auto_close_pair_before_cursor
        return @editor_state.delete_before_cursor unless current_editor_auto_indent?
        return @editor_state.delete_before_cursor unless editor_cursor_in_leading_indent?

        unit = editor_indent_unit
        return @editor_state.delete_before_cursor if unit.empty?
        return @editor_state.delete_before_cursor unless @editor_state.cursor >= unit.length
        return @editor_state.delete_before_cursor unless @editor_state.buffer[(@editor_state.cursor - unit.length)...@editor_state.cursor] == unit

        @editor_state.replace_range(@editor_state.cursor - unit.length, @editor_state.cursor, "")
        true
      end

      def handle_editor_tab_key(key)
        tab_sequence = editor_tab_sequence_for(key)
        if tab_sequence
          queue_editor_tab_remaining(key, tab_sequence)
          if !editor_search_active?
            block_given? ? yield(:forward) : editor_insert_tab
          end
          return true
        end

        shift_tab_sequence = editor_shift_tab_sequence_for(key)
        if shift_tab_sequence
          queue_editor_tab_remaining(key, shift_tab_sequence)
          if !editor_search_active?
            block_given? ? yield(:backward) : editor_outdent_tab
          end
          return true
        end

        false
      end

      def editor_insert_tab
        if @editor_state.multi_cursor? || @editor_state.selection_ranges.any?
          return @editor_state.replace_selections(editor_indent_unit)
        end

        if current_editor_auto_indent? && editor_cursor_in_leading_indent?
          return editor_smart_tab_forward
        end

        @editor_state.insert(editor_tab_padding)
        true
      end

      def editor_outdent_tab
        return true if @editor_state.multi_cursor? || @editor_state.selection_ranges.any?

        line_index, column = @editor_state.cursor_line_and_column
        line = @editor_state.lines[line_index].to_s
        old_indent = line[/\A[ \t]*/].to_s

        return true if old_indent.empty?

        reference_column = column <= old_indent.length ? column : old_indent.length
        reference_column = old_indent.length if reference_column.zero?
        target_width = previous_indent_stop(reference_column)
        editor_update_current_line_indent(editor_indent_for_width(target_width), preserve_content_column: column > old_indent.length)
        true
      end

      def editor_tab_sequence_for(key)
        return nil unless key.is_a?(String)

        EDITOR_TAB_SEQUENCES.find { |sequence| key.start_with?(sequence) }
      end

      def editor_shift_tab_sequence_for(key)
        return nil unless key.is_a?(String)

        EDITOR_SHIFT_TAB_SEQUENCES.find { |sequence| key.start_with?(sequence) }
      end

      def queue_editor_tab_remaining(key, sequence)
        return unless key.length > sequence.length
        return if sequence.end_with?("u")

        queue_pending_keys(key[sequence.length..])
      end

      def current_editor_auto_indent?
        return @editor_auto_indent_source.call != false if @editor_auto_indent_source.respond_to?(:call)

        @editor_auto_indent != false
      rescue StandardError
        @editor_auto_indent != false
      end

      def editor_newline_indent
        line_index, column = @editor_state.cursor_line_and_column
        line = @editor_state.lines[line_index].to_s
        before_cursor = line[0...column].to_s
        base_indent = line[/\A[ \t]*/].to_s
        language = editor_syntax_language
        indent = base_indent.dup
        indent += editor_indent_unit if editor_line_opens_indent?(before_cursor, language)
        indent
      end

      def editor_smart_tab_forward
        line_index, column = @editor_state.cursor_line_and_column
        line = @editor_state.lines[line_index].to_s
        old_indent = line[/\A[ \t]*/].to_s
        target_indent = editor_expected_indent_for_line(line_index)
        expected_width = indent_width(target_indent)
        target_width = column < expected_width ? expected_width : next_indent_stop(column)

        if indent_width(old_indent) >= target_width
          @editor_state.cursor = @editor_state.line_start_offset(line_index) + target_width
        else
          editor_update_current_line_indent(editor_indent_for_width(target_width), preserve_content_column: column > old_indent.length)
        end
        true
      end

      def editor_tab_padding
        unit = editor_indent_unit
        return unit if unit == "\t"

        width = indent_width(unit)
        width = 2 unless width.positive?
        column = @editor_state.cursor_line_and_column[1]
        " " * (width - (column % width))
      end

      def editor_expected_indent_for_line(line_index)
        line = @editor_state.lines[line_index].to_s
        code = editor_indent_code(line, editor_syntax_language).strip
        matching_indent = editor_matching_indent_for_line(code)
        return matching_indent if matching_indent

        previous_line = previous_non_blank_editor_line(line_index)
        return "" unless previous_line

        indent = previous_line[:indent].dup
        indent += editor_indent_unit if editor_line_opens_indent?(previous_line[:code], editor_syntax_language)
        indent
      end

      def editor_matching_indent_for_line(code)
        return nil if code.empty?
        return editor_matching_punctuation_indent(code[0]) if editor_closing_punctuation?(code[0])

        editor_matching_word_indent if editor_completed_word_closer?(code, editor_syntax_language)
      end

      def previous_non_blank_editor_line(line_index)
        (line_index.to_i - 1).downto(0) do |index|
          line = @editor_state.lines[index].to_s
          code = editor_indent_code(line, editor_syntax_language).rstrip
          next if code.strip.empty?

          return { indent: line[/\A[ \t]*/].to_s, code: code }
        end
        nil
      end

      def editor_update_current_line_indent(indent, preserve_content_column: false)
        line_index, column = @editor_state.cursor_line_and_column
        line_start = @editor_state.line_start_offset(line_index)
        line = @editor_state.lines[line_index].to_s
        old_indent = line[/\A[ \t]*/].to_s
        content_column = preserve_content_column ? [column - old_indent.length, 0].max : 0
        @editor_state.replace_range(line_start, line_start + old_indent.length, indent.to_s)
        @editor_state.cursor = line_start + indent.to_s.length + content_column
        true
      end

      def next_indent_stop(column)
        width = indent_width(editor_indent_unit)
        width = 2 unless width.positive?
        column + width - (column % width)
      end

      def previous_indent_stop(column)
        width = indent_width(editor_indent_unit)
        width = 2 unless width.positive?
        [column - 1, 0].max / width * width
      end

      def editor_indent_for_width(width)
        unit = editor_indent_unit
        return "\t" * width.to_i if unit == "\t"

        " " * [width.to_i, 0].max
      end

      def indent_width(text)
        text.to_s.each_char.sum { |char| char == "\t" ? 1 : 1 }
      end

      def editor_multiline_block_indent
        line_index, column = @editor_state.cursor_line_and_column
        line = @editor_state.lines[line_index].to_s
        before_cursor = line[0...column].to_s
        base_indent = line[/\A[ \t]*/].to_s
        language = editor_syntax_language
        opens_indent = editor_line_opens_indent?(before_cursor, language)
        paired_closer = editor_next_paired_closer
        return nil unless paired_closer
        return nil unless opens_indent || editor_auto_close_pair_opener_before_cursor?

        [base_indent + editor_indent_unit, base_indent]
      end

      def editor_next_paired_closer
        opener = editor_previous_character
        closer = editor_next_character
        return nil unless opener && closer
        return nil unless PromptInterface::EditorAutoClosePairs::AUTO_CLOSE_PAIRS[opener] == closer

        closer
      end

      def editor_auto_close_pair_opener_before_cursor?
        PromptInterface::EditorAutoClosePairs::AUTO_CLOSE_PAIRS.key?(editor_previous_character)
      end

      def editor_indent_unit
        @editor_indent_unit_path ||= nil
        if @editor_indent_unit_path != @editor_state.path
          @editor_indent_unit_path = @editor_state.path
          @editor_indent_unit = detect_editor_indent_unit
        end
        @editor_indent_unit
      end

      def detect_editor_indent_unit
        indents = @editor_state.lines.filter_map do |line|
          whitespace = line[/\A[ \t]+(?=\S)/].to_s
          whitespace.empty? ? nil : whitespace
        end
        return "  " if indents.empty?

        tab_count = indents.sum { |indent| indent.count("\t") }
        space_count = indents.sum { |indent| indent.count(" ") }
        return "\t" if tab_count > space_count

        widths = indents.filter_map do |indent|
          next if indent.include?("\t")

          indent.length if indent.length.positive?
        end
        positive_deltas = widths.each_cons(2).filter_map do |previous, current|
          delta = current - previous
          delta.positive? ? delta : nil
        end
        candidates = positive_deltas.empty? ? widths : positive_deltas
        detected = candidates.tally.max_by { |width, count| [count, -width] }&.first
        detected && detected.positive? ? " " * detected : "  "
      end

      def editor_line_opens_indent?(line, language)
        return false unless language

        code = editor_indent_code(line, language).rstrip
        return false if code.empty?

        return true if code.end_with?("{", "[", "(")

        case language
        when :ruby
          editor_ruby_line_opens_indent?(code)
        when :shell
          editor_keyword_line_opens_indent?(code, SHELL_INDENT_KEYWORDS)
        when :python
          code.end_with?(":") || editor_keyword_line_opens_indent?(code, PYTHON_INDENT_KEYWORDS)
        when :lua
          editor_keyword_line_opens_indent?(code, LUA_INDENT_KEYWORDS)
        when :yaml
          code.match?(/:\s*(?:[#].*)?\z/)
        when :html
          editor_html_line_opens_indent?(code)
        when *C_LIKE_INDENT_LANGUAGES
          false
        else
          false
        end
      end

      def editor_indent_code(line, language)
        text = line.to_s
        marker = case language
                 when :ruby, :python, :shell, :yaml
                   "#"
                 when :lua, :sql
                   "--"
                 else
                   "//"
                 end
        index = editor_comment_index(text, marker)
        index ? text[0...index].to_s : text
      end

      def editor_ruby_line_opens_indent?(code)
        return false if code.match?(/\b(?:end|else|elsif|ensure|rescue)\b\z/)
        return true if code.match?(/\A\s*(?:#{Regexp.union(RUBY_INDENT_KEYWORDS)})\b/)

        code.match?(/\bdo(?:\s*\|[^|]*\|)?\s*\z/)
      end

      def editor_keyword_line_opens_indent?(code, keywords)
        code.match?(/\b(?:#{Regexp.union(keywords)})\b\s*\z/)
      end

      def editor_html_line_opens_indent?(code)
        tag = code.match(/<([A-Za-z][\w:-]*)(?:\s[^>]*)?>\s*\z/)
        return false unless tag
        return false if code.match?(/<\/[^>]+>\s*\z/)
        return false if code.match?(/\/>\s*\z/)

        true
      end

      def editor_closing_punctuation?(text)
        PUNCTUATION_PAIRS.key?(text) && PUNCTUATION_INDENT_LANGUAGES.include?(editor_syntax_language)
      end

      def editor_reindent_for_closing_punctuation(text)
        return unless editor_cursor_in_leading_indent?

        indent = editor_matching_punctuation_indent(text)
        editor_reindent_current_line(indent) if indent
      end

      def editor_reindent_for_completed_word_closer
        line_index, column = @editor_state.cursor_line_and_column
        line = @editor_state.lines[line_index].to_s
        before_cursor = line[0...column].to_s
        return unless editor_completed_word_closer?(before_cursor, editor_syntax_language)

        indent = editor_matching_word_indent
        editor_reindent_current_line(indent) if indent
      end

      def editor_cursor_in_leading_indent?
        line_index, column = @editor_state.cursor_line_and_column
        line = @editor_state.lines[line_index].to_s
        column <= line[/\A[ \t]*/].to_s.length
      end

      def editor_reindent_current_line(indent)
        line_index, column = @editor_state.cursor_line_and_column
        line_start = @editor_state.line_start_offset(line_index)
        line = @editor_state.lines[line_index].to_s
        old_indent = line[/\A[ \t]*/].to_s
        new_indent = indent.to_s
        return false if old_indent == new_indent

        content_column = [column - old_indent.length, 0].max
        @editor_state.replace_range(line_start, line_start + old_indent.length, new_indent)
        @editor_state.cursor = line_start + new_indent.length + content_column
        true
      end

      def editor_completed_word_closer?(text, language)
        code = editor_indent_code(text, language).rstrip
        case language
        when :ruby
          code.match?(/\A[ \t]*end\z/)
        when :lua
          code.match?(/\A[ \t]*(?:end|until)\z/)
        when :shell
          code.match?(/\A[ \t]*(?:#{Regexp.union(SHELL_DEDENT_KEYWORDS)})\z/)
        when :html
          code.match?(/\A[ \t]*<\/[A-Za-z][\w:-]*>\z/)
        else
          false
        end
      end

      def editor_matching_word_indent
        case editor_syntax_language
        when :ruby
          editor_matching_keyword_indent("end", %w[end])
        when :lua
          editor_matching_keyword_indent("end", %w[end until])
        when :shell
          editor_matching_keyword_indent(nil, SHELL_DEDENT_KEYWORDS)
        when :html
          editor_matching_html_indent
        end
      end

      def editor_matching_punctuation_indent(text)
        opener = PUNCTUATION_PAIRS[text]
        stack = []
        editor_previous_code_lines.each do |line|
          editor_scan_punctuation_tokens(line[:code]).each do |token|
            if token == opener
              stack << line[:indent]
            elsif token == text
              stack.pop
            end
          end
        end
        stack.last || ""
      end

      def editor_matching_keyword_indent(opener = nil, closers = [])
        stack = []
        editor_previous_code_lines.each do |line|
          code = line[:code].strip
          next if code.empty?

          stack.pop if editor_word_closer_line?(code, closers)
          stack << line[:indent] if editor_word_opener_line?(code, opener)
        end
        stack.last || ""
      end

      def editor_matching_html_indent
        stack = []
        editor_previous_code_lines.each do |line|
          code = line[:code].strip
          next if code.empty?

          stack.pop if code.match?(/\A<\/[A-Za-z][\w:-]*>/)
          stack << line[:indent] if editor_html_line_opens_indent?(code)
        end
        stack.last || ""
      end

      def editor_previous_code_lines
        line_index, = @editor_state.cursor_line_and_column
        @editor_state.lines.first(line_index).filter_map do |line|
          code = editor_indent_code(line, editor_syntax_language).rstrip
          next if code.strip.empty?

          { indent: line[/\A[ \t]*/].to_s, code: code }
        end
      end

      def editor_scan_punctuation_tokens(code)
        code.to_s.scan(/[{}\[\]()]/)
      end

      def editor_word_opener_line?(code, opener)
        case editor_syntax_language
        when :ruby
          editor_ruby_line_opens_indent?(code)
        when :lua
          editor_keyword_line_opens_indent?(code, LUA_INDENT_KEYWORDS)
        when :shell
          editor_keyword_line_opens_indent?(code, SHELL_INDENT_KEYWORDS)
        else
          opener && code.match?(/\b#{Regexp.escape(opener)}\b/)
        end
      end

      def editor_word_closer_line?(code, closers)
        return false if closers.empty?

        code.match?(/\A(?:#{Regexp.union(closers)})\b/)
      end
    end
  end
end
