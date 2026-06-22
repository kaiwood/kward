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
          [true, handle_scout_command(argument, agent, session_store)]
        when "scouts"
          print_scouts
          [true, nil]
        when "workers"
          [true, handle_workers_command(argument, agent, session_store)]
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

      def handle_workers_command(argument, agent, session_store)
        action, value = argument.to_s.strip.split(/\s+/, 2)
        case action
        when nil, ""
          open_worker_menu(agent, session_store)
        when "list"
          open_worker_list(agent, session_store)
        when "new", "scout"
          prompt_for_scout(agent)
          nil
        when "implement", "implementation"
          send_implementation_worker(value, agent)
          nil
        when "do"
          send_scout(value, agent)
          nil
        else
          runtime_output("Usage: /workers | /workers new | /workers do <task>")
          nil
        end
      end

      def handle_scout_command(argument, agent, session_store)
        action, value = argument.to_s.strip.split(/\s+/, 2)
        case action
        when nil, ""
          open_scout_menu(agent, session_store)
        when "do"
          send_scout(value, agent)
          nil
        when "list"
          open_scout_list(agent, session_store)
        when "show", "open"
          show_scout(value, session_store)
        when "cancel", "recall"
          cancel_scout(value)
          nil
        when "dismiss", "drop"
          dismiss_scout(value)
          nil
        when "use", "apply", "start"
          use_scout(value)
          nil
        else
          send_scout(argument, agent)
          nil
        end
      end

      def scout_store
        @scout_store ||= Scouts::Store.new
      end

      def worker_store
        @worker_store ||= Workers::Store.new
      end

      def scout_runner(agent)
        workspace_root = interactive_workspace_root(agent)
        return @scout_runner if @scout_runner && @scout_runner_workspace_root == workspace_root

        @scout_runner_workspace_root = workspace_root
        @scout_runner = Scouts::Runner.new(
          store: scout_store,
          client: Client.new,
          prompt: @prompt,
          workspace_root: workspace_root,
          session_store: interactive_session_store(agent),
          provider: current_model_provider,
          model: current_model_id,
          reasoning_effort: current_reasoning_effort,
          write_lock: (@worker_write_lock ||= Workers::WriteLock.new)
        )
      end

      def worker_manager(agent)
        workspace_root = interactive_workspace_root(agent)
        return @worker_manager if @worker_manager && @worker_manager_workspace_root == workspace_root

        @worker_manager_workspace_root = workspace_root
        @worker_manager = Workers::Manager.new(
          client_factory: -> { Client.new },
          prompt: @prompt,
          workspace_root: workspace_root,
          session_store: interactive_session_store(agent),
          provider: current_model_provider,
          model: current_model_id,
          reasoning_effort: current_reasoning_effort,
          write_lock: (@worker_write_lock ||= Workers::WriteLock.new),
          worker_store: worker_store
        )
      end

      def send_scout(topic, agent)
        if topic.to_s.strip.empty?
          runtime_output("Usage: /scout do <task>")
          return
        end

        job = scout_runner(agent).start(topic)
        runtime_output("Scout #{job.fetch('id')} sent: #{job.fetch('title')}")
      end

      def send_implementation_worker(topic, agent)
        if topic.to_s.strip.empty?
          runtime_output("Usage: /workers implement <task>")
          return
        end

        remember_implementation_worker(agent)
        @worker_write_lock&.release("implementation")
        worker = worker_manager(agent).start(role: "implementation", prompt: topic)
        runtime_output("Implementation worker #{worker.id} started: #{worker.title}")
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

      def open_scout_menu(agent, session_store)
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
          open_scout_list(agent, session_store)
        end
      end

      def open_worker_menu(agent, session_store)
        return runtime_output("Usage: /workers | /workers new | /workers do <task>") unless @prompt.respond_to?(:select)

        choice = @prompt.select(
          "Workers",
          ["New read-only worker", "New implementation worker", "List workers"],
          title: "Workers",
          custom: false
        )
        case choice
        when "New read-only worker"
          prompt_for_scout(agent)
        when "New implementation worker"
          prompt_for_implementation_worker(agent)
        when "List workers"
          open_worker_list(agent, session_store)
        end
      end

      def prompt_for_scout(agent)
        topic = @prompt.ask("Scout task>") if @prompt.respond_to?(:ask)
        send_scout(topic, agent) unless topic.to_s.strip.empty?
      end

      def prompt_for_implementation_worker(agent)
        topic = @prompt.ask("Implementation task>") if @prompt.respond_to?(:ask)
        send_implementation_worker(topic, agent) unless topic.to_s.strip.empty?
      end

      def open_scout_list(agent, session_store)
        open_worker_list(agent, session_store, title: "Scouts", empty_message: "No scouts in the pipeline.")
      end

      def open_worker_list(agent, session_store, title: "Workers", empty_message: "No workers in the pipeline.")
        return print_scouts unless @prompt.respond_to?(:select)

        jobs = worker_jobs(agent)
        if jobs.empty?
          runtime_output(empty_message)
          return
        end

        labels = jobs.map { |job| worker_choice_label(job) }
        choice = @prompt.select("Select worker", labels, title: title, custom: false)
        return unless choice

        selected = jobs[labels.index(choice)]
        open_worker_actions(selected, agent, session_store) if selected
      end

      def worker_jobs(agent)
        runtime_worker_ids = @worker_manager ? @worker_manager.list.map(&:id) : []
        background_workers = worker_store.list.reject { |job| runtime_worker_ids.include?(job["id"]) }
        background_workers.concat(@worker_manager.list.map(&:to_h)) if @worker_manager
        [implementation_worker_job(agent)].compact + background_workers + scout_store.list
      end

      def implementation_worker_job(agent)
        remember_implementation_worker(agent) if implementation_agent?(agent)
        path = @implementation_worker_session_path || @active_session&.path
        return nil if path.to_s.empty?

        {
          "id" => "implementation",
          "title" => @implementation_worker_title || @active_session&.name || "Implementation",
          "role" => "implementation",
          "status" => implementation_agent?(agent) ? "active" : "idle",
          "session_path" => path
        }
      end

      def implementation_agent?(agent)
        @active_worker_role.to_s.empty? || @active_worker_role == "implementation"
      end

      def remember_implementation_worker(agent)
        return unless @active_session&.path
        return unless implementation_agent?(agent)

        @implementation_worker_session_path = @active_session.path
        @implementation_worker_title = @active_session.name || "Implementation"
      end

      def open_worker_actions(job, agent, session_store)
        return open_implementation_actions(job, session_store) if job["id"] == "implementation"
        return open_background_worker_actions(job, session_store) if job["role"] == "implementation"

        open_scout_actions(job.fetch("id"), agent, session_store)
      end

      def open_implementation_actions(job, session_store)
        actions = ["Show", "Back to list"]
        choice = @prompt.select("#{job.fetch('id')} — #{job.fetch('title')}", actions, title: "Worker", custom: false)
        case choice
        when "Show"
          load_implementation_session(session_store, job)
        when "Back to list"
          open_worker_list(nil, session_store)
        end
      end

      def open_background_worker_actions(job, session_store)
        actions = ["Show"]
        actions << "Cancel" if %w[queued running].include?(job["status"])
        actions << "Back to list"
        choice = @prompt.select("#{job.fetch('id')} — #{job.fetch('title')}", actions, title: "Worker", custom: false)
        case choice
        when "Show"
          worker = @worker_manager&.find(job.fetch("id"))
          path = job["session_path"] || worker&.session&.path
          return runtime_output("Worker #{job.fetch('id')} session is not ready yet.") unless path

          load_worker_session(session_store, path, job, worker: worker)
        when "Cancel"
          @worker_manager&.cancel(job.fetch("id"))
          runtime_output("Worker #{job.fetch('id')} cancelled.")
        when "Back to list"
          open_worker_list(nil, session_store)
        end
      end

      def load_implementation_session(session_store, job)
        return runtime_output("Implementation session unavailable.") unless session_store

        stop_live_worker_view
        @active_worker_role = "implementation"
        load_session(session_store, job.fetch("session_path"), message: "Showing implementation worker")
      rescue StandardError => e
        runtime_output("Error: #{e.message}")
        nil
      end

      def open_scout_actions(id, agent, session_store)
        job = require_scout(id)
        actions = ["Show"]
        actions << "Start from report" if job["status"] == "ready"
        actions << "Cancel" if %w[queued running].include?(job["status"])
        actions << "Dismiss"
        actions << "Back to list"
        choice = @prompt.select("#{job.fetch('id')} — #{job.fetch('title')}", actions, title: "Scout", custom: false)
        case choice
        when "Show"
          show_scout(job.fetch("id"), session_store)
        when "Start from report"
          use_scout(job.fetch("id"))
        when "Cancel"
          cancel_scout(job.fetch("id"))
        when "Dismiss"
          dismiss_scout(job.fetch("id"))
        when "Back to list"
          open_scout_list(agent, session_store)
        end
      end

      def scout_choice_label(job)
        worker_choice_label(job)
      end

      def worker_choice_label(job)
        role = job["role"] || "scout"
        error = job["status"] == "failed" && !job["error"].to_s.empty? ? " — #{job['error']}" : ""
        "#{job.fetch('id')} [#{role}/#{job.fetch('status')}] #{job.fetch('title')}#{error}"
      end

      def show_scout(id, session_store)
        job = require_scout(id)
        remember_implementation_worker(nil) if @active_worker_role == "implementation"
        worker = @scout_runner&.worker(job.fetch("id"))
        path = worker_session_path(job) || worker&.session&.path
        return load_worker_session(session_store, path, job, worker: worker) if path

        runtime_output(scout_report_text(job))
        nil
      end

      def worker_session_path(job)
        path = job["session_path"].to_s
        return nil if path.empty?
        return path if File.file?(path)

        nil
      end

      def load_worker_session(session_store, path, job, worker: nil)
        unless session_store
          runtime_output(scout_report_text(job))
          return nil
        end

        agent = load_session(session_store, path, message: "Showing worker #{job.fetch('id')}")
        agent = build_worker_agent(agent.conversation, role: job["role"] || "scout")
        @active_worker_role = job["role"] || "scout"
        start_live_worker_view(worker, agent) if live_worker?(worker)
        agent
      rescue StandardError => e
        runtime_output("Error: #{e.message}")
        nil
      end

      def live_worker?(worker)
        worker && %w[queued running].include?(worker.status)
      end

      def start_live_worker_view(worker, agent)
        return unless prompt_interface?

        stop_live_worker_view
        renderer = live_worker_renderer(worker)
        @live_worker_view = Workers::LiveView.new(worker: worker, agent: agent, renderer: renderer).start
        runtime_output("Watching worker #{worker.id}; the view will update until it finishes.")
      end

      def stop_live_worker_view
        @live_worker_view&.stop
        @live_worker_view = nil
      end

      def live_worker_renderer(worker)
        markdown_chunks = []
        stream_state = {
          streamed: false,
          last_flush: monotonic_now,
          stream_block_open: false,
          markdown_streams: {},
          defer_assistant_streaming: false
        }
        lambda do |event, agent|
          if event == :flush
            flush_interactive_markdown_deltas(markdown_chunks, stream_state, force: worker_finished?(worker))
            next
          end

          notify_plugin_transcript_event(event, agent.respond_to?(:conversation) ? agent.conversation : nil)
          handle_live_worker_event(event, markdown_chunks, stream_state)
          flush_interactive_markdown_deltas(markdown_chunks, stream_state, force: worker_finished?(worker))
        rescue StandardError => e
          runtime_output("Worker view error: #{e.message}")
        end
      end

      def handle_live_worker_event(event, markdown_chunks, stream_state)
        case event
        when Events::AssistantMessage
          return if stream_state[:streamed]

          render_assistant_message(event.message)
        else
          handle_interactive_event(event, markdown_chunks, stream_state)
        end
      end

      def worker_finished?(worker)
        %w[ready failed cancelled archived].include?(worker.status)
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
        @scout_runner ||= Scouts::Runner.new(
          store: scout_store,
          client: Client.new,
          prompt: @prompt,
          workspace_root: current_workspace_root,
          session_store: @session_store,
          provider: current_model_provider,
          model: current_model_id,
          reasoning_effort: current_reasoning_effort,
          write_lock: (@worker_write_lock ||= Workers::WriteLock.new)
        )
      end

    end
  end
end
