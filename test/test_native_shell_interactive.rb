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

  def test_nolog_round_trips_and_nonterminal_ignoreeof_does_not_spin
    out, err, status = Open3.capture3({ "ENV" => nil, "HISTFILE" => "", "PS1" => "" }, RbConfig.ruby, EXECUTABLE, "-i",
      stdin_data: "set -o nolog -o ignoreeof\nset +o\nset +o nolog\n")
    assert status.success?, err
    assert_includes out, "set -o nolog\n"
    assert_includes out, "set -o ignoreeof\n"
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

  private

  def with_terminal
    PTY.spawn({ "ENV" => nil, "HISTFILE" => "", "PS1" => "ready> ", "TERM" => "xterm" }, RbConfig.ruby, EXECUTABLE) do |reader, writer, pid|
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
  end
end
