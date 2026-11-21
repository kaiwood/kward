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

  def test_interactive_kwshrc_applies_aliases_exports_and_relative_sources_in_order
    Dir.mktmpdir do |home|
      config = File.join(home, "settings")
      Dir.mkdir(config)
      File.write(File.join(config, "config.json"), "not JSON")
      File.write(File.join(config, "kwshrc"), "export SHELL_TEST_COLOR=first\nsource extra.rc\n")
      File.write(File.join(config, "extra.rc"), "alias report_config='printf \"rc:%s:%s\\n\" \"$SHELL_TEST_COLOR\"'\n")
      File.write(File.join(home, ".kwshrc"), <<~KWSHRC)
        export SHELL_TEST_COLOR=override
        export ENV=#{home}/startup
        touch #{home}/unwanted
      KWSHRC
      File.write(File.join(home, "startup"), "touch #{home}/unwanted\n")
      env = { "HOME" => home, "KWARD_CONFIG_PATH" => File.join(config, "config.json"), "ENV" => nil, "SHELL_TEST_COLOR" => nil }

      with_terminal(env) do |reader, writer, pid|
        read_until(reader, PROMPT)
        writer.write("report_con\tworks\n")
        read_until(reader, "\r\nrc:override:works\r\n")
        read_until(reader, PROMPT)
        writer.write("exit\n")
        assert_equal 0, wait_for_exit(pid).exitstatus
      end
      refute File.exist?(File.join(home, "unwanted"))

      output, error, status = Open3.capture3(env, RbConfig.ruby, EXECUTABLE, "shell", "-c", 'printf "%s" "${SHELL_TEST_COLOR-unset}"')
      assert status.success?, error
      assert_equal "unset", output
      assert_empty error
    end
  end

  def test_malformed_kwshrc_is_reported_without_exposing_its_contents
    Dir.mktmpdir do |home|
      File.write(File.join(home, ".kwshrc"), "export PRIVATE='fixture-secret\n")
      with_terminal("HOME" => home, "KWARD_CONFIG_PATH" => nil) do |reader, writer, pid|
        startup = read_until(reader, PROMPT)
        assert_includes startup, "could not read kwshrc"
        refute_includes startup, "fixture-secret"
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

  def test_second_tab_lists_ambiguous_matches_and_keeps_the_draft
    Dir.mktmpdir do |dir|
      %w[match-left match-right].each { |name| File.write(File.join(dir, name), "") }
      with_terminal do |reader, writer, pid|
        read_until(reader, PROMPT)
        writer.write("cd #{Shellwords.escape(dir)}\n")
        read_until(reader, PROMPT)
        writer.write("printf '<%s>\\n' mat\t\t")
        read_until(reader, "\r\nmatch-left\r\nmatch-right\r\n")
        read_until(reader, "printf '<%s>\\n' match-")
        writer.write("left\n")
        read_until(reader, "\r\n<match-left>\r\n")
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
          tool("run_shell_command", command: "export VIA_AGENT=live; /bin/echo tool-output")
        end
      end
    CODE
    with_shell_agent(client) do |reader, writer, pid|
      read_until(reader, PROMPT)
      writer.write("/bin/sh -c 'echo waiting; read -r value; echo \"$value\"'\n")
      read_until(reader, "\r\nwaiting\r\n")
      writer.write("interactive-secret\n")
      read_until(reader, "\r\ninteractive-secret\r\n")
      read_until(reader, PROMPT)
      writer.write("? set VIA_AGENT to live\n")
      output = read_until(reader, "Tool result: Exit status: 0")
      refute_includes output, "\r\ntool-output\r\n"
      read_until(reader, "\r\ntool-output\r\n")
      read_until(reader, PROMPT)
      writer.write("/bin/echo \"$VIA_AGENT\"\n")
      read_until(reader, "\r\nlive\r\n")
      read_until(reader, PROMPT)
      writer.write("exit\n")
      assert_equal 0, wait_for_exit(pid).exitstatus
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

  def with_shell_agent(client_code)
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
      with_terminal({ "HOME" => home, "KWARD_CONFIG_PATH" => nil, "KWARD_CONFIG_DIR" => nil },
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
