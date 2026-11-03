require_relative "native_arithmetic"

# Namespace for the Kward CLI agent runtime.
module Kward
  # The deliberately small native kwsh grammar. Words retain quoting information
  # until execution; parsing never expands variables or launches commands.
  module NativeShell
    class SyntaxError < StandardError; end
    class IncompleteInput < SyntaxError; end

    Part = Struct.new(:kind, :text, :quoted, keyword_init: true)
    Word = Struct.new(:parts, keyword_init: true) do
      def literal
        return unless parts.all? { |part| part.kind == :literal && !part.quoted }

        parts.map(&:text).join
      end

      def assignment
        first = parts.first
        return unless first && first.kind == :literal && !first.quoted
        match = first.text.match(/\A([A-Za-z_][A-Za-z0-9_]*)=(.*)\z/m)
        return unless match

        value = [Part.new(kind: :literal, text: match[2], quoted: false)] + parts.drop(1)
        [match[1], Word.new(parts: value)]
      end
    end
    Token = Struct.new(:value, :line, keyword_init: true)
    Node = Struct.new(:kind, :values, keyword_init: true)

    class Lexer
      OPERATORS = %w[&& || >> >& <& ; | > < ( ) { }].freeze

      def initialize(source)
        @source = source
        @index = 0
        @line = 1
      end

      def tokens
        result = []
        until current.nil?
          case current
          when " ", "\t", "\r"
            advance
          when "\\"
            if @source[@index + 1] == "\n"
              advance(2)
            else
              result << Token.new(value: word, line: @line)
            end
          when "#"
            advance until current.nil? || current == "\n"
          when "\n"
            result << Token.new(value: ";", line: @line)
            advance
          else
            line = @line
            operator = OPERATORS.find { |candidate| @source[@index, candidate.length] == candidate }
            if @source[@index, 2] == "<<" || @source[@index, 2] == ";;" || current == "&" && operator != "&&"
              raise SyntaxError, "line #{@line}: unsupported operator near #{@source[@index, 2].inspect}"
            end
            # A descriptor is recognized only when immediately adjacent to redirection.
            if (match = @source[@index..].match(/\A([0-9]+)(>>|>&|<&|>|<)/))
              result << Token.new(value: [:redirect, match[1].to_i, match[2]], line: line)
              advance(match[0].length)
            elsif operator
              result << Token.new(value: operator, line: line)
              advance(operator.length)
            else
              result << Token.new(value: word, line: line)
            end
          end
        end
        result
      end

      private

      def current
        @source[@index]
      end

      def advance(count = 1)
        @line += @source[@index, count].count("\n")
        @index += count
      end

      def literal(parts, text, quoted)
        parts << Part.new(kind: :literal, text: text, quoted: quoted)
      end

      def word
        parts = []
        until current.nil? || current.match?(/[\s;&|<>()]/)
          case current
          when "'"
            advance
            start = @index
            advance until current.nil? || current == "'"
            raise IncompleteInput, "line #{@line}: unclosed single quote" unless current
            literal(parts, @source[start...@index], true)
            advance
          when '"'
            double_quote(parts)
          when "\\"
            advance
            raise IncompleteInput, "line #{@line}: trailing backslash" unless current
            literal(parts, current, true) unless current == "\n"
            advance
          when "$"
            parameter(parts, false)
          when "`"
            raise SyntaxError, "line #{@line}: command substitution is not supported"
          else
            literal(parts, current, false)
            advance
          end
        end
        # Coalesce adjacent literals, preserving quote boundaries.
        merged = []
        parts.each do |part|
          previous = merged.last
          if previous && previous.kind == :literal && part.kind == :literal && previous.quoted == part.quoted
            previous.text += part.text
          else
            merged << part
          end
        end
        Word.new(parts: merged)
      end

      def double_quote(parts)
        advance
        literal(parts, "", true)
        until current.nil? || current == '"'
          case current
          when "$"
            parameter(parts, true)
          when "`"
            raise SyntaxError, "line #{@line}: command substitution is not supported"
          when "\\"
            advance
            raise IncompleteInput, "line #{@line}: unclosed double quote" unless current
            if ['$', '`', '"', "\\", "\n"].include?(current)
              literal(parts, current, true) unless current == "\n"
            else
              literal(parts, "\\#{current}", true)
            end
            advance
          else
            literal(parts, current, true)
            advance
          end
        end
        raise IncompleteInput, "line #{@line}: unclosed double quote" unless current
        advance
      end

      def arithmetic(parts, quoted)
        advance(2)
        start = @index
        depth = 0
        until current.nil?
          if current == "("
            depth += 1
          elsif current == ")"
            if depth.zero?
              raise IncompleteInput, "line #{@line}: unclosed arithmetic expansion; expected ))" unless @source[@index + 1]
              # kwsh permits horizontal whitespace between the final closers.
              # Recognize it here, never by rewriting quoted text or commands.
              closing = @source[@index..][/\A\)[ \t]*\)/]
              unless closing
                raise SyntaxError, "line #{@line}: expected a second ) to close arithmetic expansion"
              end
              expression = @source[start...@index]
              Arithmetic::Parser.new(expression).parse
              parts << Part.new(kind: :arithmetic, text: expression, quoted: quoted)
              advance(closing.length)
              return
            end
            depth -= 1
          end
          advance
        end
        raise IncompleteInput, "line #{@line}: unclosed arithmetic expansion; expected ))"
      rescue Arithmetic::Error => e
        raise SyntaxError, "line #{@line}: #{e.message}"
      end

      def parameter(parts, quoted)
        advance
        if @source[@index, 2] == "(("
          arithmetic(parts, quoted)
          return
        end
        raise SyntaxError, "line #{@line}: command substitution is not supported" if current == "("
        raise SyntaxError, "line #{@line}: dollar-single-quoting is not supported" if current == "'" && !quoted
        if current == "{"
          advance
          start = @index
          advance until current.nil? || current == "}"
          raise IncompleteInput, "line #{@line}: unclosed parameter expansion" unless current
          name = @source[start...@index]
          advance
          unless name.match?(/\A(?:[A-Za-z_][A-Za-z0-9_]*|[0-9]+|[?@#*$])\z/)
            raise SyntaxError, "line #{@line}: unsupported parameter expansion"
          end
        elsif (match = @source[@index..].to_s.match(/\A(?:[A-Za-z_][A-Za-z0-9_]*|[0-9?@#*$])/))
          name = match[0]
          advance(name.length)
        elsif ["!", "-"].include?(current)
          raise SyntaxError, "line #{@line}: unsupported special parameter $#{current}"
        else
          literal(parts, "$", quoted)
          return
        end
        parts << Part.new(kind: :parameter, text: name, quoted: quoted)
      end
    end

    class Parser
      RESERVED = %w[if then elif else fi for in do done while until case esac select function time !].freeze
      REDIRECTS = %w[< > >> >& <&].freeze

      def self.parse(source)
        new(source).parse
      end

      def initialize(source)
        raise SyntaxError, "NUL bytes are not allowed in shell source" if source.include?("\0")
        @tokens = Lexer.new(source).tokens
        @index = 0
        @depth = 0
      end

      def parse
        tree = sequence
        error("unexpected token") if peek
        tree
      end

      private

      def node(kind, *values)
        Node.new(kind: kind, values: values)
      end

      def peek
        @tokens[@index]&.value
      end

      def text
        peek.is_a?(Word) ? peek.literal : peek
      end

      def take
        token = peek
        @index += 1
        token
      end

      def accept(value)
        return false unless text == value
        take
        true
      end

      def expect(value)
        error("expected #{value.inspect}") unless accept(value)
      end

      def error(message)
        token = @tokens[@index]
        klass = token ? SyntaxError : IncompleteInput
        raise klass, "line #{token&.line || @tokens.last&.line || 1}: #{message}"
      end

      def separators
        take while text == ";"
      end

      def sequence(stops = [])
        commands = []
        separators
        until peek.nil? || stops.include?(text)
          commands << and_or
          break if peek.nil?
          error("expected command separator") unless accept(";")
          separators
        end
        node(:sequence, commands)
      end

      def and_or
        first = pipeline
        rest = []
        while ["&&", "||"].include?(text)
          operator = take
          separators
          rest << [operator, pipeline]
        end
        rest.empty? ? first : node(:and_or, first, rest)
      end

      def pipeline
        negate = accept("!")
        commands = [command]
        while accept("|")
          separators
          commands << command
        end
        node(:pipeline, commands, negate)
      end

      def command
        @depth += 1
        raise SyntaxError, "shell syntax nesting exceeds 100 levels" if @depth > 100
        result = case text
        when "if" then conditional
        when "for" then for_loop
        when "while", "until" then condition_loop
        when "{" then group
        when "(" then error("subshell groups are not supported")
        else
          if peek.is_a?(Word) && @tokens[@index + 1]&.value == "("
            function
          else
            simple
          end
        end
        if result.kind != :simple
          redirects = []
          redirects << redirect while redirection?
          result = node(:redirect, result, redirects) unless redirects.empty?
        end
        result
      ensure
        @depth -= 1
      end

      def conditional(depth = 0)
        raise SyntaxError, "conditional nesting exceeds 100 levels" if depth >= 100
        take
        condition = nonempty_sequence(["then"])
        expect("then")
        yes = nonempty_sequence(%w[elif else fi])
        no = if text == "elif"
          conditional(depth + 1)
        elsif accept("else")
          branch = nonempty_sequence(["fi"])
          expect("fi")
          branch
        else
          expect("fi")
          node(:sequence, [])
        end
        node(:if, condition, yes, no)
      end

      def nonempty_sequence(stops)
        result = sequence(stops)
        error("expected command") if result.values.first.empty?
        result
      end

      def for_loop
        take
        name = take
        error("expected loop variable") unless name.is_a?(Word) && name.literal&.match?(/\A[A-Za-z_][A-Za-z0-9_]*\z/)
        words = nil
        if accept("in")
          words = []
          words << take while peek.is_a?(Word)
        end
        expect(";")
        separators
        expect("do")
        body = nonempty_sequence(["done"])
        expect("done")
        node(:for, name.literal, words, body)
      end

      def condition_loop
        kind = take.literal
        condition = nonempty_sequence(["do"])
        expect("do")
        body = nonempty_sequence(["done"])
        expect("done")
        node(:loop, kind, condition, body)
      end

      def group
        expect("{")
        body = nonempty_sequence(["}"])
        expect("}")
        body
      end

      def function
        name = take.literal
        error("invalid function name") unless name&.match?(/\A[A-Za-z_][A-Za-z0-9_]*\z/)
        expect("(")
        expect(")")
        separators
        node(:function, name, group)
      end

      def redirection?
        peek.is_a?(Array) || REDIRECTS.include?(peek)
      end

      def redirect
        operator = take
        if operator.is_a?(Array)
          _, descriptor, operator = operator
        else
          descriptor = operator.start_with?("<") ? 0 : 1
        end
        error("only file descriptors 0, 1, and 2 are supported") unless (0..2).cover?(descriptor)
        target = take
        error("expected redirection target") unless target.is_a?(Word)
        [descriptor, operator, target]
      end

      def simple
        words = []
        redirects = []
        while peek.is_a?(Word) || redirection?
          if redirection?
            redirects << redirect
          else
            error("unsupported or unexpected reserved word #{text}") if words.empty? && RESERVED.include?(text)
            error("[[ is not supported; use test or [") if words.empty? && text == "[["
            words << take
          end
        end
        error("expected command") if words.empty? && redirects.empty?
        node(:simple, words, redirects)
      end
    end
  end
end
