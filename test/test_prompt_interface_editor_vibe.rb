require_relative "test_helper"

class TestPromptInterfaceEditorVibe < KwardTestCase
  def test_prompt_interface_vibe_mode_allows_ctrl_number_tab_switching
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "vibe", tab_keybindings: "ctrl")
    prompt.instance_variable_set(:@tabs, [Object.new, Object.new])
    prompt.instance_variable_set(:@editor_state, Kward::PromptInterface::EditorState.new(path: "notes.txt", content: "alpha", editor_mode: "vibe"))

    assert_equal({ tab_action: :select, index: 0 }, prompt.send(:handle_key, "\e[49;5u"))
    assert_equal({ tab_action: :select, index: 1 }, prompt.send(:handle_key, "\e[50;5u"))
  end

  def test_prompt_interface_vibe_mode_opens_in_normal_mode_and_requires_insert
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "notes.txt"), "alpha")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "vibe")
        assert prompt.send(:open_editor, "notes.txt")
        editor = prompt.instance_variable_get(:@editor_state)

        assert_equal "vibe", editor.editor_mode
        assert_equal "normal", editor.vibe_mode
        prompt.send(:handle_editor_key, "z")
        assert_equal "alpha", editor.buffer

        prompt.send(:handle_editor_key, "i")
        prompt.send(:handle_editor_key, "z")
        prompt.send(:handle_editor_key, "\e")

        assert_equal "zalpha", editor.buffer
        assert_equal "normal", editor.vibe_mode
      end
    end
  end

  def test_prompt_interface_vibe_mode_supports_classic_first_non_blank_movement
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "notes.txt"), "  one\n    two\nthree\n  four")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "vibe")
        assert prompt.send(:open_editor, "notes.txt")
        editor = prompt.instance_variable_get(:@editor_state)
        editor.set_cursor_line_and_column(0, 5)

        prompt.send(:handle_editor_key, "^")
        assert_equal [0, 2], editor.cursor_line_and_column

        prompt.send(:handle_editor_key, "+")
        assert_equal [1, 4], editor.cursor_line_and_column

        prompt.send(:handle_editor_key, "-")
        assert_equal [0, 2], editor.cursor_line_and_column

        prompt.send(:handle_editor_key, "3")
        prompt.send(:handle_editor_key, "_")
        assert_equal [2, 0], editor.cursor_line_and_column

        prompt.send(:handle_editor_key, "\r")
        assert_equal [3, 2], editor.cursor_line_and_column
      end
    end
  end

  def test_prompt_interface_vibe_mode_supports_screen_position_movement
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "notes.txt"), (0...20).map { |index| "  line#{index}" }.join("\n"))
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "vibe")
        prompt.define_singleton_method(:screen_height) { 14 }
        assert prompt.send(:open_editor, "notes.txt")
        editor = prompt.instance_variable_get(:@editor_state)
        editor.viewport_row = 5

        prompt.send(:handle_editor_key, "H")
        assert_equal [5, 2], editor.cursor_line_and_column

        prompt.send(:handle_editor_key, "M")
        assert_equal [10, 2], editor.cursor_line_and_column

        prompt.send(:handle_editor_key, "L")
        assert_equal [14, 2], editor.cursor_line_and_column

        prompt.send(:handle_editor_key, "2")
        prompt.send(:handle_editor_key, "H")
        assert_equal [6, 2], editor.cursor_line_and_column

        prompt.send(:handle_editor_key, "2")
        prompt.send(:handle_editor_key, "L")
        assert_equal [13, 2], editor.cursor_line_and_column
      end
    end
  end

  def test_prompt_interface_vibe_mode_screen_position_respects_viewport_in_soft_wrap
    original_height = TTY::Screen.method(:height)
    original_width = TTY::Screen.method(:width)
    TTY::Screen.define_singleton_method(:height) { 20 }
    TTY::Screen.define_singleton_method(:width) { 40 }
    Dir.mktmpdir do |dir|
      content = (0...30).map { |index| "  line #{index} with long wrapped content that fills the row" }.join("\n")
      File.write(File.join(dir, "notes.txt"), content)
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "vibe")
        assert prompt.send(:open_editor, "notes.txt")
        editor = prompt.instance_variable_get(:@editor_state)
        prompt.send(:composer_layout, 40, 20)
        assert prompt.send(:current_editor_soft_wrap?), "expected soft wrap to be active"

        viewport_before = editor.viewport_row
        prompt.send(:handle_editor_key, "L")
        prompt.send(:composer_layout, 40, 20)
        assert_equal viewport_before, editor.viewport_row,
                     "L must not scroll the viewport in soft-wrap mode"
      end
    end
  ensure
    TTY::Screen.define_singleton_method(:height, original_height) if original_height
    TTY::Screen.define_singleton_method(:width, original_width) if original_width
  end

  def test_prompt_interface_vibe_mode_supports_page_and_scroll_movement
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "notes.txt"), (0...30).map { |index| "line#{index}" }.join("\n"))
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "vibe")
        prompt.define_singleton_method(:screen_height) { 14 }
        assert prompt.send(:open_editor, "notes.txt")
        editor = prompt.instance_variable_get(:@editor_state)

        prompt.send(:handle_editor_key, "\x06")
        assert_equal [10, 0], editor.cursor_line_and_column

        prompt.send(:handle_editor_key, "\x02")
        assert_equal [0, 0], editor.cursor_line_and_column

        prompt.send(:handle_editor_key, "\x04")
        assert_equal [5, 0], editor.cursor_line_and_column

        prompt.send(:handle_editor_key, "\x15")
        assert_equal [0, 0], editor.cursor_line_and_column

        assert_equal 0, editor.viewport_row
        prompt.send(:handle_editor_key, "\x05")
        assert_equal 1, editor.viewport_row
        prompt.send(:handle_editor_key, "\x19")
        assert_equal 0, editor.viewport_row
      end
    end
  end

  def test_prompt_interface_vibe_mode_supports_space_and_backspace_movement
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "notes.txt"), "alpha")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "vibe")
        assert prompt.send(:open_editor, "notes.txt")
        editor = prompt.instance_variable_get(:@editor_state)

        prompt.send(:handle_editor_key, " ")
        assert_equal 1, editor.cursor

        prompt.send(:handle_editor_key, "\b")
        assert_equal 0, editor.cursor
      end
    end
  end

  def test_prompt_interface_vibe_mode_e_moves_to_end_of_word
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "notes.txt"), "alpha beta gamma")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "vibe")
        assert prompt.send(:open_editor, "notes.txt")
        editor = prompt.instance_variable_get(:@editor_state)

        prompt.send(:handle_editor_key, "e")
        assert_equal 4, editor.cursor

        prompt.send(:handle_editor_key, "e")
        assert_equal 9, editor.cursor
      end
    end
  end

  def test_prompt_interface_vibe_mode_e_works_as_operator_motion
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "notes.txt"), "alpha beta")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "vibe")
        assert prompt.send(:open_editor, "notes.txt")
        editor = prompt.instance_variable_get(:@editor_state)

        prompt.send(:handle_editor_key, "d")
        prompt.send(:handle_editor_key, "e")

        assert_equal " beta", editor.buffer
        assert_equal "alpha", editor.kill_buffer
      end
    end
  end

  def test_prompt_interface_vibe_mode_big_x_deletes_before_cursor
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "notes.txt"), "alpha")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "vibe")
        assert prompt.send(:open_editor, "notes.txt")
        editor = prompt.instance_variable_get(:@editor_state)
        editor.set_cursor_line_and_column(0, 3)

        prompt.send(:handle_editor_key, "X")
        assert_equal "alha", editor.buffer
        assert_equal 2, editor.cursor

        prompt.send(:handle_editor_key, "u")
        assert_equal "alpha", editor.buffer
      end
    end
  end

  def test_prompt_interface_vibe_mode_big_x_supports_counts
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "notes.txt"), "alpha")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "vibe")
        assert prompt.send(:open_editor, "notes.txt")
        editor = prompt.instance_variable_get(:@editor_state)
        editor.set_cursor_line_and_column(0, 4)

        prompt.send(:handle_editor_key, "2")
        prompt.send(:handle_editor_key, "X")

        assert_equal "ala", editor.buffer
        assert_equal 2, editor.cursor
      end
    end
  end

  def test_prompt_interface_vibe_mode_dd_deletes_final_empty_line
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "notes.txt"), "one\ntwo\n")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "vibe")
        assert prompt.send(:open_editor, "notes.txt")
        editor = prompt.instance_variable_get(:@editor_state)
        editor.move_file_end

        prompt.send(:handle_editor_key, "d")
        prompt.send(:handle_editor_key, "d")

        assert_equal "one\ntwo", editor.buffer
        assert_equal "\n", editor.kill_buffer
      end
    end
  end

  def test_prompt_interface_vibe_mode_dd_deletes_final_non_empty_line
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "notes.txt"), "one\ntwo")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "vibe")
        assert prompt.send(:open_editor, "notes.txt")
        editor = prompt.instance_variable_get(:@editor_state)
        editor.set_cursor_line_and_column(1, 0)

        prompt.send(:handle_editor_key, "d")
        prompt.send(:handle_editor_key, "d")

        assert_equal "one", editor.buffer
        assert_equal "\ntwo", editor.kill_buffer
      end
    end
  end

  def test_prompt_interface_vibe_mode_big_i_inserts_at_first_non_blank_and_big_a_inserts_at_line_end
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "notes.txt"), "alpha\n  beta")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "vibe")
        assert prompt.send(:open_editor, "notes.txt")
        editor = prompt.instance_variable_get(:@editor_state)
        editor.set_cursor_line_and_column(1, 4)

        prompt.send(:handle_editor_key, "I")
        assert_equal "insert", editor.vibe_mode
        prompt.send(:handle_editor_key, "!")
        prompt.send(:handle_editor_key, "\e")
        assert_equal "alpha\n  !beta", editor.buffer

        prompt.send(:handle_editor_key, "A")
        assert_equal "insert", editor.vibe_mode
        prompt.send(:handle_editor_key, "?")
        prompt.send(:handle_editor_key, "\e")
        assert_equal "alpha\n  !beta?", editor.buffer
      end
    end
  end

  def test_prompt_interface_vibe_mode_big_r_replaces_existing_text_until_escape
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "notes.txt"), "alpha beta")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "vibe")
        assert prompt.send(:open_editor, "notes.txt")
        editor = prompt.instance_variable_get(:@editor_state)
        editor.set_cursor_line_and_column(0, 6)

        prompt.send(:handle_editor_key, "R")
        assert_equal "replace", editor.vibe_mode
        prompt.send(:handle_editor_key, "G")
        prompt.send(:handle_editor_key, "A")
        prompt.send(:handle_editor_key, "M")
        prompt.send(:handle_editor_key, "M")
        prompt.send(:handle_editor_key, "A")
        prompt.send(:handle_editor_key, "\e")

        assert_equal "alpha GAMMA", editor.buffer
        assert_equal "normal", editor.vibe_mode
      end
    end
  end

  def test_prompt_interface_vibe_mode_big_r_appends_after_end_of_line
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "notes.txt"), "alpha")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "vibe")
        assert prompt.send(:open_editor, "notes.txt")
        editor = prompt.instance_variable_get(:@editor_state)
        editor.move_line_end

        prompt.send(:handle_editor_key, "R")
        prompt.send(:handle_editor_key, "!")
        prompt.send(:handle_editor_key, "\e")

        assert_equal "alpha!", editor.buffer
      end
    end
  end

  def test_prompt_interface_vibe_mode_named_escape_and_ctrl_c_return_to_normal_mode
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "notes.txt"), "alpha")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "vibe")
        assert prompt.send(:open_editor, "notes.txt")
        editor = prompt.instance_variable_get(:@editor_state)

        prompt.send(:handle_editor_key, "i")
        assert_equal "insert", editor.vibe_mode
        prompt.send(:handle_editor_key, :escape)
        assert_equal "normal", editor.vibe_mode

        prompt.send(:handle_editor_key, "i")
        assert_equal "insert", editor.vibe_mode
        prompt.send(:handle_editor_key, "\x03")
        assert_equal "normal", editor.vibe_mode
      end
    end
  end

  def test_prompt_interface_vibe_mode_csi_u_escape_and_ctrl_c_return_to_normal_mode
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "notes.txt"), "alpha")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "vibe")
        assert prompt.send(:open_editor, "notes.txt")
        editor = prompt.instance_variable_get(:@editor_state)

        prompt.send(:handle_editor_key, "i")
        assert_equal "insert", editor.vibe_mode
        prompt.send(:handle_editor_key, "\e[27u")
        assert_equal "normal", editor.vibe_mode

        prompt.send(:handle_editor_key, "i")
        assert_equal "insert", editor.vibe_mode
        prompt.send(:handle_editor_key, "\e[27;1u")
        assert_equal "normal", editor.vibe_mode

        prompt.send(:handle_editor_key, "i")
        assert_equal "insert", editor.vibe_mode
        prompt.send(:handle_editor_key, "\e[99;5u")
        assert_equal "normal", editor.vibe_mode
      end
    end
  end

  def test_prompt_interface_vibe_mode_escape_and_ctrl_c_cancel_command_mode
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "notes.txt"), "alpha")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "vibe")
        assert prompt.send(:open_editor, "notes.txt")
        editor = prompt.instance_variable_get(:@editor_state)

        prompt.send(:handle_editor_key, ":")
        prompt.send(:handle_editor_key, "w")
        prompt.send(:handle_editor_key, :escape)
        assert_equal "normal", editor.vibe_mode
        assert_equal "", editor.vibe_command

        prompt.send(:handle_editor_key, ":")
        prompt.send(:handle_editor_key, "q")
        prompt.send(:handle_editor_key, "\x03")
        assert_equal "normal", editor.vibe_mode
        assert_equal "", editor.vibe_command
      end
    end
  end

  def test_prompt_interface_vibe_mode_repeats_search_direction
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "notes.txt"), "alpha\nbeta\nalpha")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "vibe")
        assert prompt.send(:open_editor, "notes.txt")
        editor = prompt.instance_variable_get(:@editor_state)

        prompt.send(:handle_editor_key, "/")
        "alpha".each_char { |char| prompt.send(:handle_editor_key, char) }
        prompt.send(:handle_editor_key, "\r")
        assert_equal [2, 0], editor.cursor_line_and_column

        prompt.send(:handle_editor_key, "n")
        assert_equal [0, 0], editor.cursor_line_and_column

        prompt.send(:handle_editor_key, "N")
        assert_equal [2, 0], editor.cursor_line_and_column
      end
    end
  end

  def test_prompt_interface_vibe_mode_star_and_hash_search_word_under_cursor
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "notes.txt"), "alpha beta\ngamma beta\nalpha")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "vibe")
        assert prompt.send(:open_editor, "notes.txt")
        editor = prompt.instance_variable_get(:@editor_state)
        editor.set_cursor_line_and_column(0, 6)

        prompt.send(:handle_editor_key, "*")
        assert_equal [1, 6], editor.cursor_line_and_column
        assert_equal :forward, editor.search_direction

        prompt.send(:handle_editor_key, "#")
        assert_equal [0, 6], editor.cursor_line_and_column
        assert_equal :backward, editor.search_direction
      end
    end
  end

  def test_prompt_interface_vibe_mode_question_mark_searches_backward
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "notes.txt"), "alpha\nbeta\nalpha")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "vibe")
        assert prompt.send(:open_editor, "notes.txt")
        editor = prompt.instance_variable_get(:@editor_state)
        editor.move_file_end

        prompt.send(:handle_editor_key, "?")
        assert editor.search_active
        assert_equal :backward, editor.search_direction
        "alpha".each_char { |char| prompt.send(:handle_editor_key, char) }
        prompt.send(:handle_editor_key, "\r")

        assert_equal [2, 0], editor.cursor_line_and_column
        assert_equal "Found: alpha", editor.status
      end
    end
  end

  def test_prompt_interface_vibe_mode_visual_yanks_character_selection_to_clipboard
    output = StringIO.new
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "notes.txt"), "alpha beta")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: output, editor_mode: "vibe")
        assert prompt.send(:open_editor, "notes.txt")
        editor = prompt.instance_variable_get(:@editor_state)

        prompt.send(:handle_editor_key, "v")
        4.times { prompt.send(:handle_editor_key, "l") }
        assert_equal "visual", editor.vibe_mode
        assert_equal "alpha", editor.selected_text

        prompt.send(:handle_editor_key, "y")

        assert_equal "normal", editor.vibe_mode
        refute editor.selection_active?
        assert_equal "alpha", editor.kill_buffer
        assert_includes output.string, "\e]52;c;#{Base64.strict_encode64("alpha")}\a"
      end
    end
  end

  def test_prompt_interface_vibe_mode_visual_wraps_full_character_selection_in_quotes
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "notes.txt"), "string")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "vibe")
        assert prompt.send(:open_editor, "notes.txt")
        editor = prompt.instance_variable_get(:@editor_state)

        prompt.send(:handle_editor_key, "v")
        5.times { prompt.send(:handle_editor_key, "l") }
        prompt.send(:handle_editor_key, "\"")

        assert_equal "\"string\"", editor.buffer
      end
    end
  end

  def test_prompt_interface_vibe_mode_visual_line_yanks_full_lines
    output = StringIO.new
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "notes.txt"), "one\ntwo\nthree")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: output, editor_mode: "vibe")
        assert prompt.send(:open_editor, "notes.txt")
        editor = prompt.instance_variable_get(:@editor_state)

        prompt.send(:handle_editor_key, "V")
        prompt.send(:handle_editor_key, "j")
        assert_equal "visual_line", editor.vibe_mode
        assert_equal "one\ntwo\n", editor.selected_text

        prompt.send(:handle_editor_key, "y")

        assert_equal "normal", editor.vibe_mode
        assert_equal "one\ntwo\n", editor.kill_buffer
        assert_includes output.string, "\e]52;c;#{Base64.strict_encode64("one\ntwo\n")}\a"
      end
    end
  end

  def test_prompt_interface_vibe_mode_visual_delete_change_paste_and_undo
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "notes.txt"), "alpha beta")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "vibe")
        assert prompt.send(:open_editor, "notes.txt")
        editor = prompt.instance_variable_get(:@editor_state)

        prompt.send(:handle_editor_key, "v")
        4.times { prompt.send(:handle_editor_key, "l") }
        prompt.send(:handle_editor_key, "d")
        assert_equal " beta", editor.buffer
        prompt.send(:handle_editor_key, "u")
        assert_equal "alpha beta", editor.buffer

        editor.set_cursor_line_and_column(0, 0)
        prompt.send(:handle_editor_key, "v")
        4.times { prompt.send(:handle_editor_key, "l") }
        prompt.send(:handle_editor_key, "c")
        assert_equal "insert", editor.vibe_mode
        prompt.send(:handle_editor_key, "A")
        prompt.send(:handle_editor_key, "\e")
        assert_equal "A beta", editor.buffer

        editor.set_cursor_line_and_column(0, 0)
        editor.kill_buffer = "omega"
        prompt.send(:handle_editor_key, "v")
        prompt.send(:handle_editor_key, "p")
        assert_equal "omega beta", editor.buffer
      end
    end
  end

  def test_prompt_interface_vibe_mode_visual_escape_clears_selection
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "notes.txt"), "alpha")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "vibe")
        assert prompt.send(:open_editor, "notes.txt")
        editor = prompt.instance_variable_get(:@editor_state)

        prompt.send(:handle_editor_key, "v")
        prompt.send(:handle_editor_key, "l")
        assert editor.selection_active?
        prompt.send(:handle_editor_key, "\e")

        assert_equal "normal", editor.vibe_mode
        refute editor.selection_active?
      end
    end
  end

  def test_prompt_interface_vibe_mode_supports_counts_and_navigation
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "notes.txt"), "one\ntwo\nthree")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "vibe")
        assert prompt.send(:open_editor, "notes.txt")
        editor = prompt.instance_variable_get(:@editor_state)

        prompt.send(:handle_editor_key, "2")
        prompt.send(:handle_editor_key, "j")
        assert_equal [2, 0], editor.cursor_line_and_column

        prompt.send(:handle_editor_key, "g")
        prompt.send(:handle_editor_key, "g")
        assert_equal [0, 0], editor.cursor_line_and_column

        prompt.send(:handle_editor_key, "G")
        assert_equal [2, 0], editor.cursor_line_and_column
      end
    end
  end

  def test_prompt_interface_vibe_mode_redo_restores_undone_change
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "notes.txt"), "alpha")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "vibe")
        assert prompt.send(:open_editor, "notes.txt")
        editor = prompt.instance_variable_get(:@editor_state)

        prompt.send(:handle_editor_key, "x")
        assert_equal "lpha", editor.buffer
        prompt.send(:handle_editor_key, "u")
        assert_equal "alpha", editor.buffer
        prompt.send(:handle_editor_key, "\x12")
        assert_equal "lpha", editor.buffer
      end
    end
  end

  def test_prompt_interface_vibe_mode_big_u_restores_current_line
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "notes.txt"), "alpha\nbeta")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "vibe")
        assert prompt.send(:open_editor, "notes.txt")
        editor = prompt.instance_variable_get(:@editor_state)
        editor.set_cursor_line_and_column(1, 0)

        prompt.send(:handle_editor_key, "C")
        "omega".each_char { |char| prompt.send(:handle_editor_key, char) }
        prompt.send(:handle_editor_key, "\e")
        assert_equal "alpha\nomega", editor.buffer

        prompt.send(:handle_editor_key, "U")
        assert_equal "alpha\nbeta", editor.buffer
      end
    end
  end

  def test_prompt_interface_vibe_mode_dot_repeats_last_simple_change
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "notes.txt"), "one two three")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "vibe")
        assert prompt.send(:open_editor, "notes.txt")
        editor = prompt.instance_variable_get(:@editor_state)

        prompt.send(:handle_editor_key, "c")
        prompt.send(:handle_editor_key, "w")
        "1".each_char { |char| prompt.send(:handle_editor_key, char) }
        prompt.send(:handle_editor_key, "\e")
        assert_equal "1 two three", editor.buffer

        editor.set_cursor_line_and_column(0, 2)
        prompt.send(:handle_editor_key, ".")
        assert_equal "1 1 three", editor.buffer
      end
    end
  end

  def test_prompt_interface_vibe_mode_big_p_pastes_before_cursor_or_current_line
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "notes.txt"), "one\ntwo\nthree")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "vibe")
        assert prompt.send(:open_editor, "notes.txt")
        editor = prompt.instance_variable_get(:@editor_state)
        editor.kill_buffer = "X"
        editor.set_cursor_line_and_column(1, 1)

        prompt.send(:handle_editor_key, "P")
        assert_equal "one\ntXwo\nthree", editor.buffer

        editor.kill_buffer = "zero\n"
        editor.set_cursor_line_and_column(2, 1)
        prompt.send(:handle_editor_key, "P")
        assert_equal "one\ntXwo\nzero\nthree", editor.buffer
      end
    end
  end

  def test_prompt_interface_vibe_mode_deletes_yanks_pastes_and_copies_clipboard
    output = StringIO.new
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "notes.txt"), "one\ntwo\nthree")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: output, editor_mode: "vibe")
        assert prompt.send(:open_editor, "notes.txt")
        editor = prompt.instance_variable_get(:@editor_state)

        prompt.send(:handle_editor_key, "y")
        prompt.send(:handle_editor_key, "y")
        assert_equal "one\n", editor.kill_buffer
        assert_includes output.string, "\e]52;c;#{Base64.strict_encode64("one\n")}\a"

        prompt.send(:handle_editor_key, "p")
        assert_equal "one\none\ntwo\nthree", editor.buffer

        prompt.send(:handle_editor_key, "d")
        prompt.send(:handle_editor_key, "d")
        assert_equal "one\ntwo\nthree", editor.buffer
      end
    end
  end

  def test_prompt_interface_vibe_mode_supports_operator_motion_and_undo
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "notes.txt"), "alpha beta")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "vibe")
        assert prompt.send(:open_editor, "notes.txt")
        editor = prompt.instance_variable_get(:@editor_state)

        prompt.send(:handle_editor_key, "d")
        prompt.send(:handle_editor_key, "w")
        assert_equal " beta", editor.buffer

        prompt.send(:handle_editor_key, "u")
        assert_equal "alpha beta", editor.buffer
      end
    end
  end

  def test_prompt_interface_vibe_mode_big_d_deletes_to_end_of_line
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "notes.txt"), "alpha beta\ngamma")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "vibe")
        assert prompt.send(:open_editor, "notes.txt")
        editor = prompt.instance_variable_get(:@editor_state)
        editor.set_cursor_line_and_column(0, 6)

        prompt.send(:handle_editor_key, "D")

        assert_equal "alpha \ngamma", editor.buffer
        assert_equal "beta", editor.kill_buffer
        assert_equal "normal", editor.vibe_mode

        prompt.send(:handle_editor_key, "u")
        assert_equal "alpha beta\ngamma", editor.buffer
      end
    end
  end

  def test_prompt_interface_vibe_mode_change_commands_enter_insert_mode
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "notes.txt"), "alpha beta\ngamma")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "vibe")
        assert prompt.send(:open_editor, "notes.txt")
        editor = prompt.instance_variable_get(:@editor_state)

        prompt.send(:handle_editor_key, "c")
        prompt.send(:handle_editor_key, "w")
        assert_equal "insert", editor.vibe_mode
        "omega".each_char { |char| prompt.send(:handle_editor_key, char) }
        prompt.send(:handle_editor_key, "\e")
        assert_equal "omega beta\ngamma", editor.buffer

        editor.set_cursor_line_and_column(0, 6)
        prompt.send(:handle_editor_key, "C")
        assert_equal "insert", editor.vibe_mode
        "delta".each_char { |char| prompt.send(:handle_editor_key, char) }
        prompt.send(:handle_editor_key, "\e")
        assert_equal "omega delta\ngamma", editor.buffer

        editor.set_cursor_line_and_column(1, 2)
        prompt.send(:handle_editor_key, "c")
        prompt.send(:handle_editor_key, "$")
        assert_equal "insert", editor.vibe_mode
        prompt.send(:handle_editor_key, "!")
        prompt.send(:handle_editor_key, "\e")
        assert_equal "omega delta\nga!", editor.buffer
      end
    end
  end

  def test_prompt_interface_vibe_mode_change_line_and_substitute_commands
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "notes.txt"), "alpha\nbeta\ngamma")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "vibe")
        assert prompt.send(:open_editor, "notes.txt")
        editor = prompt.instance_variable_get(:@editor_state)

        prompt.send(:handle_editor_key, "c")
        prompt.send(:handle_editor_key, "c")
        assert_equal "insert", editor.vibe_mode
        "one".each_char { |char| prompt.send(:handle_editor_key, char) }
        prompt.send(:handle_editor_key, "\e")
        assert_equal "one\nbeta\ngamma", editor.buffer

        editor.set_cursor_line_and_column(1, 0)
        prompt.send(:handle_editor_key, "S")
        "two".each_char { |char| prompt.send(:handle_editor_key, char) }
        prompt.send(:handle_editor_key, "\e")
        assert_equal "one\ntwo\ngamma", editor.buffer

        editor.set_cursor_line_and_column(2, 0)
        prompt.send(:handle_editor_key, "s")
        prompt.send(:handle_editor_key, "G")
        prompt.send(:handle_editor_key, "\e")
        assert_equal "one\ntwo\nGamma", editor.buffer
      end
    end
  end

  def test_prompt_interface_vibe_mode_replace_character_and_join_lines
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "notes.txt"), "alpha\n  beta\ngamma")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "vibe")
        assert prompt.send(:open_editor, "notes.txt")
        editor = prompt.instance_variable_get(:@editor_state)
        editor.set_cursor_line_and_column(0, 1)

        prompt.send(:handle_editor_key, "r")
        prompt.send(:handle_editor_key, "O")
        assert_equal "aOpha\n  beta\ngamma", editor.buffer
        assert_equal "normal", editor.vibe_mode

        editor.set_cursor_line_and_column(0, 2)
        prompt.send(:handle_editor_key, "2")
        prompt.send(:handle_editor_key, "r")
        prompt.send(:handle_editor_key, "x")
        assert_equal "aOxxa\n  beta\ngamma", editor.buffer

        prompt.send(:handle_editor_key, "g")
        prompt.send(:handle_editor_key, "g")
        prompt.send(:handle_editor_key, "J")
        assert_equal "aOxxa beta\ngamma", editor.buffer
      end
    end
  end

  def test_prompt_interface_vibe_mode_combines_operator_and_motion_counts
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "notes.txt"), "one two three four five")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "vibe")
        assert prompt.send(:open_editor, "notes.txt")
        editor = prompt.instance_variable_get(:@editor_state)

        prompt.send(:handle_editor_key, "2")
        prompt.send(:handle_editor_key, "d")
        prompt.send(:handle_editor_key, "2")
        prompt.send(:handle_editor_key, "w")

        assert_equal " five", editor.buffer
        assert_equal "one two three four", editor.kill_buffer
      end
    end
  end

  def test_prompt_interface_vibe_mode_combines_linewise_operator_counts
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "notes.txt"), "one\ntwo\nthree\nfour\nfive")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "vibe")
        assert prompt.send(:open_editor, "notes.txt")
        editor = prompt.instance_variable_get(:@editor_state)

        prompt.send(:handle_editor_key, "2")
        prompt.send(:handle_editor_key, "d")
        prompt.send(:handle_editor_key, "2")
        prompt.send(:handle_editor_key, "d")

        assert_equal "five", editor.buffer
        assert_equal "one\ntwo\nthree\nfour\n", editor.kill_buffer
      end
    end
  end

  def test_prompt_interface_vibe_mode_supports_colon_commands
    Dir.mktmpdir do |dir|
      path = File.join(dir, "notes.txt")
      File.write(path, "one\ntwo")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "vibe")
        assert prompt.send(:open_editor, "notes.txt")
        editor = prompt.instance_variable_get(:@editor_state)
        prompt.send(:handle_editor_key, ":")
        prompt.send(:handle_editor_key, "2")
        prompt.send(:handle_editor_key, "\r")
        assert_equal [1, 0], editor.cursor_line_and_column

        prompt.send(:handle_editor_key, "i")
        prompt.send(:handle_editor_key, "!")
        prompt.send(:handle_editor_key, "\e")
        prompt.send(:handle_editor_key, ":")
        prompt.send(:handle_editor_key, "w")
        prompt.send(:handle_editor_key, "q")
        prompt.send(:handle_editor_key, "\r")

        refute prompt.send(:editor_active?)
        assert_equal "one\n!two", File.read(path)
      end
    end
  end

  def test_prompt_interface_vibe_mode_refuses_dirty_q_and_allows_q_bang
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "notes.txt"), "alpha")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "vibe")
        assert prompt.send(:open_editor, "notes.txt")
        editor = prompt.instance_variable_get(:@editor_state)
        prompt.send(:handle_editor_key, "i")
        prompt.send(:handle_editor_key, "!")
        prompt.send(:handle_editor_key, "\e")

        prompt.send(:handle_editor_key, ":")
        prompt.send(:handle_editor_key, "q")
        prompt.send(:handle_editor_key, "\r")
        assert prompt.send(:editor_active?)
        assert_equal "No write since last change (:q! overrides)", editor.status

        prompt.send(:handle_editor_key, ":")
        prompt.send(:handle_editor_key, "q")
        prompt.send(:handle_editor_key, "!")
        prompt.send(:handle_editor_key, "\r")
        refute prompt.send(:editor_active?)
      end
    end
  end

  def test_prompt_interface_vibe_mode_disables_default_shortcuts_and_selection
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "notes.txt"), "alpha")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "vibe")
        assert prompt.send(:open_editor, "notes.txt")
        editor = prompt.instance_variable_get(:@editor_state)

        prompt.send(:handle_editor_key, "\x18")
        prompt.send(:handle_editor_key, "\x03")
        assert prompt.send(:editor_active?)

        prompt.send(:handle_editor_key, "\x00")
        prompt.send(:handle_editor_key, "\e[1;2C")
        refute editor.selection_active?
      end
    end
  end

  def test_prompt_interface_vibe_insert_auto_closes_pairs
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "vibe")
    editor = Kward::PromptInterface::EditorState.new(path: "test.rb", content: "", editor_mode: "vibe")
    prompt.instance_variable_set(:@editor_state, editor)

    prompt.send(:handle_editor_key, "i")
    prompt.send(:handle_editor_key, "(")

    assert_equal "()", editor.buffer
    assert_equal 1, editor.cursor
  end

  def test_prompt_interface_vibe_replace_auto_closes_pairs
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "vibe")
    editor = Kward::PromptInterface::EditorState.new(path: "test.rb", content: "x", editor_mode: "vibe")
    prompt.instance_variable_set(:@editor_state, editor)

    prompt.send(:handle_editor_key, "R")
    prompt.send(:handle_editor_key, "[")

    assert_equal "[]", editor.buffer
    assert_equal 1, editor.cursor
  end

end
