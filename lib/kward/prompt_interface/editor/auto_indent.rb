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

      private

      def editor_insert_newline
        return @editor_state.insert("\n") unless current_editor_auto_indent?

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
