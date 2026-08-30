require_relative "test_helper"

class TestTerminalText < KwardTestCase
  def test_width_counts_terminal_cells
    assert_equal 2, Kward::TerminalText.width("界")
    assert_equal 1, Kward::TerminalText.width("e\u0301")
    assert_equal 2, Kward::TerminalText.width("👩‍💻")
  end

  def test_truncate_preserves_complete_graphemes
    assert_equal "界a", Kward::TerminalText.truncate("界abc", 3)
    assert_equal "e\u0301", Kward::TerminalText.truncate("e\u0301x", 1)
  end

  def test_wrap_reports_cell_aware_cursor_position
    layout = Kward::TerminalText.wrap("界界a", width: 4, cursor: 3)

    assert_equal ["界界", "a"], layout[:rows]
    assert_equal 1, layout[:cursor_row]
    assert_equal 1, layout[:cursor_col]
  end

  def test_grapheme_boundaries_keep_joined_emoji_together
    text = "a👩‍💻b"
    emoji_end = 1 + "👩‍💻".length

    assert_equal 1, Kward::TerminalText.previous_grapheme_boundary(text, emoji_end)
    assert_equal emoji_end, Kward::TerminalText.next_grapheme_boundary(text, 1)
  end
end
