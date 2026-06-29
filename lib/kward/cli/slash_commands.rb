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
        when "workers"
          unless experimental_workers_enabled?
            runtime_output("Workers are experimental. Start Kward with --experimental-workers to enable /workers.")
            return [true, nil]
          end

          [true, handle_workers_command(argument, agent, session_store)]
        when "queue"
          unless experimental_workers_enabled?
            runtime_output("Worker queues are experimental. Start Kward with --experimental-workers to enable /queue.")
            return [true, nil]
          end

          handle_worker_queue_command(argument, agent, session_store)
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
          if interactive_command_for(name) && prompt_interface? && @prompt.respond_to?(:start_interactive)
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

      def handle_worker_queue_command(argument, agent, session_store)
        action, value = argument.to_s.strip.split(/\s+/, 2)
        case action
        when nil, "", "status", "list"
          show_worker_queue
        when "add", "enqueue"
          enqueue_active_tab(value, agent)
        when "run", "next"
          run_next_worker_queue_job(session_store)
        else
          runtime_output("Usage: /queue [add|list|status|run]")
        end
      end

      def worker_queue_store
        @worker_queue_store ||= Workers::QueueStore.new
      end

      def enqueue_active_tab(title, agent)
        session = @active_session
        unless session&.path
          runtime_output("No active persisted session to queue.")
          return
        end

        job = worker_queue_store.enqueue(
          title: worker_queue_title(title, session, agent),
          session_path: session.path,
          workspace_root: session.cwd || current_workspace_root
        )
        runtime_output("Queued worker #{job.id}: #{job.title}")
      end

      def worker_queue_title(title, session, agent)
        explicit = title.to_s.strip
        return explicit unless explicit.empty?

        session_name = session&.name.to_s.strip
        return session_name unless session_name.empty?

        last_user = if agent&.respond_to?(:conversation)
                      agent.conversation.messages.reverse.find { |message| MessageAccess.role(message) == "user" }
                    end
        content = MessageAccess.content(last_user).to_s.strip.gsub(/\s+/, " ")
        content.empty? ? "Queued worker" : content[0, 80]
      end

      def run_next_worker_queue_job(session_store)
        unless session_store
          runtime_output("Worker queue requires persisted sessions.")
          return
        end

        record = worker_queue_runner(session_store).run_next
        if record
          runtime_output("Worker #{record.fetch('id')} finished with status #{record.fetch('status')}.")
        else
          runtime_output("Worker queue has no queued jobs.")
        end
      end

      def worker_queue_runner(session_store)
        Workers::QueueRunner.new(
          queue_store: worker_queue_store,
          session_store: session_store,
          client_factory: -> { Client.new },
          prompt: @prompt,
          workspace_root: current_workspace_root,
          provider: current_model_provider,
          model: current_model_id,
          reasoning_effort: current_reasoning_effort,
          write_lock: (@worker_write_lock ||= Workers::WriteLock.new)
        )
      end

      def show_worker_queue
        jobs = worker_queue_store.list
        if jobs.empty?
          runtime_output("Worker queue is empty.")
          return
        end

        lines = ["Worker queue:"]
        jobs.each do |job|
          details = [job.fetch("id"), "[#{job.fetch('status')}]"]
          details << "##{job['position']}" if job["position"]
          details << job.fetch("title")
          details << "commit #{job['commit_sha']}" unless job["commit_sha"].to_s.empty?
          details << "error: #{job['error']}" unless job["error"].to_s.empty?
          lines << "- #{details.join(' ')}"
        end
        runtime_output(lines.join("\n"))
      end

      def handle_workers_command(argument, agent, session_store)
        action, value = argument.to_s.strip.split(/\s+/, 2)
        replacement_agent = case action
                            when nil, ""
                              open_worker_menu(agent, session_store)
                            when "list"
                              open_worker_list(agent, session_store)
                            when "new", "do"
                              prompt_for_worker_request(agent, value)
                              nil
                            else
                              runtime_output("Usage: /workers | /workers new | /workers list")
                              nil
                            end
        replacement_agent?(replacement_agent) ? replacement_agent : nil
      end

      def worker_store
        @worker_store ||= Workers::Store.new
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
          worker_store: worker_store,
          write_lane_available: -> { !@foreground_turn_active }
        )
      end

      def open_worker_menu(agent, session_store)
        return runtime_output("Usage: /workers | /workers new | /workers list") unless @prompt.respond_to?(:select)

        choice = @prompt.select(
          "Workers",
          ["New worker", "List workers"],
          title: "Workers",
          custom: false
        )
        case choice
        when "New worker"
          prompt_for_worker_request(agent)
        when "List workers"
          open_worker_list(agent, session_store)
        end
      end

      def prompt_for_worker_request(agent, topic = nil)
        topic = @prompt.ask("Worker task>") if topic.to_s.strip.empty? && @prompt.respond_to?(:ask)
        send_worker_request(topic, agent) unless topic.to_s.strip.empty?
      end

      def send_worker_request(topic, agent)
        if topic.to_s.strip.empty?
          runtime_output("Usage: /workers new <task>")
          return
        end

        worker = worker_manager(agent).start(role: "request", prompt: topic)
        runtime_output("Worker #{worker.id} started: #{worker.title}")
      end

      def open_worker_list(agent, session_store, title: "Workers", empty_message: "No workers in the pipeline.")
        return runtime_output(empty_message) unless @prompt.respond_to?(:select)

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
        persisted_workers = worker_store.list.reject { |job| runtime_worker_ids.include?(job["id"]) }
        live_workers = @worker_manager ? @worker_manager.list.map(&:to_h) : []
        [implementation_worker_job(agent)].compact + persisted_workers + live_workers
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

      def open_worker_actions(job, _agent, session_store)
        return open_implementation_actions(job, session_store) if job["id"] == "implementation"

        open_background_worker_actions(job, session_store)
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

      def handle_request_worker_input(input, agent, session_store)
        return [false, nil] unless @active_worker_role == "request"

        worker = visible_request_worker(agent)
        return [false, nil] unless worker

        text = input.to_s.strip
        return [true, nil] if text.empty?
        return [true, proceed_request_worker(worker.to_h, agent, session_store)] if proceed_request_input?(text)

        runtime_output("Worker #{worker.id} is a read-only request review. Reply yes/proceed to queue implementation, or use /workers to switch workers.")
        [true, nil]
      end

      def visible_request_worker(agent)
        worker = @visible_worker
        return worker if worker&.role == "request" && worker.status == "ready"

        id = @visible_worker_id.to_s
        return nil if id.empty? || id == "implementation"

        worker = @worker_manager&.find(id)
        return worker if worker&.role == "request" && worker.status == "ready"

        job = worker_store.find(id)
        return nil unless job && job["role"] == "request" && job["status"] == "ready"
        return nil if job["session_path"].to_s.empty? || !session_matches_agent?(job["session_path"], agent)

        Workers::Worker.new(
          id: job.fetch("id"),
          title: job.fetch("title"),
          role: job.fetch("role"),
          workspace_root: job["workspace_root"] || current_workspace_root,
          status: job.fetch("status"),
          prompt: job["prompt"]
        ).tap { |restored| restored.update_status("ready", report: job["report"], error: job["error"]) }
      end

      def session_matches_agent?(path, agent)
        return true unless agent.respond_to?(:conversation)
        return false unless @active_session&.path

        File.expand_path(path) == File.expand_path(@active_session.path)
      end

      def proceed_request_input?(input)
        input.downcase.strip.match?(/\A(?:y|yes|yeah|yep|sure|ok|okay|go ahead|proceed|continue|implement|do it|please do|make it so)\b/)
      end

      def proceed_request_worker(job, agent, session_store)
        return runtime_output("Worker #{job.fetch('id')} is not ready to proceed.") unless request_ready?(job)

        release_implementation_writer
        manager = worker_manager(agent || build_session_agent_for_worker(job, session_store))
        worker = manager.continue(
          job.fetch("id"),
          role: "implementation",
          prompt: implementation_prompt_for_request(job),
          title: "Implement #{job.fetch('title')}"
        )
        runtime_output("Worker #{worker.id} queued from request #{job.fetch('id')}: #{worker.title}")
        wait_for_worker_session(worker)
        load_worker_session(session_store, worker.session.path, worker.to_h, worker: worker) if worker.session&.path
      rescue StandardError => e
        runtime_output("Error: #{e.message}")
        nil
      end

      def wait_for_worker_session(worker, timeout: 1.0)
        deadline = Time.now + timeout
        until worker.session&.path || Time.now >= deadline
          sleep 0.02
        end
      end

      def build_session_agent_for_worker(job, session_store)
        conversation = Conversation.new(workspace_root: job["workspace_root"] || session_store&.cwd || current_workspace_root)
        build_worker_agent(conversation, role: "request")
      end

      def request_ready?(job)
        job["role"] == "request" && job["status"] == "ready"
      end

      def implementation_prompt_for_request(job)
        <<~PROMPT
          The user reviewed and approved this Kward request. Continue in the write-capable implementation lane.

          Original request:
          #{job["prompt"]}

          Request review:
          #{job["report"].to_s.empty? ? "No saved review text is available. Use the request session transcript for context if needed." : job["report"]}

          Implement the approved next step. Make the smallest correct change, preserve existing style, and run focused verification when practical.
          If you change files, commit the changes and report the commit hash. If no file changes are needed, explain why.
        PROMPT
      end

      def open_background_worker_actions(job, session_store)
        actions = ["Show"]
        actions << "Proceed" if request_ready?(job)
        actions << "Cancel" if %w[queued running].include?(job["status"])
        actions << "Dismiss"
        actions << "Back to list"
        choice = @prompt.select("#{job.fetch('id')} — #{job.fetch('title')}", actions, title: "Worker", custom: false)
        case choice
        when "Show"
          worker = @worker_manager&.find(job.fetch("id"))
          path = job["session_path"] || worker&.session&.path
          return runtime_output("Worker #{job.fetch('id')} session is not ready yet.") unless path

          load_worker_session(session_store, path, job, worker: worker)
        when "Proceed"
          proceed_request_worker(job, nil, session_store)
        when "Cancel"
          @worker_manager&.cancel(job.fetch("id"))
          runtime_output("Worker #{job.fetch('id')} cancelled.")
        when "Dismiss"
          dismiss_worker(job.fetch("id"))
          runtime_output("Worker #{job.fetch('id')} dismissed.")
        when "Back to list"
          open_worker_list(nil, session_store)
        end
      end

      def dismiss_worker(id)
        @worker_manager&.archive(id)
      rescue ArgumentError
        nil
      ensure
        worker_store.archive(id)
      end

      def load_implementation_session(session_store, job)
        return runtime_output("Implementation session unavailable.") unless session_store

        stop_live_worker_view
        @active_worker_role = "implementation"
        set_visible_worker("implementation", status: "active")
        load_session(session_store, job.fetch("session_path"), message: "Showing implementation worker")
      rescue StandardError => e
        runtime_output("Error: #{e.message}")
        nil
      end

      def worker_choice_label(job)
        error = job["status"] == "failed" && !job["error"].to_s.empty? ? " — #{job['error']}" : ""
        "#{job.fetch('id')} [#{job.fetch('role')}/#{job.fetch('status')}] #{job.fetch('title')}#{error}"
      end

      def load_worker_session(session_store, path, job, worker: nil)
        unless session_store
          runtime_output(worker_report_text(job))
          return nil
        end

        release_implementation_writer
        agent = load_session(session_store, path, message: "Showing worker #{job.fetch('id')}")
        release_implementation_writer
        role = visible_session_role(job)
        agent = build_worker_agent(agent.conversation, role: role)
        @active_worker_role = role
        set_visible_worker(job.fetch("id"), status: job["status"], worker: worker)
        @prompt.redraw if @prompt.respond_to?(:redraw)
        start_live_worker_view(worker, agent) if live_worker?(worker)
        agent
      rescue StandardError => e
        runtime_output("Error: #{e.message}")
        nil
      end

      def visible_session_role(job)
        return "read_only" if job["id"] != "implementation" && job["role"] == "implementation"

        job["role"] || "request"
      end

      def live_worker?(worker)
        worker && %w[queued running].include?(worker.status)
      end

      def start_live_worker_view(worker, agent)
        return unless prompt_interface?

        stop_live_worker_view
        renderer = live_worker_renderer(worker)
        @live_worker_view = Workers::LiveView.new(worker: worker, agent: agent, renderer: renderer).start
        @prompt.redraw if @prompt.respond_to?(:redraw)
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
            @prompt.redraw if @prompt.respond_to?(:redraw)
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

      def worker_report_text(job)
        lines = ["Worker #{job.fetch('id')} [#{job.fetch('status')}] #{job.fetch('title')}", ""]
        if job["report"].to_s.empty?
          lines << (job["error"].to_s.empty? ? "No report yet." : "Error: #{job['error']}")
        else
          lines << job["report"]
        end
        lines.join("\n")
      end

    end
  end
end
