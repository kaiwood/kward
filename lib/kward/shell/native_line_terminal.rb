require "io/console"
require_relative "../terminal/keys"
require_relative "../terminal/sequences"
require_relative "../terminal/locale_text"
require_relative "native_prompt_format"

module Kward
  module NativeShell
    # Raw terminal ownership is scoped to reading one standalone edit line.
    # Byte reads never consume a following command's stdin.
    class LineTerminal
      GET_ATTRIBUTES = Fiddle::Function.new(Fiddle::Handle::DEFAULT["tcgetattr"], [Fiddle::TYPE_INT, Fiddle::TYPE_VOIDP], Fiddle::TYPE_INT)

      MAX_ESCAPE_BYTES = 32
      MAX_PASTE_BYTES = 1_048_576
      META_KEYS = (TerminalKeys::ALT_B + TerminalKeys::ALT_D + TerminalKeys::ALT_F +
                   TerminalKeys::ALT_BACKSPACE + TerminalKeys::ALT_LAST_WORD + TerminalKeys::ALT_Y).freeze

      def initialize(runtime, editor, bracketed_paste: false)
        @runtime = runtime
        @editor = editor
        @bracketed_paste = bracketed_paste
      end

      def read(source, prompt:, input:, output:, error:, draft: nil)
        @source, @prompt, @error = source, prompt, error
        @streams = { input: input, output: output, error: error }
        @left = @frame_rows = @cursor_row = @draft_top = 0
        @active_line = nil
        controls = control_characters(source)
        callbacks = { get: method(:character), changed: method(:redraw), alert: method(:alert) }
        if @bracketed_paste
          callbacks.merge!(get: method(:key), paste: method(:read_paste), clear: method(:clear_screen))
        end
        result = source.raw(intr: false) do
          begin
            write(TerminalSequences::BRACKETED_PASTE_ENABLE) if @bracketed_paste
            @editor.read(**callbacks, **controls, draft: draft)
          ensure
            if @bracketed_paste
              finish_frame
              write(TerminalSequences::BRACKETED_PASTE_RESTORE)
            end
          end
        end
        error.puts
        result
      ensure
        @source = @error = @streams = @prompt = @prompt_cells = nil
      end

      private

      def control_characters(source)
        attributes = "\0" * 256
        raise SystemCallError.new("tcgetattr", Fiddle.last_error) if GET_ATTRIBUTES.call(source.fileno, attributes) < 0
        offset, erase, kill, eof, interrupt = Locale::DARWIN ? [32, 3, 5, 0, 8] : [17, 2, 3, 4, 0]
        { erase: attributes.byteslice(offset + erase, 1), kill: attributes.byteslice(offset + kill, 1), eof: attributes.byteslice(offset + eof, 1), interrupt: attributes.byteslice(offset + interrupt, 1) }
      end

      def character(timeout: nil)
        text = +"".b
        while (byte = read_byte(timeout: timeout))
          text << byte
          value = text.dup.force_encoding(@editor.encoding)
          return value if value.valid_encoding?
          raise ExecutionError, "invalid terminal character" if text.bytesize >= 8
        end
        nil
      end

      # Decode CSI/SS3 and Meta keys only for the non-modal editor. Vi receives
      # a bare Escape immediately. Never look past the final byte of a key.
      def key
        first = character
        return first unless first == TerminalKeys::ESCAPE

        prefix = escape_character
        return first unless prefix

        sequence = first + prefix
        return sequence if META_KEYS.include?(sequence)
        return prefix unless prefix == "[" || prefix == "O"

        while sequence.bytesize < MAX_ESCAPE_BYTES && (byte = escape_character)
          # Preserve Enter and control characters even after a truncated key.
          return byte if byte.ord < 32 || byte.ord == 127
          sequence << byte
          return sequence if prefix == "O" || sequence.match?(TerminalKeys::CSI_SEQUENCE_PATTERN)
          break unless sequence.match?(TerminalKeys::CSI_PREFIX_PATTERN)
        end
        first
      end

      def escape_character
        character(timeout: TerminalKeys::HANDOFF_ESCAPE_DELAY)
      end

      def read_paste
        ending = TerminalSequences::BRACKETED_PASTE_END.b
        text = +"".b
        oversized = false
        while (byte = read_byte)
          text << byte
          if text.end_with?(ending)
            text = text.byteslice(0, text.bytesize - ending.bytesize).force_encoding(@editor.encoding)
            return text.gsub(/\r\n?/, "\n") unless oversized || !text.valid_encoding? || text.bytesize > MAX_PASTE_BYTES
            alert
            return ""
          end
          # Keep scanning for the terminator even when rejecting the payload.
          if text.bytesize > MAX_PASTE_BYTES + ending.bytesize || (oversized && text.bytesize > ending.bytesize)
            oversized = true
            text = text.byteslice(-ending.bytesize, ending.bytesize)
          end
        end
        nil
      end

      def read_byte(timeout: nil)
        loop do
          return @source.readpartial(1) if IO.select([@source], nil, nil, timeout || 0.1)
          return if timeout

          @runtime.poll_signals(**@streams)
          return if @runtime.exited
        end
      rescue EOFError
        nil
      end

      def clear_screen
        @frame_rows = @cursor_row = 0
        write(TerminalSequences::CLEAR_VISIBLE_SCREEN)
      end

      def alert
        write(TerminalSequences::ALERT)
      end

      def write(text)
        @error.write(text)
        @error.flush
      end

      def redraw(text, position, menu: nil)
        unless position
          @error.write("\r\n")
          text.lines(chomp: true).each { |line| @error.write(TerminalText.locale_cells(line).map(&:first).join + "\r\n") }
          @error.flush
          return
        end
        height, columns = @source.winsize
        height = 24 unless height.positive?
        columns = 80 if columns < 4
        return redraw_single_line(text, position, columns) unless @bracketed_paste

        menu_lines = menu_rows(menu, columns, [height - 1, 6].min)
        rows, cursor, column = draft_rows(text, position, columns, height - menu_lines.length)
        render_frame(rows, menu_lines, cursor, column, height)
      end

      def redraw_single_line(text, position, columns)
        row, column = format_row(text, position, columns, prompt: true)
        write("\r" + row + TerminalSequences::ERASE_LINE_END + TerminalSequences.move_to_column(column))
      end

      def draft_rows(text, position, columns, limit)
        before = text[0...position]
        index = before.count("\n")
        offset = position - (before.rindex("\n") || -1) - 1
        lines = text.split("\n", -1)
        lines = [""] if lines.empty?
        first_visible = [index - limit + 1, 0].max
        last_visible = [index, [lines.length - limit, 0].max].min
        @draft_top = @draft_top.clamp(first_visible, last_visible)
        @left = 0 if @active_line != index
        @active_line = index
        column = nil
        rows = lines[@draft_top, limit].map.with_index(@draft_top) do |line, number|
          row, cursor_column = format_row(line, number == index ? offset : nil, columns, prompt: number.zero?)
          column = cursor_column if number == index
          row
        end
        [rows, index - @draft_top, column]
      end

      def format_row(text, position, columns, prompt:)
        prefix = prompt ? fit(prompt_cells_for_redraw, columns / 2) : []
        prompt_text = prompt && @prompt.is_a?(PromptFormat) ? @prompt.render(prefix) : prefix.map(&:first).join
        width = prefix.sum(&:last)
        available = [columns - width - 1, 1].max
        cells = TerminalText.locale_cells(text)
        left = 0
        column = nil
        if position
          left = [@left, position].min
          consumed = cells[left...position].sum(&:last)
          while left < position && consumed >= available
            consumed -= cells[left].last
            left += 1
          end
          @left = left
          column = width + consumed + 1
        end
        [prompt_text + fit(cells[left..], available).map(&:first).join, column]
      end

      def menu_rows(menu, columns, limit)
        return [] unless menu && limit.positive?

        candidates, selected = menu
        count = [candidates.length, limit].min
        start = selected.clamp(0, candidates.length - count)
        candidates[start, count].map.with_index(start) do |candidate, index|
          text = (index == selected ? "> " : "  ") + candidate
          fit(TerminalText.locale_cells(text), columns - 1).map(&:first).join
        end
      end

      def render_frame(draft_rows, menu_lines, cursor, column, height)
        rows = draft_rows + menu_lines
        count = [rows.length, [@frame_rows, height].min].max
        output = @cursor_row.positive? ? +TerminalSequences.move_up([@cursor_row, height - 1].min) : +""
        count.times do |index|
          output << (index.zero? ? "\r" : "\r\n") << rows[index].to_s << TerminalSequences::ERASE_LINE_END
        end
        up = count - cursor - 1
        output << TerminalSequences.move_up(up) if up.positive?
        output << TerminalSequences.move_to_column(column)
        @frame_rows, @cursor_row, @draft_rows = rows.length, cursor, draft_rows.length
        write(output)
      end

      def finish_frame
        return if @frame_rows.zero?

        output = +""
        below = @draft_rows - @cursor_row - 1
        output << TerminalSequences.move_down(below) if below.positive?
        extra = @frame_rows - @draft_rows
        extra.times { output << "\r\n" << TerminalSequences::ERASE_LINE_END }
        output << TerminalSequences.move_up(extra) if extra.positive?
        write(output) unless output.empty?
      end

      def prompt_cells_for_redraw
        @prompt_cells ||= if @prompt.is_a?(PromptFormat)
                            @prompt.cells(@editor.encoding)
                          else
                            TerminalText.locale_cells(@prompt)
                          end
      end

      def fit(cells, limit)
        used = 0
        cells.take_while { |_, width| (used += width) <= limit }
      end
    end
  end
end
