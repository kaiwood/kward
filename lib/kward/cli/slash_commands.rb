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
        when "redraw"
          run_busy_local_command_and_requeue { @prompt.redraw if @prompt.respond_to?(:redraw) }
          [true, nil]
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
        when "sessions", "resume"
          unless session_store
            say_sessions_unavailable
            return [true, nil]
          end

          path = argument.to_s.strip
          if path.empty?
            sessions = run_busy_local_command_and_requeue { session_store.recent_tree(limit: nil) }
            path = select_session_path_from_sessions(sessions, session_store: session_store)
          end
          replacement_agent = nil
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
            break
          end
          [true, replacement_agent]
        when "name"
          rename_session(argument)
          [true, nil]
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
          if plugin_command_for(name)
            run_busy_local_command_and_requeue(activity: "running") { run_plugin_command(name, argument, agent) }
          else
            [false, nil]
          end
        end
      end

      def parse_slash_command(command)
        PromptCommands.parse(command) || [nil, ""]
      end

      # Writes the status output for the terminal CLI flow.
      def print_status
        lines = [STATUS_MESSAGE]
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
