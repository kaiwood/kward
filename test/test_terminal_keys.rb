require_relative "test_helper"

class TestTerminalKeys < KwardTestCase
  def test_terminal_key_groups_are_frozen
    groups = [
      Kward::TerminalKeys::TAB,
      Kward::TerminalKeys::LEFT,
      Kward::TerminalKeys::RIGHT,
      Kward::TerminalKeys::SHIFT_TAB,
      Kward::TerminalKeys::CTRL_TAB,
      Kward::TerminalKeys::ALT_RIGHT
    ]

    assert groups.all?(&:frozen?)
  end

  def test_terminal_key_groups_name_common_sequences
    assert_includes Kward::TerminalKeys::LEFT, "\e[D"
    assert_includes Kward::TerminalKeys::LEFT, "\eOD"
    assert_includes Kward::TerminalKeys::SHIFT_ENTER, "\e[13;2u"
    assert_includes Kward::TerminalKeys::CTRL_TAB, "\e[9;5u"
    assert_includes Kward::TerminalKeys::ALT_SHIFT_RIGHT, "\e[1;4C"
  end

  def test_terminal_key_patterns_match_expected_sequences
    assert_match Kward::TerminalKeys::CSI_KEY_PATTERN, "\e[1;3Cextra"
    assert_match Kward::TerminalKeys::SS3_KEY_PATTERN, "\eOCextra"
    assert_match Kward::TerminalKeys::CSI_U_PATTERN, "\e[97;2;65u"
    assert_match Kward::TerminalKeys::MODIFIED_CURSOR_PATTERN, "\e[1;3C"
    assert_match Kward::TerminalKeys::MODIFIED_DELETE_PATTERN, "\e[3;3~"
    assert_match Kward::TerminalKeys::UP_PATTERN, "\e[1;2A"
    assert_match Kward::TerminalKeys::DOWN_PATTERN, "\e[1;2B"
    assert_match Kward::TerminalKeys::RIGHT_PATTERN, "\e[1;2C"
    assert_match Kward::TerminalKeys::LEFT_PATTERN, "\e[1;2D"
    assert_match Kward::TerminalKeys::CTRL_NUMBER_TAB_PATTERN, "\e[49;5u"
  end
end
