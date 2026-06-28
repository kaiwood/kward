require_relative "../test_helper"

class TestCLICommands < KwardTestCase
  def test_module_split_keeps_one_shot_mode_working
    cli = Kward::CLI.new(argv: ["hello"], stdin: FakeInput.new("", tty: true), client: FakeClient.new([{ "role" => "assistant", "content" => "hi" }]))

    assert_equal "hi", cli.one_shot("hello")
  end

  def test_help_command_prints_colored_command_overview
    prompt = FakePrompt.new([])
    cli = Kward::CLI.new(argv: ["--help"], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([]))
    cli.instance_variable_set(:@color_enabled, true)

    cli.run

    output = prompt.output.join("\n")
    assert_includes output, "\e[32;1mKward\e[0m - an extendable CLI coding agent"
    assert_includes output, "\e[34;1mUsage\e[0m"
    assert_includes output, "\e[32;1mkward login\e[0m"
    assert_includes output, "\e[32;1mkward init\e[0m"
    assert_includes output, "\e[32;1mkward pan\e[0m"
    assert_includes output, "\e[36m\"Explain this project\"\e[0m"
    assert_includes output, "\e[36m\"Summarize the main changes\"\e[0m"
    refute_includes output, "--install-starter-pack"
    refute_includes output, "--pan-mode"
    assert_includes output, "Command names take precedence. Anything else is sent as a one-shot prompt."
  end

  def test_version_command_prints_version
    prompt = FakePrompt.new([])
    cli = Kward::CLI.new(argv: ["version"], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([]))

    cli.run

    assert_equal ["kward #{Kward::VERSION}"], prompt.output
  end

  def test_command_specific_help_prints_usage_and_examples
    prompt = FakePrompt.new([])
    cli = Kward::CLI.new(argv: ["help", "pan"], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([]))
    cli.instance_variable_set(:@color_enabled, true)

    cli.run

    output = prompt.output.join("\n")
    assert_includes output, "\e[32;1mpan\e[0m - Start Pan mode"
    assert_includes output, "\e[34;1mUsage\e[0m"
    assert_includes output, "\e[32;1mkward pan\e[0m"
    assert_includes output, "\e[32;1mkward --working-directory ~/code/project pan\e[0m"
  end

  def test_command_help_option_prints_command_help
    prompt = FakePrompt.new([])
    cli = Kward::CLI.new(argv: ["pan", "--help"], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([]))

    cli.run

    assert_includes prompt.output.join("\n"), "Usage\n  kward pan"
  end

  def test_doctor_reports_local_setup
    Dir.mktmpdir do |config_dir|
      Dir.mktmpdir do |workspace_dir|
        config_path = File.join(config_dir, "config.json")
        File.write(config_path, JSON.dump({ "openrouter_api_key" => "sk-test", "pan_mode" => { "username" => "u", "password" => "p" } }))
        prompt = FakePrompt.new([])
        cli = Kward::CLI.new(argv: ["--working-directory", workspace_dir, "doctor"], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([]))

        with_env("KWARD_CONFIG_PATH" => config_path) do
          cli.run
        end

        output = strip_ansi(prompt.output.join("\n"))
        assert_includes output, "Kward Doctor"
        assert_includes output, "Config: #{config_path}"
        assert_includes output, "Config JSON: valid"
        assert_includes output, "Workspace: #{File.expand_path(workspace_dir)}"
        assert_includes output, "Model: Codex / fake-model"
        assert_includes output, "Auth:"
        assert_includes output, "OpenRouter API key"
        assert_includes output, "Pan mode: credentials configured"
      end
    end
  end

  def test_doctor_help_is_available
    prompt = FakePrompt.new([])
    cli = Kward::CLI.new(argv: ["doctor", "--help"], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([]))

    cli.run

    assert_includes prompt.output.join("\n"), "Usage\n  kward doctor"
  end

  def test_auth_status_reports_configured_credentials_without_secret_values
    Dir.mktmpdir do |config_dir|
      auth_path = File.join(config_dir, "auth.json")
      github_path = File.join(config_dir, "github_auth.json")
      config_path = File.join(config_dir, "config.json")
      File.write(auth_path, JSON.dump({ "tokens" => { "access_token" => "secret-openai" } }))
      File.write(github_path, JSON.dump({ "tokens" => { "access" => "secret-github" } }))
      File.write(config_path, JSON.dump({ "openrouter_api_key" => "secret-openrouter" }))
      prompt = FakePrompt.new([])
      cli = Kward::CLI.new(argv: ["auth", "status"], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([]))

      with_env("KWARD_CONFIG_PATH" => config_path, "KWARD_AUTH_PATH" => auth_path, "KWARD_GITHUB_AUTH_PATH" => github_path) do
        cli.run
      end

      output = strip_ansi(prompt.output.join("\n"))
      assert_includes output, "Auth Status"
      assert_includes output, "OpenAI OAuth: configured"
      assert_includes output, "GitHub OAuth: configured"
      assert_includes output, "OpenRouter API key: configured"
      refute_includes output, "secret-openai"
      refute_includes output, "secret-github"
      refute_includes output, "secret-openrouter"
    end
  end

  def test_auth_logout_removes_saved_credentials
    Dir.mktmpdir do |config_dir|
      auth_path = File.join(config_dir, "auth.json")
      github_path = File.join(config_dir, "github_auth.json")
      config_path = File.join(config_dir, "config.json")
      File.write(auth_path, JSON.dump({ "tokens" => { "access_token" => "secret-openai" } }))
      File.write(github_path, JSON.dump({ "tokens" => { "access" => "secret-github" } }))
      File.write(config_path, JSON.dump({ "openrouter_api_key" => "secret-openrouter" }))
      prompt = FakePrompt.new([])
      cli = Kward::CLI.new(argv: ["auth", "logout"], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([]))

      with_env("KWARD_CONFIG_PATH" => config_path, "KWARD_AUTH_PATH" => auth_path, "KWARD_GITHUB_AUTH_PATH" => github_path) do
        cli.run
      end

      refute_path_exists auth_path
      refute_path_exists github_path
      refute JSON.parse(File.read(config_path)).key?("openrouter_api_key")
      assert_includes prompt.output.join("\n"), "Removed 3 saved credentials."
    end
  end

  def test_auth_help_is_available
    prompt = FakePrompt.new([])
    cli = Kward::CLI.new(argv: ["auth", "--help"], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([]))

    cli.run

    assert_includes prompt.output.join("\n"), "Usage\n  kward auth status|logout"
  end

  def test_known_command_with_invalid_arguments_does_not_run_one_shot
    Dir.mktmpdir do |config_dir|
      client = Object.new
      client.define_singleton_method(:chat) { |_messages, **_opts| raise "model should not be called" }
      cli = Kward::CLI.new(argv: ["pan", "extra"], stdin: FakeInput.new("", tty: true), client: client)

      stderr = with_env("KWARD_CONFIG_PATH" => File.join(config_dir, "config.json")) do
        capture_io do
          assert_raises(SystemExit) { cli.run }
        end.last
      end

      assert_includes stderr, "Usage: kward pan"
      assert_includes stderr, "Run `kward help` for available commands."
    end
  end

  def test_help_with_too_many_arguments_reports_usage
    prompt = FakePrompt.new([])
    cli = Kward::CLI.new(argv: ["help", "pan", "extra"], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([]))

    stderr = capture_io do
      assert_raises(SystemExit) { cli.run }
    end.last

    assert_includes stderr, "Usage: kward help [command]"
    assert_empty prompt.output
  end

  def test_removed_count_tests_command_runs_as_prompt_instead_of_crashing
    Dir.mktmpdir do |config_dir|
      client = RecordingClient.new(["treated as prompt"])
      cli = Kward::CLI.new(argv: ["count-tests"], stdin: FakeInput.new("", tty: true), client: client)

      stdout = with_env("KWARD_CONFIG_PATH" => File.join(config_dir, "config.json")) do
        capture_io { cli.run }.first
      end

      assert_includes stdout, "treated as prompt"
      assert_equal "count-tests", client.seen_messages.first.last[:content]
    end
  end

  def test_multi_argument_input_runs_as_one_shot_prompt
    Dir.mktmpdir do |config_dir|
      client = RecordingClient.new(["summary"])
      cli = Kward::CLI.new(argv: ["Explain", "this", "project"], stdin: FakeInput.new("", tty: true), client: client)

      stdout = with_env("KWARD_CONFIG_PATH" => File.join(config_dir, "config.json")) do
        capture_io { cli.run }.first
      end

      assert_includes stdout, "summary"
      assert_equal "Explain this project", client.seen_messages.first.last[:content]
    end
  end

  def test_single_argument_prompt_still_runs_one_shot
    Dir.mktmpdir do |config_dir|
      cli = Kward::CLI.new(argv: ["Explain this project"], stdin: FakeInput.new("", tty: true), client: FakeClient.new([{ "role" => "assistant", "content" => "summary" }]))

      stdout = with_env("KWARD_CONFIG_PATH" => File.join(config_dir, "config.json")) do
        capture_io { cli.run }.first
      end

      assert_includes stdout, "summary"
    end
  end

  def test_stdin_without_prompt_runs_as_one_shot_prompt
    Dir.mktmpdir do |config_dir|
      client = RecordingClient.new(["explained"])
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("Explain Ruby\n", tty: false), client: client)

      stdout = with_env("KWARD_CONFIG_PATH" => File.join(config_dir, "config.json")) do
        capture_io { cli.run }.first
      end

      assert_includes stdout, "explained"
      assert_equal "Explain Ruby", client.seen_messages.first.last[:content]
    end
  end

  def test_stdin_with_prompt_runs_filter_mode
    Dir.mktmpdir do |config_dir|
      client = RecordingClient.new(["Hallo"])
      cli = Kward::CLI.new(argv: ["Translate to German"], stdin: FakeInput.new("Hello\n", tty: false), client: client)

      stdout = with_env("KWARD_CONFIG_PATH" => File.join(config_dir, "config.json")) do
        capture_io { cli.run }.first
      end

      messages = client.seen_messages.first
      assert_equal "Hallo\n", stdout
      assert_includes messages.first[:content], "command-line text filter"
      assert_includes messages.last[:content], "Instruction:\nTranslate to German"
      assert_includes messages.last[:content], "Input:\nHello\n"
    end
  end

  def test_filter_flag_forces_filter_mode
    Dir.mktmpdir do |config_dir|
      client = RecordingClient.new(["Hallo"])
      cli = Kward::CLI.new(argv: ["--filter", "Translate to German"], stdin: FakeInput.new("Hello\n", tty: false), client: client)

      stdout = with_env("KWARD_CONFIG_PATH" => File.join(config_dir, "config.json")) do
        capture_io { cli.run }.first
      end

      assert_equal "Hallo\n", stdout
      assert_includes client.seen_messages.first.first[:content], "Return only the transformed output"
    end
  end

  def test_mode_oneshot_treats_stdin_and_arguments_as_prompt_mode
    Dir.mktmpdir do |config_dir|
      client = RecordingClient.new(["ok"])
      cli = Kward::CLI.new(argv: ["--mode", "oneshot", "Translate to German"], stdin: FakeInput.new("Hello\n", tty: false), client: client)

      with_env("KWARD_CONFIG_PATH" => File.join(config_dir, "config.json")) do
        capture_io { cli.run }
      end

      messages = client.seen_messages.first
      refute_includes messages.first[:content], "command-line text filter"
      assert_equal "Translate to German", messages.last[:content]
    end
  end

  def test_unknown_mode_exits_with_error
    Dir.mktmpdir do |config_dir|
      cli = Kward::CLI.new(argv: ["--mode", "review", "hello"], stdin: FakeInput.new("", tty: true), client: FakeClient.new([]))

      stderr = with_env("KWARD_CONFIG_PATH" => File.join(config_dir, "config.json")) do
        capture_io do
          assert_raises(SystemExit) { cli.run }
        end.last
      end

      assert_includes stderr, "Unknown mode: review"
      assert_includes stderr, "Expected one of: auto, chat, oneshot, filter"
    end
  end

  def test_filter_mode_without_stdin_exits_with_error
    Dir.mktmpdir do |config_dir|
      client = Object.new
      client.define_singleton_method(:chat) { |_messages, **_opts| raise "model should not be called" }
      cli = Kward::CLI.new(argv: ["--filter", "Translate to German"], stdin: FakeInput.new("", tty: true), client: client)

      stderr = with_env("KWARD_CONFIG_PATH" => File.join(config_dir, "config.json")) do
        capture_io do
          assert_raises(SystemExit) { cli.run }
        end.last
      end

      assert_includes stderr, "Filter mode requires stdin input."
    end
  end

  def test_working_directory_option_sets_one_shot_workspace
    Dir.mktmpdir do |config_dir|
      Dir.mktmpdir do |workspace_dir|
        File.write(File.join(workspace_dir, "AGENTS.md"), "Workspace marker from option")
        client = RecordingClient.new(["ok"])
        cli = Kward::CLI.new(argv: ["--working-directory", workspace_dir, "hello"], stdin: FakeInput.new("", tty: true), client: client)

        with_env("KWARD_CONFIG_PATH" => File.join(config_dir, "config.json")) do
          capture_io { cli.run }
        end

        system_message = client.seen_messages.first.first[:content]
        assert_includes system_message, "Workspace guidance is available"
        assert_includes system_message, File.join(File.realpath(workspace_dir), "AGENTS.md")
        refute_includes system_message, "Workspace marker from option"
      end
    end
  end

  def test_working_directory_option_can_follow_prompt_words
    Dir.mktmpdir do |config_dir|
      Dir.mktmpdir do |workspace_dir|
        client = RecordingClient.new(["ok"])
        cli = Kward::CLI.new(argv: ["Explain", "this", "--working-directory=#{workspace_dir}", "project"], stdin: FakeInput.new("", tty: true), client: client)

        with_env("KWARD_CONFIG_PATH" => File.join(config_dir, "config.json")) do
          capture_io { cli.run }
        end

        assert_equal "Explain this project", client.seen_messages.first.last[:content]
      end
    end
  end

  def test_prompt_delimiter_preserves_option_like_prompt_text
    Dir.mktmpdir do |config_dir|
      client = RecordingClient.new(["ok"])
      cli = Kward::CLI.new(argv: ["--", "explain", "--working-directory", "option"], stdin: FakeInput.new("", tty: true), client: client)

      with_env("KWARD_CONFIG_PATH" => File.join(config_dir, "config.json")) do
        capture_io { cli.run }
      end

      assert_equal "explain --working-directory option", client.seen_messages.first.last[:content]
    end
  end

  def test_prompt_delimiter_preserves_command_like_prompt_text
    Dir.mktmpdir do |config_dir|
      client = RecordingClient.new(["ok"])
      cli = Kward::CLI.new(argv: ["--", "pan", "extra"], stdin: FakeInput.new("", tty: true), client: client)

      with_env("KWARD_CONFIG_PATH" => File.join(config_dir, "config.json")) do
        capture_io { cli.run }
      end

      assert_equal "pan extra", client.seen_messages.first.last[:content]
    end
  end

  def test_missing_working_directory_option_value_exits_with_error
    Dir.mktmpdir do |config_dir|
      cli = Kward::CLI.new(argv: ["--working-directory"], stdin: FakeInput.new("", tty: true), client: FakeClient.new([]))

      stderr = with_env("KWARD_CONFIG_PATH" => File.join(config_dir, "config.json")) do
        capture_io do
          assert_raises(SystemExit) { cli.run }
        end.last
      end

      assert_includes stderr, "Missing value for --working-directory"
      assert_includes stderr, "Run `kward help` for available commands."
    end
  end

  def test_pan_command_starts_pan_server_with_working_directory
    Dir.mktmpdir do |config_dir|
      Dir.mktmpdir do |workspace_dir|
        calls = []
        original_new = Kward::PanServer.method(:new)
        Kward::PanServer.define_singleton_method(:new) do |client:, working_directory:|
          calls << { client: client, working_directory: working_directory }
          Object.new.tap { |server| server.define_singleton_method(:run) { calls << :run } }
        end
        client = FakeClient.new([])
        cli = Kward::CLI.new(argv: ["--working-directory", workspace_dir, "pan"], stdin: FakeInput.new("", tty: true), client: client)

        with_env("KWARD_CONFIG_PATH" => File.join(config_dir, "config.json")) do
          cli.run
        end

        assert_equal [{ client: client, working_directory: File.expand_path(workspace_dir) }, :run], calls
      ensure
        Kward::PanServer.define_singleton_method(:new, original_new) if original_new
      end
    end
  end

  def test_removed_pan_mode_flag_is_treated_as_prompt
    Dir.mktmpdir do |config_dir|
      client = RecordingClient.new(["reply"])
      cli = Kward::CLI.new(argv: ["--pan-mode"], stdin: FakeInput.new("", tty: true), client: client)

      with_env("KWARD_CONFIG_PATH" => File.join(config_dir, "config.json")) do
        output = capture_io { cli.run }.first

        assert_includes output, "reply"
        assert_equal "--pan-mode", client.seen_messages.first.last[:content]
      end
    end
  end

  def test_rpc_subcommand_starts_rpc_server
    initialize_body = JSON.generate({ jsonrpc: "2.0", id: 1, method: "initialize" })
    shutdown_body = JSON.generate({ jsonrpc: "2.0", id: 2, method: "shutdown" })
    stdin = StringIO.new("Content-Length: #{initialize_body.bytesize}\r\n\r\n#{initialize_body}Content-Length: #{shutdown_body.bytesize}\r\n\r\n#{shutdown_body}")
    cli = Kward::CLI.new(argv: ["rpc"], stdin: stdin, client: FakeClient.new([]))

    output = capture_io { cli.run }.first

    assert_includes output, '"protocolVersion":1'
    assert_includes output, '"ok":true'
  end

end
