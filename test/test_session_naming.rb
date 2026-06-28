require_relative "test_helper"

class TestSessionNaming < KwardTestCase
  def test_default_name_collapses_whitespace_and_truncates
    input = "  build\n  the   thing  " + ("x" * 200)

    name = Kward::SessionNaming.default_name(input)

    assert_equal 120, name.length
    assert_match(/\Abuild the thing x+\z/, name)
  end
end
