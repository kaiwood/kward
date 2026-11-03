module Kward
  module NativeShell
    module Condition
      UNARY = %w[-n -z -e -a -f -d -s -r -w -x -L -h -b -c -p -S -t -v].freeze
      BINARY = %w[= == != =~ < > -eq -ne -lt -le -gt -ge -nt -ot -ef].freeze

      private

      def condition_value(tree)
        kind, *values = tree
        case kind
        when :and then condition_value(values[0]) && condition_value(values[1])
        when :or then condition_value(values[0]) || condition_value(values[1])
        when :not then !condition_value(values.first)
        when :string then !scalar(values.first).empty?
        when :unary
          operator, word = values
          value = scalar(word)
          path = File.expand_path(value, @cwd)
          case operator
          when "-n" then !value.empty?
          when "-z" then value.empty?
          when "-v" then parameter_set?(value)
          when "-t" then @streams[value.to_i]&.tty? || false
          when "-e", "-a" then File.exist?(path)
          when "-f" then File.file?(path)
          when "-d" then File.directory?(path)
          when "-s" then File.size?(path).to_i.positive?
          when "-r" then File.readable?(path)
          when "-w" then File.writable?(path)
          when "-x" then File.executable?(path)
          when "-L", "-h" then File.symlink?(path)
          when "-b" then File.blockdev?(path)
          when "-c" then File.chardev?(path)
          when "-p" then File.pipe?(path)
          when "-S" then File.socket?(path)
          end
        when :binary
          operator, left, right = values
          value = scalar(left)
          if %w[= == !=].include?(operator)
            match = matches_pattern?(pattern(right), value)
            return operator == "!=" ? !match : match
          end
          if operator == "=~"
            expression = word_fields(right).flatten.map { |part| part.quoted ? Regexp.escape(part.text) : part.text }.join
            match = Regexp.new(expression, timeout: 0.1).match(value)
            captures = match ? match.to_a.each_with_index.to_h { |capture, index| [index, capture.to_s] } : {}
            @arrays["BASH_REMATCH"] = Arrays::ArrayValue.new(associative: false, values: captures)
            return !!match
          end
          other = scalar(right)
          case operator
          when "<" then value < other
          when ">" then value > other
          when "-eq", "-ne", "-lt", "-le", "-gt", "-ge"
            operators = { "-eq" => "==", "-ne" => "!=", "-lt" => "<", "-le" => "<=", "-gt" => ">", "-ge" => ">=" }
            Arithmetic.binary(operators.fetch(operator), arithmetic_value(value).to_i, arithmetic_value(other).to_i) == 1
          when "-nt", "-ot", "-ef"
            first, second = [value, other].map { |name| File.expand_path(name, @cwd) }
            if operator == "-ef"
              File.exist?(first) && File.exist?(second) && File.identical?(first, second)
            elsif operator == "-nt"
              File.exist?(first) && (!File.exist?(second) || File.mtime(first) > File.mtime(second))
            else
              File.exist?(second) && (!File.exist?(first) || File.mtime(first) < File.mtime(second))
            end
          end
        end
      rescue RegexpError, Regexp::TimeoutError => e
        raise ExecutionError, "conditional regular expression: #{e.message}"
      end
    end
  end
end
