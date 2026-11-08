require_relative "test_helper"
require "open3"
require_relative "../lib/kward/shell/native_runtime"

class TestNativeShellUlimit < KwardTestCase
  EXECUTABLE = File.expand_path("../exe/kwsh", __dir__)
  RESOURCES = { "c" => [:CORE, 512], "d" => [:DATA, 1024], "f" => [:FSIZE, 512],
                "n" => [:NOFILE, 1], "s" => [:STACK, 1024], "t" => [:CPU, 1], "v" => [:AS, 1024] }.freeze

  def invoke(source, **options)
    Open3.capture3({ "LC_ALL" => "C", "ENV" => nil }, RbConfig.ruby, EXECUTABLE, "-c", source, **options)
  end

  def limit_text(value, unit)
    value == Process::RLIM_INFINITY ? "unlimited" : (value / unit).to_s
  end

  def test_queries_use_standard_units_soft_default_and_hard_selection
    RESOURCES.each do |flag, (resource, unit)|
      soft, hard = Process.getrlimit(resource)
      output, error, status = invoke("ulimit -#{flag}; ulimit -S -#{flag}; ulimit -H -#{flag}")
      assert status.success?, error
      assert_empty error
      assert_equal [soft, soft, hard].map { |value| limit_text(value, unit) }, output.lines.map(&:chomp)
    end
    output, error, status = invoke("ulimit; ulimit -f; command -v ulimit; type ulimit")
    assert status.success?, error
    assert_equal output.lines[0], output.lines[1]
    assert_includes output, "ulimit is shell builtin"
  end

  def test_all_lists_resource_names_units_options_and_values
    output, error, status = invoke("ulimit -H -a")
    assert status.success?, error
    assert_empty error
    assert_equal 7, output.lines.length
    RESOURCES.each do |flag, (resource, unit)|
      line = output.lines.find { |text| text.include?("-#{flag}") }
      refute_nil line, flag
      assert_match(/#{Regexp.escape(limit_text(Process.getrlimit(resource).last, unit))}\n\z/, line)
      assert_includes line, "#{unit} bytes" if unit > 1
    end
  end

  def test_setting_defaults_to_both_limits_and_soft_limits_can_be_restored
    output, error, status = invoke(<<~'SHELL')
      ulimit -- 4
      ulimit -S -f 2
      ulimit -f
      ulimit -H
      ulimit -H -f 1
      printf 'rejected:%s\n' "$?"
      ulimit -H
      ulimit -S -f 4
      ulimit
      ulimit -f 3
      ulimit -H
    SHELL
    assert status.success?, error
    assert_equal "2\n4\nrejected:2\n4\n4\n3\n", output
    assert_includes error, "ulimit:"
  end

  def test_decimal_leading_zeros_unlimited_and_large_limits
    output, error, status = invoke("saved=$(ulimit -H); ulimit -S -f 0000000008; ulimit; ulimit -S -f \"$saved\"; ulimit")
    assert status.success?, error
    assert_empty error
    assert_equal ["8", limit_text(Process.getrlimit(:FSIZE).last, 512)], output.lines.map(&:chomp)
    # Values beyond a native rlim_t must be diagnosed, not truncated or wrapped.
    output, error, status = invoke("ulimit -f 18446744073709551616000000000000000000")
    refute status.success?
    assert_empty output
    assert_includes error, "ulimit:"
    largest = (Process.getrlimit(:FSIZE).last - 1) / 512
    output, error, status = invoke("ulimit -S -f #{largest}; ulimit")
    assert status.success?, error
    assert_equal "#{largest}\n", output
  end

  def test_each_resource_accepts_a_soft_limit_round_trip
    RESOURCES.each do |flag, (resource, unit)|
      output, error, status = invoke("saved=$(ulimit -#{flag}); ulimit -S -#{flag} \"$saved\"; result=$?; ulimit -#{flag}; exit $result")
      assert status.success?, "-#{flag}: #{error}"
      assert_empty error
      assert_equal "#{limit_text(Process.getrlimit(resource).first, unit)}\n", output
    end
  end

  def test_cpu_seconds_core_blocks_and_descriptor_counts_reach_external_children
    child = Shellwords.join([RbConfig.ruby, "-e", "[:CPU, :CORE, :NOFILE].each { |r| puts Process.getrlimit(r).join(':') }"])
    output, error, status = invoke("ulimit -t 5; ulimit -S -t 3; ulimit -c 8; ulimit -S -c 2; ulimit -n 128; #{child}")
    assert status.success?, error
    assert_empty error
    assert_equal "3:5\n1024:4096\n128:128\n", output
  end

  def test_soft_limit_above_hard_limit_fails_without_changing_either_value
    output, error, status = invoke("ulimit -f 2; ulimit -S -f 3; result=$?; ulimit; ulimit -H; exit $result")
    refute status.success?
    assert_equal "2\n2\n", output
    assert_includes error, "ulimit:"
  end

  def test_zero_and_grouped_flags_and_option_terminator
    output, error, status = invoke("ulimit -Sf -- +0; ulimit -Sf; ulimit -Hf")
    assert status.success?, error
    assert_empty error
    assert_equal ["0", limit_text(Process.getrlimit(:FSIZE).last, 512)], output.lines.map(&:chomp)
  end

  def test_invalid_arguments_do_not_change_limits_or_abort_the_script
    ["-z", "-a 1", "-f 1 2", "-f -- -1", "-f 1.5", "-f nope", "-f ''", "-H -S", "-f -n"].each do |args|
      output, error, status = invoke("ulimit -f 4; ulimit #{args}; result=$?; ulimit; exit $result")
      refute status.success?, args
      assert_equal "4\n", output, args
      assert_includes error, "ulimit:", args
    end
  end

  def test_subshell_pipeline_substitution_and_native_script_isolation
    Dir.mktmpdir("native-ulimit") do |dir|
      File.write(File.join(dir, "script"), "ulimit; ulimit -S -f 1; ulimit\n")
      output, error, status = invoke(<<~'SHELL', chdir: dir)
        ulimit -f 8
        (ulimit -f 2; ulimit)
        ulimit
        value=$(ulimit -f 3; ulimit)
        printf '%s\n' "$value"
        ulimit -f 4 | cat
        ulimit
        kwsh script
        ulimit
      SHELL
      assert status.success?, error
      assert_empty error
      assert_equal "2\n8\n3\n8\n8\n1\n8\n", output
    end
  end

  def test_external_children_and_native_exec_fallback_inherit_limits
    Dir.mktmpdir("native-ulimit-exec") do |dir|
      File.write(File.join(dir, "script"), "ulimit; ulimit -H; ulimit -S -f 1; ulimit\n")
      File.chmod(0o700, File.join(dir, "script"))
      child = Shellwords.join([RbConfig.ruby, "-e", "puts Process.getrlimit(:FSIZE).join(':')"])
      output, error, status = invoke("ulimit -f 4; ulimit -S -f 2; #{child}; exec ./script", chdir: dir)
      assert status.success?, error
      assert_empty error
      assert_equal "1024:2048\n2\n4\n1\n", output
    end
  end

  def test_small_disposable_files_are_limited_in_children_and_shell_builtins
    Dir.mktmpdir("native-ulimit-files") do |dir|
      writer = Shellwords.join([RbConfig.ruby, "-e", 'Signal.trap("XFSZ", "IGNORE"); begin; File.binwrite("child", "x" * 2048); rescue Errno::EFBIG; puts "limited"; end'])
      output, error, status = invoke("ulimit -f 2; #{writer}", chdir: dir)
      assert status.success?, error
      assert_equal "limited\n", output
      assert_equal 1024, File.size(File.join(dir, "child"))
      output, error, status = invoke("ulimit -f 1; cat child | wc -c", chdir: dir)
      assert status.success?, error
      assert_equal "1024", output.strip
      _, error, status = invoke("trap '' XFSZ; ulimit -f 1; alias large=#{'x' * 1024}; alias >builtin", chdir: dir)
      refute status.success?, error
      assert_equal 512, File.size(File.join(dir, "builtin"))
    end
  end

  def test_embedded_runtime_cannot_change_the_host_but_its_subshell_can
    # Exercise even the embedding boundary in a disposable process: a broken
    # guard must not irreversibly lower the test runner's own hard limit.
    code = <<~'RUBY'
      require "json"
      require "kward/shell/script_runner"
      before = Process.getrlimit(:FSIZE)
      runtime = Kward::NativeShell::Runtime.new
      output, error = StringIO.new, StringIO.new
      status = runtime.run("ulimit -f 1", output: output, error: error)
      runner_status = Kward::NativeShell::ScriptRunner.run(["-c", "ulimit -f 1"], output: output, error: error)
      child_status = runtime.run("(ulimit -f 1; ulimit >result)", error: error)
      runtime.close
      puts JSON.generate(status: status, runner_status: runner_status, error: error.string,
                         child_status: child_status, before: before, after: Process.getrlimit(:FSIZE))
    RUBY
    Dir.mktmpdir("native-ulimit-embedded") do |dir|
      output, error, status = Open3.capture3(RbConfig.ruby, "-I", File.expand_path("../lib", __dir__), "-e", code, chdir: dir)
      assert status.success?, error
      result = JSON.parse(output)
      refute_equal 0, result.fetch("status")
      refute_equal 0, result.fetch("runner_status")
      assert_includes result.fetch("error"), "owned shell process"
      assert_equal result.fetch("before"), result.fetch("after")
      assert_equal 0, result.fetch("child_status")
      assert_equal "1\n", File.read(File.join(dir, "result"))
    end
  end

  def test_failed_interactive_exec_keeps_the_current_limits
    output, error, status = Open3.capture3({ "ENV" => nil, "PS1" => "", "PS2" => "" }, RbConfig.ruby, EXECUTABLE, "-i", "-s",
                                         stdin_data: "ulimit -f 4\nulimit -S -f 2\nexec ./missing_native_ulimit\nulimit; ulimit -H\nexit\n")
    assert status.success?, error
    assert_equal "2\n4\n", output
    assert_includes error, "missing_native_ulimit"
  end

  def test_hosted_worker_limits_do_not_change_the_agent_or_other_sessions
    before = Process.getrlimit(:FSIZE)
    Dir.mktmpdir("native-ulimit-hosted") do |dir|
      shell = Kward::PersistentShellSession.new(cwd: dir)
      other = Kward::PersistentShellSession.new(cwd: dir)
      assert_equal 0, shell.run_for_agent("ulimit -f 2").exit_status
      result = shell.run_for_agent("ulimit")
      assert_equal 0, result.exit_status
      assert_equal "2", result.output.lines.last.strip
      result = other.run_for_agent("ulimit")
      assert_equal 0, result.exit_status
      assert_equal limit_text(before.first, 512), result.output.lines.last.strip
      assert_equal before, Process.getrlimit(:FSIZE)
    ensure
      shell&.close
      other&.close
    end
  end
end
