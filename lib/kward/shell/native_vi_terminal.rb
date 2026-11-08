require "io/console"
require_relative "native_vi"
require_relative "../terminal/sequences"
require_relative "../terminal/locale_text"

module Kward
  module NativeShell
    # Raw terminal ownership is scoped to reading one standalone edit line.
    # Byte reads never consume a following command's stdin.
    class ViTerminal
      GET_ATTRIBUTES = Fiddle::Function.new(Fiddle::Handle::DEFAULT["tcgetattr"], [Fiddle::TYPE_INT, Fiddle::TYPE_VOIDP], Fiddle::TYPE_INT)

      def initialize(runtime)
        @runtime = runtime
        @editor = ViEditor.new(runtime)
      end

      def read(source, prompt:, input:, output:, error:)
        @source, @prompt, @error = source, prompt, error
        @streams = { input: input, output: output, error: error }
        @left = 0
        controls = control_characters(source)
        result = source.raw(intr: false) do
          @editor.read(get: method(:character), changed: method(:redraw), alert: -> { error.write(TerminalSequences::ALERT); error.flush }, **controls)
        end
        error.puts
        result
      rescue ExecutionError, SystemCallError, IOError => e
        @runtime.vi_input_error(e, error: error)
        ViEditor::Result.new(text: "")
      ensure
        @source = @error = @streams = nil
      end

      private

      def control_characters(source)
        attributes = "\0" * 256
        raise SystemCallError.new("tcgetattr", Fiddle.last_error) if GET_ATTRIBUTES.call(source.fileno, attributes) < 0
        offset, erase, kill, eof, interrupt = Locale::DARWIN ? [32, 3, 5, 0, 8] : [17, 2, 3, 4, 0]
        { erase: attributes.byteslice(offset + erase, 1), kill: attributes.byteslice(offset + kill, 1), eof: attributes.byteslice(offset + eof, 1), interrupt: attributes.byteslice(offset + interrupt, 1) }
      end

      def character
        text = +"".b
        loop do
          unless IO.select([@source], nil, nil, 0.1)
            @runtime.poll_signals(**@streams)
            @runtime.notify_jobs(error: @error)
            return nil if @runtime.exited
            next
          end
          text << @source.readpartial(1)
          value = text.dup.force_encoding(@editor.encoding)
          return value if value.valid_encoding?
          # Invalid input is not a character in the selected locale. Reject it
          # rather than reading an unbounded invalid prefix or rendering controls.
          raise ExecutionError, "invalid terminal character" if text.bytesize >= 8
        end
      rescue EOFError
        nil
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
        prompt_cells = fit(TerminalText.locale_cells(@prompt), columns / 2)
        prompt_width = prompt_cells.sum(&:last)
        available = [columns - prompt_width - 1, 1].max
        cells = TerminalText.locale_cells(text)
        @left = position if position < @left
        @left += 1 while @left < position && cells[@left...position].sum(&:last) >= available
        visible = fit(cells[@left..] || [], available)
        column = prompt_width + cells[@left...position].sum(&:last) + 1
        @error.write(TerminalSequences::CARRIAGE_RETURN + prompt_cells.map(&:first).join + visible.map(&:first).join +
                     TerminalSequences::ERASE_LINE_END + TerminalSequences.move_to_column(column))
        @error.flush
      end

      def fit(cells, limit)
        used = 0
        cells.take_while { |_, width| (used += width) <= limit }
      end
    end
  end
end
