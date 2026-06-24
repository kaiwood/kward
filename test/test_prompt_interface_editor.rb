require_relative "test_helper"

class TestPromptInterfaceEditor < KwardTestCase
  def test_prompt_interface_diff_viewer_is_read_only_and_closes_with_escape
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "modern")
    assert prompt.send(:open_diff_viewer, "notes.txt", "-old\n+new\n")
    editor = prompt.instance_variable_get(:@editor_state)

    prompt.send(:handle_editor_key, "x")

    assert_equal "-old\n+new\n", editor.buffer
    assert_equal "Read-only diff", editor.status

    prompt.send(:handle_editor_key, "\e")

    refute prompt.send(:editor_active?)
  end

  def test_prompt_interface_diff_viewer_colors_added_and_removed_lines
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "modern")
    prompt.instance_variable_set(:@color_enabled, true)
    assert prompt.send(:open_diff_viewer, "notes.txt", "-old\n+new\n")

    assert_includes prompt.send(:editor_render_diff_line, "+new"), "\e[32m+new\e[0m"
    assert_includes prompt.send(:editor_render_diff_line, "-old"), "\e[31m-old\e[0m"
  end

  def test_prompt_interface_modern_ctrl_s_saves_file
    Dir.mktmpdir do |dir|
      path = File.join(dir, "notes.txt")
      File.write(path, "hello")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "modern")
        assert prompt.send(:open_editor, "notes.txt")

        prompt.send(:handle_editor_key, "!")
        prompt.send(:handle_editor_key, "\x13")

        assert_equal "!hello", File.read(path)
      end
    end
  end

  def test_prompt_interface_modern_ctrl_q_closes_clean_editor
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "notes.txt"), "hello")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "modern")
        assert prompt.send(:open_editor, "notes.txt")

        prompt.send(:handle_editor_key, "\x11")

        refute prompt.send(:editor_active?)
      end
    end
  end

  def test_prompt_interface_modern_slash_starts_search
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "notes.txt"), "alpha\nbeta")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "modern")
        assert prompt.send(:open_editor, "notes.txt")

        prompt.send(:handle_editor_key, "/")

        editor = prompt.instance_variable_get(:@editor_state)
        assert editor.search_active
        assert_equal :forward, editor.search_direction
        assert_equal "Search:", editor.status
      end
    end
  end

  def test_prompt_interface_modern_question_mark_starts_reverse_search
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "notes.txt"), "alpha\nbeta")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "modern")
        assert prompt.send(:open_editor, "notes.txt")

        prompt.send(:handle_editor_key, "?")

        editor = prompt.instance_variable_get(:@editor_state)
        assert editor.search_active
        assert_equal :backward, editor.search_direction
        assert_equal "Search backward:", editor.status
      end
    end
  end

  def test_prompt_interface_modern_ctrl_f_moves_right
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "notes.txt"), "hello")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "modern")
        assert prompt.send(:open_editor, "notes.txt")

        prompt.send(:handle_editor_key, "\x06")

        editor = prompt.instance_variable_get(:@editor_state)
        refute editor.search_active
        assert_equal 1, editor.cursor
      end
    end
  end

  def test_prompt_interface_modern_csi_u_ctrl_f_moves_right
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "notes.txt"), "hello")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "modern")
        assert prompt.send(:open_editor, "notes.txt")

        prompt.send(:handle_editor_key, "\e[102;5u")

        editor = prompt.instance_variable_get(:@editor_state)
        refute editor.search_active
        assert_equal 1, editor.cursor
      end
    end
  end

  def test_prompt_interface_modern_accepts_csi_u_shifted_text
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "notes.txt"), "hello")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "modern")
        assert prompt.send(:open_editor, "notes.txt")

        prompt.send(:handle_editor_key, "\e[97;2;65u")

        editor = prompt.instance_variable_get(:@editor_state)
        assert_equal "Ahello", editor.buffer
      end
    end
  end

  def test_prompt_interface_modern_undoes_csi_u_shifted_text
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "notes.txt"), "hello")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "modern")
        assert prompt.send(:open_editor, "notes.txt")
        editor = prompt.instance_variable_get(:@editor_state)

        prompt.send(:handle_editor_key, "\e[97;2;65u")
        prompt.send(:handle_editor_key, "\x1A")

        assert_equal "hello", editor.buffer
      end
    end
  end

  def test_prompt_interface_emacs_accepts_csi_u_shifted_text
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "notes.txt"), "hello")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs")
        assert prompt.send(:open_editor, "notes.txt")

        prompt.send(:handle_editor_key, "\e[97;2;65u")

        editor = prompt.instance_variable_get(:@editor_state)
        assert_equal "Ahello", editor.buffer
      end
    end
  end

  def test_prompt_interface_vibe_insert_accepts_csi_u_shifted_text
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "notes.txt"), "hello")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "vibe")
        assert prompt.send(:open_editor, "notes.txt")
        prompt.send(:handle_editor_key, "i")

        prompt.send(:handle_editor_key, "\e[97;2;65u")

        editor = prompt.instance_variable_get(:@editor_state)
        assert_equal "Ahello", editor.buffer
      end
    end
  end

  def test_prompt_interface_vibe_normal_ignores_csi_u_shifted_text
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "notes.txt"), "hello")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "vibe")
        assert prompt.send(:open_editor, "notes.txt")

        prompt.send(:handle_editor_key, "\e[97;2;65u")

        editor = prompt.instance_variable_get(:@editor_state)
        assert_equal "hello", editor.buffer
      end
    end
  end

  def test_prompt_interface_modern_ctrl_c_copies_selection
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "notes.txt"), "hello world")
      Dir.chdir(dir) do
        output = StringIO.new
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: output, editor_mode: "modern")
        assert prompt.send(:open_editor, "notes.txt")
        editor = prompt.instance_variable_get(:@editor_state)
        editor.selection_anchor = 0
        editor.cursor = 5

        prompt.send(:handle_editor_key, "\x03")

        assert_equal "hello", editor.kill_buffer
        assert_equal "Copied selection", editor.status
        refute editor.selection_active?
        assert_includes output.string, "\e]52;c;#{Base64.strict_encode64("hello")}\a"
      end
    end
  end

  def test_prompt_interface_modern_csi_u_cmd_c_copies_selection
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "notes.txt"), "hello world")
      Dir.chdir(dir) do
        output = StringIO.new
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: output, editor_mode: "modern")
        assert prompt.send(:open_editor, "notes.txt")
        editor = prompt.instance_variable_get(:@editor_state)
        editor.selection_anchor = 6
        editor.cursor = 11

        prompt.send(:handle_editor_key, "\e[99;9u")

        assert_equal "world", editor.kill_buffer
        assert_equal "Copied selection", editor.status
        refute editor.selection_active?
        assert_includes output.string, "\e]52;c;#{Base64.strict_encode64("world")}\a"
      end
    end
  end

  def test_prompt_interface_editor_auto_indent_copies_plain_text_indent
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "notes.txt"), "  alpha")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "modern")
        assert prompt.send(:open_editor, "notes.txt")
        editor = prompt.instance_variable_get(:@editor_state)
        editor.cursor = editor.buffer.length

        prompt.send(:handle_editor_key, "\n")

        assert_equal "  alpha\n  ", editor.buffer
      end
    end
  end

  def test_prompt_interface_editor_auto_indent_uses_ruby_syntax_and_detected_width
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "example.rb"), "class Example\n    attr_reader :name\n  def call")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "modern")
        assert prompt.send(:open_editor, "example.rb")
        editor = prompt.instance_variable_get(:@editor_state)
        editor.cursor = editor.buffer.length

        prompt.send(:handle_editor_key, "\n")

        assert_equal "class Example\n    attr_reader :name\n  def call\n    ", editor.buffer
      end
    end
  end

  def test_prompt_interface_editor_auto_indent_uses_tabs_when_detected
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "example.js"), "function test() {\n\treturn true;\nif (ready) {")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "modern")
        assert prompt.send(:open_editor, "example.js")
        editor = prompt.instance_variable_get(:@editor_state)
        editor.cursor = editor.buffer.length

        prompt.send(:handle_editor_key, "\n")

        assert_equal "function test() {\n\treturn true;\nif (ready) {\n\t", editor.buffer
      end
    end
  end

  def test_prompt_interface_editor_auto_indent_can_be_disabled
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "notes.txt"), "  alpha")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "modern", editor_auto_indent: false)
        assert prompt.send(:open_editor, "notes.txt")
        editor = prompt.instance_variable_get(:@editor_state)
        editor.cursor = editor.buffer.length

        prompt.send(:handle_editor_key, "\n")

        assert_equal "  alpha\n", editor.buffer
      end
    end
  end

  def test_prompt_interface_editor_reindents_javascript_closing_brace_before_insert
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "example.js"), "function test() {\n  if (ready) {\n    ")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "modern")
        assert prompt.send(:open_editor, "example.js")
        editor = prompt.instance_variable_get(:@editor_state)
        editor.cursor = editor.buffer.length

        prompt.send(:handle_editor_key, "}")

        assert_equal "function test() {\n  if (ready) {\n  }", editor.buffer
        assert_equal [2, 3], editor.cursor_line_and_column
      end
    end
  end

  def test_prompt_interface_editor_reindents_ruby_end_after_word_completion
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "example.rb"), "class Example\n  def call\n    en")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "modern")
        assert prompt.send(:open_editor, "example.rb")
        editor = prompt.instance_variable_get(:@editor_state)
        editor.cursor = editor.buffer.length

        prompt.send(:handle_editor_key, "d")

        assert_equal "class Example\n  def call\n  end", editor.buffer
        assert_equal [2, 5], editor.cursor_line_and_column
      end
    end
  end

  def test_prompt_interface_editor_reindents_lua_end_and_shell_done
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "script.lua"), "function call()\n  en")
      File.write(File.join(dir, "script.sh"), "while true\ndo\n  don")
      Dir.chdir(dir) do
        lua_prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "modern")
        assert lua_prompt.send(:open_editor, "script.lua")
        lua_editor = lua_prompt.instance_variable_get(:@editor_state)
        lua_editor.cursor = lua_editor.buffer.length
        lua_prompt.send(:handle_editor_key, "d")
        assert_equal "function call()\nend", lua_editor.buffer

        shell_prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "modern")
        assert shell_prompt.send(:open_editor, "script.sh")
        shell_editor = shell_prompt.instance_variable_get(:@editor_state)
        shell_editor.cursor = shell_editor.buffer.length
        shell_prompt.send(:handle_editor_key, "e")
        assert_equal "while true\ndo\ndone", shell_editor.buffer
      end
    end
  end

  def test_prompt_interface_editor_smart_backspace_deletes_detected_indent_unit
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "example.rb"), "class Example\n  def call\n    attr_reader :name\n  ")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "modern")
        assert prompt.send(:open_editor, "example.rb")
        editor = prompt.instance_variable_get(:@editor_state)
        editor.cursor = editor.buffer.length

        prompt.send(:handle_editor_key, "\b")

        assert_equal "class Example\n  def call\n    attr_reader :name\n", editor.buffer
      end
    end
  end

  def test_prompt_interface_editor_smart_backspace_is_disabled_with_auto_indent
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "example.rb"), "class Example\n  def call\n    attr_reader :name\n  ")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "modern", editor_auto_indent: false)
        assert prompt.send(:open_editor, "example.rb")
        editor = prompt.instance_variable_get(:@editor_state)
        editor.cursor = editor.buffer.length

        prompt.send(:handle_editor_key, "\b")

        assert_equal "class Example\n  def call\n    attr_reader :name\n ", editor.buffer
      end
    end
  end

  def test_prompt_interface_editor_reindent_and_closer_insert_undo_together
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "example.js"), "function test() {\n  if (ready) {\n    ")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "modern")
        assert prompt.send(:open_editor, "example.js")
        editor = prompt.instance_variable_get(:@editor_state)
        editor.cursor = editor.buffer.length

        prompt.send(:handle_editor_key, "}")
        prompt.send(:handle_editor_key, "\x1A")

        assert_equal "function test() {\n  if (ready) {\n    ", editor.buffer
      end
    end
  end

  def test_prompt_interface_modern_uses_shift_selection_and_clipboard_shortcuts
    output = StringIO.new
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "notes.txt"), "alpha")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: output, editor_mode: "modern")
        assert prompt.send(:open_editor, "notes.txt")
        editor = prompt.instance_variable_get(:@editor_state)

        3.times { prompt.send(:handle_editor_key, "\e[1;2C") }
        prompt.send(:handle_editor_key, "\x03")

        assert_equal "alp", editor.kill_buffer
        assert_includes output.string, "\e]52;c;#{Base64.strict_encode64("alp")}\a"
        refute editor.selection_active?

        editor.cursor = editor.buffer.length
        prompt.send(:handle_editor_key, "\x16")

        assert_equal "alphaalp", editor.buffer
      end
    end
  end

  def test_prompt_interface_editor_backspace_and_delete_remove_selection
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "notes.txt"), "alpha")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "modern")
        assert prompt.send(:open_editor, "notes.txt")
        editor = prompt.instance_variable_get(:@editor_state)

        3.times { prompt.send(:handle_editor_key, "\e[1;2C") }
        prompt.send(:handle_editor_key, "\b")

        assert_equal "ha", editor.buffer
        assert_equal [0, 0], editor.cursor_line_and_column
        refute editor.selection_active?

        2.times { prompt.send(:handle_editor_key, "\e[1;2C") }
        prompt.send(:handle_editor_key, "\e[3~")

        assert_equal "", editor.buffer
        refute editor.selection_active?
      end
    end
  end

  def test_prompt_interface_modern_ctrl_x_cuts_shift_selection
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "notes.txt"), "alpha")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "modern")
        assert prompt.send(:open_editor, "notes.txt")
        editor = prompt.instance_variable_get(:@editor_state)

        3.times { prompt.send(:handle_editor_key, "\e[1;2C") }
        prompt.send(:handle_editor_key, "\x18")

        assert_equal "ha", editor.buffer
        assert_equal "alp", editor.kill_buffer
        refute editor.selection_active?
      end
    end
  end

  def test_prompt_interface_modern_ctrl_arrow_keys_move_to_line_and_document_boundaries
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "notes.txt"), "alpha\nbeta\ngamma")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "modern")
        assert prompt.send(:open_editor, "notes.txt")
        editor = prompt.instance_variable_get(:@editor_state)
        editor.cursor = 8

        prompt.send(:handle_editor_key, "\e[1;5C")
        assert_equal [1, 4], editor.cursor_line_and_column

        prompt.send(:handle_editor_key, "\e[1;5D")
        assert_equal [1, 0], editor.cursor_line_and_column

        prompt.send(:handle_editor_key, "\e[1;5B")
        assert_equal editor.buffer.length, editor.cursor

        prompt.send(:handle_editor_key, "\e[1;5A")
        assert_equal 0, editor.cursor
      end
    end
  end

  def test_prompt_interface_modern_alt_shift_left_and_right_select_wordwise
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "notes.txt"), "alpha beta gamma")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "modern")
        assert prompt.send(:open_editor, "notes.txt")
        editor = prompt.instance_variable_get(:@editor_state)
        editor.cursor = 6

        prompt.send(:handle_editor_key, "\e[1;4C")
        assert_equal "beta", editor.selected_text
        assert_equal 10, editor.cursor

        prompt.send(:handle_editor_key, "\e[1;4D")
        refute editor.selection_active?
        assert_equal 6, editor.cursor

        prompt.send(:handle_editor_key, "\e[1;4D")
        assert_equal "alpha ", editor.selected_text
        assert_equal 0, editor.cursor
      end
    end
  end

  def test_prompt_interface_modern_ctrl_space_does_not_start_selection
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "notes.txt"), "alpha")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "modern")
        assert prompt.send(:open_editor, "notes.txt")
        editor = prompt.instance_variable_get(:@editor_state)

        prompt.send(:handle_editor_key, "\x00")
        refute editor.selection_active?
        prompt.send(:handle_editor_key, "\e[C")
        refute editor.selection_active?

        prompt.send(:handle_editor_key, "\e[32;5u")
        refute editor.selection_active?
        prompt.send(:handle_editor_key, "\e[1;2C")

        assert editor.selection_active?
        assert_equal "l", editor.selected_text
      end
    end
  end

  def test_prompt_interface_modern_ctrl_o_and_ctrl_x_do_not_save_or_close
    Dir.mktmpdir do |dir|
      path = File.join(dir, "notes.txt")
      File.write(path, "hello")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "modern")
        assert prompt.send(:open_editor, "notes.txt")

        prompt.send(:handle_editor_key, "!")
        prompt.send(:handle_editor_key, "\x0F")
        prompt.send(:handle_editor_key, "\x18")

        assert prompt.send(:editor_active?)
        assert_equal "hello", File.read(path)
      end
    end
  end

  def test_prompt_interface_modern_ctrl_z_undoes_and_ctrl_shift_z_redoes
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "notes.txt"), "hello")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "modern")
        assert prompt.send(:open_editor, "notes.txt")
        editor = prompt.instance_variable_get(:@editor_state)

        prompt.send(:handle_editor_key, "!")
        assert_equal "!hello", editor.buffer

        prompt.send(:handle_editor_key, "\x1A")
        assert_equal "hello", editor.buffer

        prompt.send(:handle_editor_key, "\e[90;6u")
        assert_equal "!hello", editor.buffer
      end
    end
  end

  def test_prompt_interface_modern_csi_u_ctrl_z_undoes_and_ctrl_shift_z_redoes
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "notes.txt"), "hello")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "modern")
        assert prompt.send(:open_editor, "notes.txt")
        editor = prompt.instance_variable_get(:@editor_state)

        prompt.send(:handle_editor_key, "!")
        prompt.send(:handle_editor_key, "\e[122;5u")
        assert_equal "hello", editor.buffer

        prompt.send(:handle_editor_key, "\e[122;6u")
        assert_equal "!hello", editor.buffer
      end
    end
  end

  def test_prompt_interface_modern_does_not_record_noop_undo
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "notes.txt"), "hello")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "modern")
        assert prompt.send(:open_editor, "notes.txt")
        editor = prompt.instance_variable_get(:@editor_state)

        prompt.send(:handle_editor_key, "\b")

        assert_empty editor.undo_stack
      end
    end
  end

  def test_prompt_interface_modern_ctrl_z_does_not_undo_during_search
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "notes.txt"), "hello")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "modern")
        assert prompt.send(:open_editor, "notes.txt")
        editor = prompt.instance_variable_get(:@editor_state)

        prompt.send(:handle_editor_key, "!")
        prompt.send(:handle_editor_key, "/")
        prompt.send(:handle_editor_key, "\x1A")

        assert_equal "!hello", editor.buffer
        assert editor.search_active
      end
    end
  end

  def test_prompt_interface_editor_page_keys_scroll_half_pages
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "notes.txt"), ("0".."20").to_a.join("\n"))
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "modern")
        prompt.define_singleton_method(:screen_height) { 14 }
        assert prompt.send(:open_editor, "notes.txt")
        editor = prompt.instance_variable_get(:@editor_state)

        prompt.send(:handle_editor_key, "\e[6~")
        assert_equal 5, editor.viewport_row
        assert_equal [5, 0], editor.cursor_line_and_column

        prompt.send(:handle_editor_key, "\e[5~")
        assert_equal 0, editor.viewport_row
        assert_equal [5, 0], editor.cursor_line_and_column
      end
    end
  end

  def test_prompt_interface_editor_supports_unix_text_keybindings
    Dir.mktmpdir do |dir|
      path = File.join(dir, "notes.txt")
      File.write(path, "alpha beta\ngamma delta")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs")
        assert prompt.send(:open_editor, "notes.txt")
        editor = prompt.instance_variable_get(:@editor_state)
        editor.cursor = editor.buffer.length

        prompt.send(:handle_editor_key, "\x01")
        assert_equal [1, 0], editor.cursor_line_and_column

        prompt.send(:handle_editor_key, "\x05")
        assert_equal [1, 11], editor.cursor_line_and_column

        prompt.send(:handle_editor_key, "\x02")
        assert_equal [1, 10], editor.cursor_line_and_column

        prompt.send(:handle_editor_key, "\x06")
        assert_equal [1, 11], editor.cursor_line_and_column

        prompt.send(:handle_editor_key, "\x17")
        assert_equal "alpha beta\ngamma ", editor.buffer
        assert_equal "delta", editor.kill_buffer

        prompt.send(:handle_editor_key, "\x19")
        assert_equal "alpha beta\ngamma delta", editor.buffer
      end
    end
  end

  def test_prompt_interface_editor_supports_ctrl_n_and_ctrl_p_line_navigation
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "notes.txt"), "one\ntwo\nthree")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs")
        assert prompt.send(:open_editor, "notes.txt")
        editor = prompt.instance_variable_get(:@editor_state)
        editor.set_cursor_line_and_column(1, 1)

        prompt.send(:handle_editor_key, "\x0E")
        assert_equal [2, 1], editor.cursor_line_and_column

        prompt.send(:handle_editor_key, "\x10")
        assert_equal [1, 1], editor.cursor_line_and_column
      end
    end
  end

  def test_prompt_interface_editor_supports_csi_u_ctrl_n_and_ctrl_p_line_navigation
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "notes.txt"), "one\ntwo\nthree")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs")
        assert prompt.send(:open_editor, "notes.txt")
        editor = prompt.instance_variable_get(:@editor_state)
        editor.set_cursor_line_and_column(1, 1)

        prompt.send(:handle_editor_key, "\e[110;5u")
        assert_equal [2, 1], editor.cursor_line_and_column

        prompt.send(:handle_editor_key, "\e[112;5u")
        assert_equal [1, 1], editor.cursor_line_and_column
      end
    end
  end

  def test_prompt_interface_editor_supports_unix_line_kill_keybindings
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "notes.txt"), "alpha beta\ngamma delta")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs")
        assert prompt.send(:open_editor, "notes.txt")
        editor = prompt.instance_variable_get(:@editor_state)
        editor.set_cursor_line_and_column(1, 6)

        prompt.send(:handle_editor_key, "\x15")
        assert_equal "alpha beta\ndelta", editor.buffer
        assert_equal "gamma ", editor.kill_buffer

        prompt.send(:handle_editor_key, "\x0B")
        assert_equal "alpha beta\n", editor.buffer
        assert_equal "delta", editor.kill_buffer
      end
    end
  end

  def test_prompt_interface_editor_ctrl_k_deletes_empty_line
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "notes.txt"), "one\n\ntwo")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs")
        assert prompt.send(:open_editor, "notes.txt")
        editor = prompt.instance_variable_get(:@editor_state)
        editor.set_cursor_line_and_column(1, 0)

        prompt.send(:handle_editor_key, "\x0B")

        assert_equal "one\ntwo", editor.buffer
        assert_equal "\n", editor.kill_buffer
        assert_equal [1, 0], editor.cursor_line_and_column
      end
    end
  end

  def test_prompt_interface_editor_ctrl_k_deletes_final_empty_line
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "notes.txt"), "one\n")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs")
        assert prompt.send(:open_editor, "notes.txt")
        editor = prompt.instance_variable_get(:@editor_state)
        editor.set_cursor_line_and_column(1, 0)

        prompt.send(:handle_editor_key, "\x0B")

        assert_equal "one", editor.buffer
        assert_equal "\n", editor.kill_buffer
        assert_equal [0, 3], editor.cursor_line_and_column
      end
    end
  end

  def test_prompt_interface_editor_supports_alt_word_keybindings
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "notes.txt"), "alpha beta gamma")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs")
        assert prompt.send(:open_editor, "notes.txt")
        editor = prompt.instance_variable_get(:@editor_state)
        editor.cursor = editor.buffer.length

        prompt.send(:handle_editor_key, "\eb")
        assert_equal 11, editor.cursor

        prompt.send(:handle_editor_key, "\eb")
        assert_equal 6, editor.cursor

        prompt.send(:handle_editor_key, "\ef")
        assert_equal 10, editor.cursor

        prompt.send(:handle_editor_key, "\ed")
        assert_equal "alpha beta", editor.buffer
        assert_equal " gamma", editor.kill_buffer
      end
    end
  end

  def test_prompt_interface_editor_supports_macos_option_arrow_word_keybindings
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "notes.txt"), "alpha beta gamma")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs")
        prompt.update_tabs(labels: ["One", "Two"], active_index: 0)
        assert prompt.send(:open_editor, "notes.txt")
        editor = prompt.instance_variable_get(:@editor_state)
        editor.cursor = editor.buffer.length

        prompt.send(:handle_editor_key, "\e[1;3D")
        assert_equal 11, editor.cursor

        prompt.send(:handle_editor_key, "\e[1;3C")
        assert_equal editor.buffer.length, editor.cursor
      end
    end
  end

  def test_prompt_interface_editor_supports_alt_backspace_and_delete_word_keybindings
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "notes.txt"), "alpha beta gamma")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs")
        assert prompt.send(:open_editor, "notes.txt")
        editor = prompt.instance_variable_get(:@editor_state)
        editor.cursor = editor.buffer.length

        prompt.send(:handle_editor_key, "\e\x7F")
        assert_equal "alpha beta ", editor.buffer
        assert_equal "gamma", editor.kill_buffer

        editor.cursor = 0
        prompt.send(:handle_editor_key, "\e[3;3~")
        assert_equal " beta ", editor.buffer
        assert_equal "alpha", editor.kill_buffer
      end
    end
  end

  def test_prompt_interface_editor_search_ignores_file_editing_keybindings
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "notes.txt"), "alpha beta")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs")
        assert prompt.send(:open_editor, "notes.txt")
        editor = prompt.instance_variable_get(:@editor_state)
        prompt.send(:handle_editor_key, "\x13")

        prompt.send(:handle_editor_key, "\x15")
        prompt.send(:handle_editor_key, "\eb")

        assert_equal "alpha beta", editor.buffer
        assert editor.search_active
      end
    end
  end

  def test_prompt_interface_editor_ctrl_space_starts_selection
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "notes.txt"), "alpha\nbeta")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs")
        assert prompt.send(:open_editor, "notes.txt")
        editor = prompt.instance_variable_get(:@editor_state)

        prompt.send(:handle_editor_key, "\x00")
        prompt.send(:handle_editor_key, "\x06")
        prompt.send(:handle_editor_key, "\x06")

        assert editor.selection_active?
        assert_equal "al", editor.selected_text

        prompt.send(:handle_editor_key, "\x0E")

        assert_equal "alpha\nbe", editor.selected_text
      end
    end
  end

  def test_prompt_interface_editor_status_strings_are_not_submitted_as_chat_input
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "notes.txt"), "alpha")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs")
        assert prompt.send(:open_editor, "notes.txt")
        editor = prompt.instance_variable_get(:@editor_state)

        refute_kind_of String, prompt.send(:handle_key, "\x00")
        assert_equal "Selection started", editor.status
        assert prompt.send(:editor_active?)

        refute_kind_of String, prompt.send(:handle_key, "\x18")
        assert_equal "C-x", editor.status
        assert_equal "C-x", editor.emacs_pending
        assert prompt.send(:editor_active?)
      end
    end
  end

  def test_prompt_interface_editor_csi_u_ctrl_space_starts_selection
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "notes.txt"), "alpha")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs")
        assert prompt.send(:open_editor, "notes.txt")
        editor = prompt.instance_variable_get(:@editor_state)

        prompt.send(:handle_editor_key, "\e[32;5u")
        prompt.send(:handle_editor_key, "\x06")

        assert editor.selection_active?
        assert_equal "a", editor.selected_text
      end
    end
  end

  def test_prompt_interface_editor_shift_navigation_selects_text
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "notes.txt"), "alpha\nbeta")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs")
        assert prompt.send(:open_editor, "notes.txt")
        editor = prompt.instance_variable_get(:@editor_state)

        prompt.send(:handle_editor_key, "\e[1;2C")
        prompt.send(:handle_editor_key, "\e[1;2C")

        assert editor.selection_active?
        assert_equal "al", editor.selected_text

        prompt.send(:handle_editor_key, "\e[1;2B")

        assert_equal "alpha\nbe", editor.selected_text
      end
    end
  end

  def test_prompt_interface_editor_ctrl_y_copies_selection_to_terminal_clipboard
    output = StringIO.new
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "notes.txt"), "alpha\nbeta")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: output, editor_mode: "emacs")
        assert prompt.send(:open_editor, "notes.txt")
        editor = prompt.instance_variable_get(:@editor_state)
        prompt.send(:handle_editor_key, "\x00")
        3.times { prompt.send(:handle_editor_key, "\x06") }

        prompt.send(:handle_editor_key, "\ew")

        assert_includes output.string, "\e]52;c;#{Base64.strict_encode64("alp")}\a"
        refute editor.selection_active?
        assert_equal "Copied region", editor.status
      end
    end
  end

  def test_prompt_interface_editor_ctrl_y_without_selection_yanks_kill_buffer
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "notes.txt"), "alpha beta")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs")
        assert prompt.send(:open_editor, "notes.txt")
        editor = prompt.instance_variable_get(:@editor_state)
        editor.cursor = editor.buffer.length
        prompt.send(:handle_editor_key, "\x17")

        prompt.send(:handle_editor_key, "\x19")

        assert_equal "alpha beta", editor.buffer
      end
    end
  end

  def test_prompt_interface_editor_escape_clears_selection
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "notes.txt"), "alpha")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs")
        assert prompt.send(:open_editor, "notes.txt")
        editor = prompt.instance_variable_get(:@editor_state)
        prompt.send(:handle_editor_key, "\x00")
        prompt.send(:handle_editor_key, "\x06")

        prompt.send(:handle_editor_key, "\e")

        assert prompt.send(:editor_active?)
        refute editor.selection_active?
      end
    end
  end

  def test_prompt_interface_editor_typing_with_selection_clears_selection_and_edits_at_cursor
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "notes.txt"), "alpha")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs")
        assert prompt.send(:open_editor, "notes.txt")
        editor = prompt.instance_variable_get(:@editor_state)
        prompt.send(:handle_editor_key, "\x00")
        prompt.send(:handle_editor_key, "\x06")

        prompt.send(:handle_editor_key, "!")

        assert_equal "a!lpha", editor.buffer
        refute editor.selection_active?
      end
    end
  end

  def test_prompt_interface_editor_render_highlights_selection_without_gutter
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "notes.txt"), "alpha")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs")
        prompt.instance_variable_set(:@color_enabled, true)
        assert prompt.send(:open_editor, "notes.txt")
        prompt.send(:handle_editor_key, "\x00")
        prompt.send(:handle_editor_key, "\x06")
        prompt.send(:handle_editor_key, "\x06")

        rows, = prompt.send(:composer_layout, 40, 10)
        text = rows.join("\n")

        assert_includes strip_ansi(text), "   1 │ alpha"
        assert_includes text, "\e[38;2;78;88;53m   1 │ \e[0m\e[7mal\e[0mpha"
        refute_includes text, "\e[7m   1"
      end
    end
  end

  def test_prompt_interface_editor_escape_does_not_close_editor
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "notes.txt"), "hello")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs")
        assert prompt.send(:open_editor, "notes.txt")

        prompt.send(:handle_editor_key, "\e")

        assert prompt.send(:editor_active?)
      end
    end
  end

  def test_prompt_interface_editor_escape_still_cancels_search
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "notes.txt"), "hello")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs")
        assert prompt.send(:open_editor, "notes.txt")
        prompt.send(:handle_editor_key, "\x13")

        prompt.send(:handle_editor_key, "\e")

        editor = prompt.instance_variable_get(:@editor_state)
        assert prompt.send(:editor_active?)
        refute editor.search_active
      end
    end
  end

  def test_prompt_interface_editor_ctrl_q_closes_clean_editor
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "notes.txt"), "hello")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs")
        assert prompt.send(:open_editor, "notes.txt")

        prompt.send(:handle_editor_key, "\x18")
        prompt.send(:handle_editor_key, "\x03")

        refute prompt.send(:editor_active?)
      end
    end
  end

  def test_prompt_interface_editor_ctrl_q_warns_before_closing_dirty_editor
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "notes.txt"), "hello")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs")
        assert prompt.send(:open_editor, "notes.txt")
        prompt.send(:handle_editor_key, "!")

        prompt.send(:handle_editor_key, "\x18")
        prompt.send(:handle_editor_key, "\x03")

        editor = prompt.instance_variable_get(:@editor_state)
        assert prompt.send(:editor_active?)
        assert editor.quit_confirmed
        assert_includes editor.status, "Press C-x C-c again"

        prompt.send(:handle_editor_key, "\x18")
        prompt.send(:handle_editor_key, "\x03")

        refute prompt.send(:editor_active?)
      end
    end
  end

  def test_prompt_interface_editor_edit_after_ctrl_q_warning_requires_new_warning
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "notes.txt"), "hello")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs")
        assert prompt.send(:open_editor, "notes.txt")
        prompt.send(:handle_editor_key, "!")
        prompt.send(:handle_editor_key, "\x18")
        prompt.send(:handle_editor_key, "\x03")
        prompt.send(:handle_editor_key, "?")

        editor = prompt.instance_variable_get(:@editor_state)
        refute editor.quit_confirmed

        prompt.send(:handle_editor_key, "\x18")
        prompt.send(:handle_editor_key, "\x03")

        assert prompt.send(:editor_active?)
        assert editor.quit_confirmed
      end
    end
  end

  def test_prompt_interface_editor_save_after_ctrl_q_warning_allows_clean_close
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "notes.txt"), "hello")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs")
        assert prompt.send(:open_editor, "notes.txt")
        prompt.send(:handle_editor_key, "!")
        prompt.send(:handle_editor_key, "\x18")
        prompt.send(:handle_editor_key, "\x03")
        prompt.send(:handle_editor_key, "\x18")
        prompt.send(:handle_editor_key, "\x13")

        editor = prompt.instance_variable_get(:@editor_state)
        refute editor.quit_confirmed

        prompt.send(:handle_editor_key, "\x18")
        prompt.send(:handle_editor_key, "\x03")

        refute prompt.send(:editor_active?)
      end
    end
  end

  def test_prompt_interface_editor_csi_u_ctrl_q_closes_clean_editor
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "notes.txt"), "hello")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs")
        assert prompt.send(:open_editor, "notes.txt")

        prompt.send(:handle_editor_key, "\x18")
        prompt.send(:handle_editor_key, "\x03")

        refute prompt.send(:editor_active?)
      end
    end
  end

  def test_prompt_interface_editor_ctrl_c_does_not_close_editor
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "notes.txt"), "hello")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs")
        assert prompt.send(:open_editor, "notes.txt")

        prompt.send(:handle_editor_key, "\x03")

        assert prompt.send(:editor_active?)
      end
    end
  end

  def test_prompt_interface_emacs_csi_u_ctrl_x_ctrl_s_saves_file
    Dir.mktmpdir do |dir|
      dir = File.realpath(dir)
      path = File.join(dir, "notes.txt")
      File.write(path, "hello")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs")
        assert prompt.send(:open_editor, "notes.txt")
        editor = prompt.instance_variable_get(:@editor_state)

        prompt.send(:handle_editor_key, "!")
        prompt.send(:handle_editor_key, "\e[120;5u")
        prompt.send(:handle_editor_key, "\e[115;5u")

        assert_equal "!hello", File.read(path)
        refute editor.search_active
        assert_nil editor.emacs_pending
      end
    end
  end

  def test_prompt_interface_editor_saves_file
    Dir.mktmpdir do |dir|
      dir = File.realpath(dir)
      path = File.join(dir, "notes.txt")
      File.write(path, "hello")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs")
        assert prompt.send(:open_editor, "notes.txt")

        prompt.send(:handle_editor_key, "!")
        prompt.send(:handle_editor_key, "\x18")
        prompt.send(:handle_editor_key, "\x13")

        assert_equal "!hello", File.read(path)
      end
    end
  end

  def test_prompt_interface_editor_warns_before_overwriting_changed_file
    Dir.mktmpdir do |dir|
      dir = File.realpath(dir)
      path = File.join(dir, "notes.txt")
      File.write(path, "hello")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs")
        assert prompt.send(:open_editor, "notes.txt")
        prompt.send(:handle_editor_key, "!")
        sleep 0.01
        File.write(path, "external")

        prompt.send(:handle_editor_key, "\x18")
        prompt.send(:handle_editor_key, "\x13")
        assert_equal "external", File.read(path)
        assert_includes prompt.instance_variable_get(:@editor_state).status, "Press Ctrl+S again"

        prompt.send(:handle_editor_key, "\x18")
        prompt.send(:handle_editor_key, "\x13")
        assert_equal "!hello", File.read(path)
      end
    end
  end

  def test_prompt_interface_editor_search_jumps_to_match
    Dir.mktmpdir do |dir|
      dir = File.realpath(dir)
      path = File.join(dir, "notes.txt")
      File.write(path, "alpha\nbeta\n")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs")
        assert prompt.send(:open_editor, "notes.txt")

        refute_kind_of String, prompt.send(:handle_editor_key, "\x13")
        "beta".each_char do |char|
          refute_kind_of String, prompt.send(:handle_editor_key, char)
        end
        refute_kind_of String, prompt.send(:handle_editor_key, "\r")

        assert_equal [1, 0], prompt.instance_variable_get(:@editor_state).cursor_line_and_column
      end
    end
  end

  def test_prompt_interface_editor_layout_shows_line_numbers
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "notes.txt"), "one\ntwo\n")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs")
        assert prompt.send(:open_editor, "notes.txt")

        rows, = prompt.send(:composer_layout, 40, 10)
        text = strip_ansi(rows.join("\n"))

        assert_includes text, "│    1 │ one"
        assert_includes text, "│    2 │ two"
        assert_includes text, "│    3 │ "
      end
    end
  end

  def test_prompt_interface_editor_line_numbers_are_absolute_after_scrolling
    original_height = TTY::Screen.method(:height)
    TTY::Screen.define_singleton_method(:height) { 8 }
    Dir.mktmpdir do |dir|
      content = (1..10).map { |index| "line #{index}" }.join("\n")
      File.write(File.join(dir, "notes.txt"), content)
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs")
        assert prompt.send(:open_editor, "notes.txt")
        editor = prompt.instance_variable_get(:@editor_state)
        editor.set_cursor_line_and_column(9, 0)

        rows, = prompt.send(:composer_layout, 40, 8)
        text = strip_ansi(rows.join("\n"))

        assert_includes text, "│   10 │ line 10"
        refute_includes text, "│    1 │ line 10"
      end
    end
  ensure
    TTY::Screen.define_singleton_method(:height, original_height) if original_height
  end

  def test_prompt_interface_editor_cursor_column_accounts_for_line_number_gutter
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "notes.txt"), "one\ntwo")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs")
        assert prompt.send(:open_editor, "notes.txt")
        editor = prompt.instance_variable_get(:@editor_state)
        editor.set_cursor_line_and_column(0, 2)

        _rows, cursor_row, cursor_col = prompt.send(:composer_layout, 40, 10)

        assert_equal 1, cursor_row
        assert_equal 11, cursor_col
      end
    end
  end

  def test_prompt_interface_editor_line_number_gutter_reserves_four_digits
    Dir.mktmpdir do |dir|
      content = (1..10).map { |index| "line #{index}" }.join("\n")
      File.write(File.join(dir, "notes.txt"), content)
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs")
        assert prompt.send(:open_editor, "notes.txt")

        rows, = prompt.send(:composer_layout, 40, 20)
        text = strip_ansi(rows.join("\n"))

        assert_includes text, "│    1 │ line 1"
        assert_includes text, "│   10 │ line 10"
      end
    end
  end

  def test_prompt_interface_editor_line_number_gutter_expands_beyond_four_digits
    Dir.mktmpdir do |dir|
      content = (1..10_000).map { |index| "line #{index}" }.join("\n")
      File.write(File.join(dir, "notes.txt"), content)
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs")
        assert prompt.send(:open_editor, "notes.txt")
        editor = prompt.instance_variable_get(:@editor_state)
        editor.set_cursor_line_and_column(9_999, 0)

        rows, = prompt.send(:composer_layout, 40, 10)
        text = strip_ansi(rows.join("\n"))

        assert_includes text, "│ 10000 │ line 10000"
      end
    end
  end

  def test_prompt_interface_editor_line_numbers_remain_visible_when_narrow
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "notes.txt"), "abcdef")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs")
        assert prompt.send(:open_editor, "notes.txt")

        rows, = prompt.send(:composer_layout, 10, 6)
        text = strip_ansi(rows.join("\n"))

        assert_includes text, "│    1"
      end
    end
  end

  def test_prompt_interface_editor_does_not_show_line_numbers_for_filler_rows
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "notes.txt"), "one\ntwo")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs")
        assert prompt.send(:open_editor, "notes.txt")

        rows, = prompt.send(:composer_layout, 40, 10)
        text = strip_ansi(rows.join("\n"))

        assert_includes text, "│    1 │ one"
        assert_includes text, "│    2 │ two"
        refute_includes text, "│    3 │"
      end
    end
  end

  def test_prompt_interface_editor_empty_buffer_shows_line_one
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs")
        assert prompt.send(:open_editor, "new.txt", allow_new: true)

        rows, = prompt.send(:composer_layout, 40, 10)
        text = strip_ansi(rows.join("\n"))

        assert_includes text, "│    1 │"
      end
    end
  end

  def test_prompt_interface_editor_layout_fills_available_height
    original_height = TTY::Screen.method(:height)
    TTY::Screen.define_singleton_method(:height) { 20 }
    Dir.mktmpdir do |dir|
      dir = File.realpath(dir)
      path = File.join(dir, "notes.txt")
      File.write(path, "one\ntwo\n")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs")
        assert prompt.send(:open_editor, "notes.txt")

        rows, = prompt.send(:composer_layout, 80, 20)

        assert_equal 19, rows.length
        assert_includes strip_ansi(rows.first), "Edit notes.txt"
      end
    end
  ensure
    TTY::Screen.define_singleton_method(:height, original_height) if original_height
  end

  def test_prompt_interface_tab_view_snapshot_restores_editor_state
    Dir.mktmpdir do |dir|
      dir = File.realpath(dir)
      path = File.join(dir, "notes.txt")
      File.write(path, "hello")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs")
        assert prompt.send(:open_editor, "notes.txt")
        prompt.send(:handle_editor_key, "!")
        snapshot = prompt.tab_view_snapshot

        prompt.send(:close_editor)
        prompt.restore_tab_view_snapshot(snapshot)

        editor = prompt.instance_variable_get(:@editor_state)
        assert_equal path, editor.path
        assert_equal "!hello", editor.buffer
      end
    end
  end

  def test_prompt_interface_composer_restore_applies_editor_snapshot_for_idle_tabs
    Dir.mktmpdir do |dir|
      dir = File.realpath(dir)
      path = File.join(dir, "notes.txt")
      File.write(path, "hello")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs")
        tab_without_editor = prompt.tab_view_snapshot
        assert prompt.send(:open_editor, "notes.txt")
        tab_with_editor = prompt.tab_view_snapshot

        prompt.restore_composer_snapshot(tab_without_editor)
        assert_nil prompt.instance_variable_get(:@editor_state)

        prompt.restore_composer_snapshot(tab_with_editor)
        assert_equal path, prompt.instance_variable_get(:@editor_state).path
      end
    end
  end

  def test_prompt_interface_tab_view_snapshot_clears_editor_when_restoring_tab_without_editor
    Dir.mktmpdir do |dir|
      dir = File.realpath(dir)
      path = File.join(dir, "notes.txt")
      File.write(path, "hello")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs")
        tab_without_editor = prompt.tab_view_snapshot
        assert prompt.send(:open_editor, "notes.txt")

        prompt.restore_tab_view_snapshot(tab_without_editor)

        assert_nil prompt.instance_variable_get(:@editor_state)
      end
    end
  end

  def test_prompt_interface_tab_view_snapshot_does_not_share_editor_buffer
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "notes.txt"), "hello")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs")
        assert prompt.send(:open_editor, "notes.txt")
        first_snapshot = prompt.tab_view_snapshot
        second_snapshot = prompt.tab_view_snapshot

        prompt.restore_tab_view_snapshot(first_snapshot)
        prompt.send(:handle_editor_key, "!")

        prompt.restore_tab_view_snapshot(second_snapshot)

        editor = prompt.instance_variable_get(:@editor_state)
        assert_equal "hello", editor.buffer
      end
    end
  end

  def test_prompt_interface_editor_mode_is_read_when_editor_opens
    Dir.mktmpdir do |dir|
      config_path = File.join(dir, "config.json")
      workspace = File.join(dir, "workspace")
      Dir.mkdir(workspace)
      File.write(File.join(workspace, "notes.txt"), "alpha")
      Kward::ConfigFiles.write_config({ "editor" => { "mode" => "default" } }, config_path)

      with_env("KWARD_CONFIG_PATH" => config_path) do
        Dir.chdir(workspace) do
          prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "default", editor_mode_source: -> { Kward::ConfigFiles.editor_mode })
          assert prompt.send(:open_editor, "notes.txt")
          assert_equal "modern", prompt.instance_variable_get(:@editor_state).editor_mode
          prompt.send(:close_editor)

          Kward::ConfigFiles.write_config({ "editor" => { "mode" => "vibe" } }, config_path)
          assert prompt.send(:open_editor, "notes.txt")
          assert_equal "vibe", prompt.instance_variable_get(:@editor_state).editor_mode
        end
      end
    end
  end

end
