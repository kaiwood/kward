module Kward
  module NativeShell
    # Shared field splitting for word expansion and read. Quote provenance stays
    # attached to characters; literal text is never split merely because it is IFS.
    module Fields
      Character = Struct.new(:text, :quoted, :split, keyword_init: true)
      DEFAULT_IFS = " \t\n".freeze

      def self.characters(value, quoted: false, split: false)
        result = value.each_char.map { |text| Character.new(text: text, quoted: quoted, split: split) }
        result << Character.new(text: "", quoted: true, split: false) if value.empty? && quoted
        result
      end

      def self.separator?(character, ifs)
        character && character.split && !character.text.empty? && ifs.include?(character.text)
      end

      def self.whitespace?(character, ifs)
        separator?(character, ifs) && DEFAULT_IFS.include?(character.text)
      end

      # Ranges retain original separators for read's final, unsplit variable.
      def self.ranges(characters, ifs, limit: nil)
        result = []
        index = 0
        index += 1 while whitespace?(characters[index], ifs)
        while index < characters.length
          start = index
          if limit && result.length >= limit
            finish = characters.length
            finish -= 1 while finish > start && whitespace?(characters[finish - 1], ifs)
            result << (start...finish) if finish > start
            break
          end
          index += 1 while index < characters.length && !separator?(characters[index], ifs)
          result << (start...index)
          if whitespace?(characters[index], ifs)
            index += 1 while whitespace?(characters[index], ifs)
            index += 1 if separator?(characters[index], ifs)
          elsif separator?(characters[index], ifs)
            index += 1
          end
          index += 1 while whitespace?(characters[index], ifs)
        end
        result
      end

      def self.value(characters)
        characters.map(&:text).join
      end

      def self.pattern(characters, glob: false)
        characters.map do |character|
          next character.text unless character.quoted || glob
          special = character.quoted ? /[\\*?\[\]{}!^\-]/ : /[{}]/
          character.text.gsub(special) { |text| "\\#{text}" }
        end.join
      end
    end
  end
end
