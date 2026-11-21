require_relative "../terminal/keys"
require_relative "../terminal/sequences"
require_relative "native_locale"

module Kward
  module NativeShell
    # Non-modal edit state. The terminal adapter owns byte reads and redraws.
    class LineEditor
      def initialize(runtime)
        @runtime = runtime
      end

      def encoding
        @locale.encoding
      end

      def read(get:, paste:, changed:, alert:, erase:, kill:, eof:, interrupt:, draft: nil)
        Locale.with(@runtime.variables) do |locale|
          @locale = locale
          @line = draft.to_s.b.force_encoding(encoding).scrub
          @position = @line.length
          @entries = @runtime.history.entries
          @index = @entries.length
          @last_tab = false
          loop do
            changed.call(@line, @position)
            key = get.call
            return nil unless key
            raise Interrupt if key == interrupt
            return @line + "\n" if TerminalKeys::RETURN.include?(key)
            return nil if key == eof && @line.empty?

            @last_tab = false unless TerminalKeys::TAB.include?(key)
            case key
            when *TerminalKeys::TAB then complete(changed, alert)
            when *TerminalKeys::UP, TerminalKeys::CTRL_P then recall(-1)
            when *TerminalKeys::DOWN, TerminalKeys::CTRL_N then recall(1)
            when *TerminalKeys::LEFT, TerminalKeys::CTRL_B then @position = [@position - 1, 0].max
            when *TerminalKeys::RIGHT, TerminalKeys::CTRL_F then @position = [@position + 1, @line.length].min
            when *TerminalKeys::HOME, TerminalKeys::CTRL_A then @position = 0
            when *TerminalKeys::END_KEY, TerminalKeys::CTRL_E then @position = @line.length
            when erase, *TerminalKeys::BACKSPACE
              @line.slice!(@position -= 1) if @position.positive?
            when kill
              @line.clear
              @position = 0
            when eof, *TerminalKeys::DELETE then @line.slice!(@position)
            when TerminalSequences::BRACKETED_PASTE_START
              text = paste.call
              return nil unless text
              insert(text)
            else
              insert(key) if key.length == 1 && key.ord >= 32 && key.ord != 127
            end
          rescue EncodingError, ExpansionError
            alert.call
          end
        end
      ensure
        @locale = @line = @draft = @entries = nil
      end

      private

      def complete(changed, alert)
        completion = @runtime.complete_line(@line, @position)
        return alert.call unless completion

        if @line[completion.range] != completion.replacement
          @line[completion.range] = @locale.text(completion.replacement)
          @position = completion.range.begin + completion.replacement.length
        elsif @last_tab && completion.candidates.length > 1
          changed.call(completion.candidates.join("\n"), nil)
        else
          alert.call
        end
        @last_tab = true
      end

      def insert(text)
        text = @locale.text(text)
        @line.insert(@position, text)
        @position += text.length
      end

      def recall(direction)
        index = @index + direction
        return unless index.between?(0, @entries.length)

        @draft = @line.dup if @index == @entries.length
        @line = index == @entries.length ? @draft.dup : @locale.text(@entries.fetch(index).last).dup
        @index = index
        @position = @line.length
      end
    end
  end
end
