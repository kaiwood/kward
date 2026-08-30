require_relative "test_helper"

class TestTextMatcher < KwardTestCase
  def test_subsequence_matches_contiguous_and_scattered_characters
    assert Kward::TextMatcher.subsequence?("lib/kward/prompt_interface.rb", "prompt")
    assert Kward::TextMatcher.subsequence?("lib/kward/prompt_interface.rb", "lkpi")
  end

  def test_subsequence_rejects_out_of_order_characters
    refute Kward::TextMatcher.subsequence?("composer", "crp")
  end

  def test_subsequence_supports_unicode_codepoints_and_newlines
    assert Kward::TextMatcher.subsequence?("café/composer.rb", "féco")
    assert Kward::TextMatcher.subsequence?("review\nthe composer", "rwco")
  end
end
