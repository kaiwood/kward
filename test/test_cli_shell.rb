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

  def test_multiline_bracketed_paste_requires_enter_and_preserves_continuations
    with_terminal do |reader, writer, pid|
      read_until(reader, PROMPT)
      writer.write("\e[20")
      writer.write("0~printf 'one\\n'\r\nprintf 'two\\n'\e[201~")
      draft = read_until(reader, %q{printf 'one\n'^Jprintf 'two\n'})
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

  private

  def with_terminal(env = {})
    defaults = { "ENV" => nil, "HISTFILE" => "", "PS1" => PROMPT, "PS2" => "more> ", "TERM" => "xterm" }
    PTY.spawn(defaults.merge(env), RbConfig.ruby, EXECUTABLE, "shell") do |reader, writer, pid|
      yield reader, writer, pid
    ensure
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
