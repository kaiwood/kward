require_relative "../test_helper"

class TestPromptInterfaceEditorVibeVisual < KwardTestCase
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

  def test_prompt_interface_vibe_mode_visual_o_switches_selection_end
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "notes.txt"), "alpha beta")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "vibe")
        assert prompt.send(:open_editor, "notes.txt")
        editor = prompt.instance_variable_get(:@editor_state)

        prompt.send(:handle_editor_key, "v")
        5.times { prompt.send(:handle_editor_key, "l") }
        assert_equal "alpha ", editor.selected_text

        prompt.send(:handle_editor_key, "o")
        prompt.send(:handle_editor_key, "l")

        assert_equal "lpha ", editor.selected_text
        assert_equal 1, editor.cursor
        assert_equal 5, editor.selection_anchor
      end
    end
  end

  def test_prompt_interface_vibe_mode_visual_block_inserts_and_appends_text
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "notes.txt"), "one\ntwo\nthree")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "vibe")
        assert prompt.send(:open_editor, "notes.txt")
        editor = prompt.instance_variable_get(:@editor_state)

        prompt.send(:handle_editor_key, "\x16")
        2.times { prompt.send(:handle_editor_key, "j") }
        prompt.send(:handle_editor_key, "I")
        "# ".each_char { |char| prompt.send(:handle_editor_key, char) }
        prompt.send(:handle_editor_key, "\e")
        assert_equal "# one\n# two\n# three", editor.buffer

        editor.buffer = "one\ntwo\nthree"
        editor.cursor = 0
        editor.set_cursor_line_and_column(0, 2)
        prompt.send(:handle_editor_key, "\x16")
        prompt.send(:handle_editor_key, "j")
        prompt.send(:handle_editor_key, "A")
        "!".each_char { |char| prompt.send(:handle_editor_key, char) }
        prompt.send(:handle_editor_key, "\e")
        assert_equal "one!\ntwo!\nthree", editor.buffer
      end
    end
  end

  def test_prompt_interface_vibe_mode_visual_block_yanks_and_deletes_rectangle
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "notes.txt"), "abcd\nefgh\nijkl")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "vibe")
        assert prompt.send(:open_editor, "notes.txt")
        editor = prompt.instance_variable_get(:@editor_state)
        editor.set_cursor_line_and_column(0, 1)

        prompt.send(:handle_editor_key, "\x16")
        prompt.send(:handle_editor_key, "j")
        prompt.send(:handle_editor_key, "l")
        assert_equal "visual_block", editor.vibe_mode
        assert_equal "bc\nfg", editor.selected_text

        prompt.send(:handle_editor_key, "y")
        assert_equal "normal", editor.vibe_mode
        assert_equal "bc\nfg", editor.kill_buffer

        editor.set_cursor_line_and_column(0, 1)
        prompt.send(:handle_editor_key, "\x16")
        prompt.send(:handle_editor_key, "j")
        prompt.send(:handle_editor_key, "l")
        prompt.send(:handle_editor_key, "d")
        assert_equal "ad\neh\nijkl", editor.buffer
        assert_equal "bc\nfg", editor.kill_buffer
      end
    end
  end

  def test_prompt_interface_vibe_mode_visual_search_extends_selection
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "notes.txt"), "alpha gamma beta gamma")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "vibe")
        assert prompt.send(:open_editor, "notes.txt")
        editor = prompt.instance_variable_get(:@editor_state)

        prompt.send(:handle_editor_key, "v")
        prompt.send(:handle_editor_key, "/")
        "gamma".each_char { |char| prompt.send(:handle_editor_key, char) }
        prompt.send(:handle_editor_key, "\r")

        assert_equal "visual", editor.vibe_mode
        assert_equal editor.buffer.index("gamma"), editor.cursor
        assert_equal "alpha g", editor.selected_text

        prompt.send(:handle_editor_key, "n")
        assert_equal editor.buffer.rindex("gamma"), editor.cursor
        assert_equal "alpha gamma beta g", editor.selected_text
      end
    end
  end

  def test_prompt_interface_vibe_mode_visual_transforms_case
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "notes.txt"), "Alpha BETA")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "vibe")
        assert prompt.send(:open_editor, "notes.txt")
        editor = prompt.instance_variable_get(:@editor_state)

        prompt.send(:handle_editor_key, "v")
        4.times { prompt.send(:handle_editor_key, "l") }
        prompt.send(:handle_editor_key, "u")
        assert_equal "alpha BETA", editor.buffer

        prompt.send(:handle_editor_key, "u")
        editor.cursor = 0
        prompt.send(:handle_editor_key, "v")
        4.times { prompt.send(:handle_editor_key, "l") }
        prompt.send(:handle_editor_key, "U")
        assert_equal "ALPHA BETA", editor.buffer

        prompt.send(:handle_editor_key, "u")
        editor.cursor = 0
        prompt.send(:handle_editor_key, "v")
        4.times { prompt.send(:handle_editor_key, "l") }
        prompt.send(:handle_editor_key, "~")
        assert_equal "aLPHA BETA", editor.buffer
      end
    end
  end

  def test_prompt_interface_vibe_mode_visual_joins_selected_lines
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "notes.txt"), "one\n  two\nthree")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "vibe")
        assert prompt.send(:open_editor, "notes.txt")
        editor = prompt.instance_variable_get(:@editor_state)

        prompt.send(:handle_editor_key, "V")
        prompt.send(:handle_editor_key, "j")
        prompt.send(:handle_editor_key, "J")

        assert_equal "one two\nthree", editor.buffer
        assert_equal "normal", editor.vibe_mode

        prompt.send(:handle_editor_key, "u")

        assert_equal "one\n  two\nthree", editor.buffer
        assert_equal "normal", editor.vibe_mode
        refute editor.selection_active?
      end
    end
  end

  def test_prompt_interface_vibe_mode_gv_restores_last_visual_selection
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "notes.txt"), "alpha beta")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "vibe")
        assert prompt.send(:open_editor, "notes.txt")
        editor = prompt.instance_variable_get(:@editor_state)

        prompt.send(:handle_editor_key, "v")
        4.times { prompt.send(:handle_editor_key, "l") }
        prompt.send(:handle_editor_key, "y")
        assert_equal "normal", editor.vibe_mode

        editor.cursor = editor.buffer.length
        prompt.send(:handle_editor_key, "g")
        prompt.send(:handle_editor_key, "v")

        assert_equal "visual", editor.vibe_mode
        assert_equal "alpha", editor.selected_text
      end
    end
  end

  def test_prompt_interface_vibe_mode_visual_indents_selected_lines
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "notes.rb"), "one\ntwo\nthree")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "vibe")
        assert prompt.send(:open_editor, "notes.rb")
        editor = prompt.instance_variable_get(:@editor_state)

        prompt.send(:handle_editor_key, "V")
        prompt.send(:handle_editor_key, "j")
        prompt.send(:handle_editor_key, ">")
        assert_equal "  one\n  two\nthree", editor.buffer
        assert_equal "normal", editor.vibe_mode

        prompt.send(:handle_editor_key, "u")
        prompt.send(:handle_editor_key, "V")
        prompt.send(:handle_editor_key, "j")
        prompt.send(:handle_editor_key, ">")
        prompt.send(:handle_editor_key, "V")
        prompt.send(:handle_editor_key, "j")
        prompt.send(:handle_editor_key, "<")
        assert_equal "one\ntwo\nthree", editor.buffer
      end
    end
  end

  def test_prompt_interface_vibe_mode_visual_text_objects_select_targets
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "notes.rb"), "call(alpha, beta)\n\ndef block\n  puts :ok\nend")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "vibe")
        assert prompt.send(:open_editor, "notes.rb")
        editor = prompt.instance_variable_get(:@editor_state)
        editor.cursor = editor.buffer.index("alpha") + 1

        prompt.send(:handle_editor_key, "v")
        prompt.send(:handle_editor_key, "i")
        prompt.send(:handle_editor_key, "w")
        assert_equal "alpha", editor.selected_text

        prompt.send(:handle_editor_key, "a")
        prompt.send(:handle_editor_key, "(")
        assert_equal "(alpha, beta)", editor.selected_text

        prompt.send(:handle_editor_key, "\e")
        editor.cursor = editor.buffer.index("puts")
        prompt.send(:handle_editor_key, "v")
        prompt.send(:handle_editor_key, "i")
        prompt.send(:handle_editor_key, "r")
        assert_equal "  puts :ok\n", editor.selected_text
      end
    end
  end

  def test_prompt_interface_vibe_mode_visual_advanced_motions_extend_selection
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "notes.txt"), "call(alpha)\ntwo\nthree")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "vibe")
        assert prompt.send(:open_editor, "notes.txt")
        editor = prompt.instance_variable_get(:@editor_state)
        editor.cursor = editor.buffer.index("(")

        prompt.send(:handle_editor_key, "v")
        prompt.send(:handle_editor_key, "%")
        assert_equal "(alpha)", editor.selected_text

        prompt.send(:handle_editor_key, "\e")
        editor.cursor = 0
        prompt.send(:handle_editor_key, "v")
        prompt.send(:handle_editor_key, "f")
        prompt.send(:handle_editor_key, "a")
        assert_equal "ca", editor.selected_text
        prompt.send(:handle_editor_key, ";")
        assert_equal "call(a", editor.selected_text
        prompt.send(:handle_editor_key, ",")
        assert_equal "ca", editor.selected_text

        prompt.send(:handle_editor_key, "\e")
        editor.set_cursor_line_and_column(2, 0)
        prompt.send(:handle_editor_key, "v")
        prompt.send(:handle_editor_key, "g")
        prompt.send(:handle_editor_key, "g")
        assert_equal [0, 0], editor.cursor_line_and_column
      end
    end
  end

  def test_prompt_interface_vibe_mode_visual_counts_extend_selection
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "notes.txt"), "one\ntwo\nthree\nfour")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "vibe")
        assert prompt.send(:open_editor, "notes.txt")
        editor = prompt.instance_variable_get(:@editor_state)

        prompt.send(:handle_editor_key, "v")
        prompt.send(:handle_editor_key, "2")
        assert_equal "2", editor.vibe_pending
        prompt.send(:handle_editor_key, "j")
        assert_equal [2, 0], editor.cursor_line_and_column
        assert_equal "", editor.vibe_pending

        prompt.send(:handle_editor_key, "\e")
        editor.set_cursor_line_and_column(0, 0)
        prompt.send(:handle_editor_key, "v")
        prompt.send(:handle_editor_key, "3")
        prompt.send(:handle_editor_key, "G")
        assert_equal [2, 0], editor.cursor_line_and_column
      end
    end
  end

  def test_prompt_interface_vibe_mode_visual_g_extends_to_last_line
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "notes.txt"), "one\ntwo\nthree")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "vibe")
        assert prompt.send(:open_editor, "notes.txt")
        editor = prompt.instance_variable_get(:@editor_state)

        prompt.send(:handle_editor_key, "v")
        prompt.send(:handle_editor_key, "G")
        assert_equal [2, 0], editor.cursor_line_and_column
        assert_equal "one\ntwo\nt", editor.selected_text

        prompt.send(:handle_editor_key, "\e")
        editor.set_cursor_line_and_column(0, 0)
        prompt.send(:handle_editor_key, "V")
        prompt.send(:handle_editor_key, "G")
        assert_equal "one\ntwo\nthree", editor.selected_text
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

end
