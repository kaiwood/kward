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
require_relative "cancellation"
require_relative "editor_prompt"
require_relative "editor_prompt_session"
require_relative "shell_prompt"
require_relative "shell_prompt_session"
require_relative "cli/transcript_formatter"
require_relative "model/context_usage"
require_relative "events"
require_relative "export_path"
require_relative "kwsh"
require_relative "persistent_shell_session"
require_relative "interactive_pty_runner"
require_relative "adaptive_pty_output_sink"
require_relative "pty_transcript_normalizer"
require_relative "auth/anthropic_oauth"
require_relative "auth/api_key_store"
require_relative "auth/github_oauth"
require_relative "auth/openrouter_api_key"
require_relative "image_attachments"
require_relative "memory/manager"
require_relative "memory/turn_context"
require_relative "transcript_export"
require_relative "message_access"
require_relative "model/model_info"
require_relative "model/azure_openai_config"
require_relative "model/provider_catalog"
require_relative "model/catalog"
require_relative "auth/openai_oauth"
require_relative "pan/server"
require_relative "plugin_registry"
require_relative "prompts/commands"
require_relative "model/retry_message"
require_relative "rpc/server"
require_relative "transport/runtime"
require_relative "session_diff"
require_relative "session_store"
require_relative "session_naming"
require_relative "tab_store"
require_relative "tab_driver"
require_relative "session_trash"
require_relative "session_tree_renderer"
require_relative "skills/capture"
require_relative "starter_pack_installer"
require_relative "steering"
require_relative "update_check"
require_relative "tools/tool_call"
require_relative "tools/registry"
require_relative "telemetry/stats"
require_relative "workspace_factory"
require_relative "git_worktree_manager"
require_relative "cli/commands"
require_relative "cli/auth_commands"
require_relative "cli/doctor"
require_relative "cli/sysprompt"
require_relative "cli/stats"
require_relative "cli/openrouter_commands"
require_relative "cli/runtime_helpers"
require_relative "cli/project_skills"
require_relative "cli/project_skills_commands"
require_relative "cli/slash_commands"
require_relative "cli/memory_commands"
require_relative "cli/hook_commands"
require_relative "cli/settings"
require_relative "cli/sessions"
require_relative "cli/tabs"
require_relative "cli/worktrees"
require_relative "cli/compaction"
require_relative "cli/rendering"
require_relative "cli/prompt_interface"
require_relative "cli/plugins"
require_relative "cli/git"
require_relative "cli/interactive_turn"
require_relative "cli/tool_summaries"
require_relative "cli/transports"

# Namespace for the Kward CLI agent runtime.
module Kward
  # Command-line interface for interactive chat, one-shot prompts, login,
  # telemetry export, Pan server mode, and the JSON-RPC backend.
  class CLI
    RESTORED_TOOL_OUTPUT_LIMIT = 2_000
    INTERACTIVE_TOOL_OUTPUT_LINE_LIMIT = 10
    STREAM_RENDER_INTERVAL = 0.025
    INTERACTIVE_EVENT_DRAIN_LIMIT = 12
    BUILTIN_SLASH_COMMANDS = PromptCommands::BUILTIN_COMMANDS
    BUILTIN_SLASH_COMMAND_NAMES = PromptCommands::BUILTIN_RESERVED_COMMAND_NAMES

    include CLI::Commands
    include CLI::AuthCommands
    include CLI::Doctor
    include CLI::Sysprompt
    include CLI::Stats
    include CLI::OpenRouterCommands
    include CLI::RuntimeHelpers
    include CLI::ProjectSkills
    include CLI::ProjectSkillsCommands
    include CLI::SlashCommands
    include CLI::MemoryCommands
    include CLI::HookCommands
    include CLI::Settings
    include CLI::Sessions
    include CLI::Tabs
    include CLI::Worktrees
    include CLI::CompactionCommands
    include CLI::Rendering
    include CLI::PromptInterfaceSupport
    include CLI::Plugins
    include CLI::GitCommands
    include CLI::InteractiveTurn
    include CLI::ToolSummaries
    include CLI::Transports

    def initialize(argv: ARGV, stdin: STDIN, prompt: TTY::Prompt.new, client: nil, session_store: nil, context_usage: ContextUsage.new)
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
      @requested_mode = "auto"
      @skip_config = false
      @pending_reasoning_config = nil
      @pending_reasoning_config_mutex = Mutex.new
      @color_enabled = ANSI.enabled?($stdout)
    end

    # Dispatches command-line modes, including RPC, login, stats export, Pan
    # mode, one-shot prompts, and interactive chat.
    #
    # @return [void]
    def run
      @argv = extract_global_options(@argv)
      ConfigFiles.skip_config = @skip_config
      with_working_directory { dispatch }
    rescue ConfigFiles::ConfigError => e
      warn config_error_message(e)
      exit 1
    rescue ArgumentError => e
      warn e.message
      warn "Run `kward help` for available commands."
      exit 1
    rescue Client::AuthenticationError => e
      raise if debug_errors?

      warn authentication_error_message(e)
      exit 1
    rescue StandardError => e
      raise if debug_errors?

      warn runtime_error_message(e)
      exit 1
    ensure
      ConfigFiles.skip_config = false
    end

    def ensure_client!
      @client ||= Client.new
    end

    def config_error_message(error)
      <<~MESSAGE.rstrip
        Invalid Kward config #{error.format}.

        File:
          #{error.path}

        Parser error:
          #{error.detail}

        Kward cannot safely continue with this config.

        Repair it with:
          kward edit #{error.path}

        Emergency fallback:
          kward --skip-config doctor
      MESSAGE
    end

    def authentication_error_message(error)
      <<~MESSAGE.rstrip
        Authentication required

        #{error.message}

        Run `kward doctor` to inspect your setup.
      MESSAGE
    end

    def runtime_error_message(error)
      <<~MESSAGE.rstrip
        Kward could not complete the request.

        #{error.message}

        Set KWARD_DEBUG=1 to show a backtrace.
      MESSAGE
    end

    def debug_errors?
      ENV["KWARD_DEBUG"] == "1"
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

        ensure_client!
        exit 1 unless print_doctor
        return
      end

      if @argv.first == "hooks"
        if help_option_arguments?(@argv[1..] || [])
          print_command_help("hooks")
          return
        end

        handle_hooks_command((@argv[1..] || []).join(" "), command_line: true)
        return
      end

      if @argv.first == "skills"
        if help_option_arguments?(@argv[1..] || [])
          print_command_help("skills")
          return
        end

        handle_project_skills_cli_command(@argv[1..] || [])
        return
      end

      if @argv.first == "edit"
        if help_option_arguments?(@argv[1..] || [])
          print_command_help("edit")
          return
        end
        raise ArgumentError, command_usage("edit") unless @argv.length == 2

        edit_file_command(@argv[1])
        return
      end

      if @argv.first == "sysprompt"
        if help_option_arguments?(@argv[1..] || [])
          print_command_help("sysprompt")
          return
        end

        ensure_client!
        print_sysprompt(@argv[1..] || [])
        return
      end

      if @argv.first == "transport"
        if help_option_arguments?(@argv[1..] || [])
          print_command_help("transport")
          return
        end

        handle_transport_command(@argv[1..] || [])
        return
      end

      if @argv.first == "rpc"
        if help_option_arguments?(@argv[1..] || [])
          print_command_help("rpc")
          return
        end
        raise ArgumentError, command_usage("rpc") unless @argv.length == 1

        ensure_client!
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

        ensure_client!
        handle_openrouter_command(@argv[1..] || [])
        return
      end

      if pan_mode?
        if help_option_arguments?(@argv[1..] || [])
          print_command_help("pan")
          return
        end
        raise ArgumentError, command_usage("pan") unless @argv.length == 1

        ensure_client!
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

    def edit_file_command(path)
      setup_interactive_prompt
      unless @prompt.respond_to?(:edit_file)
        raise ArgumentError, "The integrated editor requires an interactive terminal."
      end

      @prompt.edit_file(path, base_dir: Dir.pwd, allow_new: true)
    ensure
      @prompt.close if @prompt.respond_to?(:close) && prompt_interface?
      clear_interactive_warning_sink if respond_to?(:clear_interactive_warning_sink, true)
    end

    def run_prompt_or_interactive
      ensure_client!
      stdin_input = read_stdin_input
      first_prompt = one_shot_prompt_argument

      case resolved_execution_mode(first_prompt: first_prompt, stdin_input: stdin_input)
      when "chat"
        interactive_loop
      when "filter"
        raise ArgumentError, "Filter mode requires stdin input." if stdin_input.nil?

        answer = one_shot(filter_prompt(instruction: first_prompt, input: stdin_input), filter: true)
        puts answer unless answer.empty?
      when "oneshot"
        input = first_prompt || stdin_input.to_s.strip
        answer = one_shot(input)
        puts answer unless answer.empty?
      end
    end

    def one_shot(input, filter: false)
      streamed = false
      assistant_streamed = false
      markdown_chunks = []
      conversation = new_conversation
      apply_filter_system_prompt(conversation) if filter
      hook_manager = lifecycle_hook_manager(conversation)
      hook_context = lifecycle_hook_context(conversation)
      agent = Agent.new(
        client: @client,
        tool_registry: ToolRegistry.new(
          workspace: configured_workspace,
          prompt: @prompt,
          hook_manager: hook_manager,
          hook_context: hook_context
        ),
        conversation: conversation,
        hook_manager: hook_manager,
        hook_context: hook_context
      )
      answer = if filter
        agent.ask(input)
      else
        agent.ask(input) do |event|
          result = render_blocking_turn_event(event, markdown_chunks)
          streamed = true if result
          assistant_streamed = true if result == :assistant_streamed
        end
      end
      flush_markdown_deltas(markdown_chunks) if streamed
      return answer if filter

      assistant_streamed ? "" : render_markdown_transcript(answer)
    end

    def resolved_execution_mode(first_prompt:, stdin_input:)
      return @requested_mode unless @requested_mode == "auto"
      return "chat" if stdin_input.nil? && first_prompt.nil?
      return "filter" if !stdin_input.nil? && first_prompt

      "oneshot"
    end

    def filter_prompt(instruction:, input:)
      <<~PROMPT
        Instruction:
        #{instruction}

        Input:
        #{input}
      PROMPT
    end

    def apply_filter_system_prompt(conversation)
      return unless conversation.system_message

      conversation.system_message[:content] = [conversation.system_message[:content], filter_system_prompt].compact.join("\n\n")
    end

    def filter_system_prompt
      <<~PROMPT.strip
        You are being used as a command-line text filter.

        Transform the provided input according to the user's instruction.
        Return only the transformed output.

        Do not include explanations, introductions, summaries, Markdown fences, or commentary.
        Do not say what you changed.
        Preserve the input format unless the instruction requires changing it.
        If the input is code, data, markup, or configuration, output only the resulting code/data/markup/configuration.
      PROMPT
    end

    def interactive_loop(agent: nil)
      setup_interactive_prompt(defer_warnings: true)
      prepare_interactive_project_skills
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
      enable_interactive_warnings if respond_to?(:enable_interactive_warnings, true)

      @pending_inputs = []
      install_bang_completion_provider(agent)

      loop do
        service_background_tab_runs if respond_to?(:service_background_tab_runs, true)
        if @pending_inputs.empty? && active_tab&.shell && !active_tab.local_busy?
          run_kwsh_loop(active_tab.shell, tab: active_tab, history: build_kwsh_history(active_tab.agent))
        end
        input = @pending_inputs.shift || (active_tab ? poll_active_tab_input : @prompt.ask("You>"))
        if input.is_a?(Hash) && input[:editor_prompt]
          pending_inputs = run_editor_prompt_turn(input[:editor_prompt], active_tab&.agent || agent)
          pending_inputs.reverse_each { |pending_input| @pending_inputs.unshift(pending_input) }
          next
        end
        if input.is_a?(Hash) && input[:tab_action]
          tab_result = handle_tab_action(input, session_store)
          break if tab_result == PromptInterface::EXIT_INPUT
          agent = active_tab.agent if active_tab&.agent
          next
        end
        if input.is_a?(Hash) && input[:reasoning_action]
          next if active_tab && plugin_tab?

          conversation = active_tab ? active_tab.agent.conversation : agent.conversation
          cycle_reasoning(conversation, direction: input[:reasoning_action], persist: :debounced)
          agent = active_tab.agent if active_tab&.agent
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
          if active_tab && plugin_tab? && command.start_with?("/")
            unless plugin_tab_command_allowed?(command)
              runtime_output("#{command.split.first} is unavailable in this plugin tab.")
              next
            end
            if active_tab.driver.respond_to?(:handle_command) && active_tab.driver.handles_command?(command)
              output = active_tab.driver.handle_command(command)
              runtime_output(output) unless output.to_s.empty?
              next
            end
          end
          handled, replacement_agent = handle_local_slash_command(command, agent, session_store)
          if replacement_agent?(replacement_agent)
            agent = active_tab ? replace_active_tab_agent(replacement_agent) : replacement_agent
          elsif active_tab&.agent
            agent = active_tab.agent
          end
        end
        next if handled
        if shell_command_input?(command_input)
          shell_result = handle_interactive_shell_command(command_input, agent)
          next if shell_result == true || shell_result == :tab_action
        end

        flush_pending_reasoning_config(conversation: active_tab.agent.conversation) if active_tab&.agent
        flush_pending_reasoning_config(conversation: agent.conversation) unless active_tab
        expanded_input = expand_prompt_template(input)
        display_input = display_input || input if expanded_input
        input = expanded_input || input
        @footer_conversation = active_tab.agent.conversation if active_tab&.agent
        @footer_conversation = agent.conversation unless active_tab
        begin
          @rewind_return_leaf_id = nil
          auto_name_active_session(display_input || input) unless active_tab && plugin_tab?
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
        end
      end

      flush_pending_reasoning_config(conversation: active_tab.agent.conversation) if active_tab&.agent
      flush_pending_reasoning_config(conversation: agent.conversation) unless active_tab
      active_tab&.agent&.conversation || agent.conversation
    rescue Interrupt
      flush_pending_reasoning_config(conversation: active_tab.agent.conversation) if active_tab&.agent
      flush_pending_reasoning_config(conversation: agent&.conversation) unless active_tab
      runtime_output("Goodbye.")
      active_tab&.agent&.conversation || agent&.conversation
    ensure
      clear_bang_completion_provider
      begin
        stop_tabs if respond_to?(:stop_tabs, true)
        @prompt.close if prompt_interface?
      ensure
        clear_interactive_warning_sink if respond_to?(:clear_interactive_warning_sink, true)
        cleanup_unused_sessions
        remember_active_session(session_store)
      end
    end

    def piped_prompt
      read_stdin_input.to_s.strip
    end

    def read_stdin_input
      return nil if @stdin.tty?

      @stdin.read
    end

  end
end
