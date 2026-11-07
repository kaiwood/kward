require_relative "test_helper"
require "open3"
require "timeout"

class TestNativeShellExec < KwardTestCase
  EXECUTABLE = File.expand_path("../exe/kwsh", __dir__)

  def invoke(source, interactive: true, **options)
    Open3.popen3({ "ENV" => nil, "PS1" => "", "PS2" => "" }, RbConfig.ruby, EXECUTABLE, interactive ? "-i" : "-s", pgroup: true, **options) do |input, output, error, waiter|
      readers = [output, error].map { |io| Thread.new { io.read } }
      begin
        input.write(source)
        input.close
        Timeout.timeout(5) { [readers[0].value, readers[1].value, waiter.value] }
      ensure
        begin
          Process.kill("KILL", -waiter.pid) if waiter.alive?
        rescue Errno::ESRCH
          nil
        end
        waiter.join(2)
        readers.each { |reader| reader.join(2) }
      end
    end
  end

  def test_failed_interactive_exec_accepts_a_fresh_submission
    Dir.mktmpdir("native-exec-recovery") do |dir|
      File.write(File.join(dir, "denied"), "printf wrong\n")
      File.write(File.join(dir, "binary"), "\x7fELF\0bad")
      File.chmod(0o700, File.join(dir, "binary"))
      { "kwsh_missing_exec" => 127, "./missing" => 127, "./denied" => 126, "denied" => 126, "./binary" => 126, "." => 126, "./#{'x' * 300}" => 126 }.each do |command, expected|
        output, error, status = invoke("PATH=.:$PATH\nexec #{command}\nprintf '%s:alive' \"$?\"\nexit\n", chdir: dir)
        assert status.success?, "#{command}: #{error}"
        assert_equal "#{expected}:alive", output, command
        refute_empty error
      end
    end
  end

  def test_failure_keeps_successful_redirections_and_shell_state
    Dir.mktmpdir("native-exec-state") do |dir|
      Dir.mkdir(File.join(dir, "child"))
      output, error, status = invoke(<<~'SHELL', chdir: dir)
        exec 8>&1 9>&2
        cd child
        trap 'printf signal >&8' INT
        exec ./missing 1>output 2>error 3>&- 4>&- 5>&- 6>&- 7>&-
        printf '%s:redirected' "$?"
        kill -TERM $$; kill -INT $$
        pwd -P >&8
        exec 1>&8 2>&9
        printf restored
        exit
      SHELL
      assert status.success?, error
      assert_empty error
      assert_equal "signal#{File.realpath(dir)}/child\nrestored", output
      assert_equal "127:redirected", File.read(File.join(dir, "child", "output"))
      assert_includes File.read(File.join(dir, "child", "error")), "missing"
    end
  end

  def test_failed_exec_stdin_redirection_supplies_the_next_submission
    Dir.mktmpdir("native-exec-input") do |dir|
      File.write(File.join(dir, "next"), "printf '%s:next' \"$?\"\nexit\n")
      output, error, status = invoke("exec ./missing <next\nprintf wrong\n", chdir: dir)
      assert status.success?, error
      assert_equal "127:next", output
    end
  end

  def test_repeated_failures_keep_user_descriptors_and_successful_exec_replaces_pid
    Dir.mktmpdir("native-exec-repeat") do |dir|
      lines = ["exec 9>&1", "printf '%s:' \"$$\""]
      12.times do
        lines << "exec ./missing 3>output"
        lines << "printf x >&3"
      end
      lines << "printf '%s:' \"$$\" >&9"
      lines << "exec #{Shellwords.join([RbConfig.ruby, '-e', 'print Process.pid'])} >&9"
      output, error, status = invoke(lines.join("\n") + "\n", chdir: dir)
      assert status.success?, error
      ids = output.split(":")
      assert_equal 3, ids.length
      assert_match(/\A[0-9]+\z/, ids.first)
      assert_equal [ids.first] * 3, ids
      assert_equal "x", File.read(File.join(dir, "output"))
    end
  end

  def test_closing_stderr_does_not_break_the_recovered_prompt
    output, error, status = invoke("exec ./missing 2>&-\nprintf '%s:alive' \"$?\"\nexit\n")
    assert status.success?, error
    assert_empty error
    assert_equal "127:alive", output
  end

  def test_reservation_handles_are_not_shell_descriptors
    [3, 9].each do |fd|
      _, error, status = invoke(": >&#{fd}\n", interactive: false)
      assert_equal 2, status.exitstatus
      assert_includes error, "bad file descriptor: #{fd}"
    end
  end

  def test_failed_replacement_restores_process_state_without_leaking_backups
    probe = <<~RUBY
      require #{File.expand_path("../lib/kward/shell/script_runner", __dir__).inspect}
      native = Kward::NativeShell::NativeProcess
      cwd = Dir.pwd
      mask = File.umask
      handler = proc {}
      Signal.trap("INT", handler)
      Dir.mktmpdir do |dir|
        Tempfile.create("exec-errors") do |error|
          count = -> { (0..256).count { |fd| native::FCNTL.call(fd, Fcntl::F_GETFD, 0) >= 0 } }
          before = count.call
          flags = STDIN.fcntl(Fcntl::F_GETFL, 0)
          20.times do
            status = native.replace("/missing/kwsh-executable", ["missing"], ENV.to_h,
                                    cwd: dir, streams: { 0 => STDIN, 1 => STDOUT, 2 => error },
                                    mask: 0o077, signals: { "INT" => "DEFAULT" }, recover: true)
            abort "wrong status" unless status == 127
            abort "cwd or mask changed" unless Dir.pwd == cwd && File.umask == mask
            abort "flags changed" unless STDIN.fcntl(Fcntl::F_GETFL, 0) == flags
            abort "handler lost" unless Signal.trap("INT", handler).equal?(handler)
          end
          abort "backup descriptors leaked" unless before == count.call
        end
      end
      print "restored"
    RUBY
    output, error, status = invoke(Shellwords.join([RbConfig.ruby, "-e", probe]) + "\n")
    assert status.success?, error
    assert_empty error
    assert_equal "restored", output
  end

  def test_noninteractive_exec_failure_still_exits
    ["kwsh_missing_exec", "./missing"].each do |command|
      output, error, status = invoke("exec #{command}\nprintf wrong\n", interactive: false)
      assert_equal 127, status.exitstatus
      assert_empty output
      refute_empty error
    end
  end
end
