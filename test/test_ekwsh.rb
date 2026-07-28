require "timeout"
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
      exported = shell.run("capture printf %s $KWARD_EKWSH_TEST")
      shell.run("unset KWARD_EKWSH_TEST")
      unset = shell.run("capture printf %s ${KWARD_EKWSH_TEST:-missing}")

      assert_includes exported.output, "ready"
      assert_includes unset.output, "missing"
    end
  end

  def test_sets_safe_color_environment_without_forcing_color
    shell = Kward::Ekwsh.new(cwd: Dir.pwd, shell: "/bin/sh", env: { "PATH" => "", "TERM" => "dumb" })

    result = shell.run("capture printf '%s %s %s %s %s' \"$CLICOLOR\" \"$CLICOLOR_FORCE\" \"$FORCE_COLOR\" \"$COLORTERM\" \"$TERM\"")

    assert_includes result.output, "1   truecolor xterm-256color"
  end

  def test_defaults_git_pager_to_cat
    shell = Kward::Ekwsh.new(cwd: Dir.pwd, shell: "/bin/sh", env: { "PATH" => "" })

    result = shell.run("capture printf %s \"$GIT_PAGER\"")

    assert_includes result.output, "cat"
  end

  def test_preserves_configured_git_pager
    shell = Kward::Ekwsh.new(cwd: Dir.pwd, shell: "/bin/sh", env: { "PATH" => "", "GIT_PAGER" => "less" })

    result = shell.run("capture printf %s \"$GIT_PAGER\"")

    assert_includes result.output, "less"
  end

  def test_preserves_user_forced_color_environment
    shell = Kward::Ekwsh.new(cwd: Dir.pwd, shell: "/bin/sh", env: { "PATH" => "", "FORCE_COLOR" => "3", "CLICOLOR_FORCE" => "1" })

    result = shell.run("capture printf '%s %s' \"$FORCE_COLOR\" \"$CLICOLOR_FORCE\"")

    assert_includes result.output, "3 1"
  end

  def test_preserves_sgr_color_output_from_commands
    shell = Kward::Ekwsh.new(cwd: Dir.pwd, shell: "/bin/sh", env: { "PATH" => "" })

    result = shell.run("capture printf '\\033[31mred\\033[0m'")

    assert_includes result.output, "\e[31mred\e[0m"
  end

  def test_strips_unsafe_terminal_control_output_from_commands
    shell = Kward::Ekwsh.new(cwd: Dir.pwd, shell: "/bin/sh", env: { "PATH" => "" })

    result = shell.run("capture printf '\\033[2Jbefore\\033]0;title\\007\\033[31mred\\033[0m\\033[?1049hafter'")

    assert_includes result.output, "before\e[31mred\e[0mafter"
    refute_includes result.output, "\e[2J"
    refute_includes result.output, "\e]0;title\a"
    refute_includes result.output, "\e[?1049h"
  end

  def test_strips_unsafe_terminal_control_output_from_command_echo
    shell = Kward::Ekwsh.new(cwd: Dir.pwd, shell: "/bin/sh", env: { "PATH" => "" })

    result = shell.run("printf ok # \e[2J")

    refute_includes result.output, "\e[2J"
  end

  def test_applies_configured_environment
    shell = Kward::Ekwsh.new(cwd: Dir.pwd, shell: "/bin/sh", env: { "PATH" => "" }, configured_env: { "FORCE_COLOR" => "1" })

    result = shell.run("capture printf %s \"$FORCE_COLOR\"")

    assert_includes result.output, "1"
  end

  def test_auto_configures_rbenv_environment_when_available
    Dir.mktmpdir("rbenv") do |dir|
      FileUtils.mkdir_p(File.join(dir, "shims"))
      FileUtils.mkdir_p(File.join(dir, "bin"))
      shell = Kward::Ekwsh.new(cwd: Dir.pwd, shell: "/bin/sh", env: { "PATH" => "/usr/bin", "RBENV_ROOT" => dir })

      result = shell.run("capture printf '%s\n%s' \"$RBENV_ROOT\" \"$PATH\"")

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

      result = shell.run("capture printf %s \"$PATH\"")

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

  def test_external_command_requests_interactive_command
    shell = Kward::Ekwsh.new(cwd: Dir.pwd, shell: "/bin/sh", env: { "PATH" => "" })

    result = shell.run("printf hello")

    assert_equal 0, result.exit_status
    assert_equal "printf hello", result.interactive_command
    assert_includes result.output, "$ printf hello"
    assert_includes result.output, "interactive PTY session started"
  end

  def test_expands_configured_alias_once
    shell = Kward::Ekwsh.new(cwd: Dir.pwd, shell: "/bin/sh", env: { "PATH" => "" }, aliases: { "hi" => "printf hello" })

    result = shell.run("hi")

    assert_equal "printf hello", result.interactive_command
    assert_includes result.output, "$ hi"
  end

  def test_exposes_alias_expansion_for_one_shot_commands
    shell = Kward::Ekwsh.new(cwd: Dir.pwd, shell: "/bin/sh", env: { "PATH" => "" }, aliases: { "hi" => "printf hello" })

    assert_equal "printf hello captain", shell.expand_alias("hi captain")
    assert_equal "printf untouched", shell.expand_alias("printf untouched")
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

    assert_includes result.output, "alias ll=ls\\ -la"
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

  def test_completes_single_quoted_path_token
    Dir.mktmpdir("ekwsh") do |dir|
      File.write(File.join(dir, "my file.txt"), "")
      shell = Kward::Ekwsh.new(cwd: dir, shell: "/bin/sh", env: { "PATH" => "" })

      completion = shell.complete("cat 'my", 7)

      assert_equal 4...7, completion.range
      assert_equal "'my file.txt ", completion.replacement
    end
  end

  def test_completes_double_quoted_path_token
    Dir.mktmpdir("ekwsh") do |dir|
      FileUtils.mkdir_p(File.join(dir, "my folder"))
      shell = Kward::Ekwsh.new(cwd: dir, shell: "/bin/sh", env: { "PATH" => "" })

      completion = shell.complete('cd "my', 6)

      assert_equal '"my folder/', completion.replacement
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

  def test_path_executable_cache_invalidates_when_path_changes
    Dir.mktmpdir("ekwsh-path") do |first|
      Dir.mktmpdir("ekwsh-path") do |second|
        File.write(File.join(first, "one"), "")
        File.chmod(0o755, File.join(first, "one"))
        File.write(File.join(second, "two"), "")
        File.chmod(0o755, File.join(second, "two"))
        shell = Kward::Ekwsh.new(cwd: Dir.pwd, shell: "/bin/sh", env: { "PATH" => first })

        assert_includes shell.complete("o", 1).candidates, "one"
        shell.run("PATH=#{second}")

        completion = shell.complete("t", 1)
        assert_includes completion.candidates, "two"
        refute_includes completion.candidates, "one"
      end
    end
  end

  def test_capture_builtin_runs_command
    shell = Kward::Ekwsh.new(cwd: Dir.pwd, shell: "/bin/sh")

    result = shell.run("capture printf captured")

    assert_equal 0, result.exit_status
    assert_nil result.interactive_command
    assert_includes result.output, "$ capture printf captured"
    assert_includes result.output, "captured"
  end

  def test_alias_can_expand_to_capture_builtin
    shell = Kward::Ekwsh.new(cwd: Dir.pwd, shell: "/bin/sh", aliases: { "check" => "capture printf captured" })

    result = shell.run("check")

    assert_equal 0, result.exit_status
    assert_nil result.interactive_command
    assert_includes result.output, "$ check"
    assert_includes result.output, "captured"
  end

  def test_capture_builtin_requires_command
    shell = Kward::Ekwsh.new(cwd: Dir.pwd, shell: "/bin/sh")

    result = shell.run("capture")

    assert_equal 2, result.exit_status
    assert_includes result.output, "Usage: capture <command>"
  end

  def test_capture_builtin_is_completed
    shell = Kward::Ekwsh.new(cwd: Dir.pwd, shell: "/bin/sh", env: { "PATH" => "" })

    completion = shell.complete("cap", 3)

    assert_includes completion.candidates, "capture"
    assert_equal "capture ", completion.replacement
  end

  def test_pty_builtin_requests_interactive_command
    shell = Kward::Ekwsh.new(cwd: Dir.pwd, shell: "/bin/sh")

    result = shell.run("pty git log --oneline")

    assert_equal 0, result.exit_status
    assert_equal "git log --oneline", result.interactive_command
    assert_includes result.output, "$ pty git log --oneline"
    assert_includes result.output, "interactive PTY session started"
  end

  def test_alias_can_expand_to_pty_builtin
    shell = Kward::Ekwsh.new(cwd: Dir.pwd, shell: "/bin/sh", aliases: { "glog" => "pty git log --oneline" })

    result = shell.run("glog")

    assert_equal 0, result.exit_status
    assert_equal "git log --oneline", result.interactive_command
    assert_includes result.output, "$ glog"
    assert_includes result.output, "interactive PTY session started"
  end

  def test_alias_can_expand_to_builtin
    shell = Kward::Ekwsh.new(cwd: Dir.pwd, shell: "/bin/sh", aliases: { "where" => "pwd" })

    result = shell.run("where")

    assert_equal 0, result.exit_status
    assert_includes result.output, "$ where"
    assert_includes result.output, Dir.pwd
  end

  def test_pty_builtin_requires_command
    shell = Kward::Ekwsh.new(cwd: Dir.pwd, shell: "/bin/sh")

    result = shell.run("pty")

    assert_equal 2, result.exit_status
    assert_includes result.output, "Usage: pty <command>"
  end

  def test_pty_builtin_child_env_removes_default_git_pager
    shell = Kward::Ekwsh.new(cwd: Dir.pwd, shell: "/bin/sh", env: { "PATH" => "" })

    refute_includes shell.child_env(interactive: true), "GIT_PAGER"
    assert_equal "cat", shell.child_env.fetch("GIT_PAGER")
  end

  def test_pty_builtin_child_env_preserves_configured_git_pager
    shell = Kward::Ekwsh.new(cwd: Dir.pwd, shell: "/bin/sh", env: { "PATH" => "", "GIT_PAGER" => "less" })

    assert_equal "less", shell.child_env(interactive: true).fetch("GIT_PAGER")
  end

  def test_pty_builtin_is_completed
    shell = Kward::Ekwsh.new(cwd: Dir.pwd, shell: "/bin/sh", env: { "PATH" => "" })

    completion = shell.complete("pt", 2)

    assert_includes completion.candidates, "pty"
    assert_equal "pty ", completion.replacement
  end

  def test_nonzero_command_reports_exit_status
    shell = Kward::Ekwsh.new(cwd: Dir.pwd, shell: "/bin/sh")

    result = shell.run("capture ruby -e 'exit 7'")

    assert_equal 7, result.exit_status
    assert_includes result.output, "Exit status: 7"
  end

  def test_external_commands_run_with_tty_stdout
    shell = Kward::Ekwsh.new(cwd: Dir.pwd, shell: "/bin/sh")
    ruby = Shellwords.escape(RbConfig.ruby)

    result = shell.run(%(capture #{ruby} -e 'print STDOUT.tty? ? "tty" : "pipe"'))

    assert_equal 0, result.exit_status
    assert_match(/\btty\b/, result.output)
  end

  def test_external_commands_receive_terminal_columns
    shell = Kward::Ekwsh.new(cwd: Dir.pwd, shell: "/bin/sh")
    ruby = Shellwords.escape(RbConfig.ruby)

    result = shell.run(%(capture #{ruby} -rio/console -e 'print IO.console.winsize[1]'))

    assert_equal 0, result.exit_status
    assert_match(/\b\d+\b/, result.output)
  end

  def test_external_commands_normalize_pty_line_endings
    shell = Kward::Ekwsh.new(cwd: Dir.pwd, shell: "/bin/sh")
    ruby = Shellwords.escape(RbConfig.ruby)

    result = shell.run(%(capture #{ruby} -e 'STDOUT.write "one\\ntwo\\n"'))

    assert_equal 0, result.exit_status
    assert_includes result.output, "one\ntwo\n"
    refute_includes result.output, "\r"
  end

  def test_streams_external_command_output
    shell = Kward::Ekwsh.new(cwd: Dir.pwd, shell: "/bin/sh")
    chunks = []

    result = shell.run("capture printf one; printf two") { |chunk| chunks << chunk }

    assert result.streamed
    assert_equal result.output, chunks.join
    assert_includes chunks.join, "$ capture printf one; printf two\none"
    assert_includes chunks.join, "two\n"
  end

  def test_streaming_preserves_built_in_output_for_later_prompt_write
    shell = Kward::Ekwsh.new(cwd: Dir.pwd, shell: "/bin/sh")
    chunks = []

    result = shell.run("pwd") { |chunk| chunks << chunk }

    refute result.streamed
    assert_empty chunks
    assert_includes result.output, "$ pwd"
  end

  def test_command_timeout_reports_failure
    shell = Kward::Ekwsh.new(cwd: Dir.pwd, shell: "/bin/sh", timeout_seconds: 1)

    result = shell.run("capture ruby -e 'sleep 5'")

    assert_equal 1, result.exit_status
    assert_includes result.output, "ekwsh: command timed out after 1 seconds"
    assert_includes result.output, "Exit status: 1"
  end

  def test_command_cancellation_reports_ctrl_c_status
    shell = Kward::Ekwsh.new(cwd: Dir.pwd, shell: "/bin/sh", timeout_seconds: 5)
    cancellation = Kward::Cancellation.new
    chunks = []
    result = nil

    worker = Thread.new do
      result = shell.run("capture ruby -e 'sleep 5'", cancellation: cancellation) { |chunk| chunks << chunk }
    end
    sleep 0.1
    cancellation.cancel!
    worker.join(2)

    refute worker.alive?, "expected cancelled command to finish"
    assert_equal 130, result.exit_status
    assert_includes result.output, "^C\nExit status: 130"
    assert_includes chunks.join, "^C\nExit status: 130"
  ensure
    worker&.kill if worker&.alive?
  end

  def test_cli_ctrl_c_cancels_running_ekwsh_command
    prompt = FakePrompt.new([])
    started_at = Time.now
    prompt.define_singleton_method(:begin_busy_input) { |_message, activity: "loading"| nil }
    prompt.define_singleton_method(:finish_busy_input) { nil }
    prompt.define_singleton_method(:write_transcript_delta) do |chunk|
      @streamed_chunks ||= []
      @streamed_chunks << chunk
    end
    prompt.define_singleton_method(:streamed_chunks) { @streamed_chunks || [] }
    prompt.define_singleton_method(:poll_input) do
      Time.now - started_at > 0.1 ? Kward::PromptInterface::CANCEL_INPUT : nil
    end
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([]))
    shell = Kward::Ekwsh.new(cwd: Dir.pwd, shell: "/bin/sh", timeout_seconds: 5)

    result = Timeout.timeout(2) { cli.send(:run_ekwsh_command, shell, "capture ruby -e 'sleep 5'") }

    assert_equal 130, result.exit_status
    assert_includes prompt.streamed_chunks.join, "^C\nExit status: 130"
  end

  def test_command_output_limit_reports_failure
    shell = Kward::Ekwsh.new(cwd: Dir.pwd, shell: "/bin/sh", max_output_bytes: 3)

    result = shell.run("capture printf abcdef")

    assert_equal 1, result.exit_status
    assert_includes result.output, "abc"
    assert_includes result.output, "ekwsh: output exceeded 3 bytes; command terminated"
    assert_includes result.output, "Exit status: 1"
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
    prompt.define_singleton_method(:write_transcript_delta) do |chunk|
      @streamed_chunks ||= []
      @streamed_chunks << chunk
    end
    prompt.define_singleton_method(:streamed_chunks) { @streamed_chunks || [] }
    prompt.define_singleton_method(:busy_calls) { @busy_calls || [] }
    prompt.define_singleton_method(:finished?) { @finished }
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([]))
    shell = Kward::Ekwsh.new(cwd: Dir.pwd, shell: "/bin/sh")

    result = cli.send(:run_ekwsh_command, shell, "capture printf ok")

    assert result.streamed
    assert_includes prompt.streamed_chunks.join, "ok"
    assert_equal [[shell.prompt_label, "running"]], prompt.busy_calls
    assert prompt.finished?
  end

  def test_exit_command_requests_shell_exit
    shell = Kward::Ekwsh.new(cwd: Dir.pwd, shell: "/bin/sh")

    result = shell.run("exit")

    assert result.exit_shell
    assert_includes result.output, "$ exit"
  end

  def test_exit_accepts_numeric_status
    shell = Kward::Ekwsh.new(cwd: Dir.pwd, shell: "/bin/sh")

    result = shell.run("exit 7")

    assert result.exit_shell
    assert_equal 7, result.exit_status
    assert_includes result.output, "$ exit 7"
  end

  def test_cd_rejects_too_many_arguments
    shell = Kward::Ekwsh.new(cwd: Dir.pwd, shell: "/bin/sh")

    result = shell.run("cd one two")

    assert_equal 2, result.exit_status
    assert_includes result.output, "ekwsh: cd: too many arguments"
  end

  def test_pwd_rejects_unexpected_arguments
    shell = Kward::Ekwsh.new(cwd: Dir.pwd, shell: "/bin/sh")

    result = shell.run("pwd nope")

    assert_equal 2, result.exit_status
    assert_includes result.output, "Usage: pwd [-L|-P]"
  end

  def test_export_name_sets_empty_environment_value
    shell = Kward::Ekwsh.new(cwd: Dir.pwd, shell: "/bin/sh", env: { "PATH" => "" })

    shell.run("export KWARD_EMPTY_TEST")
    result = shell.run("capture printf '<%s>' \"$KWARD_EMPTY_TEST\"")

    assert_includes result.output, "<>"
  end

  def test_plain_assignment_persists_environment_value
    shell = Kward::Ekwsh.new(cwd: Dir.pwd, shell: "/bin/sh", env: { "PATH" => "" })

    shell.run("KWARD_ASSIGN_TEST=ready")
    result = shell.run("capture printf %s \"$KWARD_ASSIGN_TEST\"")

    assert_includes result.output, "ready"
  end

  def test_unalias_removes_aliases
    shell = Kward::Ekwsh.new(cwd: Dir.pwd, shell: "/bin/sh", env: { "PATH" => "" }, aliases: { "hi" => "printf hi" })

    removed = shell.run("unalias hi")
    result = shell.run("alias hi")

    assert_equal 0, removed.exit_status
    refute_includes result.output, "alias hi="
  end
end
