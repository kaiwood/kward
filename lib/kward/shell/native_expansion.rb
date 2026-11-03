require_relative "native_fields"
require_relative "native_pattern"

module Kward
  module NativeShell
    class ExpansionError < StandardError; end

    # Expansion reads and updates Runtime's shell variables, but never executes
    # source text. Parameter operands are already parsed and evaluated lazily.
    module Expansion
      private

      def ifs
        @variables.fetch("IFS", Fields::DEFAULT_IFS)
      end

      def parameter(name)
        case name
        when "?" then @status.to_s
        when "$" then Process.pid.to_s
        when "#" then @arguments.length.to_s
        when "@" then @arguments.join(" ")
        when "*" then @arguments.join(ifs[0].to_s)
        when "0" then @name
        when /\A\d+\z/ then @arguments[name.to_i - 1].to_s
        else @variables.fetch(name, "")
        end
      end

      def parameter_set?(name)
        case name
        when "@", "*" then !@arguments.empty?
        when "?", "$", "#", "0" then true
        when /\A\d+\z/ then name.to_i <= @arguments.length
        else @variables.key?(name)
        end
      end

      def arithmetic_value(expression)
        Arithmetic.evaluate(expression) { |name| parameter(name) }.to_s
      rescue Arithmetic::Error => e
        raise ExecutionError, e.message
      end

      def expand(word, assignment: false)
        groups = word_fields(word)
        return [groups.map { |group| Fields.value(group) }.join(" ")] if assignment

        groups.flat_map do |group|
          preserve_empty = group.any? { |character| character.quoted && character.text.empty? }
          group = group.reject { |character| character.text.empty? }
          ranges = Fields.ranges(group, ifs)
          next [""] if ranges.empty? && preserve_empty
          ranges.flat_map do |range|
            characters = group[range]
            value = Fields.value(characters)
            pattern = Fields.pattern(characters, glob: true)
            raise ExecutionError, "recursive glob patterns are not supported" if pattern.match?(/(?<!\\\\)\*\*/)
            matches = pattern.match?(/[*?\[]/) ? Dir.glob(pattern, base: @cwd).sort : []
            matches.empty? ? [value] : matches
          end
        end
      end

      def scalar(word)
        word_fields(word).map { |group| Fields.value(group) }.join(" ")
      end

      def pattern(word)
        word_fields(word).map { |group| Fields.pattern(group) }.join(" ")
      end

      def matches_pattern?(pattern, value)
        Pattern.new(pattern).match?(value)
      end

      def word_fields(word, expanded: false)
        groups = [[]]
        word.parts.each_with_index do |part, index|
          additions = case part.kind
          when :parameter
            parameter_fields(part.text, part.quoted)
          when :arithmetic
            [Fields.characters(arithmetic_value(part.text), quoted: part.quoted, split: !part.quoted)]
          else
            value = part.text
            if index.zero? && !part.quoted && (value == "~" || value.start_with?("~/"))
              home = @variables.fetch("HOME", "~")
              [Fields.characters(home, quoted: true) + Fields.characters(value.delete_prefix("~"), split: expanded)]
            elsif index.zero? && !part.quoted && value.start_with?("~")
              raise ExecutionError, "named-user tilde expansion is not supported"
            else
              [Fields.characters(value, quoted: part.quoted, split: expanded && !part.quoted)]
            end
          end
          next if additions.empty?
          groups.last.concat(additions.first)
          groups.concat(additions.drop(1))
        end
        groups
      end

      def parameter_fields(expression, quoted)
        return parameter_value_fields(expression, quoted) unless expression.is_a?(Parameter)

        name, operator, operand = expression.name, expression.operator, expression.word
        value = parameter(name)
        if operator == :length
          length = %w[@ *].include?(name) ? @arguments.length : value.length
          return [Fields.characters(length.to_s, quoted: quoted, split: !quoted)]
        end
        if operator.start_with?("#", "%")
          match = Pattern.new(pattern(operand))
          values = %w[@ *].include?(name) ? @arguments : [value]
          values = values.map { |item| remove_pattern(item, match, operator) }
          return parameter_value_fields(name, quoted, values: values)
        end

        empty = value.empty? && !(quoted && %w[@ *].include?(name))
        missing = !parameter_set?(name) || operator.start_with?(":") && empty
        action = operator.delete_prefix(":")
        use_operand = action == "+" ? !missing : missing
        return action == "+" ? [Fields.characters("", quoted: quoted)] : parameter_value_fields(name, quoted) unless use_operand

        groups = word_fields(operand, expanded: true)
        groups = [groups.flatten] if ifs.empty?
        result = groups.map { |group| Fields.value(group) }.join(ifs[0].to_s)
        case action
        when "="
          raise ExpansionError, "#{name}: cannot assign a special or positional parameter" unless name.match?(/\A[A-Za-z_][A-Za-z0-9_]*\z/)
          assign(name, result)
        when "?"
          message = operand.parts.empty? ? "parameter is unset#{operator.start_with?(":") ? ' or null' : ''}" : result
          raise ExpansionError, "#{name}: #{message}"
        end
        groups.first.concat(Fields.characters("", quoted: true)) if quoted && groups.all?(&:empty?)
        groups
      end

      def parameter_value_fields(name, quoted, values: nil)
        if name == "@" || name == "*" && !quoted
          (values || @arguments).map { |value| Fields.characters(value, quoted: quoted, split: !quoted) }
        else
          value = values ? values.join(name == "*" ? ifs[0].to_s : " ") : parameter(name)
          [Fields.characters(value, quoted: quoted, split: !quoted)]
        end
      end

      def remove_pattern(value, pattern, operator)
        sizes = operator.length == 2 ? value.length.downto(0) : 0.upto(value.length)
        prefix = operator.start_with?("#")
        sizes.each do |size|
          candidate = prefix ? value[0, size] : value[value.length - size, size]
          next unless pattern.match?(candidate)
          return prefix ? value[size..] : value[0, value.length - size]
        end
        value
      end
    end
  end
end
