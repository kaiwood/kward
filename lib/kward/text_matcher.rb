# Namespace for the Kward CLI agent runtime.
module Kward
  # Allocation-conscious text matching helpers shared by interactive search UI.
  module TextMatcher
    module_function

    def subsequence_pattern(query)
      source = query.to_s.each_char.map { |character| Regexp.escape(character) }.join(".*")
      Regexp.new(source, Regexp::MULTILINE)
    end

    def subsequence?(value, query, pattern = subsequence_pattern(query))
      text = value.to_s
      needle = query.to_s
      needle.empty? || text.match?(pattern)
    end
  end
end
