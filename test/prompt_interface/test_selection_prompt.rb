require_relative "../test_helper"

class TestPromptInterfaceSelectionPrompt < KwardTestCase
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

  def test_prompt_interface_select_filters_choices_after_csi_u_slash_text
    input, writer = IO.pipe
    output = StringIO.new
    writer.write("\e[0;1;47usec\r")
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

  def test_prompt_interface_ask_user_question_printable_shift_csi_u_enters_custom_answer
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs")
    prompt.instance_variable_set(:@question_state, {
      question: "Proceed?",
      header: "Confirm",
      options: question_args("Proceed?")[:options],
      selection_index: 0,
      index: 1,
      total: 1
    })

    prompt.send(:handle_question_key, "\e[65;2u")

    assert_equal "A", prompt.send(:composer_input)
    assert_equal 2, prompt.instance_variable_get(:@question_state)[:selection_index]
  end

  def test_prompt_interface_ask_user_question_ignores_private_use_csi_u_key_events
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs")
    prompt.instance_variable_set(:@question_state, {
      question: "Proceed?",
      header: "Confirm",
      options: question_args("Proceed?")[:options],
      selection_index: 2,
      index: 1,
      total: 1
    })

    prompt.send(:handle_question_key, "\e[57447;2u")

    assert_equal "", prompt.send(:composer_input)
  end

  def test_prompt_interface_ask_user_question_custom_answer_uses_composer_shortcuts
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs")
    prompt.instance_variable_set(:@question_state, {
      question: "Proceed?",
      header: "Confirm",
      options: question_args("Proceed?")[:options],
      selection_index: 2,
      index: 1,
      total: 1
    })
    prompt.send(:composer_input=, "hello world")
    prompt.send(:composer_cursor=, "hello world".length)

    prompt.send(:handle_question_key, "\eb")
    prompt.send(:handle_question_key, "\ed")
    prompt.send(:handle_question_key, "\x01")
    prompt.send(:handle_question_key, "\x0B")
    prompt.send(:handle_question_key, "\x19")

    assert_equal "hello ", prompt.send(:composer_input)
    assert_equal "hello ".length, prompt.send(:composer_cursor)
    assert_equal 2, prompt.instance_variable_get(:@question_state)[:selection_index]
  end

  def test_prompt_interface_ask_user_question_renders_tabs
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs")
    prompt.update_tabs(labels: %w[Main Ops], active_index: 1)
    prompt.instance_variable_set(:@question_state, {
      question: "Proceed?",
      header: "Confirm",
      options: question_args("Proceed?")[:options],
      selection_index: 0,
      index: 1,
      total: 1
    })

    rows, = prompt.send(:composer_layout, 80, 24)
    rendered_rows = rows.last(3).map { |row| strip_ansi(row) }

    assert_match(/1 Main +│ 2 Ops │/, rendered_rows[1])
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

end
