require_relative "../test_helper"

class TestPromptInterfaceEditorIndentation < KwardTestCase
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

        assert_equal "class Example\n    attr_reader :name\n  def call\n    \n  end", editor.buffer
        assert_equal [3, 4], editor.cursor_line_and_column
      end
    end
  end

  def test_prompt_interface_editor_endwise_adds_ruby_end
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "example.rb"), "if condition")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "modern")
        assert prompt.send(:open_editor, "example.rb")
        editor = prompt.instance_variable_get(:@editor_state)
        editor.cursor = editor.buffer.length

        prompt.send(:handle_editor_key, "\n")

        assert_equal "if condition\n  \nend", editor.buffer
        assert_equal [1, 2], editor.cursor_line_and_column
      end
    end
  end

  def test_prompt_interface_editor_endwise_skips_existing_ruby_end
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "example.rb"), "if condition\nend")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "modern")
        assert prompt.send(:open_editor, "example.rb")
        editor = prompt.instance_variable_get(:@editor_state)
        editor.set_cursor_line_and_column(0, "if condition".length)

        prompt.send(:handle_editor_key, "\n")

        assert_equal "if condition\n  \nend", editor.buffer
        assert_equal [1, 2], editor.cursor_line_and_column
      end
    end
  end

  def test_prompt_interface_editor_endwise_ctrl_enter_from_middle_of_line
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "example.rb"), "if condition")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "modern")
        assert prompt.send(:open_editor, "example.rb")
        editor = prompt.instance_variable_get(:@editor_state)
        editor.set_cursor_line_and_column(0, 2)

        prompt.send(:handle_editor_key, "\e[13;5u")

        assert_equal "if condition\n  \nend", editor.buffer
        assert_equal [1, 2], editor.cursor_line_and_column
      end
    end
  end

  def test_prompt_interface_editor_endwise_ctrl_enter_indents_already_closed_block
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "example.rb"), "if condition\nend")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "modern")
        assert prompt.send(:open_editor, "example.rb")
        editor = prompt.instance_variable_get(:@editor_state)
        editor.set_cursor_line_and_column(0, 2)

        prompt.send(:handle_editor_key, "\e[13;5u")

        assert_equal "if condition\n  \nend", editor.buffer
        assert_equal [1, 2], editor.cursor_line_and_column
      end
    end
  end

  def test_prompt_interface_editor_auto_indent_understands_erb_blocks_and_tags
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "example.html.erb"), "<% if user %>\n  <div>")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "modern")
        assert prompt.send(:open_editor, "example.html.erb")
        editor = prompt.instance_variable_get(:@editor_state)
        editor.cursor = editor.buffer.length

        prompt.send(:handle_editor_key, "\n")

        assert_equal "<% if user %>\n  <div>\n    ", editor.buffer
      end
    end
  end

  def test_prompt_interface_editor_endwise_handles_supported_languages
    examples = {
      "example.cr" => ["if condition", "end"],
      "example.ex" => ["if condition do", "end"],
      "example.jl" => ["if condition", "end"],
      "example.lua" => ["if condition then", "end"],
      "Makefile" => ["ifdef DEBUG", "endif"],
      "example.sh" => ["if true; then", "fi"]
    }

    examples.each do |filename, (opening, closing)|
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, filename), opening)
        Dir.chdir(dir) do
          prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "modern")
          assert prompt.send(:open_editor, filename)
          editor = prompt.instance_variable_get(:@editor_state)
          editor.cursor = editor.buffer.length

          prompt.send(:handle_editor_key, "\n")

          assert_equal "#{opening}\n  \n#{closing}", editor.buffer, filename
          assert_equal [1, 2], editor.cursor_line_and_column, filename
        end
      end
    end
  end

  def test_prompt_interface_editor_endwise_ignores_comments_and_endless_methods
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "example.rb"), "# if condition\ndef call = value")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "modern")
        assert prompt.send(:open_editor, "example.rb")
        editor = prompt.instance_variable_get(:@editor_state)
        editor.set_cursor_line_and_column(0, editor.lines[0].length)

        prompt.send(:handle_editor_key, "\n")
        assert_equal "# if condition\n", editor.buffer[0, "# if condition\n".length]

        editor.set_cursor_line_and_column(2, editor.lines[2].length)
        prompt.send(:handle_editor_key, "\n")

        refute_includes editor.buffer, "def call = value\n  \nend"
      end
    end
  end

  def test_prompt_interface_editor_endwise_is_disabled_with_auto_indent
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "example.rb"), "if condition")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "modern", editor_auto_indent: false)
        assert prompt.send(:open_editor, "example.rb")
        editor = prompt.instance_variable_get(:@editor_state)
        editor.cursor = editor.buffer.length

        prompt.send(:handle_editor_key, "\n")

        assert_equal "if condition\n", editor.buffer
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

  def test_prompt_interface_editor_auto_indent_expands_auto_closed_block
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "example.rb"), "class HelloWorld ")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "modern")
        assert prompt.send(:open_editor, "example.rb")
        editor = prompt.instance_variable_get(:@editor_state)
        editor.cursor = editor.buffer.length

        prompt.send(:handle_editor_key, "{")
        prompt.send(:handle_editor_key, "\n")

        assert_equal "class HelloWorld {\n  \n}", editor.buffer
        assert_equal [1, 2], editor.cursor_line_and_column
      end
    end
  end

  def test_prompt_interface_editor_auto_indent_expands_other_auto_close_pairs
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "example.js"), "call")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "modern")
        assert prompt.send(:open_editor, "example.js")
        editor = prompt.instance_variable_get(:@editor_state)
        editor.cursor = editor.buffer.length

        prompt.send(:handle_editor_key, "(")
        prompt.send(:handle_editor_key, "\n")

        assert_equal "call(\n  \n)", editor.buffer
        assert_equal [1, 2], editor.cursor_line_and_column
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

  def test_prompt_interface_editor_smart_tab_jumps_to_expected_indent_then_next_stop
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "example.rb"), "class Example\n  def call\nputs :ok")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "modern")
        assert prompt.send(:open_editor, "example.rb")
        editor = prompt.instance_variable_get(:@editor_state)
        editor.set_cursor_line_and_column(2, 0)

        prompt.send(:handle_editor_key, "\t")
        assert_equal "class Example\n  def call\n    puts :ok", editor.buffer
        assert_equal [2, 4], editor.cursor_line_and_column

        prompt.send(:handle_editor_key, "\t")
        assert_equal "class Example\n  def call\n      puts :ok", editor.buffer
        assert_equal [2, 6], editor.cursor_line_and_column
      end
    end
  end

  def test_prompt_interface_editor_smart_tab_moves_forward_on_empty_indented_line
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "example.rb"), "class Example\n  def call\n    ")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "modern")
        assert prompt.send(:open_editor, "example.rb")
        editor = prompt.instance_variable_get(:@editor_state)
        editor.set_cursor_line_and_column(2, 0)

        prompt.send(:handle_editor_key, "\t")
        assert_equal [2, 4], editor.cursor_line_and_column
        assert_equal "class Example\n  def call\n    ", editor.buffer

        prompt.send(:handle_editor_key, "\t")
        assert_equal "class Example\n  def call\n      ", editor.buffer
        assert_equal [2, 6], editor.cursor_line_and_column
      end
    end
  end

  def test_prompt_interface_editor_smart_tab_uses_detected_width_after_line_content
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "example.rb"), "class Example\n    attr_reader :name\n  def call")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "modern")
        assert prompt.send(:open_editor, "example.rb")
        editor = prompt.instance_variable_get(:@editor_state)
        editor.cursor = editor.buffer.length

        prompt.send(:handle_editor_key, "\t")

        assert_equal "class Example\n    attr_reader :name\n  def call  ", editor.buffer
      end
    end
  end

  def test_prompt_interface_editor_shift_tab_moves_back_by_indent_stop
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "example.rb"), "class Example\n  def call\n    other\n      puts :ok")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "modern")
        assert prompt.send(:open_editor, "example.rb")
        editor = prompt.instance_variable_get(:@editor_state)
        editor.set_cursor_line_and_column(3, 6)

        prompt.send(:handle_editor_key, "\e[Z")
        assert_equal "class Example\n  def call\n    other\n    puts :ok", editor.buffer
        assert_equal [3, 4], editor.cursor_line_and_column

        prompt.send(:handle_editor_key, "\e[9;2u")
        assert_equal "class Example\n  def call\n    other\n  puts :ok", editor.buffer
        assert_equal [3, 2], editor.cursor_line_and_column
      end
    end
  end

  def test_prompt_interface_editor_smart_tab_uses_tabs_when_detected
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "example.js"), "function test() {\n\treturn true;\nif (ready) {\nreturn ready;")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "modern")
        assert prompt.send(:open_editor, "example.js")
        editor = prompt.instance_variable_get(:@editor_state)
        editor.set_cursor_line_and_column(3, 0)

        prompt.send(:handle_editor_key, "\t")
        assert_equal "function test() {\n\treturn true;\nif (ready) {\n\treturn ready;", editor.buffer
        assert_equal [3, 1], editor.cursor_line_and_column
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

end
