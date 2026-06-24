require_relative "test_helper"
require "pty"

class TestPromptInterface < KwardTestCase
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

  def test_non_busy_ctrl_c_raises_interrupt
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs")

    assert_raises(Interrupt) do
      prompt.send(:handle_key, "\x03")
    end
  end

  def test_non_busy_csi_u_ctrl_c_raises_interrupt
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs")

    assert_raises(Interrupt) do
      prompt.send(:handle_key, "\e[99;5u")
    end
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

  def test_prompt_interface_alt_tab_keybindings_return_tab_actions
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, tab_keybindings: "alt")
    prompt.update_tabs(labels: ["1"], active_index: 0)

    assert_equal({ tab_action: :new }, prompt.send(:handle_key, "\et"))
    assert_equal({ tab_action: :next }, prompt.send(:handle_key, "\e[1;3C"))
    assert_equal({ tab_action: :previous }, prompt.send(:handle_key, "\e[1;3D"))
    assert_equal({ tab_action: :select, index: 2 }, prompt.send(:handle_key, "\e3"))
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

  def test_prompt_interface_select_is_modal_while_active
    input, writer = IO.pipe
    output = StringIO.new
    prompt = Kward::PromptInterface.new(input: input, output: output)
    selected = nil
    thread = Thread.new { selected = prompt.select("Session>", ["first", "second"]) }
    wait_until { prompt.modal_active? }

    writer.write("\r")
    writer.close
    thread.join(1)

    assert_equal "first", selected
    refute prompt.modal_active?
  ensure
    thread&.kill if thread&.alive?
    input&.close unless input&.closed?
  end

  def test_prompt_interface_ask_user_question_is_modal_before_question_state_is_rendered
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs")
    question_prompt_active_before_question = nil
    question_state_before_question = :unset
    prompt.define_singleton_method(:begin_question_prompt_state) do
      question_prompt_active_before_question = instance_variable_get(:@question_prompt_active)
      question_state_before_question = instance_variable_get(:@question_state)
      {
        prompt_label: "You>",
        input: "",
        cursor: 0,
        asking: true,
        busy: false,
        queued_count: 0,
        steered_count: 0,
        pending_keys: [],
        select_state: nil
      }
    end
    prompt.define_singleton_method(:ask_single_user_question) do |question, _index, _total|
      { question: question[:question], answer: "Yes", custom: false }
    end

    answers = prompt.ask_user_question([question_args("Proceed?")])

    assert question_prompt_active_before_question
    assert_nil question_state_before_question
    refute prompt.modal_active?
    assert_equal [{ question: "Proceed?", answer: "Yes", custom: false }], answers
  end

  def test_prompt_interface_select_uses_initial_index
    input, writer = IO.pipe
    output = StringIO.new
    writer.write("\r")
    writer.close
    prompt = Kward::PromptInterface.new(input: input, output: output)

    assert_equal "second", prompt.select("Session>", ["first", "second"], initial_index: 1)
  ensure
    input&.close unless input&.closed?
  end

  def test_prompt_interface_select_does_not_wrap_at_edges
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs")
    prompt.instance_variable_set(:@select_state, { choices: %w[first second], selection_index: 0, title: "Sessions", custom: false })

    prompt.send(:select_previous_choice)
    assert_equal 0, prompt.send(:selection_index)

    prompt.instance_variable_get(:@select_state)[:selection_index] = 1
    prompt.send(:select_next_choice)
    assert_equal 1, prompt.send(:selection_index)
  end

  def test_prompt_interface_select_centers_long_list_scroll_window
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs")
    choices = (1..12).map { |index| "choice #{index}" }
    prompt.instance_variable_set(:@select_state, { choices: choices, selection_index: 0, title: "Sessions", custom: false })

    assert_equal ["choice 1", "choice 2", "choice 3", "choice 4", "choice 5"], prompt.send(:visible_selection_matches, choices, height: 12)[:choices]

    prompt.instance_variable_get(:@select_state)[:selection_index] = 2
    assert_equal ["choice 1", "choice 2", "choice 3", "choice 4", "choice 5"], prompt.send(:visible_selection_matches, choices, height: 12)[:choices]

    prompt.instance_variable_get(:@select_state)[:selection_index] = 3
    assert_equal ["choice 2", "choice 3", "choice 4", "choice 5", "choice 6"], prompt.send(:visible_selection_matches, choices, height: 12)[:choices]

    prompt.instance_variable_get(:@select_state)[:selection_index] = 11
    assert_equal ["choice 8", "choice 9", "choice 10", "choice 11", "choice 12"], prompt.send(:visible_selection_matches, choices, height: 12)[:choices]
  end

  def test_prompt_interface_select_ignores_typing_until_search_is_started
    input, writer = IO.pipe
    output = StringIO.new
    writer.write("sec\r")
    writer.close
    prompt = Kward::PromptInterface.new(input: input, output: output)

    assert_equal "first", prompt.select("Session>", ["first", "second"])
  ensure
    input&.close unless input&.closed?
  end

  def test_prompt_interface_select_filters_choices_after_slash
    input, writer = IO.pipe
    output = StringIO.new
    writer.write("/sec\r")
    writer.close
    prompt = Kward::PromptInterface.new(input: input, output: output)

    assert_equal "second", prompt.select("Session>", ["first", "second"])
  ensure
    input&.close unless input&.closed?
  end

  def test_prompt_interface_select_search_blocks_action_keys_until_escape
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs")
    action_keys = prompt.send(:normalized_select_action_keys, { "c" => :clone })
    prompt.instance_variable_set(:@select_state, { choices: ["first", "second"], selection_index: 0, title: "Sessions", custom: false, action_keys: action_keys, search_active: false })

    assert prompt.send(:handle_select_key, "/")
    assert_equal 0, prompt.send(:handle_select_key, "c")
    assert_equal "c", prompt.send(:composer_input)
    assert prompt.send(:handle_select_key, "\e[27u")
    assert_empty prompt.send(:composer_input)
    refute prompt.send(:select_search_active?)
    assert_equal({ action: :clone, choice: "first" }, prompt.send(:handle_select_key, "c"))
  end

  def test_prompt_interface_select_search_supports_shell_style_editing_keys
    input, writer = IO.pipe
    output = StringIO.new
    writer.write("/ab\x01Z\x05X\r")
    writer.close
    prompt = Kward::PromptInterface.new(input: input, output: output)

    assert_equal "ZabX", prompt.select("Session>", ["ZabX", "other"])
  ensure
    input&.close unless input&.closed?
  end

  def test_prompt_interface_select_search_supports_shell_style_kill_and_yank_keys
    input, writer = IO.pipe
    output = StringIO.new
    writer.write("/hello world\x15\x19\r")
    writer.close
    prompt = Kward::PromptInterface.new(input: input, output: output)

    assert_equal "hello world", prompt.select("Session>", ["hello world", "other"])
  ensure
    input&.close unless input&.closed?
  end

  def test_prompt_interface_select_title_switches_to_search_while_searching
    input, writer = IO.pipe
    output = StringIO.new
    writer.write("/sec\r")
    writer.close
    prompt = Kward::PromptInterface.new(input: input, output: output)

    assert_equal "second", prompt.select("Session>", ["first", "second"])
    stripped = strip_ansi(output.string)
    assert_includes stripped, "╭ Search "
    assert_includes stripped, "╭ Session "
  ensure
    input&.close unless input&.closed?
  end

  def test_prompt_interface_select_hides_cursor_until_search_starts
    input, writer = IO.pipe
    output = StringIO.new
    writer.write("/sec\r")
    writer.close
    prompt = Kward::PromptInterface.new(input: input, output: output)

    assert_equal "second", prompt.select("Session>", ["first", "second"])
    assert_includes output.string, Kward::PromptInterface::CURSOR_HIDE
    assert_includes output.string, Kward::PromptInterface::CURSOR_SHOW
  ensure
    input&.close unless input&.closed?
  end

  def test_prompt_interface_select_action_key_returns_selected_choice
    input, writer = IO.pipe
    output = StringIO.new
    writer.write("c")
    writer.close
    prompt = Kward::PromptInterface.new(input: input, output: output)

    assert_equal({ action: :clone, choice: "first" }, prompt.select("Session>", ["first", "second"], action_keys: { "c" => :clone }))
  ensure
    input&.close unless input&.closed?
  end

  def test_prompt_interface_select_action_handler_keeps_modal_visible_while_busy
    input, writer = IO.pipe
    output = StringIO.new
    writer.write("c")
    writer.close
    prompt = Kward::PromptInterface.new(input: input, output: output)
    modal_active_during_action = nil
    started_at = Time.now

    result = prompt.select(
      "Session>",
      ["first"],
      action_keys: { "c" => { action: :clone, activity: "cloning" } },
      action_handlers: { clone: ->(choice) { modal_active_during_action = prompt.modal_active?; "cloned #{choice}" } }
    )

    assert_equal "cloned first", result
    assert modal_active_during_action
    assert_operator Time.now - started_at, :>=, Kward::PromptInterface::SELECT_ACTION_MINIMUM_BUSY_SECONDS
    output_text = strip_ansi(output.string)
    assert_includes output_text, "Sessions"
    assert_includes output_text, "cloning"
  ensure
    input&.close unless input&.closed?
  end

  def test_prompt_interface_select_action_key_accepts_csi_u_printable_key
    input, writer = IO.pipe
    output = StringIO.new
    writer.write("\e[99u")
    writer.close
    prompt = Kward::PromptInterface.new(input: input, output: output)

    assert_equal({ action: :clone, choice: "first" }, prompt.select("Session>", ["first"], action_keys: { "c" => :clone }))
  ensure
    input&.close unless input&.closed?
  end

  def test_prompt_interface_select_input_action_runs_handler_and_keeps_picker_open
    input, writer = IO.pipe
    output = StringIO.new
    prompt = Kward::PromptInterface.new(input: input, output: output)
    handled = []

    thread = Thread.new do
      prompt.select(
        "Session>",
        ["first"],
        action_keys: { "r" => { action: :rename, input_prompt: "Name>" } },
        action_handlers: { rename: ->(choice, name) { handled << [choice, name]; { select_continue: true, choices: ["renamed"], selection_index: 0 } } }
      )
    end

    writer.write("rRenamed\r")
    sleep 0.05
    writer.write("\e")
    writer.close
    thread.join(1)

    assert_equal [["first", "Renamed"]], handled
    output_text = strip_ansi(output.string)
    assert_includes output_text, "Renaming · Enter save · Esc cancel"
    assert_includes output_text, "Name"
    assert_includes output_text, "renamed"
    refute_includes output_text, "streaming"
    assert_match(/#{Regexp.escape(Kward::PromptInterface::CURSOR_SHOW)}.*Renamed/m, output.string)
  ensure
    thread&.kill if thread&.alive?
    input&.close unless input&.closed?
  end

  def test_prompt_interface_select_confirmed_action_requires_same_key_twice
    input, writer = IO.pipe
    output = StringIO.new
    writer.write("dd")
    writer.close
    prompt = Kward::PromptInterface.new(input: input, output: output)

    assert_equal(
      { action: :delete, choice: "first" },
      prompt.select("Session>", ["first"], action_keys: { "d" => { action: :delete, confirm: "Press d again to delete, Esc to cancel.", confirm_title: "Delete session?" } })
    )
    output_text = strip_ansi(output.string)
    assert_includes output_text, "Delete session?"
    assert_includes output_text, "Press d again to delete, Esc to cancel."
  ensure
    input&.close unless input&.closed?
  end

  def test_prompt_interface_select_confirmed_action_escape_returns_to_picker
    input, writer = IO.pipe
    output = StringIO.new
    prompt = Kward::PromptInterface.new(input: input, output: output)
    selected = nil
    thread = Thread.new do
      selected = prompt.select(
        "Session>",
        ["first"],
        action_keys: {
          "c" => :clone,
          "d" => { action: :delete, confirm: "Press d again to delete, Esc to cancel.", confirm_title: "Delete session?" }
        }
      )
    end

    writer.write("d")
    sleep 0.05
    writer.write("\e")
    sleep 0.5
    writer.write("c")
    writer.close
    thread.join(1)

    assert_equal({ action: :clone, choice: "first" }, selected)
  ensure
    thread&.kill if thread&.alive?
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

  def test_prompt_interface_select_consecutive_escape_cancels_once
    input, writer = IO.pipe
    output = StringIO.new
    writer.write("\e\e")
    writer.close
    prompt = Kward::PromptInterface.new(input: input, output: output)

    assert_nil prompt.select("Session>", ["first", "second"])
    refute_includes strip_ansi(output.string), "You>"
  ensure
    input&.close unless input&.closed?
  end

  def test_prompt_interface_select_cancel_keeps_composer_reserved
    input, writer = IO.pipe
    output = StringIO.new
    writer.write("\e")
    writer.close
    prompt = Kward::PromptInterface.new(input: input, output: output)

    assert_nil prompt.select("Session>", (1..12).map { |index| "choice #{index}" })
    assert_operator prompt.instance_variable_get(:@reserved_rows), :>, 0
  ensure
    input&.close unless input&.closed?
  end

  def test_prompt_interface_select_escape_with_pending_escape_timeout_cancels_once
    input, writer = IO.pipe
    output = StringIO.new
    writer.write("\e")
    writer.close
    prompt = Kward::PromptInterface.new(input: input, output: output)
    prompt.send(:queue_pending_keys, "\e")

    assert_nil prompt.select("Session>", ["first", "second"])
    refute_includes strip_ansi(output.string), "You>"
  ensure
    input&.close unless input&.closed?
  end

  def test_prompt_interface_select_requeues_repeated_escape_sequences
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs")
    prompt.instance_variable_set(:@select_state, { choices: %w[first second third fourth], selection_index: 0, title: "Sessions", custom: false, action_keys: {}, search_active: false })
    prompt.define_singleton_method(:read_pending_escape_sequence) { "[B\e[B\e[B" }

    result = prompt.send(:handle_select_key, "\e")
    prompt.send(:drain_pending_select_keys_locked, result)

    assert_empty prompt.instance_variable_get(:@pending_keys)
    assert_equal 3, prompt.instance_variable_get(:@select_state)[:selection_index]
  end

  def test_prompt_interface_select_search_accepts_bracketed_paste
    input, writer = IO.pipe
    output = StringIO.new
    writer.write("/\e[200~sec\e[201~\r")
    writer.close
    prompt = Kward::PromptInterface.new(input: input, output: output)

    assert_equal "second", prompt.select("Session>", ["first", "second"])
  ensure
    input&.close unless input&.closed?
  end

  def test_prompt_interface_select_input_accepts_bracketed_paste
    input, writer = IO.pipe
    output = StringIO.new
    captured = nil
    writer.write("r\e[200~New name\e[201~\r")
    writer.close
    prompt = Kward::PromptInterface.new(input: input, output: output)

    prompt.select(
      "Session>",
      ["first"],
      action_keys: { "r" => { action: :rename, input_prompt: "Name>" } },
      action_handlers: { rename: ->(_choice, input) { captured = input } }
    )

    assert_equal "New name", captured
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

  def test_prompt_interface_ask_user_question_requeues_repeated_escape_sequences
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs")
    prompt.instance_variable_set(:@question_state, {
      question: "Proceed?",
      header: "Confirm",
      options: question_args("Proceed?")[:options],
      selection_index: 0,
      index: 1,
      total: 1
    })
    prompt.define_singleton_method(:read_pending_escape_sequence) { "[B\e[B" }

    result = prompt.send(:handle_question_key, "\e")
    prompt.send(:drain_pending_question_keys_locked, result)

    assert_empty prompt.instance_variable_get(:@pending_keys)
    assert_equal 2, prompt.instance_variable_get(:@question_state)[:selection_index]
  end

  def test_prompt_interface_ask_user_question_handles_cursor_key_variants
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs")
    prompt.instance_variable_set(:@question_state, {
      question: "Proceed?",
      header: "Confirm",
      options: question_args("Proceed?")[:options],
      selection_index: 0,
      index: 1,
      total: 1
    })

    ["\e[B", "\e[1;1B", "\e[1;2B", "\eOB"].each do |sequence|
      prompt.instance_variable_get(:@question_state)[:selection_index] = 0
      prompt.send(:handle_question_key, sequence)

      assert_equal 1, prompt.instance_variable_get(:@question_state)[:selection_index], "#{sequence.inspect} should move down"
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

  def test_prompt_interface_ask_user_question_printable_csi_u_enters_custom_answer
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs")
    prompt.instance_variable_set(:@question_state, {
      question: "Proceed?",
      header: "Confirm",
      options: question_args("Proceed?")[:options],
      selection_index: 0,
      index: 1,
      total: 1
    })

    prompt.send(:handle_question_key, "\e[32u")
    prompt.send(:handle_question_key, "\e[119;1u")

    assert_equal " w", prompt.send(:composer_input)
    assert_equal 2, prompt.instance_variable_get(:@question_state)[:selection_index]
  end

  def test_prompt_interface_ask_user_question_handles_csi_u_backspace
    input, writer = IO.pipe
    output = StringIO.new
    writer.write("maybe\e[127u\e[13u")
    writer.close
    prompt = Kward::PromptInterface.new(input: input, output: output)

    assert_equal [{ question: "Proceed?", answer: "mayb", custom: true }], prompt.ask_user_question([question_args("Proceed?")])
  ensure
    input&.close unless input&.closed?
  end

  def test_prompt_interface_ask_user_question_cancels_on_csi_u_escape
    input, writer = IO.pipe
    output = StringIO.new
    writer.write("maybe\e[27u")
    writer.close
    prompt = Kward::PromptInterface.new(input: input, output: output)

    assert_nil prompt.ask_user_question([question_args("Proceed?")])
  ensure
    input&.close unless input&.closed?
  end

  def test_prompt_interface_ask_user_question_accepts_bracketed_paste_custom_answer
    input, writer = IO.pipe
    output = StringIO.new
    writer.write("\e[200~maybe later\e[201~\r")
    writer.close
    prompt = Kward::PromptInterface.new(input: input, output: output)

    answers = prompt.ask_user_question([question_args("Proceed?")])

    assert_equal [{ question: "Proceed?", answer: "maybe later", custom: true }], answers
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
    assert_includes stripped, "Type a custom answer below."
    assert_includes stripped, "╭ Answer"
    assert_includes stripped, "│ maybe"
    assert_includes output.string, "\e[?25l"
    assert_includes output.string, "\e[?25h"
    assert_includes output.string, "\e[19;8H"
  ensure
    TTY::Screen.define_singleton_method(:width, original_width) if original_width
    TTY::Screen.define_singleton_method(:height, original_height) if original_height
    input&.close unless input&.closed?
  end

  def test_prompt_interface_ask_user_question_renders_custom_text_in_composer_box
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs")
    prompt.instance_variable_set(:@question_state, {
      question: "Proceed?",
      header: "Confirm",
      options: question_args("Proceed?")[:options],
      selection_index: 2,
      index: 1,
      total: 1
    })
    prompt.send(:composer_input=, "some ")
    prompt.send(:composer_cursor=, 5)

    rows, cursor_row, cursor_col = prompt.send(:question_composer_layout, 120, 20)
    stripped = strip_ansi(rows.join("\n"))

    assert_includes stripped, "Type a custom answer below."
    assert_includes stripped, "│ some "
    assert_operator cursor_row, :>, prompt.send(:question_overlay_rows, 120).length
    assert_equal 7, cursor_col
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

  def test_prompt_interface_shows_file_overlay_and_completes_selection
    input, writer = IO.pipe
    output = StringIO.new
    writer.write("@li\t\r")
    writer.close
    prompt = Kward::PromptInterface.new(input: input, output: output)
    prompt.instance_variable_set(:@file_mention_paths, ["README.md", "lib/main.rb"])

    assert_equal "@lib/main.rb", prompt.ask("You>")
    stripped = strip_ansi(output.string)
    assert_includes stripped, "╭ Files"
    assert_includes stripped, "› lib/main.rb"
    assert_includes stripped, "╰"
  ensure
    input&.close unless input&.closed?
  end

  def test_prompt_interface_file_overlay_completes_active_mention_in_middle_of_input
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs")
    prompt.instance_variable_set(:@file_mention_paths, ["doc/api.md", "lib/main.rb"])
    prompt.send(:composer_input=, "read @api please")
    prompt.send(:composer_cursor=, 9)

    assert prompt.send(:complete_selected_file_mention)
    assert_equal "read @doc/api.md please", prompt.send(:composer_input)
    assert_equal "read @doc/api.md".length, prompt.send(:composer_cursor)
  end

  def test_prompt_interface_file_overlay_down_selects_next_match
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs")
    prompt.instance_variable_set(:@file_mention_paths, ["README.md", "lib/main.rb"])
    prompt.send(:composer_input=, "@")
    prompt.send(:composer_cursor=, 1)

    prompt.send(:handle_key, "\e[B")

    assert_equal "lib/main.rb", prompt.send(:selected_file_mention_path)
  end

  def test_prompt_interface_file_overlay_shows_no_matches
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs")
    prompt.instance_variable_set(:@file_mention_paths, ["README.md"])
    prompt.send(:composer_input=, "@missing")
    prompt.send(:composer_cursor=, 8)

    rows = prompt.send(:file_overlay_rows, 80)

    assert_includes strip_ansi(rows.join("\n")), "No matching files"
  end

  def test_prompt_interface_dollar_file_overlay_opens_editor
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "lib"))
      File.write(File.join(dir, "lib", "main.rb"), "puts :hi\n")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs")
        prompt.instance_variable_set(:@file_mention_paths, ["README.md", "lib/main.rb"])
        prompt.send(:composer_input=, "$li")
        prompt.send(:composer_cursor=, 3)

        assert prompt.send(:open_selected_file_in_editor)

        editor = prompt.instance_variable_get(:@editor_state)
        assert_equal File.realpath(File.join(dir, "lib", "main.rb")), editor.path
        assert_equal "puts :hi\n", editor.buffer
      end
    end
  end

  def test_prompt_interface_dollar_file_overlay_only_works_at_prompt_start
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs")
    prompt.instance_variable_set(:@file_mention_paths, ["README.md"])
    prompt.send(:composer_input=, "open $README")
    prompt.send(:composer_cursor=, "open $README".length)

    refute prompt.send(:file_open_overlay_visible?)
    refute prompt.send(:file_overlay_visible?)
  end

  def test_prompt_interface_enter_opens_typed_existing_file_outside_narrowdown
    Dir.mktmpdir do |dir|
      dir = File.realpath(dir)
      path = File.join(dir, "ignored.log")
      File.write(path, "ignored\n")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs")
        prompt.instance_variable_set(:@file_mention_paths, [])
        prompt.send(:composer_input=, "$ignored.log")
        prompt.send(:composer_cursor=, "$ignored.log".length)

        assert prompt.send(:open_selected_file_in_editor, fallback_to_typed_path: true)

        editor = prompt.instance_variable_get(:@editor_state)
        assert_equal path, editor.path
        assert_equal "ignored\n", editor.buffer
      end
    end
  end

  def test_prompt_interface_enter_opens_new_file_without_creating_until_save
    Dir.mktmpdir do |dir|
      dir = File.realpath(dir)
      path = File.join(dir, "new.txt")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs")
        prompt.instance_variable_set(:@file_mention_paths, [])
        prompt.send(:composer_input=, "$new.txt")
        prompt.send(:composer_cursor=, "$new.txt".length)

        assert prompt.send(:open_selected_file_in_editor, fallback_to_typed_path: true)
        refute File.exist?(path)

        editor = prompt.instance_variable_get(:@editor_state)
        assert editor.new_file
        assert_equal "", editor.buffer
        prompt.send(:handle_editor_key, "h")
        prompt.send(:handle_editor_key, "i")
        prompt.send(:handle_editor_key, "\x18")
        prompt.send(:handle_editor_key, "\x13")

        assert_equal "hi", File.read(path)
      end
    end
  end

  def test_prompt_interface_named_enter_opens_typed_new_file
    Dir.mktmpdir do |dir|
      dir = File.realpath(dir)
      FileUtils.mkdir_p(File.join(dir, "plan"))
      path = File.join(dir, "plan", "editor.md")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs")
        prompt.instance_variable_set(:@file_mention_paths, [])
        prompt.send(:composer_input=, "$plan/editor.md")
        prompt.send(:composer_cursor=, "$plan/editor.md".length)

        assert_equal :return, prompt.send(:key_name_for, "\r")
        assert prompt.send(:handle_key, "\r")
        refute File.exist?(path)

        editor = prompt.instance_variable_get(:@editor_state)
        assert editor.new_file
        assert_equal path, editor.path
      end
    end
  end

  def test_prompt_interface_refuses_new_file_with_missing_parent
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs")
        prompt.instance_variable_set(:@file_mention_paths, [])
        prompt.send(:composer_input=, "$missing/new.txt")
        prompt.send(:composer_cursor=, "$missing/new.txt".length)

        refute prompt.send(:open_selected_file_in_editor, fallback_to_typed_path: true)
        assert_nil prompt.instance_variable_get(:@editor_state)
        assert_includes prompt.instance_variable_get(:@file_editor_open_status), "parent directory is missing"
      end
    end
  end

  def test_prompt_interface_tab_does_not_open_typed_missing_file
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs")
        prompt.instance_variable_set(:@file_mention_paths, [])
        prompt.send(:composer_input=, "$new.txt")
        prompt.send(:composer_cursor=, "$new.txt".length)

        refute prompt.send(:open_selected_file_in_editor)
        assert_nil prompt.instance_variable_get(:@editor_state)
      end
    end
  end

  def test_prompt_interface_file_overlay_uses_git_ignored_project_files
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "lib"))
      File.write(File.join(dir, "lib", "main.rb"), "")
      File.write(File.join(dir, "ignored.log"), "")
      File.write(File.join(dir, ".gitignore"), "ignored.log\n")
      system("git", "init", "--quiet", chdir: dir)
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs")

        paths = prompt.send(:project_file_paths)

        assert_includes paths, "lib/main.rb"
        assert_includes paths, ".gitignore"
        refute_includes paths, "ignored.log"
      end
    end
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

  def test_prompt_interface_select_close_keeps_composer_visible
    input, writer = IO.pipe
    output = StringIO.new
    original_width = TTY::Screen.method(:width)
    original_height = TTY::Screen.method(:height)
    TTY::Screen.define_singleton_method(:width) { 80 }
    TTY::Screen.define_singleton_method(:height) { 20 }
    writer.write("\r")
    writer.close
    prompt = Kward::PromptInterface.new(input: input, output: output)

    assert_equal "choice one", prompt.select("Tree>", ["choice one"], title: "Session Tree")

    assert_includes strip_ansi(output.string), "╭ Tree"
    assert_includes strip_ansi(output.string), "│"
    assert_includes output.string, Kward::PromptInterface::SYNCHRONIZED_OUTPUT_ENABLE
    assert_includes output.string, Kward::PromptInterface::SYNCHRONIZED_OUTPUT_DISABLE
    assert_equal true, prompt.instance_variable_get(:@asking)
  ensure
    TTY::Screen.define_singleton_method(:width, original_width) if original_width
    TTY::Screen.define_singleton_method(:height, original_height) if original_height
    input&.close unless input&.closed?
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

  def test_prompt_interface_git_overlay_renders_status_summary
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs")
    prompt.instance_variable_set(:@git_state, { status_lines: [" M lib/file.rb", "?? new.txt"], composing: false, selected_index: 0 })

    rows = prompt.send(:git_overlay_rows, 80)
    rendered = strip_ansi(rows.join("\n"))

    assert_includes rendered, "Git"
    assert_includes rendered, "↑/↓ select · s stage/unstage · Tab message · Esc cancel"
    assert_includes rendered, "›  M lib/file.rb"
    assert_includes rendered, "  ?? new.txt"
  end

  def test_prompt_interface_git_overlay_scrolls_to_selected_status_line
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs")
    status_lines = (1..12).map { |index| " M file#{index}.rb" }
    prompt.instance_variable_set(:@git_state, { status_lines: status_lines, composing: false, selected_index: 10 })

    rows = prompt.send(:git_overlay_rows, 80, height: 15)
    rendered = strip_ansi(rows.join("\n"))

    assert_includes rendered, "… 4 above"
    assert_includes rendered, "›  M file11.rb"
    refute_includes rendered, " M file1.rb"
  end

  def test_prompt_interface_git_tab_enters_commit_message_mode
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs")
    prompt.instance_variable_set(:@git_state, { status_lines: [" M file"], composing: false, selected_index: 0 })

    assert_equal true, prompt.send(:handle_git_key, "\t")

    assert_equal "Commit>", prompt.instance_variable_get(:@prompt_label)
    assert prompt.send(:git_composing?)
  end

  def test_prompt_interface_git_enter_submits_commit_message
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs")
    prompt.instance_variable_set(:@git_state, { status_lines: [" M file"], composing: true, selected_index: 0 })
    prompt.send(:composer_input=, "ship it")
    prompt.send(:composer_cursor=, "ship it".length)

    assert_equal "ship it", prompt.send(:handle_git_key, "\r")
  end

  def test_prompt_interface_git_message_accepts_spaces
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs")
    prompt.instance_variable_set(:@git_state, { status_lines: [" M file"], composing: true, selected_index: 0 })
    "ship it".each_char { |char| prompt.send(:handle_git_key, char) }

    assert_equal "ship it", prompt.send(:composer_input)
  end

  def test_prompt_interface_git_message_accepts_bracketed_paste
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs")
    prompt.instance_variable_set(:@git_state, { status_lines: [" M file"], composing: true, selected_index: 0 })

    assert_nil prompt.send(:handle_git_key, "\e[200~ship it now\e[201~")
    assert_equal "ship it now", prompt.send(:composer_input)
  end

  def test_prompt_interface_git_arrow_keys_move_selection
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs")
    prompt.instance_variable_set(:@git_state, { status_lines: [" M one.rb", "?? two.rb"], composing: false, selected_index: 0 })

    assert_equal true, prompt.send(:handle_git_key, "\e[B")
    assert_equal 1, prompt.instance_variable_get(:@git_state)[:selected_index]

    assert_equal true, prompt.send(:handle_git_key, "\e[A")
    assert_equal 0, prompt.instance_variable_get(:@git_state)[:selected_index]
  end

  def test_prompt_interface_git_s_requests_toggle_for_selected_file
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs")
    prompt.instance_variable_set(:@git_state, { status_lines: [" M one.rb", "?? two.rb"], composing: false, selected_index: 1 })

    assert_equal({ action: :toggle_stage, index: 1 }, prompt.send(:handle_git_key, "s"))
  end

  def test_prompt_interface_git_s_inserts_while_composing
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs")
    prompt.instance_variable_set(:@git_state, { status_lines: [" M file"], composing: true, selected_index: 0 })

    prompt.send(:handle_git_key, "s")

    assert_equal "s", prompt.send(:composer_input)
  end

  def test_prompt_interface_git_cursor_is_hidden_until_composing
    output = StringIO.new
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: output)
    prompt.instance_variable_set(:@git_state, { status_lines: [" M file"], composing: false, selected_index: 0 })
    prompt.instance_variable_set(:@cursor_visible, true)

    prompt.send(:render_cursor_visibility_locked)

    assert_includes output.string, Kward::PromptInterface::CURSOR_HIDE

    output.truncate(0)
    output.rewind
    prompt.instance_variable_set(:@git_state, { status_lines: [" M file"], composing: true, selected_index: 0 })
    prompt.send(:render_cursor_visibility_locked)

    assert_includes output.string, Kward::PromptInterface::CURSOR_SHOW
  end

  def test_prompt_interface_git_escape_cancels
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs")
    prompt.instance_variable_set(:@git_state, { status_lines: [" M file"], composing: false })

    assert_equal Kward::PromptInterface::SELECT_CANCEL, prompt.send(:handle_git_key, "\e")
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

end
