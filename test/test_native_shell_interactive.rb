require_relative "test_helper"
require "open3"
require "pty"
require "timeout"
require_relative "../lib/kward/shell/script_runner"

class TestNativeShellInteractive < KwardTestCase
  EXECUTABLE = File.expand_path("../exe/kwsh", __dir__)

  def test_history_prompts_and_parameter_expanded_trace_prefixes
    out, err, status = Open3.capture3({ "ENV" => nil, "HISTFILE" => "", "PS1" => '${label:-go}!/!!> ', "PS4" => '[$?]${label}: ' },
      RbConfig.ruby, EXECUTABLE, "-i", stdin_data: "label=trace\nset -x\nfalse\nanswer=yes\nset +x\nexit\n")
    assert status.success?, err
    assert_empty out
    assert_includes err, "go1/!> "
    assert_includes err, "trace2/!> "
    assert_includes err, "[0]trace: false\n"
    assert_includes err, "[1]trace: answer=yes\n"
  end

  def test_trace_expansion_never_executes_command_text
    Dir.mktmpdir do |dir|
      out, err, status = Open3.capture3({ "PS4" => '$(touch injected)' }, RbConfig.ruby, EXECUTABLE, "-xc", "printf safe", chdir: dir)
      assert status.success?, err
      assert_equal "safe", out
      refute File.exist?(File.join(dir, "injected"))
      assert_includes err, "only parameter expansion"
    end
  end

  def test_nolog_and_ignoreeof_round_trip
    out, err, status = Open3.capture3({ "ENV" => nil, "HISTFILE" => "", "PS1" => "" }, RbConfig.ruby, EXECUTABLE, "-i",
      stdin_data: "set -o nolog -o ignoreeof\nset +o\nset +o nolog +o ignoreeof\n")
    assert status.success?, err
    assert_includes out, "set -o nolog\n"
    assert_includes out, "set -o ignoreeof\n"
  end

  def test_nonterminal_ignoreeof_waits_for_an_explicit_exit_trap_without_spinning
    Open3.popen3({ "ENV" => nil, "HISTFILE" => "", "PS1" => "" }, RbConfig.ruby, EXECUTABLE, "-i", pgroup: true) do |input, output, error, waiter|
      input.write("trap 'exit 7' USR1\nset -o ignoreeof\nprintf 'ready\\n'\n")
      input.close
      assert_equal "ready\n", Timeout.timeout(5) { output.gets }
      assert_nil waiter.join(0.25), "ignoreeof exited at a nonterminal EOF"
      Process.kill("USR1", waiter.pid)
      assert_equal 7, Timeout.timeout(5) { waiter.value }.exitstatus
      assert_empty error.read
    ensure
      Process.kill("KILL", -waiter.pid) rescue nil
    end
  end

  def test_read_prompts_with_ps2_for_backslash_newline_continuation
    with_terminal("PS2" => "continuation> ") do |reader, writer, pid|
      read_until(reader, "ready> ")
      writer.write("read value\nfirst\\\n")
      output = read_until(reader, "continuation> ")
      refute_includes output, "value=firstsecond"
      writer.write("second\nprintf '<%s>' \"$value\"\nexit\n")
      output << read_until(reader, "<firstsecond>")
      assert_includes output, "<firstsecond>"
      assert_equal 0, Process.waitpid2(pid)[1].exitstatus
    end
  end

  def test_terminal_eof_is_ignored_until_explicit_exit
    with_terminal do |reader, writer, pid|
      read_until(reader, "ready> ")
      writer.write("set -o ignoreeof\n")
      read_until(reader, "ready> ")
      writer.write("\x04")
      assert_includes read_until(reader, "ready> "), "use exit"
      writer.write("exit 7\n")
      assert_equal 7, Process.waitpid2(pid)[1].exitstatus
    end
  end

  def test_mail_interval_creation_modification_and_mailpath_precedence
    Dir.mktmpdir do |dir|
      runtime = Kward::NativeShell::Runtime.new(cwd: dir, env: { "MAIL" => "box", "MAILCHECK" => "10", "NAME" => "captain" })
      error = StringIO.new
      runtime.check_mail(error, now: 0)
      File.write(File.join(dir, "box"), "mail")
      runtime.check_mail(error, now: 9)
      assert_empty error.string
      runtime.check_mail(error, now: 10)
      assert_includes error.string, "mail"
      error.truncate(0); error.rewind
      runtime.variables["MAILPATH"] = 'other\\%box%hello ${NAME}'
      runtime.check_mail(error, now: 20)
      File.write(File.join(dir, "other%box"), "new")
      runtime.check_mail(error, now: 30)
      assert_equal "hello captain\n", error.string
      error.truncate(0); error.rewind
      File.utime(Time.at(100), Time.at(100), File.join(dir, "box"))
      runtime.check_mail(error, now: 40)
      assert_empty error.string
      runtime.variables["MAILCHECK"] = "0"
      File.utime(Time.at(100), Time.at(100), File.join(dir, "other%box"))
      runtime.check_mail(error, now: 40)
      assert_equal "hello captain\n", error.string
    ensure
      runtime&.send(:close_resources)
    end
  end

  def test_vi_terminal_editing_history_and_interrupt_recovery
    with_terminal do |reader, writer, pid|
      read_until(reader, "ready> ")
      writer.write("set -o vi\n")
      read_until(reader, "ready> ")
      writer.write("xprintf 'edited\\n'\e0x\n")
      assert_includes read_until(reader, "\r\nedited\r\n"), "edited"
      read_until(reader, "ready> ")
      writer.write("\ek\n")
      assert_includes read_until(reader, "\r\nedited\r\n"), "edited"
      read_until(reader, "ready> ")
      writer.write("unfinished\x03")
      read_until(reader, "\r\n\rready> ")
      writer.write("printf 'status:%s\\n' \"$?\"\n")
      assert_includes read_until(reader, "\r\nstatus:130\r\n"), "status:130"
      writer.write("set +o vi\nexit\n")
      assert_equal 0, Process.waitpid2(pid)[1].exitstatus
    end
  end

  def test_vi_preserves_command_stdin_and_custom_terminal_controls
    with_terminal do |reader, writer, pid|
      read_until(reader, "ready> ")
      writer.write("stty erase '^H' kill '^X' eof '^E'; set -o vi\n")
      read_until(reader, "ready> ")
      writer.write("ignored\x18read valx\x08ue\npayload\n")
      read_until(reader, "\r\n\rready> ")
      writer.write("printf '<%s>\\n' \"$value\"\n")
      assert_includes read_until(reader, "\r\n<payload>\r\n"), "<payload>"
      read_until(reader, "ready> ")
      writer.write("\x05")
      assert_equal 0, Process.waitpid2(pid)[1].exitstatus
    end
  end

  def test_vi_setup_failure_returns_to_plain_input
    with_terminal("LC_ALL" => "kward_nonexistent_locale") do |reader, writer, pid|
      read_until(reader, "ready> ")
      writer.write("set -o vi\n")
      assert_includes read_until(reader, "vi disabled:"), "vi disabled:"
      read_until(reader, "ready> ")
      writer.write("printf 'recovered\\n'\nexit\n")
      assert_includes read_until(reader, "\r\nrecovered\r\n"), "recovered"
      assert_equal 0, Process.waitpid2(pid)[1].exitstatus
    end
  end

  def test_vi_external_editor_runs_after_terminal_restoration
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "vi"), "#!/usr/bin/env ruby\nrequire 'io/console'\nabort 'terminal not restored' unless STDIN.echo?\nFile.write(ARGV.fetch(0), \"printf 'from-editor\\\\n'\\n\")\n")
      File.chmod(0700, File.join(dir, "vi"))
      with_terminal("PATH" => "#{dir}:#{ENV.fetch('PATH')}") do |reader, writer, pid|
        read_until(reader, "ready> ")
        writer.write("set -o vi\n")
        read_until(reader, "ready> ")
        writer.write("old draft\ev")
        assert_includes read_until(reader, "\r\nfrom-editor\r\n"), "from-editor"
        writer.write("exit\n")
        assert_equal 0, Process.waitpid2(pid)[1].exitstatus
      end
    end
  end

  private

  def with_terminal(env = {})
    PTY.spawn({ "ENV" => nil, "HISTFILE" => "", "PS1" => "ready> ", "TERM" => "xterm" }.merge(env), RbConfig.ruby, EXECUTABLE) do |reader, writer, pid|
      yield reader, writer, pid
    ensure
      Process.kill("KILL", -pid) rescue nil
      Process.waitpid(pid) rescue nil
    end
  end

  def read_until(reader, text)
    result = +""
    Timeout.timeout(5) { result << reader.readpartial(1) until result.include?(text) }
    result
  rescue Timeout::Error
    flunk "terminal did not produce #{text.inspect}: #{(result[-3000..] || result).inspect}"
  end
end
