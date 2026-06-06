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

    assert_includes rendered, "\e[1m# Heading\e[0m"
    assert_includes rendered, "`\e[2mcode\e[0m`"
    assert_includes rendered, "\e[90m┌─ code ruby\e[0m"
    assert_includes rendered, "\e[2m│ puts :ok\e[0m"
    assert_includes rendered, "\e[90m└───────────────────────────────────────\e[0m"
    assert_includes Kward::ANSI.strip(rendered), "- item"
  end

  def test_ansi_markdown_separates_code_fences_without_color
    rendered = Kward::ANSI.markdown("```ruby\nputs :ok\n```\n", enabled: false)

    assert_equal "┌─ code ruby\n│ puts :ok\n└───────────────────────────────────────\n", rendered
  end

  def test_ansi_enablement_respects_environment_overrides
    output = FakeInput.new("", tty: false)

    assert Kward::ANSI.enabled?(output, env: { "KWARD_COLOR" => "always" })
    refute Kward::ANSI.enabled?(output, env: { "KWARD_COLOR" => "never" })
    refute Kward::ANSI.enabled?(FakeInput.new("", tty: true), env: { "NO_COLOR" => "1" })
    assert Kward::ANSI.enabled?(output, env: { "FORCE_COLOR" => "1" })
  end

end
