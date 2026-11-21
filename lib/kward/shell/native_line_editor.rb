require_relative "../terminal/keys"
require_relative "../terminal/sequences"
require_relative "native_locale"
require_relative "native_syntax"

module Kward
  module NativeShell
    # Non-modal edit state. The terminal adapter owns byte reads and redraws.
    class LineEditor
      # Keep path and flag punctuation in words, like the default Zsh Emacs keymap.
      WORD_CHARACTERS = "[:alnum:]#{Regexp.escape('*?_-.[]~=/&;!#$%^(){}<>')}".freeze
      WORD_START = /\G[#{WORD_CHARACTERS}]*[^#{WORD_CHARACTERS}]*/
      WORD_END = /\G[^#{WORD_CHARACTERS}]*[#{WORD_CHARACTERS}]*/

      HISTORY_SEARCH_KEYS = [TerminalKeys::CTRL_R, TerminalKeys::CTRL_S].freeze
      CUT_LIMIT = 8
      UNDO_LIMIT = 100

      def initialize(runtime)
        @runtime = runtime
        @cuts = []
      end

      def encoding
        @locale.encoding
      end

      def read(get:, paste:, changed:, alert:, clear:, erase:, kill:, eof:, interrupt:, suggestions: false, draft: nil, completion_cancel: nil)
        Locale.with(@runtime.variables) do |locale|
          @locale = locale
          @line = draft.to_s.b.force_encoding(encoding).scrub
          @position = @line.length
          @history = @runtime.history
          @cuts.clear if @private_edit != @history.paused?
          @private_edit = @history.paused?
          suggestions &&= !@private_edit
          @history.refresh
          @entries = @history.entries
          @index = @entries.length
          @history_prefix = nil
          @vertical_column = nil
          @menu = nil
          @last_tab = false
          @continued_cut = false
          @undo = []
          @last_yank = nil
          loop do
            suggestion = suggestion_for_draft if suggestions
            draw(changed, suggestion)
            key = get.call
            return nil unless key
            raise Interrupt if key == interrupt
            next if @menu && handle_menu(key)
            if HISTORY_SEARCH_KEYS.include?(key) && ![erase, kill, eof].include?(key)
              @last_tab = @continued_cut = false
              @last_yank = nil
              refresh_history if @index == @entries.length
              @history_prefix = nil
              key = search_history(key, get: get, changed: changed, alert: alert, clear: clear, erase: erase, interrupt: interrupt)
              return nil unless key
              next if key == :cancel_search
            end
            if TerminalKeys::RETURN.include?(key)
              draw(changed, nil) if suggestion
              return @line + "\n"
            end
            return nil if key == eof && @line.empty?

            @vertical_column = nil unless (TerminalKeys::UP + TerminalKeys::DOWN).include?(key)
            @last_tab = false unless TerminalKeys::TAB.include?(key)
            @last_yank = nil unless TerminalKeys::ALT_Y.include?(key)
            consecutive_cut = @continued_cut
            @continued_cut = false
            case key
            when *TerminalKeys::TAB then complete(alert, completion_cancel)
            when *TerminalKeys::UP then move_vertical(-1)
            when *TerminalKeys::DOWN then move_vertical(1)
            when TerminalKeys::CTRL_P then recall(-1)
            when TerminalKeys::CTRL_N then recall(1)
            when *TerminalKeys::LEFT, TerminalKeys::CTRL_B then @position = [@position - 1, 0].max
            when *TerminalKeys::RIGHT
              suggestion ? insert(suggestion) : move_right
            when TerminalKeys::CTRL_F then move_right
            when *TerminalKeys::HOME, TerminalKeys::CTRL_A then @position = line_start
            when *TerminalKeys::END_KEY, TerminalKeys::CTRL_E then @position = line_end
            when erase, *TerminalKeys::BACKSPACE
              replace(@position - 1, 1) if @position.positive?
            when kill then cut(0, @line.length)
            when eof, *TerminalKeys::DELETE then replace(@position, 1) if @position < @line.length
            when *TerminalKeys::ALT_LEFT, *TerminalKeys::ALT_B then @position = previous_word
            when *TerminalKeys::ALT_RIGHT, *TerminalKeys::ALT_F then @position = @line.match(WORD_START, @position).end(0)
            when TerminalKeys::CTRL_K then cut(@position, kill_line_end, consecutive_cut)
            when TerminalKeys::CTRL_W, *TerminalKeys::ALT_BACKSPACE then cut(previous_word, @position, consecutive_cut)
            when *TerminalKeys::ALT_D then cut(@position, @line.match(WORD_END, @position).end(0), consecutive_cut)
            when TerminalKeys::CTRL_Y then yank(0)
            when *TerminalKeys::ALT_Y then yank_pop
            when *TerminalKeys::ALT_LAST_WORD then insert_last_word(alert)
            when TerminalKeys::CTRL_L then clear.call
            when TerminalKeys::CTRL_T, TerminalKeys::CTRL_T_CSI_U then transpose
            when TerminalKeys::CTRL_UNDERSCORE then undo
            when *TerminalKeys::SHIFT_ENTER then insert("\n")
            when TerminalSequences::BRACKETED_PASTE_START
              text = paste.call
              return nil unless text
              insert(text)
            else
              insert(key) if printable_key?(key)
            end
          rescue EncodingError, ExpansionError
            alert.call
          end
        end
      ensure
        @locale = @line = @draft = @entries = @undo = @last_yank = @history_prefix = @menu = nil
      end

      private

      def complete(alert, cancel)
        completion = @runtime.complete_line(@line, @position, cancel: cancel)
        return alert.call unless completion

        if @line[completion.range] != completion.replacement
          replace(completion.range.begin, completion.range.size, @locale.text(completion.replacement))
        elsif @last_tab && completion.candidates.length > 1
          @menu = completion
          @menu_index = 0
        else
          alert.call
        end
        @last_tab = true
      end

      def draw(changed, suggestion)
        return changed.call(@line, @position, suggestion: suggestion) unless @menu

        text = @line.dup
        choice = @locale.text(@menu.choices.fetch(@menu_index))
        text[@menu.choice_range] = choice
        changed.call(text, @menu.choice_range.begin + choice.length, menu: [@menu.candidates, @menu_index])
      end

      def suggestion_for_draft
        return if @menu || @line.empty? || @line.include?("\n") || @position != @line.length || @index != @entries.length

        @entries.reverse_each do |_, entry|
          next unless entry.b.start_with?(@line.b)

          text = @locale.text(entry)
          next unless text.valid_encoding? && text.length > @position && !text.match?(/[[:cntrl:]]/)

          return text[@position..]
        end
        nil
      end

      def move_right
        @position += 1 if @position < @line.length
      end

      def handle_menu(key)
        case key
        when *TerminalKeys::TAB, *TerminalKeys::SHIFT_TAB
          direction = TerminalKeys::TAB.include?(key) ? 1 : -1
          @menu_index = (@menu_index + direction) % @menu.choices.length
          return true
        when TerminalKeys::ESCAPE
          @menu = nil
          @last_tab = false
          return true
        end

        replace(@menu.choice_range.begin, @menu.choice_range.size, @locale.text(@menu.choices.fetch(@menu_index)))
        @menu = nil
        @last_tab = false
        TerminalKeys::RETURN.include?(key)
      end

      def previous_word
        @position - @line[0, @position].reverse.match(WORD_END).end(0)
      end

      def line_start(position = @position)
        (@line[0...position].rindex("\n") || -1) + 1
      end

      def line_end(position = @position)
        @line.index("\n", position) || @line.length
      end

      def kill_line_end
        finish = line_end
        finish == @position && finish < @line.length ? finish + 1 : finish
      end

      def move_vertical(direction)
        start = line_start
        finish = line_end
        return recall(direction, prefix: true) unless @line.include?("\n")
        return if direction.negative? ? start.zero? : finish == @line.length

        @vertical_column ||= @position - start
        target = direction.negative? ? line_start(start - 1) : finish + 1
        @position = [target + @vertical_column, line_end(target)].min
      end

      def cut(start, finish, consecutive = false)
        return if start == finish

        text = @line[start...finish]
        if consecutive
          @cuts[0] = start < @position ? text + @cuts.first : @cuts.first + text
        else
          @cuts.unshift(text)
          @cuts.pop if @cuts.length > CUT_LIMIT
        end
        replace(start, finish - start)
        @continued_cut = true
      end

      def yank(index, start = @position, length = 0)
        return if @cuts.empty?

        text = @locale.text(@cuts.fetch(index)).scrub
        replace(start, length, text)
        @last_yank = [index, start, text.length]
      end

      def yank_pop
        return unless @last_yank && @cuts.length > 1

        index, start, length = @last_yank
        yank((index + 1) % @cuts.length, start, length)
      end

      def insert_last_word(alert)
        return alert.call unless @index.positive?

        word = Lexer.new(history_text(@index - 1)).tokens.reverse_each.find { |token| token.value.is_a?(Word) }
        word ? insert(word.source) : alert.call
      rescue SyntaxError
        alert.call
      end

      def transpose
        right = @position
        right -= 1 if right == @line.length || @line[right] == "\n"
        return unless right.positive?

        pair = @line[right - 1, 2]
        replace(right - 1, 2, pair.reverse) unless pair.include?("\n")
      end

      def insert(text)
        replace(@position, 0, @locale.text(text))
      end

      def replace(start, length, text = "")
        removed = @line[start, length]
        if removed != text
          @history_prefix = nil
          @undo << [start, text.length, removed, @position]
          @undo.shift if @undo.length > UNDO_LIMIT
          @line[start, length] = text
        end
        @position = start + text.length
      end

      def undo
        change = @undo.pop
        return unless change

        start, length, text, cursor = change
        @history_prefix = nil
        @line[start, length] = text
        @position = cursor
      end

      def printable_key?(key)
        key.length == 1 && key.ord >= 32 && key.ord != 127
      end

      def refresh_history
        @history.refresh
        @entries = @history.entries
        @index = @entries.length
      end

      def recall(direction, prefix: false)
        if @index == @entries.length
          return if direction.positive?

          refresh_history
        end
        @history_prefix = prefix ? (@history_prefix || @line.dup) : nil
        index = @index + direction
        while index.between?(0, @entries.length)
          if index == @entries.length || !@history_prefix || history_text(index).start_with?(@history_prefix)
            select_history(index)
            @history_prefix = nil if index == @entries.length
            return
          end
          index += direction
        end
      end

      def search_history(key, get:, changed:, alert:, clear:, erase:, interrupt:)
        query = "".force_encoding(encoding)
        direction = history_direction(key)
        anchor = @index
        index = nil
        failed = false
        loop do
          label = direction.negative? ? "reverse-i-search" : "forward-i-search"
          label = "failed #{label}" if failed
          prefix = "(#{label}: #{query}"
          changed.call(prefix + "): " + (index ? history_text(index) : ""), prefix.length)
          key = get.call
          return nil unless key
          raise Interrupt if key == interrupt

          match = nil
          case key
          when TerminalKeys::CTRL_G, TerminalKeys::ESCAPE then return :cancel_search
          when TerminalKeys::CTRL_L
            clear.call
            next
          when *HISTORY_SEARCH_KEYS
            direction = history_direction(key)
            match = history_match(query, index ? index + direction : anchor, direction)
            anchor = match if match
          when erase, *TerminalKeys::BACKSPACE
            query.chop!
            index = nil if query.empty?
            match = history_match(query, anchor, direction) unless query.empty?
          else
            if printable_key?(key)
              query << key
              match = history_match(query, anchor, direction)
            elsif TerminalKeys::RETURN.include?(key) && (!index || failed)
              alert.call
              next
            else
              select_history(index) if index && !failed
              return key
            end
          end
          index = match if match
          failed = match.nil? && !query.empty?
        end
      end

      def history_direction(key)
        key == TerminalKeys::CTRL_R ? -1 : 1
      end

      def history_match(query, start, direction)
        fold = query == query.downcase
        start = @entries.length - 1 if direction.negative? && start == @entries.length
        while start.between?(0, @entries.length - 1)
          text = history_text(start)
          text = text.downcase if fold
          return start if text.include?(query)
          start += direction
        end
        nil
      end

      def select_history(index)
        @draft = @line.dup if @index == @entries.length
        @line = index == @entries.length ? @draft.dup : history_text(index)
        @index = index
        @position = @line.length
        @undo.clear
      end

      def history_text(index)
        @locale.text(@entries.fetch(index).last).scrub
      end
    end
  end
end
