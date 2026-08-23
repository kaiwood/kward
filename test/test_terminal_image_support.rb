require_relative "test_helper"

class TestTerminalImageSupport < KwardTestCase
  def test_static_protocol_recognizes_ghostty_and_kitty_hints
    assert_equal :kitty, Kward::TerminalImageSupport.static_protocol("TERM" => "xterm-ghostty")
    assert_equal :kitty, Kward::TerminalImageSupport.static_protocol("TERM_PROGRAM" => "Ghostty")
    assert_equal :kitty, Kward::TerminalImageSupport.static_protocol("KITTY_WINDOW_ID" => "1")
  end

  def test_static_protocol_prefers_iterm_protocol_for_wezterm
    assert_equal :iterm2, Kward::TerminalImageSupport.static_protocol("TERM_PROGRAM" => "WezTerm")
    assert_equal :iterm2, Kward::TerminalImageSupport.static_protocol("WEZTERM_PANE" => "1")
    assert_equal :iterm2, Kward::TerminalImageSupport.static_protocol("TERM_FEATURES" => "TFCw")
  end

  def test_detect_fails_closed_without_a_tty
    assert_nil Kward::TerminalImageSupport.detect(
      env: { "TERM_PROGRAM" => "ghostty" },
      input: StringIO.new,
      output: StringIO.new
    )
    assert_equal :kitty, Kward::TerminalImageSupport.detect(env: { "TERM_PROGRAM" => "ghostty" })
  end

  def test_detect_uses_a_known_kitty_hint_when_the_probe_is_negative
    assert_equal :kitty, Kward::TerminalImageSupport.detect(
      env: { "TERM_PROGRAM" => "ghostty" },
      input: tty_stub,
      output: tty_stub,
      probe_result: false
    )
  end

  def test_detect_stays_fail_closed_for_unknown_terminals_after_a_negative_probe
    assert_nil Kward::TerminalImageSupport.detect(
      env: { "TERM_PROGRAM" => "unknown-terminal" },
      input: tty_stub,
      output: tty_stub,
      probe_result: false
    )
  end

  def test_probe_parser_requires_a_da1_boundary
    refute Kward::TerminalImageSupport.da1_response?("\e_Gi=31;OK\e\\")
    assert Kward::TerminalImageSupport.da1_response?("\e_Gi=31;OK\e\\\e[?1;2c")
    assert Kward::TerminalImageSupport.kitty_probe_success?("\e_Gi=31;OK\e\\\e[?1;2c")
    refute Kward::TerminalImageSupport.kitty_probe_success?("\e[?1;2c")
  end

  def test_kitty_probe_uses_the_protocol_query
    assert_equal "\e_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA\e\\\e[c", Kward::TerminalImageSupport::KITTY_PROBE
  end

  def test_kitty_cleanup_and_tmux_passthrough_sequences_are_protocol_safe
    delete = Kward::TerminalSequences.kitty_delete(7)
    assert_equal "\e_Ga=d,d=I,i=7,q=2;\e\\", delete
    assert_equal "\ePtmux;\e\e_Ga=d,d=I,i=7,q=2;\e\e\\\e\\", Kward::TerminalSequences.tmux_passthrough(delete)
  end

  private

  def tty_stub
    Object.new.tap { |io| io.define_singleton_method(:tty?) { true } }
  end
end
