# Namespace for the Kward CLI agent runtime.
module Kward
  # Small text navigation helpers shared by composer and editor buffers.
  module TextBoundary
    module_function

    def previous_word_boundary(text, index)
      cursor = index.to_i
      cursor -= 1 while cursor.positive? && word_separator?(text[cursor - 1])
      cursor -= 1 while cursor.positive? && !word_separator?(text[cursor - 1])
      cursor
    end

    def next_word_boundary(text, index)
      cursor = index.to_i
      cursor += 1 while cursor < text.length && word_separator?(text[cursor])
      cursor += 1 while cursor < text.length && !word_separator?(text[cursor])
      cursor
    end

    def word_separator?(char)
      char.to_s.match?(/\s/)
    end
  end
end
