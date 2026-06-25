# Namespace for the Kward CLI agent runtime.
module Kward
  # Interactive terminal UI used by the CLI frontend.
  class PromptInterface
    # Endwise-style closing keyword insertion for the built-in editor.
    module EditorEndwise
      ENDWISE_LINE_PARSE_LIMIT = 100_000
      ENDWISE_SINGLE_LINE_DEFINITION = /;\s*end[\s;]*\z/.freeze
      ENDWISE_ENDLESS_DEFINITION = /\A\s*?def\s+[^\s(]+\s*(?:\(.*\))?\s*=/.freeze

      ENDWISE_LANGUAGES = {
        ruby: {
          line_comments: ["#"],
          block_comments: [{ start: /\A\s*=begin\b/, end: /\A\s*=end\b/ }],
          close_pattern: /\Aend\b/,
          openings: [
            { pattern: /\A\s*?if(\s|\()/, close: "end" },
            { pattern: /\A\s*?unless(\s|\()/, close: "end" },
            { pattern: /\A\s*?while(\s|\()/, close: "end" },
            { pattern: /\A\s*?for(\s|\()/, close: "end" },
            { pattern: /\s?do(\s?\z|\s\|.*\|\s?\z)/, close: "end" },
            { pattern: /\A\s*?def\s/, close: "end" },
            { pattern: /\A\s*?class\s/, close: "end" },
            { pattern: /\A\s*?module\s/, close: "end" },
            { pattern: /\A\s*?case(\s|\()/, close: "end" },
            { pattern: /\A\s*?begin\s/, close: "end" },
            { pattern: /\A\s*?until(\s|\()/, close: "end" }
          ]
        },
        crystal: {
          line_comments: ["#"],
          block_comments: [],
          close_pattern: /\Aend\b/,
          openings: [
            { pattern: /\A\s*?if(\s|\()/, close: "end" },
            { pattern: /\A\s*?unless(\s|\()/, close: "end" },
            { pattern: /\A\s*?while(\s|\()/, close: "end" },
            { pattern: /\A\s*?for(\s|\()/, close: "end" },
            { pattern: /\s?do(\s?\z|\s\|.*\|\s?\z)/, close: "end" },
            { pattern: /\A\s*?enum\s/, close: "end" },
            { pattern: /\A\s*?struct\s/, close: "end" },
            { pattern: /\A\s*?macro\s/, close: "end" },
            { pattern: /\A\s*?union\s/, close: "end" },
            { pattern: /\A\s*?lib\s/, close: "end" },
            { pattern: /\A\s*?annotation\s/, close: "end" },
            { pattern: /\A\s*?def\s/, close: "end" },
            { pattern: /\A\s*?class\s/, close: "end" },
            { pattern: /\A\s*?module\s/, close: "end" },
            { pattern: /\A\s*?case(\s|\()/, close: "end" },
            { pattern: /\A\s*?begin\s/, close: "end" },
            { pattern: /\A\s*?until(\s|\()/, close: "end" }
          ]
        },
        elixir: {
          line_comments: ["#"],
          block_comments: [],
          close_pattern: /\Aend\b/,
          openings: [
            { pattern: /\bdo\s*\z/, close: "end" },
            { pattern: /\A\s*fn\s*\z/, close: "end" },
            { pattern: /\bfn\b.*->\s*\z/, close: "end" }
          ]
        },
        julia: {
          line_comments: ["#"],
          block_comments: [],
          close_pattern: /\Aend\b/,
          openings: [
            { pattern: /\A\s*begin\s*\z/, close: "end" },
            { pattern: /\A\s*if\b/, close: "end" },
            { pattern: /\A\s*while\b/, close: "end" },
            { pattern: /\A\s*for\b/, close: "end" },
            { pattern: /\A\s*try\s*\z/, close: "end" },
            { pattern: /\A\s*let(?:\s|\z)/, close: "end" },
            { pattern: /\A\s*quote\s*\z/, close: "end" },
            { pattern: /\A\s*function\b/, close: "end" },
            { pattern: /\A\s*macro\b/, close: "end" },
            { pattern: /\A\s*module\b/, close: "end" },
            { pattern: /\A\s*baremodule\b/, close: "end" },
            { pattern: /\A\s*(?:mutable\s+)?struct\b/, close: "end" },
            { pattern: /\A\s*abstract\s+type\b/, close: "end" },
            { pattern: /\A\s*primitive\s+type\b/, close: "end" },
            { pattern: /\bdo(?:\s+.*)?\s*\z/, close: "end" }
          ]
        },
        lua: {
          line_comments: ["--"],
          block_comments: [{ start: /\A\s*--\[\[/, end: /\]\]/ }],
          close_pattern: /\Aend\b/,
          openings: [
            { pattern: /\A\s*do\s*\z/, close: "end" },
            { pattern: /\A\s*while\b.*\bdo\s*\z/, close: "end" },
            { pattern: /\A\s*if\b.*\bthen\s*\z/, close: "end" },
            { pattern: /\A\s*for\b.*\bdo\s*\z/, close: "end" },
            { pattern: /\A\s*(?:local\s+)?function\b.*\)\s*\z/, close: "end" }
          ]
        },
        makefile: {
          line_comments: ["#"],
          block_comments: [],
          close_pattern: /\Aendif\b/,
          openings: [
            { pattern: /\A\s*if(?:eq|neq)\b/, close: "endif" },
            { pattern: /\A\s*ifn?def\b/, close: "endif" }
          ]
        },
        shell: {
          line_comments: ["#"],
          block_comments: [],
          close_pattern: /\A(?:fi|done|esac)\b/,
          openings: [
            { pattern: /\bthen\s*\z/, close: "fi" },
            { pattern: /\A\s*case\b/, close: "esac" },
            { pattern: /\bdo\s*\z/, close: "done" }
          ]
        }
      }.freeze

      private

      def editor_insert_endwise_newline
        plan = editor_endwise_plan(called_with_modifier: false)
        return false unless plan

        editor_apply_endwise_plan(plan)
      end

      def editor_insert_endwise_modifier_newline
        plan = editor_endwise_plan(called_with_modifier: true) || editor_endwise_plain_modifier_plan
        editor_apply_endwise_plan(plan)
      end

      def editor_endwise_plan(called_with_modifier:)
        return nil unless current_editor_auto_indent?

        line_index, column = @editor_state.cursor_line_and_column
        return nil unless editor_endwise_line_exists?(line_index)

        language = editor_syntax_language
        definition = ENDWISE_LANGUAGES[language]
        return nil unless definition

        line = @editor_state.lines[line_index].to_s
        line_length = line.length
        return nil if !called_with_modifier && line_length > column

        closing_indent = editor_endwise_indentation_for(line)
        inner_indent = closing_indent + editor_indent_unit
        close = editor_endwise_closing_keyword_for_line(line_index, column, called_with_modifier: called_with_modifier)
        target_offset = @editor_state.line_start_offset(line_index) + line_length

        if close
          return {
            cursor_column: inner_indent.length,
            cursor_line: line_index + 1,
            offset: target_offset,
            text: "\n#{inner_indent}\n#{closing_indent}#{close}"
          }
        end

        return nil unless called_with_modifier && editor_endwise_line_opens_block?(line_index, language)

        {
          cursor_column: inner_indent.length,
          cursor_line: line_index + 1,
          offset: target_offset,
          text: "\n#{inner_indent}"
        }
      end

      def editor_endwise_plain_modifier_plan
        line_index, = @editor_state.cursor_line_and_column
        line = @editor_state.lines[line_index].to_s
        {
          cursor_column: 0,
          cursor_line: line_index + 1,
          offset: @editor_state.line_start_offset(line_index) + line.length,
          text: "\n"
        }
      end

      def editor_apply_endwise_plan(plan)
        @editor_state.cursor = plan.fetch(:offset)
        @editor_state.insert(plan.fetch(:text))
        @editor_state.set_cursor_line_and_column(plan.fetch(:cursor_line), plan.fetch(:cursor_column))
        true
      end

      def editor_endwise_line_exists?(line_index)
        line_index >= 0 && line_index < @editor_state.lines.length
      end

      def editor_endwise_line_opens_block?(line_index, language = editor_syntax_language)
        code = editor_endwise_code_line_at(line_index, language)
        return false if editor_endwise_ignored_definition?(code, language)

        ENDWISE_LANGUAGES.fetch(language).fetch(:openings).any? do |opening|
          code.match?(opening.fetch(:pattern))
        end
      end

      def editor_endwise_closing_keyword_for_line(line_index, column, called_with_modifier: false)
        language = editor_syntax_language
        definition = ENDWISE_LANGUAGES[language]
        return nil unless definition

        openings = definition.fetch(:openings)
        line = @editor_state.lines[line_index].to_s
        code = editor_endwise_code_line_at(line_index, language)
        current_indent = editor_endwise_indentation_for(line)

        return nil if !called_with_modifier && line.length > column
        return nil if editor_endwise_ignored_definition?(code, language)

        openings.each do |opening|
          next unless code.match?(opening.fetch(:pattern))

          close = opening.fetch(:close)
          stack_count = 0
          (line_index..(line_index + ENDWISE_LINE_PARSE_LIMIT)).each do |scan_line|
            return close if @editor_state.lines.length <= scan_line + 1

            line_below = @editor_state.lines[scan_line + 1].to_s
            code_below = editor_endwise_code_line_at(scan_line + 1, language)
            closes_any_block = editor_endwise_closes_block?(code_below, language)
            closes_this_block = editor_endwise_closes_with?(code_below, close)

            if current_indent.length > editor_endwise_indentation_for(line_below).length && closes_any_block
              return close
            end

            next unless current_indent == editor_endwise_indentation_for(line_below)

            if openings.any? { |inner_opening| code_below.match?(inner_opening.fetch(:pattern)) }
              stack_count += 1
            end

            if closes_any_block && stack_count.positive?
              stack_count -= 1
            elsif closes_this_block
              return nil
            end
          end
        end

        nil
      end

      def editor_endwise_ignored_definition?(code, language)
        return true if code.match?(ENDWISE_SINGLE_LINE_DEFINITION)
        return true if %i[ruby crystal].include?(language) && code.match?(ENDWISE_ENDLESS_DEFINITION)

        false
      end

      def editor_endwise_code_line_at(line_index, language)
        definition = ENDWISE_LANGUAGES[language]
        line = @editor_state.lines[line_index].to_s
        return "" if editor_endwise_inside_block_comment?(line_index, definition.fetch(:block_comments))

        editor_endwise_strip_line_comment(line, definition.fetch(:line_comments))
      end

      def editor_endwise_inside_block_comment?(line_index, block_comments)
        active_comment = nil
        @editor_state.lines.first(line_index + 1).each_with_index do |line, index|
          if active_comment
            target_line = index == line_index
            active_comment = nil if line.match?(active_comment.fetch(:end))
            return true if target_line

            next
          end

          block_comments.each do |block_comment|
            start_match = line.match(block_comment.fetch(:start))
            next unless start_match

            rest = line[(start_match.begin(0) + start_match[0].length)..].to_s
            if rest.match?(block_comment.fetch(:end))
              return true if index == line_index

              next
            end

            active_comment = block_comment
            return true if index == line_index

            break
          end
        end

        false
      end

      def editor_endwise_strip_line_comment(line, line_comments)
        comment_index = line_comments.filter_map do |comment|
          index = line.index(comment)
          index unless index.nil?
        end.min

        comment_index ? line[0...comment_index].to_s : line
      end

      def editor_endwise_indentation_for(line)
        trimmed = line.to_s.strip
        return line.to_s if trimmed.empty?

        line.to_s[0...line.to_s.index(trimmed)].to_s
      end

      def editor_endwise_closes_block?(code, language)
        code.to_s.strip.match?(ENDWISE_LANGUAGES.fetch(language).fetch(:close_pattern))
      end

      def editor_endwise_closes_with?(code, close)
        code.to_s.strip.match?(/\A#{Regexp.escape(close)}\b/)
      end
    end
  end
end
