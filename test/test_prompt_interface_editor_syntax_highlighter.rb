require_relative "test_helper"

class TestPromptInterfaceEditorSyntaxHighlighter < KwardTestCase
  def test_detects_ruby_by_extension_and_known_filename
    prompt = syntax_prompt

    assert_equal :ruby, prompt.send(:editor_detect_syntax_language, "lib/example.rb")
    assert_equal :ruby, prompt.send(:editor_detect_syntax_language, "Gemfile")
    assert_equal :ruby, prompt.send(:editor_detect_syntax_language, "kward.gemspec")
  end

  def test_detects_markdown_by_extension
    prompt = syntax_prompt

    assert_equal :markdown, prompt.send(:editor_detect_syntax_language, "README.md")
    assert_equal :markdown, prompt.send(:editor_detect_syntax_language, "notes.markdown")
  end

  def test_unknown_files_remain_plain
    prompt = syntax_prompt(path: "notes.txt")

    assert_equal "hello world", prompt.send(:editor_render_line, "hello world", 0, 80)
  end

  def test_disabled_color_returns_plain_text
    prompt = syntax_prompt(path: "example.rb", color_enabled: false)

    assert_equal "def call", prompt.send(:editor_render_line, "def call", 0, 80)
  end

  def test_ruby_highlighting_colorizes_keywords_and_strings
    prompt = syntax_prompt(path: "example.rb")
    rendered = prompt.send(:editor_render_line, "def call = \"ok\"", 0, 80)

    assert_includes rendered, "\e[34mdef\e[0m"
    assert_includes rendered, "\e[32m\"ok\"\e[0m"
    assert_equal "def call = \"ok\"", strip_ansi(rendered)
  end

  def test_ruby_hash_comment_colors_full_comment_without_inner_highlighting
    prompt = syntax_prompt(path: "example.rb")
    rendered = prompt.send(:editor_render_line, "# Namespace for the Kward CLI agent runtime.", 0, 80)

    assert_equal "# Namespace for the Kward CLI agent runtime.", strip_ansi(rendered)
    assert_equal "\e[90m# Namespace for the Kward CLI agent runtime.\e[0m", rendered
  end

  def test_ruby_inline_comment_preserves_code_highlighting_before_comment
    prompt = syntax_prompt(path: "example.rb")
    rendered = prompt.send(:editor_render_line, "class Agent # return Kward", 0, 80)

    assert_includes rendered, "\e[34mclass\e[0m"
    assert_includes rendered, "\e[33mAgent\e[0m"
    assert_includes rendered, "\e[90m# return Kward\e[0m"
    refute_includes rendered, "\e[34mreturn\e[0m"
  end

  def test_ruby_hash_inside_string_is_not_treated_as_comment
    prompt = syntax_prompt(path: "example.rb")
    rendered = prompt.send(:editor_render_line, "value = \"not # comment\"", 0, 80)

    assert_equal "value = \"not # comment\"", strip_ansi(rendered)
    assert_includes rendered, "\e[32m\"not # comment\"\e[0m"
    refute_includes rendered, "\e[90m# comment\e[0m"
  end

  def test_ruby_block_comment_colors_full_block_without_inner_highlighting
    content = "=begin\nclass Agent\n=end\ndef call"
    prompt = syntax_prompt(path: "example.rb", content: content)

    start_line = prompt.send(:editor_render_line, "=begin", 0, 80)
    inner_line = prompt.send(:editor_render_line, "class Agent", 1, 80)
    end_line = prompt.send(:editor_render_line, "=end", 2, 80)
    code_line = prompt.send(:editor_render_line, "def call", 3, 80)

    assert_equal "\e[90m=begin\e[0m", start_line
    assert_equal "\e[90mclass Agent\e[0m", inner_line
    assert_equal "\e[90m=end\e[0m", end_line
    assert_includes code_line, "\e[34mdef\e[0m"
  end

  def test_markdown_highlighting_colorizes_headings_and_inline_code
    prompt = syntax_prompt(path: "README.md")
    heading = prompt.send(:editor_render_line, "# Title", 0, 80)
    inline = prompt.send(:editor_render_line, "Use `kward` now", 0, 80)

    assert_includes heading, "\e[36m# \e[0m"
    assert_includes heading, "\e[1mTitle\e[0m"
    assert_includes inline, "\e[2m`kward`\e[0m"
    assert_equal "# Title", strip_ansi(heading)
    assert_equal "Use `kward` now", strip_ansi(inline)
  end

  def test_selection_overrides_syntax_highlighting
    prompt = syntax_prompt(path: "example.rb", content: "def call")
    state = prompt.instance_variable_get(:@editor_state)
    state.selection_anchor = 0
    state.cursor = 3

    rendered = prompt.send(:editor_render_line, "def call", 0, 80)

    assert_includes rendered, "\e[7mdef\e[0m"
    refute_includes rendered, "\e[34mdef\e[0m"
    assert_equal "def call", strip_ansi(rendered)
  end

  def test_highlighted_editor_rows_keep_full_visible_width
    prompt = syntax_prompt(path: "README.md", content: "# Title\n\nUse `kward` now")

    rows, = prompt.send(:editor_layout, 60, 12)

    assert rows.all? { |row| strip_ansi(row).length == 60 }
  end

  private

  def syntax_prompt(path: "notes.txt", content: "", color_enabled: true)
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new)
    prompt.instance_variable_set(:@color_enabled, color_enabled)
    prompt.instance_variable_set(:@editor_state, Kward::PromptInterface::EditorState.new(path: path, content: content))
    prompt
  end
end
