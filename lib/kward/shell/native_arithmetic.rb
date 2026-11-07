require "strscan"

module Kward
  module NativeShell
    # Integer arithmetic ASTs preserve short-circuiting and lvalue ownership.
    # Parsing is independent of shell state; evaluation never uses Ruby eval.
    module Arithmetic
      class Error < StandardError; end
      MAX_BITS = 4_096
      MAX_DEPTH = 100

      def self.integer(text)
        value = text.to_s.strip
        return 0 if value.empty?
        unless value.match?(/\A[+-]?(?:0[xX][0-9a-fA-F]+|0[0-7]*|[1-9][0-9]*)\z/)
          raise Error, "arithmetic requires an integer value"
        end
        negative = value.start_with?("-")
        digits = value.delete_prefix("+").delete_prefix("-")
        base = digits.start_with?("0x", "0X") ? 16 : digits.start_with?("0") ? 8 : 10
        digits = digits[2..] if base == 16
        digits = digits.sub(/\A0+/, "")
        return 0 if digits.empty?
        # More significant digits than bits cannot fit in any supported base.
        # Reject before constructing a huge integer; leading zeros cost no bits.
        raise Error, "arithmetic result exceeds #{MAX_BITS} bits" if digits.length > MAX_BITS
        bounded(Integer(digits, base) * (negative ? -1 : 1))
      end

      def self.bounded(value)
        raise Error, "arithmetic result exceeds #{MAX_BITS} bits" if value.bit_length > MAX_BITS
        value
      end

      def self.evaluate(source, assign: nil, &variable)
        Evaluator.new(variable, assign).evaluate(Parser.new(source).parse)
      end

      def self.binary(operator, left, right)
        value = case operator
        when "+" then left + right
        when "-" then left - right
        when "*" then left * right
        when "/", "%"
          raise Error, "arithmetic division by zero" if right.zero?
          quotient = left.abs / right.abs
          quotient = -quotient if left.negative? != right.negative?
          operator == "/" ? quotient : left - quotient * right
        when "**"
          raise Error, "negative arithmetic exponent" if right.negative?
          raise Error, "arithmetic exponent exceeds result limit" if left.abs > 1 && (left.abs.bit_length - 1) * right > MAX_BITS
          if left == -1
            right.odd? ? -1 : 1
          elsif left == 0
            right.zero? ? 1 : 0
          elsif left == 1
            1
          else
            left**right
          end
        when "<<", ">>"
          raise Error, "arithmetic shift exceeds limit" unless (0..MAX_BITS).cover?(right)
          operator == "<<" ? left << right : left >> right
        when "&" then left & right
        when "|" then left | right
        when "^" then left ^ right
        when "==" then left == right ? 1 : 0
        when "!=" then left != right ? 1 : 0
        when "<" then left < right ? 1 : 0
        when "<=" then left <= right ? 1 : 0
        when ">" then left > right ? 1 : 0
        when ">=" then left >= right ? 1 : 0
        when "," then right
        else raise Error, "unknown arithmetic operator"
        end
        bounded(value)
      end

      class Evaluator
        def initialize(variable, assign)
          @variable, @assign = variable, assign
          @depth = 0
          @reading = []
        end

        def evaluate(node)
          @depth += 1
          raise Error, "arithmetic nesting exceeds #{MAX_DEPTH} levels" if @depth > MAX_DEPTH
          kind, *args = node
          case kind
          when :number then args.first
          when :variable, :parameter then read(args.first)
          when :unary
            operator, operand = args
            value = evaluate(operand)
            result = case operator
            when "+" then value
            when "-" then -value
            when "!" then value.zero? ? 1 : 0
            when "~" then ~value
            end
            Arithmetic.bounded(result)
          when :update
            name, delta, post = args
            before = read(name)
            after = store(name, Arithmetic.bounded(before + delta))
            post ? before : after
          when :assign
            name, operator, operand = args
            before = read(name) unless operator == "="
            value = evaluate(operand)
            store(name, operator == "=" ? value : Arithmetic.binary(operator.delete_suffix("="), before, value))
          when :conditional
            condition, yes, no = args
            evaluate(evaluate(condition).zero? ? no : yes)
          when :binary then binary_chain(node)
          end
        ensure
          @depth -= 1
        end

        private

        # A long left-associative chain is not recursive expression nesting.
        def binary_chain(node)
          operations = []
          while node.first == :binary
            _, operator, left, right = node
            operations << [operator, right]
            node = left
          end
          value = evaluate(node)
          operations.reverse_each do |operator, right|
            value = if operator == "&&"
              value.zero? ? 0 : (evaluate(right).zero? ? 0 : 1)
            elsif operator == "||"
              value.zero? ? (evaluate(right).zero? ? 0 : 1) : 1
            else
              Arithmetic.binary(operator, value, evaluate(right))
            end
          end
          value
        end

        def read(name)
          raise Error, "recursive arithmetic variable: #{name}" if @reading.include?(name)
          @reading << name
          begin
            value = @variable.call(name).to_s
            value.strip.empty? ? 0 : evaluate(Parser.new(value).parse)
          ensure
            @reading.pop
          end
        end

        def store(name, value)
          raise Error, "arithmetic assignment is unavailable" unless @assign
          @assign.call(name, value.to_s)
          value
        end
      end

      class Parser
        LEVELS = [ %w[,], %w[= += -= *= /= %= <<= >>= &= ^= |=], %w[?], %w[||], %w[&&], %w[|], %w[^], %w[&], %w[== !=], %w[< <= > >=], %w[<< >>], %w[+ -], %w[* / %], %w[**] ].freeze
        PRECEDENCE = LEVELS.each_with_index.each_with_object({}) { |(operators, index), result| operators.each { |operator| result[operator] = index + 1 } }.freeze

        def initialize(source)
          @scanner = StringScanner.new(source)
          @depth = 0
          advance
        end

        def parse
          result = expression
          raise Error, "unexpected token in arithmetic expression" if @token
          result
        end

        private

        def advance
          @scanner.skip(/\s+/)
          @token = if @scanner.eos?
            nil
          elsif (number = @scanner.scan(/0[xX][0-9a-fA-F]+|[0-9]+/))
            [:number, Arithmetic.integer(number)]
          elsif (name = @scanner.scan(/[A-Za-z_][A-Za-z0-9_]*/))
            [:variable, name]
          elsif @scanner.scan(/\$\{([A-Za-z_][A-Za-z0-9_]*|[0-9]+|[?#$])\}/) || @scanner.scan(/\$([A-Za-z_][A-Za-z0-9_]*|[0-9?#$])/)
            [:parameter, @scanner[1]]
          elsif (operator = @scanner.scan(/<<=|>>=|\+\+|--|\*\*|&&|\|\||<<|>>|[+*\/%&|^!<>=-]=|[+*\/%()~!<>=?:,&|^-]/))
            operator
          else
            raise Error, "unsupported token in arithmetic expression"
          end
        end

        def expression(minimum = 1)
          @depth += 1
          raise Error, "arithmetic nesting exceeds #{MAX_DEPTH} levels" if @depth > MAX_DEPTH
          left = unary
          while (precedence = PRECEDENCE[@token]) && precedence >= minimum
            operator = @token
            advance
            if operator == "?"
              yes = expression
              raise Error, "expected : in arithmetic conditional" unless @token == ":"
              advance
              left = [:conditional, left, yes, expression(precedence)]
            else
              assignment = LEVELS[1].include?(operator)
              name = lvalue(left) if assignment
              right = expression(assignment || operator == "**" ? precedence : precedence + 1)
              left = assignment ? [:assign, name, operator, right] : [:binary, operator, left, right]
            end
          end
          left
        ensure
          @depth -= 1
        end

        def unary
          if %w[+ - ! ~ ++ --].include?(@token)
            operator = @token
            advance
            operand = expression(15)
            return [:update, lvalue(operand), operator == "++" ? 1 : -1, false] if %w[++ --].include?(operator)
            return [:unary, operator, operand]
          end
          if @token == "("
            advance
            value = expression
            raise Error, "expected ) in arithmetic expression" unless @token == ")"
            advance
          elsif @token.is_a?(Array)
            value = @token
            advance
          else
            raise Error, "expected an integer, variable, or ( in arithmetic expression"
          end
          if %w[++ --].include?(@token)
            value = [:update, lvalue(value), @token == "++" ? 1 : -1, true]
            advance
          end
          value
        end

        def lvalue(node)
          raise Error, "arithmetic assignment requires a variable" unless node.first == :variable
          node[1]
        end
      end
    end
  end
end
