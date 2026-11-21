require_relative "test_helper"

class TestTerminalHandoff < KwardTestCase
  def test_child_keyboard_mutations_are_blocked_at_every_chunk_boundary
    controls = ["\e[<u", "\e[<1u", "\e[<99u", "\e[>0u", "\e[=0u", "\e[=1;3u", "\e[>4m", "\e[>4;2m"]
    controls.each do |control|
      (0..control.bytesize).each do |split|
        output = StringIO.new
        handoff = Kward::PromptInterface::TerminalHandoffOutput.new(output)
        handoff.write("before" + control.byteslice(0, split))
        handoff.write(control.byteslice(split..) + "after")
        assert_equal "beforeafter", output.string, "#{control.inspect} at #{split}"
      end
    end
  end

  def test_screen_switches_and_resets_reassert_keyboard_encoding_without_pushing
    controls = ["\ec", "\e[!p", "\e[?1049h", "\e[?1049l", "\e[?47h", "\e[?1047l", "\e[?25;1049h"]
    controls.each do |control|
      output = StringIO.new
      handoff = Kward::PromptInterface::TerminalHandoffOutput.new(output)
      control.each_byte { |byte| handoff.write(byte.chr) }
      assert_equal control + Kward::TerminalSequences::KEYBOARD_PROTOCOL_SET, output.string
    end
  end

  def test_ordinary_output_queries_and_terminal_strings_remain_byte_preserving
    output = StringIO.new
    handoff = Kward::PromptInterface::TerminalHandoffOutput.new(output)
    text = "snowman ☃\rprogress\e[0m\e[?u\e[2J\e]title\a\ePpayload\a\e[<u\e\\\e_Gdata\e\\"
    text.b.each_byte { |byte| assert_equal 1, handoff.write(byte.chr) }
    assert_equal text.b, output.string.b
  end

  def test_output_parser_does_not_retain_plain_output_or_terminal_string_payloads
    output = StringIO.new
    handoff = Kward::PromptInterface::TerminalHandoffOutput.new(output)
    chunk = "x" * 8192
    10.times { handoff.write(chunk) }
    assert_empty handoff.instance_variable_get(:@pending)
    handoff.write("\e]" + chunk)
    assert_empty handoff.instance_variable_get(:@pending)
    handoff.write("\a\e[" + chunk.tr("x", "1"))
    assert_operator handoff.instance_variable_get(:@pending).bytesize, :<, 4096
    assert_includes output.string, Kward::TerminalSequences::CONTROL_SEQUENCE_CANCEL
    handoff.write("\e[<uafter")
    assert output.string.end_with?("after")
    refute_includes output.string, "\e[<u"
  end

  def test_interrupted_control_cannot_hide_a_keyboard_mutation
    output = StringIO.new
    handoff = Kward::PromptInterface::TerminalHandoffOutput.new(output)
    handoff.write("\e[123\e[<uafter")
    assert_equal "\e[123" + Kward::TerminalSequences::CONTROL_SEQUENCE_CANCEL + "after", output.string
  end

  def test_embedded_controls_do_not_end_keyboard_mode_sequences
    output = StringIO.new
    handoff = Kward::PromptInterface::TerminalHandoffOutput.new(output)
    handoff.write("\e[<\a1uafter")
    assert_equal "\aafter", output.string
    handoff.write("\e[<\x18u\e[<\x1au")
    assert output.string.end_with?("\e[<\x18u\e[<\x1au")
  end

  def test_adaptive_handoff_protects_shortcuts_before_and_after_screen_switch
    output = StringIO.new
    prompt = build_prompt(output: output)
    prompt.start
    3.times do
      prompt.with_inline_terminal_handoff(preserve_tab_keybindings: true) do |_input, handoff_output, transition|
        sink = Kward::AdaptivePtyOutputSink.new(output: handoff_output, on_exclusive: transition)
        sink.write("progress\rfinished\e[>0")
        sink.write("u\e[?1049h\e[<99u")
        assert output.string.end_with?("\e[?1049h" + Kward::TerminalSequences::KEYBOARD_PROTOCOL_SET)
        assert_equal({ input: "", tab_action: { tab_action: :select, index: 1 } }, prompt.filter_terminal_handoff_input("\e[50;5u"))
        sink.finish
      end
      assert_equal({ tab_action: :select, index: 2 }, prompt.send(:handle_key, "\e[51;5u"))
    end
    prompt.close
    assert_equal 1, output.string.scan(Kward::TerminalSequences::KEYBOARD_PROTOCOL_ENABLE).length
    assert_equal 1, output.string.scan(Kward::TerminalSequences::KEYBOARD_PROTOCOL_RESTORE).length
    refute_includes output.string, "\e[<99u"
  end

  def test_fragmented_keys_translate_to_legacy_child_input
    keys = { "\e[99;5u" => "\x03", "\e[27u" => "\e", "\e[97;1;97u" => "a", "\e[13u" => "\r", "\e[99;5:3u" => "" }
    keys.each do |key, expected|
      (1...key.bytesize).each do |split|
        prompt = build_prompt
        first = prompt.filter_terminal_handoff_input(key.byteslice(0, split))
        second = prompt.filter_terminal_handoff_input(key.byteslice(split..))
        assert_equal expected, first[:input] + second[:input], "#{key.inspect} at #{split}"
        assert_nil first[:tab_action]
        assert_nil second[:tab_action]
      end
    end
  end

  def test_standalone_modifier_reports_do_not_reach_child_input
    keys = ["\e[57441;2u", "\e[57444;9u", "\e[57444;10u", "\e[57450;9:2u"]
    keys.each do |key|
      (1...key.bytesize).each do |split|
        prompt = build_prompt
        first = prompt.filter_terminal_handoff_input("a" + key.byteslice(0, split))
        second = prompt.filter_terminal_handoff_input(key.byteslice(split..) + "\e[A")
        assert_equal({ input: "a", tab_action: nil }, first, "#{key.inspect} at #{split}")
        assert_equal({ input: "\e[A", tab_action: nil }, second, "#{key.inspect} at #{split}")
      end
    end
  end

  def test_tab_shortcuts_accept_extended_fields_lock_modifiers_and_xterm_encoding
    keys = ["\e[51;5u", "\e[51;5:1u", "\e[51;69u", "\e[51;133u", "\e[51::51;5u", "\e[27;5;51~"]
    keys.each do |key|
      prompt = build_prompt
      assert_equal({ tab_action: :select, index: 2 }, prompt.send(:handle_key, key), key.inspect)
      result = nil
      key.each_byte { |byte| result = prompt.filter_terminal_handoff_input(byte.chr) }
      assert_equal({ input: "", tab_action: { tab_action: :select, index: 2 } }, result, key.inspect)
    end
  end

  def test_alt_bindings_work_with_legacy_and_preserved_keyboard_encoding
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, tab_keybindings: "alt")
    prompt.update_tabs(labels: %w[1 2 3], active_index: 0)
    ["\e3", "\e[51;3u", "\e[51;67u"].each do |key|
      assert_equal({ tab_action: :select, index: 2 }, prompt.send(:handle_key, key))
      assert_equal({ input: "", tab_action: { tab_action: :select, index: 2 } }, prompt.filter_terminal_handoff_input(key))
    end
  end

  def test_key_releases_do_not_switch_tabs_or_reach_child
    prompt = build_prompt
    assert_equal true, prompt.send(:handle_key, "\e[51;5:3u")
    assert_equal({ input: "", tab_action: nil }, prompt.filter_terminal_handoff_input("\e[51;5:3u"))
  end

  def test_bracketed_paste_is_forwarded_without_executing_embedded_shortcuts
    prompt = build_prompt
    paste = "\e[200~text\x14\e[51;5u\e[57444;9u\e[201~"
    forwarded = +""
    paste.each_byte do |byte|
      result = prompt.filter_terminal_handoff_input(byte.chr)
      forwarded << result[:input]
      assert_nil result[:tab_action]
    end
    assert_equal paste, forwarded
    assert_equal({ input: "", tab_action: { tab_action: :select, index: 0 } }, prompt.filter_terminal_handoff_input("\e[49;5u"))
  end

  def test_unknown_sequences_are_forwarded_and_incomplete_input_is_bounded
    prompt = build_prompt
    sequence = "\e[?25;1$y"
    forwarded = sequence.each_byte.map { |byte| prompt.filter_terminal_handoff_input(byte.chr)[:input] }.join
    assert_equal sequence, forwarded
    result = prompt.filter_terminal_handoff_input("\e[" + "1" * 8192)
    refute_empty result[:input]
    assert_empty prompt.instance_variable_get(:@handoff_input_buffer)
  end

  private

  def build_prompt(output: StringIO.new)
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: output, tab_keybindings: "ctrl")
    prompt.update_tabs(labels: %w[1 2 3], active_index: 0)
    prompt
  end
end
