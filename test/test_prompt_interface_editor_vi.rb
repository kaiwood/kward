require_relative "test_helper"

class TestPromptInterfaceEditorVi < KwardTestCase
  def test_prompt_interface_vi_mode_allows_ctrl_number_tab_switching
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "vi", tab_keybindings: "ctrl")
    prompt.instance_variable_set(:@tabs, [Object.new, Object.new])
    prompt.instance_variable_set(:@editor_state, Kward::PromptInterface::EditorState.new(path: "notes.txt", content: "alpha", editor_mode: "vi"))

    assert_equal({ tab_action: :select, index: 0 }, prompt.send(:handle_key, "\e[49;5u"))
    assert_equal({ tab_action: :select, index: 1 }, prompt.send(:handle_key, "\e[50;5u"))
  end

  def test_prompt_interface_vi_mode_opens_in_normal_mode_and_requires_insert
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "notes.txt"), "alpha")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "vi")
        assert prompt.send(:open_editor, "notes.txt")
        editor = prompt.instance_variable_get(:@editor_state)

        assert_equal "vi", editor.editor_mode
        assert_equal "normal", editor.vi_mode
        prompt.send(:handle_editor_key, "z")
        assert_equal "alpha", editor.buffer

        prompt.send(:handle_editor_key, "i")
        prompt.send(:handle_editor_key, "z")
        prompt.send(:handle_editor_key, "\e")

        assert_equal "zalpha", editor.buffer
        assert_equal "normal", editor.vi_mode
      end
    end
  end

  def test_prompt_interface_vi_mode_e_moves_to_end_of_word
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "notes.txt"), "alpha beta gamma")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "vi")
        assert prompt.send(:open_editor, "notes.txt")
        editor = prompt.instance_variable_get(:@editor_state)

        prompt.send(:handle_editor_key, "e")
        assert_equal 4, editor.cursor

        prompt.send(:handle_editor_key, "e")
        assert_equal 9, editor.cursor
      end
    end
  end

  def test_prompt_interface_vi_mode_e_works_as_operator_motion
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "notes.txt"), "alpha beta")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "vi")
        assert prompt.send(:open_editor, "notes.txt")
        editor = prompt.instance_variable_get(:@editor_state)

        prompt.send(:handle_editor_key, "d")
        prompt.send(:handle_editor_key, "e")

        assert_equal " beta", editor.buffer
        assert_equal "alpha", editor.kill_buffer
      end
    end
  end

  def test_prompt_interface_vi_mode_dd_deletes_final_empty_line
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "notes.txt"), "one\ntwo\n")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "vi")
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

  def test_prompt_interface_vi_mode_dd_deletes_final_non_empty_line
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "notes.txt"), "one\ntwo")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "vi")
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

  def test_prompt_interface_vi_mode_big_i_and_big_a_insert_at_line_edges
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "notes.txt"), "alpha\nbeta")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "vi")
        assert prompt.send(:open_editor, "notes.txt")
        editor = prompt.instance_variable_get(:@editor_state)
        editor.set_cursor_line_and_column(1, 2)

        prompt.send(:handle_editor_key, "I")
        assert_equal "insert", editor.vi_mode
        prompt.send(:handle_editor_key, "!")
        prompt.send(:handle_editor_key, "\e")
        assert_equal "alpha\n!beta", editor.buffer

        prompt.send(:handle_editor_key, "A")
        assert_equal "insert", editor.vi_mode
        prompt.send(:handle_editor_key, "?")
        prompt.send(:handle_editor_key, "\e")
        assert_equal "alpha\n!beta?", editor.buffer
      end
    end
  end

  def test_prompt_interface_vi_mode_named_escape_and_ctrl_c_return_to_normal_mode
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "notes.txt"), "alpha")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "vi")
        assert prompt.send(:open_editor, "notes.txt")
        editor = prompt.instance_variable_get(:@editor_state)

        prompt.send(:handle_editor_key, "i")
        assert_equal "insert", editor.vi_mode
        prompt.send(:handle_editor_key, :escape)
        assert_equal "normal", editor.vi_mode

        prompt.send(:handle_editor_key, "i")
        assert_equal "insert", editor.vi_mode
        prompt.send(:handle_editor_key, "\x03")
        assert_equal "normal", editor.vi_mode
      end
    end
  end

  def test_prompt_interface_vi_mode_csi_u_escape_and_ctrl_c_return_to_normal_mode
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "notes.txt"), "alpha")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "vi")
        assert prompt.send(:open_editor, "notes.txt")
        editor = prompt.instance_variable_get(:@editor_state)

        prompt.send(:handle_editor_key, "i")
        assert_equal "insert", editor.vi_mode
        prompt.send(:handle_editor_key, "\e[27u")
        assert_equal "normal", editor.vi_mode

        prompt.send(:handle_editor_key, "i")
        assert_equal "insert", editor.vi_mode
        prompt.send(:handle_editor_key, "\e[27;1u")
        assert_equal "normal", editor.vi_mode

        prompt.send(:handle_editor_key, "i")
        assert_equal "insert", editor.vi_mode
        prompt.send(:handle_editor_key, "\e[99;5u")
        assert_equal "normal", editor.vi_mode
      end
    end
  end

  def test_prompt_interface_vi_mode_escape_and_ctrl_c_cancel_command_mode
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "notes.txt"), "alpha")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "vi")
        assert prompt.send(:open_editor, "notes.txt")
        editor = prompt.instance_variable_get(:@editor_state)

        prompt.send(:handle_editor_key, ":")
        prompt.send(:handle_editor_key, "w")
        prompt.send(:handle_editor_key, :escape)
        assert_equal "normal", editor.vi_mode
        assert_equal "", editor.vi_command

        prompt.send(:handle_editor_key, ":")
        prompt.send(:handle_editor_key, "q")
        prompt.send(:handle_editor_key, "\x03")
        assert_equal "normal", editor.vi_mode
        assert_equal "", editor.vi_command
      end
    end
  end

  def test_prompt_interface_vi_mode_visual_yanks_character_selection_to_clipboard
    output = StringIO.new
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "notes.txt"), "alpha beta")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: output, editor_mode: "vi")
        assert prompt.send(:open_editor, "notes.txt")
        editor = prompt.instance_variable_get(:@editor_state)

        prompt.send(:handle_editor_key, "v")
        5.times { prompt.send(:handle_editor_key, "l") }
        assert_equal "visual", editor.vi_mode
        assert_equal "alpha", editor.selected_text

        prompt.send(:handle_editor_key, "y")

        assert_equal "normal", editor.vi_mode
        refute editor.selection_active?
        assert_equal "alpha", editor.kill_buffer
        assert_includes output.string, "\e]52;c;#{Base64.strict_encode64("alpha")}\a"
      end
    end
  end

  def test_prompt_interface_vi_mode_visual_line_yanks_full_lines
    output = StringIO.new
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "notes.txt"), "one\ntwo\nthree")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: output, editor_mode: "vi")
        assert prompt.send(:open_editor, "notes.txt")
        editor = prompt.instance_variable_get(:@editor_state)

        prompt.send(:handle_editor_key, "V")
        prompt.send(:handle_editor_key, "j")
        assert_equal "visual_line", editor.vi_mode
        assert_equal "one\ntwo\n", editor.selected_text

        prompt.send(:handle_editor_key, "y")

        assert_equal "normal", editor.vi_mode
        assert_equal "one\ntwo\n", editor.kill_buffer
        assert_includes output.string, "\e]52;c;#{Base64.strict_encode64("one\ntwo\n")}\a"
      end
    end
  end

  def test_prompt_interface_vi_mode_visual_delete_change_paste_and_undo
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "notes.txt"), "alpha beta")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "vi")
        assert prompt.send(:open_editor, "notes.txt")
        editor = prompt.instance_variable_get(:@editor_state)

        prompt.send(:handle_editor_key, "v")
        5.times { prompt.send(:handle_editor_key, "l") }
        prompt.send(:handle_editor_key, "d")
        assert_equal " beta", editor.buffer
        prompt.send(:handle_editor_key, "u")
        assert_equal "alpha beta", editor.buffer

        editor.set_cursor_line_and_column(0, 0)
        prompt.send(:handle_editor_key, "v")
        5.times { prompt.send(:handle_editor_key, "l") }
        prompt.send(:handle_editor_key, "c")
        assert_equal "insert", editor.vi_mode
        prompt.send(:handle_editor_key, "A")
        prompt.send(:handle_editor_key, "\e")
        assert_equal "A beta", editor.buffer

        editor.set_cursor_line_and_column(0, 0)
        editor.kill_buffer = "omega"
        prompt.send(:handle_editor_key, "v")
        prompt.send(:handle_editor_key, "l")
        prompt.send(:handle_editor_key, "p")
        assert_equal "omega beta", editor.buffer
      end
    end
  end

  def test_prompt_interface_vi_mode_visual_escape_clears_selection
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "notes.txt"), "alpha")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "vi")
        assert prompt.send(:open_editor, "notes.txt")
        editor = prompt.instance_variable_get(:@editor_state)

        prompt.send(:handle_editor_key, "v")
        prompt.send(:handle_editor_key, "l")
        assert editor.selection_active?
        prompt.send(:handle_editor_key, "\e")

        assert_equal "normal", editor.vi_mode
        refute editor.selection_active?
      end
    end
  end

  def test_prompt_interface_vi_mode_supports_counts_and_navigation
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "notes.txt"), "one\ntwo\nthree")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "vi")
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

  def test_prompt_interface_vi_mode_deletes_yanks_pastes_and_copies_clipboard
    output = StringIO.new
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "notes.txt"), "one\ntwo\nthree")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: output, editor_mode: "vi")
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

  def test_prompt_interface_vi_mode_supports_operator_motion_and_undo
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "notes.txt"), "alpha beta")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "vi")
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

  def test_prompt_interface_vi_mode_supports_colon_commands
    Dir.mktmpdir do |dir|
      path = File.join(dir, "notes.txt")
      File.write(path, "one\ntwo")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "vi")
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

  def test_prompt_interface_vi_mode_refuses_dirty_q_and_allows_q_bang
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "notes.txt"), "alpha")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "vi")
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

  def test_prompt_interface_vi_mode_disables_default_shortcuts_and_selection
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "notes.txt"), "alpha")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "vi")
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

end
