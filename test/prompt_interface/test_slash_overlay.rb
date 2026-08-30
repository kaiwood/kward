require_relative "../test_helper"

class TestPromptInterfaceSlashOverlay < KwardTestCase
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

  def test_prompt_interface_updates_slash_overlay_commands
    prompt = Kward::PromptInterface.new(
      input: StringIO.new,
      output: StringIO.new,
      slash_commands: [{ name: "plan", description: "Plan work.", argument_hint: "<task>" }]
    )
    prompt.send(:composer_input=, "/usage")

    refute prompt.send(:slash_overlay_visible?)

    prompt.update_slash_commands([{ name: "usage", description: "Show usage.", argument_hint: "" }])

    assert prompt.send(:slash_overlay_visible?)
    assert_equal "usage", prompt.send(:selected_slash_command)[:name]
  end

  def test_prompt_interface_caches_and_caps_case_insensitive_slash_matches
    commands = 12.times.map { |index| { name: "Command#{index}", description: "Command #{index}." } }
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, slash_commands: commands)
    prompt.send(:composer_input=, "/command")

    matches = prompt.send(:slash_overlay_matches)

    assert_equal 8, matches.length
    assert_same matches, prompt.send(:slash_overlay_matches)
  end

  def test_prompt_interface_can_disable_slash_overlay_for_completion_provider
    input, writer = IO.pipe
    output = StringIO.new
    writer.write("/\r")
    writer.close
    prompt = Kward::PromptInterface.new(
      input: input,
      output: output,
      slash_commands: [{ name: "plan", description: "Plan work.", argument_hint: "<task>" }]
    )

    result = prompt.with_completion_provider(->(_value, _cursor) { nil }, slash_overlay: false) do
      prompt.ask("Shell $")
    end

    assert_equal "/", result
    refute_includes strip_ansi(output.string), "Slash commands"
  ensure
    input&.close unless input&.closed?
  end

  def test_prompt_interface_csi_u_tab_completes_slash_selection
    prompt = Kward::PromptInterface.new(
      input: StringIO.new,
      output: StringIO.new,
      slash_commands: [{ name: "plan", description: "Plan work.", argument_hint: "<task>" }]
    )

    prompt.send(:handle_key, "/")

    assert_equal true, prompt.send(:handle_key, "\e[9;1;9u")
    assert_equal "/plan ", prompt.send(:composer_input)
  end

  def test_prompt_interface_escape_closes_slash_overlay_and_keeps_prompt_active
    input, writer = IO.pipe
    output = StringIO.new
    writer.write("/\e\t done\r")
    writer.close
    prompt = Kward::PromptInterface.new(
      input: input,
      output: output,
      slash_commands: [{ name: "plan", description: "Plan work.", argument_hint: "<task>" }]
    )

    assert_equal "/ done", prompt.ask("You>")
  ensure
    input&.close unless input&.closed?
  end

  def test_prompt_interface_slash_overlay_keeps_composer_visible_on_short_screens
    prompt = Kward::PromptInterface.new(
      input: StringIO.new,
      output: StringIO.new,
      slash_commands: (1..14).map { |index| { name: "cmd#{index}", description: "Command #{index}.", argument_hint: "" } }
    )
    prompt.send(:composer_input=, "/")
    prompt.send(:composer_cursor=, 1)
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

  def test_prompt_interface_closing_slash_overlay_does_not_blank_composer_rows_before_repaint
    output = StringIO.new
    original_width = TTY::Screen.method(:width)
    original_height = TTY::Screen.method(:height)
    TTY::Screen.define_singleton_method(:width) { 80 }
    TTY::Screen.define_singleton_method(:height) { 20 }
    prompt = Kward::PromptInterface.new(
      input: StringIO.new,
      output: output,
      slash_commands: [{ name: "plan", description: "Plan work.", argument_hint: "" }]
    )
    prompt.start
    prompt.send(:composer_input=, "/")
    prompt.send(:composer_cursor=, 1)
    prompt.send(:render_prompt_locked)
    output.truncate(0)
    output.rewind

    prompt.send(:dismiss_slash_overlay)
    prompt.send(:render_prompt_locked)

    composer_top = 18
    composer_bottom = 20
    composer_top.upto(composer_bottom - 1) do |row|
      refute_includes output.string, "\e[#{row};1H#{TTY::Cursor.clear_line}\e[#{row + 1};1H"
    end
    assert_includes strip_ansi(output.string), "╭ You"
    assert_includes strip_ansi(output.string), "│ /"
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

    assert_includes output.string, "\e[38;2;138;160;106;1mSlash commands\e[0m"
    assert_includes output.string, "\e[38;2;138;160;106;1m› /alpha — First command.\e[0m"
    assert_includes output.string, "\e[38;2;138;160;106;1m› /beta — Second command.\e[0m"
  ensure
    input&.close unless input&.closed?
  end

  def test_prompt_interface_truncated_selected_overlay_item_keeps_color
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs")
    prompt.instance_variable_set(:@color_enabled, true)

    row = prompt.send(:overlay_content_row, prompt.send(:overlay_choice_line, "A very long selected overlay item that must be truncated", selected: true), 18)

    assert_match(/\e\[38;2;138;160;106;1m› A very long sele\e\[0m/, row)
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

end
