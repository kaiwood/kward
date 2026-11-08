require_relative "test_helper"
require_relative "../lib/kward/shell/script_runner"
require_relative "../lib/kward/shell/native_vi"

class TestNativeShellVi < KwardTestCase
  def setup
    super
    @runtime = Kward::NativeShell::Runtime.new(env: { "HISTFILE" => "", "LC_ALL" => "C" }, hosted: false)
    @editor = Kward::NativeShell::ViEditor.new(@runtime)
  end

  def teardown
    @runtime.send(:close_resources)
    super
  end

  def edit(keys)
    characters = keys.chars
    @bells = 0
    @editor.read(get: -> { characters.shift }, changed: ->(*) {}, alert: -> { @bells += 1 })
  end

  def test_insert_erase_kill_quote_and_word_erase
    assert_equal "hello!\n", edit("hello?\x7f!\n").text
    assert_equal "new\n", edit("old\x15new\n").text
    assert_equal "one !\n", edit("one two\x17!\n").text
    assert_equal "literal\e\n", edit("literal\x16\e\n").text
    assert_nil edit("\x04")
  end

  def test_motions_deletion_yank_put_and_counts
    assert_equal "aXbc\n", edit("abc\e0liX\n").text
    assert_equal "three\n", edit("one two three\e02dw\n").text
    assert_equal "abcabc\n", edit("abc\e0y$$p\n").text
    assert_equal "c\n", edit("abc\e02x\n").text
    assert_equal "c\n", edit("abc\e99X\n").text # X removes preceding characters, not the cursor character
  end

  def test_find_replace_case_and_undo
    assert_equal "aXXd\n", edit("abcd\e0l2rX\n").text
    assert_equal "ABC\n", edit("abc\e099~\n").text
    assert_equal "abc\n", edit("abc\e0xu\n").text
    assert_equal "abc\n", edit("abc\e0xxU\n").text
    assert_equal "d\n", edit("abcd\e0dfc\n").text
    assert_equal "bcd\n", edit("abcd\e0dtb\n").text
  end

  def test_repeat_survives_lines_and_count_override
    assert_equal "bc\n", edit("abc\e0x\n").text
    assert_equal "ef\n", edit("def\e0.\n").text
    assert_equal "ij\n", edit("ghij\e02.\n").text
    assert_equal "wordswords\n", edit("\eAwords\e.\n").text
    assert_equal "saved\n", edit("\eAsaved\n").text
    assert_equal "nextsaved\n", edit("next\e.\n").text
  end

  def test_history_navigation_search_copy_and_undo
    @runtime.history.add("printf one")
    @runtime.history.add("printf two")
    assert_equal "printf one\n", edit("draft\e2k\n").text
    assert_equal "draft\n", edit("draft\ekj\n").text
    assert_equal "printf two\n", edit("\ek0xu\n").text
    assert_equal "printf one\n", edit("\e/one\n\n").text
    assert_equal "printf two\n", edit("\eG?two\n\n").text
    assert_equal "printf one\n", edit("\e1G\n").text
    assert_equal "echo two\n", edit("echo\e_\n").text
  end

  def test_comments_external_editor_and_alias_commands
    assert_equal "#unused\n", edit("unused\e#").text
    request = edit("printf edited\ev")
    assert request.external
    assert_equal "printf edited", request.text
    @runtime.aliases["_a"] = "A!\e"
    assert_equal "hello!\n", edit("hello\e@a\n").text
  end

  def test_remaining_motion_and_change_families
    cases = {
      "one.two three\e0erX\n" => "onX.two three\n",
      "one.two three\e0wrX\n" => "oneXtwo three\n",
      "one.two three\e0WrX\n" => "one.two Xhree\n",
      "one.two three\ebrX\n" => "one.two Xhree\n",
      "one.two three\eBrX\n" => "one.two Xhree\n",
      "one.two three\e0ErX\n" => "one.twX three\n",
      "  abc\e^rX\n" => "  Xbc\n",
      "abc\e99|rX\n" => "abX\n",
      "abc\e99hrX\n" => "Xbc\n",
      "abacad\e02farX\n" => "abacXd\n",
      "abacad\eFarX\n" => "abacXd\n",
      "abacad\e0tcrX\n" => "abXcad\n",
      "abacad\eTbrX\n" => "abXcad\n",
      "axbxcx\e0fx;rX\n" => "axbXcx\n",
      "axbxcx\e0fx;,rX\n" => "aXbxcx\n",
      "abc\e0lCZ\n" => "aZ\n",
      "abc\eSZ\n" => "Z\n",
      "abc\e0lRZX\n" => "aZX\n",
      "abc\edd\n" => "\n",
      "abc\eyy0P\n" => "abcabc\n",
      "abc\e0x2p\n" => "baac\n",
      "abc\e0ccnew\n" => "new\n",
      "abc\e0lD\n" => "a\n",
      "abc\e0Y$P\n" => "ababcc\n"
    }
    cases.each { |keys, expected| assert_equal expected, edit(keys).text, keys.inspect }
  end

  def test_pathname_completion_escapes_data_and_directory_suffixes
    Dir.mktmpdir do |dir|
      @runtime.run("cd #{Shellwords.escape(dir)}")
      File.write(File.join(dir, "alpha"), "")
      File.write(File.join(dir, "alpine"), "")
      File.write(File.join(dir, "semi;colon"), "")
      Dir.mkdir(File.join(dir, "folder"))
      assert_equal "cat alp\n", edit("cat al\e\\\n").text
      assert_equal "cat alpha alpine\n", edit("cat al\e*\n").text
      assert_equal "cat semi\\;colon \n", edit("cat semi\e\\\n").text
      assert_equal "cd folder/\n", edit("cd fold\e\\\n").text
      assert_equal ["folder/"], @runtime.vi_expansions("fold", full: false)
      assert_equal ["alpha", "alpine"], @runtime.vi_expansions("al", full: true)
    end
  end

  def test_literal_interrupt_and_interrupt_during_multi_character_commands
    assert_equal "a\x03b\n", edit("a\x16\x03b\n").text
    assert_raises(Interrupt) { edit("abc\x03") }
    assert_raises(Interrupt) { edit("abc\ef\x03") }
    assert_raises(Interrupt) { edit("abc\e/pattern\x03") }
  end

  def test_hosted_vi_is_rejected_and_disabling_round_trips
    runtime = Kward::NativeShell::Runtime.new(env: {}, hosted: true, interactive: true)
    error = StringIO.new
    assert_equal 2, runtime.run("set -o vi", error: error)
    assert_includes error.string, "standalone-only"
    assert_equal 0, runtime.run("set +o vi", error: error)
    refute runtime.option_enabled?("vi")
  ensure
    runtime&.send(:close_resources)
  end

  def test_default_prompts_and_control_safe_cell_rendering
    error = StringIO.new
    assert_equal "$ ", @runtime.prompt_text("PS1", error: error)
    assert_equal "> ", @runtime.prompt_text("PS2", error: error)
    assert_equal "+ ", @runtime.prompt_text("PS4", error: error)
    Kward::NativeShell::Locale.with("LC_ALL" => "C") do
      cells = Kward::TerminalText.locale_cells("a\0\e\n")
      assert_equal "a^@^[^J", cells.map(&:first).join
      assert_equal 7, cells.sum(&:last)
    end
  end

  def test_locale_characters_case_and_cell_widths
    @runtime.variables["LC_ALL"] = "C.UTF-8"
    begin
      Kward::NativeShell::Locale.with(@runtime.variables) { }
    rescue Kward::NativeShell::ExecutionError
      skip "C.UTF-8 locale is not installed"
    end
    assert_equal "Été\n", edit("été\e0~\n").text
    Kward::NativeShell::Locale.with(@runtime.variables) do
      assert_equal [2, 1, 0], Kward::TerminalText.locale_cells("界e\u0301").map(&:last)
    end
  end

  def test_long_lines_are_not_truncated_to_the_display_window
    text = "a" * 5000
    assert_equal "X#{text[1..]}\n", edit("#{text}\e0rX\n").text
  end

  def test_terminal_sequences_load_without_gems_for_native_fallback
    require "open3"
    out, error, status = Open3.capture3(RbConfig.ruby, "--disable=gems", "-I", File.expand_path("../lib", __dir__),
      "-e", 'require "kward/terminal/sequences"; print Kward::TerminalSequences.osc52("ok")')
    assert status.success?, error
    assert_equal "\e]52;c;b2s=\a", out
  end

  def test_invalid_commands_and_history_do_not_change_line
    assert_equal "abc\n", edit("abc\e0Fz99kq\n").text
    assert_operator @bells, :>=, 3
    @runtime.aliases["_a"] = "@a"
    assert_equal "abc\n", edit("abc\e@a\n").text
    assert_equal 1, @bells
  end
end
