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

  def test_ansi_colorizes_semantic_palette
    assert_equal "\e[36mactivity\e[0m", Kward::ANSI.colorize("activity", :activity, enabled: true)
    assert_equal "\e[32msuccess\e[0m", Kward::ANSI.colorize("success", :success, enabled: true)
    assert_equal "\e[33mcaution\e[0m", Kward::ANSI.colorize("caution", :caution, enabled: true)
    assert_equal "\e[31mfailure\e[0m", Kward::ANSI.colorize("failure", :failure, enabled: true)
    assert_equal "\e[35mtool\e[0m", Kward::ANSI.colorize("tool", :tool, enabled: true)
    assert_equal "\e[90mmetadata\e[0m", Kward::ANSI.colorize("metadata", :metadata, enabled: true)
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

  def test_markdown_stream_emits_text_before_incomplete_inline_markup
    stream = Kward::ANSI::MarkdownStream.new(enabled: true)

    assert_equal "Start ", stream.render("Start **smo")
    assert_equal "\e[1msmooth\e[0m ending", stream.render("oth** ending")
    assert_equal " and ", stream.render(" and `co")
    assert_equal "`\e[2mcode\e[0m`", stream.render("de`")
  end

  def test_markdown_stream_preserves_split_block_markup
    stream = Kward::ANSI::MarkdownStream.new(enabled: false)

    assert_empty stream.render("```ru")
    assert_equal "┌─ code ruby\n", stream.render("by\n")
    assert_empty stream.render("puts :ok")
    assert_equal "│ puts :ok\n└───────────────────────────────────────\n", stream.render("\n```\n")
  end

  def test_markdown_stream_matches_full_render_across_chunk_boundaries
    samples = [
      "# Heading\n",
      "Use **bold**, *italic*, _also_, ~~gone~~, `code`, and [docs](https://example.test).\n",
      "> quoted **text**\n",
      "- [x] done\n",
      "```ruby\nputs :ok\n```\n"
    ]

    samples.each do |source|
      expected = Kward::ANSI.markdown(source, enabled: true)
      (1...source.length).each do |split|
        stream = Kward::ANSI::MarkdownStream.new(enabled: true)
        rendered = stream.render(source[0...split])
        rendered << stream.render(source[split..])
        rendered << stream.render("", final: true)

        assert_equal expected, rendered, "split #{source.inspect} at #{split}"
      end
    end
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

  def test_ansi_strips_terminal_control_sequences
    text = "a\e[31mb\e[0mc\e]52;c;payload\a\e_Ginline=1:payload\e\\\e[2Jd"

    assert_equal "abcd", Kward::ANSI.strip(text)
  end

  def test_ansi_wraps_visible_width_without_counting_sgr_color
    rows = Kward::ANSI.wrap_visible("\e[31mabcdef\e[0m", 3)

    assert_equal ["\e[31mabc", "def\e[0m"], rows
    assert_equal ["abc", "def"], rows.map { |row| Kward::ANSI.strip(row) }
  end

  def test_ansi_wraps_visible_width_without_counting_non_sgr_sequences
    rows = Kward::ANSI.wrap_visible("ab\e]0;title\acd\e[2Jef", 2)

    assert_equal ["ab", "cd", "ef"], rows
  end

  def test_ansi_enablement_respects_environment_overrides
    output = FakeInput.new("", tty: false)

    assert Kward::ANSI.enabled?(output, env: { "KWARD_COLOR" => "always" })
    refute Kward::ANSI.enabled?(output, env: { "KWARD_COLOR" => "never" })
    refute Kward::ANSI.enabled?(FakeInput.new("", tty: true), env: { "NO_COLOR" => "1" })
    assert Kward::ANSI.enabled?(output, env: { "FORCE_COLOR" => "1" })
  end

end
