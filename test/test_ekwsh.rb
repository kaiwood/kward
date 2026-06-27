require_relative "test_helper"

class TestEkwsh < KwardTestCase
  def test_runs_command_in_current_directory
    Dir.mktmpdir("ekwsh") do |dir|
      shell = Kward::Ekwsh.new(cwd: dir, shell: "/bin/sh")

      result = shell.run("pwd")

      assert_equal 0, result.exit_status
      assert_includes result.output, "$ pwd"
      assert_includes result.output, dir
    end
  end

  def test_cd_persists_for_later_commands
    Dir.mktmpdir("ekwsh") do |dir|
      nested = File.join(dir, "nested")
      Dir.mkdir(nested)
      shell = Kward::Ekwsh.new(cwd: dir, shell: "/bin/sh")

      shell.run("cd nested")
      result = shell.run("pwd")

      assert_equal nested, shell.cwd
      assert_includes result.output, nested
    end
  end

  def test_export_and_unset_persist_environment
    Dir.mktmpdir("ekwsh") do |dir|
      shell = Kward::Ekwsh.new(cwd: dir, shell: "/bin/sh", env: { "PATH" => ENV.fetch("PATH", "") })

      shell.run("export KWARD_EKWSH_TEST=ready")
      exported = shell.run("printf %s $KWARD_EKWSH_TEST")
      shell.run("unset KWARD_EKWSH_TEST")
      unset = shell.run("printf %s ${KWARD_EKWSH_TEST:-missing}")

      assert_includes exported.output, "ready"
      assert_includes unset.output, "missing"
    end
  end

  def test_completes_builtin_command
    shell = Kward::Ekwsh.new(cwd: Dir.pwd, shell: "/bin/sh", env: { "PATH" => "" })

    completion = shell.complete("pw", 2)

    assert_equal 0...2, completion.range
    assert_equal "pwd ", completion.replacement
    assert_includes completion.candidates, "pwd"
  end

  def test_completes_path_arguments
    Dir.mktmpdir("ekwsh") do |dir|
      File.write(File.join(dir, "alpha.txt"), "")
      shell = Kward::Ekwsh.new(cwd: dir, shell: "/bin/sh", env: { "PATH" => "" })

      completion = shell.complete("cat al", 6)

      assert_equal 4...6, completion.range
      assert_equal "alpha.txt ", completion.replacement
    end
  end

  def test_completes_cd_with_directories_only
    Dir.mktmpdir("ekwsh") do |dir|
      Dir.mkdir(File.join(dir, "alpha"))
      File.write(File.join(dir, "alpine.txt"), "")
      shell = Kward::Ekwsh.new(cwd: dir, shell: "/bin/sh", env: { "PATH" => "" })

      completion = shell.complete("cd al", 5)

      assert_equal "alpha/", completion.replacement
      assert_equal ["alpha/"], completion.candidates
    end
  end

  def test_does_not_complete_empty_command_prompt
    shell = Kward::Ekwsh.new(cwd: Dir.pwd, shell: "/bin/sh", env: { "PATH" => ENV.fetch("PATH", "") })

    assert_nil shell.complete("", 0)
  end

  def test_completes_paths_with_shell_escaping
    Dir.mktmpdir("ekwsh") do |dir|
      File.write(File.join(dir, "my file.txt"), "")
      shell = Kward::Ekwsh.new(cwd: dir, shell: "/bin/sh", env: { "PATH" => "" })

      completion = shell.complete("cat my", 6)

      assert_equal "my\\ file.txt ", completion.replacement
    end
  end

  def test_completes_escaped_space_path_token
    Dir.mktmpdir("ekwsh") do |dir|
      FileUtils.mkdir_p(File.join(dir, "my folder"))
      File.write(File.join(dir, "my folder", "alpha.txt"), "")
      shell = Kward::Ekwsh.new(cwd: dir, shell: "/bin/sh", env: { "PATH" => "" })

      completion = shell.complete("cat my\\ folder/al", 17)

      assert_equal "my\\ folder/alpha.txt ", completion.replacement
    end
  end

  def test_nonzero_command_reports_exit_status
    shell = Kward::Ekwsh.new(cwd: Dir.pwd, shell: "/bin/sh")

    result = shell.run("exit 7")

    assert_equal 7, result.exit_status
    assert_includes result.output, "Exit status: 7"
  end

  def test_cli_wraps_command_execution_in_busy_prompt
    prompt = FakePrompt.new([])
    prompt.define_singleton_method(:begin_busy_input) do |message, activity: "loading"|
      @busy_calls ||= []
      @busy_calls << [message, activity]
    end
    prompt.define_singleton_method(:finish_busy_input) do
      @finished = true
    end
    prompt.define_singleton_method(:busy_calls) { @busy_calls || [] }
    prompt.define_singleton_method(:finished?) { @finished }
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([]))
    shell = Kward::Ekwsh.new(cwd: Dir.pwd, shell: "/bin/sh")

    result = cli.send(:run_ekwsh_command, shell, "printf ok")

    assert_includes result.output, "ok"
    assert_equal [[shell.prompt_label, "running"]], prompt.busy_calls
    assert prompt.finished?
  end

  def test_exit_command_requests_shell_exit
    shell = Kward::Ekwsh.new(cwd: Dir.pwd, shell: "/bin/sh")

    result = shell.run("exit")

    assert result.exit_shell
    assert_includes result.output, "$ exit"
  end
end
