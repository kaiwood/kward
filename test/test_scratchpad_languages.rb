require_relative "test_helper"

class TestScratchpadLanguages < KwardTestCase
  def test_normalizes_canonical_names_and_aliases
    Kward::ScratchpadLanguages::LANGUAGES.each do |language, definition|
      assert_equal language, Kward::ScratchpadLanguages.normalize(language)

      definition.fetch(:aliases).each do |alias_name|
        assert_equal language, Kward::ScratchpadLanguages.normalize(alias_name), alias_name
      end
    end
  end

  def test_provides_a_display_path_for_each_language
    Kward::ScratchpadLanguages::LANGUAGES.each do |language, definition|
      assert_equal definition.fetch(:display_path), Kward::ScratchpadLanguages.display_path(language)
    end
  end

  def test_only_ruby_is_runnable
    assert Kward::ScratchpadLanguages.runnable?(:ruby)
    refute Kward::ScratchpadLanguages.runnable?(:python)
    refute Kward::ScratchpadLanguages.runnable?(:text)
  end

  def test_unknown_language_is_rejected
    error = assert_raises(ArgumentError) { Kward::ScratchpadLanguages.normalize("not-a-language") }

    assert_includes error.message, "not-a-language"
    assert_includes error.message, "/scratchpad help"
  end

  def test_help_lists_canonical_names_and_aliases
    help = Kward::ScratchpadLanguages.help_text

    assert_includes help, "javascript (js, jsx, mjs, cjs)"
    assert_includes help, "python (py, pyw)"
    assert_includes help, "csharp (cs, c#)"
  end
end
