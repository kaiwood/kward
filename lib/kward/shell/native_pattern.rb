module Kward
  module NativeShell
    # Shell patterns for case and parameter trimming, not filesystem globbing.
    # Wildcards match slashes and leading dots here. Only a single-character
    # bracket expression uses Regexp; arbitrary shell text is always escaped.
    class Pattern
      CLASSES = %w[alnum alpha blank cntrl digit graph lower print punct space upper xdigit].freeze

      Bracket = Struct.new(:source, :locale) do
        def match?(value)
          locale.bracket?(source, value)
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

      def bracket_literal(character)
        character == "&" ? "\\&" : Regexp.escape(character)
      end

      def bracket
        start = @index
        content = +""
        if ["!", "^"].include?(@source[@index])
          content << "^"
          @index += 1
        end
        if @source[@index] == "]"
          content << "\\]"
          @index += 1
        end
        entries = 0
        while (character = @source[@index])
          if character == "]" && (entries.positive? || content.end_with?("\\]"))
            @index += 1
            return Bracket.new(@source[(start - 1)...@index], @locale) if @locale
            return Regexp.new("\\A[#{content}]\\z")
          elsif character == "\\" && @source[@index + 1]
            content << bracket_literal(@source[@index + 1])
            @index += 2
          elsif (match = @source[@index..].match(/\A\[([.=])(.*?)\1\]/m))
            # Collating symbols and equivalence classes are interpreted by libc.
            return /\A\b\B\z/ if !@locale && match[2].length != 1
            content << bracket_literal(match[2])
            @index += match[0].length
          elsif (match = @source[@index..].match(/\A\[:([a-z]+):\]/)) && CLASSES.include?(match[1])
            content << match[0]
            @index += match[0].length
          else
            content << (character == "-" ? "-" : bracket_literal(character))
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
