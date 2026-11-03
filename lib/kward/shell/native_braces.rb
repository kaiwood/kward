module Kward
  module NativeShell
    # Brace expansion operates on source word parts, before any substitutions.
    # Quoted braces and braces produced by variables remain literal.
    module Braces
      LIMIT = 4_096
      module_function

      def expand(word)
        atoms = word.parts.flat_map do |part|
          if part.kind == :literal && !part.text.empty?
            part.text.chars.map { |text| Part.new(kind: :literal, text: text, quoted: part.quoted) }
          else
            [part]
          end
        end
        expand_atoms(atoms, 0).map { |parts| Word.new(parts: coalesce(parts)) }
      end

      def literal?(part, value)
        part&.kind == :literal && !part.quoted && part.text == value
      end

      def expand_atoms(atoms, depth)
        raise ExpansionError, "brace nesting exceeds 32 levels" if depth > 32
        atoms.each_index do |start|
          next unless literal?(atoms[start], "{")
          level = 0
          splits = []
          finish = nil
          ((start + 1)...atoms.length).each do |index|
            if literal?(atoms[index], "{")
              level += 1
            elsif literal?(atoms[index], "}")
              if level.zero?
                finish = index
                break
              end
              level -= 1
            elsif level.zero? && literal?(atoms[index], ",")
              splits << index
            end
          end
          next unless finish
          alternatives = if splits.empty?
            sequence(atoms[(start + 1)...finish])
          else
            ([start] + splits).zip(splits + [finish]).map { |left, right| atoms[(left + 1)...right] }
          end
          next unless alternatives
          result = []
          alternatives.each do |alternative|
            result.concat(expand_atoms(atoms[0...start] + alternative + atoms[(finish + 1)..], depth + 1))
            raise ExpansionError, "brace expansion exceeds #{LIMIT} words" if result.length > LIMIT
          end
          return result
        end
        [atoms]
      end

      def sequence(parts)
        return unless parts.all? { |part| part.kind == :literal && !part.quoted }
        text = parts.map(&:text).join
        match = text.match(/\A(-?\d+|[a-zA-Z])\.\.(-?\d+|[a-zA-Z])(?:\.\.(-?\d+))?\z/)
        return unless match
        first, last, step = match.captures
        raise ExpansionError, "brace sequence exceeds numeric limit" if [first, last, step].compact.any? { |value| value.length > 128 }
        numeric = first.match?(/\A-?\d+\z/) && last.match?(/\A-?\d+\z/)
        return unless numeric || first.length == 1 && last.length == 1 && first.match?(/[a-zA-Z]/) && last.match?(/[a-zA-Z]/)
        from, to = numeric ? [first.to_i, last.to_i] : [first.ord, last.ord]
        stride = step ? step.to_i.abs : 1
        stride = 1 if stride.zero?
        stride = -stride if from > to
        count = (to - from).abs / stride.abs + 1
        raise ExpansionError, "brace expansion exceeds #{LIMIT} words" if count > LIMIT
        padded = numeric && [first, last].any? { |value| value.match?(/\A-?0\d/) }
        width = [first.length, last.length].max
        from.step(to, stride).map do |value|
          text = numeric ? (padded ? format("%0#{width}d", value) : value.to_s) : value.chr
          [Part.new(kind: :literal, text: text, quoted: false)]
        end
      end

      def coalesce(parts)
        parts.each_with_object([]) do |part, result|
          if part.kind == :literal && result.last&.kind == :literal && result.last.quoted == part.quoted
            previous = result.pop
            result << Part.new(kind: :literal, text: previous.text + part.text, quoted: part.quoted)
          else
            result << part
          end
        end
      end
    end
  end
end
