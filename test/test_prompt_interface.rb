require_relative "test_helper"

class TestPromptInterface < KwardTestCase
  def test_prompt_interface_renders_empty_composer_before_typing
    output = StringIO.new
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: output)

    prompt.start

    refute_includes output.string, "You> "
  end

  def test_prompt_interface_renders_boxed_composer_and_scroll_region
    output = StringIO.new
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: output)

    prompt.start

    assert_includes output.string, "╭ You "
    refute_includes output.string, "│ You> "
    assert_includes output.string, "╰"
    assert_match(/\e\[1;\d+r/, output.string)
    refute_includes output.string, TTY::Cursor.clear_screen
  end

  def test_prompt_interface_enables_and_restores_keyboard_protocol
    output = StringIO.new
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: output)

    prompt.start
    prompt.close

    assert_includes output.string, "\e[>1u"
    assert_includes output.string, "\e[r"
    assert_includes output.string, "\e[<u"
  end

  def test_prompt_interface_renders_output_when_screen_has_extra_rows
    output = StringIO.new
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: output)
    prompt.start
    output.truncate(0)
    output.rewind

    prompt.say("first\nsecond")

    assert_includes output.string, "first"
    assert_includes output.string, "second"
  end

  def test_prompt_interface_submits_input_on_enter
    input, writer = IO.pipe
    output = StringIO.new
    writer.write("hello\r")
    writer.close
    prompt = Kward::PromptInterface.new(input: input, output: output)

    assert_equal "hello", prompt.ask("You>")
  ensure
    input&.close unless input&.closed?
  end

  def test_prompt_interface_select_uses_arrows_and_enter
    input, writer = IO.pipe
    output = StringIO.new
    writer.write("\e[B\r")
    writer.close
    prompt = Kward::PromptInterface.new(input: input, output: output)

    assert_equal "second", prompt.select("Session>", ["first", "second"])
  ensure
    input&.close unless input&.closed?
  end

  def test_prompt_interface_select_filters_choices
    input, writer = IO.pipe
    output = StringIO.new
    writer.write("sec\r")
    writer.close
    prompt = Kward::PromptInterface.new(input: input, output: output)

    assert_equal "second", prompt.select("Session>", ["first", "second"])
  ensure
    input&.close unless input&.closed?
  end

  def test_prompt_interface_select_escape_cancels
    input, writer = IO.pipe
    output = StringIO.new
    writer.write("\e")
    writer.close
    prompt = Kward::PromptInterface.new(input: input, output: output)

    assert_nil prompt.select("Session>", ["first", "second"])
  ensure
    input&.close unless input&.closed?
  end

  def test_prompt_interface_select_submits_on_csi_u_enter
    input, writer = IO.pipe
    output = StringIO.new
    writer.write("\e[B\e[13u")
    writer.close
    prompt = Kward::PromptInterface.new(input: input, output: output)

    assert_equal "second", prompt.select("Session>", ["first", "second"])
  ensure
    input&.close unless input&.closed?
  end

  def test_prompt_interface_select_cancels_on_csi_u_escape
    ["\e[27u", "\e[27;1u"].each do |sequence|
      input, writer = IO.pipe
      output = StringIO.new
      writer.write(sequence)
      writer.close
      prompt = Kward::PromptInterface.new(input: input, output: output)

      assert_nil prompt.select("Session>", ["first", "second"])
    ensure
      input&.close unless input&.closed?
    end
  end

  def test_prompt_interface_ask_user_question_selects_option
    input, writer = IO.pipe
    output = StringIO.new
    writer.write("\e[B\r")
    writer.close
    prompt = Kward::PromptInterface.new(input: input, output: output)

    answers = prompt.ask_user_question([question_args("Proceed?")])

    assert_equal [{ question: "Proceed?", answer: "No", custom: false }], answers
    assert_includes strip_ansi(output.string), "Question 1/1"
    assert_includes strip_ansi(output.string), "Proceed?"
    assert_includes strip_ansi(output.string), "No — Stop."
  ensure
    input&.close unless input&.closed?
  end

  def test_prompt_interface_ask_user_question_accepts_custom_answer
    input, writer = IO.pipe
    output = StringIO.new
    writer.write("maybe\r")
    writer.close
    prompt = Kward::PromptInterface.new(input: input, output: output)

    answers = prompt.ask_user_question([question_args("Proceed?")])

    assert_equal [{ question: "Proceed?", answer: "maybe", custom: true }], answers
    assert_includes strip_ansi(output.string), "Type something: maybe"
  ensure
    input&.close unless input&.closed?
  end

  def test_prompt_interface_ask_user_question_handles_multiple_questions
    input, writer = IO.pipe
    output = StringIO.new
    writer.write("custom\r\e[B\r")
    writer.close
    prompt = Kward::PromptInterface.new(input: input, output: output)

    answers = prompt.ask_user_question([question_args("First?"), question_args("Second?")])

    assert_equal [
      { question: "First?", answer: "custom", custom: true },
      { question: "Second?", answer: "No", custom: false }
    ], answers
  ensure
    input&.close unless input&.closed?
  end

  def test_prompt_interface_ask_user_question_escape_cancels
    input, writer = IO.pipe
    output = StringIO.new
    writer.write("\e")
    writer.close
    prompt = Kward::PromptInterface.new(input: input, output: output)

    assert_nil prompt.ask_user_question([question_args("Proceed?")])
  ensure
    input&.close unless input&.closed?
  end

  def test_prompt_interface_exits_on_ctrl_d_when_empty
    assert_nil ask_prompt_with_input("\x04")
  end

  def test_prompt_interface_exits_on_csi_u_ctrl_d_when_empty
    assert_nil ask_prompt_with_input("\e[4u")
    assert_nil ask_prompt_with_input("\e[100;5u")
  end

  def test_prompt_interface_does_not_exit_on_ctrl_d_when_text_remains
    assert_equal "hello", ask_prompt_with_input("hello\x04\r")
  end

  def test_prompt_interface_handles_cursor_movement_keys
    input, writer = IO.pipe
    output = StringIO.new
    writer.write("ab\e[DZ\r")
    writer.close
    prompt = Kward::PromptInterface.new(input: input, output: output)

    assert_equal "aZb", prompt.ask("You>")
  ensure
    input&.close unless input&.closed?
  end

  def test_prompt_interface_backspace_deletes_empty_line
    input, writer = IO.pipe
    output = StringIO.new
    writer.write("hello\e[13;2u\b\r")
    writer.close
    prompt = Kward::PromptInterface.new(input: input, output: output)

    assert_equal "hello", prompt.ask("You>")
  ensure
    input&.close unless input&.closed?
  end

  def test_prompt_interface_backspace_after_escape_return_shift_enter_deletes_empty_line
    input, writer = IO.pipe
    output = StringIO.new
    writer.write("hello\e\r\x7F\r")
    writer.close
    prompt = Kward::PromptInterface.new(input: input, output: output)

    assert_equal "hello", prompt.ask("You>")
  ensure
    input&.close unless input&.closed?
  end

  def test_prompt_interface_inserts_newline_on_shift_enter_variants
    ["\e[13;2u", "\e[13;2~", "\e[27;2;13~", "\e\r", "\e\n"].each do |sequence|
      assert_equal "hello\nworld", ask_prompt_with_input("hello#{sequence}world\r")
    end
  end

  def test_prompt_interface_pastes_bracketed_multiline_text
    assert_equal "hello\nworld", ask_prompt_with_input("\e[200~hello\nworld\e[201~\r")
  end

  def test_prompt_interface_shows_slash_overlay_and_completes_selection
    input, writer = IO.pipe
    output = StringIO.new
    writer.write("/\t\r")
    writer.close
    prompt = Kward::PromptInterface.new(
      input: input,
      output: output,
      slash_commands: [{ name: "plan", description: "Plan work.", argument_hint: "<task>" }]
    )

    assert_equal "/plan ", prompt.ask("You>")
    assert_includes strip_ansi(output.string), "Slash commands"
    assert_includes strip_ansi(output.string), "/plan <task>"
  ensure
    input&.close unless input&.closed?
  end

  def test_prompt_interface_reuses_history_with_up_arrow
    input, writer = IO.pipe
    output = StringIO.new
    writer.write("first\r\e[A\r")
    writer.close
    prompt = Kward::PromptInterface.new(input: input, output: output)

    assert_equal "first", prompt.ask("You>")
    assert_equal "first", prompt.ask("You>")
  ensure
    input&.close unless input&.closed?
  end

  def test_prompt_interface_queues_input_while_busy
    input, writer = IO.pipe
    output = StringIO.new
    writer.write("next\r")
    writer.close
    prompt = Kward::PromptInterface.new(input: input, output: output)
    prompt.begin_busy_input("You>")

    queued = poll_prompt_until(prompt) { |result| result.is_a?(String) }

    assert_equal "next", queued
    refute_includes output.string, "You> "
  ensure
    input&.close unless input&.closed?
  end

  def test_prompt_interface_does_not_redraw_composer_between_stream_chunks
    output = StringIO.new
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: output)
    prompt.begin_busy_input("You>")
    output.truncate(0)
    output.rewind

    prompt.start_stream_block("Assistant")
    prompt.write_delta("hello")

    assert_includes output.string, "Assistant>"
    assert_includes output.string, "hello"
    refute_includes strip_ansi(output.string), Kward::PromptInterface::HELP_TEXT
    refute_includes strip_ansi(output.string), Kward::PromptInterface::BUSY_HELP_TEXT
    refute_includes strip_ansi(output.string), "You> "
    refute_includes strip_ansi(output.string), "╭"
  end

  def test_prompt_interface_restores_cursor_to_composer_after_stream_render
    output = StringIO.new
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: output)
    original_width = TTY::Screen.method(:width)
    original_height = TTY::Screen.method(:height)
    TTY::Screen.define_singleton_method(:width) { 80 }
    TTY::Screen.define_singleton_method(:height) { 20 }
    prompt.begin_busy_input("You>")
    output.truncate(0)
    output.rewind

    prompt.start_stream_block("Assistant")
    assert_match(/\e\[19;3H\z/, output.string)

    output.truncate(0)
    output.rewind
    prompt.write_delta("hello")
    assert_match(/\e\[19;3H\z/, output.string)

    output.truncate(0)
    output.rewind
    prompt.finish_stream_block
    assert_match(/\e\[19;3H\z/, output.string)
  ensure
    TTY::Screen.define_singleton_method(:width, original_width) if original_width
    TTY::Screen.define_singleton_method(:height, original_height) if original_height
  end

  def test_prompt_interface_writes_transcript_newlines_as_crlf
    output = StringIO.new
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: output)
    prompt.begin_busy_input("You>")
    output.truncate(0)
    output.rewind

    prompt.start_stream_block("Tool output")
    prompt.write_delta(".git/\n.gitignore\nREADME.md\n")

    stripped = strip_ansi(output.string)
    assert_includes stripped, "Tool output>\r\n.git/\r\n.gitignore\r\nREADME.md\r\n"
  end

  def test_prompt_interface_advances_after_full_width_stream_chunk
    output = StringIO.new
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: output)
    original_width = TTY::Screen.method(:width)
    TTY::Screen.define_singleton_method(:width) { 10 }
    prompt.begin_busy_input("You>")
    output.truncate(0)
    output.rewind

    prompt.write_delta("a" * 10)
    prompt.write_delta("next")

    assert_includes output.string, "\r\nnext"
  ensure
    TTY::Screen.define_singleton_method(:width, original_width) if original_width
  end

  def test_prompt_interface_resets_scroll_region_and_rerenders_on_resize
    output = StringIO.new
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: output)
    original_height = TTY::Screen.method(:height)
    prompt.start
    output.truncate(0)
    output.rewind
    TTY::Screen.define_singleton_method(:height) { 12 }

    prompt.send(:handle_resize_locked)
    prompt.send(:render_prompt_locked)

    assert_includes output.string, "\e[r"
    assert_includes output.string, TTY::Cursor.clear_screen
    assert_match(/\e\[1;\d+r/, output.string)
    assert_includes output.string, "╭ You "
  ensure
    TTY::Screen.define_singleton_method(:height, original_height) if original_height
  end

  def test_prompt_interface_redraw_replays_visible_transcript_and_composer
    output = StringIO.new
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: output)
    prompt.start
    prompt.say("first\nsecond")
    output.truncate(0)
    output.rewind

    prompt.redraw

    assert_includes output.string, TTY::Cursor.clear_screen
    assert_includes output.string, "first\r\nsecond"
    assert_includes output.string, "╭ You "
  end

  def test_prompt_interface_clear_transcript_removes_visible_transcript
    output = StringIO.new
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: output)
    prompt.start
    prompt.say("former transcript")
    output.truncate(0)
    output.rewind

    prompt.clear_transcript

    assert_includes output.string, TTY::Cursor.clear_screen
    refute_includes output.string, "former transcript"
    assert_includes output.string, "╭ You "
  end

  def test_prompt_interface_clears_between_old_and_new_composer_when_height_grows
    output = StringIO.new
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: output)
    prompt.instance_variable_set(:@last_width, 80)
    prompt.instance_variable_set(:@last_height, 10)
    prompt.instance_variable_set(:@reserved_rows, 3)
    original_width = TTY::Screen.method(:width)
    original_height = TTY::Screen.method(:height)
    TTY::Screen.define_singleton_method(:width) { 80 }
    TTY::Screen.define_singleton_method(:height) { 20 }

    prompt.send(:handle_resize_locked)

    assert_includes output.string, "\e[8;1H#{TTY::Cursor.clear_line}"
    assert_includes output.string, "\e[20;1H#{TTY::Cursor.clear_line}"
  ensure
    TTY::Screen.define_singleton_method(:width, original_width) if original_width
    TTY::Screen.define_singleton_method(:height, original_height) if original_height
  end

  def test_prompt_interface_clears_wrapped_old_composer_rows_when_resized_narrower
    output = StringIO.new
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: output)
    prompt.instance_variable_set(:@last_width, 120)
    prompt.instance_variable_set(:@last_height, 20)
    prompt.instance_variable_set(:@reserved_rows, 3)
    original_width = TTY::Screen.method(:width)
    original_height = TTY::Screen.method(:height)
    TTY::Screen.define_singleton_method(:width) { 30 }
    TTY::Screen.define_singleton_method(:height) { 20 }

    prompt.send(:handle_resize_locked)

    assert_includes output.string, "\e[9;1H#{TTY::Cursor.clear_line}"
    assert_includes output.string, "\e[20;1H#{TTY::Cursor.clear_line}"
  ensure
    TTY::Screen.define_singleton_method(:width, original_width) if original_width
    TTY::Screen.define_singleton_method(:height, original_height) if original_height
  end

  def test_prompt_interface_reserves_composer_rows_after_resized_clear_for_output
    output = StringIO.new
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: output)
    original_width = TTY::Screen.method(:width)
    original_height = TTY::Screen.method(:height)
    TTY::Screen.define_singleton_method(:width) { 80 }
    TTY::Screen.define_singleton_method(:height) { 20 }
    prompt.start
    output.truncate(0)
    output.rewind
    TTY::Screen.define_singleton_method(:height) { 10 }

    prompt.send(:clear_prompt_for_output_locked)

    assert_includes output.string, "\e[r"
    assert_includes output.string, "\e[1;7r"
  ensure
    TTY::Screen.define_singleton_method(:width, original_width) if original_width
    TTY::Screen.define_singleton_method(:height, original_height) if original_height
  end

  def test_prompt_interface_uses_compact_composer_on_tiny_screens
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new)
    original_height = TTY::Screen.method(:height)
    TTY::Screen.define_singleton_method(:height) { 3 }
    prompt.instance_variable_set(:@input, "hello")
    prompt.instance_variable_set(:@cursor, 5)

    rows, cursor_row, = prompt.send(:composer_layout, 20)

    assert_equal 1, rows.length
    assert_equal 0, cursor_row
    assert_includes rows.join, "You> hello"
  ensure
    TTY::Screen.define_singleton_method(:height, original_height) if original_height
  end

  def test_prompt_interface_caps_boxed_composer_height
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new)
    value = (1..10).map { |index| "line #{index}" }.join("\n")
    prompt.instance_variable_set(:@input, value)
    prompt.instance_variable_set(:@cursor, value.length)

    rows, cursor_row, = prompt.send(:composer_layout, 80)

    assert_operator rows.length, :<=, Kward::PromptInterface::COMPOSER_MAX_INPUT_ROWS + 2
    assert_operator cursor_row, :<, rows.length - 1
    assert_includes rows.join("\n"), "line 10"
  end

  def test_prompt_interface_submits_on_csi_u_enter
    assert_equal "hello", ask_prompt_with_input("hello\e[13u")
  end

  def test_prompt_interface_csi_u_backspace_deletes_empty_line
    assert_equal "hello", ask_prompt_with_input("hello\e[13;2u\e[127u\r")
  end

  def test_prompt_interface_handles_bundled_csi_u_keys
    assert_equal "hello", ask_prompt_with_input("hello\e[13;2u\e[127u\e[13u")
  end

  def test_prompt_interface_wraps_before_terminal_width
    input, writer = IO.pipe
    output = StringIO.new
    writer.write("abcde\r")
    writer.close
    prompt = Kward::PromptInterface.new(input: input, output: output)

    prompt.instance_variable_set(:@input, "abcde")
    assert prompt.send(:input_rows, 10).all? { |row| row.length < 10 }

    original_width = TTY::Screen.method(:width)
    TTY::Screen.define_singleton_method(:width) { 10 }

    assert_equal "abcde", prompt.ask("You>")
  ensure
    TTY::Screen.define_singleton_method(:width, original_width) if original_width
    input&.close unless input&.closed?
  end

end
