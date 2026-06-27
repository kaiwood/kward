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

  def test_sets_safe_color_environment_without_forcing_color
    shell = Kward::Ekwsh.new(cwd: Dir.pwd, shell: "/bin/sh", env: { "PATH" => "", "TERM" => "dumb" })

    result = shell.run("printf '%s %s %s %s %s' \"$CLICOLOR\" \"$CLICOLOR_FORCE\" \"$FORCE_COLOR\" \"$COLORTERM\" \"$TERM\"")

    assert_includes result.output, "1   truecolor xterm-256color"
  end

  def test_preserves_user_forced_color_environment
    shell = Kward::Ekwsh.new(cwd: Dir.pwd, shell: "/bin/sh", env: { "PATH" => "", "FORCE_COLOR" => "3", "CLICOLOR_FORCE" => "1" })

    result = shell.run("printf '%s %s' \"$FORCE_COLOR\" \"$CLICOLOR_FORCE\"")

    assert_includes result.output, "3 1"
  end

  def test_preserves_sgr_color_output_from_commands
    shell = Kward::Ekwsh.new(cwd: Dir.pwd, shell: "/bin/sh", env: { "PATH" => "" })

    result = shell.run("printf '\\033[31mred\\033[0m'")

    assert_includes result.output, "\e[31mred\e[0m"
  end

  def test_applies_configured_environment
    shell = Kward::Ekwsh.new(cwd: Dir.pwd, shell: "/bin/sh", env: { "PATH" => "" }, configured_env: { "FORCE_COLOR" => "1" })

    result = shell.run("printf %s \"$FORCE_COLOR\"")

    assert_includes result.output, "1"
  end

  def test_auto_configures_rbenv_environment_when_available
    Dir.mktmpdir("rbenv") do |dir|
      FileUtils.mkdir_p(File.join(dir, "shims"))
      FileUtils.mkdir_p(File.join(dir, "bin"))
      shell = Kward::Ekwsh.new(cwd: Dir.pwd, shell: "/bin/sh", env: { "PATH" => "/usr/bin", "RBENV_ROOT" => dir })

      result = shell.run("printf '%s\n%s' \"$RBENV_ROOT\" \"$PATH\"")

      assert_includes result.output, dir
      assert_includes result.output, "#{File.join(dir, "shims")}:#{File.join(dir, "bin")}:/usr/bin"
    end
  end

  def test_auto_configured_rbenv_path_does_not_duplicate_entries
    Dir.mktmpdir("rbenv") do |dir|
      shims = File.join(dir, "shims")
      bin = File.join(dir, "bin")
      FileUtils.mkdir_p(shims)
      FileUtils.mkdir_p(bin)
      shell = Kward::Ekwsh.new(cwd: Dir.pwd, shell: "/bin/sh", env: { "PATH" => "#{shims}:/usr/bin", "RBENV_ROOT" => dir })

      result = shell.run("printf %s \"$PATH\"")

      assert_includes result.output, "#{shims}:#{bin}:/usr/bin"
    end
  end

  def test_intercepts_relative_kward_executable_edit_command
    shell = Kward::Ekwsh.new(cwd: Dir.pwd, shell: "/bin/sh", env: { "PATH" => "" })

    result = shell.run("./exe/kward edit Gemfile")

    assert_equal 0, result.exit_status
    assert_equal File.expand_path("Gemfile", Dir.pwd), result.open_editor_path
    assert_includes result.output, "$ ./exe/kward edit Gemfile"
  end

  def test_expands_configured_alias_once
    shell = Kward::Ekwsh.new(cwd: Dir.pwd, shell: "/bin/sh", env: { "PATH" => "" }, aliases: { "hi" => "printf hello" })

    result = shell.run("hi")

    assert_includes result.output, "$ hi"
    assert_includes result.output, "hello"
  end

  def test_builtin_wins_over_alias
    shell = Kward::Ekwsh.new(cwd: Dir.pwd, shell: "/bin/sh", env: { "PATH" => "" }, aliases: { "pwd" => "printf wrong" })

    result = shell.run("pwd")

    refute_includes result.output, "wrong"
    assert_includes result.output, Dir.pwd
  end

  def test_alias_builtin_lists_configured_aliases
    shell = Kward::Ekwsh.new(cwd: Dir.pwd, shell: "/bin/sh", env: { "PATH" => "" }, aliases: { "ll" => "ls -la" })

    result = shell.run("alias")

    assert_includes result.output, "ll=ls\\ -la"
  end

  def test_completes_alias_commands
    shell = Kward::Ekwsh.new(cwd: Dir.pwd, shell: "/bin/sh", env: { "PATH" => "" }, aliases: { "ll" => "ls -la" })

    completion = shell.complete("l", 1)

    assert_includes completion.candidates, "ll"
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

  def test_completes_path_like_command_position_tokens
    Dir.mktmpdir("ekwsh") do |dir|
      Dir.mkdir(File.join(dir, "exe"))
      Dir.mkdir(File.join(dir, "examples"))
      shell = Kward::Ekwsh.new(cwd: dir, shell: "/bin/sh", env: { "PATH" => "" })

      completion = shell.complete("./ex", 4)

      assert_equal 0...4, completion.range
      assert_equal "./ex", completion.replacement
      assert_equal ["./examples/", "./exe/"], completion.candidates
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
