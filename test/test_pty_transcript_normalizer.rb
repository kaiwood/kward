require_relative "test_helper"

class TestPtyTranscriptNormalizer < KwardTestCase
  def test_carriage_return_progress_keeps_the_final_frame
    output = "Downloading 10%\r\e[2KDownloading 100%"

    assert_equal "Downloading 100%", Kward::PtyTranscriptNormalizer.normalize(output)
  end

  def test_horizontal_absolute_position_overwrites_the_current_line
    output = "first frame\e[K\e[0Gsecond frame\e[K\e[0Gdone\e[K"

    assert_equal "done", Kward::PtyTranscriptNormalizer.normalize(output)
  end

  def test_relative_horizontal_cursor_movement_overwrites_cells
    assert_equal "abcXYZ", Kward::PtyTranscriptNormalizer.normalize("abcdef\e[3DXYZ")
  end

  def test_cursor_positions_clamp_to_screen_width
    assert_equal "ok     X", Kward::PtyTranscriptNormalizer.normalize("ok\e[1000GX", columns: 8)
    assert_equal "ok     X", Kward::PtyTranscriptNormalizer.normalize("ok\e[1000CX", columns: 8)
    assert_equal "Xk", Kward::PtyTranscriptNormalizer.normalize("ok\e[1000DX", columns: 8)
  end

  def test_expanded_rows_respect_the_transcript_byte_budget
    output = "\e[80GX\n" * 2

    assert_nil Kward::PtyTranscriptNormalizer.normalize(output, max_bytes: 100)
  end

  def test_backspace_redraws_without_other_cursor_controls
    assert_equal "abX", Kward::PtyTranscriptNormalizer.normalize("abc\bX")
  end

  def test_wide_and_combining_graphemes_use_terminal_cells
    assert_equal "好Y", Kward::PtyTranscriptNormalizer.normalize("好X\e[3GY")
    assert_equal "e\u0301Y", Kward::PtyTranscriptNormalizer.normalize("e\u0301X\e[2GY")
    assert_equal "e\u0301Y", Kward::PtyTranscriptNormalizer.normalize("e\e[31m\u0301X\e[2GY")
  end

  def test_overwriting_or_erasing_one_half_of_a_wide_grapheme_clears_both
    assert_equal " YX", Kward::PtyTranscriptNormalizer.normalize("好X\e[2GY")
    assert_equal "", Kward::PtyTranscriptNormalizer.normalize("好X\e[2G\e[K")
    assert_equal "  X", Kward::PtyTranscriptNormalizer.normalize("好X\e[1G\e[1K")
  end

  def test_static_lines_preserve_sgr_and_remove_terminal_modes
    output = "\e[?2026h\e[32mdone\e[0m\e[?2026l"

    assert_equal "\e[32mdone\e[0m", Kward::PtyTranscriptNormalizer.normalize(output)
  end

  def test_rewritten_lines_are_plain_and_keep_static_lines_styled
    output = "\e[33mheading\e[0m\n\e[?2026h\e[32mold\e[0m\e[0Gnew\e[K\e[?2026l\n"

    assert_equal "\e[33mheading\e[0m\nnew\n", Kward::PtyTranscriptNormalizer.normalize(output)
  end
end
