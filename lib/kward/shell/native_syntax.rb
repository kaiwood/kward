require "shellwords"
require_relative "native_arithmetic"
require_relative "native_condition"

# Namespace for the Kward CLI agent runtime.
module Kward
  # The deliberately small native kwsh grammar. Words retain quoting information
  # until execution; parsing never expands variables or launches commands.
  module NativeShell
    class SyntaxError < StandardError; end
    class IncompleteInput < SyntaxError; end

    Reference = Struct.new(:name, :subscript, :append, keyword_init: true)
    Part = Struct.new(:kind, :text, :quoted, keyword_init: true)
    Word = Struct.new(:parts, keyword_init: true) do
      def literal
        return unless parts.all? { |part| part.kind == :literal && !part.quoted }

        parts.map(&:text).join
      end

      def assignment
        first = parts.first
        return unless first && first.kind == :literal && !first.quoted
        if (array = first.text.match(/\A([A-Za-z_][A-Za-z0-9_]*)\[/))
          return subscript_assignment(array[0].length, array[1])
        end
        match = first.text.match(/\A([A-Za-z_][A-Za-z0-9_]*)=(.*)\z/m)
        return unless match

        value = [Part.new(kind: :literal, text: match[2], quoted: false)] + parts.drop(1)
        [match[1], Word.new(parts: value)]
      end

      def array_element
        return unless parts.first&.kind == :literal && !parts.first.quoted && parts.first.text.start_with?("[")
        subscript_assignment(1, nil)
      end

      def subscript_assignment(prefix, name)
        key = []
        parts.each_with_index do |part, index|
          text = index.zero? ? part.text[prefix..] : part.text
          if part.kind == :literal && !part.quoted && (ending = text.match(/\](\+?)=/))
            finish = ending.begin(0)
            key << Part.new(kind: :literal, text: text[0...finish], quoted: false)
            value = [Part.new(kind: :literal, text: text[ending.end(0)..], quoted: false)] + parts.drop(index + 1)
            return [Reference.new(name: name, subscript: Word.new(parts: key), append: ending[1] == "+"), Word.new(parts: value)]
          end
          key << Part.new(kind: part.kind, text: text, quoted: part.quoted)
        end
        nil
      end
    end
    Parameter = Struct.new(:name, :operator, :word, keyword_init: true)
    HereDocument = Struct.new(:delimiter, :strip_tabs, :expand, :word, keyword_init: true)
    Token = Struct.new(:value, :line, :source, :start, :finish, :alias_names, :alias_next, keyword_init: true)
    Node = Struct.new(:kind, :values, :source, :line, keyword_init: true)

    class Lexer
      OPERATORS = %w[&& || <<- << >> <> >| >& <& ;; ;& ; & | > < ( ) { }].freeze

      def initialize(source, depth: 0, aliases: {}, line: 1, eof: true)
        @source = source.dup
        @eof = eof
        @alias_regions = []
        @token_end = 0
        @aliases = aliases
        @substitution_depth = depth
        @index = 0
        @line = line
        @arithmetic_depth = 0
        @parameter_depth = 0
        @heredocs = []
      end

      def tokens
        result = []
        while (token = next_token)
          result << token
        end
        result
      end

      def next_token
        until current.nil?
          line = @line
          start = @index
          case current
          when " ", "\t", "\r"
            advance
          when "#"
            advance until current.nil? || current == "\n"
          when "\n"
            advance
            consume_heredocs
            return token(";", line: line, start: start)
          else
            if @source[@index, 2] == "\\\n"
              advance(2)
              raise IncompleteInput, "continued input line" if current.nil? && !@eof
              next
            end
            operator = OPERATORS.find { |candidate| @source[@index, candidate.length] == candidate }
            operator = nil if ["{", "}"].include?(operator) && @source[@index + 1]&.match?(/[^\s;|&()<>]/)
            value = if @source[@index, 2] == "(("
              [:arithmetic, arithmetic_source]
            elsif ["<(", ">("].include?(@source[@index, 2])
              word
            elsif (match = @source[@index..].match(/\A([0-9]+)(<<-|<<|>>|<>|>\||>&|<&|>|<)/))
              advance(match[0].length)
              [:redirect, match[1].to_i, match[2]]
            elsif operator
              advance(operator.length)
              operator
            else
              word
            end
            return token(value, line: line, start: start, source: @source[start...@index])
          end
        end
        raise IncompleteInput, "unclosed here-document" unless @heredocs.empty?
        nil
      end

      def regex_token
        advance while current&.match?(/\s/)
        return unless current
        line, start = @line, @index
        value = word(regex: true)
        token(value, line: line, start: start, source: @source[start...@index])
      end

      # Reinsert alias text into the same lexical stream. Quotes and here-docs
      # can cross the replacement boundary, unlike independently lexed tokens.
      def replace_alias(token, source, names)
        first, last = token.start, token.finish
        delta = source.length - (last - first)
        @alias_regions.each do |region|
          region[:start] += delta if region[:start] >= last
          region[:finish] += delta if region[:finish] >= last
        end
        @source[first...last] = source
        @alias_regions << { start: first, finish: first + source.length, names: names,
                            trailing: source.end_with?(" ", "\t") }
        @index = @token_end = first
        @line = token.line
      end

      def token(value, line:, start:, source: nil)
        names = @alias_regions.select { |region| region[:start] <= start && start < region[:finish] }.flat_map { |region| region[:names] }.uniq
        following = @alias_regions.any? { |region| region[:trailing] && @token_end < region[:finish] && region[:finish] <= start }
        @token_end = @index
        Token.new(value: value, line: line, source: source, start: start, finish: @index,
                  alias_names: names, alias_next: following)
      end
      private :token

      def queue_heredoc(document)
        @heredocs << document
      end

      def heredoc_word
        parts = []
        until current.nil?
          case current
          when "$" then parameter(parts, true)
          when "`" then backticks(parts, true)
          when "\\"
            advance
            if ['$', '`', "\\", "\n"].include?(current)
              literal(parts, current, true) unless current == "\n"
              advance
            else
              literal(parts, "\\", true)
            end
          else
            literal(parts, current, true)
            advance
          end
        end
        Word.new(parts: parts)
      end

      private

      def consume_heredocs
        pending = @heredocs
        @heredocs = []
        pending.each do |document|
          body = +""
          loop do
            line = +""
            finish = nil
            loop do
              raise IncompleteInput, "unclosed here-document: #{document.delimiter}" unless current
              finish = @source.index("\n", @index)
              fragment = @source[@index...(finish || @source.length)]
              advance(fragment.length + (finish ? 1 : 0))
              line << fragment
              break unless document.expand && finish && line[/\\+\z/].to_s.length.odd?
              line.chop!
            end
            line = line.sub(/\A\t+/, "") if document.strip_tabs
            break if line == document.delimiter
            body << line
            body << "\n" if finish
          end
          document.word = if document.expand
            Lexer.new(body, depth: @substitution_depth, aliases: @aliases).heredoc_word
          else
            Word.new(parts: [Part.new(kind: :literal, text: body, quoted: true)])
          end
        end
      end

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

      def word(parameter_word: false, quoted: false, stop: "}", regex: false)
        parts = []
        until current.nil? || (parameter_word ? current == stop : (regex ? current.match?(/\s/) : word_end?))
          case current
          when "'"
            if quoted
              literal(parts, current, true)
              advance
              next
            end
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
            literal(parts, "\\", true) if quoted && !['$', '`', '"', "\\", "\n", "}"].include?(current)
            continued = current == "\n"
            literal(parts, current, true) unless continued
            advance
            raise IncompleteInput, "continued input line" if continued && current.nil? && !@eof
          when "$"
            parameter(parts, quoted)
          when "`"
            backticks(parts, quoted)
          when "<", ">"
            if !regex && ["<(", ">("].include?(@source[@index, 2])
              direction = current
              advance(2)
              parts << Part.new(kind: :process, text: [direction, nested_program], quoted: false)
            else
              literal(parts, current, quoted)
              advance
            end
          else
            literal(parts, current, quoted)
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
        start = parts.length
        until current.nil? || current == '"'
          case current
          when "$"
            parameter(parts, true)
          when "`"
            backticks(parts, true)
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
        literal(parts, "", true) if parts.length == start
        advance
      end

      def arithmetic(parts, quoted)
        @arithmetic_depth += 1
        raise SyntaxError, "arithmetic nesting exceeds 100 levels" if @arithmetic_depth > 100
        advance(2)
        depth = 0
        expression = []
        until current.nil?
          if current == ")" && depth.zero?
            raise IncompleteInput, "line #{@line}: unclosed arithmetic expansion; expected ))" unless @source[@index + 1]
            closing = @source[@index..][/\A\)[ \t]*\)/]
            raise SyntaxError, "line #{@line}: expected a second ) to close arithmetic expansion" unless closing
            word = Word.new(parts: expression)
            Arithmetic::Parser.new(word.literal.to_s).parse if word.literal
            advance(closing.length)
            parts << Part.new(kind: :arithmetic, text: word, quoted: quoted)
            return
          end
          case current
          when "$" then parameter(expression, false)
          when "`" then backticks(expression, false)
          when "\\"
            advance
            raise IncompleteInput, "unclosed arithmetic expansion" unless current
            literal(expression, current, false) unless current == "\n"
            advance
          else
            depth += 1 if current == "("
            depth -= 1 if current == ")"
            literal(expression, current, false)
            advance
          end
        end
        raise IncompleteInput, "line #{@line}: unclosed arithmetic expansion; expected ))"
      rescue Arithmetic::Error => e
        raise SyntaxError, "line #{@line}: #{e.message}"
      ensure
        @arithmetic_depth -= 1
      end

      def arithmetic_source
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
              advance(closing.length)
              return expression
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
        if current == "("
          advance
          parts << Part.new(kind: :command, text: nested_program, quoted: quoted)
          return
        end
        if current == "'" && !quoted
          dollar_quote(parts)
          return
        end
        if current == "{"
          braced_parameter(parts, quoted)
          return
        elsif (match = @source[@index..].to_s.match(/\A(?:[A-Za-z_][A-Za-z0-9_]*|[0-9?@#*$!-])/))
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

      def dollar_quote(parts)
        advance
        value = +"".b
        escapes = { "a" => "\a", "b" => "\b", "e" => "\e", "E" => "\e", "f" => "\f", "n" => "\n", "r" => "\r", "t" => "\t", "v" => "\v" }
        until current.nil? || current == "'"
          if current != "\\"
            value << current.b
            advance
            next
          end
          advance
          raise IncompleteInput, "unclosed dollar-single-quote" unless current
          escape = current
          advance
          if escapes.key?(escape)
            value << escapes.fetch(escape)
          elsif ["\\", "'", '"'].include?(escape)
            value << escape
          elsif escape == "c" && current
            value << (current.upcase.ord & 31).chr
            advance(current == "\\" && @source[@index + 1] == "\\" ? 2 : 1)
          elsif %w[x u U].include?(escape)
            maximum = { "x" => 2, "u" => 4, "U" => 8 }.fetch(escape)
            digits = @source[@index..][/\A[0-9a-fA-F]{1,#{maximum}}/]
            if digits
              value << digits.to_i(16).chr(escape == "x" ? Encoding::BINARY : Encoding::UTF_8).b
              advance(digits.length)
            else
              value << "\\#{escape}"
            end
          elsif escape.match?(/[0-7]/)
            extra = @source[@index..][/\A[0-7]{0,2}/]
            value << ((escape + extra).to_i(8) & 255).chr(Encoding::BINARY)
            advance(extra.length)
          else
            value << "\\#{escape}"
          end
        end
        raise IncompleteInput, "unclosed dollar-single-quote" unless current
        advance
        literal(parts, value.split("\0", 2).first.to_s.force_encoding(Encoding.default_external), true)
      rescue RangeError
        raise SyntaxError, "invalid character escape"
      end

      def word_end?
        current.match?(/[\s;&|<>()]/) && !["<(", ">("].include?(@source[@index, 2])
      end

      def nested_program
        @substitution_depth += 1
        raise SyntaxError, "substitution nesting exceeds 100 levels" if @substitution_depth > 100
        previous_heredocs = @heredocs
        @heredocs = []
        Parser.new(nil, lexer: self, aliases: @aliases).parse_until_close
      ensure
        @heredocs = previous_heredocs if previous_heredocs
        @substitution_depth -= 1
      end

      def backticks(parts, quoted)
        advance
        source = +""
        until current.nil? || current == "`"
          if current == "\\" && ['$', '`', "\\", "\n"].include?(@source[@index + 1])
            advance
            source << current unless current == "\n"
          else
            source << current
          end
          advance
        end
        raise IncompleteInput, "line #{@line}: unclosed command substitution" unless current
        advance
        raise SyntaxError, "substitution nesting exceeds 100 levels" if @substitution_depth >= 100
        lexer = Lexer.new(source, depth: @substitution_depth + 1, aliases: @aliases)
        parts << Part.new(kind: :command, text: Parser.new(nil, lexer: lexer, aliases: @aliases).parse, quoted: quoted)
      end

      def braced_parameter(parts, quoted)
        @parameter_depth += 1
        raise SyntaxError, "parameter nesting exceeds 100 levels" if @parameter_depth > 100
        advance
        length = current == "#" && @source[@index + 1] != "}"
        keys = current == "!" && @source[@index + 1] != "}"
        advance if length || keys
        name = @source[@index..][/\A(?:[A-Za-z_][A-Za-z0-9_]*|[0-9]+|[?@#*$!-])/]
        raise IncompleteInput, "line #{@line}: unclosed parameter expansion" unless current
        raise SyntaxError, "line #{@line}: unsupported parameter expansion" unless name
        advance(name.length)
        if current == "["
          advance
          subscript = word(parameter_word: true, stop: "]")
          raise IncompleteInput, "unclosed array subscript" unless current == "]"
          advance
          name = Reference.new(name: name, subscript: subscript)
        end
        if keys && (!name.is_a?(Reference) || !%w[@ *].include?(name.subscript.literal))
          raise SyntaxError, "indirection requires an array @ or * reference"
        end
        if current == "}"
          advance
          value = length || keys ? Parameter.new(name: name, operator: keys ? :keys : :length) : name
        else
          operator = @source[@index..][/\A(?::[-=+?]|[-=+?]|##?|%%?)/] unless length || keys
          raise IncompleteInput, "line #{@line}: unclosed parameter expansion" unless current
          raise SyntaxError, "line #{@line}: unsupported parameter expansion" unless operator
          advance(operator.length)
          pattern = operator.start_with?("#", "%")
          operand = word(parameter_word: true, quoted: quoted && !pattern)
          raise IncompleteInput, "line #{@line}: unclosed parameter expansion" unless current == "}"
          advance
          value = Parameter.new(name: name, operator: operator, word: operand)
        end
        parts << Part.new(kind: :parameter, text: value, quoted: quoted)
      ensure
        @parameter_depth -= 1
      end
    end

    class Parser
      RESERVED = %w[if then elif else fi for in do done while until case esac select function time !].freeze
      REDIRECTS = %w[< > >> <> >| >& <& << <<-].freeze

      def self.parse(source, aliases: {}, line: 1, eof: true)
        new(source, aliases: aliases, line: line, eof: eof).parse
      end

      def initialize(source, lexer: nil, aliases: {}, line: 1, eof: true)
        raise SyntaxError, "NUL bytes are not allowed in shell source" if source&.include?("\0")
        @lexer = lexer || Lexer.new(source, aliases: aliases, line: line, eof: eof)
        @aliases = aliases
        @alias_tokens = 0
        @alias_bytes = 0
        @tokens = []
        @index = 0
        @depth = 0
      end

      def parse
        tree = sequence
        error("unexpected token") if peek
        tree
      end

      def parse_until_close
        tree = sequence([")"])
        expect(")")
        tree
      end

      private

      def node(kind, *values)
        Node.new(kind: kind, values: values)
      end

      def peek(offset = 0)
        while @tokens.length <= @index + offset
          token = @lexer.next_token
          break unless token
          @alias_tokens += 1 unless token.alias_names.to_a.empty?
          raise SyntaxError, "alias expansion exceeds 65536 tokens" if @alias_tokens > 65_536
          @tokens << token
        end
        @tokens[@index + offset]&.value
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
          expand_alias
          break if peek.nil? || stops.include?(text)
          if text == ";" && @tokens[@index].source.nil?
            separators
            next
          end
          command = and_or
          background = accept("&")
          commands << (background ? node(:background, command) : command)
          break if peek.nil? || [";;", ";&", ")"].include?(text) && stops.include?(text)
          error("expected command separator") unless background || accept(";")
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

      def expand_alias
        loop do
          name = peek.is_a?(Word) && peek.literal
          break unless name && @aliases.key?(name) && !RESERVED.include?(name)
          token = @tokens[@index]
          names = token.alias_names || []
          break if names.include?(name)
          raise SyntaxError, "alias expansion exceeds 100 levels" if names.length >= 100
          replacement = @aliases.fetch(name)
          @alias_bytes += replacement.bytesize
          raise SyntaxError, "alias replacement exceeds 1048576 bytes" if @alias_bytes > 1_048_576
          @lexer.replace_alias(token, replacement, names + [name])
          @tokens.slice!(@index..)
        end
      end

      def pipeline
        start = @index
        expand_alias
        negate = accept("!")
        commands = [command]
        while accept("|")
          separators
          commands << command
        end
        result = node(:pipeline, commands, negate)
        result.source = @tokens[start...@index].filter_map(&:source).join(" ")
        result
      end

      def command
        expand_alias
        peek
        line = @tokens[@index]&.line
        @depth += 1
        raise SyntaxError, "shell syntax nesting exceeds 100 levels" if @depth > 100
        result = if peek.is_a?(Array) && peek.first == :arithmetic
          expression = take.last
          validate_arithmetic(expression)
          node(:arithmetic, expression)
        else
          compound_or_simple
        end
        if result.kind != :simple
          redirects = []
          redirects << redirect while redirection?
          result = node(:redirect, result, redirects) unless redirects.empty?
        end
        result.line = line
        result
      ensure
        @depth -= 1
      end

      def validate_arithmetic(expression)
        Arithmetic::Parser.new(expression).parse unless expression.strip.empty?
      rescue Arithmetic::Error => e
        error(e.message)
      end

      def compound_or_simple
        case text
        when "if" then conditional
        when "for" then for_loop
        when "case" then case_command
        when "[["
          take
          condition = test_expression
          expect("]]")
          node(:test, condition)
        when "while", "until" then condition_loop
        when "{" then group
        when "("
          take
          node(:subshell, parse_until_close)
        else
          append = peek.is_a?(Word) && peek.literal&.match(/\A([A-Za-z_][A-Za-z0-9_]*)\+=\z/)
          if peek.is_a?(Word) && (peek.assignment || append) && peek(1) == "("
            word = take
            name, value = append ? [append[1], Word.new(parts: [])] : word.assignment
            error("invalid array assignment") unless name.is_a?(String) && value.parts.all? { |part| part.kind == :literal && part.text.empty? }
            node(:array_assign, name, array_elements, !!append)
          elsif peek.is_a?(Word) && peek(1) == "("
            function
          else
            simple
          end
        end
      end

      def array_elements
        expect("(")
        elements = []
        until text == ")"
          next if accept(";")
          error("expected array element") unless peek.is_a?(Word)
          elements << take
        end
        expect(")")
        elements
      end

      def test_expression(minimum = 0)
        @depth += 1
        raise SyntaxError, "conditional nesting exceeds 100 levels" if @depth > 100
        left = if accept("!")
          [:not, test_expression(3)]
        elsif accept("(")
          result = test_expression
          expect(")")
          result
        elsif Condition::UNARY.include?(text)
          operator = take.literal
          [:unary, operator, test_word]
        else
          word = test_word
          if Condition::BINARY.include?(text)
            operator = text
            take
            [:binary, operator, word, test_word(regex: operator == "=~")]
          else
            [:string, word]
          end
        end
        while %w[&& ||].include?(text) && (text == "&&" ? 2 : 1) >= minimum
          operator = take
          left = [operator == "&&" ? :and : :or, left, test_expression(operator == "&&" ? 3 : 2)]
        end
        left
      ensure
        @depth -= 1
      end

      def test_word(regex: false)
        if regex && @tokens.length == @index
          token = @lexer.regex_token
          @tokens << token if token
        end
        error("expected conditional operand") unless peek.is_a?(Word) && text != "]]"
        take
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
        if peek.is_a?(Array) && peek.first == :arithmetic
          expressions = take.last.split(";", -1)
          error("arithmetic for requires init; condition; update") unless expressions.length == 3
          expressions.each { |expression| validate_arithmetic(expression) }
          separators
          expect("do")
          body = nonempty_sequence(["done"])
          expect("done")
          return node(:arithmetic_for, expressions, body)
        end
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

      def case_command
        take
        subject = take
        error("expected case word") unless subject.is_a?(Word)
        separators
        expect("in")
        separators
        clauses = []
        until text == "esac"
          accept("(")
          patterns = []
          loop do
            pattern = take
            error("expected case pattern") unless pattern.is_a?(Word)
            patterns << pattern
            break unless accept("|")
          end
          expect(")")
          body = sequence(%w[;; ;& esac])
          terminator = take if %w[;; ;&].include?(text)
          clauses << [patterns, body, terminator == ";&"]
          break unless terminator
          separators
        end
        expect("esac")
        node(:case, subject, clauses)
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
        peek.is_a?(Array) && peek.first == :redirect || REDIRECTS.include?(peek)
      end

      def redirect
        operator = take
        if operator.is_a?(Array)
          _, descriptor, operator = operator
        else
          descriptor = operator.start_with?("<") ? 0 : 1
        end
        error("only file descriptors 0 through 9 are supported") unless (0..9).cover?(descriptor)
        target = take
        error("expected redirection target") unless target.is_a?(Word)
        if ["<<", "<<-"].include?(operator)
          raw = @tokens[@index - 1].source
          delimiter = Shellwords.split(raw).join
          target = HereDocument.new(delimiter: delimiter, strip_tabs: operator == "<<-", expand: !raw.match?(/["'\\]/))
          @lexer.queue_heredoc(target)
        end
        [descriptor, operator, target]
      end

      def simple
        words = []
        redirects = []
        while peek.is_a?(Word) || redirection?
          expand_alias if words.all?(&:assignment) || @tokens[@index]&.alias_next
          break unless peek.is_a?(Word) || redirection?
          if redirection?
            redirects << redirect
          else
            error("unsupported or unexpected reserved word #{text}") if words.empty? && RESERVED.include?(text)
            error("[[ is not supported; use test or [") if words.empty? && text == "[["
            words << take
          end
        end
        if text == "(" && words.first&.literal == "declare" && words.last&.assignment
          error("array declaration requires -a or -A") unless words.length == 3 && %w[-a -A].include?(words[1].literal)
          name, value = words.last.assignment
          error("invalid array declaration") unless name.is_a?(String) && value.parts.all? { |part| part.kind == :literal && part.text.empty? }
          result = node(:declare_array, words[1].literal, name, array_elements)
          return redirects.empty? ? result : node(:redirect, result, redirects)
        end
        error("expected command") if words.empty? && redirects.empty?
        node(:simple, words, redirects)
      end
    end
  end
end
