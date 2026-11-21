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
      META_KEYS = (TerminalKeys::ALT_B + TerminalKeys::ALT_D + TerminalKeys::ALT_F + TerminalKeys::ALT_BACKSPACE).freeze

      def initialize(runtime, editor, bracketed_paste: false)
        @runtime = runtime
        @editor = editor
        @bracketed_paste = bracketed_paste
      end

      def read(source, prompt:, input:, output:, error:, draft: nil)
        @source, @prompt, @error = source, prompt, error
        @streams = { input: input, output: output, error: error }
        @left = 0
        controls = control_characters(source)
        callbacks = { get: method(:character), changed: method(:redraw), alert: method(:alert) }
        callbacks.merge!(get: method(:key), paste: method(:read_paste)) if @bracketed_paste
        result = source.raw(intr: false) do
          begin
            write(TerminalSequences::BRACKETED_PASTE_ENABLE) if @bracketed_paste
            @editor.read(**callbacks, **controls, draft: draft)
          ensure
            write(TerminalSequences::BRACKETED_PASTE_RESTORE) if @bracketed_paste
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

      def alert
        write(TerminalSequences::ALERT)
      end

      def write(text)
        @error.write(text)
        @error.flush
      end

      def redraw(text, position)
        unless position
          @error.write("\r\n")
          text.lines(chomp: true).each { |line| @error.write(TerminalText.locale_cells(line).map(&:first).join + "\r\n") }
          @error.flush
          return
        end
        columns = @source.winsize.last
        columns = 80 if columns < 4
        prompt_cells = fit(prompt_cells_for_redraw, columns / 2)
        prompt = @prompt.is_a?(PromptFormat) ? @prompt.render(prompt_cells) : prompt_cells.map(&:first).join
        prompt_width = prompt_cells.sum(&:last)
        available = [columns - prompt_width - 1, 1].max
        cells = TerminalText.locale_cells(text)
        @left = position if position < @left
        @left += 1 while @left < position && cells[@left...position].sum(&:last) >= available
        visible = fit(cells[@left..] || [], available)
        column = prompt_width + cells[@left...position].sum(&:last) + 1
        @error.write(TerminalSequences::CARRIAGE_RETURN + prompt + visible.map(&:first).join +
                     TerminalSequences::ERASE_LINE_END + TerminalSequences.move_to_column(column))
        @error.flush
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
