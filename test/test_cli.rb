require "shellwords"
require_relative "test_helper"

class TestCLI < KwardTestCase
  def rewrite_session_timestamps(path, timestamps_by_id)
    lines = File.readlines(path).map do |line|
      record = JSON.parse(line)
      timestamp = timestamps_by_id[record["id"]]
      record["timestamp"] = timestamp.utc.iso8601(3) if timestamp
      JSON.generate(record)
    end
    File.write(path, lines.join("\n") + "\n")
  end

  def hide_composer_git_branch(cli)
    cli.define_singleton_method(:composer_git_branch_text) { nil }
  end

  def create_project_skill(workspace, name)
    path = File.join(workspace, ".agents", "skills", name, "SKILL.md")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "---\nname: #{name}\ndescription: #{name} project skill.\n---\n")
    path
  end

  class RecordingPromptInterface < FakePrompt
    attr_reader :options, :started

    def initialize(**options)
      super([])
      @options = options
      @started = false
    end

    def start
      @started = true
    end
  end

  class RecordingPromptInterfaceCLI < Kward::CLI
    def load_prompt_interface
      RecordingPromptInterface
    end
  end

  class WarningPromptInterface < FakePrompt
    def initialize(**_options)
      super([])
    end

    def start
      @started = true
    end

    def start_stream_block(*)
    end

    def write_delta(*)
    end
  end

  class WarningPromptInterfaceCLI < Kward::CLI
    def load_prompt_interface
      WarningPromptInterface
    end
  end

  class CountingConversation < Kward::Conversation
    attr_reader :refresh_count

    def refresh_system_message!
      @refresh_count = @refresh_count.to_i + 1
      super
    end
  end

  class BannerPrompt < FakePrompt
    attr_reader :banner_count

    def initialize(inputs)
      super(inputs)
      @banner_count = 0
    end

    def print_visual_banner(message = nil)
      @banner_count += 1
      @output << (message || "[visual banner]")
    end
  end

  class EventAgent
    def initialize(events, answer: "")
      @events = events
      @answer = answer
    end

    def ask(_input, **_options)
      @events.each { |event| yield event }
      @answer
    end
  end

  class PollingPrompt < FakePrompt
    def poll_input
      @inputs.shift
    end
  end

  class FailingSteering
    def submit(_input)
      raise "steering failed"
    end
  end

  class RecordingLoginCLI < Kward::CLI
    attr_reader :login_providers

    def initialize(*args, fail_login: false, **kwargs)
      super(*args, **kwargs)
      @fail_login = fail_login
      @login_providers = []
    end

    def login(provider: nil, oauth: nil, auth_method: nil)
      raise "OAuth timed out" if @fail_login

      @login_providers << provider
      @prompt.say("Saved #{provider} OAuth login")
    end
  end

  class BusyPrompt < FakePrompt
    attr_reader :events, :write_deltas

    def initialize(inputs)
      super(inputs)
      @events = []
      @write_deltas = []
      @stream_block = nil
    end

    def begin_busy_input(message, activity: "streaming")
      @events << [:begin_busy_input, message, activity]
    end

    def finish_busy_input
      @events << [:finish_busy_input]
    end

    def poll_input
      nil
    end

    def start_stream_block(label)
      return if @stream_block == label

      @stream_block = label
      @events << [:start_stream_block, label]
    end

    def write_delta(delta)
      @events << [:write_delta, delta]
      @write_deltas << delta
      @output << delta
    end

    def finish_stream_block
      @stream_block = nil
      @events << [:finish_stream_block]
    end

    def close
      @events << [:close]
    end
  end

  class CombinedStreamPrompt < BusyPrompt
    attr_reader :stream_writes

    def initialize(inputs)
      super
      @stream_writes = []
    end

    def write_stream_block(label, delta, finish: false)
      @stream_writes << { label: label, delta: delta, finish: finish }
    end
  end

  class BusySelectPrompt < BusyPrompt
    attr_reader :select_messages, :select_choices, :select_titles, :select_initial_indices

    def initialize(inputs, selections: [])
      super(inputs)
      @selections = selections
      @select_messages = []
      @select_choices = []
      @select_titles = []
      @select_initial_indices = []
    end

    def select(message, choices, title: "Sessions", custom: false, initial_index: 0, action_keys: {}, action_handlers: {})
      @select_messages << message
      @select_choices << choices
      @select_titles << title
      @select_initial_indices << initial_index
      @selections.empty? ? choices.first : @selections.shift
    end
  end

  class BusyPollingSelectPrompt < BusySelectPrompt
    def initialize(inputs, selections: [])
      super([], selections: selections)
      @poll_inputs = inputs
    end

    def poll_input
      @poll_inputs.shift
    end
  end

  class DelayedEventAgent
    attr_reader :conversation

    def initialize(conversation, delay:, events:, answer: "")
      @conversation = conversation
      @delay = delay
      @events = events
      @answer = answer
    end

    def ask(_input, **_options)
      sleep @delay
      @events.each { |event| yield event }
      @answer
    end
  end

  class SlowModelsClient < FakeClient
    def available_models
      sleep 0.05
      super
    end
  end

  class ReloadTrackingClient < FakeClient
    def initialize
      super([])
    end
  end

  def with_fake_net_http(responses)
    fake_http = Object.new
    fake_http.define_singleton_method(:requests) { @requests ||= [] }
    fake_http.define_singleton_method(:request) do |request|
      requests << request
      responses.shift
    end
    original_start = Net::HTTP.method(:start)
    Net::HTTP.define_singleton_method(:start) do |_host, _port, **_options, &block|
      block.call(fake_http)
    end
    yield fake_http
  ensure
    Net::HTTP.define_singleton_method(:start, original_start) if original_start
  end

  def with_clipboard_stub(copy_proc)
    original_new = Kward::Clipboard.method(:new)
    Kward::Clipboard.define_singleton_method(:new) do |**_kwargs|
      Object.new.tap do |clipboard|
        clipboard.define_singleton_method(:copy) { |text| copy_proc.call(text) }
      end
    end
    yield
  ensure
    Kward::Clipboard.define_singleton_method(:new, original_new)
  end

  def test_sysprompt_prints_annotated_effective_prompt
    Dir.mktmpdir do |config_dir|
      Dir.mktmpdir do |workspace_dir|
        Dir.mktmpdir do |home|
          File.write(File.join(config_dir, "config.json"), JSON.dump({
            "personas" => {
              "workspaces" => { workspace_dir => "Workspace persona." }
            }
          }))
          File.write(File.join(config_dir, "PRINCIPLES.md"), "Global principles.\n")
          File.write(File.join(workspace_dir, "AGENTS.md"), "Workspace instructions.\n")
          plugins_dir = File.join(home, ".kward", "plugins")
          FileUtils.mkdir_p(plugins_dir)
          File.write(File.join(plugins_dir, "context.rb"), <<~'RUBY')
            Kward.plugin do |plugin|
              plugin.prompt_context { |ctx| "Plugin workspace: #{ctx.workspace_root}" }
            end
          RUBY

          prompt = FakePrompt.new([])
          with_env("HOME" => home, "KWARD_CONFIG_PATH" => File.join(config_dir, "config.json")) do
            Kward::CLI.new(argv: ["--working-directory", workspace_dir, "sysprompt"], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([])).run
          end

          output = prompt.output.join("\n")
          assert_includes output, "Kward System Prompt"
          workspace_root = File.realpath(workspace_dir)
          assert_includes output, "Workspace: #{workspace_root}"
          assert_includes output, "## Config principles"
          assert_includes output, "Source: #{File.join(config_dir, "PRINCIPLES.md")}"
          assert_includes output, "Global principles."
          assert_includes output, "## Persona"
          assert_includes output, "Workspace persona."
          assert_includes output, "## Plugin context"
          assert_includes output, "Plugin workspace: #{workspace_root}"
          assert_includes output, "## Workspace AGENTS.md hint"
          assert_includes output, File.join(workspace_root, "AGENTS.md")
          refute_includes output, "Workspace instructions."
          assert_includes output, "Memory: not included"
        end
      end
    end
  end

  def test_sysprompt_raw_prints_unannotated_effective_prompt
    Dir.mktmpdir do |config_dir|
      Dir.mktmpdir do |workspace_dir|
        File.write(File.join(config_dir, "config.json"), JSON.dump({}))
        File.write(File.join(config_dir, "PRINCIPLES.md"), "Global principles.\n")
        File.write(File.join(workspace_dir, "AGENTS.md"), "Workspace instructions.\n")

        prompt = FakePrompt.new([])
        with_env("KWARD_CONFIG_PATH" => File.join(config_dir, "config.json")) do
          Kward::CLI.new(argv: ["--working-directory=#{workspace_dir}", "sysprompt", "--raw"], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([])).run
        end

        output = prompt.output.join("\n")
        assert_includes output, "You are Kward"
        assert_includes output, "Global principles."
        assert_includes output, "Workspace guidance is available"
        refute_includes output, "Kward System Prompt"
        refute_includes output, "## Config principles"
        refute_includes output, "Workspace instructions."
      end
    end
  end

  def test_sysprompt_reports_replacement_prompt_without_generated_sections
    Dir.mktmpdir do |config_dir|
      Dir.mktmpdir do |workspace_dir|
        FileUtils.mkdir_p(File.join(config_dir, "prompts"))
        replacement = File.join(config_dir, "prompts", "minimal.md")
        File.write(replacement, "Minimal instructions.\n")
        File.write(File.join(config_dir, "PRINCIPLES.md"), "Global principles.\n")
        File.write(File.join(workspace_dir, "AGENTS.md"), "Workspace instructions.\n")
        File.write(File.join(config_dir, "config.json"), JSON.dump("system_prompt" => { "file" => "prompts/minimal.md" }))

        prompt = FakePrompt.new([])
        with_env("KWARD_CONFIG_PATH" => File.join(config_dir, "config.json")) do
          Kward::CLI.new(argv: ["--working-directory=#{workspace_dir}", "sysprompt"], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([])).run
        end

        output = prompt.output.join("\n")
        assert_includes output, "## Custom system prompt (replacement)"
        assert_includes output, "Source: #{replacement}"
        assert_includes output, "Minimal instructions."
        refute_includes output, "## Built-in system prompt"
        refute_includes output, "Global principles."
        refute_includes output, "Workspace guidance is available"
      end
    end
  end

  def test_init_command_creates_default_config_and_reports_result
    Dir.mktmpdir do |config_dir|
      prompt = FakePrompt.new([])
      calls = []
      original_install = Kward::StarterPackInstaller.method(:install)
      Kward::StarterPackInstaller.define_singleton_method(:install) do
        calls << true
        Kward::StarterPackInstaller::Result.new(installed: ["PRINCIPLES.md"], skipped: ["prompts/plan.md"])
      end

      with_env("KWARD_CONFIG_PATH" => File.join(config_dir, "config.json")) do
        Kward::CLI.new(argv: ["init"], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([])).run
      end

      assert_equal [true], calls
      assert_path_exists File.join(config_dir, "config.json")
      output = prompt.output.join("\n")
      assert_includes output, "Installed 1 starter pack file."
      assert_includes output, "Skipped 1 existing starter pack file."
    ensure
      Kward::StarterPackInstaller.define_singleton_method(:install, original_install) if original_install
    end
  end

  def test_install_starter_pack_flag_is_treated_as_prompt
    Dir.mktmpdir do |config_dir|
      client = RecordingClient.new(["reply"])

      with_env("KWARD_CONFIG_PATH" => File.join(config_dir, "config.json")) do
        capture_io do
          Kward::CLI.new(argv: ["--install-starter-pack"], stdin: FakeInput.new("", tty: true), prompt: FakePrompt.new([]), client: client).run
        end

        assert_equal "--install-starter-pack", client.seen_messages.first.last[:content]
      end
    end
  end

  def test_interactive_response_prompt_falls_back_to_assistant_without_persona_label
    Dir.mktmpdir do |config_dir|
      File.write(File.join(config_dir, "config.json"), JSON.dump({}))
      prompt = FakePrompt.new(["hello", nil])
      client = FakeClient.new([{ "role" => "assistant", "content" => "reply" }])

      with_env("KWARD_CONFIG_PATH" => File.join(config_dir, "config.json")) do
        cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client)
        cli.interactive_loop(agent: Kward::Agent.new(client: client, tool_registry: Kward::ToolRegistry.new(prompt: prompt), conversation: Kward::Conversation.new))
      end

      output = strip_ansi(prompt.output.join)
      assert_includes output, "Assistant> reply"
      refute_includes output, "Kward> reply"
    end
  end

  def test_one_shot_renders_markdown_without_streaming
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), client: FakeClient.new([{ "role" => "assistant", "content" => "# Plan\nRun `bundle test`.\n" }]))
    cli.instance_variable_set(:@color_enabled, true)

    output = cli.one_shot("hello")

    assert_includes output, "# \e[1mPlan\e[0m"
    assert_includes output, "`\e[2mbundle test\e[0m`"
  end

  def test_login_github_uses_github_oauth_label
    prompt = FakePrompt.new([])
    oauth = Object.new
    oauth.define_singleton_method(:login) { |prompt:| "/tmp/github_auth.json" }
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([]))

    cli.login(provider: "github", oauth: oauth)

    assert_includes prompt.output.join, "GitHub OAuth login to /tmp/github_auth.json"
  end

  def test_login_openrouter_stores_api_key_in_private_credential_file
    Dir.mktmpdir do |dir|
      path = File.join(dir, "config.json")
      prompt = FakePrompt.new(["sk-or-test"])
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([]))

      with_env("KWARD_CONFIG_PATH" => path) { cli.login(provider: "openrouter") }

      credentials_path = File.join(dir, "api_keys.json")
      assert_equal "sk-or-test", JSON.parse(File.read(credentials_path))["openrouter"]
      assert_includes prompt.output.join, "OpenRouter API key to #{credentials_path}"
      refute_includes prompt.output.join, "sk-or-test"
    end
  end

  def test_api_key_login_does_not_store_a_key_when_model_validation_fails
    Dir.mktmpdir do |dir|
      path = File.join(dir, "config.json")
      prompt = FakePrompt.new(["invalid-key"])
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([]))
      catalog = Object.new
      catalog.define_singleton_method(:refresh) { raise "Groq model refresh failed: 401" }

      cli.define_singleton_method(:model_catalog) { |provider_id:, api_key:| catalog }

      with_env("KWARD_CONFIG_PATH" => path) do
        error = assert_raises(RuntimeError) { cli.login(provider: "groq") }
        assert_equal "Groq model refresh failed: 401", error.message
      end

      refute File.exist?(File.join(dir, "api_keys.json"))
      refute_includes prompt.output.join, "invalid-key"
    end
  end

  def test_login_picker_sorts_api_key_providers_and_keeps_subscription_logins_separate
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: FakePrompt.new([]), client: FakeClient.new([]))

    assert_equal ["API key", "Subscription / OAuth"], cli.send(:login_method_choices)
    assert_equal ["Anthropic", "Azure OpenAI", "Cerebras", "DeepSeek", "Fireworks AI", "Google Gemini", "Groq", "Mistral", "NVIDIA NIM", "OpenAI", "OpenRouter", "Together AI", "xAI"], cli.send(:login_provider_choices, :api_key)
    assert_equal ["Anthropic Claude", "ChatGPT", "GitHub Copilot"], cli.send(:login_provider_choices, :oauth)
    assert_equal "openrouter", cli.send(:selected_login_provider, "OpenRouter")
  end

  def test_slash_command_entries_include_skills
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "config.json"), JSON.dump({}))
      skill_dir = File.join(dir, "skills", "planner")
      FileUtils.mkdir_p(skill_dir)
      File.write(File.join(skill_dir, "SKILL.md"), "---\nname: planner\ndescription: Helps plan work.\n---\n")
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: FakePrompt.new([]), client: FakeClient.new([]))

      with_env("KWARD_CONFIG_PATH" => File.join(dir, "config.json")) do
        command = cli.send(:slash_command_entries).find { |entry| entry[:name] == "skill:planner" }

        assert_equal "Helps plan work.", command[:description]
        assert_equal "", command[:argument_hint]
      end
    end
  end

  def test_sandbox_slash_command_reports_and_updates_global_policy
    Dir.mktmpdir do |dir|
      config_path = File.join(dir, "config.json")
      File.write(config_path, JSON.dump({ "sandbox" => { "mode" => "off", "network" => "deny" } }))
      prompt = FakePrompt.new([])
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([]))

      with_env("KWARD_CONFIG_PATH" => config_path) do
        conversation = Kward::Conversation.new(workspace_root: dir)
        agent = Struct.new(:conversation, :tool_registry).new(conversation, Kward::ToolRegistry.new)

        handled, = cli.send(:handle_local_slash_command, "/sandbox status", agent, nil)
        assert_equal true, handled
        assert_includes prompt.output.join, "Command sandbox"
        assert_includes prompt.output.join, "Mode: off"

        handled, = cli.send(:handle_local_slash_command, "/sandbox workspace_write", agent, nil)
        assert_equal true, handled
        assert_equal "workspace_write", JSON.parse(File.read(config_path)).dig("sandbox", "mode")

        handled, = cli.send(:handle_local_slash_command, "/sandbox network allow", agent, nil)
        assert_equal true, handled
        assert_equal "allow", JSON.parse(File.read(config_path)).dig("sandbox", "network")
      end
    end
  end

  def test_hooks_slash_command_lists_configured_hooks
    Dir.mktmpdir do |dir|
      config_path = File.join(dir, "config.json")
      File.write(config_path, JSON.dump({
        "hooks" => {
          "shell_command_before" => [
            { "id" => "block-release", "command" => "ruby hook.rb", "failure_policy" => "deny" }
          ]
        }
      }))
      prompt = FakePrompt.new([])
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([]))

      with_env("KWARD_CONFIG_PATH" => config_path) do
        conversation = Kward::Conversation.new(workspace_root: dir)
        agent = Struct.new(:conversation, :tool_registry).new(conversation, Kward::ToolRegistry.new)

        handled, replacement = cli.send(:handle_local_slash_command, "/hooks list", agent, nil)

        assert_equal true, handled
        assert_nil replacement
        output = prompt.output.join
        assert_includes output, "Lifecycle hooks"
        assert_includes output, "block-release shell_command_before"
        assert_includes output, "failure_policy=deny"
      end
    end
  end

  def test_hooks_top_level_command_reuses_hook_commands
    Dir.mktmpdir do |dir|
      config_path = File.join(dir, "config.json")
      File.write(config_path, JSON.dump({
        "hooks" => {
          "turn_end" => [{ "id" => "notify", "command" => "ruby hook.rb" }]
        }
      }))
      prompt = FakePrompt.new([])

      with_env("KWARD_CONFIG_PATH" => config_path) do
        Kward::CLI.new(argv: ["hooks", "list"], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([])).run
      end

      output = prompt.output.join
      assert_includes output, "Lifecycle hooks"
      assert_includes output, "notify turn_end"
    end
  end

  def test_hooks_slash_command_shows_events
    prompt = FakePrompt.new([])
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([]))
    conversation = Kward::Conversation.new(system_message: nil)
    agent = Struct.new(:conversation, :tool_registry).new(conversation, Kward::ToolRegistry.new)

    handled, = cli.send(:handle_local_slash_command, "/hooks events", agent, nil)

    assert_equal true, handled
    output = prompt.output.join
    assert_includes output, "Lifecycle hook events"
    assert_includes output, "shell_command_before failure_policy=deny"
  end

  def test_hooks_doctor_reports_config_diagnostics
    Dir.mktmpdir do |dir|
      config_path = File.join(dir, "config.json")
      File.write(config_path, JSON.dump({
        "hooks" => {
          "unknown_event" => [
            { "id" => "bad-command", "type" => "command", "command" => "definitely-missing-kward-hook", "timeout_seconds" => 0, "failure_policy" => "explode" }
          ],
          "turn_end" => [
            { "id" => "bad-http", "type" => "http", "url" => "ftp://example.test/hook" },
            { "id" => "bad-type", "type" => "socket" }
          ]
        }
      }))
      prompt = FakePrompt.new([])
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([]))

      with_env("KWARD_CONFIG_PATH" => config_path) do
        conversation = Kward::Conversation.new(workspace_root: dir)
        agent = Struct.new(:conversation, :tool_registry).new(conversation, Kward::ToolRegistry.new)

        handled, = cli.send(:handle_local_slash_command, "/hooks doctor", agent, nil)

        assert_equal true, handled
        output = prompt.output.join
        assert_includes output, "unknown event unknown_event"
        assert_includes output, "unknown failure_policy explode"
        assert_includes output, "timeout_seconds must be positive"
        assert_includes output, "command executable not found: definitely-missing-kward-hook"
        assert_includes output, "bad-http: url must be http or https"
        assert_includes output, "bad-type: unsupported hook type socket"
      end
    end
  end

  def test_hooks_slash_command_trusts_workspace_hooks
    Dir.mktmpdir do |dir|
      config_path = File.join(dir, "config.json")
      File.write(config_path, JSON.dump({}))
      FileUtils.mkdir_p(File.join(dir, ".kward"))
      File.write(File.join(dir, ".kward", "hooks.json"), JSON.dump("hooks" => { "turn_end" => [{ "id" => "workspace-hook", "command" => "echo ok" }] }))
      prompt = FakePrompt.new([])
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([]))
      cli.instance_variable_set(:@working_directory, dir)

      with_env("KWARD_CONFIG_PATH" => config_path) do
        conversation = Kward::Conversation.new(workspace_root: dir)
        agent = Struct.new(:conversation, :tool_registry).new(conversation, Kward::ToolRegistry.new)

        handled, = cli.send(:handle_local_slash_command, "/hooks trust", agent, nil)
        cli.send(:handle_local_slash_command, "/hooks list", agent, nil)

        assert_equal true, handled
        output = prompt.output.join
        assert_includes output, "Trusted workspace hooks"
        assert_includes output, "workspace-hook turn_end source=workspace"
      end
    end
  end

  def test_hooks_slash_command_shows_audit_logs
    Dir.mktmpdir do |dir|
      config_path = File.join(dir, "config.json")
      File.write(config_path, JSON.dump({}))
      log_dir = File.join(dir, "logs")
      FileUtils.mkdir_p(log_dir)
      File.write(File.join(log_dir, "hooks.jsonl"), JSON.dump(
        "timestamp" => "2026-07-06T12:00:00.000Z",
        "kind" => "result",
        "event" => "shell_command_before",
        "decision" => "deny",
        "message" => "blocked"
      ) + "\n")
      prompt = FakePrompt.new([])
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([]))

      with_env("KWARD_CONFIG_PATH" => config_path) do
        conversation = Kward::Conversation.new(workspace_root: dir)
        agent = Struct.new(:conversation, :tool_registry).new(conversation, Kward::ToolRegistry.new)

        handled, = cli.send(:handle_local_slash_command, "/hooks logs", agent, nil)

        assert_equal true, handled
        output = prompt.output.join
        assert_includes output, "Lifecycle hook audit log"
        assert_includes output, "shell_command_before"
        assert_includes output, "decision=deny"
      end
    end
  end

  def test_skill_slash_command_activates_skill_without_model_turn
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "config.json"), JSON.dump({}))
      skill_dir = File.join(dir, "skills", "planner")
      FileUtils.mkdir_p(skill_dir)
      File.write(File.join(skill_dir, "SKILL.md"), "---\nname: planner\ndescription: Helps plan work.\n---\n\nPlan carefully.\n")
      prompt = FakePrompt.new([])
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([]))

      with_env("KWARD_CONFIG_PATH" => File.join(dir, "config.json")) do
        conversation = Kward::Conversation.new(system_message: nil)
        agent = Struct.new(:conversation, :tool_registry).new(conversation, Kward::ToolRegistry.new)

        handled, replacement = cli.send(:handle_local_slash_command, "/skill planner", agent, nil)

        assert_equal true, handled
        assert_nil replacement
        assert_includes prompt.output.join, "Activated skill: planner"
        assert_equal "assistant", conversation.messages[-2]["role"]
        assert_equal "tool", conversation.messages[-1][:role]
        assert_equal "read_skill", conversation.messages[-1][:name]
        assert_includes conversation.messages[-1][:content], "Plan carefully."
      end
    end
  end

  def test_skill_capture_slash_command_reviews_and_saves_a_personal_skill
    Dir.mktmpdir do |dir|
      config_path = File.join(dir, "config.json")
      File.write(config_path, JSON.dump({}))
      store = Kward::SessionStore.new(config_dir: dir, cwd: Dir.pwd)
      session = store.create
      conversation = Kward::Conversation.new(system_message: nil)
      session.attach(conversation)
      conversation.append_user("Prepare a release")
      conversation.append_assistant("Run the release checks")
      prompt_class = Class.new(FakePrompt) do
        attr_reader :reviewed_content

        def select(_message, choices, **_options)
          choices.first
        end

        def review_document(title:, content:)
          @reviewed_content = [title, content]
          yield content
        end
      end
      prompt = prompt_class.new([])
      client = RecordingClient.new(["---\nname: release-checklist\ndescription: Prepare a release.\n---\nRun the release checks.\n"])
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client)

      with_env("KWARD_CONFIG_PATH" => config_path) do
        agent = Struct.new(:conversation, :tool_registry).new(Kward::Conversation.new, Kward::ToolRegistry.new)

        handled, = cli.send(:handle_local_slash_command, "/skill capture", agent, store)

        assert_equal true, handled
        assert_equal "Review captured skill", prompt.reviewed_content.first
        assert_equal "release-checklist", YAML.safe_load(File.read(File.join(dir, "skills", "release-checklist", "SKILL.md")))["name"]
        assert_includes prompt.output.join, "Saved personal skill:"
      end
    end
  end

  def test_skill_colon_slash_command_activates_skill
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "config.json"), JSON.dump({}))
      skill_dir = File.join(dir, "skills", "planner")
      FileUtils.mkdir_p(skill_dir)
      File.write(File.join(skill_dir, "SKILL.md"), "---\nname: planner\ndescription: Helps plan work.\n---\n\nPlan carefully.\n")
      prompt = FakePrompt.new([])
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([]))

      with_env("KWARD_CONFIG_PATH" => File.join(dir, "config.json")) do
        conversation = Kward::Conversation.new(system_message: nil)
        agent = Struct.new(:conversation, :tool_registry).new(conversation, Kward::ToolRegistry.new)

        handled, = cli.send(:handle_local_slash_command, "/skill:planner", agent, nil)

        assert_equal true, handled
        assert_includes prompt.output.join, "Activated skill: planner"
      end
    end
  end

  def test_streamed_interactive_turn_renders_markdown_after_buffering
    prompt = FakePrompt.new([])
    client = MarkdownStreamingClient.new(["# Pla", "n\n```ruby\n", "puts :ok\n```\n"])
    agent = Kward::Agent.new(client: client, tool_registry: Kward::ToolRegistry.new(prompt: prompt))
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client)
    cli.instance_variable_set(:@color_enabled, true)

    output = capture_io do
      cli.send(:run_blocking_interactive_turn, agent, "hello")
    end.first

    assert_includes output, "# \e[1mPlan\e[0m"
    assert_includes output, "\e[90m┌─ code ruby\e[0m"
    assert_includes output, "\e[2m│ puts :ok\e[0m"
  end

  def test_run_reports_config_errors_without_backtrace
    Dir.mktmpdir do |config_dir|
      config_path = File.join(config_dir, "config.json")
      File.write(config_path, "{\n  \"model\": \"gpt-5\"\n  \"provider\": \"openai\"\n}")

      with_env("KWARD_CONFIG_PATH" => config_path) do
        stdout, stderr = capture_io do
          error = assert_raises(SystemExit) do
            Kward::CLI.new(argv: ["hello"], stdin: FakeInput.new("", tty: true), prompt: FakePrompt.new([]), client: FakeClient.new([])).run
          end
          assert_equal 1, error.status
        end

        assert_empty stdout
        assert_includes stderr, "Invalid Kward config JSON."
        assert_includes stderr, config_path
        assert_includes stderr, "Parser error:"
        assert_includes stderr, "Repair it with:"
        assert_includes stderr, "kward edit #{config_path}"
        assert_includes stderr, "kward --skip-config doctor"
        refute_includes stderr, "test/test_cli.rb"
      end
    end
  end

  def test_skip_config_doctor_ignores_broken_main_config
    Dir.mktmpdir do |config_dir|
      config_path = File.join(config_dir, "config.json")
      File.write(config_path, "{\n  \"model\": \"gpt-5\"\n  \"provider\": \"openai\"\n}")
      prompt = FakePrompt.new([])

      with_env("KWARD_CONFIG_PATH" => config_path) do
        Kward::CLI.new(argv: ["--skip-config", "doctor"], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([])).run
      end

      output = strip_ansi(prompt.output.join("\n"))
      assert_includes output, "Config JSON: valid"
      refute_includes output, "invalid:"
    end
  end

  def test_doctor_reports_config_json_syntax_errors
    Dir.mktmpdir do |config_dir|
      config_path = File.join(config_dir, "config.json")
      File.write(config_path, "{\n  \"model\": \"gpt-5\"\n  \"provider\": \"openai\"\n}")
      prompt = FakePrompt.new([])

      with_env("KWARD_CONFIG_PATH" => config_path) do
        Kward::CLI.new(argv: ["doctor"], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([])).run
      end

      output = strip_ansi(prompt.output.join("\n"))
      assert_includes output, "Kward Doctor"
      assert_includes output, "Config: #{config_path}"
      assert_includes output, "Config JSON: invalid:"
      assert_includes output, "line"
      assert_includes output, "Pan mode: skipped because config is invalid"
    end
  end

  def test_edit_command_opens_file_in_integrated_editor
    Dir.mktmpdir do |dir|
      path = File.join(dir, "outside.txt")
      prompt = FakePrompt.new([])
      opened = []
      prompt.define_singleton_method(:edit_file) do |file, base_dir:, allow_new:|
        opened << { file: file, base_dir: base_dir, allow_new: allow_new }
        true
      end
      cli = Kward::CLI.new(argv: ["edit", path], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([]))

      cli.run

      assert_equal [{ file: path, base_dir: Dir.pwd, allow_new: true }], opened
    end
  end

  def test_scratchpad_editor_prompt_action_is_requeued_for_interactive_loop
    action = { editor_prompt: { instruction: "write a HelloWorld class" } }
    prompt = FakePrompt.new([])
    prompt.define_singleton_method(:scratchpad) { |_language| action }
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([]))
    cli.instance_variable_set(:@pending_inputs, [])

    cli.send(:handle_local_slash_command, "/scratchpad ruby", nil, nil)

    assert_equal [action], cli.instance_variable_get(:@pending_inputs)
  end

  def test_interactive_loop_opens_scratchpad_without_model_turn
    prompt = FakePrompt.new(["/scratchpad ruby", "/exit"])
    opened = []
    prompt.define_singleton_method(:scratchpad) { |language| opened << language }
    conversation = Kward::Conversation.new(system_message: nil)
    agent = Object.new
    agent.define_singleton_method(:conversation) { conversation }
    agent.define_singleton_method(:ask) { |_input, **_options| raise "model should not be called" }
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([]))

    cli.interactive_loop(agent: agent)

    assert_equal [:ruby], opened
  end

  def test_interactive_loop_opens_files_browser_without_model_turn
    prompt = FakePrompt.new(["/files", "/exit"])
    opened = false
    prompt.define_singleton_method(:open_project_browser) { opened = true }
    conversation = Kward::Conversation.new(system_message: nil)
    agent = Object.new
    agent.define_singleton_method(:conversation) { conversation }
    agent.define_singleton_method(:ask) { |_input, **_options| raise "model should not be called" }
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([]))

    cli.interactive_loop(agent: agent)

    assert opened
    assert_empty conversation.messages
  end

  def test_interactive_loop_runs_ekwsh_without_model_turn
    Dir.mktmpdir do |dir|
      prompt = FakePrompt.new(["/shell", "pwd", "exit", "/exit"])
      conversation = Kward::Conversation.new(system_message: nil, workspace_root: dir)
      agent = Object.new
      agent.define_singleton_method(:conversation) { conversation }
      agent.define_singleton_method(:ask) { |_input, **_options| raise "model should not be called" }
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([]))

      cli.interactive_loop(agent: agent)

      output = strip_ansi(prompt.output.join)
      assert_includes output, "Entering ekwsh"
      assert_includes output, "$ pwd"
      assert_includes output, File.realpath(dir)
      assert_includes output, "$ exit"
      assert_includes output, "Shell exited."
      assert_empty conversation.messages
    end
  end

  def test_interactive_loop_runs_ekwsh_pty_builtin_without_model_turn
    Dir.mktmpdir do |dir|
      prompt = FakePrompt.new(["/shell", "pty printf shell-pty-ok", "exit", "/exit"])
      conversation = Kward::Conversation.new(system_message: nil, workspace_root: dir)
      agent = Object.new
      agent.define_singleton_method(:conversation) { conversation }
      agent.define_singleton_method(:ask) { |_input, **_options| raise "model should not be called" }
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([]))
      hide_composer_git_branch(cli)

      cli.interactive_loop(agent: agent)

      output = strip_ansi(prompt.output.join)
      assert_includes output, "$ pty printf shell-pty-ok"
      refute_includes output, "interactive PTY session"
      assert_includes output, "Shell exited."
      assert_empty conversation.messages
    end
  end

  def test_interactive_loop_runs_explicit_pty_command_without_model_turn
    Dir.mktmpdir do |dir|
      prompt = FakePrompt.new(["/pty printf pty-ok", "/exit"])
      conversation = Kward::Conversation.new(system_message: nil, workspace_root: dir)
      agent = Object.new
      agent.define_singleton_method(:conversation) { conversation }
      agent.define_singleton_method(:ask) { |_input, **_options| raise "model should not be called" }
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([]))
      hide_composer_git_branch(cli)

      cli.interactive_loop(agent: agent)

      output = strip_ansi(prompt.output.join)
      assert_includes output, "$ printf pty-ok"
      assert_includes output, "pty-ok"
      refute_includes output, "interactive PTY session"
      assert_empty conversation.messages
    end
  end

  def test_interactive_loop_reports_pty_usage_without_command
    prompt = FakePrompt.new(["/pty", "/exit"])
    conversation = Kward::Conversation.new(system_message: nil)
    agent = Object.new
    agent.define_singleton_method(:conversation) { conversation }
    agent.define_singleton_method(:ask) { |_input, **_options| raise "model should not be called" }
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([]))
    hide_composer_git_branch(cli)

    cli.interactive_loop(agent: agent)

    output = strip_ansi(prompt.output.join)
    assert_includes output, "Usage: /pty <command>"
    assert_empty conversation.messages
  end

  def test_interactive_loop_runs_ekwsh_with_global_config
    Dir.mktmpdir do |dir|
      config_path = File.join(dir, "config.json")
      File.write(File.join(dir, "ekwsh.yml"), <<~YAML)
        env:
          KWARD_EKWSH_CONFIG_TEST: configured
        aliases:
          hi: printf alias-ok
      YAML
      prompt = FakePrompt.new(["/shell", "printf %s $KWARD_EKWSH_CONFIG_TEST", "hi", "exit", "/exit"])
      conversation = Kward::Conversation.new(system_message: nil, workspace_root: dir)
      agent = Object.new
      agent.define_singleton_method(:conversation) { conversation }
      agent.define_singleton_method(:ask) { |_input, **_options| raise "model should not be called" }
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([]))
      calls = []
      cli.define_singleton_method(:run_interactive_pty_with_terminal_handoff) do |shell, command, env:, cwd:|
        calls << { shell: shell, command: command, env: env, cwd: cwd }
        Kward::InteractivePtyRunner::Result.new(exit_status: 0)
      end

      with_env("KWARD_CONFIG_PATH" => config_path) do
        cli.interactive_loop(agent: agent)
      end

      assert_equal ["printf %s $KWARD_EKWSH_CONFIG_TEST", "printf alias-ok"], calls.map { |call| call[:command] }
      assert calls.all? { |call| call[:env]["KWARD_EKWSH_CONFIG_TEST"] == "configured" }
      assert_empty conversation.messages
    end
  end

  def test_interactive_loop_opens_ekwsh_kward_edit_alias_in_current_prompt
    Dir.mktmpdir do |dir|
      file_path = File.join(File.realpath(dir), "note one.md")
      prompt = FakePrompt.new(["/shell", "alias vibe='kward edit'", "vibe 'note one.md'", "exit", "/exit"])
      opened = []
      prompt.define_singleton_method(:edit_file) do |path, base_dir:, allow_new:|
        opened << { path: path, base_dir: base_dir, allow_new: allow_new }
        true
      end
      conversation = Kward::Conversation.new(system_message: nil, workspace_root: dir)
      agent = Object.new
      agent.define_singleton_method(:conversation) { conversation }
      agent.define_singleton_method(:ask) { |_input, **_options| raise "model should not be called" }
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([]))

      cli.interactive_loop(agent: agent)

      assert_equal [{ path: file_path, base_dir: File.realpath(dir), allow_new: true }], opened
      output = strip_ansi(prompt.output.join)
      assert_includes output, "$ vibe 'note one.md'"
      refute_includes output, "Exit status:"
      assert_empty conversation.messages
    end
  end

  def test_interactive_loop_opens_bang_ekwsh_kward_edit_alias_in_current_prompt
    Dir.mktmpdir do |dir|
      config_path = File.join(dir, "config.json")
      File.write(config_path, "{}")
      File.write(File.join(dir, "ekwsh.yml"), <<~YAML)
        aliases:
          vibe: kward edit
      YAML
      file_path = File.join(File.realpath(dir), "note one.md")
      prompt = FakePrompt.new(["!vibe 'note one.md'", "/exit"])
      opened = []
      prompt.define_singleton_method(:edit_file) do |path, base_dir:, allow_new:|
        opened << { path: path, base_dir: base_dir, allow_new: allow_new }
        true
      end
      conversation = Kward::Conversation.new(system_message: nil, workspace_root: dir)
      agent = Object.new
      agent.define_singleton_method(:conversation) { conversation }
      agent.define_singleton_method(:ask) { |_input, **_options| raise "model should not be called" }
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([]))
      pty_calls = []
      cli.define_singleton_method(:run_interactive_pty_with_terminal_handoff) do |shell, command, env:, cwd:|
        pty_calls << { shell: shell, command: command, env: env, cwd: cwd }
        raise "editor alias should not start a PTY"
      end

      with_env("KWARD_CONFIG_PATH" => config_path) do
        cli.interactive_loop(agent: agent)
      end

      assert_equal [{ path: file_path, base_dir: File.realpath(dir), allow_new: true }], opened
      assert_empty pty_calls
      output = strip_ansi(prompt.output.join)
      assert_includes output, "$ vibe 'note one.md'"
      refute_includes output, "Exit status:"
      assert_empty conversation.messages
    end
  end

  def test_interactive_loop_requeues_ekwsh_tab_action
    prompt = FakePrompt.new([{ tab_action: :next }, "/exit"])
    conversation = Kward::Conversation.new(system_message: nil)
    agent = Object.new
    agent.define_singleton_method(:conversation) { conversation }
    agent.define_singleton_method(:ask) { |_input, **_options| raise "model should not be called" }
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([]))
    cli.instance_variable_set(:@pending_inputs, [])

    cli.send(:run_ekwsh, agent)

    assert_equal [{ tab_action: :next }], cli.instance_variable_get(:@pending_inputs)
    assert_empty conversation.messages
  end

  def test_ekwsh_running_command_requeues_tab_action
    started_at = Time.now
    prompt = FakePrompt.new(["capture ruby -e 'sleep 5'"])
    prompt.define_singleton_method(:begin_busy_input) { |_message, activity: "loading"| nil }
    prompt.define_singleton_method(:finish_busy_input) { nil }
    prompt.define_singleton_method(:write_transcript_delta) { |_chunk| nil }
    prompt.define_singleton_method(:poll_input) do
      Time.now - started_at > 0.1 ? { tab_action: :next } : nil
    end
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([]))
    cli.instance_variable_set(:@pending_inputs, [])
    shell = Kward::Ekwsh.new(cwd: Dir.pwd, shell: "/bin/sh", timeout_seconds: 5)

    result = Timeout.timeout(2) { cli.send(:run_ekwsh_loop, shell) }

    assert_equal :tab_action, result
    assert_equal [{ tab_action: :next }], cli.instance_variable_get(:@pending_inputs)
  end

  def test_interactive_loop_persists_ekwsh_history_separately
    Dir.mktmpdir do |dir|
      config_path = File.join(dir, "config.json")
      workspace = File.join(dir, "workspace")
      FileUtils.mkdir_p(workspace)
      input, writer = IO.pipe
      writer.write("/shell\npwd\nexit\nnormal prompt\n/exit\n")
      writer.close
      prompt_history = Kward::PromptHistory.new(config_dir: dir, cwd: workspace)
      prompt = Kward::PromptInterface.new(input: input, output: StringIO.new, prompt_history: prompt_history)
      conversation = Kward::Conversation.new(system_message: nil, workspace_root: workspace)
      agent = Object.new
      agent.define_singleton_method(:conversation) { conversation }
      agent.define_singleton_method(:ask) { |_input, **_options| "done" }
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([]))

      with_env("KWARD_CONFIG_PATH" => config_path) do
        cli.interactive_loop(agent: agent)
      end

      assert_equal ["pwd", "exit"], Kward::PromptHistory.new(config_dir: dir, cwd: workspace, kind: "shell").values
      assert_equal ["/shell", "normal prompt", "/exit"], Kward::PromptHistory.new(config_dir: dir, cwd: workspace).values
    ensure
      prompt&.close
      input&.close unless input&.closed?
    end
  end

  def test_bang_completion_provider_completes_real_prompt_input
    Dir.mktmpdir do |dir|
      input, writer = IO.pipe
      writer.write("!pw\t\r")
      writer.close
      prompt = Kward::PromptInterface.new(input: input, output: StringIO.new)
      conversation = Kward::Conversation.new(system_message: nil, workspace_root: dir)
      agent = Object.new
      agent.define_singleton_method(:conversation) { conversation }
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([]))

      with_env("PATH" => "") do
        cli.send(:install_bang_completion_provider, agent)
        assert_equal "!pwd ", prompt.ask("You>")
      ensure
        cli.send(:clear_bang_completion_provider)
      end
    ensure
      prompt&.close
      input&.close unless input&.closed?
    end
  end

  def test_bang_completion_displays_and_cycles_workspace_paths
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "examples"))
      FileUtils.mkdir_p(File.join(dir, "exe"))
      input, writer = IO.pipe
      writer.write("!cat ./ex\t\t\r")
      writer.close
      output = StringIO.new
      prompt = Kward::PromptInterface.new(input: input, output: output)
      conversation = Kward::Conversation.new(system_message: nil, workspace_root: dir)
      agent = Object.new
      agent.define_singleton_method(:conversation) { conversation }
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([]))

      with_env("PATH" => "") do
        cli.send(:install_bang_completion_provider, agent)
        assert_equal "!cat ./exe/", prompt.ask("You>")
      ensure
        cli.send(:clear_bang_completion_provider)
      end

      rendered_output = strip_ansi(output.string)
      assert_includes rendered_output, "╭ Completions"
      assert_includes rendered_output, "./examples/"
      assert_includes rendered_output, "./exe/"
      refute_includes rendered_output, "completions:"
    ensure
      prompt&.close
      input&.close unless input&.closed?
    end
  end

  def test_bang_completion_preserves_marker_and_offsets_command_range
    Dir.mktmpdir do |dir|
      conversation = Kward::Conversation.new(system_message: nil, workspace_root: dir)
      agent = Object.new
      agent.define_singleton_method(:conversation) { conversation }
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: FakePrompt.new([]), client: FakeClient.new([]))

      completion = with_env("PATH" => "") do
        cli.send(:complete_bang_command, "!pw", 3, agent)
      end

      assert_equal 1...3, completion.range
      assert_equal "pwd ", completion.replacement
      assert_includes completion.candidates, "pwd"
    end
  end

  def test_bang_completion_includes_configured_ekwsh_aliases
    Dir.mktmpdir do |dir|
      config_path = File.join(dir, "config.json")
      File.write(File.join(dir, "ekwsh.yml"), <<~YAML)
        aliases:
          greet: printf hello
      YAML
      conversation = Kward::Conversation.new(system_message: nil, workspace_root: dir)
      agent = Object.new
      agent.define_singleton_method(:conversation) { conversation }
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: FakePrompt.new([]), client: FakeClient.new([]))

      completion = with_env("KWARD_CONFIG_PATH" => config_path, "PATH" => "") do
        cli.send(:complete_bang_command, "!gre", 4, agent)
      end

      assert_equal 1...4, completion.range
      assert_equal "greet ", completion.replacement
      assert_includes completion.candidates, "greet"
    end
  end

  def test_bang_completion_resolves_paths_from_workspace_root_without_aliases
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "lib"))
      File.write(File.join(dir, "lib", "known.rb"), "")
      conversation = Kward::Conversation.new(system_message: nil, workspace_root: dir)
      agent = Object.new
      agent.define_singleton_method(:conversation) { conversation }
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: FakePrompt.new([]), client: FakeClient.new([]))

      completion = cli.send(:complete_bang_command, "!cat lib/kno", 12, agent)

      assert_equal 5...12, completion.range
      assert_equal "lib/known.rb ", completion.replacement
    end
  end

  def test_bang_completion_declines_input_without_leading_marker
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: FakePrompt.new([]), client: FakeClient.new([]))

    assert_equal false, cli.send(:complete_bang_command, "pw", 2, Object.new)
  end

  def test_redraw_interactive_prompt_restores_durable_conversation_transcript
    output = StringIO.new
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: output)
    conversation = Kward::Conversation.new(system_message: nil)
    conversation.append_user("durable input")
    prompt.say("transient bang output")
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([]))
    cli.instance_variable_set(:@footer_conversation, conversation)

    cli.send(:redraw_interactive_prompt)

    transcript = prompt.instance_variable_get(:@transcript_buffer).to_s
    assert_includes transcript, "durable input"
    refute_includes transcript, "transient bang output"
  ensure
    prompt&.close
  end

  def test_interactive_loop_runs_bang_shell_command_in_pty_without_model_turn
    Dir.mktmpdir do |dir|
      prompt = FakePrompt.new(["!echo hello", "/exit"])
      conversation = Kward::Conversation.new(system_message: nil, workspace_root: dir)
      agent = Object.new
      agent.define_singleton_method(:conversation) { conversation }
      agent.define_singleton_method(:ask) { |_input, **_options| raise "model should not be called" }
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([]))

      cli.interactive_loop(agent: agent)

      output = strip_ansi(prompt.output.join)
      assert_includes output, "$ echo hello"
      refute_includes output, "interactive PTY session"
      assert_empty conversation.messages
    end
  end

  def test_interactive_loop_writes_bang_command_echo_without_repainting_composer
    Dir.mktmpdir do |dir|
      prompt = FakePrompt.new(["!ls", "/exit"])
      transcripts = []
      prompt.define_singleton_method(:write_transcript) { |message| transcripts << message }
      conversation = Kward::Conversation.new(system_message: nil, workspace_root: dir)
      agent = Object.new
      agent.define_singleton_method(:conversation) { conversation }
      agent.define_singleton_method(:ask) { |_input, **_options| raise "model should not be called" }
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([]))
      cli.define_singleton_method(:run_interactive_pty_with_terminal_handoff) do |_shell, _command, env:, cwd:, **_options|
        Kward::InteractivePtyRunner::Result.new(exit_status: 0, input_forwarded: false)
      end

      cli.interactive_loop(agent: agent)

      assert_equal ["$ ls\n"], transcripts
      assert_empty prompt.output
    end
  end

  def test_interactive_loop_uses_full_terminal_handoff_for_line_oriented_git_commands
    Dir.mktmpdir do |dir|
      prompt = FakePrompt.new(["!git push", "/exit"])
      handoff_options = []
      conversation = Kward::Conversation.new(system_message: nil, workspace_root: dir)
      agent = Object.new
      agent.define_singleton_method(:conversation) { conversation }
      agent.define_singleton_method(:ask) { |_input, **_options| raise "model should not be called" }
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([]))
      cli.define_singleton_method(:run_interactive_pty_with_terminal_handoff) do |_shell, _command, env:, cwd:, **options|
        handoff_options << options
        Kward::InteractivePtyRunner::Result.new(exit_status: 0, input_forwarded: false)
      end

      cli.interactive_loop(agent: agent)

      assert_equal [{}], handoff_options
      assert_equal 1, prompt.refresh_composer_status_count
      assert_empty conversation.messages
    end
  end

  def test_interactive_pty_uses_adaptive_inline_handoff_when_available
    input, input_writer = IO.pipe
    output = StringIO.new
    transitions = 0
    prompt = FakePrompt.new([])
    prompt.define_singleton_method(:with_inline_terminal_handoff) do |&block|
      block.call(input, output, -> { transitions += 1 })
    end
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([]))
    completed_sink = nil

    result = cli.send(
      :run_interactive_pty_with_terminal_handoff,
      "/bin/sh",
      "printf inline-output",
      env: {},
      cwd: Dir.pwd
    ) do |sink, _completed_result|
      completed_sink = sink
    end

    assert_equal 0, result.exit_status
    assert_instance_of Kward::AdaptivePtyOutputSink, completed_sink
    assert_equal "inline-output", output.string
    assert_equal 0, transitions
  ensure
    input_writer&.close unless input_writer&.closed?
    input&.close unless input&.closed?
  end

  def test_interactive_loop_records_line_oriented_bang_output
    Dir.mktmpdir do |dir|
      prompt = FakePrompt.new(["!ls", "/exit"])
      recorded_output = []
      prompt.define_singleton_method(:record_transient_terminal_output) do |text, render: true|
        recorded_output << [text, render]
      end
      conversation = Kward::Conversation.new(system_message: nil, workspace_root: dir)
      agent = Object.new
      agent.define_singleton_method(:conversation) { conversation }
      agent.define_singleton_method(:ask) { |_input, **_options| raise "model should not be called" }
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([]))
      cli.define_singleton_method(:run_interactive_pty_with_terminal_handoff) do |_shell, _command, env:, cwd:, &on_sink|
        sink = Kward::PassthroughPtyOutputSink.new(output: StringIO.new, max_capture_bytes: 1_048_576)
        sink.write("\e[36mGemfile\e[0m\r\nREADME.md\r\n")
        result = Kward::InteractivePtyRunner::Result.new(exit_status: 0, input_forwarded: false)
        on_sink.call(sink, result)
        result
      end

      cli.interactive_loop(agent: agent)

      assert_equal [["\e[36mGemfile\e[0m\nREADME.md\n", false]], recorded_output
      assert_empty conversation.messages
    end
  end

  def test_interactive_loop_does_not_record_full_screen_bang_output
    Dir.mktmpdir do |dir|
      prompt = FakePrompt.new(["!less README.md", "/exit"])
      recorded_output = []
      prompt.define_singleton_method(:record_transient_terminal_output) do |text, render: true|
        recorded_output << [text, render]
      end
      conversation = Kward::Conversation.new(system_message: nil, workspace_root: dir)
      agent = Object.new
      agent.define_singleton_method(:conversation) { conversation }
      agent.define_singleton_method(:ask) { |_input, **_options| raise "model should not be called" }
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([]))
      cli.define_singleton_method(:run_interactive_pty_with_terminal_handoff) do |_shell, _command, env:, cwd:, &on_sink|
        sink = Kward::PassthroughPtyOutputSink.new(output: StringIO.new, max_capture_bytes: 1_048_576)
        sink.write("\e[?1049hfull screen\e[?1049l")
        result = Kward::InteractivePtyRunner::Result.new(exit_status: 0, input_forwarded: true)
        on_sink.call(sink, result)
        result
      end

      cli.interactive_loop(agent: agent)

      assert_empty recorded_output
      assert_empty conversation.messages
    end
  end

  def test_interactive_loop_does_not_record_cursor_oriented_bang_output
    Dir.mktmpdir do |dir|
      prompt = FakePrompt.new(["!printf cursor", "/exit"])
      recorded_output = []
      prompt.define_singleton_method(:record_transient_terminal_output) do |text, render: true|
        recorded_output << [text, render]
      end
      conversation = Kward::Conversation.new(system_message: nil, workspace_root: dir)
      agent = Object.new
      agent.define_singleton_method(:conversation) { conversation }
      agent.define_singleton_method(:ask) { |_input, **_options| raise "model should not be called" }
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([]))
      cursor_output = "\e[1;1Hcursor output\r\n"
      forwarded_output = +""
      cli.define_singleton_method(:run_interactive_pty_with_terminal_handoff) do |_shell, _command, env:, cwd:, &on_sink|
        forwarded_output << cursor_output
        sink = Kward::PassthroughPtyOutputSink.new(output: StringIO.new, max_capture_bytes: 1_048_576)
        sink.write(cursor_output)
        result = Kward::InteractivePtyRunner::Result.new(exit_status: 0, input_forwarded: false)
        on_sink.call(sink, result)
        result
      end

      cli.interactive_loop(agent: agent)

      assert_equal cursor_output, forwarded_output
      assert_empty recorded_output
      assert_empty conversation.messages
    end
  end

  def test_completed_inline_pty_output_retains_only_bytes_before_forwarded_input
    recorded_output = []
    prompt = FakePrompt.new([])
    prompt.define_singleton_method(:record_transient_terminal_output) do |text, render: true|
      recorded_output << [text, render]
    end
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([]))
    sink = Kward::AdaptivePtyOutputSink.new(
      output: StringIO.new,
      on_exclusive: -> {},
      max_capture_bytes: 1_048_576
    )
    sink.write("Preparing push\r\nEnter OTP: \r\n")
    sink.input_forwarded
    sink.write("123456\r\nPushed successfully\r\n")
    result = Kward::InteractivePtyRunner::Result.new(exit_status: 0, input_forwarded: true)

    cli.send(:record_completed_pty_output, sink, result)

    assert_equal [["Preparing push\nEnter OTP: \n", false]], recorded_output
  end

  def test_completed_inline_pty_output_collapses_carriage_return_progress
    recorded_output = []
    prompt = FakePrompt.new([])
    prompt.define_singleton_method(:record_transient_terminal_output) do |text, render: true|
      recorded_output << [text, render]
    end
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([]))
    sink = Kward::AdaptivePtyOutputSink.new(
      output: StringIO.new,
      on_exclusive: -> {},
      max_capture_bytes: 1_048_576
    )
    sink.write("Enumerating objects: 3, done.\r\n")
    sink.write("\e[?2026hWriting objects: 33%\e[K\e[0GWriting objects: 100%\e[K\r\n\e[?2026l")
    sink.write("Done\r\n")
    sink.finish
    result = Kward::InteractivePtyRunner::Result.new(exit_status: 0, input_forwarded: false)

    cli.send(:record_completed_pty_output, sink, result)

    assert_equal [["Enumerating objects: 3, done.\nWriting objects: 100%\nDone\n", false]], recorded_output
  end

  def test_terminal_transcript_output_rejects_truncated_output
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: FakePrompt.new([]), client: FakeClient.new([]))
    result = Kward::InteractivePtyRunner::Result.new(exit_status: 0, input_forwarded: false)

    assert_nil cli.send(:terminal_transcript_output, "safe output\n", result, truncated: true)
  end

  def test_interactive_loop_expands_legacy_pty_alias_for_bang_command
    Dir.mktmpdir do |dir|
      config_path = File.join(dir, "config.json")
      File.write(File.join(dir, "ekwsh.yml"), <<~YAML)
        aliases:
          glog: pty git log --decorate
      YAML
      prompt = FakePrompt.new(["!glog --stat", "/exit"])
      conversation = Kward::Conversation.new(system_message: nil, workspace_root: dir)
      agent = Object.new
      agent.define_singleton_method(:conversation) { conversation }
      agent.define_singleton_method(:ask) { |_input, **_options| raise "model should not be called" }
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([]))
      calls = []
      cli.define_singleton_method(:run_interactive_pty_with_terminal_handoff) do |shell, command, env:, cwd:|
        calls << { shell: shell, command: command, env: env, cwd: cwd }
        Kward::InteractivePtyRunner::Result.new(exit_status: 141)
      end

      with_env("KWARD_CONFIG_PATH" => config_path) do
        cli.interactive_loop(agent: agent)
      end

      output = strip_ansi(prompt.output.join)
      assert_equal ["git log --decorate --stat"], calls.map { |call| call[:command] }
      assert_includes output, "$ glog --stat"
      refute_includes output, "interactive PTY session"
      refute_includes output, "141"
      assert_empty conversation.messages
    end
  end

  def test_interactive_loop_runs_bang_shell_command_from_workspace_root
    Dir.mktmpdir do |dir|
      prompt = FakePrompt.new(["!pwd", "/exit"])
      conversation = Kward::Conversation.new(system_message: nil, workspace_root: dir)
      agent = Object.new
      agent.define_singleton_method(:conversation) { conversation }
      agent.define_singleton_method(:ask) { |_input, **_options| raise "model should not be called" }
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([]))
      calls = []
      cli.define_singleton_method(:run_interactive_pty_with_terminal_handoff) do |shell, command, env:, cwd:|
        calls << { shell: shell, command: command, env: env, cwd: cwd }
        Kward::InteractivePtyRunner::Result.new(exit_status: 0)
      end

      with_env("GIT_PAGER" => "cat") do
        cli.interactive_loop(agent: agent)
      end

      assert_equal 1, calls.length
      assert_equal "/bin/sh", calls.first[:shell]
      assert_equal "pwd", calls.first[:command]
      assert_equal File.realpath(dir), calls.first[:cwd]
      assert_equal "cat", calls.first[:env]["GIT_PAGER"]
      assert_equal "xterm-256color", calls.first[:env]["TERM"] if ENV["TERM"].to_s.empty? || ENV["TERM"] == "dumb"
    end
  end

  def test_interactive_loop_runs_captured_shell_command_without_model_turn
    Dir.mktmpdir do |dir|
      prompt = FakePrompt.new(["/capture echo hello", "/exit"])
      conversation = Kward::Conversation.new(system_message: nil, workspace_root: dir)
      agent = Object.new
      agent.define_singleton_method(:conversation) { conversation }
      agent.define_singleton_method(:ask) { |_input, **_options| raise "model should not be called" }
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([]))

      cli.interactive_loop(agent: agent)

      output = strip_ansi(prompt.output.join)
      assert_includes output, "Shell> echo hello"
      assert_includes output, "Exit status: 0"
      assert_includes output, "STDOUT:\nhello"
      assert_empty conversation.messages
    end
  end

  def test_interactive_loop_runs_captured_shell_command_from_workspace_root
    Dir.mktmpdir do |dir|
      prompt = FakePrompt.new(["/capture pwd", "/exit"])
      conversation = Kward::Conversation.new(system_message: nil, workspace_root: dir)
      agent = Object.new
      agent.define_singleton_method(:conversation) { conversation }
      agent.define_singleton_method(:ask) { |_input, **_options| raise "model should not be called" }
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([]))

      cli.interactive_loop(agent: agent)

      assert_includes strip_ansi(prompt.output.join), "STDOUT:\n#{File.realpath(dir)}"
    end
  end

  def test_captured_user_command_is_not_subject_to_model_command_sandbox
    Dir.mktmpdir do |dir|
      config_path = File.join(dir, "config.json")
      output_path = File.join(dir, "captured-user-command")
      File.write(config_path, JSON.dump("sandbox" => { "mode" => "read_only" }))
      prompt = FakePrompt.new(["/capture touch #{Shellwords.escape(output_path)}", "/exit"])
      conversation = Kward::Conversation.new(system_message: nil, workspace_root: dir)
      agent = Object.new
      agent.define_singleton_method(:conversation) { conversation }
      agent.define_singleton_method(:ask) { |_input, **_options| raise "model should not be called" }
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([]))

      with_env("KWARD_CONFIG_PATH" => config_path) do
        cli.interactive_loop(agent: agent)
      end

      assert_path_exists output_path
    end
  end

  def test_interactive_loop_reports_empty_capture_command
    prompt = FakePrompt.new(["/capture", "/exit"])
    conversation = Kward::Conversation.new(system_message: nil)
    agent = Object.new
    agent.define_singleton_method(:conversation) { conversation }
    agent.define_singleton_method(:ask) { |_input, **_options| raise "model should not be called" }
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([]))

    cli.interactive_loop(agent: agent)

    assert_includes prompt.output.join, "Usage: /capture <command>"
    assert_empty conversation.messages
  end

  def test_interactive_loop_reports_empty_bang_shell_command
    prompt = FakePrompt.new(["!", "/exit"])
    conversation = Kward::Conversation.new(system_message: nil)
    agent = Object.new
    agent.define_singleton_method(:conversation) { conversation }
    agent.define_singleton_method(:ask) { |_input, **_options| raise "model should not be called" }
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([]))

    cli.interactive_loop(agent: agent)

    assert_includes prompt.output.join, "Shell command is required after !"
    assert_empty conversation.messages
  end

  def test_interactive_loop_reports_turn_error_without_crashing
    prompt = BusyPrompt.new(["hello", "/exit"])
    conversation = Kward::Conversation.new(system_message: nil)
    agent = Object.new
    agent.define_singleton_method(:conversation) { conversation }
    agent.define_singleton_method(:ask) do |_input, **_options|
      raise Kward::Client::RequestError.new(provider: "Copilot", code: 400, body: JSON.dump("error" => { "code" => "model_not_supported" }))
    end
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([]))

    cli.interactive_loop(agent: agent)

    assert_includes prompt.output.join, "Error: Copilot request failed: 400"
    assert_includes prompt.events, [:finish_busy_input]
  end

  def test_prompt_interface_interactive_turn_returns_after_question_answer_without_extra_input
    input, writer = IO.pipe
    output = StringIO.new
    prompt = Kward::PromptInterface.new(input: input, output: output)
    client = FakeClient.new([
      assistant_tool_call("ask_user_question", { questions: [question_args("Proceed?")] }),
      { "role" => "assistant", "content" => "done" }
    ])
    registry = Kward::ToolRegistry.new(prompt: prompt, skills: [])
    agent = Kward::Agent.new(client: client, tool_registry: registry, conversation: Kward::Conversation.new)
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client)
    queued_inputs = nil

    thread = Thread.new { queued_inputs = cli.send(:run_interactive_turn, agent, "/plan fix", display_input: "/plan fix") }
    wait_until { prompt.instance_variable_get(:@question_state) }
    writer.write("\r")
    thread.join(1)

    refute thread.alive?, "turn should finish after the question answer without requiring another keypress"
    assert_equal [], queued_inputs
  ensure
    thread&.kill if thread&.alive?
    writer&.close unless writer&.closed?
    input&.close unless input&.closed?
  end

  def test_prompt_interface_uses_combined_stream_writes_when_available
    prompt = CombinedStreamPrompt.new([])
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([]))

    cli.send(:print_block_delta, "Assistant", "hello")

    assert_equal [{ label: "Assistant", delta: "hello", finish: false }], prompt.stream_writes
    assert_empty prompt.events
  end

  def test_prompt_interface_interactive_turn_enters_busy_state_before_printing_user_transcript
    prompt = BusyPrompt.new([])
    prompt.define_singleton_method(:say) do |message|
      @events << [:say, message]
      @output << message
    end
    agent = EventAgent.new([])
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([]))

    cli.send(:run_interactive_turn, agent, "hello")

    begin_index = prompt.events.index([:begin_busy_input, "You>", "streaming"])
    say_index = prompt.events.index { |event| event.first == :say }
    assert_operator begin_index, :<, say_index
  end

  def test_prompt_interface_interactive_turn_batches_streamed_deltas
    prompt = BusyPrompt.new([])
    events = 10.times.map { |index| Kward::Events::AssistantDelta.new(delta: index.to_s) }
    agent = EventAgent.new(events)
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([]))

    cli.send(:run_interactive_turn, agent, "hello")

    assert_equal ["0123456789"], prompt.write_deltas
    assert_operator prompt.write_deltas.length, :<, events.length
  end

  def test_prompt_interface_interactive_turn_renders_streamed_inline_bold
    prompt = BusyPrompt.new([])
    events = [Kward::Events::ReasoningDelta.new(delta: "**Exploring key handling** -> Better Markdown")]
    agent = EventAgent.new(events)
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([]))
    cli.instance_variable_set(:@color_enabled, true)

    cli.send(:run_interactive_turn, agent, "hello")

    assert_equal ["\e[1mExploring key handling\e[0m -> Better Markdown"], prompt.write_deltas
  end

  def test_prompt_interface_interactive_turn_cancels_on_busy_ctrl_c
    prompt = BusyPrompt.new([Kward::PromptInterface::CANCEL_INPUT])
    prompt.define_singleton_method(:poll_input) { @inputs.shift }
    assert_interactive_turn_cancels(prompt)
  end

  def test_prompt_interface_interactive_turn_cancels_on_interrupt_signal
    poll_count = 0
    prompt = BusyPrompt.new([])
    prompt.define_singleton_method(:poll_input) do
      poll_count += 1
      raise Interrupt if poll_count > 1
    end
    assert_interactive_turn_cancels(prompt)
  end

  def assert_interactive_turn_cancels(prompt)
    cancellation_seen = Queue.new
    agent = Object.new
    agent.define_singleton_method(:ask) do |_input, cancellation: nil, &block|
      block.call(Kward::Events::AssistantDelta.new(delta: "partial"))
      cancellation_seen << cancellation
      sleep 10
    end
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([]))

    queued = cli.send(:run_interactive_turn, agent, "hello")

    assert_empty queued
    assert cancellation_seen.pop.cancelled?
    assert_equal ["partial"], prompt.write_deltas
    assert_includes prompt.events, [:finish_busy_input]
    refute_includes prompt.output.join, "Error: cancelled"
  end

  def test_prompt_interface_interactive_turn_flushes_pending_delta_on_completion
    prompt = BusyPrompt.new([])
    agent = EventAgent.new([Kward::Events::AssistantDelta.new(delta: "final")])
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([]))

    cli.send(:run_interactive_turn, agent, "hello")

    assert_equal ["final"], prompt.write_deltas
  end

  def test_prompt_interface_interactive_turn_renders_late_reasoning_before_assistant
    prompt = BusyPrompt.new([])
    conversation = Kward::Conversation.new(system_message: nil, model: "gpt-5")
    agent = Object.new
    agent.define_singleton_method(:conversation) { conversation }
    agent.define_singleton_method(:ask) do |_input, **_options, &block|
      block.call(Kward::Events::AssistantDelta.new(delta: "answer"))
      sleep Kward::CLI::STREAM_RENDER_INTERVAL + 0.01
      block.call(Kward::Events::ReasoningDelta.new(delta: "thinking"))
      "answer"
    end
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([]))

    cli.send(:run_interactive_turn, agent, "hello")

    assert_order(prompt.events, [:start_stream_block, "Reasoning"], [:start_stream_block, "Assistant"])
    assert_equal ["thinking", "answer"], prompt.write_deltas
  end

  def test_prompt_interface_interactive_turn_keeps_late_reasoning_before_already_flushable_assistant
    prompt = BusyPrompt.new([])
    conversation = Kward::Conversation.new(system_message: nil, model: "gpt-5")
    agent = Object.new
    agent.define_singleton_method(:conversation) { conversation }
    agent.define_singleton_method(:ask) do |_input, **_options, &block|
      block.call(Kward::Events::ReasoningDelta.new(delta: "early\n"))
      block.call(Kward::Events::AssistantDelta.new(delta: "```text\npartial\n"))
      deadline = Time.now + 1
      sleep 0.005 until prompt.write_deltas.include?("early\n") || Time.now > deadline
      raise "timed out waiting for early reasoning flush" unless prompt.write_deltas.include?("early\n")

      block.call(Kward::Events::ReasoningDelta.new(delta: "late\n"))
      "answer"
    end
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([]))

    cli.send(:run_interactive_turn, agent, "hello")

    assert_order(prompt.events, [:write_delta, "early\n"], [:write_delta, "late\n"], [:start_stream_block, "Assistant"])
    assert_includes prompt.write_deltas.last, "┌─ code text"
    assert_includes prompt.write_deltas.last, "└"
  end

  def test_prompt_interface_interactive_turn_streams_assistant_without_reasoning_on_non_reasoning_model
    prompt = BusyPrompt.new([])
    conversation = Kward::Conversation.new(system_message: nil, model: "gpt-4.1")
    agent = Object.new
    agent.define_singleton_method(:conversation) { conversation }
    agent.define_singleton_method(:ask) do |_input, **_options, &block|
      block.call(Kward::Events::AssistantDelta.new(delta: "answer"))
      sleep Kward::CLI::STREAM_RENDER_INTERVAL + 0.01
      "answer"
    end
    client = FakeClient.new([])
    client.provider = "Copilot"
    client.model = "gpt-4.1"
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client)

    cli.send(:run_interactive_turn, agent, "hello")

    assert_equal ["answer"], prompt.write_deltas
  end

  def test_prompt_interface_interactive_turn_notifies_plugin_transcript_events
    prompt = BusyPrompt.new([])
    conversation = Kward::Conversation.new(system_message: nil)
    conversation.append_user("hello")
    agent = EventAgent.new([Kward::Events::AssistantDelta.new(delta: "live")])
    agent.define_singleton_method(:conversation) { conversation }
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([]))
    registry = Kward::PluginRegistry.new
    received = []
    registry.evaluate do |plugin|
      plugin.on_transcript_event do |event, ctx|
        received << [event.type, event.payload[:delta], ctx.transcript.messages.length]
      end
    end
    cli.instance_variable_set(:@plugin_registry, registry)

    cli.send(:run_interactive_turn, agent, "hello")

    assert_equal [["assistant_delta", "live", 1]], received
    assert_equal ["live"], prompt.write_deltas
  end

  def test_prompt_interface_interactive_turn_renders_reasoning_boundaries_as_separate_blocks
    prompt = BusyPrompt.new([])
    events = [
      Kward::Events::ReasoningDelta.new(delta: "First step\n\n"),
      Kward::Events::ReasoningBoundary.new,
      Kward::Events::ReasoningDelta.new(delta: "Second step"),
      Kward::Events::ReasoningBoundary.new
    ]
    agent = EventAgent.new(events)
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([]))

    cli.send(:run_interactive_turn, agent, "hello")

    assert_equal 2, prompt.events.count { |event| event == [:start_stream_block, "Reasoning"] }
    assert_equal ["First step\n\n", "Second step"], prompt.write_deltas
  end

  def test_prompt_interface_interactive_turn_keeps_stream_block_open_between_throttled_flushes
    prompt = BusyPrompt.new([])
    flushed = Queue.new
    prompt.define_singleton_method(:write_delta) do |delta|
      super(delta)
      flushed << true
    end
    events = ["I am Commander K’", "warD, sir —", " your officer"].map do |chunk|
      Kward::Events::AssistantDelta.new(delta: chunk)
    end
    agent = Object.new
    agent.define_singleton_method(:ask) do |_input, **_options, &block|
      events.each do |event|
        block.call(event)
        flushed.pop
      end
      ""
    end
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([]))
    clock = 0.0
    cli.define_singleton_method(:monotonic_now) { clock += Kward::CLI::STREAM_RENDER_INTERVAL }

    cli.send(:run_interactive_turn, agent, "hello")

    assert_equal 1, prompt.events.count { |event| event == [:start_stream_block, "Assistant"] }
    assert_equal ["I am Commander K’", "warD, sir —", " your officer"], prompt.write_deltas
    assert_equal 1, prompt.events.count { |event| event == [:finish_stream_block] }
  end

  def test_prompt_interface_interactive_turn_flushes_deltas_before_tool_events
    prompt = BusyPrompt.new([])
    readme_tool_call = tool_call("read_file", path: "README.md")
    events = [
      Kward::Events::AssistantDelta.new(delta: "before tool"),
      Kward::Events::ToolCall.new(tool_call: readme_tool_call),
      Kward::Events::ToolResult.new(tool_call: readme_tool_call, content: "README contents\n")
    ]
    agent = EventAgent.new(events)
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([]))

    cli.send(:run_interactive_turn, agent, "hello")

    assert_order(prompt.events, [:start_stream_block, "Assistant"], [:write_delta, "before tool"], [:finish_stream_block], [:start_stream_block, "Tool"])
  end

  def test_prompt_interface_interactive_turn_keeps_markdown_fence_state_across_flushes
    prompt = BusyPrompt.new([])
    chunks = [
      "```ruby\nKward::",
      "Resources::AvatarKwardLogo::PIXELS\n```\n\ninstead of the missing PNG fixture:\n\n```ruby\nlib/kward/resources/avatar_k",
      "ward_48x48.png\n```\n"
    ]
    agent = Object.new
    agent.define_singleton_method(:ask) do |_input, **_options, &block|
      chunks.each do |chunk|
        block.call(Kward::Events::AssistantDelta.new(delta: chunk))
        sleep Kward::CLI::STREAM_RENDER_INTERVAL + 0.01
      end
      chunks.join
    end
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([]))

    cli.send(:run_interactive_turn, agent, "hello")

    output = strip_ansi(prompt.write_deltas.join)
    assert_includes output, "│ Kward::Resources::AvatarKwardLogo::PIXELS\n└"
    assert_includes output, "│ lib/kward/resources/avatar_kward_48x48.png\n└"
    refute_includes output, "└───────────────────────────────────────Resources"
    refute_includes output, "\nlib/kward/resources/avatar_kward_48x48.png\n┌─ code"
  end

  def test_transcript_block_renders_markdown_when_colored
    prompt = FakePrompt.new([])
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([]))
    cli.instance_variable_set(:@color_enabled, true)

    cli.send(:render_transcript_block, "Assistant", "## Plan\nRun `bundle test`.\n")

    output = prompt.output.join("\n")
    assert_includes output, "## \e[1mPlan\e[0m"
    assert_includes output, "`\e[2mbundle test\e[0m`"
  end

  def test_cli_colors_stream_labels_when_forced
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), client: FakeClient.new([]))
    cli.instance_variable_set(:@color_enabled, true)

    assistant_output = capture_io { cli.send(:start_stream_block, "Assistant") }.first
    reasoning_output = capture_io { cli.send(:start_stream_block, "Reasoning") }.first
    retry_output = capture_io { cli.send(:start_stream_block, "Retry") }.first
    tool_output = capture_io { cli.send(:print_tool_result, tool_call("read_file", path: "README.md"), "content") }.first
    failed_tool_output = capture_io { cli.send(:print_tool_result, tool_call("read_file", path: "README.md"), "Error: missing") }.first

    runtime_prompt = FakePrompt.new([])
    runtime_cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: runtime_prompt, client: FakeClient.new([]))
    runtime_cli.instance_variable_set(:@color_enabled, true)
    runtime_cli.send(:runtime_output, "Saved.")

    assert_includes assistant_output, "\e[32;1mAssistant>\e[0m"
    assert_includes reasoning_output, "\e[90;1mReasoning>\e[0m"
    assert_includes retry_output, "\e[33;1mRetry>\e[0m"
    assert_includes tool_output, "\e[36;1mTool>\e[0m"
    assert_includes failed_tool_output, "\e[31;1mTool>\e[0m"
    assert_includes runtime_prompt.output.join, "\e[90;1mRuntime>\e[0m"
  end

  def test_interactive_conversation_history_still_works
    prompt = FakePrompt.new(["hello", "again", "/exit"])
    client = RecordingClient.new(["reply 1", "reply 2"])
    agent = Kward::Agent.new(client: client, tool_registry: Kward::ToolRegistry.new(prompt: prompt))
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client)

    conversation = cli.interactive_loop(agent: agent)

    assert_equal "hello", client.seen_messages[0][1][:content]
    assert_equal "reply 1", client.seen_messages[1][2]["content"]
    assert_equal "again", client.seen_messages[1][3][:content]
    assert_equal 4, conversation.messages.length
    assert_equal 5, conversation.context_messages.length
  end

  def test_copy_defaults_to_last_assistant_response
    prompt = FakePrompt.new(["hello", "/copy", "/exit"])
    client = RecordingClient.new(["reply"])
    agent = Kward::Agent.new(client: client, tool_registry: Kward::ToolRegistry.new(prompt: prompt))
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client)
    copied = []
    with_clipboard_stub(lambda { |text| copied << text; Kward::Clipboard::Result.new(success?: true, method: "test", message: "copied") }) do
      cli.interactive_loop(agent: agent)
    end

    assert_equal ["reply"], copied
    assert_includes prompt.output.join("\n"), "Copied last assistant response."
  end

  def test_copy_transcript_copies_markdown_transcript
    prompt = FakePrompt.new(["hello", "/copy transcript", "/exit"])
    client = RecordingClient.new(["reply"])
    agent = Kward::Agent.new(client: client, tool_registry: Kward::ToolRegistry.new(prompt: prompt))
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client)
    copied = []
    with_clipboard_stub(lambda { |text| copied << text; Kward::Clipboard::Result.new(success?: true, method: "test", message: "copied") }) do
      cli.interactive_loop(agent: agent)
    end

    assert_equal 1, copied.length
    assert_includes copied.first, "# Kward Session"
    assert_includes copied.first, "## User\n\nhello"
    assert_includes copied.first, "## Assistant\n\nreply"
  end

  def test_copy_rejects_composer_target
    prompt = FakePrompt.new(["/copy composer", "/exit"])
    client = RecordingClient.new([])
    agent = Kward::Agent.new(client: client, tool_registry: Kward::ToolRegistry.new(prompt: prompt))
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client)
    copied = []
    with_clipboard_stub(lambda { |text| copied << text; Kward::Clipboard::Result.new(success?: true, method: "test", message: "copied") }) do
      cli.interactive_loop(agent: agent)
    end

    assert_empty copied
    assert_includes prompt.output.join("\n"), "Usage: /copy [last|transcript]"
  end

  def test_copy_reports_clipboard_failure
    prompt = FakePrompt.new(["hello", "/copy", "/exit"])
    client = RecordingClient.new(["reply"])
    agent = Kward::Agent.new(client: client, tool_registry: Kward::ToolRegistry.new(prompt: prompt))
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client)
    with_clipboard_stub(lambda { |_text| Kward::Clipboard::Result.new(success?: false, message: "no supported clipboard mechanism found") }) do
      cli.interactive_loop(agent: agent)
    end

    assert_includes prompt.output.join("\n"), "Copy failed: no supported clipboard mechanism found."
  end

  def test_interactive_mode_persists_session_jsonl
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      prompt = FakePrompt.new(["hello", "/exit"])
      client = RecordingClient.new(["reply"])
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client, session_store: store)

      cli.interactive_loop

      files = Dir.glob(File.join(store.session_dir, "*.jsonl"))
      assert_equal 1, files.length
      records = jsonl_records(files.first)
      assert_equal "session", records[0]["type"]
      messages = records.select { |record| record["type"] == "message" }.map { |record| record["message"] }
      assert_equal "hello", messages[0]["content"]
      assert_equal "reply", messages[1]["content"]
    end
  end

  def test_interactive_startup_omits_title_session_and_help_text
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      prompt = FakePrompt.new(["/exit"])
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: RecordingClient.new([]), session_store: store)

      cli.interactive_loop

      output = prompt.output.join("\n")
      refute_includes output, "Ruby CLI Agent"
      refute_includes output, "Session:"
      refute_includes output, "Ask a question and press Enter"
    end
  end

  def test_project_skill_trust_is_resolved_before_building_the_conversation
    Dir.mktmpdir do |dir|
      config_dir = File.join(dir, "config")
      workspace = File.join(dir, "workspace")
      skill_path = File.join(workspace, ".agents", "skills", "project-agent", "SKILL.md")
      FileUtils.mkdir_p(File.dirname(skill_path))
      FileUtils.mkdir_p(config_dir)
      File.write(File.join(config_dir, "config.json"), JSON.dump({}))
      File.write(skill_path, "---\nname: project-agent\ndescription: Project workspace skill.\n---\n")
      prompt = FakeSettingsPrompt.new([], ["Allow"])
      slash_command_updates = []
      prompt.define_singleton_method(:update_slash_commands) { |commands| slash_command_updates << commands }
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt)
      cli.define_singleton_method(:prompt_interface?) { true }
      cli.define_singleton_method(:current_workspace_root) { workspace }

      with_env("KWARD_CONFIG_PATH" => File.join(config_dir, "config.json")) do
        cli.send(:prepare_interactive_project_skills)
        conversation = cli.send(:new_conversation, workspace_root: workspace)

        assert_empty slash_command_updates
        assert_equal [skill_path], cli.instance_variable_get(:@interactive_project_skill_paths)
        assert_includes conversation.system_message[:content], "project-agent: Project workspace skill."
        assert_equal "allow", Kward::Skills::TrustStore.new(config_dir: config_dir).decision(
          workspace_root: workspace,
          skill_path: skill_path,
          digest: Kward::Skills::TrustStore.digest_files([skill_path], root: workspace)
        )
      end
    end
  end

  def test_project_skill_trust_rechecks_new_skills
    Dir.mktmpdir do |dir|
      config_dir = File.join(dir, "config")
      workspace = File.join(dir, "workspace")
      FileUtils.mkdir_p(config_dir)
      File.write(File.join(config_dir, "config.json"), JSON.dump({}))
      first_path = create_project_skill(workspace, "first")
      prompt = FakeSettingsPrompt.new([], ["Allow", "Allow"])
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt)
      cli.define_singleton_method(:prompt_interface?) { true }
      cli.define_singleton_method(:current_workspace_root) { workspace }

      with_env("KWARD_CONFIG_PATH" => File.join(config_dir, "config.json")) do
        cli.send(:prepare_interactive_project_skills)
        second_path = create_project_skill(workspace, "second")
        cli.send(:prepare_interactive_project_skills)

        assert_equal [first_path, second_path], cli.instance_variable_get(:@interactive_project_skill_paths).sort
        assert_equal 2, prompt.select_choices.length
      end
    end
  end

  def test_project_skill_commands_report_and_manage_workspace_trust
    Dir.mktmpdir do |dir|
      config_dir = File.join(dir, "config")
      workspace = File.join(dir, "workspace")
      FileUtils.mkdir_p(config_dir)
      File.write(File.join(config_dir, "config.json"), JSON.dump({}))
      skill_path = create_project_skill(workspace, "project-agent")
      prompt = FakePrompt.new([])
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt)
      cli.define_singleton_method(:current_workspace_root) { workspace }

      with_env("KWARD_CONFIG_PATH" => File.join(config_dir, "config.json")) do
        cli.send(:handle_project_skills_command, "status")
        assert_includes prompt.output.join, "needs review"

        cli.send(:handle_project_skills_command, "trust")
        assert_includes prompt.output.join, "trusted"
        assert_equal [skill_path], cli.instance_variable_get(:@interactive_project_skill_paths)

        cli.send(:handle_project_skills_command, "untrust")
        assert_includes prompt.output.join, "trust removed"
        assert_empty cli.instance_variable_get(:@interactive_project_skill_paths)

        cli.send(:handle_project_skills_cli_command, ["status"])
        assert_includes prompt.output.join, "needs review"
      end
    end
  end

  def test_project_skill_review_shows_bounded_skill_content_before_allowing
    Dir.mktmpdir do |dir|
      config_dir = File.join(dir, "config")
      workspace = File.join(dir, "workspace")
      skill_dir = File.join(workspace, ".agents", "skills", "project-agent")
      skill_path = File.join(skill_dir, "SKILL.md")
      FileUtils.mkdir_p(File.join(skill_dir, "references"))
      FileUtils.mkdir_p(config_dir)
      File.write(File.join(config_dir, "config.json"), JSON.dump({}))
      File.write(skill_path, "---\nname: project-agent\ndescription: Project workspace skill.\n---\nReview this instruction.\n")
      File.write(File.join(skill_dir, "references", "notes.md"), "Supporting notes.\n")
      prompt = FakeSettingsPrompt.new([], ["Review", "Allow"])
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt)
      cli.define_singleton_method(:prompt_interface?) { true }
      cli.define_singleton_method(:current_workspace_root) { workspace }

      with_env("KWARD_CONFIG_PATH" => File.join(config_dir, "config.json")) do
        cli.send(:prepare_interactive_project_skills)

        assert_equal [skill_path], cli.instance_variable_get(:@interactive_project_skill_paths)
        output = prompt.output.join("\n")
        assert_includes output, "Review this instruction."
        assert_includes output, "references/notes.md"
      end
    end
  end

  def test_interactive_warnings_are_rendered_as_runtime_output
    Dir.mktmpdir do |dir|
      workspace = File.join(dir, "workspace")
      config_path = File.join(dir, "config.json")
      skill_dir = File.join(workspace, ".agents", "skills", "project-agent")
      FileUtils.mkdir_p(skill_dir)
      File.write(config_path, JSON.dump({}))
      File.write(File.join(skill_dir, "SKILL.md"), "---\nname: project-agent\ndescription: Project skill.\n---\n")

      cli = nil
      with_env("KWARD_CONFIG_PATH" => config_path) do
        Dir.chdir(workspace) do
          cli = WarningPromptInterfaceCLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: TTY::Prompt.new)
          _stdout, stderr = capture_io { cli.send(:setup_interactive_prompt, defer_warnings: true) }
          prompt_output = cli.instance_variable_get(:@prompt).output
          assert_empty prompt_output

          Kward::ConfigFiles.emit_warning("Warning: queued startup diagnostic")
          assert_empty prompt_output

          cli.send(:enable_interactive_warnings)
          output = prompt_output.join("\n")
          assert_includes output, "Runtime> Warning: queued startup diagnostic"
          assert_empty stderr
        end
      end
    ensure
      cli&.send(:clear_interactive_warning_sink)
    end
  end

  def test_interactive_mode_resumes_last_session_on_startup_when_enabled
    Dir.mktmpdir do |config_dir|
      config_path = File.join(config_dir, "config.json")
      File.write(config_path, JSON.dump("sessions" => { "auto_resume" => true }))
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      first_prompt = FakePrompt.new(["hello", "/exit"])
      first_client = RecordingClient.new(["reply"])
      with_env("KWARD_CONFIG_PATH" => config_path) do
        Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: first_prompt, client: first_client, session_store: store).interactive_loop
      end

      assert_path_exists store.last_session_path

      second_prompt = BannerPrompt.new(["again", "/exit"])
      second_client = RecordingClient.new(["second"])
      with_env("KWARD_CONFIG_PATH" => config_path) do
        Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: second_prompt, client: second_client, session_store: store).interactive_loop
      end

      assert_equal "hello", second_client.seen_messages[0][1]["content"]
      assert_equal "reply", second_client.seen_messages[0][2]["content"]
      assert_equal "again", second_client.seen_messages[0][3][:content]
      assert_equal 0, second_prompt.banner_count
      output = strip_ansi(second_prompt.output.join("\n"))
      assert_includes output, "Resumed session:"
      assert_includes output, "You> hello"
      assert_includes output, "reply"
    end
  end

  def test_interactive_mode_resumes_last_session_with_tabs_when_enabled
    Dir.mktmpdir do |config_dir|
      config_path = File.join(config_dir, "config.json")
      File.write(config_path, JSON.dump("sessions" => { "auto_resume" => true }))
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      with_env("KWARD_CONFIG_PATH" => config_path) do
        Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: FakePrompt.new(["hello", "/exit"]), client: RecordingClient.new(["reply"]), session_store: store).interactive_loop
        prompt = FakePrompt.new(["again", "/exit"])
        client = RecordingClient.new(["second"])

        Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client, session_store: store).interactive_loop

        assert_equal "hello", client.seen_messages[0][1]["content"]
        assert_equal "again", client.seen_messages[0][3][:content]
      end
    end
  end

  def test_interactive_mode_starts_new_session_when_auto_resume_disabled
    Dir.mktmpdir do |config_dir|
      config_path = File.join(config_dir, "config.json")
      File.write(config_path, JSON.dump("sessions" => { "auto_resume" => false }))
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      first_prompt = FakePrompt.new(["hello", "/exit"])
      first_client = RecordingClient.new(["reply"])
      with_env("KWARD_CONFIG_PATH" => config_path) do
        Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: first_prompt, client: first_client, session_store: store).interactive_loop
      end

      second_prompt = FakePrompt.new(["again", "/exit"])
      second_client = RecordingClient.new(["second"])
      with_env("KWARD_CONFIG_PATH" => config_path) do
        Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: second_prompt, client: second_client, session_store: store).interactive_loop
      end

      message = second_client.seen_messages[0][1]
      assert_equal "again", message["content"] || message[:content]
      output = strip_ansi(second_prompt.output.join("\n"))
      refute_includes output, "Resumed session:"
      refute_includes output, "You> hello"
    end
  end

  def test_interactive_mode_prints_visual_banner_once_without_persisting_it
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      prompt = BannerPrompt.new(["hello", "/exit"])
      client = RecordingClient.new(["reply"])
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client, session_store: store)

      cli.interactive_loop

      assert_equal 1, prompt.banner_count
      output = prompt.output.join("\n")
      assert_includes output, "Kward v#{Kward::VERSION} is online."
      assert_includes output, "State your business."
      files = Dir.glob(File.join(store.session_dir, "*.jsonl"))
      assert_equal 1, files.length
      refute_includes File.read(files.first), "Kward v#{Kward::VERSION} is online."
    end
  end

  def test_startup_plugins_value_lists_loaded_plugin_filenames
    Dir.mktmpdir do |home|
      plugin_root = File.join(home, ".kward", "plugins")
      registry = Kward::PluginRegistry.new
      registry.instance_variable_set(:@paths, [
        File.join(plugin_root, "alpha.rb"),
        File.join(plugin_root, "folder", "plugin.rb")
      ])
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: FakePrompt.new([]), client: RecordingClient.new([]))
      cli.instance_variable_set(:@plugin_registry, registry)

      with_env("HOME" => home) do
        assert_equal "alpha.rb, folder/plugin.rb", cli.send(:startup_plugins_value)
      end
    end
  end

  def test_startup_plugins_value_shows_none_without_loaded_plugins
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: FakePrompt.new([]), client: RecordingClient.new([]))
    cli.instance_variable_set(:@plugin_registry, Kward::PluginRegistry.new)

    assert_equal "none", cli.send(:startup_plugins_value)
  end

  def test_startup_info_screen_uses_color_when_enabled
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: FakePrompt.new([]), client: RecordingClient.new([]))
    cli.instance_variable_set(:@color_enabled, true)
    cli.instance_variable_set(:@plugin_registry, Kward::PluginRegistry.new)

    with_env("KWARD_DISABLE_UPDATE_CHECK" => "1") do
      output = cli.send(:startup_info_screen)

      assert_includes output, "\e[32m●\e[0m Kward v#{Kward::VERSION} is online."
      refute_includes output, "\e[36;1mKward\e[0m"
      assert_includes output, "\e[90mWorkspace   \e[0m"
      assert_includes output, "\e[1mState your business.\e[0m"
      refute_includes output, "\e[33;1mState your business.\e[0m"
      assert_includes Kward::ANSI.strip(output), "Plugins     none"
    end
  end

  def test_startup_info_screen_shows_cached_update_notice
    Dir.mktmpdir do |config_dir|
      cache_path = File.join(config_dir, "cache", "update_check.json")
      FileUtils.mkdir_p(File.dirname(cache_path))
      File.write(cache_path, JSON.dump("checked_at" => Time.now.utc.iso8601, "latest_version" => "999.0.0"))
      config_path = File.join(config_dir, "config.json")
      File.write(config_path, JSON.dump({}))
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: FakePrompt.new([]), client: RecordingClient.new([]))
      cli.instance_variable_set(:@color_enabled, true)
      cli.instance_variable_set(:@plugin_registry, Kward::PluginRegistry.new)

      with_env("KWARD_CONFIG_PATH" => config_path) do
        output = cli.send(:startup_info_screen)

        assert_includes output, "\e[33m●\e[0m Kward v#{Kward::VERSION} is online."
        assert_includes output, "  New version available: 999.0.0"
        assert_includes output, "  Run: gem update kward"
      end
    end
  end

  def test_startup_info_screen_can_refresh_update_notice_before_rendering
    checker = Object.new
    requested_refresh = nil
    checker.define_singleton_method(:notice) do |refresh: false|
      requested_refresh = refresh
      Kward::UpdateCheck::Notice.new(latest_version: "999.0.0")
    end
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: FakePrompt.new([]), client: RecordingClient.new([]))
    cli.instance_variable_set(:@color_enabled, true)
    cli.instance_variable_set(:@plugin_registry, Kward::PluginRegistry.new)
    cli.instance_variable_set(:@startup_update_check, checker)

    output = cli.send(:startup_info_screen, refresh_update_check: true)

    assert_equal true, requested_refresh
    assert_includes output, "  New version available: 999.0.0"
  end

  def test_update_check_disabled_ignores_cached_notice
    Dir.mktmpdir do |config_dir|
      cache_path = File.join(config_dir, "cache", "update_check.json")
      FileUtils.mkdir_p(File.dirname(cache_path))
      File.write(cache_path, JSON.dump("checked_at" => Time.now.utc.iso8601, "latest_version" => "999.0.0"))
      config_path = File.join(config_dir, "config.json")
      File.write(config_path, JSON.dump("updates" => { "check" => false }))
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: FakePrompt.new([]), client: RecordingClient.new([]))
      cli.instance_variable_set(:@color_enabled, true)
      cli.instance_variable_set(:@plugin_registry, Kward::PluginRegistry.new)

      with_env("KWARD_CONFIG_PATH" => config_path) do
        output = cli.send(:startup_info_screen)

        assert_includes output, "\e[32m●\e[0m Kward v#{Kward::VERSION} is online."
        refute_includes output, "New version available"
        refute_includes output, "gem update kward"
      end
    end
  end

  def test_startup_workspace_label_uses_parent_and_folder_outside_home
    Dir.mktmpdir do |dir|
      workspace = File.join(dir, "kaiwood", "kward")
      FileUtils.mkdir_p(workspace)
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: FakePrompt.new([]), client: RecordingClient.new([]))
      cli.instance_variable_set(:@working_directory, workspace)

      with_env("HOME" => File.join(dir, "home")) do
        assert_equal "kaiwood/kward", cli.send(:startup_workspace_label)
      end
    end
  end

  def test_startup_workspace_label_uses_parent_and_folder_for_nested_path_inside_home
    Dir.mktmpdir do |home|
      workspace = File.join(home, "Repositories", "github.com", "kaiwood", "kward")
      FileUtils.mkdir_p(workspace)
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: FakePrompt.new([]), client: RecordingClient.new([]))
      cli.instance_variable_set(:@working_directory, workspace)

      with_env("HOME" => home) do
        assert_equal "kaiwood/kward", cli.send(:startup_workspace_label)
      end
    end
  end

  def test_startup_workspace_label_uses_home_relative_path_for_direct_child_of_home
    Dir.mktmpdir do |home|
      workspace = File.join(home, "project")
      FileUtils.mkdir_p(workspace)
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: FakePrompt.new([]), client: RecordingClient.new([]))
      cli.instance_variable_set(:@working_directory, workspace)

      with_env("HOME" => home) do
        assert_equal "~/project", cli.send(:startup_workspace_label)
      end
    end
  end

  def test_unused_session_removed_on_exit
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      prompt = FakePrompt.new(["/exit"])
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: RecordingClient.new([]), session_store: store)

      cli.interactive_loop

      assert_empty Dir.glob(File.join(store.session_dir, "*.jsonl"))
    end
  end

  def test_new_command_clears_prompt_transcript
    Dir.mktmpdir do |config_dir|
      Dir.mktmpdir do |workspace|
        store = Kward::SessionStore.new(config_dir: config_dir, cwd: workspace)
        output = StringIO.new
        input, writer = IO.pipe
        writer.write("hello\r/new\r/exit\r")
        writer.close
        prompt = Kward::PromptInterface.new(input: input, output: output)
        client = RecordingClient.new(["reply"])
        cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client, session_store: store)

        with_env("KWARD_CONFIG_PATH" => File.join(config_dir, "config.json")) do
          cli.interactive_loop
        end

        assert_includes strip_ansi(output.string), "You> hello"
        assert_includes output.string, TTY::Cursor.clear_screen
        after_clear = output.string.split(TTY::Cursor.clear_screen).last
        refute_includes strip_ansi(after_clear), "You> hello"
        refute_includes strip_ansi(after_clear), "Kward>"
        refute_includes strip_ansi(after_clear), "Started new session:"
      ensure
        input&.close unless input&.closed?
      end
    end
  end

  def test_non_empty_session_kept_on_exit
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      prompt = FakePrompt.new(["hello", "/exit"])
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: RecordingClient.new(["reply"]), session_store: store)

      cli.interactive_loop

      files = Dir.glob(File.join(store.session_dir, "*.jsonl"))
      assert_equal 1, files.length
      assert jsonl_records(files.first).any? { |record| record["type"] == "message" && record["message"]["role"] == "user" }
    end
  end

  def test_named_empty_session_kept_on_exit
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      prompt = FakePrompt.new(["/session name Useful", "/exit"])
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: RecordingClient.new([]), session_store: store)

      cli.interactive_loop

      files = Dir.glob(File.join(store.session_dir, "*.jsonl"))
      assert_equal 1, files.length
      assert jsonl_records(files.first).any? { |record| record["type"] == "session_info" && record["name"] == "Useful" }
    end
  end

  def test_rename_names_empty_session_and_keeps_it_on_exit
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      prompt = FakePrompt.new(["/rename Useful", "/exit"])
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: RecordingClient.new([]), session_store: store)

      cli.interactive_loop

      files = Dir.glob(File.join(store.session_dir, "*.jsonl"))
      assert_equal 1, files.length
      assert jsonl_records(files.first).any? { |record| record["type"] == "session_info" && record["name"] == "Useful" }
    end
  end

  def test_rename_requires_name
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      prompt = FakePrompt.new(["/rename", "/exit"])
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: RecordingClient.new([]), session_store: store)

      cli.interactive_loop

      assert prompt.output.any? { |line| line.include?("Usage: /rename <name>") }
      assert_empty Dir.glob(File.join(store.session_dir, "*.jsonl"))
    end
  end

  def test_session_name_does_not_enter_busy_state
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      prompt = BusyPrompt.new(["/session name Useful", "/exit"])
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: RecordingClient.new([]), session_store: store)

      cli.interactive_loop

      refute_includes prompt.events, [:begin_busy_input, "You>", "loading"]
      assert prompt.output.any? { |line| line.include?("Named session: Useful") }
      assert jsonl_records(Dir.glob(File.join(store.session_dir, "*.jsonl")).first).any? { |record| record["type"] == "session_info" && record["name"] == "Useful" }
    end
  end

  def test_session_name_without_argument_clears_session_name
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      prompt = FakePrompt.new(["/session name Useful", "/session name", "/exit"])
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: RecordingClient.new([]), session_store: store)

      cli.interactive_loop

      assert prompt.output.any? { |line| line.include?("Cleared session name.") }
      assert_empty Dir.glob(File.join(store.session_dir, "*.jsonl"))
    end
  end

  def test_name_is_no_longer_a_builtin_command
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      prompt = FakePrompt.new(["/name Useful", "/exit"])
      client = RecordingClient.new(["reply"])
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client, session_store: store)

      cli.interactive_loop

      assert_equal "/name Useful", client.seen_messages.first.last[:content]
      refute prompt.output.any? { |line| line.include?("Named session: Useful") }
    end
  end

  def test_quit_exits_like_exit
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      client = RecordingClient.new([])
      prompt = FakePrompt.new(["/quit"])
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client, session_store: store)

      cli.interactive_loop

      assert_empty client.seen_messages
      assert_empty Dir.glob(File.join(store.session_dir, "*.jsonl"))
    end
  end

  def test_one_shot_does_not_create_session_file
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      client = RecordingClient.new(["reply"])
      cli = Kward::CLI.new(argv: ["hello"], stdin: FakeInput.new("", tty: true), client: client, session_store: store)

      assert_equal "reply", cli.one_shot("hello")

      refute Dir.exist?(store.session_dir)
    end
  end

  def test_one_shot_executes_tool_calls
    client = RecordingClient.new([
      assistant_tool_call("read_file", path: "README.md"),
      "README summary"
    ])
    cli = Kward::CLI.new(argv: ["read README"], stdin: FakeInput.new("", tty: true), client: client)

    output = capture_io do
      assert_equal "README summary", cli.one_shot("read README")
    end.first

    assert_equal 2, client.seen_messages.length
    assert_equal "tool", client.seen_messages[1][3][:role]
    assert_equal "call_read_file", client.seen_messages[1][3][:tool_call_id]
    assert_equal "read_file", client.seen_messages[1][3][:name]
    assert_includes client.seen_messages[1][3][:content], "# Kward"
    assert_includes output, "Tool>"
    refute_includes output, "Tool output>"
  end

  def test_resume_explicit_session_path_loads_prior_messages
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      saved = store.create
      conversation = Kward::Conversation.new
      saved.attach(conversation)
      conversation.append_user("hello")
      conversation.append_assistant("reply")
      prompt = BannerPrompt.new(["/resume #{saved.path}", "again", "/exit"])
      client = RecordingClient.new(["second"])
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client, session_store: store)

      cli.interactive_loop

      assert_equal "hello", client.seen_messages[0][1]["content"]
      assert_equal "reply", client.seen_messages[0][2]["content"]
      assert_equal "again", client.seen_messages[0][3][:content]
      assert_equal 1, prompt.banner_count
      output = strip_ansi(prompt.output.join("\n"))
      assert_includes output, "You> hello"
      assert_includes output, "reply"
    end
  end

  def test_session_explicit_session_path_loads_prior_messages
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      saved = store.create
      conversation = Kward::Conversation.new
      saved.attach(conversation)
      conversation.append_user("hello")
      conversation.append_assistant("reply")
      prompt = BannerPrompt.new(["/session #{saved.path}", "again", "/exit"])
      client = RecordingClient.new(["second"])
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client, session_store: store)

      cli.interactive_loop

      assert_equal "hello", client.seen_messages[0][1]["content"]
      assert_equal "reply", client.seen_messages[0][2]["content"]
      assert_equal "again", client.seen_messages[0][3][:content]
      assert_equal 1, prompt.banner_count
    end
  end

  def test_resume_prompt_interface_preserves_scrollback_with_synchronized_redraw
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      saved = store.create
      conversation = Kward::Conversation.new(system_message: nil)
      saved.attach(conversation)
      1.upto(30) do |index|
        conversation.append_user(format("turn %03d", index))
      end
      output = StringIO.new
      input, writer = IO.pipe
      writer.write("/resume #{saved.path}\r/exit\r")
      writer.close
      prompt = Kward::PromptInterface.new(input: input, output: output)
      original_width = TTY::Screen.method(:width)
      original_height = TTY::Screen.method(:height)
      TTY::Screen.define_singleton_method(:width) { 80 }
      TTY::Screen.define_singleton_method(:height) { 20 }
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: RecordingClient.new([]), session_store: store)

      cli.interactive_loop

      rendered = strip_ansi(output.string)
      assert_includes output.string, Kward::PromptInterface::SYNCHRONIZED_OUTPUT_ENABLE
      assert_includes output.string, Kward::PromptInterface::SYNCHRONIZED_OUTPUT_DISABLE
      assert_includes output.string, TTY::Cursor.clear_screen
      assert_includes rendered, "turn 001\r\n"
      assert_includes rendered, "turn 030"
    ensure
      TTY::Screen.define_singleton_method(:width, original_width) if original_width
      TTY::Screen.define_singleton_method(:height, original_height) if original_height
      input&.close unless input&.closed?
    end
  end

  def test_resume_slash_command_shows_loading_spinner
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      saved = store.create
      conversation = Kward::Conversation.new
      saved.attach(conversation)
      conversation.append_user("hello")
      prompt = BusyPrompt.new(["/resume #{saved.path}", "/exit"])
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: RecordingClient.new([]), session_store: store)

      cli.interactive_loop

      loading_index = prompt.events.index([:begin_busy_input, "You>", "loading"])
      assert loading_index
      finish_after_loading = prompt.events[loading_index..].index([:finish_busy_input])
      assert finish_after_loading
      assert_includes prompt.output.join("\n"), "Resumed session:"
    end
  end

  def test_resume_picker_loads_sessions_with_spinner_before_opening_picker
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      saved = store.create
      conversation = Kward::Conversation.new
      saved.attach(conversation)
      conversation.append_user("hello")
      prompt = BusyPrompt.new(["/resume", "/exit"])
      prompt.define_singleton_method(:select) do |_message, choices, title: "Sessions", custom: false, **_kwargs|
        events << [:select_session]
        choices.first
      end
      store.define_singleton_method(:recent_tree) do |limit: 20, keep_empty_path: nil|
        prompt.events << [:recent_tree, limit]
        super(limit: limit, keep_empty_path: keep_empty_path)
      end
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: RecordingClient.new([]), session_store: store)

      cli.interactive_loop

      recent_index = prompt.events.index([:recent_tree, nil])
      select_index = prompt.events.index([:select_session])
      loading_start_index = prompt.events.index([:begin_busy_input, "You>", "loading"])
      loading_finish_index = prompt.events.index([:finish_busy_input])
      assert recent_index
      assert select_index
      assert loading_start_index
      assert loading_finish_index
      assert_operator loading_start_index, :<, recent_index
      assert_operator recent_index, :<, loading_finish_index
      assert_operator loading_finish_index, :<, select_index
    end
  end

  def test_resume_picker_displays_cloned_sessions_as_tree_children
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      source = store.create
      conversation = Kward::Conversation.new(system_message: nil)
      source.attach(conversation)
      conversation.append_user("source prompt")
      store.create_independent_from_conversation(conversation, parent_session: source)
      prompt = BusySelectPrompt.new(["/resume", "/exit"])
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: RecordingClient.new([]), session_store: store)

      cli.interactive_loop

      choices = prompt.select_choices.first
      assert choices.any? { |label| label.start_with?("└─ source prompt") }, choices.inspect
    end
  end

  def test_resume_updates_composer_context_usage_source
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      saved = store.create
      conversation = Kward::Conversation.new(system_message: nil)
      saved.attach(conversation)
      conversation.append_user("resumed context")
      prompt = FakePrompt.new(["/resume #{saved.path}", "/exit"])
      context_usage = Object.new
      seen_messages = []
      context_usage.define_singleton_method(:call) do |context_parts:, **_kwargs|
        seen_messages.replace(context_parts[:messages])
        { percent: 9 }
      end
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([]), session_store: store, context_usage: context_usage)
      hide_composer_git_branch(cli)

      cli.interactive_loop

      assert_equal "9% · Codex fake-model · medium", cli.send(:composer_status_text)
      assert_equal "resumed context", seen_messages.last["content"] || seen_messages.last[:content]
      assert_equal 1, prompt.redraw_count
    end
  end

  def test_resume_renders_reasoning_summary_parts_as_separate_blocks
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      saved = store.create
      conversation = Kward::Conversation.new
      saved.attach(conversation)
      conversation.append_user("inspect file")
      conversation.append_assistant({
        "role" => "assistant",
        "content" => "",
        "response_items" => [
          {
            "type" => "reasoning",
            "summary" => [
              { "type" => "summary_text", "text" => "Planning provider tests" },
              { "type" => "summary_text", "text" => "Documenting availability" }
            ]
          }
        ]
      })
      prompt = FakePrompt.new(["/resume #{saved.path}", "/exit"])
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: RecordingClient.new([]), session_store: store)

      cli.interactive_loop

      output = strip_ansi(prompt.output.join("\n"))
      assert_includes output, "Reasoning> Planning provider tests"
      assert_includes output, "Reasoning> Documenting availability"
      refute_includes output, "Planning provider tests\nDocumenting availability"
    end
  end

  def test_resume_renders_reasoning_tools_and_tool_output
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      saved = store.create
      conversation = Kward::Conversation.new
      saved.attach(conversation)
      conversation.append_user("inspect file")
      conversation.append_assistant({
        "role" => "assistant",
        "content" => "I'll read it.",
        "reasoning_summary" => "Need to inspect the file.",
        "tool_calls" => [tool_call("read_file", path: "README.md")]
      })
      conversation.append_tool(tool_call_id: "call_read_file", name: "read_file", content: "README contents\n")
      prompt = FakePrompt.new(["/resume #{saved.path}", "/exit"])
      client = RecordingClient.new([])
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client, session_store: store)

      cli.interactive_loop

      output = strip_ansi(prompt.output.join("\n"))
      assert_includes output, "You> inspect file"
      assert_includes output, "Reasoning> Need to inspect the file."
      assert_includes output, "I'll read it."
      assert_includes output, "Tool> read_file: README.md\n\n1 lines, 16 bytes"
      refute_includes output, "Tool output>"
      assert_includes output, "1 lines, 16 bytes"
      refute_includes output, "README contents"
    end
  end

  def test_resume_renders_response_item_reasoning_and_hides_commentary
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      saved = store.create
      conversation = Kward::Conversation.new
      saved.attach(conversation)
      conversation.append_user("inspect file")
      conversation.append_assistant({
        "role" => "assistant",
        "content" => "",
        "tool_calls" => [tool_call("read_file", path: "README.md")],
        "response_items" => [
          { "type" => "reasoning", "summary" => [{ "type" => "summary_text", "text" => "Need context." }] },
          { "type" => "message", "phase" => "commentary", "content" => [{ "type" => "output_text", "text" => "Need inspect file first." }] },
          { "type" => "function_call", "id" => "fc_1", "call_id" => "call_read_file", "name" => "read_file", "arguments" => JSON.dump("path" => "README.md") }
        ]
      })
      conversation.append_tool(tool_call_id: "call_read_file", name: "read_file", content: "README contents\n")
      prompt = FakePrompt.new(["/resume #{saved.path}", "/exit"])
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: RecordingClient.new([]), session_store: store)

      cli.interactive_loop

      output = strip_ansi(prompt.output.join("\n"))
      assert_includes output, "Reasoning> Need context."
      refute_includes output, "Need inspect file first."
      assert_includes output, "Tool> read_file: README.md\n\n1 lines, 16 bytes"
    end
  end

  def test_retry_event_renders_retry_message
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), client: FakeClient.new([]))
    event = Kward::Events::Retry.new(provider: "Codex", model: "gpt-test", attempt: 2, max_attempts: 3, delay_seconds: 1, error: "Codex request failed: 503 upstream", request_bytes: 123)

    output = capture_io do
      cli.send(:print_retry, event)
    end.first

    assert_includes output, "Retry>"
    assert_includes output, "Retrying Codex request after transient failure (attempt 2/3) in 1s with 123 byte payload"
    assert_includes output, "Codex request failed: 503 upstream"
  end

  def test_tool_output_display_uses_compact_summaries
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: FakePrompt.new([]), client: FakeClient.new([]))

    read_output = capture_io do
      cli.send(:print_tool_result, tool_call("read_file", path: "README.md"), "line one\nline two\n")
    end.first
    assert_includes read_output, "read_file: README.md\n\n2 lines, 18 bytes"
    assert_includes read_output, "2 lines, 18 bytes"
    refute_includes read_output, "line one"

    shell_output = capture_io do
      cli.send(:print_tool_result, tool_call("run_shell_command", command: "echo ok"), "Exit status: 0\n\nSTDOUT:\nok\n\nSTDERR:\nwarn\n")
    end.first
    assert_includes shell_output, "run_shell_command: echo ok\n\nExit status: 0"
    assert_includes shell_output, "Exit status: 0"
    assert_includes shell_output, "stdout (3 bytes):\nok"
    assert_includes shell_output, "stderr (5 bytes):\nwarn"

    research_output = capture_io do
      cli.send(:print_tool_result, tool_call("web_search", queries: ["ruby"]), "# Web search\n\n## Query: ruby\n1. Ruby\n   URL: https://ruby-lang.org\n")
    end.first
    assert_includes research_output, "web_search"
    assert_includes research_output, "ruby: 1 result(s)"
  end

  def test_read_skill_tool_output_starts_content_on_immediate_next_line
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: FakePrompt.new([]), client: FakeClient.new([]))
    content = "---\nname: beautiful-ruby\ndescription: Use when writing Ruby.\n---\n"

    output = capture_io do
      cli.send(:print_tool_result, tool_call("read_skill", name: "beautiful-ruby"), content)
    end.first

    assert_includes strip_ansi(output), "Tool> read_skill:\n---\nname: beautiful-ruby"
    refute_includes strip_ansi(output), "Tool> read_skill:\n\n---"
    refute_includes strip_ansi(output), "Tool> read_skill: ---"
  end

  def test_interactive_tool_output_limit_keeps_10_line_summary_unchanged
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: FakePrompt.new([]), client: FakeClient.new([]))
    content = (1..10).map { |index| "line#{index}" }.join("\n")

    output = capture_io do
      cli.send(:print_tool_result, tool_call("custom_tool", {}), content, line_limit: Kward::CLI::INTERACTIVE_TOOL_OUTPUT_LINE_LIMIT)
    end.first

    summary = strip_ansi(output).split("Tool> ", 2).last
    assert_equal 10, summary.lines.reject { |line| line == "\n" }.length
    assert_includes output, "line10"
    refute_includes output, "truncated"
  end

  def test_interactive_tool_output_limit_does_not_truncate_model_context
    command = %q(ruby -e '12.times { |i| puts "line#{i + 1}" }')
    prompt = FakePrompt.new(["show lines", "/exit"])
    client = RecordingClient.new([assistant_tool_call("run_shell_command", command: command), "done"])
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client, session_store: store)

      output = capture_io do
        cli.interactive_loop
      end.first

      assert_includes output, "Tool>"
      refute_includes output, "Tool output>"
      assert_includes output, "...[truncated"
      refute_includes output, "line12"
      tool_message = client.seen_messages[1].find { |message| (message["role"] || message[:role]) == "tool" }
      assert_includes tool_message[:content], "line12"
    end
  end

  def test_resume_limits_restored_tool_output_to_10_lines
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      saved = store.create
      conversation = Kward::Conversation.new
      saved.attach(conversation)
      conversation.append_user("inspect restored output")
      conversation.append_assistant({
        "role" => "assistant",
        "content" => nil,
        "tool_calls" => [tool_call("custom_tool", {})]
      })
      conversation.append_tool(tool_call_id: "call_custom_tool", name: "custom_tool", content: (1..12).map { |index| "line#{index}" }.join("\n"))
      prompt = FakePrompt.new(["/resume #{saved.path}", "/exit"])
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: RecordingClient.new([]), session_store: store)

      cli.interactive_loop

      output = strip_ansi(prompt.output.join("\n"))
      assert_includes output, "Tool> custom_tool: line1\n\nline2"
      assert_includes output, "...[truncated 3 lines]"
      refute_includes output, "line12"
    end
  end

  def test_session_commands_name_clone_and_export
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      export_path = File.join(store.session_dir, "session.md")
      prompt = FakePrompt.new(["hello", "/session name Draft", "/session name Useful", "/clone", "/export #{export_path}", "/exit"])
      client = RecordingClient.new(["reply"])
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client, session_store: store)

      cli.interactive_loop

      files = Dir.glob(File.join(store.session_dir, "*.jsonl"))
      assert_equal 2, files.length
      assert files.any? { |file| jsonl_records(file).any? { |record| record["type"] == "session_info" && record["name"] == "Useful" } }
      output = strip_ansi(prompt.output.join("\n"))
      assert_includes output, "You> hello"
      assert_includes output, "reply"
      assert_includes File.read(export_path), "## User\n\nhello"
      assert_includes File.read(export_path), "## Assistant\n\nreply"
      source_path, clone_path = files.sort_by { |file| jsonl_records(file).find { |record| record["type"] == "session" }.key?("parentId") ? 1 : 0 }
      source = jsonl_records(source_path).find { |record| record["type"] == "session" }
      clone = jsonl_records(clone_path).find { |record| record["type"] == "session" }
      clone_name = jsonl_records(clone_path).select { |record| record["type"] == "session_info" }.last
      assert_equal source["id"], clone["parentId"]
      assert_equal "Useful", clone_name["name"]
    end
  end

  def test_session_picker_clone_action_ignores_missing_inserted_copy
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      source = store.create
      conversation = Kward::Conversation.new
      source.attach(conversation)
      conversation.append_user("saved prompt")
      prompt = FakePrompt.new([])
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: RecordingClient.new([]), session_store: store)
      sessions = store.recent_tree(limit: nil)
      labels = cli.send(:session_picker_labels, sessions)

      result = cli.send(:copy_session_selection, store, sessions, labels, labels.first) do
        File.join(store.session_dir, "missing.jsonl")
      end

      assert_nil result
    end
  end

  def test_session_picker_clone_action_clones_and_keeps_picker_open
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      source = store.create
      conversation = Kward::Conversation.new
      source.attach(conversation)
      conversation.append_user("saved prompt")
      conversation.append_assistant("saved reply")
      prompt = FakePrompt.new(["/session", "/exit"])
      prompt.define_singleton_method(:select) do |_message, choices, title: "Sessions", custom: false, initial_index: 0, action_keys: {}, action_handlers: {}|
        @clone_result = action_handlers.fetch(action_keys.fetch("c")[:action]).call(choices.first)
        nil
      end
      client = RecordingClient.new([])
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client, session_store: store)

      cli.interactive_loop

      files = Dir.glob(File.join(store.session_dir, "*.jsonl"))
      assert_equal 2, files.length
      clone_path = (files - [source.path]).first
      clone_result = prompt.instance_variable_get(:@clone_result)
      cloned_label = clone_result[:choices][clone_result[:selection_index]]

      assert_equal true, clone_result[:select_continue]
      assert_includes cloned_label, File.basename(clone_path)
      refute_includes strip_ansi(prompt.output.join("\n")), "Cloned session: #{clone_path}"
    end
  end

  def test_session_picker_fork_action_opens_fork_prompt_selector
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      source = store.create
      conversation = Kward::Conversation.new
      source.attach(conversation)
      conversation.append_user("kept prompt")
      conversation.append_assistant("kept reply")
      conversation.append_user("saved prompt")
      conversation.append_assistant("saved reply")
      prompt = FakePrompt.new(["/session", "/exit"])
      prompt.define_singleton_method(:select) do |message, choices, title: "Sessions", custom: false, initial_index: 0, action_keys: {}, action_handlers: {}|
        @select_messages ||= []
        @select_titles ||= []
        @select_choices ||= []
        @select_initial_indices ||= []
        @select_messages << message
        @select_titles << title
        @select_choices << choices
        @select_initial_indices << initial_index
        if message == "Session>" && @select_messages.count("Session>") == 1
          action = action_keys.fetch("f")
          { action: action.is_a?(Hash) ? action[:action] : action, choice: choices.first, defer_finish_render: action.is_a?(Hash) && action[:defer_finish_render] }
        elsif message == "Session>"
          @forked_label = choices[initial_index]
          nil
        else
          choices.find { |choice| choice.include?("saved prompt") } || choices.first
        end
      end
      client = RecordingClient.new([])
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client, session_store: store)

      cli.interactive_loop

      files = Dir.glob(File.join(store.session_dir, "*.jsonl"))
      assert_equal 2, files.length
      fork_path = (files - [source.path]).first
      fork_session, fork_conversation = store.load(fork_path)
      fork_messages = fork_conversation.messages.reject { |message| (message["role"] || message[:role]) == "system" }
      output = strip_ansi(prompt.output.join("\n"))

      assert_equal ["Session>", "Fork>", "Session>"], prompt.instance_variable_get(:@select_messages)
      assert_equal "Fork", prompt.instance_variable_get(:@select_titles)[1]
      assert_empty prompt.prefilled_inputs
      assert_equal prompt.instance_variable_get(:@forked_label), prompt.instance_variable_get(:@select_choices)&.last&.[](prompt.instance_variable_get(:@select_initial_indices)&.last)
      assert_equal ["kept prompt", "kept reply"], fork_messages.map { |message| message["content"] || message[:content] }
      assert_equal fork_session.leaf_id, fork_messages.last["id"]
      refute_includes output, "Forked session: #{fork_path}"
      refute_includes File.read(fork_path), "saved prompt"
      refute_includes File.read(fork_path), "saved reply"
      source_header = jsonl_records(source.path).find { |record| record["type"] == "session" }
      fork_header = jsonl_records(fork_path).find { |record| record["type"] == "session" }
      assert_equal source_header["id"], fork_header["parentId"]
    end
  end

  def test_session_picker_repeated_fork_action_does_not_escape_as_agent
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      source = store.create
      conversation = Kward::Conversation.new
      source.attach(conversation)
      conversation.append_user("kept prompt")
      conversation.append_assistant("kept reply")
      conversation.append_user("saved prompt")
      conversation.append_assistant("saved reply")
      prompt = FakePrompt.new(["/session"])
      prompt.define_singleton_method(:select) do |message, choices, title: "Sessions", custom: false, initial_index: 0, action_keys: {}, action_handlers: {}|
        @select_messages ||= []
        @select_messages << message
        if message == "Session>"
          return nil if @select_messages.count("Session>") == 3

          action = action_keys.fetch("f")
          { action: action.is_a?(Hash) ? action[:action] : action, choice: choices[initial_index] || choices.first, defer_finish_render: action.is_a?(Hash) && action[:defer_finish_render] }
        else
          return nil if @select_messages.count("Fork>") == 2

          choices.find { |choice| choice.include?("saved prompt") } || choices.first
        end
      end
      client = RecordingClient.new([])
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client, session_store: store)

      conversation = cli.interactive_loop

      assert_kind_of Kward::Conversation, conversation
      assert_equal ["Session>", "Fork>", "Session>", "Fork>", "Session>"], prompt.instance_variable_get(:@select_messages)
      assert_equal 2, Dir.glob(File.join(store.session_dir, "*.jsonl")).length
    end
  end

  def test_session_picker_rename_action_keeps_picker_open
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      source = store.create
      conversation = Kward::Conversation.new
      source.attach(conversation)
      conversation.append_user("saved prompt")
      prompt = FakePrompt.new(["/session", "/exit"])
      test = self
      prompt.define_singleton_method(:select) do |message, choices, title: "Sessions", custom: false, initial_index: 0, action_keys: {}, action_handlers: {}|
        @select_messages ||= []
        @select_choices ||= []
        @select_initial_indices ||= []
        @select_messages << message
        @select_choices << choices
        @select_initial_indices << initial_index
        action = action_keys.fetch("r")
        test.assert_equal :rename, action[:action]
        test.assert_equal "Name>", action[:input_prompt]
        result = action_handlers.fetch(:rename).call(choices.first, "Renamed session")
        @select_choices << result[:choices]
        @select_initial_indices << result[:selection_index]
        nil
      end
      client = RecordingClient.new([])
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client, session_store: store)

      cli.interactive_loop

      records = jsonl_records(source.path)
      assert_equal "Renamed session", records.select { |record| record["type"] == "session_info" }.last["name"]
      assert_equal ["Session>"], prompt.instance_variable_get(:@select_messages)
      assert_includes prompt.instance_variable_get(:@select_choices).last[prompt.instance_variable_get(:@select_initial_indices).last], "Renamed session"
    end
  end

  def test_session_picker_delete_action_deletes_selected_session
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      source = store.create
      conversation = Kward::Conversation.new
      source.attach(conversation)
      conversation.append_user("saved prompt")
      prompt = FakePrompt.new(["/session", "/exit"])
      test = self
      prompt.define_singleton_method(:select) do |_message, choices, title: "Sessions", custom: false, initial_index: 0, action_keys: {}, action_handlers: {}|
        test.assert_equal "Press d again to delete, Esc to cancel.", action_keys.fetch("d")[:confirm]
        result = action_handlers.fetch(action_keys.fetch("d")[:action]).call(choices.first)
        test.assert_equal [], result[:choices]
        nil
      end
      original_new = Kward::SessionTrash.method(:new)
      Kward::SessionTrash.define_singleton_method(:new) do |**_kwargs|
        Object.new.tap do |trash|
          trash.define_singleton_method(:delete) do |path|
            File.delete(path) if File.exist?(path)
            true
          end
        end
      end
      client = RecordingClient.new([])
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client, session_store: store)

      cli.interactive_loop

      refute File.exist?(source.path)
    ensure
      Kward::SessionTrash.define_singleton_method(:new, original_new) if original_new
    end
  end

  def test_git_diff_before_hook_can_deny_diff_view
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: FakePrompt.new([]), client: RecordingClient.new([]))
    cli.define_singleton_method(:run_lifecycle_hook) do |_name, **_kwargs|
      decision = Kward::Hooks::Decision.deny("No diff")
      Kward::Hooks::Manager::Result.new(event: nil, decision: decision, decisions: [decision], warnings: [], messages: [], payload: {})
    end

    result = cli.send(:git_diff_view, Dir.pwd, " M README.md")

    assert_equal "README.md", result[:path]
    assert_equal "Declined: No diff\n", result[:content]
  end

  def test_git_commit_before_hook_can_deny_commit
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: FakePrompt.new([]), client: RecordingClient.new([]))
    cli.define_singleton_method(:run_lifecycle_hook) do |_name, **_kwargs|
      decision = Kward::Hooks::Decision.deny("No commit")
      Kward::Hooks::Manager::Result.new(event: nil, decision: decision, decisions: [decision], warnings: [], messages: [], payload: {})
    end

    result = cli.send(:git_commit, Dir.pwd, "test")

    assert_equal false, result[:success]
    assert_equal "Declined: No commit", result[:output]
  end

  def test_session_export_before_hook_can_deny_export
    export_path = File.join(Dir.pwd, "tmp-cli-export-denied.md")
    prompt = FakePrompt.new([])
    conversation = Kward::Conversation.new(system_message: nil)
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: RecordingClient.new([]))
    cli.define_singleton_method(:run_lifecycle_hook) do |name, **_kwargs|
      decision = name == "session_export_before" ? Kward::Hooks::Decision.deny("No export") : Kward::Hooks::Decision.allow
      Kward::Hooks::Manager::Result.new(event: nil, decision: decision, decisions: [decision], warnings: [], messages: [], payload: {})
    end

    cli.send(:export_session, conversation, export_path)

    refute_path_exists export_path
    assert_includes prompt.output.join, "Declined: No export"
  ensure
    File.delete(export_path) if export_path && File.exist?(export_path)
  end

  def test_session_rename_emits_lifecycle_hook
    Dir.mktmpdir do |dir|
      store = Kward::SessionStore.new(config_dir: File.join(dir, "config"), cwd: dir)
      session = store.create
      prompt = FakePrompt.new([])
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: RecordingClient.new([]), session_store: store)
      cli.instance_variable_set(:@active_session, session)
      events = []
      cli.define_singleton_method(:run_lifecycle_hook) do |name, **kwargs|
        events << [name, kwargs[:session]&.path, kwargs[:payload]]
        decision = Kward::Hooks::Decision.allow
        Kward::Hooks::Manager::Result.new(event: nil, decision: decision, decisions: [decision], warnings: [], messages: [], payload: kwargs[:payload] || {})
      end

      cli.send(:rename_session, "Captain's log")

      assert_equal "session_rename", events.first[0]
      assert_equal session.path, events.first[1]
      assert_equal "Captain's log", events.first[2][:new_name]
    end
  end

  def test_export_renders_compaction_summary_content
    export_path = File.join(Dir.pwd, "tmp-cli-export.md")
    conversation = Kward::Conversation.new(system_message: nil)
    conversation.compact!("summary content", compaction_summary: true)
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: FakePrompt.new([]), client: RecordingClient.new([]))

    cli.send(:export_session, conversation, export_path)

    assert_includes File.read(export_path), "## Compactionsummary\n\nsummary content"
  ensure
    File.delete(export_path) if export_path && File.exist?(export_path)
  end

  def test_export_rejects_explicit_path_outside_workspace_or_session_directory
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      outside_path = File.join(Dir.mktmpdir, "session.md")
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: FakePrompt.new([]), client: RecordingClient.new([]), session_store: store)

      assert_raises(ArgumentError) { cli.send(:export_path, outside_path) }
    ensure
      FileUtils.remove_entry(File.dirname(outside_path)) if outside_path && File.exist?(File.dirname(outside_path))
    end
  end

  def test_compact_command_summarizes_context_before_next_turn
    Dir.mktmpdir do |config_dir|
      config_path = File.join(config_dir, "config.json")
      File.write(config_path, JSON.dump({ "compaction" => { "keep_recent_tokens" => 20 } }))
      prompt = FakePrompt.new(["hello with enough detail to compact", "second turn before compaction", "/compact focus on files", "again", "/exit"])
      client = RecordingClient.new(["reply", "second reply", "summary", "after"])
      agent = Kward::Agent.new(client: client, tool_registry: Kward::ToolRegistry.new(prompt: prompt))
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client)

      conversation = nil
      with_env("KWARD_CONFIG_PATH" => config_path) do
        conversation = cli.interactive_loop(agent: agent)
      end

      refute client.seen_messages.flatten.any? { |message| message.is_a?(Hash) && message[:content] == "/compact focus on files" }
      assert_includes client.seen_messages[2].last[:content], "Additional focus: focus on files"
      summary_message = client.seen_messages[3].find { |message| (message[:role] || message["role"]) == "compactionSummary" }
      assert summary_message
      assert_includes summary_message[:summary], "summary"
      assert_equal "again", client.seen_messages[3].last[:content]
      assert_equal "after", conversation.messages.last["content"]
      assert_includes prompt.output.join("\n"), "Compacted context:"
    end
  end

  def test_compact_command_reports_empty_context_without_calling_client
    prompt = FakePrompt.new(["/compact", "/exit"])
    client = RecordingClient.new([])
    agent = Kward::Agent.new(client: client, tool_registry: Kward::ToolRegistry.new(prompt: prompt))
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client)

    cli.interactive_loop(agent: agent)

    assert_empty client.seen_messages
    assert_includes prompt.output.join("\n"), "Nothing to compact"
  end

  def test_interactive_resume_can_select_recent_session
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      saved = store.create
      conversation = Kward::Conversation.new
      saved.attach(conversation)
      conversation.append_user("selected session")
      conversation.append_assistant("old reply")
      prompt = FakeSessionSelectPrompt.new(["/resume", "again", "/exit"], "selected session")
      client = RecordingClient.new(["new reply"])
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client, session_store: store)

      cli.interactive_loop

      assert_equal ["Session>"], prompt.select_messages
      assert_equal 1, prompt.select_choices.first.length
      assert_match(/\Aselected session — #{Regexp.escape(File.basename(saved.path))}\s+just now\z/, prompt.select_choices.first.first)
      assert_equal "selected session", client.seen_messages[0][1]["content"]
      assert_equal "again", client.seen_messages[0][3][:content]
    end
  end


  def test_fork_slash_command_creates_new_session_from_selected_prompt
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      session = store.create
      conversation = Kward::Conversation.new(system_message: nil)
      session.attach(conversation)
      conversation.append_user("keep this")
      conversation.append_assistant("kept reply")
      conversation.append_user("edit this prompt")
      conversation.append_assistant("future reply")
      prompt = FakeSessionSelectPrompt.new(["/resume #{session.path}", "/fork", "/exit"], "edit this prompt")
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: RecordingClient.new([]), session_store: store)

      cli.interactive_loop

      files = Dir.glob(File.join(store.session_dir, "*.jsonl"))
      assert_equal 2, files.length
      fork_path = (files - [session.path]).first
      fork_session, fork_conversation = store.load(fork_path)
      fork_messages = fork_conversation.messages.reject { |message| (message["role"] || message[:role]) == "system" }
      output = strip_ansi(prompt.output.join("\n"))

      assert_equal ["Fork>"], prompt.select_messages.last(1)
      assert_equal "Fork", prompt.select_titles.last
      assert_equal ["edit this prompt"], prompt.prefilled_inputs
      assert_equal ["keep this", "kept reply"], fork_messages.map { |message| message["content"] || message[:content] }
      assert_equal fork_session.leaf_id, fork_messages.last["id"]
      assert_includes output, "Forked session: #{fork_path}"
      refute_includes File.read(fork_path), "edit this prompt"
      refute_includes File.read(fork_path), "future reply"
      source = jsonl_records(session.path).find { |record| record["type"] == "session" }
      fork = jsonl_records(fork_path).find { |record| record["type"] == "session" }
      assert_equal source["id"], fork["parentId"]
    end
  end

  def test_fork_slash_command_without_composer_prefill_does_not_auto_run_selected_text
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      session = store.create
      conversation = Kward::Conversation.new(system_message: nil)
      session.attach(conversation)
      conversation.append_user("first prompt")
      prompt = FakeSessionSelectNoPrefillPrompt.new(["/resume #{session.path}", "/fork", "/exit"], "first prompt")
      client = RecordingClient.new(["should not be used"])
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client, session_store: store)

      cli.interactive_loop

      assert_empty client.seen_messages
      assert_includes prompt.output.join("\n"), "Selected prompt for editing:\nfirst prompt"
    end
  end

  def test_rewind_slash_command_selects_user_prompt_and_prefills_prompt
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      session = store.create
      conversation = Kward::Conversation.new(system_message: nil)
      session.attach(conversation)
      conversation.append_user("first prompt")
      conversation.append_assistant("first reply")
      conversation.append_user("edit this prompt")
      conversation.append_assistant("future reply")
      prompt = FakeSessionSelectPrompt.new(["/resume #{session.path}", "/rewind", "/exit"], "edit this prompt")
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: RecordingClient.new([]), session_store: store)

      cli.interactive_loop
      loaded_session, loaded_conversation = store.load(session.path)

      assert_equal ["Rewind>"], prompt.select_messages.last(1)
      assert_equal "Rewind", prompt.select_titles.last
      assert prompt.select_choices.last.all? { |choice| choice.include?("prompt") }
      assert prompt.select_choices.last.first.include?("Last prompt: edit this prompt")
      assert_equal ["edit this prompt"], prompt.prefilled_inputs
      assert_equal "first reply", loaded_conversation.messages.reject { |message| (message["role"] || message[:role]) == "system" }.last["content"]
      assert_equal loaded_session.leaf_id, loaded_conversation.messages.reject { |message| (message["role"] || message[:role]) == "system" }.last["id"]
    end
  end

  def test_rewind_slash_command_can_return_to_where_user_was
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      session = store.create
      conversation = Kward::Conversation.new(system_message: nil)
      session.attach(conversation)
      conversation.append_user("first prompt")
      conversation.append_assistant("first reply")
      conversation.append_user("edit this prompt")
      conversation.append_assistant("future reply")
      prompt = FakeSettingsPrompt.new(
        ["/resume #{session.path}", "/rewind", "/rewind", "/exit"],
        []
      )
      prompt.define_singleton_method(:select) do |message, choices, title: "Sessions", custom: false, initial_index: 0, **_kwargs|
        @select_messages << message
        @select_choices << choices
        @select_titles << title
        @select_initial_indices << initial_index
        choices.find { |choice| choice.include?("Return to where I was") } || choices.find { |choice| choice.include?("Last prompt: edit this prompt") }
      end
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: RecordingClient.new([]), session_store: store)

      cli.interactive_loop
      loaded_session, loaded_conversation = store.load(session.path)

      assert_equal ["edit this prompt"], prompt.prefilled_inputs
      assert_includes prompt.select_choices[1].first, "Return to where I was: future reply"
      assert_equal "future reply", loaded_conversation.messages.reject { |message| (message["role"] || message[:role]) == "system" }.last["content"]
      assert_equal loaded_session.leaf_id, loaded_conversation.messages.reject { |message| (message["role"] || message[:role]) == "system" }.last["id"]
    end
  end

  def test_rewind_slash_command_shows_only_user_prompts
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      session = store.create
      conversation = Kward::Conversation.new(system_message: nil)
      session.attach(conversation)
      conversation.append_user("root prompt")
      conversation.append_assistant({
        "role" => "assistant",
        "content" => nil,
        "tool_calls" => [tool_call("read_file", path: "README.md")]
      })
      conversation.append_tool(tool_call_id: "call_read_file", name: "read_file", content: "README contents")
      conversation.append_assistant("assistant reply")
      conversation.append_user("latest prompt")
      prompt = FakeSessionSelectPrompt.new(["/resume #{session.path}", "/rewind", "/exit"], "root prompt")
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: RecordingClient.new([]), session_store: store)

      cli.interactive_loop

      choices = prompt.select_choices.last
      assert_equal 2, choices.length
      assert choices.any? { |choice| choice.include?("root prompt") }
      assert choices.any? { |choice| choice.include?("latest prompt") }
      refute choices.any? { |choice| choice.include?("assistant reply") }
      refute choices.any? { |choice| choice.include?("README contents") }
      refute choices.any? { |choice| choice.include?("read_file") }
    end
  end

  def test_rewind_slash_command_shows_relative_timestamps
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      session = store.create
      conversation = Kward::Conversation.new(system_message: nil)
      session.attach(conversation)
      conversation.append_user("older prompt")
      older_entry = session.leaf_id
      conversation.append_assistant("older reply")
      conversation.append_user("newer prompt")
      newer_entry = session.leaf_id
      rewrite_session_timestamps(session.path, { older_entry => Time.now.utc - 14 * 60, newer_entry => Time.now.utc - 4 * 60 })
      prompt = FakeSessionSelectPrompt.new(["/resume #{session.path}", "/rewind", "/exit"], "older prompt")
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: RecordingClient.new([]), session_store: store)

      cli.interactive_loop

      choices = prompt.select_choices.last
      assert choices.any? { |choice| choice.include?("newer prompt") && choice.end_with?("4 min ago") }
      assert choices.any? { |choice| choice.include?("older prompt") && choice.end_with?("14 min ago") }
    end
  end

  def test_rewind_slash_command_uses_display_content_for_prefill
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      session = store.create
      conversation = Kward::Conversation.new(system_message: nil)
      session.attach(conversation)
      conversation.append_user("Plan this:\nfix bug\n", display_content: "/plan fix bug")
      conversation.append_assistant("future reply")
      prompt = FakeSessionSelectPrompt.new(["/resume #{session.path}", "/rewind", "/exit"], "/plan fix bug")
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: RecordingClient.new([]), session_store: store)

      cli.interactive_loop

      assert_equal ["/plan fix bug"], prompt.prefilled_inputs
      assert prompt.select_choices.last.any? { |choice| choice.include?("Last prompt: /plan fix bug") }
    end
  end

  def test_rewind_slash_command_without_composer_prefill_does_not_auto_run_selected_text
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      session = store.create
      conversation = Kward::Conversation.new(system_message: nil)
      session.attach(conversation)
      conversation.append_user("first prompt")
      prompt = FakeSessionSelectNoPrefillPrompt.new(["/resume #{session.path}", "/rewind", "/exit"], "first prompt")
      client = RecordingClient.new(["should not be used"])
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client, session_store: store)

      cli.interactive_loop

      assert_empty client.seen_messages
      assert_includes prompt.output.join("\n"), "Selected prompt for editing:\nfirst prompt"
    end
  end

  def test_tree_slash_command_selects_user_entry_and_prefills_prompt
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      session = store.create
      conversation = Kward::Conversation.new(system_message: nil)
      session.attach(conversation)
      conversation.append_user("first prompt")
      conversation.append_assistant("first reply")
      conversation.append_user("edit this prompt")
      conversation.append_assistant("future reply")
      prompt = FakeSessionSelectPrompt.new(["/resume #{session.path}", "/tree", "/exit"], "edit this prompt")
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: RecordingClient.new([]), session_store: store)

      cli.interactive_loop
      loaded_session, loaded_conversation = store.load(session.path)

      assert_equal ["Tree>"], prompt.select_messages.last(1)
      assert_equal prompt.select_choices.last.length - 1, prompt.select_initial_indices.last
      assert_equal ["edit this prompt"], prompt.prefilled_inputs
      assert_equal "first reply", loaded_conversation.messages.reject { |message| (message["role"] || message[:role]) == "system" }.last["content"]
      assert_equal loaded_session.leaf_id, loaded_conversation.messages.reject { |message| (message["role"] || message[:role]) == "system" }.last["id"]
    end
  end

  def test_tree_slash_command_loads_tree_with_spinner_before_opening_picker
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      session = store.create
      conversation = Kward::Conversation.new(system_message: nil)
      session.attach(conversation)
      conversation.append_user("first prompt")
      conversation.append_assistant("first reply")
      prompt = BusySelectPrompt.new(["/resume #{session.path}", "/tree", "/exit"])
      prompt.define_singleton_method(:select) do |message, choices, title: "Sessions", custom: false, initial_index: 0, **_kwargs|
        events << [:select, message, title, initial_index]
        choices.first
      end
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: RecordingClient.new([]), session_store: store)

      cli.interactive_loop

      tree_select_index = prompt.events.index { |event| event[0] == :select && event[1] == "Tree>" }
      loading_indices = prompt.events.each_index.select { |index| prompt.events[index] == [:begin_busy_input, "You>", "loading"] }
      tree_loading_index = loading_indices.find { |index| tree_select_index && index < tree_select_index }
      tree_finish_index = prompt.events[tree_loading_index..tree_select_index]&.index([:finish_busy_input])
      assert tree_select_index
      assert tree_loading_index
      assert tree_finish_index
      assert_operator tree_loading_index, :<, tree_select_index
      assert_operator tree_loading_index + tree_finish_index, :<, tree_select_index
    end
  end

  def test_tree_slash_command_applies_selection_with_loading_spinner
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      session = store.create
      conversation = Kward::Conversation.new(system_message: nil)
      session.attach(conversation)
      conversation.append_user("first prompt")
      conversation.append_assistant("first reply")
      conversation.append_user("edit this prompt")
      prompt = BusySelectPrompt.new(["/resume #{session.path}", "/tree", "/exit"])
      prompt.define_singleton_method(:select) do |message, choices, title: "Sessions", custom: false, initial_index: 0, **_kwargs|
        events << [:select, message, title, initial_index]
        choices.find { |choice| choice.include?("edit this prompt") } || choices.first
      end
      prompt.define_singleton_method(:prefill_input) do |value|
        events << [:prefill_input, value]
        super(value)
      end
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: RecordingClient.new([]), session_store: store)

      cli.interactive_loop

      tree_select_index = prompt.events.index { |event| event[0] == :select && event[1] == "Tree>" }
      loading_indices = prompt.events.each_index.select { |index| prompt.events[index] == [:begin_busy_input, "You>", "loading"] }
      tree_loading_index = loading_indices.find { |index| tree_select_index && index > tree_select_index }
      tree_finish_index = prompt.events[tree_loading_index..]&.index([:finish_busy_input])
      prefill_index = prompt.events.index([:prefill_input, "edit this prompt"])
      assert tree_select_index
      assert tree_loading_index
      assert tree_finish_index
      assert prefill_index
      assert_operator tree_select_index, :<, tree_loading_index
      assert_operator tree_loading_index + tree_finish_index, :<, prefill_index
    end
  end

  def test_tree_slash_command_uses_display_content_for_prefill
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      session = store.create
      conversation = Kward::Conversation.new(system_message: nil)
      session.attach(conversation)
      conversation.append_user("Plan this:\nfix bug\n", display_content: "/plan fix bug")
      conversation.append_assistant("future reply")
      prompt = FakeSessionSelectPrompt.new(["/resume #{session.path}", "/tree", "/exit"], "/plan fix bug")
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: RecordingClient.new([]), session_store: store)

      cli.interactive_loop

      assert_equal ["/plan fix bug"], prompt.prefilled_inputs
      assert prompt.select_choices.last.any? { |choice| choice.include?("user: /plan fix bug") }
    end
  end

  def test_tree_slash_command_starts_cursor_at_current_tree_position
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      session = store.create
      conversation = Kward::Conversation.new(system_message: nil)
      session.attach(conversation)
      conversation.append_user("first prompt")
      conversation.append_assistant("first reply")
      first_reply_id = session.leaf_id
      conversation.append_user("future prompt")
      conversation.append_assistant("future reply")
      session.branch(first_reply_id)
      prompt = FakeSessionSelectPrompt.new(["/resume #{session.path}", "/tree", "/exit"], "first reply")
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: RecordingClient.new([]), session_store: store)

      cli.interactive_loop

      choices = prompt.select_choices.last
      assert_equal choices.index { |choice| choice.include?("first reply") }, prompt.select_initial_indices.last
    end
  end

  def test_tree_slash_command_selects_assistant_entry_without_prefill_or_autorun
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      session = store.create
      conversation = Kward::Conversation.new(system_message: nil)
      session.attach(conversation)
      conversation.append_user("first prompt")
      conversation.append_assistant("visible reply")
      conversation.append_user("future prompt")
      prompt = FakeSessionSelectPrompt.new(["/resume #{session.path}", "/tree", "/exit"], "visible reply")
      client = RecordingClient.new(["should not be used"])
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client, session_store: store)

      cli.interactive_loop
      loaded_session, loaded_conversation = store.load(session.path)

      choices = prompt.select_choices.last
      assert choices.any? { |choice| choice.include?("user: first prompt") }
      assert choices.any? { |choice| choice.include?("assistant: visible reply") }
      assert_empty prompt.prefilled_inputs
      assert_empty client.seen_messages
      refute_includes prompt.output.join("
"), "Only user turns can be edited from the session tree."
      assert_equal "visible reply", loaded_conversation.messages.reject { |message| (message["role"] || message[:role]) == "system" }.last["content"]
      assert_equal loaded_session.leaf_id, loaded_conversation.messages.reject { |message| (message["role"] || message[:role]) == "system" }.last["id"]
    end
  end

  def test_tree_slash_command_uses_pi_style_active_path_branch_prefixes_and_tool_results
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      session = store.create
      conversation = Kward::Conversation.new(system_message: nil)
      session.attach(conversation)
      conversation.append_user("root prompt")
      conversation.append_assistant("root reply")
      root_reply_id = session.leaf_id
      conversation.append_user("active branch")
      conversation.append_assistant({
        "role" => "assistant",
        "content" => nil,
        "tool_calls" => [tool_call("read_file", path: "README.md", offset: 2, limit: 3)]
      })
      conversation.append_tool(tool_call_id: "call_read_file", name: "read_file", content: "README contents")
      active_leaf_id = session.leaf_id
      session.branch(root_reply_id)
      conversation.append_user("side branch")
      conversation.append_assistant("side reply")
      session.branch(active_leaf_id)
      prompt = FakeSessionSelectPrompt.new(["/resume #{session.path}", "/tree", "/exit"], "active branch")
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: RecordingClient.new([]), session_store: store)

      cli.interactive_loop

      choices = prompt.select_choices.last
      active_choice = choices.find { |choice| choice.include?("active branch") }
      side_choice = choices.find { |choice| choice.include?("side branch") }
      refute choices.any? { |choice| choice.include?("assistant: ") && choice.include?("(no content)") }
      assert choices.any? { |choice| choice.include?("[read: README.md:2-4]") }
      root_choice = choices.find { |choice| choice.include?("root prompt") }
      assert root_choice.start_with?("• user: root prompt"), root_choice
      assert_includes active_choice, "      ├⊟ • user: active branch"
      assert_includes side_choice, "      └⊟ user: side branch"
      assert_operator choices.index(active_choice), :<, choices.index(side_choice)
    end
  end

  def test_tree_slash_command_without_composer_prefill_does_not_auto_run_selected_text
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      session = store.create
      conversation = Kward::Conversation.new(system_message: nil)
      session.attach(conversation)
      conversation.append_user("first prompt")
      conversation.append_assistant("first reply")
      conversation.append_user("edit this prompt")
      prompt = FakeSessionSelectNoPrefillPrompt.new(["/resume #{session.path}", "/tree", "/exit"], "edit this prompt")
      client = RecordingClient.new(["should not be used"])
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client, session_store: store)

      cli.interactive_loop

      assert_empty client.seen_messages
      assert_includes prompt.output.join("
"), "Selected text for editing:
edit this prompt"
    end
  end

  def test_resume_picker_shows_cloned_sessions_newest_first
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      source = store.create
      conversation = Kward::Conversation.new(system_message: nil)
      source.attach(conversation)
      conversation.append_user("root session")
      clone, clone_conversation = store.create_independent_from_conversation(conversation, parent_session: source)
      clone.rename("clone session")
      clone_conversation.append_user("clone session")
      old_time = Time.now - 60
      set_last_activity_time = lambda do |path, timestamp|
        lines = File.readlines(path, chomp: true)
        index = lines.rindex { |line| JSON.parse(line)["type"] == "message" }
        record = JSON.parse(lines[index])
        record["timestamp"] = timestamp.utc.iso8601(3)
        lines[index] = JSON.generate(record)
        File.write(path, lines.join("\n") + "\n")
      end
      set_last_activity_time.call(source.path, old_time)
      set_last_activity_time.call(clone.path, Time.now)
      prompt = FakeSessionSelectPrompt.new(["/resume", "/exit"], "clone session")
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: RecordingClient.new([]), session_store: store)

      cli.interactive_loop

      assert_equal ["Session>"], prompt.select_messages
      assert_match(/\Aroot session — #{Regexp.escape(File.basename(source.path))}\s+1 min ago\z/, prompt.select_choices.first.first)
      assert prompt.select_choices.first.any? { |choice| choice.match?(/\A└─ clone session — #{Regexp.escape(File.basename(clone.path))}\s+just now\z/) }
    end
  end

  def test_resume_picker_deletes_empty_unnamed_sessions
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      empty = store.create
      saved = store.create
      conversation = Kward::Conversation.new(system_message: nil)
      saved.attach(conversation)
      conversation.append_user("saved session")
      prompt = FakeSessionSelectPrompt.new(["/resume", "/exit"], "saved session")
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: RecordingClient.new([]), session_store: store)

      cli.interactive_loop

      assert_equal ["Session>"], prompt.select_messages
      assert prompt.select_choices.first.any? { |choice| choice.match?(/\Asaved session — #{Regexp.escape(File.basename(saved.path))}\s+just now\z/) }
      refute_path_exists empty.path
    end
  end

  def test_resume_picker_reports_no_saved_sessions_when_only_empty_unnamed_session_exists
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      prompt = FakePrompt.new(["/resume", "/exit"])
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: RecordingClient.new([]), session_store: store)

      cli.interactive_loop

      assert_empty Dir.glob(File.join(store.session_dir, "*.jsonl"))
      assert_empty prompt.output.grep(/Recent sessions:/)
      assert_includes prompt.output.join("\n"), "No saved sessions found."
    end
  end

  def test_resume_picker_shows_renamed_active_session_immediately
    Dir.mktmpdir do |config_dir|
      store = Kward::SessionStore.new(config_dir: config_dir, cwd: Dir.pwd)
      saved = store.create
      conversation = Kward::Conversation.new
      saved.attach(conversation)
      conversation.append_user("selected session")
      conversation.append_assistant("old reply")
      prompt = FakeSessionSelectPrompt.new(["/resume #{saved.path}", "/session name Useful", "/resume", "/exit"], "Useful")
      client = RecordingClient.new([])
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client, session_store: store)

      cli.interactive_loop

      assert_equal ["Session>"], prompt.select_messages
      assert prompt.select_choices.first.any? { |choice| choice.match?(/\AUseful — .*\s+just now\z/) }
    end
  end

  def test_interactive_prompt_slash_command_expands_template
    Dir.mktmpdir do |dir|
      Dir.mktmpdir do |home|
        File.write(File.join(dir, "config.json"), JSON.dump({}))
        prompts_dir = File.join(dir, "prompts")
        FileUtils.mkdir_p(prompts_dir)
        File.write(File.join(prompts_dir, "plan.md"), "---\ndescription: Plan work.\nargument-hint: <task>\n---\nPlan this:\n$ARGUMENTS\n")
        prompt = FakePrompt.new(["/plan fix bug", "/exit"])
        client = RecordingClient.new(["planned"])

        with_env("HOME" => home, "KWARD_CONFIG_PATH" => File.join(dir, "config.json")) do
          agent = Kward::Agent.new(client: client, tool_registry: Kward::ToolRegistry.new(prompt: prompt))
          cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client)

          cli.interactive_loop(agent: agent)
        end

        assert_equal "Plan this:\nfix bug\n", client.seen_messages[0][1][:content]
      end
    end
  end

  def test_interactive_prompt_slash_command_persists_original_display_content_and_session_name
    Dir.mktmpdir do |dir|
      Dir.mktmpdir do |home|
        File.write(File.join(dir, "config.json"), JSON.dump({}))
        prompts_dir = File.join(dir, "prompts")
        FileUtils.mkdir_p(prompts_dir)
        File.write(File.join(prompts_dir, "plan.md"), "Plan this:\n$ARGUMENTS\n")
        store = Kward::SessionStore.new(config_dir: dir, cwd: Dir.pwd)
        prompt = FakePrompt.new(["/plan fix bug", "/exit"])
        client = RecordingClient.new(["planned"])

        with_env("HOME" => home, "KWARD_CONFIG_PATH" => File.join(dir, "config.json")) do
          cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client, session_store: store)

          cli.interactive_loop
        end

        user_message = jsonl_records(Dir.glob(File.join(store.session_dir, "*.jsonl")).first).find do |record|
          record["type"] == "message" && record.dig("message", "role") == "user"
        end["message"]
        assert_equal "Plan this:\nfix bug\n", user_message["content"]
        assert_equal "/plan fix bug", user_message["display_content"]
        assert_equal "/plan fix bug", store.recent.first.name
        assert_equal "/plan fix bug", store.recent.first.first_message
      end
    end
  end

  def test_interactive_first_plain_input_persists_session_name
    Dir.mktmpdir do |dir|
      store = Kward::SessionStore.new(config_dir: dir, cwd: Dir.pwd)
      prompt = FakePrompt.new(["Something is not working", "/exit"])
      client = RecordingClient.new(["done"])
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client, session_store: store)

      cli.interactive_loop

      assert_equal "Something is not working", store.recent.first.name
    end
  end

  def test_prompt_interface_slash_command_displays_original_input
    Dir.mktmpdir do |dir|
      Dir.mktmpdir do |home|
        File.write(File.join(dir, "config.json"), JSON.dump({}))
        prompts_dir = File.join(dir, "prompts")
        FileUtils.mkdir_p(prompts_dir)
        File.write(File.join(prompts_dir, "plan.md"), "Plan this:\n$ARGUMENTS\n")
        prompt = BusyPrompt.new(["/plan fix bug", "/exit"])
        client = RecordingClient.new(["planned"])

        with_env("HOME" => home, "KWARD_CONFIG_PATH" => File.join(dir, "config.json")) do
          agent = Kward::Agent.new(client: client, tool_registry: Kward::ToolRegistry.new(prompt: prompt))
          cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client)

          cli.interactive_loop(agent: agent)
        end

        output = strip_ansi(prompt.output.join("\n"))
        assert_includes output, "You> /plan fix bug"
        refute_includes output, "Plan this:"
        assert_equal "Plan this:\nfix bug\n", client.seen_messages[0][1][:content]
      end
    end
  end

  def test_transcript_and_export_show_original_slash_command_display_content
    conversation = Kward::Conversation.new(system_message: nil)
    conversation.append_user("Plan this:\nfix bug\n", display_content: "/plan fix bug")
    conversation.append_assistant("planned")
    prompt = FakePrompt.new([])
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: RecordingClient.new([]))

    cli.send(:render_conversation_transcript, conversation)
    transcript_output = strip_ansi(prompt.output.join("\n"))
    assert_includes transcript_output, "You> /plan fix bug"
    refute_includes transcript_output, "Plan this:"

    markdown = cli.send(:markdown_transcript, conversation)
    assert_includes markdown, "/plan fix bug"
    refute_includes markdown, "Plan this:"
  end

  def test_transcript_replay_renders_structured_user_image_parts
    original_term_program = ENV["TERM_PROGRAM"]
    original_kitty_window_id = ENV["KITTY_WINDOW_ID"]
    ENV.delete("TERM_PROGRAM")
    ENV["KITTY_WINDOW_ID"] = "1"
    data = Base64.strict_encode64("png bytes")
    conversation = Kward::Conversation.new(
      system_message: nil,
      messages: [
        {
          role: "user",
          content: [
            { type: "text", text: "look\ndata:image/png;base64,#{data}" },
            { type: "image", media_type: "image/png", data: data }
          ]
        }
      ]
    )
    prompt = FakePrompt.new([])
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: RecordingClient.new([]))

    cli.send(:render_conversation_transcript, conversation)

    output = prompt.output.join("\n")
    stripped = strip_ansi(output)
    assert_includes stripped, "You> look"
    refute_includes stripped, "You> look\ndata:image/png;base64"
    assert_includes output, "[image] pasted image · image/png · 9 B"
    assert_includes output, "\e_Ga=T,f=100,t=d,c=40,q=2,m=0;#{data}\e\\"
  ensure
    original_term_program ? ENV["TERM_PROGRAM"] = original_term_program : ENV.delete("TERM_PROGRAM")
    original_kitty_window_id ? ENV["KITTY_WINDOW_ID"] = original_kitty_window_id : ENV.delete("KITTY_WINDOW_ID")
  end

  def test_interactive_prompt_slash_command_allows_empty_arguments
    Dir.mktmpdir do |dir|
      Dir.mktmpdir do |home|
        File.write(File.join(dir, "config.json"), JSON.dump({}))
        prompts_dir = File.join(dir, "prompts")
        FileUtils.mkdir_p(prompts_dir)
        File.write(File.join(prompts_dir, "plan.md"), "Plan this:\n$ARGUMENTS\n")
        prompt = FakePrompt.new(["/plan", "/exit"])
        client = RecordingClient.new(["planned"])

        with_env("HOME" => home, "KWARD_CONFIG_PATH" => File.join(dir, "config.json")) do
          agent = Kward::Agent.new(client: client, tool_registry: Kward::ToolRegistry.new(prompt: prompt))
          cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client)

          cli.interactive_loop(agent: agent)
        end

        assert_equal "Plan this:\n\n", client.seen_messages[0][1][:content]
      end
    end
  end

  def test_one_shot_does_not_expand_prompt_slash_command
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "config.json"), JSON.dump({}))
      prompts_dir = File.join(dir, "prompts")
      FileUtils.mkdir_p(prompts_dir)
      File.write(File.join(prompts_dir, "plan.md"), "Plan this:\n$ARGUMENTS\n")
      client = RecordingClient.new(["ok"])
      cli = Kward::CLI.new(argv: ["/plan fix bug"], stdin: FakeInput.new("", tty: true), client: client)

      with_env("KWARD_CONFIG_PATH" => File.join(dir, "config.json")) do
        cli.one_shot("/plan fix bug")
      end

      assert_equal "/plan fix bug", client.seen_messages[0][1][:content]
    end
  end

  def test_non_tui_slash_command_selection_expands_template
    Dir.mktmpdir do |dir|
      Dir.mktmpdir do |home|
        File.write(File.join(dir, "config.json"), JSON.dump({}))
        prompts_dir = File.join(dir, "prompts")
        FileUtils.mkdir_p(prompts_dir)
        File.write(File.join(prompts_dir, "plan.md"), "Plan this:\n$ARGUMENTS\n")
        prompt = FakeSelectPrompt.new(["/p", "/exit"])
        client = RecordingClient.new(["planned"])

        with_env("HOME" => home, "KWARD_CONFIG_PATH" => File.join(dir, "config.json")) do
          agent = Kward::Agent.new(client: client, tool_registry: Kward::ToolRegistry.new(prompt: prompt))
          cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client)

          cli.interactive_loop(agent: agent)
        end

        assert_equal "Plan this:\n\n", client.seen_messages[0][1][:content]
        assert_equal ["Slash command>"], prompt.select_messages
      end
    end
  end

  def test_interactive_loop_redraw_command_refreshes_prompt
    prompt = FakePrompt.new(["/redraw", "/exit"])
    client = RecordingClient.new([])
    agent = Kward::Agent.new(client: client, tool_registry: Kward::ToolRegistry.new(prompt: prompt))
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client)

    cli.interactive_loop(agent: agent)

    assert_equal 1, prompt.redraw_count
    assert_empty client.seen_messages
  end

  def test_interactive_loop_exits_when_prompt_returns_nil
    prompt = FakePrompt.new([nil])
    client = RecordingClient.new([])
    agent = Kward::Agent.new(client: client, tool_registry: Kward::ToolRegistry.new(prompt: prompt))
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client)

    conversation = cli.interactive_loop(agent: agent)

    assert_empty client.seen_messages
    assert_equal Kward::Conversation.new.messages, conversation.messages
  end

  def test_interactive_turn_displays_pasted_image
    path = "kward_user_transcript.png"
    original_term_program = ENV["TERM_PROGRAM"]
    original_kitty_window_id = ENV["KITTY_WINDOW_ID"]
    ENV.delete("TERM_PROGRAM")
    ENV["KITTY_WINDOW_ID"] = "1"
    File.binwrite(path, "png bytes")
    prompt = FakePrompt.new([])
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([]))

    cli.send(:print_user_transcript, "look #{path}")

    assert_includes strip_ansi(prompt.output.join("\n")), "You> look #{path}"
    assert_includes prompt.output.join("\n"), "[image] #{path} · image/png · 9 B"
    assert_includes prompt.output.join("\n"), "\e_Ga=T,f=100,t=d,c=40,q=2,m=0;#{Base64.strict_encode64("png bytes")}\e\\"
  ensure
    original_term_program ? ENV["TERM_PROGRAM"] = original_term_program : ENV.delete("TERM_PROGRAM")
    original_kitty_window_id ? ENV["KITTY_WINDOW_ID"] = original_kitty_window_id : ENV.delete("KITTY_WINDOW_ID")
    File.delete(path) if path && File.exist?(path)
  end

  def test_user_transcript_uses_display_input_for_hidden_attachment
    path = "kward_hidden_transcript.png"
    original_term_program = ENV["TERM_PROGRAM"]
    original_kitty_window_id = ENV["KITTY_WINDOW_ID"]
    ENV.delete("TERM_PROGRAM")
    ENV["KITTY_WINDOW_ID"] = "1"
    File.binwrite(path, "png bytes")
    prompt = FakePrompt.new([])
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([]))

    cli.send(:print_user_transcript, "look\n#{path}", display_input: "look")

    output = prompt.output.join("\n")
    stripped = strip_ansi(output)
    assert_includes stripped, "You> look"
    refute_includes stripped, "You> look\n#{path}"
    assert_includes output, "[image] #{path} · image/png · 9 B"
    assert_includes output, "\e_Ga=T,f=100,t=d,c=40,q=2,m=0;#{Base64.strict_encode64("png bytes")}\e\\"
  ensure
    original_term_program ? ENV["TERM_PROGRAM"] = original_term_program : ENV.delete("TERM_PROGRAM")
    original_kitty_window_id ? ENV["KITTY_WINDOW_ID"] = original_kitty_window_id : ENV.delete("KITTY_WINDOW_ID")
    File.delete(path) if path && File.exist?(path)
  end

  def test_user_transcript_hides_data_url_text_and_renders_image_escape
    original_term_program = ENV["TERM_PROGRAM"]
    original_kitty_window_id = ENV["KITTY_WINDOW_ID"]
    ENV.delete("TERM_PROGRAM")
    ENV["KITTY_WINDOW_ID"] = "1"
    data = Base64.strict_encode64("png bytes")
    prompt = FakePrompt.new([])
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([]))

    cli.send(:print_user_transcript, "look\ndata:image/png;base64,#{data}", display_input: "look")

    output = prompt.output.join("\n")
    stripped = strip_ansi(output)
    assert_includes stripped, "You> look"
    refute_includes stripped, "You> look\ndata:image/png;base64"
    assert_includes output, "[image] pasted image · image/png · 9 B"
    assert_includes output, "\e_Ga=T,f=100,t=d,c=40,q=2,m=0;#{data}\e\\"
  ensure
    original_term_program ? ENV["TERM_PROGRAM"] = original_term_program : ENV.delete("TERM_PROGRAM")
    original_kitty_window_id ? ENV["KITTY_WINDOW_ID"] = original_kitty_window_id : ENV.delete("KITTY_WINDOW_ID")
  end

  def test_user_transcript_skips_image_escape_without_supported_terminal
    path = "kward_unsupported_transcript.png"
    original_term = ENV["TERM"]
    original_term_program = ENV["TERM_PROGRAM"]
    original_kitty_window_id = ENV["KITTY_WINDOW_ID"]
    ENV["TERM"] = "xterm-256color"
    ENV.delete("TERM_PROGRAM")
    ENV.delete("KITTY_WINDOW_ID")
    File.binwrite(path, "png bytes")
    prompt = FakePrompt.new([])
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([]))

    cli.send(:print_user_transcript, "look #{path}")

    output = prompt.output.join("\n")
    assert_includes output, "[image] #{path} · image/png · 9 B"
    refute_includes output, "\e_G"
    refute_includes output, "\e]1337;File="
  ensure
    original_term ? ENV["TERM"] = original_term : ENV.delete("TERM")
    original_term_program ? ENV["TERM_PROGRAM"] = original_term_program : ENV.delete("TERM_PROGRAM")
    original_kitty_window_id ? ENV["KITTY_WINDOW_ID"] = original_kitty_window_id : ENV.delete("KITTY_WINDOW_ID")
    File.delete(path) if path && File.exist?(path)
  end

  def test_composer_attachment_badges_reports_missing_image
    prompt = FakePrompt.new([])
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([]))

    badges = cli.send(:composer_attachment_badges, "look Screenshot 2099-01-01 at 12.00.00.png")

    assert_equal ["[image?] Screenshot 2099-01-01 at 12.00.00.png not found"], badges
  end

  def test_interactive_turn_returns_prompt_queued_during_streaming
    input, writer = IO.pipe
    output = StringIO.new
    prompt = Kward::PromptInterface.new(input: input, output: output)
    client = StreamingRecordingClient.new(["reply 1"])
    agent = Kward::Agent.new(client: client, tool_registry: Kward::ToolRegistry.new(prompt: prompt))
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client)

    writer_thread = Thread.new do
      sleep 0.03
      writer.write("second\r")
      writer.close
    end

    queued = cli.send(:run_interactive_turn, agent, "first")

    assert_includes strip_ansi(output.string), "You> first"
    assert_equal ["second"], queued
    assert_equal "first", client.seen_messages[0][1][:content]
  ensure
    writer_thread&.join
    input&.close unless input&.closed?
  end

  def test_settings_returns_to_changed_interface_option
    Dir.mktmpdir do |config_dir|
      config_path = File.join(config_dir, "config.json")
      File.write(config_path, JSON.dump({ "editor" => { "mode" => "modern" } }))
      prompt = FakeSettingsPrompt.new(
        ["/settings", "/exit"],
        ["Interface", "Editor mode (modern)", "vibe", "Back", "Done"]
      )
      client = RecordingClient.new([])
      agent = Kward::Agent.new(client: client, tool_registry: Kward::ToolRegistry.new(prompt: prompt))
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client)

      with_env("KWARD_CONFIG_PATH" => config_path) do
        cli.interactive_loop(agent: agent)
      end

      interface_indices = prompt.select_messages.each_index.select { |index| prompt.select_messages[index] == "Interface" }
      assert_equal 2, interface_indices.length
      changed_menu_index = interface_indices.last
      changed_choices = prompt.select_choices[changed_menu_index]
      assert_includes changed_choices[prompt.select_initial_indices[changed_menu_index]], "Editor mode"
      assert_equal prompt.select_choices.first.index("Interface"), prompt.select_initial_indices.last
    end
  end

  def test_login_slash_command_selects_openai_provider_without_calling_client
    prompt = FakeSettingsPrompt.new(["/login", "/exit"], ["Subscription / OAuth", "ChatGPT"])
    client = RecordingClient.new([])
    agent = Kward::Agent.new(client: client, tool_registry: Kward::ToolRegistry.new(prompt: prompt))
    cli = RecordingLoginCLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client)

    cli.interactive_loop(agent: agent)

    assert_equal ["openai"], cli.login_providers
    assert_equal ["API key", "Subscription / OAuth"], prompt.select_choices.first
    assert_equal "Login", prompt.select_titles.first
    assert_empty client.seen_messages
  end

  def test_login_slash_command_shows_running_spinner_after_provider_selection
    prompt = BusySelectPrompt.new(["/login", "/exit"], selections: ["Subscription / OAuth", "ChatGPT"])
    client = RecordingClient.new([])
    agent = Kward::Agent.new(client: client, tool_registry: Kward::ToolRegistry.new(prompt: prompt))
    cli = RecordingLoginCLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client)

    cli.interactive_loop(agent: agent)

    running_index = prompt.events.index([:begin_busy_input, "You>", "running"])
    assert running_index
    finish_after_running = prompt.events[running_index..].index([:finish_busy_input])
    assert finish_after_running
    assert_equal ["openai"], cli.login_providers
    assert_empty client.seen_messages
  end

  def test_login_slash_command_selects_github_provider_without_calling_client
    prompt = FakeSettingsPrompt.new(["/login", "/exit"], ["Subscription / OAuth", "GitHub Copilot"])
    client = RecordingClient.new([])
    agent = Kward::Agent.new(client: client, tool_registry: Kward::ToolRegistry.new(prompt: prompt))
    cli = RecordingLoginCLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client)

    cli.interactive_loop(agent: agent)

    assert_equal ["copilot"], cli.login_providers
    assert_empty client.seen_messages
  end

  def test_login_slash_command_reports_failure_and_continues_session
    prompt = FakeSettingsPrompt.new(["/login", "/status", "/exit"], ["Subscription / OAuth", "ChatGPT"])
    client = RecordingClient.new([])
    agent = Kward::Agent.new(client: client, tool_registry: Kward::ToolRegistry.new(prompt: prompt))
    cli = RecordingLoginCLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client, fail_login: true)

    cli.interactive_loop(agent: agent)

    output = prompt.output.join("\n")
    assert_includes output, "Login error: OAuth timed out"
    assert_includes output, "Kward status"
    assert_empty client.seen_messages
  end

  def test_status_slash_command_prints_status_without_calling_client
    prompt = FakePrompt.new(["/status", "/exit"])
    client = RecordingClient.new([])
    agent = Kward::Agent.new(client: client, tool_registry: Kward::ToolRegistry.new(prompt: prompt))
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client)

    cli.interactive_loop(agent: agent)

    assert_includes prompt.output.join("\n"), "Kward status"
    assert_includes prompt.output.join("\n"), "Auto-compaction reserve:"
    assert_empty client.seen_messages
  end

  def test_status_shows_auto_compaction_disabled
    Dir.mktmpdir do |config_dir|
      config_path = File.join(config_dir, "config.json")
      File.write(config_path, JSON.dump({ "compaction" => { "enabled" => false } }))

      prompt = FakePrompt.new(["/status", "/exit"])
      client = RecordingClient.new([])
      agent = Kward::Agent.new(client: client, tool_registry: Kward::ToolRegistry.new(prompt: prompt))
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client)

      with_env("KWARD_CONFIG_PATH" => config_path) do
        cli.interactive_loop(agent: agent)
      end

      assert_includes prompt.output.join("\n"), "Auto-compaction: disabled"
    end
  end

  def test_model_slash_command_shows_loading_spinner_before_overlay
    Dir.mktmpdir do |config_dir|
      config_path = File.join(config_dir, "config.json")
      File.write(config_path, JSON.dump({}))
      prompt = BusySelectPrompt.new(["/model", "/exit"])
      client = SlowModelsClient.new([])
      agent = Kward::Agent.new(client: client, tool_registry: Kward::ToolRegistry.new(prompt: prompt))
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client)

      with_env("KWARD_CONFIG_PATH" => config_path) do
        cli.interactive_loop(agent: agent)
      end

      loading_index = prompt.events.index([:begin_busy_input, "You>", "loading"])
      assert loading_index
      finish_after_loading = prompt.events[loading_index..].index([:finish_busy_input])
      assert finish_after_loading
      assert_equal ["Default model"], prompt.select_messages
    end
  end

  def test_compact_slash_command_keeps_busy_composer_visible_while_running
    Dir.mktmpdir do |config_dir|
      config_path = File.join(config_dir, "config.json")
      File.write(config_path, JSON.dump({ "compaction" => { "keep_recent_tokens" => 20 } }))
      prompt = BusyPrompt.new(["hello with enough detail to compact", "second turn before compaction", "/compact focus", "/exit"])
      client = RecordingClient.new(["reply", "second reply", "summary"])
      agent = Kward::Agent.new(client: client, tool_registry: Kward::ToolRegistry.new(prompt: prompt))
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client)

      with_env("KWARD_CONFIG_PATH" => config_path) do
        cli.interactive_loop(agent: agent)
      end

      compacting_index = prompt.events.index([:begin_busy_input, "You>", "compacting"])
      assert compacting_index
      finish_after_compacting = prompt.events[compacting_index..].index([:finish_busy_input])
      assert finish_after_compacting
      assert_includes prompt.output.join("\n"), "Compacted context:"
    end
  end

  def test_piped_prompt_reads_non_tty_input
    cli = Kward::CLI.new(stdin: FakeInput.new("hello from stdin\n", tty: false), client: FakeClient.new([]))

    assert_equal "hello from stdin", cli.piped_prompt
  end

  def test_piped_prompt_ignores_tty_input
    cli = Kward::CLI.new(stdin: FakeInput.new("ignored", tty: true), client: FakeClient.new([]))

    assert_equal "", cli.piped_prompt
  end

  def test_reload_plugins_updates_footer_renderer
    Dir.mktmpdir do |home|
      plugins_dir = File.join(home, ".kward", "plugins")
      plugin_path = File.join(plugins_dir, "footer.rb")
      FileUtils.mkdir_p(plugins_dir)
      File.write(plugin_path, <<~'RUBY')
        Kward.plugin do |plugin|
          plugin.footer do |_ctx|
            "footer=v1"
          end
        end
      RUBY

      with_env("HOME" => home, "KWARD_CONFIG_PATH" => nil) do
        cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: FakePrompt.new([]), client: FakeClient.new([]))
        footer = cli.send(:prompt_footer_renderer)
        conversation = Kward::Conversation.new(plugin_registry: cli.send(:plugin_registry))

        assert_equal "footer=v1", footer.call

        File.write(plugin_path, <<~'RUBY')
          Kward.plugin do |plugin|
            plugin.footer do |_ctx|
              "footer=v2"
            end
          end
        RUBY
        cli.send(:reload_plugins, conversation)

        assert_equal "footer=v2", footer.call
      end
    end
  end

  def test_reload_plugins_updates_commands_and_current_system_message
    Dir.mktmpdir do |home|
      plugins_dir = File.join(home, ".kward", "plugins")
      plugin_path = File.join(plugins_dir, "version.rb")
      FileUtils.mkdir_p(plugins_dir)
      File.write(plugin_path, <<~'RUBY')
        Kward.plugin do |plugin|
          plugin.command "version" do |_args, ctx|
            ctx.say("plugin=v1")
          end
          plugin.prompt_context do |_ctx|
            "Plugin context: v1"
          end
        end
      RUBY

      with_env("HOME" => home, "KWARD_CONFIG_PATH" => nil) do
        prompt = FakePrompt.new([])
        slash_command_updates = []
        prompt.define_singleton_method(:update_slash_commands) { |commands| slash_command_updates << commands }
        cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([]))
        registry = cli.send(:plugin_registry)
        conversation = Kward::Conversation.new(plugin_registry: registry)
        agent = Kward::Agent.new(client: FakeClient.new([]), tool_registry: Kward::ToolRegistry.new(prompt: prompt), conversation: conversation)

        cli.send(:run_plugin_command, "version", "", agent)
        File.write(plugin_path, <<~'RUBY')
          Kward.plugin do |plugin|
            plugin.command "version" do |_args, ctx|
              ctx.say("plugin=v2")
            end
            plugin.command "release" do |_args, ctx|
              ctx.say("release")
            end
            plugin.prompt_context do |_ctx|
              "Plugin context: v2"
            end
          end
        RUBY
        cli.send(:reload_plugins, conversation)
        cli.send(:run_plugin_command, "version", "", agent)

        assert_includes slash_command_updates.last.map { |entry| entry[:name] }, "release"

        output = prompt.output.join("\n")
        assert_includes output, "plugin=v1"
        assert_includes output, "Plugins reloaded."
        assert_includes output, "plugin=v2"
        system_message = conversation.system_message
        assert_includes Kward::MessageAccess.content(system_message), "Plugin context: v2"
        refute_includes Kward::MessageAccess.content(system_message), "Plugin context: v1"
      end
    end
  end

  def test_reload_plugins_refreshes_prompt_templates_and_completion
    Dir.mktmpdir do |home|
      Dir.mktmpdir do |config_dir|
        config_path = File.join(config_dir, "config.json")
        prompts_dir = File.join(config_dir, "prompts")
        File.write(config_path, JSON.dump({}))
        FileUtils.mkdir_p(prompts_dir)
        File.write(File.join(prompts_dir, "plan.md"), "Plan v1: $ARGUMENTS\n")

        with_env("HOME" => home, "KWARD_CONFIG_PATH" => config_path) do
          prompt = FakePrompt.new([])
          slash_command_updates = []
          prompt.define_singleton_method(:update_slash_commands) { |commands| slash_command_updates << commands }
          cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([]))
          conversation = Kward::Conversation.new(system_message: nil, workspace_root: config_dir)

          assert_equal ["plan"], cli.send(:prompt_templates).map(&:command)
          File.write(File.join(prompts_dir, "plan.md"), "Plan v2: $ARGUMENTS\n")
          File.write(File.join(prompts_dir, "review.md"), "Review: $ARGUMENTS\n")

          cli.send(:reload_plugins, conversation)

          prompt_names = slash_command_updates.last.map { |entry| entry[:name] }
          assert_includes prompt_names, "review"
          assert_equal "Plan v2: task\n", cli.send(:expand_prompt_template, "/plan task")
          assert_equal "Review: task\n", cli.send(:expand_prompt_template, "/review task")
        end
      end
    end
  end

  def test_interactive_plugin_slash_command_runs_without_calling_client
    Dir.mktmpdir do |home|
      plugins_dir = File.join(home, ".kward", "plugins")
      FileUtils.mkdir_p(plugins_dir)
      File.write(File.join(plugins_dir, "count.rb"), <<~'RUBY')
        Kward.plugin do |plugin|
          plugin.command "count", description: "Count transcript messages" do |_args, ctx|
            ctx.say("messages=#{ctx.transcript.messages.length}")
          end
        end
      RUBY
      prompt = FakePrompt.new(["hello", "/count", "/exit"])
      client = RecordingClient.new(["reply"])

      with_env("HOME" => home, "KWARD_CONFIG_PATH" => nil) do
        agent = Kward::Agent.new(client: client, tool_registry: Kward::ToolRegistry.new(prompt: prompt))
        cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client)
        cli.interactive_loop(agent: agent)
      end

      assert_equal 1, client.seen_messages.length
      assert_includes prompt.output.join("\n"), "messages=2"
    end
  end

  def test_openrouter_refresh_caches_models_for_configured_key
    Dir.mktmpdir do |dir|
      config_path = File.join(dir, "config.json")
      File.write(config_path, JSON.dump("openrouter_api_key" => "sk-or-secret"))
      prompt = FakePrompt.new([])
      client = ReloadTrackingClient.new
      body = JSON.dump("data" => [
        {
          "id" => "anthropic/claude-sonnet-4.5",
          "architecture" => { "input_modalities" => ["text"], "output_modalities" => ["text"] }
        }
      ])

      with_env("KWARD_CONFIG_PATH" => config_path, "OPENROUTER_API_KEY" => nil) do
        with_fake_net_http([fake_net_response(200, body)]) do |http|
          Kward::CLI.new(argv: ["openrouter", "refresh"], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client).run

          cache_path = File.join(dir, "cache", "openrouter_models.json")
          cache = JSON.parse(File.read(cache_path))
          assert_equal ["anthropic/claude-sonnet-4.5"], cache.fetch("models").map { |model| model.fetch("id") }
          assert_equal URI("https://openrouter.ai/api/v1/models/user"), http.requests.first.uri
          assert_equal "Bearer sk-or-secret", http.requests.first["Authorization"]
          assert_equal 1, client.reload_count
          assert_includes prompt.output.join("\n"), "Refreshed 1 OpenRouter text model"
        end
      end
    end
  end

  def test_openrouter_list_prints_cached_models
    Dir.mktmpdir do |dir|
      config_path = File.join(dir, "config.json")
      cache_path = File.join(dir, "cache", "openrouter_models.json")
      FileUtils.mkdir_p(File.dirname(cache_path))
      File.write(config_path, JSON.dump("openrouter_api_key" => "sk-or-secret"))
      File.write(cache_path, JSON.dump("version" => 1, "refreshed_at" => "2026-06-20T00:00:00Z", "models" => [{ "id" => "openai/gpt-5.5" }]))
      prompt = FakePrompt.new([])

      with_env("KWARD_CONFIG_PATH" => config_path, "OPENROUTER_API_KEY" => nil) do
        Kward::CLI.new(argv: ["openrouter", "list"], stdin: FakeInput.new("", tty: true), prompt: prompt, client: FakeClient.new([])).run
      end

      output = prompt.output.join("\n")
      assert_includes output, "OpenRouter models cached at 2026-06-20T00:00:00Z"
      assert_includes output, "openai/gpt-5.5"
    end
  end

  def test_interactive_plugin_slash_command_shows_running_spinner
    Dir.mktmpdir do |home|
      plugins_dir = File.join(home, ".kward", "plugins")
      FileUtils.mkdir_p(plugins_dir)
      File.write(File.join(plugins_dir, "news.rb"), <<~'RUBY')
        Kward.plugin do |plugin|
          plugin.command "news", description: "Show news" do |_args, ctx|
            ctx.say("news ready")
          end
        end
      RUBY
      prompt = BusyPrompt.new(["/news", "/exit"])
      client = RecordingClient.new([])

      with_env("HOME" => home, "KWARD_CONFIG_PATH" => nil) do
        agent = Kward::Agent.new(client: client, tool_registry: Kward::ToolRegistry.new(prompt: prompt))
        cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client)
        cli.interactive_loop(agent: agent)
      end

      running_index = prompt.events.index([:begin_busy_input, "You>", "running"])
      assert running_index
      finish_after_running = prompt.events[running_index..].index([:finish_busy_input])
      assert finish_after_running
      assert_equal 0, client.seen_messages.length
      assert_includes prompt.output.join("\n"), "news ready"
    end
  end

end
