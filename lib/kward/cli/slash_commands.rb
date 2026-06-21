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
        when "scout"
          handle_scout_command(argument, agent)
          [true, nil]
        when "scouts"
          print_scouts
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

      def handle_scout_command(argument, agent)
        action, value = argument.to_s.strip.split(/\s+/, 2)
        case action
        when nil, ""
          open_scout_menu(agent)
        when "do"
          send_scout(value, agent)
        when "list"
          open_scout_list(agent)
        when "show", "open"
          show_scout(value)
        when "cancel", "recall"
          cancel_scout(value)
        when "dismiss", "drop"
          dismiss_scout(value)
        when "use", "apply", "start"
          use_scout(value)
        else
          send_scout(argument, agent)
        end
      end

      def scout_store
        @scout_store ||= Scouts::Store.new
      end

      def scout_runner(agent)
        workspace_root = interactive_workspace_root(agent)
        return @scout_runner if @scout_runner && @scout_runner_workspace_root == workspace_root

        @scout_runner_workspace_root = workspace_root
        @scout_runner = Scouts::Runner.new(store: scout_store, client: Client.new, prompt: @prompt, workspace_root: workspace_root)
      end

      def send_scout(topic, agent)
        if topic.to_s.strip.empty?
          runtime_output("Usage: /scout do <task>")
          return
        end

        job = scout_runner(agent).start(topic)
        runtime_output("Scout #{job.fetch('id')} sent: #{job.fetch('title')}")
      end

      def print_scouts
        jobs = scout_store.list
        if jobs.empty?
          runtime_output("No scouts in the pipeline.")
          return
        end

        lines = ["Scouts"]
        jobs.each { |job| lines << "  #{scout_choice_label(job)}" }
        runtime_output(lines.join("\n"))
      end

      def open_scout_menu(agent)
        return runtime_output("Usage: /scout do <task> | /scout list | /scout show <id> | /scout cancel <id> | /scout dismiss <id> | /scout use <id>") unless @prompt.respond_to?(:select)

        choice = @prompt.select(
          "Scout",
          ["Send a new scout", "List scouts"],
          title: "Scouts",
          custom: false
        )
        case choice
        when "Send a new scout"
          prompt_for_scout(agent)
        when "List scouts"
          open_scout_list(agent)
        end
      end

      def prompt_for_scout(agent)
        topic = @prompt.ask("Scout task>") if @prompt.respond_to?(:ask)
        send_scout(topic, agent) unless topic.to_s.strip.empty?
      end

      def open_scout_list(agent)
        return print_scouts unless @prompt.respond_to?(:select)

        jobs = scout_store.list
        if jobs.empty?
          runtime_output("No scouts in the pipeline.")
          return
        end

        labels = jobs.map { |job| scout_choice_label(job) }
        choice = @prompt.select("Select scout", labels, title: "Scouts", custom: false)
        return unless choice

        selected = jobs[labels.index(choice)]
        open_scout_actions(selected.fetch("id"), agent) if selected
      end

      def open_scout_actions(id, agent)
        job = require_scout(id)
        actions = ["Show report"]
        actions << "Start from report" if job["status"] == "ready"
        actions << "Cancel" if %w[queued running].include?(job["status"])
        actions << "Dismiss"
        actions << "Back to list"
        choice = @prompt.select("#{job.fetch('id')} — #{job.fetch('title')}", actions, title: "Scout", custom: false)
        case choice
        when "Show report"
          show_scout(job.fetch("id"))
        when "Start from report"
          use_scout(job.fetch("id"))
        when "Cancel"
          cancel_scout(job.fetch("id"))
        when "Dismiss"
          dismiss_scout(job.fetch("id"))
        when "Back to list"
          open_scout_list(agent)
        end
      end

      def scout_choice_label(job)
        error = job["status"] == "failed" && !job["error"].to_s.empty? ? " — #{job['error']}" : ""
        "#{job.fetch('id')} [#{job.fetch('status')}] #{job.fetch('title')}#{error}"
      end

      def show_scout(id)
        job = require_scout(id)
        text = scout_report_text(job)
        if @prompt.respond_to?(:view_text)
          @prompt.view_text(title: "Scout #{job.fetch('id')}", content: text)
        else
          runtime_output(text)
        end
      end

      def scout_report_text(job)
        lines = ["Scout #{job.fetch('id')} [#{job.fetch('status')}] #{job.fetch('title')}", ""]
        if job["report"].to_s.empty?
          lines << (job["error"].to_s.empty? ? "No report yet." : "Error: #{job['error']}")
        else
          lines << job["report"]
        end
        lines.join("\n")
      end

      def cancel_scout(id)
        job = require_scout(id)
        scout_runner_for_existing_jobs.cancel(job.fetch("id"))
        runtime_output("Scout #{job.fetch('id')} cancelled.")
      end

      def dismiss_scout(id)
        job = scout_store.dismiss(require_scout(id).fetch("id"))
        runtime_output("Scout #{job.fetch('id')} dismissed.")
      end

      def use_scout(id)
        job = require_scout(id)
        unless job["status"] == "ready"
          runtime_output("Scout #{job.fetch('id')} is #{job['status']}; only ready scouts can be used.")
          return
        end

        scout_store.mark_started(job.fetch("id"))
        @pending_inputs << <<~PROMPT
          Use this scout report as preparation and implement the requested task.

          Original request:
          #{job["prompt"]}

          Scout report:
          #{job["report"]}
        PROMPT
        runtime_output("Scout #{job.fetch('id')} queued as the next task.")
      end

      def require_scout(id)
        value = id.to_s.strip.delete_prefix("#")
        raise ArgumentError, "Scout id is required" if value.empty?

        scout_store.find(value) || raise(ArgumentError, "Unknown scout: #{value}")
      end

      def scout_runner_for_existing_jobs
        @scout_runner ||= Scouts::Runner.new(store: scout_store, client: Client.new, prompt: @prompt, workspace_root: current_workspace_root)
      end

    end
  end
end
