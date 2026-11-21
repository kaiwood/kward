require_relative "test_helper"
require "fiddle"
require "open3"
require "pty"
require "shellwords"
require "timeout"

class TestCLIShell < KwardTestCase
  EXECUTABLE = File.expand_path("../exe/kward", __dir__)
  MAIN = File.expand_path("../lib/main.rb", __dir__)
  PROMPT = "ready> "
  PASTE_ON = "\e[?2004h"
  PASTE_OFF = "\e[?2004l"

  def test_shell_starts_without_agent_dependencies_or_config_and_passes_arguments_through
    fiddle_paths = Gem.loaded_specs["fiddle"]&.full_require_paths || []
    ruby_options = ["--disable=gems,rubyopt", *fiddle_paths.flat_map { |path| ["-I", path] }]
    Dir.mktmpdir do |home|
      output, error, status = Open3.capture3({ "HOME" => home, "KWARD_CONFIG_DIR" => nil, "RUBYOPT" => nil },
        RbConfig.ruby, *ruby_options, EXECUTABLE, "shell", "-c", 'printf "<%s>\n" "$0" "$@"; exit 17',
        "named", "--working-directory", "--", "--skip-config", "a b")
      assert_equal "<named>\n<--working-directory>\n<-->\n<--skip-config>\n<a b>\n", output, error
      assert_empty error
      assert_equal 17, status.exitstatus
      assert_empty Dir.children(home)
    end
  end

  def test_pipe_keeps_command_input_unbuffered
    output, error, status = Open3.capture3(RbConfig.ruby, MAIN, "shell",
      stdin_data: "read value\nfrom-stdin\nprintf '<%s>\\n' \"$value\"\n")
    assert status.success?, error
    assert_equal "<from-stdin>\n", output
    assert_empty error
  end

  def test_shell_help_uses_subcommand_name
    output, error, status = Open3.capture3(RbConfig.ruby, EXECUTABLE, "shell", "--help")
    assert status.success?, error
    assert_includes output, "Usage: kward shell"
  end

  def test_interactive_kwshrc_executes_native_code_in_order_without_reading_json
    Dir.mktmpdir do |home|
      config = File.join(home, "shell settings")
      Dir.mkdir(config)
      File.write(File.join(config, "config.json"), "not JSON")
      File.write(File.join(config, "kwshrc"), <<~'KWSHRC')
        cd "$HOME"
        source './extra rc' first
        alias report_config='show_config'
        show_config() {
          printf 'rc:%s:%s\n' "$SHELL_TEST_COLOR" "$1"
        }
      KWSHRC
      File.write(File.join(home, "extra rc"), <<~'KWSHRC')
        if [ "$1" = first ]; then
          eval 'export SHELL_TEST_COLOR=first'
        fi
      KWSHRC
      File.write(File.join(home, ".kwshrc"), <<~'KWSHRC')
        export SHELL_TEST_COLOR="$SHELL_TEST_COLOR:override"
        export ENV="$HOME/unwanted-startup"
      KWSHRC
      File.write(File.join(home, "unwanted-startup"), "exit 99\n")
      File.write(File.join(home, "startup"), 'export SHELL_TEST_COLOR="$SHELL_TEST_COLOR:env"')
      env = { "HOME" => home, "KWARD_CONFIG_PATH" => File.join(config, "config.json"), "ENV" => nil, "SHELL_TEST_COLOR" => nil }

      with_terminal(env) do |reader, writer, pid|
        read_until(reader, PROMPT)
        writer.write("report_con\tworks\n")
        read_until(reader, "\r\nrc:first:override:works\r\n")
        read_until(reader, PROMPT)
        writer.write("exit\n")
        assert_equal 0, wait_for_exit(pid).exitstatus
      end

      output, error, status = Open3.capture3(env.merge("ENV" => '${HOME}/startup'), RbConfig.ruby, EXECUTABLE,
                                            "shell", "-ic", 'report_config "$1"', "name", "argument")
      assert status.success?, error
      assert_equal "rc:first:override:env:argument\n", output
      assert_empty error
    end
  end

  def test_noninteractive_shell_and_separate_kwsh_do_not_execute_kwshrc
    Dir.mktmpdir do |home|
      Dir.mkdir(File.join(home, ".kward"))
      File.write(File.join(home, ".kward", "kwshrc"), "exit 91\n")
      File.write(File.join(home, ".kwshrc"), "exit 92\n")
      script = File.join(home, "script")
      File.write(script, "printf clean\n")
      env = { "HOME" => home, "KWARD_CONFIG_PATH" => nil, "ENV" => nil }
      kwsh = File.expand_path("../exe/kwsh", __dir__)

      [[EXECUTABLE, "shell", "-c", "printf clean"], [EXECUTABLE, "shell", script],
       [EXECUTABLE, "shell"], [kwsh, "-ic", "printf clean"]].each do |command|
        output, error, status = Open3.capture3(env, RbConfig.ruby, *command, stdin_data: "printf clean\n")
        assert status.success?, "#{command.inspect}: #{error}"
        assert_equal "clean", output
        assert_empty error
      end
    end
  end

  def test_malformed_kwshrc_is_reported_without_exposing_its_contents
    Dir.mktmpdir do |home|
      File.write(File.join(home, ".kwshrc"), "export PRIVATE='fixture-secret\n")
      with_terminal("HOME" => home, "KWARD_CONFIG_PATH" => nil) do |reader, writer, pid|
        startup = read_until(reader, PROMPT)
        assert_match(/kwsh: line \d+: unclosed single quote/, startup)
        refute_includes startup, "fixture-secret"
        writer.write("printf 'still running\\n'\n")
        read_until(reader, "\r\nstill running\r\n")
        read_until(reader, PROMPT)
        writer.write("exit\n")
        assert_equal 0, wait_for_exit(pid).exitstatus
      end
    end
  end

  def test_tab_completes_live_functions_executables_builtins_and_paths
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "name with $cash.txt"), "from-file\n")
      File.write(File.join(dir, "project-file"), "")
      Dir.mkdir(File.join(dir, "project space"))
      File.write(File.join(dir, "test-command"), "#!/bin/sh\nprintf 'from-executable\\n'\n", perm: 0o700)
      with_terminal do |reader, writer, _pid|
        read_until(reader, PROMPT)
        writer.write("cd #{Shellwords.escape(dir)}; PATH=.; test_function() { /usr/bin/printf 'from-function\\n'; }\n")
        read_until(reader, PROMPT)
        writer.write(":; test_func\t\n")
        read_until(reader, "\r\nfrom-function\r\n")
        read_until(reader, PROMPT)
        writer.write("TESTRUN=yes test-com\t\n")
        read_until(reader, "\r\nfrom-executable\r\n")
        read_until(reader, PROMPT)
        writer.write("/bin/cat \"name wZZ\"\e[D\e[D\e[D\t\n")
        read_until(reader, "\r\nfrom-file\r\n")
        read_until(reader, PROMPT)
        writer.write("cd proj\t\n")
        read_until(reader, PROMPT)
        writer.write("pw\t\n")
        assert_includes read_until(reader, "/project space\r\n"), "/project space\r\n"
      end
    end
  end

  def test_tab_does_not_evaluate_command_substitutions_in_the_draft
    Dir.mktmpdir do |dir|
      marker = File.join(dir, "not-executed")
      with_terminal do |reader, writer, pid|
        read_until(reader, PROMPT)
        writer.write("printf '%s' \"$(touch #{Shellwords.escape(marker)})\"\t\x03")
        read_until(reader, PASTE_OFF)
        read_until(reader, PASTE_ON + "\r" + PROMPT)
        refute File.exist?(marker)
        writer.write("exit 0\n")
        assert_equal 0, wait_for_exit(pid).exitstatus
      end
    end
  end

  def test_completion_menu_cycles_cancels_and_accepts_without_submitting
    Dir.mktmpdir do |dir|
      ["match-left", "match right"].each { |name| File.write(File.join(dir, name), "") }
      with_terminal do |reader, writer, pid|
        read_until(reader, PROMPT)
        writer.write("cd #{Shellwords.escape(dir)}\n")
        read_until(reader, PROMPT)
        writer.write("printf '<%s>\\n' mat\t\t")
        read_until(reader, "> match right")
        writer.write("\t")
        read_until(reader, "> match-left")
        writer.write("\e[Z")
        read_until(reader, "> match right")
        writer.write("\e")
        read_until(reader, "\r#{PROMPT}printf '<%s>\\n' match\e[K")
        writer.write("\t\t")
        read_until(reader, "> match right")
        writer.write("\n")
        draft = read_until(reader, "\r#{PROMPT}printf '<%s>\\n' match\\ right \e[K")
        refute_includes draft, PASTE_OFF
        writer.write("\n")
        read_until(reader, "\r\n<match right>\r\n")
        read_until(reader, PROMPT)
        writer.write("exit\n")
        assert_equal 0, wait_for_exit(pid).exitstatus
      end
    end
  end

  def test_cursor_editing_and_history_restore_a_draft
    with_terminal do |reader, writer, pid|
      read_until(reader, PASTE_ON + "\r" + PROMPT)
      writer.write("printf 'edit:%s\\n' AZ\e[DB\e[C\e[Hx\e[H\e[3~\e[F!\x7f\n")
      read_until(reader, "\r\nedit:ABZ\r\n")
      read_until(reader, PROMPT)
      writer.write("printf 'draft:%s\\n' saved\eOA\eOB\n")
      read_until(reader, "\r\ndraft:saved\r\n")
      read_until(reader, PROMPT)
      writer.write("\e[A\e[A\n")
      read_until(reader, "\r\nedit:ABZ\r\n")
      read_until(reader, PROMPT)
      writer.write("\x04")
      assert_equal 0, wait_for_exit(pid).exitstatus
    end
  end

  def test_option_arrows_and_meta_letters_move_by_words
    with_terminal do |reader, writer, pid|
      read_until(reader, PROMPT)
      writer.write("echo one two three\e[1;3D\eBX\e[1;3CY\eFZ\n")
      read_until(reader, "\r\none Xtwo YthreeZ\r\n")
      read_until(reader, PROMPT)
      writer.write("exit\n")
      assert_equal 0, wait_for_exit(pid).exitstatus
    end
  end

  def test_word_cuts_support_both_option_backspace_encodings_and_yank_in_order
    with_terminal("LC_ALL" => "C.UTF-8") do |reader, writer, pid|
      prompt = read_until(reader, PROMPT)
      skip "C.UTF-8 locale is not installed" if prompt.include?("unavailable locale")
      writer.write("printf '<%s>\\n' keep café/notes.txt   tail\e\x7F\e\b\n")
      read_until(reader, "\r\n<keep>\r\n")
      read_until(reader, PROMPT)
      writer.write("printf '<%s>\\n' \x19\n")
      read_until(reader, "\r\n<café/notes.txt>\r\n<tail>\r\n".b)
      read_until(reader, PROMPT)
      writer.write("printf '<%s>\\n' keep discard tail\eb\eb\ed\n")
      read_until(reader, "\r\n<keep>\r\n<tail>\r\n")
      read_until(reader, PROMPT)
      writer.write("printf '<%s>\\n' keep discard\x17\n")
      read_until(reader, "\r\n<keep>\r\n")
      read_until(reader, PROMPT)
      writer.write("exit\n")
      assert_equal 0, wait_for_exit(pid).exitstatus
    end
  end

  def test_line_cuts_can_be_yanked_into_the_draft
    with_terminal do |reader, writer, pid|
      read_until(reader, PROMPT)
      writer.write("printf '<%s>\\n' keep discard\eb\x0B\x0B\n")
      read_until(reader, "\r\n<keep>\r\n")
      read_until(reader, PROMPT)
      writer.write("printf '<%s>\\n' \x19\n")
      read_until(reader, "\r\n<discard>\r\n")
      read_until(reader, PROMPT)
      writer.write("printf 'whole-line\\n'\eb\x15")
      read_until(reader, "\r#{PROMPT}\e[K")
      writer.write("\x19")
      draft = read_until(reader, "\r#{PROMPT}printf 'whole-line\\n'\e[K")
      refute_includes draft, PASTE_OFF
      writer.write("\n")
      read_until(reader, "\r\nwhole-line\r\n")
      read_until(reader, PROMPT)
      writer.write("exit\n")
      assert_equal 0, wait_for_exit(pid).exitstatus
    end
  end

  def test_cut_to_end_of_line_keeps_later_lines_of_a_pasted_draft
    with_terminal do |reader, writer, pid|
      read_until(reader, PROMPT)
      writer.write("\e[200~echo one discard\necho two\e[201~\e[A\x0B\n")
      read_until(reader, "\r\none\r\ntwo\r\n")
      read_until(reader, PROMPT)
      writer.write("exit\n")
      assert_equal 0, wait_for_exit(pid).exitstatus
    end
  end

  def test_open_shells_merge_history_and_find_new_entries_by_prefix
    Dir.mktmpdir do |dir|
      env = { "HISTFILE" => File.join(dir, "history") }
      with_terminal(env) do |first, first_input, first_pid|
        with_terminal(env) do |second, second_input, second_pid|
          read_until(first, PROMPT)
          read_until(second, PROMPT)
          first_input.write("echo match-first\n")
          read_until(first, "\r\nmatch-first\r\n")
          read_until(first, PROMPT)
          second_input.write("echo match-second\n")
          read_until(second, "\r\nmatch-second\r\n")
          read_until(second, PROMPT)
          second_input.write("echo unrelated\n")
          read_until(second, "\r\nunrelated\r\n")
          read_until(second, PROMPT)
          first_input.write("echo match\e[A")
          read_until(first, "\r#{PROMPT}echo match-second\e[K")
          first_input.write("\e[A")
          read_until(first, "\r#{PROMPT}echo match-first\e[K")
          first_input.write("\e[B\e[B\n")
          read_until(first, "\r\nmatch\r\n")
          read_until(first, PROMPT)
          second_input.write("\x12echo match")
          read_until(second, "(reverse-i-search: echo match): echo match\e[K")
          second_input.write("\x07exit\n")
          first_input.write("exit\n")
          assert_equal 0, wait_for_exit(second_pid).exitstatus
          assert_equal 0, wait_for_exit(first_pid).exitstatus
        end
      end
      assert_equal 0600, File.stat(env.fetch("HISTFILE")).mode & 0777
    end
  end

  def test_history_suggestions_are_visible_but_only_right_arrow_accepts_them
    with_terminal do |reader, writer, pid|
      read_until(reader, PROMPT)
      writer.write("echo local-suggestion\n")
      read_until(reader, "\r\nlocal-suggestion\r\n")
      read_until(reader, PROMPT)
      writer.write("echo local")
      read_until(reader, "echo local\e[2m-suggestion\e[0m")
      writer.write("\n")
      read_until(reader, "\r\nlocal\r\n")
      read_until(reader, PROMPT)
      writer.write("echo local\e[C")
      read_until(reader, "\r#{PROMPT}echo local-suggestion\e[K")
      writer.write("\n")
      read_until(reader, "\r\nlocal-suggestion\r\n")
      read_until(reader, PROMPT)
      writer.write("exit\n")
      assert_equal 0, wait_for_exit(pid).exitstatus
    end
  end

  def test_disabling_autosuggestions_also_disables_right_arrow_acceptance
    with_terminal("KWSH_AUTOSUGGEST" => "0") do |reader, writer, pid|
      read_until(reader, PROMPT)
      writer.write("echo disable-suggestion\n")
      read_until(reader, "\r\ndisable-suggestion\r\n")
      read_until(reader, PROMPT)
      writer.write("echo disable\e[C\n")
      output = read_until(reader, "\r\ndisable\r\n")
      refute_includes output, "\e[2m"
      read_until(reader, PROMPT)
      writer.write("exit\n")
      assert_equal 0, wait_for_exit(pid).exitstatus
    end
  end

  def test_incremental_history_search_moves_in_both_directions_and_can_restore_the_draft
    with_terminal do |reader, writer, pid|
      read_until(reader, PROMPT)
      writer.write("echo Match-old\n")
      read_until(reader, "\r\nMatch-old\r\n")
      read_until(reader, PROMPT)
      writer.write("echo Match-new\n")
      read_until(reader, "\r\nMatch-new\r\n")
      read_until(reader, PROMPT)

      writer.write("echo AB\e[D\x12match")
      read_until(reader, "(reverse-i-search: match): echo Match-new")
      writer.write("\x12")
      read_until(reader, "(reverse-i-search: match): echo Match-old")
      writer.write("\x13")
      read_until(reader, "(forward-i-search: match): echo Match-new")
      writer.write("\x07X\n")
      read_until(reader, "\r\nAXB\r\n")
      read_until(reader, PROMPT)
      writer.write("exit\n")
      assert_equal 0, wait_for_exit(pid).exitstatus
    end
  end

  def test_failed_history_search_does_not_submit_a_stale_match
    with_terminal do |reader, writer, pid|
      read_until(reader, PROMPT)
      writer.write("echo found\n")
      read_until(reader, "\r\nfound\r\n")
      read_until(reader, PROMPT)
      writer.write("\x12foundx")
      read_until(reader, "(failed reverse-i-search: foundx): echo found")
      writer.write("\n")
      waiting = read_until(reader, "\a")
      refute_includes waiting, PASTE_OFF
      writer.write("\x7f")
      read_until(reader, "(reverse-i-search: found): echo found")
      writer.write("\n")
      read_until(reader, "\r\nfound\r\n")
      read_until(reader, PROMPT)
      writer.write("exit\n")
      assert_equal 0, wait_for_exit(pid).exitstatus
    end
  end

  def test_clear_screen_redraws_the_draft_without_erasing_scrollback
    with_terminal do |reader, writer, pid|
      read_until(reader, PROMPT)
      writer.write("echo AB\e[D\x0c")
      redraw = read_until(reader, "\e[2J\e[H")
      redraw << read_until(reader, "\r#{PROMPT}echo AB\e[K")
      refute_includes redraw, "\e[3J"
      writer.write("X\n")
      read_until(reader, "\r\nAXB\r\n")
      read_until(reader, PROMPT)
      writer.write("exit\n")
      assert_equal 0, wait_for_exit(pid).exitstatus
    end
  end

  def test_transposition_and_undo_restore_text_and_cursor
    with_terminal do |reader, writer, pid|
      read_until(reader, PROMPT)
      writer.write("echo teh\x14\n")
      read_until(reader, "\r\nthe\r\n")
      read_until(reader, PROMPT)
      writer.write("echo abc\e[D\e[D\x14\x1fX\n")
      read_until(reader, "\r\naXbc\r\n")
      read_until(reader, PROMPT)
      writer.write("echo keep discard\x17\x1f\n")
      read_until(reader, "\r\nkeep discard\r\n")
      read_until(reader, PROMPT)
      writer.write("exit\n")
      assert_equal 0, wait_for_exit(pid).exitstatus
    end
  end

  def test_meta_period_inserts_the_previous_shell_word_with_quoting_intact
    with_terminal do |reader, writer, pid|
      read_until(reader, PROMPT)
      writer.write("echo 'two words'\n")
      read_until(reader, "\r\ntwo words\r\n")
      read_until(reader, PROMPT)
      writer.write("printf '<%s>\\n' \e.")
      draft = read_until(reader, "printf '<%s>\\n' 'two words'\e[K")
      refute_includes draft, PASTE_OFF
      writer.write("\n")
      read_until(reader, "\r\n<two words>\r\n")
      read_until(reader, PROMPT)
      writer.write("exit\n")
      assert_equal 0, wait_for_exit(pid).exitstatus
    end
  end

  def test_yank_pop_replaces_only_the_just_yanked_text_and_wraps
    with_terminal do |reader, writer, pid|
      read_until(reader, PROMPT)
      writer.write("older\x15new\x15echo \x19\ey")
      read_until(reader, "\r#{PROMPT}echo older\e[K")
      writer.write("\eY")
      read_until(reader, "\r#{PROMPT}echo new\e[K")
      writer.write("\x1f!\ey\n")
      read_until(reader, "\r\nolder!\r\n")
      read_until(reader, PROMPT)
      writer.write("exit\n")
      assert_equal 0, wait_for_exit(pid).exitstatus
    end
  end

  def test_multiline_bracketed_paste_requires_enter_and_preserves_continuations
    with_terminal do |reader, writer, pid|
      read_until(reader, PROMPT)
      writer.write("\e[20")
      writer.write("0~printf 'one\\n'\r\nprintf 'two\\n'\e[201~")
      draft = read_until(reader, "printf 'one\\n'\e[K\r\nprintf 'two\\n'\e[K")
      refute_includes draft, "\r\none\r\n"
      refute_includes draft, PASTE_OFF
      writer.write("\n")
      submitted = read_until(reader, "\r\none\r\ntwo\r\n")
      assert_includes submitted, PASTE_OFF
      read_until(reader, PROMPT)
      writer.write("if true; then\n")
      read_until(reader, "\rmore> ")
      writer.write("printf 'continued\\n'; fi\n")
      read_until(reader, "\r\ncontinued\r\n")
      read_until(reader, PROMPT)
      writer.write("exit\n")
      assert_equal 0, wait_for_exit(pid).exitstatus
    end
  end

  def test_multiline_arrows_and_home_edit_the_selected_line
    with_terminal do |reader, writer, pid|
      read_until(reader, PROMPT)
      writer.write("\e[200~echo AB\necho CD\e[201~\e[A\e[D" + "X\e[B\x01" + "printf '>' ; ")
      read_until(reader, "printf '>' ; echo CD\e[K")
      writer.write("\n")
      read_until(reader, "\r\nAXB\r\n>CD\r\n")
      read_until(reader, PROMPT)
      writer.write("echo first\e[13;2uecho second\n")
      read_until(reader, "\r\nfirst\r\nsecond\r\n")
      read_until(reader, PROMPT)
      writer.write("exit\n")
      assert_equal 0, wait_for_exit(pid).exitstatus
    end
  end

  def test_invalid_bracketed_paste_is_discarded_without_running_partial_input
    with_terminal("LC_ALL" => "C.UTF-8") do |reader, writer, pid|
      prompt = read_until(reader, PROMPT)
      skip "C.UTF-8 locale is not installed" if prompt.include?("unavailable locale")
      writer.write("\e[200~\xff\nprintf 'not-run\\n'\n\e[201~".b)
      discarded = read_until(reader, "\a")
      refute_includes discarded, "\r\nnot-run\r\n"
      read_until(reader, PROMPT)
      writer.write("printf 'still-editing\\n'\n")
      output = read_until(reader, "\r\nstill-editing\r\n")
      refute_includes output, "\r\nnot-run\r\n"
      read_until(reader, PROMPT)
      writer.write("exit\n")
      assert_equal 0, wait_for_exit(pid).exitstatus
    end
  end

  def test_interrupt_discards_the_draft_and_read_gets_the_next_line
    with_terminal do |reader, writer, pid|
      read_until(reader, PROMPT)
      writer.write("printf 'discarded'\x03")
      read_until(reader, PASTE_OFF)
      read_until(reader, PASTE_ON + "\r" + PROMPT)
      writer.write("printf 'status:%s\\n' \"$?\"; read value\npayload\n")
      read_until(reader, "\r\nstatus:130\r\n")
      read_until(reader, PASTE_ON + "\r" + PROMPT)
      writer.write("printf '<%s>\\n' \"$value\"\n")
      read_until(reader, "\r\n<payload>\r\n")
      read_until(reader, PROMPT)
      writer.write("exit\n")
      assert_equal 0, wait_for_exit(pid).exitstatus
    end
  end

  def test_fullscreen_child_owns_the_terminal_and_can_be_suspended_and_resumed
    with_terminal do |reader, writer, pid|
      read_until(reader, PROMPT)
      program = <<~'RUBY'
        require "io/console"
        abort "terminal still raw" unless STDIN.echo?
        STDOUT.sync = true
        print "\e[?1049hchild-ready\n"
        value = STDIN.gets
        print "\e[?1049lchild:#{value}"
      RUBY
      writer.write(Shellwords.join([RbConfig.ruby, "-e", program.tr("\n", ";")]) + "\n")
      handoff = read_until(reader, "\e[?1049hchild-ready\r\n")
      assert_includes handoff, PASTE_OFF
      writer.write("\x1a")
      read_until(reader, "Stopped")
      read_until(reader, PASTE_ON + "\r" + PROMPT)
      writer.write("fg\nterminal-input\n")
      read_until(reader, "\e[?1049lchild:terminal-input\r\n")
      read_until(reader, PASTE_ON + "\r" + PROMPT)
      writer.write("exit\n")
      assert_equal 0, wait_for_exit(pid).exitstatus
    end
  end

  def test_vi_override_and_dumb_terminal_fallback
    with_terminal do |reader, writer, pid|
      read_until(reader, PROMPT)
      writer.write("set -o vi\n")
      read_until(reader, PASTE_OFF)
      refute_includes read_until(reader, PROMPT), PASTE_ON
      writer.write("xprintf 'vi\\n'\e0x\n")
      read_until(reader, "\r\nvi\r\n")
      read_until(reader, PROMPT)
      writer.write("set +o vi\n")
      read_until(reader, PASTE_ON + "\r" + PROMPT)
      writer.write("exit\n")
      assert_equal 0, wait_for_exit(pid).exitstatus
    end

    with_terminal("TERM" => "dumb") do |reader, writer, pid|
      refute_includes read_until(reader, PROMPT), PASTE_ON
      writer.write("printf 'plain\\n'\nexit\n")
      output = read_until(reader, "\r\nplain\r\n")
      refute_includes output, PASTE_ON
      assert_equal 0, wait_for_exit(pid).exitstatus
    end
  end

  def test_prompt_from_kwshrc_updates_directory_and_status_and_unset_restores_ps1
    Dir.mktmpdir do |home|
      Dir.mkdir(File.join(home, "project"))
      File.write(File.join(home, ".kwshrc"), "export PROMPT='%F{cyan}%~%f [%?] %%> '\n")
      env = { "HOME" => home, "KWARD_CONFIG_PATH" => nil, "KWARD_CONFIG_DIR" => nil }
      with_terminal(env) do |reader, writer, pid|
        read_until(reader, PASTE_ON + "\r\e[36m")
        writer.write("cd \"$HOME/project\"; false\n")
        read_until(reader, "\e[36m~/project\e[39m [1] %> \e[0m")
        writer.write("if true; then\n")
        read_until(reader, "more> ")
        writer.write("true; fi\n")
        read_until(reader, "\e[36m~/project\e[39m [0] %> \e[0m")
        writer.write("unset PROMPT\n")
        read_until(reader, "\r" + PROMPT)
        writer.write("exit\n")
        assert_equal 0, wait_for_exit(pid).exitstatus
      end
    end
  end

  def test_prompt_colors_do_not_count_toward_the_cursor_in_either_editor
    with_terminal("PROMPT" => "%F{cyan}XY%f> ") do |reader, writer, pid|
      row = "\r\e[36mXY\e[39m> \e[0m"
      read_until(reader, row + "\e[K\e[5G")
      writer.write("ab\e[D")
      read_until(reader, row + "ab\e[K\e[6G")
      writer.write("\x15set -o vi\n")
      read_until(reader, row + "\e[K\e[5G")
      writer.write("xexit\e0x\n")
      assert_equal 0, wait_for_exit(pid).exitstatus
    end
  end

  def test_truncated_prompt_resets_styles_before_the_command_line
    with_terminal("PROMPT" => "%K{20}%B%F{#a0b1c2}#{'x' * 5000}%f%b%k") do |reader, writer, pid|
      output = read_until(reader, "\e[0m\e[K")
      assert_match(/\r\e\[48;5;20m\e\[1m\e\[38;2;160;177;194mx+\e\[0m\e\[K\z/, output)
      refute_includes output, "\e[39m"
      writer.write("exit\n")
      assert_equal 0, wait_for_exit(pid).exitstatus
    end
  end

  def test_prompt_respects_no_color_and_treats_metadata_as_literal_text
    Dir.mktmpdir do |home|
      Dir.mkdir(File.join(home, "work%F{red}\e[2J"))
      env = { "HOME" => home, "PROMPT" => "%K{20}%B%~%b%k %F{#a0b1c2}%?%f > ", "NO_COLOR" => "1" }
      with_terminal(env) do |reader, writer, pid|
        read_until(reader, PASTE_ON + "\r")
        writer.write("cd \"$HOME\"/work*\n")
        output = read_until(reader, "~/work%F{red}^[[2J 0 > ")
        refute_match(/\e\[[\d;]+m/, output)
        refute_includes output, "\e[2J"
        writer.write("exit\n")
        assert_equal 0, wait_for_exit(pid).exitstatus
      end
    end
  end

  def test_plain_prompt_preserves_literals_without_running_shell_expansions
    with_terminal("TERM" => "dumb", "PROMPT" => '%F{cyan}$(exit 8) %? %unknown%f > ') do |reader, writer, pid|
      output = read_until(reader, '$(exit 8) 0 %unknown > ')
      refute_includes output, "\e[36m"
      refute_includes output, PASTE_ON
      writer.write("exit 17\n")
      assert_equal 17, wait_for_exit(pid).exitstatus
    end
  end

  def test_prompt_metadata_in_explicit_interactive_input_does_not_change_kwsh_defaults
    kwsh = File.expand_path("../exe/kwsh", __dir__)
    env = { "ENV" => nil, "PROMPT" => "%n@%m %d (%1~)%# ", "PS1" => PROMPT }
    dir = Dir.pwd
    username = Etc.getpwuid(Process.euid).name
    host = Etc.uname.fetch(:nodename).split(".", 2).first
    sigil = Process.euid.zero? ? "#" : "%"
    env.merge!("HOME" => dir, "PWD" => dir)
    _out, prompt, status = Open3.capture3(env, RbConfig.ruby, EXECUTABLE, "shell", "-i", stdin_data: "exit\n")
    assert status.success?, prompt
    assert_equal "#{username}@#{host} #{dir} (~)#{sigil} ", prompt

    _out, prompt, status = Open3.capture3(env, RbConfig.ruby, kwsh, "-i", stdin_data: "exit\n")
    assert status.success?, prompt
    assert_equal PROMPT, prompt
  end

  def test_private_history_mode_skips_disk_history_and_shell_agent_context
    client = <<~'CODE'
      def chat(messages, **)
        prompt = messages.reverse.find { |message| (message[:role] || message["role"]) == "user" }
        text = (prompt[:content] || prompt["content"]).to_s
        answer(text.include?("Last command: (none)") && !text.include?("private-fixture") ? "No captured context." : "Unexpected context.")
      end
    CODE
    Dir.mktmpdir do |dir|
      path = File.join(dir, "history")
      with_shell_agent(client, "HISTFILE" => path, "PROMPT" => "%F{cyan}ready> %f") do |reader, writer, pid|
        read_until(reader, PROMPT)
        writer.write("echo public-before\n")
        read_until(reader, "\r\npublic-before\r\n")
        read_until(reader, PROMPT)
        writer.write("history pause\n")
        private_prompt = "\r[private] \e[36mready> "
        read_until(reader, private_prompt)
        writer.write("if true; then\n")
        read_until(reader, "\r[private] more> ")
        writer.write("echo private-fixture; fi\n")
        read_until(reader, "\r\nprivate-fixture\r\n")
        read_until(reader, private_prompt)
        writer.write("? check the last command\n")
        read_until(reader, "Shell agent unavailable while history is paused.")
        read_until(reader, private_prompt)
        writer.write("history status\n")
        read_until(reader, "\r\nShell history is paused.\r\n")
        read_until(reader, private_prompt)
        writer.write("\x12private")
        read_until(reader, "(failed reverse-i-search: private): echo public-before\e[K")
        writer.write("\x07history resume\n")
        read_until(reader, "\r\e[36mready> ")
        writer.write("? check the last command\n")
        read_until(reader, "\r\nNo captured context.\r\n")
        read_until(reader, PROMPT)
        writer.write("echo public-after\n")
        read_until(reader, "\r\npublic-after\r\n")
        read_until(reader, PROMPT)
        writer.write("exit\n")
        assert_equal 0, wait_for_exit(pid).exitstatus
      end
      entries = File.readlines(path).map { |line| JSON.parse(line).last }
      assert_equal ["echo public-before", "echo public-after", "exit"], entries
    end
  end

  def test_shell_question_receives_the_last_stderr_and_exit_status_and_prepares_an_editable_draft
    client = <<~'CODE'
      def chat(messages, **)
        prompt = messages.reverse.find { |message| (message[:role] || message["role"]) == "user" }
        text = (prompt[:content] || prompt["content"]).to_s
        if text.include?("prepare a command")
          tool_result(messages) ? answer("Prepared a draft") : tool("prepare_shell_command", command: "/bin/echo draft")
        elsif text.include?("Last exit status: 23") && text.include?("<shell_output>\nfixture failure\n")
          answer("The last error was fixture failure.")
        else
          answer("Incorrect context: #{text}")
        end
      end
    CODE
    with_shell_agent(client) do |reader, writer, pid|
      read_until(reader, PROMPT)
      writer.write("/bin/sh -c 'echo fixture failure >&2; exit 23'\n")
      read_until(reader, "\r\nfixture failure\r\n")
      read_until(reader, PROMPT)
      writer.write("? what was the last error message?\n")
      read_until(reader, "\r\nThe last error was fixture failure.\r\n")
      read_until(reader, PROMPT)
      writer.write("? prepare a command\n\n")
      read_until(reader, "\r\nPrepared a draft\r\n")
      before_enter = read_until(reader, "ready> /bin/echo draft")
      refute_includes before_enter, "\r\ndraft\r\n"
      writer.write("-edited\n")
      read_until(reader, "\r\ndraft-edited\r\n")
      read_until(reader, PROMPT)
      writer.write("exit 17\n")
      assert_equal 17, wait_for_exit(pid).exitstatus
    end
  end

  def test_shell_agent_runs_explicit_commands_in_the_live_shell_and_omits_output_after_input
    client = <<~'CODE'
      def chat(messages, **)
        result = tool_result(messages)
        if result
          answer("Tool result: #{result[:content] || result["content"]}")
        elsif messages.last.to_s.include?("interactive-secret")
          answer("Leaked interactive input")
        else
          command = <<~'SH'
            export VIA_AGENT=live; /bin/echo tool-output; /bin/echo tool-error >&2
            while [ ! -f "$AGENT_TEST_GATE" ]; do /bin/sleep 0.01; done
            printf tail-output
          SH
          tool("run_shell_command", command: command, timeout_seconds: 10)
        end
      end
    CODE
    Dir.mktmpdir do |dir|
      gate = File.join(dir, "continue")
      with_shell_agent(client, "AGENT_TEST_GATE" => gate) do |reader, writer, pid|
        read_until(reader, PROMPT)
        writer.write("/bin/sh -c 'echo waiting; read -r value; echo \"$value\"'\n")
        read_until(reader, "\r\nwaiting\r\n")
        writer.write("interactive-secret\n")
        read_until(reader, "\r\ninteractive-secret\r\n")
        read_until(reader, PROMPT)
        writer.write("? set VIA_AGENT to live\n")
        output = read_until(reader, "\r\ntool-output\r\ntool-error\r\n")
        assert_includes output, "\r\n#{PROMPT}export VIA_AGENT=live; /bin/echo tool-output; /bin/echo tool-error >&2\r\nwhile"
        File.write(gate, "")
        read_until(reader, "tail-output\r\nTool result: Exit status: 0")
        result = read_until(reader, "\r\ntool-output\r\ntool-error\r\ntail-output\r\n")
        refute_includes result, "export VIA_AGENT=live"
        read_until(reader, PROMPT)
        writer.write("/bin/echo \"$VIA_AGENT\"\n")
        read_until(reader, "\r\nlive\r\n")
        read_until(reader, PROMPT)
        writer.write("exit\n")
        assert_equal 0, wait_for_exit(pid).exitstatus
      end
    end
  end

  def test_shell_agent_relays_command_output_even_when_it_cannot_be_captured
    client = <<~'CODE'
      def chat(messages, **)
        if (result = tool_result(messages))
          text = (result[:content] || result["content"]).to_s
          return answer(text.include?("STDOUT:") ? "Unexpected captured output" : "Command finished")
        end

        tool("run_shell_command", command: <<~'SH')
          printf 'Downloading\n\033[?25l\033[?7s\033[?7l10%%\r\033[K100%%\n\033[?7h\033[?7r\033[?25h'
          printf 'Finished download\n' >&2
        SH
      end
    CODE
    with_shell_agent(client) do |reader, writer, pid|
      read_until(reader, PROMPT)
      writer.write("? run the download\n")
      read_until(reader, "Downloading\r\n\e[?25l\e[?7s\e[?7l10%\r\e[K100%\r\n\e[?7h\e[?7r\e[?25hFinished download\r\nCommand finished\r\n")
      read_until(reader, PROMPT)
      writer.write("exit\n")
      assert_equal 0, wait_for_exit(pid).exitstatus
    end
  end

  def test_shell_agent_echo_uses_the_live_styled_prompt_for_each_command
    client = <<~'CODE'
      def chat(messages, **)
        results = messages.count { |message| (message[:role] || message["role"]) == "tool" }
        case results
        when 0 then tool("run_shell_command", command: 'cd "$AGENT_TEST_DIRECTORY"; false')
        when 1 then tool("run_shell_command", command: "/bin/echo after-change")
        else answer("Done changing directories.")
        end
      end
    CODE
    Dir.mktmpdir do |dir|
      destination = File.join(dir, "changed-dir")
      Dir.mkdir(destination)
      with_shell_agent(client, "AGENT_TEST_DIRECTORY" => destination,
                       "PROMPT" => "%F{cyan}%1~ [%?]%f > ", "KWARD_COLOR" => "always") do |reader, writer, pid|
        read_until(reader, "\e[0m")
        writer.write("? change directories, then print a message\n")
        read_until(reader, "\e[36mchanged-dir [1]\e[39m > \e[0m/bin/echo after-change\r\n")
        read_until(reader, "after-change\r\nDone changing directories.\r\n")
        read_until(reader, "\e[36mchanged-dir [0]\e[39m > \e[0m")
        writer.write("exit\n")
        assert_equal 0, wait_for_exit(pid).exitstatus
      end
    end
  end

  def test_shell_agent_command_times_out_without_ending_the_live_shell
    client = <<~'CODE'
      def chat(messages, **)
        result = tool_result(messages)
        return answer((result[:content] || result["content"]).to_s) if result

        tool("run_shell_command", command: "/bin/sleep 20", timeout_seconds: 1)
      end
    CODE
    with_shell_agent(client) do |reader, writer, pid|
      read_until(reader, PROMPT)
      writer.write("? run a sleep command with a timeout\n")
      read_until(reader, "\r\n#{PROMPT}/bin/sleep 20\r\n")
      read_until(reader, "\r\nExit status: 124\r\n")
      read_until(reader, PROMPT)
      writer.write("/bin/echo still-live\n")
      read_until(reader, "\r\nstill-live\r\n")
      read_until(reader, PROMPT)
      writer.write("exit\n")
      assert_equal 0, wait_for_exit(pid).exitstatus
    end
  end

  private

  def with_shell_agent(client_code, env = {})
    lib = File.expand_path("../lib", __dir__)
    code = <<~RUBY_CODE
      require "kward/shell/standalone_agent"
      require "kward/entrypoint"
      class ShellTestClient
        def current_provider = "Codex"
        def current_model = "fake-model"
        def current_reasoning_effort = "medium"
        def current_context_window = 200_000

        def tool(name, **arguments)
          { "role" => "assistant", "tool_calls" => [{ "id" => "call_1", "type" => "function",
            "function" => { "name" => name, "arguments" => JSON.generate(arguments) } }] }
        end

        def tool_result(messages) = messages.reverse.find { |message| (message[:role] || message["role"]) == "tool" }
        def answer(text) = { "role" => "assistant", "content" => text }
        #{client_code}
      end
      class Kward::StandaloneAgent
        def self.new = super(client: ShellTestClient.new)
      end
      exit Kward::Entrypoint.run
    RUBY_CODE
    Dir.mktmpdir do |home|
      with_terminal({ "HOME" => home, "KWARD_CONFIG_PATH" => nil, "KWARD_CONFIG_DIR" => nil }.merge(env),
                    command: ["-I", lib, "-e", code, "--"]) { |*pty| yield(*pty) }
    end
  end


  def with_terminal(env = {}, command: [EXECUTABLE], **env_options)
    defaults = { "ENV" => nil, "HISTFILE" => "", "PROMPT" => nil, "KWARD_COLOR" => nil, "FORCE_COLOR" => nil, "CLICOLOR_FORCE" => nil,
                 "NO_COLOR" => nil, "CLICOLOR" => nil, "PS1" => PROMPT, "PS2" => "more> ", "TERM" => "xterm" }
    PTY.spawn(defaults.merge(env, env_options), RbConfig.ruby, *command, "shell") do |reader, writer, pid|
      yield reader, writer, pid
    ensure
      # Close the PTY before reaping to release the terminal on macOS.
      reader.close unless reader.closed?
      writer.close unless writer.closed?
      Process.kill("KILL", pid) rescue nil
      Process.waitpid(pid) rescue nil
    end
  end

  def read_until(reader, text)
    result = +"".b
    Timeout.timeout(5) { result << reader.readpartial(1) until result.include?(text) }
    result
  rescue Timeout::Error, EOFError, Errno::EIO
    flunk "terminal did not produce #{text.inspect}: #{(result[-1500..] || result).inspect}"
  end

  def wait_for_exit(pid)
    Timeout.timeout(5) { Process.waitpid2(pid).last }
  end
end
