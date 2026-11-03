require "strscan"

module Kward
  module NativeShell
    # A bounded integer-only arithmetic language, never Ruby or shell eval.
    # Parsing produces postfix instructions without reading shell variables.
    module Arithmetic
      class Error < StandardError; end

      MAX_BYTES = 4_096
      MAX_BITS = 4_096
      MAX_DEPTH = 100

      def self.integer(text)
        value = text.to_s.strip
        return 0 if value.empty?
        unless value.bytesize <= MAX_BYTES && value.match?(/\A[+-]?(?:0[xX][0-9a-fA-F]+|0[0-7]*|[1-9][0-9]*)\z/)
          raise Error, "arithmetic requires an integer value"
        end

        bounded(Integer(value, 0))
      end

      def self.bounded(value)
        raise Error, "arithmetic result exceeds #{MAX_BITS} bits" if value.bit_length > MAX_BITS
        value
      end

      def self.evaluate(source, &variable)
        stack = []
        Parser.new(source).parse.each do |instruction, operand|
          case instruction
          when :number then stack << operand
          when :variable then stack << integer(variable.call(operand))
          when :negate then stack << bounded(-stack.pop)
          else
            right = stack.pop
            left = stack.pop
            value = case instruction
            when "+" then left + right
            when "-" then left - right
            when "*" then left * right
            when "/", "%"
              raise Error, "arithmetic division by zero" if right.zero?
              quotient = left.abs / right.abs
              quotient = -quotient if left.negative? != right.negative?
              instruction == "/" ? quotient : left - quotient * right
            end
            stack << bounded(value)
          end
        end
        stack.fetch(0)
      end

      class Parser
        def initialize(source)
          raise Error, "arithmetic expression exceeds #{MAX_BYTES} bytes" if source.bytesize > MAX_BYTES
          @scanner = StringScanner.new(source)
          @instructions = []
          @depth = 0
          advance
        end

        def parse
          expression
          raise Error, "unexpected token in arithmetic expression" if @token
          @instructions
        end

        private

        def advance
          @scanner.skip(/\s+/)
          @token = if @scanner.eos?
            nil
          elsif @scanner.scan(/\+\+|--|\*\*|[+*\/%-]=/)
            raise Error, "arithmetic assignment, increment, and exponentiation are not supported"
          elsif (number = @scanner.scan(/0[xX][0-9a-fA-F]+|[0-9]+/))
            [:number, Arithmetic.integer(number)]
          elsif (name = @scanner.scan(/[A-Za-z_][A-Za-z0-9_]*/))
            [:variable, name]
          elsif @scanner.scan(/\$\{([A-Za-z_][A-Za-z0-9_]*|[0-9]+|[?#$])\}/)
            [:variable, @scanner[1]]
          elsif @scanner.scan(/\$([A-Za-z_][A-Za-z0-9_]*|[0-9?#$])/)
            [:variable, @scanner[1]]
          elsif (operator = @scanner.scan(/[+*\/%()-]/))
            operator
          else
            raise Error, "unsupported token in arithmetic expression"
          end
        end

        def expression
          term
          while ["+", "-"].include?(@token)
            operator = @token
            advance
            term
            @instructions << [operator]
          end
        end

        def term
          unary
          while ["*", "/", "%"].include?(@token)
            operator = @token
            advance
            unary
            @instructions << [operator]
          end
        end

        def unary
          @depth += 1
          raise Error, "arithmetic nesting exceeds #{MAX_DEPTH} levels" if @depth > MAX_DEPTH
          if ["+", "-"].include?(@token)
            operator = @token
            advance
            unary
            @instructions << [:negate] if operator == "-"
          elsif @token == "("
            advance
            expression
            raise Error, "expected ) in arithmetic expression" unless @token == ")"
            advance
          elsif @token.is_a?(Array)
            @instructions << @token
            advance
          else
            raise Error, "expected an integer, variable, or ( in arithmetic expression"
          end
        ensure
          @depth -= 1
        end
      end
    end
  end
end
