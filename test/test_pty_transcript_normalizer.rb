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

  def test_static_lines_preserve_sgr_and_remove_terminal_modes
    output = "\e[?2026h\e[32mdone\e[0m\e[?2026l"

    assert_equal "\e[32mdone\e[0m", Kward::PtyTranscriptNormalizer.normalize(output)
  end

  def test_rewritten_lines_are_plain_and_keep_static_lines_styled
    output = "\e[33mheading\e[0m\n\e[?2026h\e[32mold\e[0m\e[0Gnew\e[K\e[?2026l\n"

    assert_equal "\e[33mheading\e[0m\nnew\n", Kward::PtyTranscriptNormalizer.normalize(output)
  end
end
