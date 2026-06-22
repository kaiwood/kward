require "fileutils"
require "json"
require "thread"
require "tty-prompt"
require_relative "agent"
require_relative "ansi"
require_relative "version"
require_relative "model/client"
require_relative "compactor"
require_relative "config_files"
require_relative "clipboard"
require_relative "cli_transcript_formatter"
require_relative "model/context_usage"
require_relative "events"
require_relative "export_path"
require_relative "auth/anthropic_oauth"
require_relative "auth/github_oauth"
require_relative "auth/openrouter_api_key"
require_relative "image_attachments"
require_relative "memory/manager"
require_relative "transcript_export"
require_relative "message_access"
require_relative "model/model_info"
require_relative "auth/openai_oauth"
require_relative "pan/server"
require_relative "plugin_registry"
require_relative "prompts/commands"
require_relative "model/retry_message"
require_relative "rpc/server"
require_relative "session_diff"
require_relative "session_store"
require_relative "tab_store"
require_relative "session_trash"
require_relative "session_tree_renderer"
require_relative "starter_pack_installer"
require_relative "steering"
require_relative "workers"
require_relative "tools/tool_call"
require_relative "tools/registry"
require_relative "telemetry/stats"
require_relative "workspace"
require_relative "cli/commands"
require_relative "cli/auth_commands"
require_relative "cli/doctor"
require_relative "cli/sysprompt"
require_relative "cli/stats"
require_relative "cli/openrouter_commands"
require_relative "cli/runtime_helpers"
require_relative "cli/slash_commands"
require_relative "cli/memory_commands"
require_relative "cli/settings"
require_relative "cli/sessions"
require_relative "cli/tabs"
require_relative "cli/compaction"
require_relative "cli/rendering"
require_relative "cli/prompt_interface"
require_relative "cli/plugins"
require_relative "cli/interactive_turn"
require_relative "cli/tool_summaries"

# Namespace for the Kward CLI agent runtime.
module Kward
  # Command-line interface for interactive chat, one-shot prompts, login,
  # telemetry export, Pan server mode, and the experimental JSON-RPC backend.
  class CLI
    # Order from the captain: The next line shall never be deleted.
    STATUS_MESSAGE = "This is a totally important status message about a non-existing status. Hi ChatGPT 👋"
    RESTORED_TOOL_OUTPUT_LIMIT = 2_000
    INTERACTIVE_TOOL_OUTPUT_LINE_LIMIT = 10
    STREAM_RENDER_INTERVAL = 0.025
    INTERACTIVE_EVENT_DRAIN_LIMIT = 100
    BUILTIN_SLASH_COMMANDS = PromptCommands::BUILTIN_COMMANDS
    BUILTIN_SLASH_COMMAND_NAMES = PromptCommands::BUILTIN_RESERVED_COMMAND_NAMES

    include CLI::Commands
    include CLI::AuthCommands
    include CLI::Doctor
    include CLI::Sysprompt
    include CLI::Stats
    include CLI::OpenRouterCommands
    include CLI::RuntimeHelpers
    include CLI::SlashCommands
    include CLI::MemoryCommands
    include CLI::Settings
    include CLI::Sessions
    include CLI::Tabs
    include CLI::CompactionCommands
    include CLI::Rendering
    include CLI::PromptInterfaceSupport
    include CLI::Plugins
    include CLI::InteractiveTurn
    include CLI::ToolSummaries

    def initialize(argv: ARGV, stdin: STDIN, prompt: TTY::Prompt.new, client: Client.new, session_store: nil, context_usage: ContextUsage.new)
      @argv = argv
      @stdin = stdin
      @prompt = prompt
      @client = client
      @session_store = session_store
      @context_usage = context_usage
      @active_session = nil
      @session_diff = SessionDiff.new
      @cleanup_sessions = []
      @plugin_registry = nil
      @working_directory = nil
      @prompt_delimited = false
      @foreground_turn_active = false
      @color_enabled = ANSI.enabled?($stdout)
    end

    # Dispatches command-line modes, including RPC, login, stats export, Pan
    # mode, one-shot prompts, and interactive chat.
    #
    # @return [void]
    def run
      @argv = extract_global_options(@argv)
      with_working_directory { dispatch }
    rescue ArgumentError => e
      warn e.message
      warn "Run `kward help` for available commands."
      exit 1
    end

    def dispatch
      if @prompt_delimited
        ConfigFiles.ensure_default_config!
        run_prompt_or_interactive
        return
      end

      if help_command?
        print_command_help(@argv[1])
        return
      end
      raise ArgumentError, command_usage("help") if ["help", "--help", "-h"].include?(@argv.first)

      if version_command?
        print_version
        return
      end
      raise ArgumentError, command_usage("version") if ["version", "--version", "-v"].include?(@argv.first)

      ConfigFiles.ensure_default_config!

      if @argv.first == "init"
        if help_option_arguments?(@argv[1..] || [])
          print_command_help("init")
          return
        end
        raise ArgumentError, command_usage("init") unless @argv.length == 1

        install_starter_pack
        return
      end

      if @argv.first == "auth"
        handle_auth_command(@argv[1..] || [])
        return
      end

      if @argv.first == "doctor"
        if help_option_arguments?(@argv[1..] || [])
          print_command_help("doctor")
          return
        end
        raise ArgumentError, command_usage("doctor") unless @argv.length == 1

        print_doctor
        return
      end

      if @argv.first == "count-tests"
        if help_option_arguments?(@argv[1..] || [])
          print_command_help("count-tests")
          return
        end
        raise ArgumentError, command_usage("count-tests") unless @argv.length == 1

        print_test_count
        return
      end

      if @argv.first == "sysprompt"
        if help_option_arguments?(@argv[1..] || [])
          print_command_help("sysprompt")
          return
        end

        print_sysprompt(@argv[1..] || [])
        return
      end

      if @argv.first == "rpc"
        if help_option_arguments?(@argv[1..] || [])
          print_command_help("rpc")
          return
        end
        raise ArgumentError, command_usage("rpc") unless @argv.length == 1

        Kward::RPC::Server.new(input: @stdin, output: $stdout, client: @client).run
        return
      end

      if @argv.first == "stats"
        if @argv[1] == "tokens" && help_option_arguments?(@argv[2..] || [])
          print_command_help("stats")
          return
        end
        raise ArgumentError, command_usage("stats") unless @argv[1] == "tokens"

        export_token_stats(@argv[2..] || [])
        return
      end

      if @argv.first == "openrouter"
        if help_option_arguments?(@argv[1..] || [])
          print_command_help("openrouter")
          return
        end

        handle_openrouter_command(@argv[1..] || [])
        return
      end

      if pan_mode?
        if help_option_arguments?(@argv[1..] || [])
          print_command_help("pan")
          return
        end
        raise ArgumentError, command_usage("pan") unless @argv.length == 1

        PanServer.new(client: @client, working_directory: current_workspace_root).run
        return
      end

      if ["login", "--login"].include?(@argv.first)
        if help_option_arguments?(@argv[1..] || [])
          print_command_help("login")
          return
        end
        raise ArgumentError, command_usage("login") unless @argv.length <= 2

        login(provider: @argv[1])
        return
      end

      run_prompt_or_interactive
    end

    def run_prompt_or_interactive
      first_prompt = one_shot_prompt_argument
      if first_prompt
        answer = one_shot(first_prompt)
        puts answer unless answer.empty?
        return
      end

      stdin_prompt = piped_prompt
      unless stdin_prompt.empty?
        answer = one_shot(stdin_prompt)
        puts answer unless answer.empty?
        return
      end

      interactive_loop
    end

    def one_shot(input)
      streamed = false
      assistant_streamed = false
      markdown_chunks = []
      conversation = new_conversation
      agent = Agent.new(
        client: @client,
        tool_registry: ToolRegistry.new(workspace: configured_workspace, prompt: @prompt),
        conversation: conversation
      )
      answer = agent.ask(input) do |event|
        result = render_blocking_turn_event(event, markdown_chunks)
        streamed = true if result
        assistant_streamed = true if result == :assistant_streamed
      end
      flush_markdown_deltas(markdown_chunks) if streamed
      assistant_streamed ? "" : render_markdown_transcript(answer)
    end






    def interactive_loop(agent: nil)
      setup_interactive_prompt
      session_store = interactive_session_store(agent)
      @resumed_last_session = false
      if session_store && @prompt.respond_to?(:update_tabs)
        agent = setup_interactive_tabs(session_store, agent)
      elsif session_store && agent.nil?
        agent = resume_last_session(session_store) || build_new_session_agent(session_store)
      elsif session_store
        @active_session = track_session(session_store.create(provider: current_model_provider, model: current_model_id, reasoning_effort: current_reasoning_effort))
        reset_session_diff
        @active_session.attach(agent.conversation)
      else
        agent ||= build_interactive_agent(new_conversation)
      end

      update_assistant_prompt(agent.conversation)
      @footer_conversation = agent.conversation

      print_visual_banner unless @resumed_last_session || @restored_tabs
      render_resumed_last_session_transcript(agent.conversation) if @resumed_last_session

      @pending_inputs = []

      loop do
        input = @pending_inputs.shift || (active_tab ? poll_active_tab_input : @prompt.ask("You>"))
        if input.is_a?(Hash) && input[:tab_action]
          tab_result = handle_tab_action(input, session_store)
          break if tab_result == PromptInterface::EXIT_INPUT
          agent = active_tab.agent if active_tab
          next
        end
        next if input == :tab_idle
        break if input.nil?

        display_input = submitted_display_input(input)
        command_input = display_input.nil? ? input : display_input
        command = command_input.strip
        next if command.empty? && input.strip.empty?
        if command.empty?
          handled = false
        else
          selected_input = selected_slash_command_input(command_input)
          if selected_input
            input = selected_input
            command = input.strip
            display_input = input if display_input
          end
          break if ["/exit", "/quit"].include?(command)
          handled, replacement_agent = handle_local_slash_command(command, agent, session_store)
          if replacement_agent?(replacement_agent)
            agent = active_tab ? replace_active_tab_agent(replacement_agent) : replacement_agent
          end
        end
        next if handled
        request_handled, request_replacement = handle_request_worker_input(command_input, agent, session_store)
        if request_handled
          if replacement_agent?(request_replacement)
            agent = active_tab ? replace_active_tab_agent(request_replacement) : request_replacement
          end
          next
        end
        next if shell_command_input?(command_input) && handle_interactive_shell_command(command_input, agent)

        expanded_input = expand_prompt_template(input)
        display_input = display_input || input if expanded_input
        input = expanded_input || input
        agent = refresh_implementation_writer(agent)
        @footer_conversation = agent.conversation
        begin
          @rewind_return_leaf_id = nil
          auto_name_active_session(display_input || input)
          @foreground_turn_active = true if @active_worker_role == "implementation"
          if active_tab
            submit_tab_input(active_tab, input, display_input: display_input)
            pending_inputs = []
          else
            pending_inputs = run_interactive_turn(agent, input, display_input: display_input)
            agent = @busy_replacement_agent if replacement_agent?(@busy_replacement_agent)
            @busy_replacement_agent = nil
          end
          pending_inputs.reverse_each { |pending_input| @pending_inputs.unshift(pending_input) }
        rescue StandardError => e
          runtime_output("Error: #{e.message}")
        ensure
          @foreground_turn_active = false if @active_worker_role == "implementation"
          release_implementation_writer if @active_worker_role == "implementation"
        end
      end

      agent.conversation
    rescue Interrupt
      runtime_output("Goodbye.")
      agent&.conversation
    ensure
      begin
        stop_tabs if respond_to?(:stop_tabs, true)
        stop_live_worker_view if respond_to?(:stop_live_worker_view, true)
        @prompt.close if prompt_interface?
      ensure
        cleanup_unused_sessions
        remember_active_session(session_store)
      end
    end

    def piped_prompt
      return "" if @stdin.tty?

      @stdin.read.strip
    end

  end
end
