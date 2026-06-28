require_relative "../test_helper"

class TestPromptInterfaceGitOverlay < KwardTestCase
  def test_prompt_interface_git_overlay_renders_status_summary
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs")
    prompt.instance_variable_set(:@git_state, { status_lines: [" M lib/file.rb", "?? new.txt"], composing: false, selected_index: 0 })

    rows = prompt.send(:git_overlay_rows, 80)
    rendered = strip_ansi(rows.join("\n"))

    assert_includes rendered, "Git"
    assert_includes rendered, "↑/↓ select · Enter diff · s stage/unstage · Tab message · Esc cancel"
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

  def test_prompt_interface_git_tab_returns_to_overlay_and_preserves_message_draft
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs")
    prompt.instance_variable_set(:@git_state, { status_lines: [" M file"], composing: true, selected_index: 0 })
    prompt.send(:composer_input=, "ship it")
    prompt.send(:composer_cursor=, 4)

    assert_equal true, prompt.send(:handle_git_key, "\t")

    assert_equal "Git>", prompt.instance_variable_get(:@prompt_label)
    refute prompt.send(:git_composing?)
    assert_equal "", prompt.send(:composer_input)

    assert_equal true, prompt.send(:handle_git_key, "\t")

    assert_equal "Commit>", prompt.instance_variable_get(:@prompt_label)
    assert prompt.send(:git_composing?)
    assert_equal "ship it", prompt.send(:composer_input)
    assert_equal 4, prompt.send(:composer_cursor)
  end

  def test_prompt_interface_git_enter_opens_selected_file_diff
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs")
    prompt.instance_variable_set(:@git_state, { status_lines: [" M one.rb", "?? two.rb"], composing: false, selected_index: 1 })

    assert_equal({ action: :open_diff, index: 1 }, prompt.send(:handle_git_key, "\r"))
  end

  def test_prompt_interface_git_enter_submits_commit_message
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs")
    prompt.instance_variable_set(:@git_state, { status_lines: [" M file"], composing: true, selected_index: 0 })
    prompt.send(:composer_input=, "ship it")
    prompt.send(:composer_cursor=, "ship it".length)

    assert_equal "ship it", prompt.send(:handle_git_key, "\r")
  end

  def test_prompt_interface_git_shift_enter_inserts_message_newline
    Kward::PromptInterface::SHIFT_ENTER_SEQUENCES.each do |sequence|
      prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs")
      prompt.instance_variable_set(:@git_state, { status_lines: [" M file"], composing: true, selected_index: 0 })
      prompt.send(:composer_input=, "hello")
      prompt.send(:composer_cursor=, "hello".length)

      assert_nil prompt.send(:handle_git_key, sequence)
      assert_equal "hello\n", prompt.send(:composer_input)
    end
  end

  def test_prompt_interface_git_message_accepts_spaces
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs")
    prompt.instance_variable_set(:@git_state, { status_lines: [" M file"], composing: true, selected_index: 0 })
    "ship it".each_char { |char| prompt.send(:handle_git_key, char) }

    assert_equal "ship it", prompt.send(:composer_input)
  end

  def test_prompt_interface_git_message_accepts_csi_u_shifted_text
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs")
    prompt.instance_variable_set(:@git_state, { status_lines: [" M file"], composing: true, selected_index: 0 })

    assert_equal 1, prompt.send(:handle_git_key, "\e[97;2;65u")
    assert_equal "A", prompt.send(:composer_input)
  end

  def test_prompt_interface_git_message_uses_composer_shortcuts
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs")
    prompt.instance_variable_set(:@git_state, { status_lines: [" M file"], composing: true, selected_index: 0 })
    prompt.send(:composer_input=, "ship it now")
    prompt.send(:composer_cursor=, "ship it now".length)

    prompt.send(:handle_git_key, "\x01")
    assert_equal 0, prompt.send(:composer_cursor)

    prompt.send(:handle_git_key, "\x05")
    assert_equal "ship it now".length, prompt.send(:composer_cursor)

    prompt.send(:handle_git_key, "\e\x7F")
    assert_equal "ship it ", prompt.send(:composer_input)
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

  def test_prompt_interface_git_s_accepts_csi_u_printable_key
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs")
    prompt.instance_variable_set(:@git_state, { status_lines: [" M one.rb", "?? two.rb"], composing: false, selected_index: 1 })

    assert_equal({ action: :toggle_stage, index: 1 }, prompt.send(:handle_git_key, "\e[115u"))
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

end
