require_relative "../terminal/keys"
require_relative "native_locale"
require_relative "native_pattern"

module Kward
  module NativeShell
    # Character-oriented vi edit state. IO/raw mode and command execution belong
    # to the standalone runner; history copies never mutate retained entries.
    class ViEditor
      Result = Struct.new(:text, :external, keyword_init: true)
      class InvalidCommand < StandardError; end
      MOTIONS = " hl0^$|wWbBeEfFtT;,".freeze
      MAX_MACRO_DEPTH = 100
      MAX_MACRO_BYTES = 1_048_576
      CHANGES = "aAiIRcdCDSrxXpP~_*\\".freeze

      def initialize(runtime)
        @runtime = runtime
        @saved = ""
      end

      def encoding
        @locale.encoding
      end

      def read(get:, changed:, alert:, erase: TerminalKeys::BACKSPACE.last, kill: TerminalKeys::CTRL_U, eof: TerminalKeys::CTRL_D, interrupt: TerminalKeys::CTRL_C)
        @get, @changed, @alert = get, changed, alert
        @erase, @kill, @eof, @interrupt = erase, kill, eof, interrupt
        @line, @draft, @original = +"", +"", +""
        @position = 0
        @history_index = entries.length
        @insert = @initial = true
        @replace = false
        @queue = []
        @recording = @undo = nil
        @macro_bytes = 0
        Locale.with(@runtime.variables) do |locale|
          @locale = locale
          @line.force_encoding(locale.encoding)
          loop do
            @changed.call(@line, @position)
            key = input
            return nil unless key
            raise Interrupt if key == @interrupt
            if @insert
              if TerminalKeys::RETURN.include?(key)
                @recording[-1] = TerminalKeys::ESCAPE if @recording
                finish_change
                return Result.new(text: @line + "\n")
              end
              return nil if key == @eof && @line.empty?
              insert_key(key)
            else
              return Result.new(text: @line + "\n") if TerminalKeys::RETURN.include?(key)
              result = command(key)
              return result if result
            end
          rescue InvalidCommand, SyntaxError, ExpansionError, ExecutionError, ArgumentError, RangeError, SystemCallError, IOError
            @recording = nil
            @alert.call
          end
        end
      ensure
        @locale = @get = @changed = @alert = nil
      end

      private

      def entries
        @runtime.history.entries
      end

      def input
        value = @queue.empty? ? @get.call : @queue.shift
        value, @macro_depth = value.is_a?(Array) ? value : [value, 0]
        @recording << value if @recording && value
        value
      end

      def operand(interrupt: true)
        key = input || raise(InvalidCommand)
        raise Interrupt if interrupt && key == @interrupt
        key
      end

      def insert_key(key)
        case key
        when TerminalKeys::ESCAPE
          @insert = @replace = false
          @position = [@position - 1, 0].max
          @original = @line.dup if @initial
          @initial = false
          finish_change
        when @erase
          if @position > 0
            @line.slice!(@position - 1)
            @position -= 1
          else
            @alert.call
          end
        when @kill
          @line.clear
          @position = 0
        when TerminalKeys::CTRL_W
          start = @position
          start -= 1 while start > 0 && blank?(@line[start - 1])
          kind = category(@line[start - 1]) if start > 0
          start -= 1 while start > 0 && category(@line[start - 1]) == kind
          @line.slice!(start...@position)
          @position = start
        else
          key = operand(interrupt: false) if key == TerminalKeys::CTRL_V
          key = @locale.text(key)
          if @replace && @position < @line.length
            @line[@position] = key
          else
            @line.insert(@position, key)
          end
          @position += key.length
        end
      end

      def command(key)
        digits = +""
        while key.match?(/\A[0-9]\z/) && (key != "0" || !digits.empty?)
          digits << key
          key = operand
        end
        count = digits.empty? ? 1 : digits.to_i
        @recording = digits.chars + [key] if CHANGES.include?(key)
        @changed_command = false
        case key
        when *MOTIONS.chars
          @position = motion(key, count).first
        when "a", "A", "i", "I", "R"
          begin_change
          @position = [@position + 1, @line.length].min if key == "a"
          @position = @line.length if key == "A"
          @position = 0 if key == "I"
          @insert = true
          @replace = key == "R"
        when "c", "d", "y"
          operation(key, operand, count)
        when "C", "D", "S", "Y"
          operation({ "C" => "c", "D" => "d", "S" => "c", "Y" => "y" }.fetch(key), key == "S" ? "c" : "$", count)
        when "x", "X"
          raise InvalidCommand if @line.empty? || key == "X" && @position.zero?
          from = key == "X" ? [@position - count, 0].max : @position
          to = key == "X" ? @position : [@position + count, @line.length].min
          delete(from...to)
        when "p", "P"
          raise InvalidCommand if @saved.empty?
          begin_change
          at = key == "P" ? @position : [@position + 1, @line.length].min
          text = @saved * count
          @line.insert(at, text)
          @position = at + text.length - 1
        when "r"
          character = operand
          raise InvalidCommand if @line.empty? || character == TerminalKeys::ESCAPE
          begin_change
          length = [count, @line.length - @position].min
          @line[@position, length] = character * length
          @position += length - 1
        when "~"
          raise InvalidCommand if @line.empty?
          begin_change
          length = [count, @line.length - @position].min
          @line[@position, length] = @locale.swapcase(@line[@position, length])
          @position = [@position + length, @line.length - 1].min
        when "u"
          raise InvalidCommand unless @undo && @history_index == entries.length
          previous = [@line.dup, @position]
          @line, @position = @undo
          @undo = previous
        when "U"
          raise InvalidCommand unless @history_index == entries.length
          begin_change
          @line = @original.dup
          @position = 0
        when "k", "-", "j", "+", "G"
          target = case key
          when "k", "-" then @history_index - count
          when "j", "+" then @history_index + count
          else digits.empty? ? 0 : entries.index { |number, _| number == count }
          end
          raise InvalidCommand unless target && target >= 0
          @alert.call if target > entries.length
          select_history([target, entries.length].min)
        when "/", "?"
          pattern = +""
          loop do
            char = operand
            break if TerminalKeys::RETURN.include?(char)
            raise InvalidCommand if char == TerminalKeys::ESCAPE
            char == @erase ? pattern.chop! : pattern << char
            @changed.call(key + pattern, pattern.length + 1)
          end
          @search = pattern unless pattern.empty?
          @search_direction = key == "/" ? -1 : 1
          search(@search_direction)
        when "n", "N"
          raise InvalidCommand unless @search_direction
          search(key == "N" ? -@search_direction : @search_direction)
        when "_"
          words = entries.last&.last.to_s.split(/[[:space:]]+/)
          word = digits.empty? ? words.last : words[count - 1]
          raise InvalidCommand unless word
          begin_change
          @position = [@position + 1, @line.length].min
          @line.insert(@position, " " + word)
          @position += word.length + 1
          @insert = true
        when "."
          raise InvalidCommand unless @last_change
          repeat = @last_change.dup
          repeat.shift while !digits.empty? && repeat.first&.match?(/\A[0-9]\z/)
          repeat = digits.chars + repeat unless digits.empty?
          @queue = repeat + @queue
        when "@"
          letter = operand
          raise InvalidCommand unless letter.match?(/\A[A-Za-z]\z/)
          value = @runtime.aliases.fetch("_#{letter}", "")
          @macro_bytes += value.bytesize
          raise ExecutionError, "vi alias expansion limit exceeded" if @macro_bytes > MAX_MACRO_BYTES || @macro_depth >= MAX_MACRO_DEPTH
          @queue = @locale.text(value).chars.map { |char| [char, @macro_depth + 1] } + @queue
        when "#"
          return Result.new(text: "#" + @line + "\n")
        when "v"
          text = digits.empty? ? @line : entries.find { |number, _| number == count }&.last
          raise InvalidCommand unless text
          return Result.new(text: text, external: true)
        when "=", "\\", "*"
          expand_word(key)
        when TerminalKeys::CTRL_L
          # The terminal adapter redraws after every operation.
        else
          raise InvalidCommand
        end
        finish_change unless @insert
        nil
      end

      def begin_change
        if @history_index != entries.length
          @history_index = entries.length
          @original = @line.dup
        end
        @undo = [@line.dup, @position]
        @changed_command = true
      end

      def finish_change
        @last_change = @recording.dup if @recording && @changed_command
        @recording = nil
      end

      def delete(range)
        begin_change
        @saved = @line.slice!(range)
        @position = [range.begin, [@line.length - 1, 0].max].min
      end

      def operation(operator, movement, count)
        if movement == operator
          range = 0...@line.length
        else
          target, inclusive = motion(movement, count)
          from, to = [@position, target].minmax
          to += 1 if target >= @position && inclusive
          range = from...to
        end
        if operator == "y"
          @saved = @line[range]
        else
          delete(range)
          if operator == "c"
            @position = [range.begin, @line.length].min
            @insert = true
          end
        end
      end

      def motion(key, count)
        last = [@line.length - 1, 0].max
        target = @position
        inclusive = false
        case key
        when "h" then target = [target - count, 0].max
        when "l", " " then target = [target + count, last].min
        when "0" then target = 0
        when "^" then target = @line.index(/[^ \t]/) || 0
        when "$" then target = last; inclusive = true
        when "|" then target = [count - 1, last].min
        when "w", "W", "e", "E", "b", "B"
          [count, @line.length + 1].min.times do
            target = word_motion(target, key)
          end
          inclusive = "eE".include?(key) || target == last && "wW".include?(key)
        when "f", "F", "t", "T", ";", ","
          if key == ";" || key == ","
            raise InvalidCommand unless @find
            character, direction, till = @find
            direction = -direction if key == ","
            repeat = true
          else
            character = operand
            direction = key == key.upcase ? -1 : 1
            till = key.downcase == "t"
            @find = [character, direction, till]
          end
          raise InvalidCommand if count > @line.length
          start = target + (repeat && till ? direction * 2 : direction)
          count.times do
            raise InvalidCommand unless start.between?(0, last)
            target = direction == 1 ? @line.index(character, start) : @line.rindex(character, start)
            raise InvalidCommand unless target
            start = target + direction
          end
          target -= direction if till
          inclusive = direction == 1
        else
          raise InvalidCommand
        end
        raise InvalidCommand if target == @position && "hl wWbBeE".include?(key)
        [target, inclusive]
      end

      def word_motion(position, key)
        last = [@line.length - 1, 0].max
        big = key == key.upcase
        case key.downcase
        when "w"
          kind = category(@line[position], big: big)
          position += 1 while position < last && category(@line[position], big: big) == kind
          position += 1 while position < last && blank?(@line[position])
        when "b"
          position -= 1 if position > 0
          position -= 1 while position > 0 && blank?(@line[position])
          kind = category(@line[position], big: big)
          position -= 1 while position > 0 && category(@line[position - 1], big: big) == kind
        when "e"
          position += 1 if position < last
          position += 1 while position < last && blank?(@line[position])
          kind = category(@line[position], big: big)
          position += 1 while position < last && category(@line[position + 1], big: big) == kind
        end
        position
      end

      def blank?(character)
        character && (character == "\n" || @locale.bracket?("[[:blank:]]", character))
      end

      def category(character, big: false)
        return :blank if blank?(character) || !character
        return :word if big || character == "_" || @locale.bracket?("[[:alnum:]]", character)
        :punctuation
      end

      def select_history(index)
        @draft = @line.dup if @history_index == entries.length
        @line = @locale.text(index == entries.length ? @draft : entries.fetch(index).last)
        @history_index = index
        @position = 0
      end

      def search(direction)
        raise InvalidCommand unless @search && !@search.empty?
        pattern = @search.start_with?("^") ? @search.delete_prefix("^") + "*" : "*#{@search}*"
        matcher = Pattern.new(pattern, locale: @locale)
        index = @history_index + direction
        while index.between?(0, entries.length - 1)
          return select_history(index) if matcher.match?(entries[index].last)
          index += direction
        end
        raise InvalidCommand
      end

      def expand_word(key)
        from = @position
        from -= 1 while from > 0 && !blank?(@line[from - 1])
        to = @position
        to += 1 while to < @line.length && !blank?(@line[to])
        matches = @runtime.vi_expansions(@line[from...to], full: key == "=")
        raise InvalidCommand if matches.empty?
        if key == "="
          @changed.call(matches.join("\n"), nil)
          return
        end
        text = if key == "*"
          matches.map { |match| Shellwords.escape(match) }.join(" ")
        else
          prefix = matches.first.dup
          prefix.chop! until matches.all? { |match| match.start_with?(prefix) }
          suffix = matches.one? && !prefix.end_with?("/") ? " " : ""
          Shellwords.escape(prefix) + suffix
        end
        begin_change
        @line[from...to] = text
        @position = from + text.length
        @insert = true
      end
    end
  end
end
