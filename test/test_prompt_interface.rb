require_relative "test_helper"
require "pty"

class TestPromptInterface < KwardTestCase
  def bundled_test_banner_pixels
    Kward::PromptInterface::BANNER_LOGO_PIXELS
  end

  def test_prompt_interface_renders_empty_composer_before_typing
    output = StringIO.new
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: output)

    prompt.start

    refute_includes output.string, "You> "
  end

  def test_prompt_interface_top_border_displays_model_and_reasoning
    output = StringIO.new
    status = lambda { "Codex gpt-5.5 · medium" }
    original_width = TTY::Screen.method(:width)
    original_height = TTY::Screen.method(:height)
    TTY::Screen.define_singleton_method(:width) { 80 }
    TTY::Screen.define_singleton_method(:height) { 20 }
    prompt = Kward::PromptInterface.new(
      input: StringIO.new,
      output: output,
      composer_status: status
    )

    prompt.start

    assert_includes strip_ansi(output.string), "╭ You"
    assert_includes strip_ansi(output.string), " Codex gpt-5.5 · medium ╮"
  ensure
    TTY::Screen.define_singleton_method(:width, original_width) if original_width
    TTY::Screen.define_singleton_method(:height, original_height) if original_height
  end

  def test_prompt_interface_borders_use_primary_green
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new)
    prompt.instance_variable_set(:@color_enabled, true)
    primary_green = "\e[38;2;138;160;106m"

    assert_includes prompt.send(:top_border, 20), "#{primary_green}╭\e[0m"
    assert_includes prompt.send(:bottom_border, 20), "#{primary_green}╰──────────────────╯\e[0m"
    assert_includes prompt.send(:box_content_row, "row", 3), "#{primary_green}│\e[0m row #{primary_green}│\e[0m"
    assert_includes prompt.send(:overlay_top_border, "Menu", 20), "#{primary_green}╭\e[0m"
    assert_includes prompt.send(:overlay_bottom_border, 20), "#{primary_green}╰──────────────────╯\e[0m"
    assert_includes prompt.send(:overlay_content_row, prompt.send(:overlay_text_line, "Choice"), 6), "#{primary_green}│\e[0m Choice #{primary_green}│\e[0m"
  end

  def test_prompt_interface_top_border_symmetry_uses_single_space_padding
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, composer_status: -> { "Codex gpt-5.5 · medium" })
    line = strip_ansi(prompt.send(:top_border, 80))

    assert_equal "╭ You ───────────────────────────────────────────────── Codex gpt-5.5 · medium ╮", line
  end

  def test_prompt_interface_top_border_renders_status_at_minimum_exact_width
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, composer_status: -> { "Codex gpt-5.5 · medium" })
    line = strip_ansi(prompt.send(:top_border, 40))

    assert_equal "╭ You ───────── Codex gpt-5.5 · medium ╮", line
  end

  def test_prompt_interface_top_border_hides_status_when_no_room
    prompt = Kward::PromptInterface.new(
      input: StringIO.new,
      output: StringIO.new,
      composer_status: -> { "Codex gpt-5.5 · medium" }
    )

    line = strip_ansi(prompt.send(:top_border, 20))

    assert_equal "╭ You ─────────────╮", line
  end

  def test_prompt_interface_compact_composer_does_not_show_status
    prompt = Kward::PromptInterface.new(
      input: StringIO.new,
      output: StringIO.new,
      composer_status: -> { "Codex gpt-5.5 · medium" }
    )
    original_height = TTY::Screen.method(:height)
    original_width = TTY::Screen.method(:width)
    TTY::Screen.define_singleton_method(:height) { 3 }
    TTY::Screen.define_singleton_method(:width) { 80 }

    rows, = prompt.send(:composer_layout, 80)

    assert_equal 1, rows.length
    assert_includes rows.first, "You>"
    refute_includes rows.first, "Codex gpt-5.5"
  ensure
    TTY::Screen.define_singleton_method(:height, original_height) if original_height
    TTY::Screen.define_singleton_method(:width, original_width) if original_width
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

  def test_prompt_interface_renders_footer_line
    output = StringIO.new
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: output, footer: -> { "custom footer" })

    prompt.start

    assert_includes strip_ansi(output.string), "│ custom footer"
  end

  def test_prompt_interface_start_does_not_render_banner_in_fixed_composer
    output = StringIO.new
    prompt = Kward::PromptInterface.new(
      input: StringIO.new,
      output: output,
      banner_pixels: bundled_test_banner_pixels,
      banner_message: Kward::PromptInterface::BANNER_MESSAGE
    )

    prompt.start

    rendered = strip_ansi(output.string)
    refute_includes rendered, "State your business."
    refute_includes output.string, "\e[48;2;"
    refute_includes output.string, "\e_G"
    refute_includes output.string, "\e]1337;File="
  end

  def test_prompt_interface_prints_visual_banner_message_without_inline_image_escape
    output = StringIO.new
    prompt = Kward::PromptInterface.new(
      input: StringIO.new,
      output: output,
      banner_pixels: bundled_test_banner_pixels,
      banner_message: Kward::PromptInterface::BANNER_MESSAGE
    )

    prompt.start
    prompt.print_visual_banner

    rendered = strip_ansi(output.string)
    assert_includes rendered, "State your business."
    refute_includes output.string, "\e_G"
    refute_includes output.string, "\e]1337;File="
  end

  def test_prompt_interface_visual_banner_is_not_replayed_on_redraw
    output = StringIO.new
    prompt = Kward::PromptInterface.new(
      input: StringIO.new,
      output: output,
      banner_pixels: bundled_test_banner_pixels,
      banner_message: Kward::PromptInterface::BANNER_MESSAGE
    )

    prompt.start
    prompt.print_visual_banner
    output.truncate(0)
    output.rewind

    prompt.redraw

    refute_includes strip_ansi(output.string), "State your business."
    refute_includes output.string, "\e[48;2;"
  end

  def test_prompt_interface_renders_banner_from_pixel_data_without_decoding_png
    output = StringIO.new
    original_decoder = Kward::PixelLogo.method(:indexed_png_pixels)
    Kward::PixelLogo.define_singleton_method(:indexed_png_pixels) { |_path| raise "PNG decoder should not be used" }
    prompt = Kward::PromptInterface.new(
      input: StringIO.new,
      output: output,
      banner_pixels: bundled_test_banner_pixels,
      banner_message: Kward::PromptInterface::BANNER_MESSAGE
    )

    prompt.start
    prompt.print_visual_banner

    assert_includes output.string, "\e[48;2;"
    assert_includes output.string, "\e[38;2;"
    assert_includes strip_ansi(output.string), "▀"
    refute_includes output.string, "\e_G"
    refute_includes output.string, "\e]1337;File="
  ensure
    Kward::PixelLogo.define_singleton_method(:indexed_png_pixels, original_decoder) if original_decoder
  end

  def test_prompt_interface_renders_centered_visual_banner_as_half_block_pixels_at_full_size
    output = StringIO.new
    original_width = TTY::Screen.method(:width)
    original_height = TTY::Screen.method(:height)
    TTY::Screen.define_singleton_method(:width) { 80 }
    TTY::Screen.define_singleton_method(:height) { 30 }
    prompt = Kward::PromptInterface.new(
      input: StringIO.new,
      output: output,
      banner_pixels: bundled_test_banner_pixels,
      banner_message: Kward::PromptInterface::BANNER_MESSAGE
    )

    prompt.start
    prompt.print_visual_banner

    color_index = output.string.index("\e[48;2;")
    assert color_index
    logo_row = strip_ansi(prompt.send(:banner_rows, 80).find { |row| row.include?("\e[48;2;") })
    assert_equal 56, logo_row.length
    assert_equal 16, prompt.send(:banner_logo_rows).length
    assert_includes output.string, "\e[38;2;"
    assert_includes strip_ansi(output.string), "▀"
    refute_includes output.string, "\e_G"
    refute_includes output.string, "\e]1337;File="
    assert_includes strip_ansi(output.string), "                              State your business."
    assert_operator output.string.rindex(TTY::Cursor.clear_line), :<, color_index
  ensure
    TTY::Screen.define_singleton_method(:width, original_width) if original_width
    TTY::Screen.define_singleton_method(:height, original_height) if original_height
  end

  def test_prompt_interface_scales_visual_banner_down_on_short_terminals
    output = StringIO.new
    original_width = TTY::Screen.method(:width)
    original_height = TTY::Screen.method(:height)
    TTY::Screen.define_singleton_method(:width) { 100 }
    TTY::Screen.define_singleton_method(:height) { 17 }
    prompt = Kward::PromptInterface.new(
      input: StringIO.new,
      output: output,
      banner_pixels: bundled_test_banner_pixels,
      banner_message: Kward::PromptInterface::BANNER_MESSAGE
    )

    prompt.start
    prompt.print_visual_banner

    color_index = output.string.index("\e[48;2;")
    assert color_index
    logo_row = strip_ansi(prompt.send(:banner_rows, 100).find { |row| row.include?("\e[48;2;") })
    assert_equal 66, logo_row.length
    assert_equal 11, prompt.send(:banner_logo_rows).length
    assert_includes strip_ansi(output.string), "                                        State your business."
  ensure
    TTY::Screen.define_singleton_method(:width, original_width) if original_width
    TTY::Screen.define_singleton_method(:height, original_height) if original_height
  end

  def test_prompt_interface_hides_banner_logo_when_terminal_is_too_short
    original_height = TTY::Screen.method(:height)
    TTY::Screen.define_singleton_method(:height) { 9 }
    prompt = Kward::PromptInterface.new(
      input: StringIO.new,
      output: StringIO.new,
      banner_pixels: bundled_test_banner_pixels,
      banner_message: Kward::PromptInterface::BANNER_MESSAGE
    )

    rows = prompt.send(:banner_rows, 80)

    assert rows.any? { |row| row.include?("State your business.") }
    refute rows.any? { |row| row.include?("\e[48;2;") }
  ensure
    TTY::Screen.define_singleton_method(:height, original_height) if original_height
  end

  def test_prompt_interface_refreshes_footer_while_idle
    input, writer = IO.pipe
    output = StringIO.new
    value = "first"
    prompt = Kward::PromptInterface.new(input: input, output: output, footer: -> { value })
    prompt.start
    value = "second"
    prompt.instance_variable_set(:@last_footer_refresh, prompt.send(:monotonic_now) - Kward::PromptInterface::FOOTER_REFRESH_INTERVAL)
    output.truncate(0)
    output.rewind

    prompt.poll_input

    assert_includes strip_ansi(output.string), "│ second"
  ensure
    writer&.close unless writer&.closed?
    input&.close unless input&.closed?
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

    stripped = strip_ansi(output.string)
    assert_equal [{ question: "Proceed?", answer: "No", custom: false }], answers
    assert_includes stripped, "╭ Question 1/1 · Confirm"
    assert_includes stripped, "│ Proceed?"
    assert_includes stripped, "› No — Stop."
    assert_includes stripped, "╰"
    assert_includes output.string, "\e[?25l"
    assert_includes output.string, "\e[?25h"
  ensure
    input&.close unless input&.closed?
  end

  def test_prompt_interface_ask_user_question_accepts_custom_answer
    input, writer = IO.pipe
    output = StringIO.new
    writer.write("maybe\r")
    writer.close
    prompt = Kward::PromptInterface.new(input: input, output: output)
    original_width = TTY::Screen.method(:width)
    original_height = TTY::Screen.method(:height)
    TTY::Screen.define_singleton_method(:width) { 80 }
    TTY::Screen.define_singleton_method(:height) { 20 }

    answers = prompt.ask_user_question([question_args("Proceed?")])

    stripped = strip_ansi(output.string)
    assert_equal [{ question: "Proceed?", answer: "maybe", custom: true }], answers
    assert_includes stripped, "Type something: maybe"
    assert_includes stripped, "╭ Answer"
    refute_includes stripped, "│ maybe"
    assert_includes output.string, "\e[?25l"
    assert_includes output.string, "\e[?25h"
    assert_includes output.string, "\e[16;28H"
  ensure
    TTY::Screen.define_singleton_method(:width, original_width) if original_width
    TTY::Screen.define_singleton_method(:height, original_height) if original_height
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

  def test_prompt_interface_ctrl_d_deletes_character_right_when_text_remains
    assert_equal "ac", ask_prompt_with_input("abc\x01\x06\x04\r")
    assert_equal "ac", ask_prompt_with_input("abc\e[H\e[C\e[3~\r")
  end

  def test_prompt_interface_handles_shell_style_line_movement_keys
    assert_equal "ZabX", ask_prompt_with_input("ab\x01Z\x05X\r")
    assert_equal "ZabX", ask_prompt_with_input("ab\e[HZ\e[FX\r")
  end

  def test_prompt_interface_handles_shell_style_character_movement_keys
    assert_equal "aZbX", ask_prompt_with_input("ab\x02Z\x06X\r")
    assert_equal "aZbX", ask_prompt_with_input("ab\e[DZ\e[CX\r")
  end

  def test_prompt_interface_handles_shell_style_word_movement_keys
    assert_equal "one two ZthreeX", ask_prompt_with_input("one two three\ebZ\efX\r")
    assert_equal "one two ZthreeX", ask_prompt_with_input("one two three\e[1;3DZ\e[1;3CX\r")
  end

  def test_prompt_interface_handles_shell_style_word_delete_keys
    assert_equal "one two ", ask_prompt_with_input("one two three\x17\r")
    assert_equal "one ", ask_prompt_with_input("one two\e\x7F\r")
    assert_equal " two three", ask_prompt_with_input("one two three\x01\ed\r")
  end

  def test_prompt_interface_yanks_last_kill
    assert_equal "hello world", ask_prompt_with_input("hello world\x15\x19\r")
    assert_equal "hello world", ask_prompt_with_input("hello world\x01\x0B\x19\r")
    assert_equal "one -two", ask_prompt_with_input("one two\x17-\x19\r")
  end

  def test_prompt_interface_ctrl_l_redraws_without_changing_input
    input, writer = IO.pipe
    output = StringIO.new
    writer.write("hello\x0C\r")
    writer.close
    prompt = Kward::PromptInterface.new(input: input, output: output)

    assert_equal "hello", prompt.ask("You>")
    assert_includes output.string, TTY::Cursor.clear_screen
  ensure
    input&.close unless input&.closed?
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
    stripped = strip_ansi(output.string)
    assert_includes stripped, "╭ Slash commands"
    assert_includes stripped, "› /plan <task>"
    assert_includes stripped, "╰"
  ensure
    input&.close unless input&.closed?
  end

  def test_prompt_interface_slash_overlay_keeps_composer_visible_on_short_screens
    prompt = Kward::PromptInterface.new(
      input: StringIO.new,
      output: StringIO.new,
      slash_commands: (1..14).map { |index| { name: "cmd#{index}", description: "Command #{index}.", argument_hint: "" } }
    )
    prompt.instance_variable_set(:@input, "/")
    prompt.instance_variable_set(:@cursor, 1)
    original_width = TTY::Screen.method(:width)
    original_height = TTY::Screen.method(:height)
    TTY::Screen.define_singleton_method(:width) { 80 }
    TTY::Screen.define_singleton_method(:height) { 12 }

    rows, = prompt.send(:composer_layout, 80)

    assert_operator rows.length, :<=, 11
    assert_includes strip_ansi(rows.join("\n")), "╭ You"
  ensure
    TTY::Screen.define_singleton_method(:width, original_width) if original_width
    TTY::Screen.define_singleton_method(:height, original_height) if original_height
  end

  def test_prompt_interface_selected_overlay_items_keep_color_after_navigation
    input, writer = IO.pipe
    output = StringIO.new
    writer.write("/\e[B\r")
    writer.close
    prompt = Kward::PromptInterface.new(
      input: input,
      output: output,
      slash_commands: [
        { name: "alpha", description: "First command.", argument_hint: "" },
        { name: "beta", description: "Second command.", argument_hint: "" }
      ]
    )
    prompt.instance_variable_set(:@color_enabled, true)

    assert_equal "/", prompt.ask("You>")

    assert_includes output.string, "\e[38;2;155;255;0;1mSlash commands\e[0m"
    assert_includes output.string, "\e[38;2;155;255;0;1m› /alpha — First command.\e[0m"
    assert_includes output.string, "\e[38;2;155;255;0;1m› /beta — Second command.\e[0m"
  ensure
    input&.close unless input&.closed?
  end

  def test_prompt_interface_truncated_selected_overlay_item_keeps_color
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new)
    prompt.instance_variable_set(:@color_enabled, true)

    row = prompt.send(:overlay_content_row, prompt.send(:overlay_choice_line, "A very long selected overlay item that must be truncated", selected: true), 18)

    assert_match(/\e\[38;2;155;255;0;1m› A very long sele\e\[0m/, row)
  end

  def test_prompt_interface_aligns_overlay_left_and_right
    left_prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, overlay_settings: { "alignment" => "left" })
    right_prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, overlay_settings: { "alignment" => "right" })

    left_row = left_prompt.send(:overlay_card_rows, "Menu", [left_prompt.send(:overlay_text_line, "Choice")], 40).first
    right_row = right_prompt.send(:overlay_card_rows, "Menu", [right_prompt.send(:overlay_text_line, "Choice")], 40).first

    assert_equal "╭", strip_ansi(left_row)[0]
    assert_equal " " * 4, strip_ansi(right_row)[0, 4]
    assert_equal "╭", strip_ansi(right_row)[4]
  end

  def test_prompt_interface_maximum_overlay_width_matches_composer_width
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, overlay_settings: { "width" => "maximum" })

    assert_equal 120, prompt.send(:overlay_card_width, 120)
  end

  def test_prompt_interface_question_cursor_uses_overlay_alignment
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, overlay_settings: { "alignment" => "right" })
    prompt.instance_variable_set(:@question_state, {
      question: "Proceed?",
      header: "Confirm",
      options: [{ label: "Yes", description: "Continue." }],
      selection_index: 1,
      index: 1,
      total: 1
    })
    prompt.instance_variable_set(:@input, "maybe")
    prompt.instance_variable_set(:@cursor, 5)

    assert_equal 49, prompt.send(:question_custom_cursor_col, 120)
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

  def test_prompt_interface_renders_braille_spinner_while_busy
    output = StringIO.new
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: output)

    prompt.begin_busy_input("You>")

    assert_includes output.string, "╭ You · ⠋ streaming "
  end

  def test_prompt_interface_advances_braille_spinner_while_busy
    input, writer = IO.pipe
    output = StringIO.new
    prompt = Kward::PromptInterface.new(input: input, output: output)
    prompt.begin_busy_input("You>")
    prompt.instance_variable_set(:@last_spinner_tick, prompt.send(:monotonic_now) - Kward::PromptInterface::SPINNER_INTERVAL)
    output.truncate(0)
    output.rewind

    prompt.poll_input

    assert_match(/╭ You · [⠙⠹⠸⠼⠴⠦⠧⠇⠏] streaming /, output.string)
  ensure
    writer&.close unless writer&.closed?
    input&.close unless input&.closed?
  end

  def test_prompt_interface_hides_spinner_when_input_is_queued
    output = StringIO.new
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: output)
    prompt.begin_busy_input("You>")
    output.truncate(0)
    output.rewind

    prompt.set_queued_count(1)

    assert_includes output.string, "╭ You · 1 queued "
    refute_includes output.string, "streaming"
  end

  def test_prompt_interface_keeps_terminal_backspace_between_busy_polls
    PTY.open do |master, slave|
      output = StringIO.new
      prompt = Kward::PromptInterface.new(input: slave, output: output)
      prompt.begin_busy_input("You>")
      master.write("abcdef")
      6.times { prompt.poll_input }
      assert_equal "abcdef", prompt.instance_variable_get(:@input)

      master.write("\x7F" * 3)
      sleep 0.05
      3.times { prompt.poll_input }

      assert_equal "abc", prompt.instance_variable_get(:@input)
    ensure
      prompt&.close
    end
  end

  def test_prompt_interface_restores_terminal_mode_on_close
    PTY.open do |master, slave|
      output = StringIO.new
      prompt = Kward::PromptInterface.new(input: slave, output: output)
      prompt.start
      prompt.close

      master.write("\x7F")
      sleep 0.05

      refute slave.wait_readable(0.05)
    end
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

    assert_includes output.string, "Kward>"
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

  def test_prompt_interface_separates_say_output_from_next_stream_block
    output = StringIO.new
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: output)
    prompt.start
    output.truncate(0)
    output.rewind

    prompt.say("\nYou> abcdefg\ndasdsadas\n")
    prompt.start_stream_block("Tool")
    prompt.write_delta("abcde\n")
    prompt.finish_stream_block

    stripped = strip_ansi(output.string)
    assert_includes stripped, "dasdsadas\r\n"
    assert_includes stripped, "\r\nTool>\r\nabcde"
    refute_includes stripped, "╯Tool>"
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
