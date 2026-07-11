# Namespace for the Kward CLI agent runtime.
module Kward
  # Command-line frontend that coordinates terminal interaction, sessions, tools, and model turns.
  class CLI
    # Interactive slash-command parsing and dispatch helpers.
    module SlashCommands
      private

      def handle_local_slash_command(command, agent, session_store)
        name, argument = parse_slash_command(command)
        case name
        when "status"
          run_busy_local_command_and_requeue { print_status }
          [true, nil]
        when "stats"
          run_busy_local_command_and_requeue { print_stats(argument) }
          [true, nil]
        when "memory"
          activity = memory_summarize_command?(argument) ? "summarizing" : "loading"
          run_busy_local_command_and_requeue(activity: activity) { handle_memory_command(argument, agent) }
          [true, nil]
        when "hooks"
          run_busy_local_command_and_requeue { handle_hooks_command(argument) }
          [true, nil]
        when "skill"
          run_busy_local_command_and_requeue { activate_skill_command(argument, agent) }
          [true, nil]
        when "redraw"
          run_busy_local_command_and_requeue { @prompt.redraw if @prompt.respond_to?(:redraw) }
          [true, nil]
        when "git"
          handle_git_command(agent)
          [true, nil]
        when "diff"
          open_session_diff
          [true, nil]
        when "files"
          open_project_files_browser
          [true, nil]
        when "shell"
          run_ekwsh(agent)
          [true, nil]
        when "scratchpad"
          open_scratchpad_command(argument)
          [true, nil]
        when "pty"
          run_interactive_pty_command(argument, agent)
          [true, nil]
        when "tab"
          [true, handle_tab_command(argument, session_store)]
        when "settings"
          configure_settings(agent.conversation)
          [true, nil]
        when "login"
          login_interactively
          [true, nil]
        when "model"
          models = run_busy_local_command_and_requeue { normalized_available_models }
          configure_model(agent.conversation, models: models)
          [true, nil]
        when "reasoning"
          configure_reasoning(agent.conversation)
          [true, nil]
        when "reload"
          run_busy_local_command_and_requeue { reload_plugins(agent.conversation) }
          [true, nil]
        when "new"
          [true, run_busy_local_command_and_requeue { start_new_session(session_store) }]
        when "session"
          session_command, session_argument = argument.to_s.split(/\s+/, 2)
          if session_command == "name"
            rename_session(session_argument)
            [true, nil]
          else
            [true, open_or_resume_session(session_store, argument)]
          end
        when "resume"
          [true, open_or_resume_session(session_store, argument)]
        when "rename"
          rename_session(argument, require_name: true)
          [true, nil]
        when "clone"
          [true, run_busy_local_command_and_requeue { clone_session(session_store, agent) }]
        when "fork"
          [true, fork_session(session_store)]
        when "rewind"
          [true, run_busy_local_command_and_requeue { rewind_session(session_store) }]
        when "tree"
          [true, navigate_session_tree(session_store)]
        when "copy"
          run_busy_local_command_and_requeue { copy_session_text(agent.conversation, argument) }
          [true, nil]
        when "export"
          run_busy_local_command_and_requeue { export_session(agent.conversation, argument) }
          [true, nil]
        when "compact"
          run_busy_local_command_and_requeue(activity: "compacting") { compact_context(agent, argument) }
          [true, nil]
        else
          if name.to_s.start_with?("skill:")
            run_busy_local_command_and_requeue { activate_skill_command(name.to_s.delete_prefix("skill:"), agent) }
            [true, nil]
          elsif interactive_command_for(name) && prompt_interface? && @prompt.respond_to?(:start_interactive)
            run_interactive_command(name, argument, agent)
          elsif plugin_command_for(name)
            run_busy_local_command_and_requeue(activity: "running") { run_plugin_command(name, argument, agent) }
          else
            [false, nil]
          end
        end
      end

      def parse_slash_command(command)
        PromptCommands.parse(command) || [nil, ""]
      end

      def open_or_resume_session(session_store, argument)
        unless session_store
          say_sessions_unavailable
          return nil
        end

        path = argument.to_s.strip
        if path.empty?
          sessions = run_busy_local_command_and_requeue { recent_sessions(session_store, tree: true) }
          path = select_session_path_from_sessions(sessions, session_store: session_store)
        end

        selection = path
        loop do
          replacement_agent = if selection.respond_to?(:conversation)
                                selection
                              elsif selection.is_a?(Hash) && selection[:action] == :clone
                                run_busy_local_command_and_requeue(activity: "cloning") { clone_session_from_path(session_store, selection[:path]) }
                              elsif selection.is_a?(Hash) && selection[:action] == :fork
                                selection = reopen_sessions_after_fork(session_store, selection[:path], selection[:choice_label])
                                next
                              elsif selection.to_s.empty?
                                nil
                              else
                                run_busy_local_command_and_requeue { resume_session(session_store, selection) }
                              end
          return replacement_agent
        end
      end

      def activate_skill_command(name, agent)
        skill_name = name.to_s.strip
        if skill_name.empty?
          runtime_output("Usage: /skill <name>")
          return
        end

        tool_call = {
          "id" => "skill_#{skill_name.gsub(/[^a-zA-Z0-9_-]/, "_")}",
          "type" => "function",
          "function" => {
            "name" => "read_skill",
            "arguments" => JSON.dump({ name: skill_name })
          }
        }
        agent.conversation.append_assistant("role" => "assistant", "content" => nil, "tool_calls" => [tool_call])
        result = agent.tool_registry.dispatch(tool_call, agent.conversation)
        runtime_output(result.start_with?("Error:") ? result : "Activated skill: #{skill_name}")
      end

      def open_session_diff
        unless @active_session&.path
          runtime_output("No active persisted session.")
          return
        end

        content = SessionDiff.content_from_session_file(@active_session.path)
        if content.empty?
          runtime_output("No file changes recorded in this session.")
          return
        end

        if @prompt.respond_to?(:open_modal_diff_viewer)
          @prompt.open_modal_diff_viewer("Session diff", content)
        elsif @prompt.respond_to?(:open_diff_viewer)
          @prompt.open_diff_viewer("Session diff", content)
        else
          runtime_output(content)
        end
      end

      def open_scratchpad_command(argument)
        if @prompt.respond_to?(:scratchpad)
          @prompt.scratchpad(scratchpad_language_argument(argument))
        else
          runtime_output("The scratchpad is only available in the interactive prompt.")
        end
      end

      def scratchpad_language_argument(argument)
        value = argument.to_s.strip.downcase
        return :text if value.empty? || value == "text"
        return :markdown if ["markdown", "md"].include?(value)
        return :ruby if ["ruby", "rb"].include?(value)

        :text
      end

      def open_project_files_browser
        if @prompt.respond_to?(:open_project_browser)
          @prompt.open_project_browser
        else
          runtime_output("The project file browser is only available in the interactive prompt.")
        end
      end

      # Writes the status output for the terminal CLI flow.
      def print_status
        lines = ["Kward status"]
        lines << ""
        lines << auto_compaction_status_line
        if @active_session
          lines << "Session: #{@active_session.name || @active_session.id}"
          lines << "File: #{@active_session.path}"
        end
        lines.compact!
        runtime_output(lines.join("\n"))
      end

      def auto_compaction_status_line
        settings = Kward::Compaction::Settings.from_config
        return "Auto-compaction: disabled" unless settings.enabled

        context_window = composer_context_window
        return "Auto-compaction: enabled, unknown context window" unless context_window.to_i.positive?

        reserve_tokens = Kward::Compactor.auto_compaction_reserve_tokens(
          context_window: context_window,
          configured_reserve_tokens: settings.reserve_tokens
        )
        percent = ((reserve_tokens.to_f / context_window.to_i) * 100).round(1)
        "Auto-compaction reserve: #{reserve_tokens} tokens (#{percent}% of #{context_window})"
      rescue StandardError => e
        warn "Auto-compaction status unavailable: #{e.message}"
        nil
      end

    end
  end
end
