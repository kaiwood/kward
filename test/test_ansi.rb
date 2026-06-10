require_relative "test_helper"

class TestANSI < KwardTestCase
  def test_ansi_colorizes_when_enabled_and_strips_sequences
    colored = Kward::ANSI.colorize("Assistant>", :green, :bold, enabled: true)

    assert_equal "\e[32;1mAssistant>\e[0m", colored
    assert_equal "Assistant>", Kward::ANSI.strip(colored)
    assert_equal "Assistant>", Kward::ANSI.colorize("Assistant>", :green, enabled: false)
  end

  def test_ansi_colorizes_palette_truecolor
    colored = Kward::ANSI.colorize("border", :primary_green, enabled: true)

    assert_equal "\e[38;2;138;160;106mborder\e[0m", colored
  end

  def test_ansi_markdown_renders_basic_styles
    rendered = Kward::ANSI.markdown("# Heading\nUse `code`.\n\n```ruby\nputs :ok\n```\n- item\n", enabled: true)

    assert_includes rendered, "# \e[1mHeading\e[0m"
    assert_includes rendered, "`\e[2mcode\e[0m`"
    assert_includes rendered, "\e[90m┌─ code ruby\e[0m"
    assert_includes rendered, "\e[2m│ puts :ok\e[0m"
    assert_includes rendered, "\e[90m└───────────────────────────────────────\e[0m"
    assert_includes Kward::ANSI.strip(rendered), "- item"
  end

  def test_ansi_markdown_renders_inline_bold
    rendered = Kward::ANSI.markdown("**Exploring key handling** -> Better Markdown\n", enabled: true)

    assert_equal "\e[1mExploring key handling\e[0m -> Better Markdown\n", rendered
  end

  def test_ansi_markdown_renders_inline_links_and_emphasis
    rendered = Kward::ANSI.markdown("Use *italic*, _also_, ~~gone~~, and [docs](https://example.test).\n", enabled: true)

    assert_equal "Use \e[3mitalic\e[0m, \e[3malso\e[0m, \e[9mgone\e[0m, and \e[36mdocs\e[0m (\e[2mhttps://example.test\e[0m).\n", rendered
  end

  def test_ansi_markdown_renders_blockquotes_and_task_lists
    rendered = Kward::ANSI.markdown("> quoted **text**\n- [ ] open\n- [x] done\n* [X] also\n", enabled: true)

    assert_equal "\e[90m│\e[0m quoted \e[1mtext\e[0m\n\e[90m☐\e[0m open\n\e[32m☑\e[0m done\n\e[32m☑\e[0m also\n", rendered
  end

  def test_ansi_markdown_renders_task_lists_without_color
    rendered = Kward::ANSI.markdown("- [ ] open\n- [x] done\n", enabled: false)

    assert_equal "☐ open\n☑ done\n", rendered
  end

  def test_ansi_markdown_separates_code_fences_without_color
    rendered = Kward::ANSI.markdown("```ruby\nputs :ok\n```\n", enabled: false)

    assert_equal "┌─ code ruby\n│ puts :ok\n└───────────────────────────────────────\n", rendered
  end

  def test_ansi_sanitizes_transcript_but_preserves_sgr_color
    text = "\e[2J\e[31mred\e[0m\e_Ginline=1:payload\e\\\e]0;title\a"

    assert_equal "\e[31mred\e[0m", Kward::ANSI.sanitize_transcript(text)
  end

  def test_ansi_wraps_visible_width_without_counting_sgr_color
    rows = Kward::ANSI.wrap_visible("\e[31mabcdef\e[0m", 3)

    assert_equal ["\e[31mabc", "def\e[0m"], rows
    assert_equal ["abc", "def"], rows.map { |row| Kward::ANSI.strip(row) }
  end

  def test_ansi_enablement_respects_environment_overrides
    output = FakeInput.new("", tty: false)

    assert Kward::ANSI.enabled?(output, env: { "KWARD_COLOR" => "always" })
    refute Kward::ANSI.enabled?(output, env: { "KWARD_COLOR" => "never" })
    refute Kward::ANSI.enabled?(FakeInput.new("", tty: true), env: { "NO_COLOR" => "1" })
    assert Kward::ANSI.enabled?(output, env: { "FORCE_COLOR" => "1" })
  end

end
