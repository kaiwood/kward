module Kward
  module NativeShell
    # Shell patterns for case and parameter trimming, not filesystem globbing.
    # Wildcards match slashes and leading dots here. Only a single-character
    # bracket expression uses Regexp; arbitrary shell text is always escaped.
    class Pattern
      CLASSES = %w[alnum alpha blank cntrl digit graph lower print punct space upper xdigit].freeze

      class LimitError < ArgumentError; end
      MAX_MATCH_STEPS = 1_000_000
      MAX_MATCH_BYTES = 16 * 1024 * 1024

      # Test alternatives separately: libc fnmatch can commit to a shorter
      # element in a mixed bracket even when a longer element would match.
      class Bracket
        def initialize(locale, elements, negated)
          @locale, @negated = locale, negated
          @elements = []
          until elements.empty?
            first = elements.shift
            if elements.length >= 2 && elements.first.first == :dash
              elements.shift
              @elements << [:range, first, elements.shift]
            else
              @elements << first
            end
          end
        end

        def match?(value)
          return false unless @locale.collating_element?(value)
          matched = @elements.any? do |kind, text, last|
            case kind
            when :range
              lower, upper = endpoint(text), endpoint(last)
              lower && upper && @locale.compare(lower, value) <= 0 && @locale.compare(value, upper) <= 0
            when :symbol then @locale.symbol?(text, value)
            when :equivalent then @locale.equivalent?(text, value)
            when :class then value.length == 1 && @locale.bracket?("[[:#{text}:]]", value)
            else value == text
            end
          end
          @negated ? !matched : matched
        end

        private

        def endpoint(element)
          kind, text = element
          text if %i[literal dash].include?(kind) || kind == :symbol && @locale.symbol?(text, text)
        end
      end

      def initialize(source, locale: nil)
        @locale = locale
        @source = locale ? locale.text(source) : source
        @index = 0
        @tokens = []
        while (character = @source[@index])
          @index += 1
          @tokens << case character
          when "*" then :star
          when "?" then :any
          when "\\"
            escaped = @source[@index]
            @index += 1 if escaped
            escaped || "\\"
          when "[" then bracket || "["
          else character
          end
        end
      end

      def wildcards?
        @tokens.any? { |token| token == :star || token == :any || token.is_a?(Regexp) || token.is_a?(Bracket) }
      end

      def match?(value)
        characters = (@locale ? @locale.text(value) : value).chars
        return match_collating(characters) if @locale&.multichar && @tokens.any? { |token| token.is_a?(Bracket) }
        token_index = 0
        value_index = 0
        star_index = nil
        retry_index = 0
        while value_index < characters.length
          token = @tokens[token_index]
          if token == :star
            star_index = token_index
            token_index += 1
            retry_index = value_index
          elsif token == :any || (token.is_a?(Regexp) || token.is_a?(Bracket)) && token.match?(characters[value_index]) || token == characters[value_index]
            token_index += 1
            value_index += 1
          elsif star_index
            token_index = star_index + 1
            retry_index += 1
            value_index = retry_index
          else
            return false
          end
        end
        token_index += 1 while @tokens[token_index] == :star
        token_index == @tokens.length
      end

      private

      # Iterative frontier matching keeps both short and long collating-element
      # paths alive without recursive backtracking. Work and copied bytes are
      # bounded explicitly, including unsuccessful prefix probes.
      def match_collating(characters)
        positions = [0]
        steps = bytes = 0
        @tokens.each_with_index do |token, index|
          if token == :star
            return true if index == @tokens.length - 1
            first = positions.min
            steps += characters.length - first + 1
            raise LimitError, "collating pattern match exceeds work limit" if steps > MAX_MATCH_STEPS
            positions = (first..characters.length).to_a
          else
            following = {}
            positions.each do |start|
              next if start == characters.length
              if token.is_a?(Bracket)
                candidate = +""
                start.upto(characters.length - 1) do |finish|
                  candidate << characters[finish]
                  steps += 1
                  bytes += candidate.bytesize
                  raise LimitError, "collating pattern match exceeds work limit" if steps > MAX_MATCH_STEPS || bytes > MAX_MATCH_BYTES
                  following[finish + 1] = true if token.match?(candidate)
                end
              else
                steps += 1
                following[start + 1] = true if token == :any || token == characters[start]
              end
            end
            positions = following.keys
          end
          raise LimitError, "collating pattern match exceeds work limit" if steps > MAX_MATCH_STEPS
          return false if positions.empty?
        end
        positions.include?(characters.length)
      end

      def bracket_literal(character)
        character == "&" ? "\\&" : Regexp.escape(character)
      end

      def bracket
        start = @index
        content = +""
        elements = []
        negated = ["!", "^"].include?(@source[@index])
        if negated
          content << "^"
          @index += 1
        end
        if @source[@index] == "]"
          content << "\\]"
          elements << [:literal, "]"]
          @index += 1
        end
        entries = 0
        while (character = @source[@index])
          if character == "]" && (entries.positive? || content.end_with?("\\]"))
            @index += 1
            return Bracket.new(@locale, elements, negated) if @locale
            return Regexp.new("\\A[#{content}]\\z")
          elsif character == "\\" && @source[@index + 1]
            content << bracket_literal(@source[@index + 1])
            elements << [:literal, @source[@index + 1]]
            @index += 2
          elsif (match = @source[@index..].match(/\A\[([.=])(.*?)\1\]/m))
            # Collating symbols and equivalence classes are interpreted by libc.
            return /\A\b\B\z/ if !@locale && match[2].length != 1
            content << bracket_literal(match[2])
            elements << [match[1] == "." ? :symbol : :equivalent, match[2]]
            @index += match[0].length
          elsif (match = @source[@index..].match(/\A\[:([a-z]+):\]/)) && CLASSES.include?(match[1])
            content << match[0]
            elements << [:class, match[1]]
            @index += match[0].length
          else
            content << (character == "-" ? "-" : bracket_literal(character))
            elements << [character == "-" ? :dash : :literal, character]
            @index += 1
          end
          entries += 1
        end
        @index = start
        nil
      rescue RegexpError
        # An invalid range cannot match a character.
        /\A\b\B\z/
      end
    end
  end
end
