require_relative "test_helper"
require "pty"

class TestPromptInterface < KwardTestCase
  def test_prompt_interface_completion_provider_handles_plain_tab
    input, writer = IO.pipe
    output = StringIO.new
    writer.write("pw\t\n")
    writer.close
    prompt = Kward::PromptInterface.new(input: input, output: output)
    shell = Kward::Ekwsh.new(cwd: Dir.pwd, shell: "/bin/sh", env: { "PATH" => "" })

    result = prompt.with_completion_provider(->(value, cursor) { shell.complete(value, cursor) }) do
      prompt.ask("Shell $")
    end

    assert_equal "pwd ", result
  ensure
    input&.close unless input&.closed?
  end

  def test_prompt_interface_normalizes_csi_u_key_events
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new)

    enter = prompt.send(:csi_u_key_event, prompt.send(:parse_csi_u_key, "\e[13u"))
    printable = prompt.send(:csi_u_key_event, prompt.send(:parse_csi_u_key, "\e[97;2;65u"))
    modified = prompt.send(:csi_u_key_event, prompt.send(:parse_csi_u_key, "\e[102;5u"))

    assert_equal({ type: :enter, modifier: 1 }, enter)
    assert_equal({ type: :printable, text: "A", modifier: 2 }, printable)
    assert_equal({ type: :modified, code: 102, modifier: 5 }, modified)
  end

  def test_busy_ctrl_c_returns_cancel_input
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs")
    prompt.instance_variable_set(:@busy, true)

    assert_equal Kward::PromptInterface::CANCEL_INPUT, prompt.send(:handle_key, "\x03")
  end

  def test_busy_csi_u_ctrl_c_returns_cancel_input
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs")
    prompt.instance_variable_set(:@busy, true)

    assert_equal Kward::PromptInterface::CANCEL_INPUT, prompt.send(:handle_key, "\e[99;5u")
  end

  def test_non_busy_ctrl_c_does_not_interrupt
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs")

    assert_equal true, prompt.send(:handle_key, "\x03")
  end

  def test_non_busy_csi_u_ctrl_c_does_not_interrupt
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs")

    assert_equal true, prompt.send(:handle_key, "\e[99;5u")
  end

  def test_prompt_interface_ignores_mouse_reporting_sequences_in_composer
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new)

    assert_equal true, prompt.send(:handle_key, "\e[<34;95;55M")
    assert_equal "", prompt.send(:composer_input)
  end

  def test_prompt_interface_ignores_mouse_reporting_sequence_bodies_in_composer
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new)

    assert_equal true, prompt.send(:handle_key, "[<34;95;55M")
    assert_equal "", prompt.send(:composer_input)
  end

  def test_prompt_interface_requeues_keys_after_mouse_reporting_sequence
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new)

    assert_equal true, prompt.send(:handle_key, "\e[<34;95;55Mx")
    prompt.send(:handle_key, prompt.instance_variable_get(:@pending_keys).shift)

    assert_equal "x", prompt.send(:composer_input)
  end

  def test_prompt_interface_start_forces_mouse_reporting_off_outside_editor
    output = StringIO.new
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: output)

    prompt.start

    assert_includes output.string, "\e[?1006l\e[?1003l"
  end

  def test_prompt_interface_renders_empty_composer_before_typing
    output = StringIO.new
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: output)

    prompt.start

    refute_includes output.string, "You> "
  end

  def test_prompt_interface_does_not_synchronize_routine_composer_render
    output = StringIO.new
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: output)
    prompt.start
    output.truncate(0)
    output.rewind

    prompt.send(:insert_string, "a")
    prompt.send(:render_prompt_locked)

    refute_includes output.string, Kward::PromptInterface::SYNCHRONIZED_OUTPUT_ENABLE
    refute_includes output.string, Kward::PromptInterface::SYNCHRONIZED_OUTPUT_DISABLE
  end

  def test_prompt_interface_throttles_composer_status_during_typing
    count = 0
    output = StringIO.new
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: output, composer_status: -> { count += 1; "status #{count}" })
    prompt.start

    10.times do
      prompt.send(:handle_key, "a")
      prompt.send(:render_prompt_locked)
    end

    assert_equal 1, count
    assert_includes strip_ansi(output.string), "status 1"
    refute_includes strip_ansi(output.string), "status 2"
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
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs")
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

    assert_includes strip_ansi(output.string), "╭ You "
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

  def test_prompt_interface_renders_connected_tab_bar
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs")
    prompt.update_tabs(labels: %w[Main Tab Tab], active_index: 1)

    rows, = prompt.send(:composer_layout, 80)
    rendered_rows = rows.last(3).map { |row| strip_ansi(row) }

    assert_match(/\A╰─+╮ +╭─+╯\z/, rendered_rows[0])
    assert_match(/1 Main +│ 2 Tab │ +3 Tab/, rendered_rows[1])
    assert_match(/\A +╰─+╯ +\z/, rendered_rows[2])
    refute_includes rendered_rows.join("\n"), "[2]"
  end

  def test_prompt_interface_does_not_render_unchanged_tabs
    output = StringIO.new
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: output)
    prompt.start
    prompt.update_tabs(labels: [{ name: "Main", color: :yellow }], active_index: 0)
    output.truncate(0)
    output.rewind

    refute prompt.update_tabs(labels: [{ name: "Main", color: :yellow }], active_index: 0)
    assert_empty output.string
  end

  def test_prompt_interface_renders_connected_tab_bar_for_first_tab
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs")
    prompt.update_tabs(labels: %w[Main Tab Tab], active_index: 0)

    rows, = prompt.send(:composer_layout, 80)
    rendered_rows = rows.last(3).map { |row| strip_ansi(row) }

    assert_match(/\A╰─+╮ +╭─+╯\z/, rendered_rows[0])
    assert_match(/│ 1 Main │ +2 Tab +3 Tab/, rendered_rows[1])
    assert_match(/\A +╰─+╯ +\z/, rendered_rows[2])
  end

  def test_prompt_interface_keeps_tab_labels_stable_when_switching_tabs
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs")
    prompt.update_tabs(labels: %w[Main Tab Tab], active_index: 0)
    rows, = prompt.send(:composer_layout, 80)
    first_tab_row = strip_ansi(rows.last(2).first)

    prompt.update_tabs(labels: %w[Main Tab Tab], active_index: 1)
    rows, = prompt.send(:composer_layout, 80)
    second_tab_row = strip_ansi(rows.last(2).first)

    assert_equal first_tab_row.index("1 Main"), second_tab_row.index("1 Main")
    assert_equal first_tab_row.index("2 Tab"), second_tab_row.index("2 Tab")
    assert_equal first_tab_row.index("3 Tab"), second_tab_row.index("3 Tab")
  end

  def test_prompt_interface_preserves_tab_borders_in_narrow_width
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs")
    prompt.update_tabs(labels: %w[1 2 3], active_index: 1)

    rows, = prompt.send(:composer_layout, 12)
    rendered_rows = rows.map { |row| strip_ansi(row) }

    assert_equal 3, rendered_rows.length
    assert_equal 12, rendered_rows.last.length
    assert_includes rendered_rows.last, "╰"
    assert_includes rendered_rows.last, "╯"
  end

  def test_prompt_interface_colorizes_only_tab_names
    output = StringIO.new
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: output)
    prompt.instance_variable_set(:@color_enabled, true)
    prompt.update_tabs(labels: [{ name: "Main", color: :yellow }, { name: "Ops", color: :red }, { name: "Done", color: :green }], active_index: 0)

    rows, = prompt.send(:composer_layout, 80)
    tab_row = rows.last(2).first

    assert_includes tab_row, "1 \e[33mMain\e[0m"
    assert_includes tab_row, "2 \e[31mOps\e[0m"
    assert_includes tab_row, "3 \e[32mDone\e[0m"
    refute_includes tab_row, "\e[33m1"
    assert_match(/1 Main.*2 Ops.*3 Done/, strip_ansi(tab_row))
  end

  def test_prompt_interface_tab_cycles_reasoning_in_normal_prompt
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new)

    assert_equal({ reasoning_action: :next }, prompt.send(:handle_key, "\t"))
  end

  def test_prompt_interface_shift_tab_cycles_reasoning_backwards_in_normal_prompt
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new)

    assert_equal({ reasoning_action: :previous }, prompt.send(:handle_key, "\e[Z"))
    assert_equal({ reasoning_action: :previous }, prompt.send(:handle_key, "\e[9;2u"))
  end

  def test_prompt_interface_tab_keeps_slash_completion_when_overlay_visible
    prompt = Kward::PromptInterface.new(
      input: StringIO.new,
      output: StringIO.new,
      slash_commands: [{ name: "help", description: "Show help" }]
    )
    prompt.send(:composer_input=, "/he")
    prompt.send(:composer_cursor=, 3)

    assert_equal true, prompt.send(:handle_key, "\t")
    assert_equal "/help ", prompt.send(:composer_input)
  end

  def test_prompt_interface_tab_keeps_file_completion_when_overlay_visible
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new)
    prompt.send(:composer_input=, "read @CHANGELOG.m")
    prompt.send(:composer_cursor=, "read @CHANGELOG.m".length)

    assert_equal true, prompt.send(:handle_key, "\t")
    assert_equal "read @CHANGELOG.md", prompt.send(:composer_input)
  end

  def test_prompt_interface_tab_does_not_cycle_reasoning_when_busy
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new)
    prompt.instance_variable_set(:@busy, true)

    assert_nil prompt.send(:handle_key, "\t")
    assert_equal "", prompt.send(:composer_input)
  end

  def test_prompt_interface_alt_tab_keybindings_return_tab_actions
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, tab_keybindings: "alt")
    prompt.update_tabs(labels: ["1"], active_index: 0)

    assert_equal({ tab_action: :new }, prompt.send(:handle_key, "\et"))
    assert_equal({ tab_action: :next }, prompt.send(:handle_key, "\e[1;3C"))
    assert_equal({ tab_action: :previous }, prompt.send(:handle_key, "\e[1;3D"))
    assert_equal({ tab_action: :select, index: 2 }, prompt.send(:handle_key, "\e3"))
  end

  def test_prompt_interface_ctrl_tab_navigation_works_with_alt_tab_keybindings
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, tab_keybindings: "alt")
    prompt.update_tabs(labels: ["1"], active_index: 0)

    assert_equal({ tab_action: :next }, prompt.send(:handle_key, "\e[9;5u"))
    assert_equal({ tab_action: :next }, prompt.send(:handle_key, "\e[27;5;9~"))
    assert_equal({ tab_action: :next }, prompt.send(:handle_key, "\e[1;5I"))
    assert_equal({ tab_action: :next }, prompt.send(:handle_key, "\e[9;5;9u"))
    assert_equal({ tab_action: :previous }, prompt.send(:handle_key, "\e[9;6u"))
    assert_equal({ tab_action: :previous }, prompt.send(:handle_key, "\e[27;6;9~"))
    assert_equal({ tab_action: :previous }, prompt.send(:handle_key, "\e[1;6I"))
    assert_equal({ tab_action: :previous }, prompt.send(:handle_key, "\e[9;6;9u"))
    assert_equal({ tab_action: :previous }, prompt.send(:handle_key, "\e[1;6Z"))
  end

  def test_prompt_interface_alt_w_does_not_close_tab
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, tab_keybindings: "alt")
    prompt.update_tabs(labels: ["1", "2"], active_index: 0)
    prompt.send(:composer_input=, "hello world")
    prompt.send(:composer_cursor=, "hello world".length)

    assert_nil prompt.send(:handle_key, "\ew")
    assert_equal "hello world", prompt.send(:composer_input)
  end

  def test_prompt_interface_alt_backspace_deletes_previous_word_with_tabs
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, tab_keybindings: "alt")
    prompt.update_tabs(labels: ["1", "2"], active_index: 0)
    prompt.send(:composer_input=, "hello world")
    prompt.send(:composer_cursor=, "hello world".length)

    assert_equal true, prompt.send(:handle_key, "\e\x7F")
    assert_equal "hello ", prompt.send(:composer_input)
  end

  def test_prompt_interface_ctrl_w_deletes_previous_word_with_tabs
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, tab_keybindings: "ctrl")
    prompt.update_tabs(labels: ["1", "2"], active_index: 0)
    prompt.send(:composer_input=, "hello world")
    prompt.send(:composer_cursor=, "hello world".length)

    assert_equal true, prompt.send(:handle_key, "\x17")
    assert_equal "hello ", prompt.send(:composer_input)
  end

  def test_prompt_interface_ctrl_tab_keybindings_return_tab_actions
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, tab_keybindings: "ctrl")
    prompt.update_tabs(labels: ["1"], active_index: 0)

    assert_equal({ tab_action: :new }, prompt.send(:handle_key, "\x14"))
    assert_equal({ tab_action: :close }, prompt.send(:handle_key, "\e[119;5u"))
    assert_equal({ tab_action: :next }, prompt.send(:handle_key, "\e[9;5u"))
    assert_equal({ tab_action: :previous }, prompt.send(:handle_key, "\e[9;6u"))
    assert_equal({ tab_action: :select, index: 2 }, prompt.send(:handle_key, "\e[51;5u"))
  end

  def test_prompt_interface_renders_attachment_badge_rows
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, attachment_badges: ->(_input) { ["[image] screenshot.png · image/png · 12 KB"] })
    prompt.send(:composer_input=, "describe screenshot.png")
    prompt.send(:composer_cursor=, "describe screenshot.png".length)

    rows, cursor_row, = prompt.send(:composer_layout, 80)
    rendered = strip_ansi(rows.join("\n"))

    assert_includes rendered, "[image] screenshot.png · image/png · 12 KB"
    assert_equal 2, cursor_row
  end

  def test_prompt_interface_caps_input_height_with_attachment_badges
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, attachment_badges: ->(_input) { ["[image] one.png", "[image] two.png"] })
    value = (1..10).map { |index| "line #{index}" }.join("\n")
    prompt.send(:composer_input=, value)
    prompt.send(:composer_cursor=, value.length)

    rows, cursor_row, = prompt.send(:composer_layout, 80)

    assert_operator rows.length, :<=, Kward::PromptInterface::COMPOSER_MAX_INPUT_ROWS + 2
    assert_operator cursor_row, :<, rows.length - 1
    assert_includes rows.join("\n"), "[image] one.png"
    assert_includes rows.join("\n"), "line 10"
  end

  def test_prompt_interface_start_does_not_render_banner_in_fixed_composer
    output = StringIO.new
    prompt = Kward::PromptInterface.new(
      input: StringIO.new,
      output: output,
      banner_message: Kward::PromptInterface::BANNER_MESSAGE
    )

    prompt.start

    rendered = strip_ansi(output.string)
    refute_includes rendered, "State your business."
    refute_includes output.string, "\e_G"
    refute_includes output.string, "\e]1337;File="
  end

  def test_prompt_interface_prints_visual_banner_message_without_inline_image_escape
    output = StringIO.new
    prompt = Kward::PromptInterface.new(
      input: StringIO.new,
      output: output,
      banner_message: Kward::PromptInterface::BANNER_MESSAGE
    )

    prompt.start
    prompt.print_visual_banner

    rendered = strip_ansi(output.string)
    assert_includes rendered, "State your business."
    refute_includes output.string, "\e_G"
    refute_includes output.string, "\e]1337;File="
  end

  def test_prompt_interface_startup_info_screen_is_replayed_on_redraw
    output = StringIO.new
    prompt = Kward::PromptInterface.new(
      input: StringIO.new,
      output: output,
      banner_message: Kward::PromptInterface::BANNER_MESSAGE
    )

    prompt.start
    prompt.print_visual_banner("Kward is online.\n\nWorkspace   kaiwood/kward\nBranch      main\nPlugins     alpha.rb, beta.rb\n\nState your business.")
    output.truncate(0)
    output.rewind

    prompt.redraw

    rendered = strip_ansi(output.string)
    assert_includes rendered, "Kward is online."
    assert_includes rendered, "Workspace   kaiwood/kward"
    assert_includes rendered, "Branch      main"
    assert_includes rendered, "Plugins     alpha.rb, beta.rb"
    assert_order rendered, "Kward is online.", "Workspace   kaiwood/kward", "Plugins     alpha.rb, beta.rb", "State your business."
  end

  def test_prompt_interface_does_not_repaint_startup_info_screen_when_overlay_grows_composer
    output = StringIO.new
    original_width = TTY::Screen.method(:width)
    original_height = TTY::Screen.method(:height)
    TTY::Screen.define_singleton_method(:width) { 80 }
    TTY::Screen.define_singleton_method(:height) { 30 }
    prompt = Kward::PromptInterface.new(
      input: StringIO.new,
      output: output,
      slash_commands: (1..8).map { |index| { name: "cmd#{index}", description: "Command #{index}.", argument_hint: "" } },
      banner_message: Kward::PromptInterface::BANNER_MESSAGE
    )

    prompt.start
    prompt.print_visual_banner("Kward is online.\n\nWorkspace   kaiwood/kward\nBranch      main\nPlugins     alpha.rb, beta.rb\n\nState your business.")
    output.truncate(0)
    output.rewind

    prompt.send(:composer_input=, "/")
    prompt.send(:composer_cursor=, 1)
    prompt.send(:render_prompt_locked)

    rendered = strip_ansi(output.string)
    refute_includes rendered, "Kward is online."
    refute_includes rendered, "State your business."
    refute_includes output.string, TTY::Cursor.clear_screen
  ensure
    TTY::Screen.define_singleton_method(:width, original_width) if original_width
    TTY::Screen.define_singleton_method(:height, original_height) if original_height
  end

  def test_prompt_interface_restores_startup_info_screen_after_overlay_resizes_composer
    output = StringIO.new
    original_width = TTY::Screen.method(:width)
    original_height = TTY::Screen.method(:height)
    TTY::Screen.define_singleton_method(:width) { 80 }
    TTY::Screen.define_singleton_method(:height) { 30 }
    prompt = Kward::PromptInterface.new(
      input: StringIO.new,
      output: output,
      slash_commands: (1..8).map { |index| { name: "cmd#{index}", description: "Command #{index}.", argument_hint: "" } },
      banner_message: Kward::PromptInterface::BANNER_MESSAGE
    )

    prompt.start
    prompt.print_visual_banner("Kward is online.\n\nWorkspace   kaiwood/kward\nBranch      main\nPlugins     alpha.rb, beta.rb\n\nState your business.")
    prompt.send(:composer_input=, "/")
    prompt.send(:composer_cursor=, 1)
    prompt.send(:render_prompt_locked)
    output.truncate(0)
    output.rewind

    prompt.send(:composer_input=, "")
    prompt.send(:composer_cursor=, 0)
    prompt.send(:render_prompt_locked)

    rendered = strip_ansi(output.string)
    assert_includes rendered, "Kward is online."
    assert_includes rendered, "Workspace   kaiwood/kward"
    assert_includes rendered, "Branch      main"
    assert_includes rendered, "Plugins     alpha.rb, beta.rb"
    assert_order rendered, "Kward is online.", "Workspace   kaiwood/kward", "Plugins     alpha.rb, beta.rb", "State your business."
    refute_includes output.string, TTY::Cursor.clear_screen
  ensure
    TTY::Screen.define_singleton_method(:width, original_width) if original_width
    TTY::Screen.define_singleton_method(:height, original_height) if original_height
  end

  def test_prompt_interface_restores_transcript_text_after_overlay_resizes_composer
    output = StringIO.new
    original_width = TTY::Screen.method(:width)
    original_height = TTY::Screen.method(:height)
    TTY::Screen.define_singleton_method(:width) { 40 }
    TTY::Screen.define_singleton_method(:height) { 12 }
    prompt = Kward::PromptInterface.new(
      input: StringIO.new,
      output: output,
      slash_commands: (1..4).map { |index| { name: "cmd#{index}", description: "Command #{index}.", argument_hint: "" } }
    )

    prompt.start
    prompt.say((1..8).map { |index| "line#{index}" }.join("\n"))
    prompt.send(:composer_input=, "/")
    prompt.send(:composer_cursor=, 1)
    prompt.send(:render_prompt_locked)
    output.truncate(0)
    output.rewind

    prompt.send(:composer_input=, "")
    prompt.send(:composer_cursor=, 0)
    prompt.send(:render_prompt_locked)

    assert_includes output.string, "line8"
    refute_includes output.string, TTY::Cursor.clear_screen
  ensure
    TTY::Screen.define_singleton_method(:width, original_width) if original_width
    TTY::Screen.define_singleton_method(:height, original_height) if original_height
  end

  def test_prompt_interface_renders_startup_info_screen
    output = StringIO.new
    prompt = Kward::PromptInterface.new(
      input: StringIO.new,
      output: output,
      banner_message: Kward::PromptInterface::BANNER_MESSAGE
    )

    prompt.start
    prompt.print_visual_banner("Kward is online.\n\nWorkspace   kaiwood/kward\nBranch      main\nPlugins     alpha.rb, beta.rb\n\nState your business.")

    rendered = strip_ansi(output.string)
    assert_includes rendered, "Kward is online."
    assert_includes rendered, "Workspace   kaiwood/kward"
    assert_includes rendered, "Branch      main"
    assert_includes rendered, "Plugins     alpha.rb, beta.rb"
    assert_order rendered, "Kward is online.", "Workspace   kaiwood/kward", "Plugins     alpha.rb, beta.rb", "State your business."
    refute_includes output.string, "\e[48;2;"
    refute_includes output.string, "\e_G"
    refute_includes output.string, "\e]1337;File="
  end

  def test_prompt_interface_limits_startup_info_screen_on_short_terminals
    original_height = TTY::Screen.method(:height)
    TTY::Screen.define_singleton_method(:height) { 6 }
    prompt = Kward::PromptInterface.new(
      input: StringIO.new,
      output: StringIO.new,
      banner_message: Kward::PromptInterface::BANNER_MESSAGE
    )

    rows = prompt.send(:banner_rows, 80, message: "one\ntwo\nState your business.")

    assert_equal ["State your business.", ""], rows
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

    assert_includes output.string, "\e[>25u"
    assert_includes output.string, "\e[r"
    assert_includes output.string, "\e[<u"
  end

  def test_prompt_interface_terminal_handoff_restores_terminal_protocols_and_prompt
    output = StringIO.new
    yielded_input = nil
    yielded_output = nil
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: output)
    prompt.start
    output.truncate(0)
    output.rewind

    prompt.with_terminal_handoff do |input, handoff_output|
      yielded_input = input
      yielded_output = handoff_output
      handoff_output.print("child")
    end

    assert_same prompt.instance_variable_get(:@input_io), yielded_input
    assert_same output, yielded_output
    assert_includes output.string, "child"
    assert_includes output.string, "\e[r"
    assert_includes output.string, "\e[<u"
    assert_includes output.string, "\e[?2004l"
    assert_includes output.string, "\e[>25u"
    assert_includes output.string, "\e[?2004h"
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

  def test_prompt_interface_converts_pasted_image_path_to_hidden_attachment
    Dir.mktmpdir do |dir|
      path = File.join(dir, "Screenshot 2026-06-07 at 12.34.56.png")
      File.binwrite(path, "png bytes")
      input, writer = IO.pipe
      output = StringIO.new
      writer.write("look \e[200~#{path}\e[201~\r")
      writer.close
      prompt = Kward::PromptInterface.new(
        input: input,
        output: output,
        attachment_parser: ->(text) { Kward::ImageAttachments.extract_references_from_text(text) },
        attachment_badges: ->(_input, attachments) { attachments.map { |attachment| "[image] #{attachment[:label]}" } }
      )

      result = prompt.ask("You>")

      assert_kind_of Kward::PromptInterface::SubmittedInput, result
      assert_equal "look", result.display_input
      assert_equal "look\n#{path}", result.to_s
      assert_includes strip_ansi(output.string), "[image] Screenshot 2026-06-07 at 12.34.56.png"
      refute_includes strip_ansi(output.string), "look #{path}"
    ensure
      input&.close unless input&.closed?
    end
  end

  def test_prompt_interface_converts_shell_escaped_pasted_image_path_to_hidden_attachment
    Dir.mktmpdir do |dir|
      path = File.join(dir, "Screenshot 2026-06-07 at 12.34.56.png")
      escaped_path = Shellwords.escape(path)
      File.binwrite(path, "png bytes")
      input, writer = IO.pipe
      output = StringIO.new
      writer.write("look \e[200~#{escaped_path}\e[201~\r")
      writer.close
      prompt = Kward::PromptInterface.new(
        input: input,
        output: output,
        attachment_parser: ->(text) { Kward::ImageAttachments.extract_references_from_text(text) },
        attachment_badges: ->(_input, attachments) { attachments.map { |attachment| "[image] #{attachment[:label]}" } }
      )

      result = prompt.ask("You>")

      assert_kind_of Kward::PromptInterface::SubmittedInput, result
      assert_equal "look", result.display_input
      assert_equal "look\n#{path}", result.to_s
      assert_includes strip_ansi(output.string), "[image] Screenshot 2026-06-07 at 12.34.56.png"
      refute_includes strip_ansi(output.string), escaped_path
    ensure
      input&.close unless input&.closed?
    end
  end

  def test_prompt_interface_backspace_at_start_removes_hidden_attachment
    Dir.mktmpdir do |dir|
      path = File.join(dir, "Screenshot 2026-06-07 at 12.34.56.png")
      File.binwrite(path, "png bytes")
      input, writer = IO.pipe
      output = StringIO.new
      writer.write("\e[200~#{path}\e[201~\x7F\r")
      writer.close
      prompt = Kward::PromptInterface.new(
        input: input,
        output: output,
        attachment_parser: ->(text) { Kward::ImageAttachments.extract_references_from_text(text) },
        attachment_badges: ->(_input, attachments) { attachments.map { |attachment| "[image] #{attachment[:label]}" } }
      )

      assert_equal "", prompt.ask("You>")
    ensure
      input&.close unless input&.closed?
    end
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

  def test_prompt_interface_loads_persistent_history_for_up_arrow
    Dir.mktmpdir do |config_dir|
      Dir.mktmpdir do |workspace|
        history = Kward::PromptHistory.new(config_dir: config_dir, cwd: workspace)
        history.append("persisted prompt")
        input, writer = IO.pipe
        output = StringIO.new
        writer.write("\e[A\r")
        writer.close
        prompt = Kward::PromptInterface.new(input: input, output: output, prompt_history: history)

        assert_equal "persisted prompt", prompt.ask("You>")
      ensure
        input&.close unless input&.closed?
      end
    end
  end

  def test_prompt_interface_persists_submitted_history
    Dir.mktmpdir do |config_dir|
      Dir.mktmpdir do |workspace|
        history = Kward::PromptHistory.new(config_dir: config_dir, cwd: workspace)
        input, writer = IO.pipe
        output = StringIO.new
        writer.write("save me\r")
        writer.close
        prompt = Kward::PromptInterface.new(input: input, output: output, prompt_history: history)

        assert_equal "save me", prompt.ask("You>")
        assert_equal ["save me"], Kward::PromptHistory.new(config_dir: config_dir, cwd: workspace).values
      ensure
        input&.close unless input&.closed?
      end
    end
  end

  def test_prompt_interface_switches_prompt_history_temporarily
    Dir.mktmpdir do |config_dir|
      Dir.mktmpdir do |workspace|
        prompt_history = Kward::PromptHistory.new(config_dir: config_dir, cwd: workspace)
        shell_history = Kward::PromptHistory.new(config_dir: config_dir, cwd: workspace, kind: "shell")
        input, writer = IO.pipe
        output = StringIO.new
        writer.write("shell command\rnormal prompt\r")
        writer.close
        prompt = Kward::PromptInterface.new(input: input, output: output, prompt_history: prompt_history)

        assert_equal "shell command", prompt.with_prompt_history(shell_history) { prompt.ask("Shell $") }
        assert_equal "normal prompt", prompt.ask("You>")

        assert_equal ["shell command"], Kward::PromptHistory.new(config_dir: config_dir, cwd: workspace, kind: "shell").values
        assert_equal ["normal prompt"], Kward::PromptHistory.new(config_dir: config_dir, cwd: workspace).values
      ensure
        input&.close unless input&.closed?
      end
    end
  end

  def test_prompt_interface_preserves_persistent_history_after_empty_snapshot_restore
    Dir.mktmpdir do |config_dir|
      Dir.mktmpdir do |workspace|
        history = Kward::PromptHistory.new(config_dir: config_dir, cwd: workspace)
        history.append("persisted prompt")
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, prompt_history: history)

        prompt.restore_composer_snapshot({})
        prompt.send(:recall_previous_history)

        assert_equal "persisted prompt", prompt.send(:composer_input)
      end
    end
  end

  def test_prompt_interface_ctrl_r_search_accepts_selected_history_into_composer
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new)
    prompt.send(:load_history, ["explain project", "run tests", "review diff"])
    prompt.send(:composer_input=, "e")
    prompt.send(:composer_cursor=, 1)

    prompt.send(:handle_key, "\x12")
    assert prompt.send(:history_search_active?)
    assert_equal ["review diff", "run tests", "explain project"], prompt.send(:history_search_matches)

    prompt.send(:handle_key, "\e[B")
    prompt.send(:handle_key, "\r")

    refute prompt.send(:history_search_active?)
    assert_equal "run tests", prompt.send(:composer_input)
  end

  def test_prompt_interface_ctrl_r_search_cancels_to_original_draft
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new)
    prompt.send(:load_history, ["explain project"])
    prompt.send(:composer_input=, "draft")
    prompt.send(:composer_cursor=, 5)

    prompt.send(:handle_key, "\x12")
    prompt.send(:handle_key, "x")
    prompt.send(:handle_key, "\e")

    refute prompt.send(:history_search_active?)
    assert_equal "draft", prompt.send(:composer_input)
  end

  def test_prompt_interface_renders_braille_spinner_while_busy
    output = StringIO.new
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: output)

    prompt.begin_busy_input("You>")

    assert_includes strip_ansi(output.string), "╭ You · ⠋ streaming "
  end

  def test_prompt_interface_renders_custom_busy_activity
    output = StringIO.new
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: output)

    prompt.begin_busy_input("You>", activity: "compacting")

    assert_includes strip_ansi(output.string), "╭ You · ⠋ compacting "
  end

  def test_prompt_interface_renders_busy_help_text_by_default
    output = StringIO.new
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: output)

    prompt.begin_busy_input("You>")

    assert_includes strip_ansi(output.string), Kward::PromptInterface::BUSY_HELP_TEXT
  end

  def test_prompt_interface_hides_busy_help_text_when_disabled
    output = StringIO.new
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: output, busy_help: false)

    prompt.begin_busy_input("You>")

    refute_includes strip_ansi(output.string), Kward::PromptInterface::BUSY_HELP_TEXT
  end

  def test_prompt_interface_redraws_only_changed_composer_rows
    output = StringIO.new
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: output)
    prompt.begin_busy_input("You>")
    prompt.instance_variable_set(:@last_spinner_tick, prompt.send(:monotonic_now) - Kward::PromptInterface::SPINNER_INTERVAL)
    output.truncate(0)
    output.rewind

    prompt.send(:tick_spinner_locked)
    prompt.send(:render_prompt_locked)

    assert_equal 0, output.string.scan(TTY::Cursor.clear_line).length
    assert_match(/╭ You · [⠙⠹⠸⠼⠴⠦⠧⠇⠏] streaming /, strip_ansi(output.string))
  end

  def test_question_overlay_wraps_each_line_of_approval_details
    output = StringIO.new
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: output)
    prompt.instance_variable_set(:@question_state, {
      question: "The agent wants to run this shell command.\nArguments:\n{\n  \"command\": \"bundle exec ruby -Itest test/test_permissions_policy.rb\"\n}",
      header: "Approval required · Shell command",
      options: question_args("Proceed?")[:options],
      selection_index: 0,
      index: 1,
      total: 1
    })

    rows = prompt.send(:question_overlay_rows, 40).map { |row| Kward::ANSI.strip(row) }

    assert rows.any? { |row| row.include?("\"command\":") }
    assert rows.any? { |row| row.include?("test_permissions") }
  end

  def test_prompt_interface_busy_poll_does_not_handle_key_after_question_modal_activates
    output = StringIO.new
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: output)
    prompt.begin_busy_input("You>")
    prompt.send(:add_history, "last prompt text")
    ready = Queue.new
    release = Queue.new
    result = :unset
    prompt.define_singleton_method(:read_key) do |nonblock: false|
      ready << nonblock
      release.pop
      "\e[A"
    end

    thread = Thread.new { result = prompt.poll_input }
    ready.pop
    prompt.instance_variable_set(:@question_prompt_active, true)
    prompt.instance_variable_set(:@question_state, {
      question: "Proceed?",
      header: "Confirm",
      options: question_args("Proceed?")[:options],
      selection_index: 1,
      index: 1,
      total: 1
    })
    release << true
    thread.join(1)

    refute thread.alive?
    assert_nil result
    assert_empty prompt.send(:composer_input)
    assert_equal 1, prompt.instance_variable_get(:@question_state)[:selection_index]
    assert_equal ["\e[A"], prompt.instance_variable_get(:@pending_keys)
  ensure
    thread&.kill if thread&.alive?
  end

  def test_prompt_interface_busy_poll_does_not_submit_after_question_modal_activates
    output = StringIO.new
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: output)
    prompt.begin_busy_input("You>")
    ready = Queue.new
    release = Queue.new
    result = :unset
    prompt.define_singleton_method(:read_key) do |nonblock: false|
      ready << nonblock
      release.pop
      "\r"
    end

    thread = Thread.new { result = prompt.poll_input }
    ready.pop
    prompt.instance_variable_set(:@question_prompt_active, true)
    prompt.instance_variable_set(:@question_state, {
      question: "Proceed?",
      header: "Confirm",
      options: question_args("Proceed?")[:options],
      selection_index: 0,
      index: 1,
      total: 1
    })
    release << true
    thread.join(1)

    refute thread.alive?
    assert_nil result
    assert prompt.instance_variable_get(:@asking)
    assert_operator prompt.instance_variable_get(:@rendered_rows), :>, 0
    assert_equal ["\r"], prompt.instance_variable_get(:@pending_keys)
  ensure
    thread&.kill if thread&.alive?
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

    assert_match(/╭ You · [⠙⠹⠸⠼⠴⠦⠧⠇⠏] streaming /, strip_ansi(output.string))
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

    assert_includes strip_ansi(output.string), "╭ You · 1 queued "
    refute_includes output.string, "streaming"
  end

  def test_prompt_interface_shows_steering_status_with_spinner
    output = StringIO.new
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: output)
    prompt.begin_busy_input("You>")
    output.truncate(0)
    output.rewind

    prompt.set_steered_count(1)

    assert_includes strip_ansi(output.string), "╭ You · ⠋ steering "
    refute_includes output.string, "steered"
    refute_includes output.string, "queued"
  end

  def test_prompt_interface_returns_to_streaming_after_steering_clears
    output = StringIO.new
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: output)
    prompt.begin_busy_input("You>")
    prompt.set_steered_count(1)
    output.truncate(0)
    output.rewind

    prompt.clear_steered_count

    assert_includes strip_ansi(output.string), "╭ You · ⠋ streaming "
    refute_includes output.string, "steering"
    refute_includes output.string, "steered"
  end

  def test_prompt_interface_keeps_terminal_backspace_between_busy_polls
    PTY.open do |master, slave|
      output = StringIO.new
      prompt = Kward::PromptInterface.new(input: slave, output: output)
      prompt.begin_busy_input("You>")
      master.write("abcdef")
      6.times { prompt.poll_input }
      assert_equal "abcdef", prompt.send(:composer_input)

      master.write("\x7F" * 3)
      sleep 0.05
      3.times { prompt.poll_input }

      assert_equal "abc", prompt.send(:composer_input)
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

  def test_prompt_interface_writes_raw_transcript_delta
    output = StringIO.new
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: output)

    prompt.write_transcript_delta("shell")
    prompt.write_transcript_delta(" output\n")

    assert_includes strip_ansi(output.string), "shell output"
  ensure
    prompt&.close
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
    assert_includes output.string, Kward::PromptInterface::CURSOR_HIDE
    assert_match(/\e\[19;3H#{Regexp.escape(Kward::PromptInterface::CURSOR_SHOW)}.*\z/, output.string)

    output.truncate(0)
    output.rewind
    prompt.write_delta("hello")
    assert_includes output.string, Kward::PromptInterface::CURSOR_HIDE
    assert_match(/\e\[19;3H#{Regexp.escape(Kward::PromptInterface::CURSOR_SHOW)}.*\z/, output.string)

    output.truncate(0)
    output.rewind
    prompt.finish_stream_block
    assert_includes output.string, Kward::PromptInterface::CURSOR_HIDE
    assert_match(/\e\[19;3H#{Regexp.escape(Kward::PromptInterface::CURSOR_SHOW)}.*\z/, output.string)
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
    assert_includes stripped, "Tool output> .git/\r\n.gitignore\r\nREADME.md\r\n"
  end

  def test_prompt_interface_synchronizes_say_redraw
    output = StringIO.new
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: output)
    prompt.start
    output.truncate(0)
    output.rewind

    prompt.say("hello")

    assert_includes output.string, Kward::PromptInterface::SYNCHRONIZED_OUTPUT_ENABLE
    assert_includes output.string, Kward::PromptInterface::SYNCHRONIZED_OUTPUT_DISABLE
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
    assert_includes stripped, "\r\nTool> abcde"
    refute_includes stripped, "╯Tool>"
  end

  def test_prompt_interface_separates_open_stream_blocks
    output = StringIO.new
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: output)
    prompt.start
    output.truncate(0)
    output.rewind

    prompt.start_stream_block("Assistant")
    prompt.write_delta("assistant text")
    prompt.start_stream_block("Reasoning")
    prompt.write_delta("reasoning text")

    stripped = strip_ansi(output.string)
    assert_includes stripped, "Assistant> assistant text\r\n\r\nReasoning> reasoning text"
  end

  def test_prompt_interface_does_not_add_extra_newline_when_finished_block_already_ends_with_one
    output = StringIO.new
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: output)

    prompt.write_stream_block("Reasoning", "First step\n\n", finish: true)
    prompt.write_stream_block("Reasoning", "Second step", finish: true)

    stripped = strip_ansi(output.string)
    assert_includes stripped, "Reasoning> First step\r\n\r\nReasoning> Second step\r\n"
    refute_includes stripped, "First step\r\n\r\n\r\nReasoning>"
  ensure
    prompt&.close
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
    assert_equal ["", "", "", "aaaaaaaaaa", "next"], prompt.send(:transcript_viewport_rows, 5, 10)
  ensure
    TTY::Screen.define_singleton_method(:width, original_width) if original_width
  end

  def test_prompt_interface_resets_stream_position_after_redrawing_full_width_transcript
    output = StringIO.new
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: output)
    original_width = TTY::Screen.method(:width)
    original_height = TTY::Screen.method(:height)
    TTY::Screen.define_singleton_method(:width) { 10 }
    TTY::Screen.define_singleton_method(:height) { 20 }
    prompt.begin_busy_input("You>")
    output.truncate(0)
    output.rewind

    prompt.write_delta("a" * 10)
    prompt.redraw
    output.truncate(0)
    output.rewind
    prompt.write_delta("next")

    assert_includes output.string, "\r\nnext"
  ensure
    TTY::Screen.define_singleton_method(:width, original_width) if original_width
    TTY::Screen.define_singleton_method(:height, original_height) if original_height
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
    assert_includes strip_ansi(output.string), "╭ You "
  ensure
    TTY::Screen.define_singleton_method(:height, original_height) if original_height
  end

  def test_prompt_interface_reuses_transcript_display_rows_until_transcript_changes
    output = StringIO.new
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: output)
    prompt.start
    prompt.say("first")

    rows = prompt.send(:transcript_display_rows, 80)
    assert_same rows, prompt.send(:transcript_display_rows, 80)

    prompt.say("second")

    refute_same rows, prompt.send(:transcript_display_rows, 80)
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
    assert_includes strip_ansi(output.string), "╭ You "
  end

  def test_prompt_interface_redraw_preserves_transcript_sgr_color
    output = StringIO.new
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: output)
    prompt.instance_variable_set(:@color_enabled, true)
    prompt.start
    output.truncate(0)
    output.rewind

    prompt.start_stream_block("Tool output")
    prompt.write_delta("\e[31mred\e[0m\n")
    output.truncate(0)
    output.rewind

    prompt.redraw

    assert_includes output.string, "\e[36;1mTool output>\e[0m"
    assert_includes output.string, "\e[31mred\e[0m"
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
    assert_includes strip_ansi(output.string), "╭ You "
  end

  def test_prompt_interface_tab_view_snapshot_is_not_mutated_by_later_transcript_restore
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs")
    prompt.say("first tab")
    snapshot = prompt.tab_view_snapshot

    prompt.restore_transcript do
      prompt.say("second tab")
    end

    prompt.restore_tab_view_snapshot(snapshot)

    assert_includes strip_ansi(snapshot[:transcript_buffer].to_s), "first tab"
    refute_includes strip_ansi(snapshot[:transcript_buffer].to_s), "second tab"
    assert_includes strip_ansi(prompt.instance_variable_get(:@transcript_buffer).to_s), "first tab"
    refute_includes strip_ansi(prompt.instance_variable_get(:@transcript_buffer).to_s), "second tab"
  end

  def test_prompt_interface_tab_view_snapshot_is_not_mutated_by_later_stream_state_changes
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs")
    prompt.start_stream_block("Assistant")
    snapshot = prompt.tab_view_snapshot

    prompt.finish_stream_block

    assert_equal "Assistant", snapshot[:stream_state].block
  end

  def test_prompt_interface_restore_transcript_preserves_history_with_synchronized_redraw
    output = StringIO.new
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: output)
    original_width = TTY::Screen.method(:width)
    original_height = TTY::Screen.method(:height)
    TTY::Screen.define_singleton_method(:width) { 80 }
    TTY::Screen.define_singleton_method(:height) { 20 }
    prompt.start
    output.truncate(0)
    output.rewind

    prompt.restore_transcript do
      1.upto(30) { |index| prompt.say("line #{index}") }
    end

    assert_includes output.string, Kward::PromptInterface::SYNCHRONIZED_OUTPUT_ENABLE
    assert_includes output.string, Kward::PromptInterface::SYNCHRONIZED_OUTPUT_DISABLE
    assert_includes output.string, TTY::Cursor.clear_screen
    assert_includes strip_ansi(output.string), "line 1\r\n"
    assert_includes strip_ansi(output.string), "line 30"
  ensure
    TTY::Screen.define_singleton_method(:width, original_width) if original_width
    TTY::Screen.define_singleton_method(:height, original_height) if original_height
  end

  def test_prompt_interface_visual_output_is_not_saved_for_redraw
    output = StringIO.new
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: output)
    prompt.start
    output.truncate(0)
    output.rewind

    prompt.say_visual("\e_Ginline=1:payload\e\\")

    assert_includes output.string, "\e_Ginline=1:payload\e\\"
    refute_includes prompt.instance_variable_get(:@transcript_buffer), "\e_G"
    output.truncate(0)
    output.rewind

    prompt.redraw

    refute_includes output.string, "\e_G"
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
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs")
    original_height = TTY::Screen.method(:height)
    TTY::Screen.define_singleton_method(:height) { 3 }
    prompt.send(:composer_input=, "hello")
    prompt.send(:composer_cursor=, 5)

    rows, cursor_row, = prompt.send(:composer_layout, 20)

    assert_equal 1, rows.length
    assert_equal 0, cursor_row
    assert_includes rows.join, "You> hello"
  ensure
    TTY::Screen.define_singleton_method(:height, original_height) if original_height
  end

  def test_prompt_interface_caps_boxed_composer_height
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs")
    value = (1..10).map { |index| "line #{index}" }.join("\n")
    prompt.send(:composer_input=, value)
    prompt.send(:composer_cursor=, value.length)

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

    prompt.send(:composer_input=, "abcde")
    rows, = prompt.send(:composer_layout, 10)
    assert rows.all? { |row| Kward::ANSI.strip(row).length <= 10 }

    original_width = TTY::Screen.method(:width)
    TTY::Screen.define_singleton_method(:width) { 10 }

    assert_equal "abcde", prompt.ask("You>")
  ensure
    TTY::Screen.define_singleton_method(:width, original_width) if original_width
    input&.close unless input&.closed?
  end

  def test_start_interactive_renders_canvas_in_composer_region
    output = StringIO.new
    original_width = TTY::Screen.method(:width)
    original_height = TTY::Screen.method(:height)
    TTY::Screen.define_singleton_method(:width) { 40 }
    TTY::Screen.define_singleton_method(:height) { 20 }
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: output)
    prompt.start

    controller = prompt.start_interactive(title: "Test", rows: 3, fps: 30)
    controller.clear_frame
    controller.put(0, 0, "X", :red)
    controller.put(1, 2, "O", :green)
    controller.render
    prompt.send(:render_prompt_locked)

    plain = strip_ansi(output.string)
    assert_includes plain, "╭ Test"
    assert_includes plain, "X"
    assert_includes plain, "O"
    assert_includes plain, "Interactive"
    assert_includes plain, "Ctrl+C exits"
  ensure
    TTY::Screen.define_singleton_method(:width, original_width) if original_width
    TTY::Screen.define_singleton_method(:height, original_height) if original_height
  end

  def test_interactive_resize_updates_controller_width
    output = StringIO.new
    width = 40
    original_width = TTY::Screen.method(:width)
    original_height = TTY::Screen.method(:height)
    TTY::Screen.define_singleton_method(:width) { width }
    TTY::Screen.define_singleton_method(:height) { 20 }
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: output)
    prompt.start
    controller = prompt.start_interactive(title: "Test", rows: 3, fps: 30)

    width = 60
    prompt.send(:handle_resize_locked)

    assert_equal 54, controller.width
  ensure
    TTY::Screen.define_singleton_method(:width, original_width) if original_width
    TTY::Screen.define_singleton_method(:height, original_height) if original_height
  end

  def test_finish_interactive_restores_composer_state
    output = StringIO.new
    original_width = TTY::Screen.method(:width)
    original_height = TTY::Screen.method(:height)
    TTY::Screen.define_singleton_method(:width) { 40 }
    TTY::Screen.define_singleton_method(:height) { 20 }
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: output)
    prompt.start
    prompt.send(:composer_input=, "hello world")
    prompt.send(:render_prompt_locked)

    controller = prompt.start_interactive(title: "Test", rows: 3, fps: 30)
    controller.clear_frame
    controller.render
    prompt.send(:render_prompt_locked)

    prompt.finish_interactive

    assert prompt.send(:composer_input).include?("hello world")
    refute prompt.send(:interactive_active_locked?)
  ensure
    TTY::Screen.define_singleton_method(:width, original_width) if original_width
    TTY::Screen.define_singleton_method(:height, original_height) if original_height
  end

  def test_interactive_ctrl_c_forces_exit
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new)
    prompt.start

    controller = prompt.start_interactive(title: "Test", rows: 3, fps: 30)
    prompt.send(:handle_interactive_key, "\x03")

    assert controller.exited?
    assert prompt.interactive_exited?
  end

  def test_interactive_escape_forces_exit
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new)
    prompt.start

    controller = prompt.start_interactive(title: "Test", rows: 3, fps: 30)
    prompt.send(:handle_interactive_key, "\e")

    assert controller.exited?
    assert prompt.interactive_exited?
  end

  def test_interactive_csi_u_escape_forces_exit
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new)
    prompt.start

    controller = prompt.start_interactive(title: "Test", rows: 3, fps: 30)
    prompt.send(:handle_interactive_key, "\e[27u")

    assert controller.exited?
    assert prompt.interactive_exited?
  end

  def test_interactive_csi_u_space_routes_space_key_to_controller
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new)
    prompt.start

    controller = prompt.start_interactive(title: "Test", rows: 3, fps: 30)
    prompt.send(:handle_interactive_key, "\e[32u")

    assert_equal :space, controller.poll_key
  end

  def test_interactive_csi_u_printable_key_routes_character_to_controller
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new)
    prompt.start

    controller = prompt.start_interactive(title: "Test", rows: 3, fps: 30)
    prompt.send(:handle_interactive_key, "\e[113u")

    assert_equal "q", controller.poll_key
  end

  def test_interactive_routes_keys_to_controller
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new)
    prompt.start

    controller = prompt.start_interactive(title: "Test", rows: 3, fps: 30)
    prompt.send(:handle_interactive_key, "\e[D")

    assert_equal :left, controller.poll_key
  end

  def test_interactive_poll_input_returns_exited_when_controller_exits
    input, writer = IO.pipe
    writer.close
    prompt = Kward::PromptInterface.new(input: input, output: StringIO.new)
    prompt.start

    controller = prompt.start_interactive(title: "Test", rows: 3, fps: 30)
    controller.exit

    result = prompt.poll_input
    assert_equal :interactive_exited, result
  ensure
    input&.close unless input&.closed?
  end

  def test_interactive_tick_invokes_on_tick_callback
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new)
    prompt.start

    controller = prompt.start_interactive(title: "Test", rows: 3, fps: 30)
    tick_count = 0
    controller.on_tick { |_ui| tick_count += 1 }
    prompt.send(:instance_variable_set, :@last_interactive_tick, 0)

    prompt.send(:tick_interactive_locked)

    assert_equal 1, tick_count
  end

  def test_interactive_tick_requires_an_explicit_render
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new)
    prompt.start
    controller = prompt.start_interactive(title: "Test", rows: 3, fps: 30)
    controller.on_tick { |ui| ui.put(0, 0, "X") }
    prompt.send(:instance_variable_set, :@last_interactive_tick, 0)

    refute prompt.send(:tick_interactive_locked)

    controller.render
    assert prompt.send(:tick_interactive_locked)
  end

  def test_interactive_tick_returns_exit_from_callback
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new)
    prompt.start

    controller = prompt.start_interactive(title: "Test", rows: 3, fps: 30)
    controller.on_tick { :exit }
    prompt.send(:instance_variable_set, :@last_interactive_tick, 0)

    prompt.send(:tick_interactive_locked)

    assert controller.exited?
  end

  def test_interactive_active_false_by_default
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new)

    refute prompt.interactive_active?
    refute prompt.send(:interactive_active_locked?)
  end

  def test_editor_auto_closes_pairs_and_skips_existing_closer
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "modern")
    editor = Kward::PromptInterface::EditorState.new(path: "test.rb", content: "", editor_mode: "modern")
    prompt.instance_variable_set(:@editor_state, editor)

    prompt.send(:handle_editor_key, "(")
    assert_equal "()", editor.buffer
    assert_equal 1, editor.cursor

    prompt.send(:handle_editor_key, ")")
    assert_equal "()", editor.buffer
    assert_equal 2, editor.cursor
  end

  def test_editor_auto_close_pairs_wraps_selection
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "modern")
    editor = Kward::PromptInterface::EditorState.new(path: "test.rb", content: "alpha", editor_mode: "modern")
    editor.cursor = 0
    editor.begin_selection
    editor.cursor = 5
    prompt.instance_variable_set(:@editor_state, editor)

    prompt.send(:handle_editor_key, "[")

    assert_equal "[alpha]", editor.buffer
    assert_equal 7, editor.cursor
    refute editor.selection_active?
  end

  def test_editor_auto_close_pairs_wraps_selection_in_quotes
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "modern")
    editor = Kward::PromptInterface::EditorState.new(path: "test.rb", content: "alpha", editor_mode: "modern")
    editor.cursor = 0
    editor.begin_selection
    editor.cursor = 5
    prompt.instance_variable_set(:@editor_state, editor)

    prompt.send(:handle_editor_key, "\"")

    assert_equal "\"alpha\"", editor.buffer
    assert_equal 7, editor.cursor
    refute editor.selection_active?
  end

  def test_editor_auto_close_pairs_wraps_backward_selection_in_quotes
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "modern")
    editor = Kward::PromptInterface::EditorState.new(path: "test.rb", content: "alpha", editor_mode: "modern")
    editor.cursor = 5
    editor.begin_selection
    editor.cursor = 0
    prompt.instance_variable_set(:@editor_state, editor)

    prompt.send(:handle_editor_key, "'")

    assert_equal "'alpha'", editor.buffer
    assert_equal 7, editor.cursor
    refute editor.selection_active?
  end

  def test_editor_auto_close_pairs_extends_quote_wrap_to_word_end
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "modern")
    editor = Kward::PromptInterface::EditorState.new(path: "test.rb", content: "string", editor_mode: "modern")
    prompt.instance_variable_set(:@editor_state, editor)

    5.times { prompt.send(:handle_editor_key, "\e[1;2C") }
    prompt.send(:handle_editor_key, "\"")

    assert_equal "\"string\"", editor.buffer
    assert_equal 8, editor.cursor
    refute editor.selection_active?
  end

  def test_editor_auto_close_pairs_backspace_deletes_empty_pair
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "modern")
    editor = Kward::PromptInterface::EditorState.new(path: "test.rb", content: "", editor_mode: "modern")
    prompt.instance_variable_set(:@editor_state, editor)

    prompt.send(:handle_editor_key, "{")
    prompt.send(:handle_editor_key, "\b")

    assert_equal "", editor.buffer
    assert_equal 0, editor.cursor
  end

  def test_editor_auto_close_pairs_suppresses_quotes_inside_words
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "modern")
    editor = Kward::PromptInterface::EditorState.new(path: "test.rb", content: "dont", editor_mode: "modern")
    editor.cursor = 3
    prompt.instance_variable_set(:@editor_state, editor)

    prompt.send(:handle_editor_key, "'")

    assert_equal "don't", editor.buffer
    assert_equal 4, editor.cursor
  end

  def test_editor_auto_close_pairs_can_be_disabled
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "modern", editor_auto_close_pairs: false)
    editor = Kward::PromptInterface::EditorState.new(path: "test.rb", content: "", editor_mode: "modern")
    prompt.instance_variable_set(:@editor_state, editor)

    prompt.send(:handle_editor_key, "(")

    assert_equal "(", editor.buffer
    assert_equal 1, editor.cursor
  end

  def test_editor_bracketed_paste_does_not_auto_close_pairs
    input = StringIO.new("(")
    prompt = Kward::PromptInterface.new(input: input, output: StringIO.new, editor_mode: "modern")
    editor = Kward::PromptInterface::EditorState.new(path: "test.rb", content: "", editor_mode: "modern")
    prompt.instance_variable_set(:@editor_state, editor)

    prompt.send(:handle_editor_key, "\e[200~")

    assert_equal "(", editor.buffer
    assert_equal 1, editor.cursor
  end

end
