require "json"
require "thread"
require_relative "../cancellation"

# Namespace for the Kward CLI agent runtime.
module Kward
  # Command-line frontend that coordinates terminal interaction, sessions, tools, and model turns.
  class CLI
    # TUI session tab coordination and asynchronous turn execution.
    module Tabs
      WORKTREE_AGENT_CONTEXT = <<~PROMPT.strip.freeze
        This is an active Git worktree tab. The workspace is sandboxed separately from the host repository metadata.
        When the user explicitly asks you to commit, use the advertised `git_commit` tool. Do not use `run_shell_command` for `git add` or `git commit`, because shared Git metadata is intentionally protected there.
        `git_commit` requires a commit message and accepts optional workspace-relative paths; omit paths to include all current changes in this worktree. Do not create a commit unless the user requested one.
      PROMPT

      TabRuntime = Struct.new(
        :session,
        :agent,
        :driver,
        :diff,
        :snapshot,
        :status,
        :thread,
        :cancellation,
        :event_history,
        :seen_events,
        :queued_inputs,
        :steering,
        :error,
        :answer,
        :stream_state,
        :markdown_chunks,
        :label,
        :unread,
        :pending_question,
        :shell,
        :error_reported,
        :local_busy_activity,
        keyword_init: true
      ) do
        def running?
          %w[queued running waiting_for_question].include?(status.to_s)
        end

        def local_busy?
          !local_busy_activity.to_s.empty?
        end

        def idle?
          !running? && !local_busy?
        end

        def record_event(event)
          event_history << event
        end
      end

      class TabQuestionPrompt
        attr_accessor :tab

        def initialize(cli)
          @cli = cli
        end

        def ask_user_question(questions, cancellation: nil)
          @cli.send(:ask_tab_user_question, @tab, questions, cancellation: cancellation)
        end

        def ask_tool_approval(tool_name:, args:, reason: nil)
          answers = ask_user_question([
            {
              header: "Approval required · #{tool_name.to_s.tr("_", " ").capitalize}",
              question: (["The agent wants to use #{tool_name}.", "Arguments:\n#{JSON.pretty_generate(args.to_h)}", reason].compact).join("\n"),
              options: [
                { label: "Allow once", description: "Run this tool call." },
                { label: "Allow this tool for this session", description: "Run this call and future calls to #{tool_name}." },
                { label: "Deny", description: "Do not run this tool call." }
              ]
            }
          ])
          answer = answers&.first
          return { denied_message: answer[:answer] } if answer&.fetch(:custom, false) && !answer[:answer].to_s.empty?

          case answer&.fetch(:answer, nil)
          when "Allow once" then true
          when "Allow this tool for this session" then :allow_for_session
          else false
          end
        end
      end

      private

      def setup_interactive_tabs(session_store, agent)
        @tabs = []
        @active_tab_index = 0
        @tab_store = session_store ? TabStore.new(config_dir: session_store.config_dir, cwd: session_store.cwd) : nil
        @tab_live_view = nil
        @restored_tabs = false
        restored = restore_tabs(session_store) if session_store && agent.nil?
        return restored if restored

        if agent.nil? && (resumed_agent = resume_last_session(session_store))
          restored_agent = build_tab_agent(resumed_agent.conversation, @active_session)
          @tabs << build_tab(@active_session, restored_agent, driver: SessionTabDriver.new(session: @active_session, agent: restored_agent), label: default_tab_label(0))
          return activate_tab(0, render: false)
        end

        if agent
          @active_session = track_session(session_store.create(provider: current_model_provider, model: current_model_id, reasoning_effort: current_reasoning_effort))
          @active_session.attach(agent.conversation)
          tab_agent = build_tab_agent(agent.conversation, @active_session)
        else
          @active_session = track_session(session_store.create(provider: current_model_provider, model: current_model_id, reasoning_effort: current_reasoning_effort))
          conversation = new_conversation(workspace_root: session_store.cwd)
          @active_session.attach(conversation)
          tab_agent = build_tab_agent(conversation, @active_session)
        end
        @tabs << build_tab(@active_session, tab_agent, driver: SessionTabDriver.new(session: @active_session, agent: tab_agent), label: default_tab_label(0))
        activate_tab(0, render: false)
      end

      def restore_tabs(session_store)
        data = @tab_store&.load || {}
        descriptors = Array(data["tabs"])
        return nil if descriptors.empty?

        descriptors.each_with_index do |descriptor, index|
          tab = build_tab_from_descriptor(descriptor, session_store, label: restored_tab_label(data, index))
          @tabs << tab if tab
        rescue StandardError => e
          descriptor = descriptor.transform_keys(&:to_s) if descriptor.respond_to?(:transform_keys)
          if descriptor.is_a?(Hash) && descriptor.key?("worktree")
            @tabs << unavailable_worktree_tab(descriptor, e, label: restored_tab_label(data, index))
          end
        end
        return nil if @tabs.empty?

        @active_tab_index = [[data["active_index"].to_i, 0].max, @tabs.length - 1].min
        @restored_tabs = true
        activate_tab(@active_tab_index)
      end

      def build_tab_from_descriptor(descriptor, session_store, label: nil)
        descriptor = descriptor.transform_keys(&:to_s)
        if descriptor["kind"] == "session"
          worktree = if descriptor.key?("worktree")
            binding = GitWorktreeBinding.from_descriptor(descriptor["worktree"])
            raise GitWorktreeManager::Error, "Invalid worktree binding." unless binding

            binding
          end
          validate_worktree_binding!(worktree)
          root = worktree_root_for(worktree, fallback: session_store.cwd)
          session, conversation = restore_tab_session(session_store, descriptor.fetch("session_path"), workspace_root: root, strict: worktree&.active? == true)
          agent = build_tab_agent(conversation, session, worktree: worktree)
          return build_tab(session, agent, driver: SessionTabDriver.new(session: session, agent: agent, worktree: worktree), label: label)
        end

        tab_type = plugin_registry.tab_type_for_id(descriptor["plugin_tab_type"])
        driver = if tab_type
          host = PluginTabHost.new(client: @client, workspace_root: session_store.cwd)
          tab_type.handler.call(host, descriptor)
        else
          UnavailableTabDriver.new(descriptor: descriptor, message: "Plugin tab #{descriptor["plugin_tab_type"].inspect} is unavailable.")
        end
        raise "Plugin tab #{descriptor["plugin_tab_type"].inspect} did not return a tab driver." unless driver
        build_tab(nil, nil, driver: driver, label: label || descriptor["label"] || tab_type&.title)
      end

      def open_plugin_tab(name, session_store)
        tab_type = plugin_registry.tab_type_for(name)
        return runtime_output("Plugin tab #{name.inspect} is not available.") unless tab_type

        if tab_type.singleton == :global && (existing = @tabs.find { |tab| tab.driver.descriptor["plugin_tab_type"] == tab_type.id })
          return switch_tab(@tabs.index(existing))
        end

        save_active_tab_state
        stop_tab_live_view
        descriptor = { "kind" => "plugin", "plugin_tab_type" => tab_type.id, "label" => tab_type.title }
        host = PluginTabHost.new(client: @client, workspace_root: session_store.cwd)
        driver = tab_type.handler.call(host, descriptor)
        raise "Plugin tab #{name.inspect} did not return a tab driver." unless driver

        @tabs << build_tab(nil, nil, driver: driver, label: tab_type.title)
        @active_tab_index = @tabs.length - 1
        activate_tab(@active_tab_index)
      rescue StandardError => e
        runtime_output("Could not open plugin tab #{name.inspect}: #{e.message}")
      end

      def restore_tab_session(session_store, path, workspace_root: session_store.cwd, strict: false)
        if File.file?(path)
          session, conversation = session_store.load(path, workspace: configured_workspace(root: workspace_root, strict: strict), provider: current_model_provider, model: current_model_id, reasoning_effort: current_reasoning_effort)
          return [track_session(session), conversation]
        end

        session = track_session(session_store.create(provider: current_model_provider, model: current_model_id, reasoning_effort: current_reasoning_effort))
        conversation = new_conversation(workspace_root: workspace_root)
        session.attach(conversation)
        [session, conversation]
      end

      def build_tab_agent(conversation, _session, worktree: nil)
        conversation.plugin_registry ||= plugin_registry if conversation.respond_to?(:plugin_registry)
        strict = worktree&.active? == true
        update_worktree_agent_context(conversation, strict)
        workspace = configured_workspace(root: conversation.workspace_root, strict: strict)
        prompt = TabQuestionPrompt.new(self)
        hook_manager = strict ? nil : lifecycle_hook_manager(conversation)
        hook_context = strict ? nil : lifecycle_hook_context(conversation)
        git_committer = if strict
                          ->(message:, paths:) { git_commit_for_agent(workspace.root.to_s, message: message, paths: paths) }
                        end
        tool_registry = ToolRegistry.new(
          workspace: workspace,
          prompt: prompt,
          tool_approval: tab_tool_approval_callback(prompt),
          hook_manager: hook_manager,
          hook_context: hook_context,
          mcp_clients: strict ? [] : nil,
          git_committer: git_committer
        )
        @footer_conversation = conversation
        @footer_tool_registry = tool_registry
        agent = Agent.new(
          client: @client,
          tool_registry: tool_registry,
          conversation: conversation,
          hook_manager: hook_manager,
          hook_context: hook_context
        )
        agent.instance_variable_set(:@tab_question_prompt, prompt)
        agent
      end

      def update_worktree_agent_context(conversation, strict)
        desired = strict ? WORKTREE_AGENT_CONTEXT : nil
        return if conversation.execution_profile_context == desired
        return unless strict || conversation.execution_profile_context == WORKTREE_AGENT_CONTEXT

        conversation.update_execution_profile_context!(desired)
      end

      def tab_tool_approval_callback(prompt)
        return nil unless ConfigFiles.permission_policy(safely_read_config.to_h).enabled?

        lambda do |tool_call:, name:, args:, cancellation:|
          prompt.ask_tool_approval(tool_name: name, args: args, reason: args["hook_message"] || args[:hook_message])
        end
      end

      def build_tab(session, agent, driver: nil, label: nil)
        driver ||= SessionTabDriver.new(session: session, agent: agent)
        TabRuntime.new(
          session: session,
          agent: agent,
          driver: driver,
          diff: session&.path ? SessionDiff.from_session_file(session.path) : SessionDiff.new,
          snapshot: nil,
          status: "idle",
          thread: nil,
          cancellation: nil,
          event_history: [],
          seen_events: 0,
          queued_inputs: [],
          steering: nil,
          error: nil,
          answer: nil,
          stream_state: new_tab_stream_state(driver),
          markdown_chunks: [],
          label: label,
          unread: false,
          pending_question: nil,
          shell: nil,
          error_reported: false,
          local_busy_activity: nil
        ).tap { |tab| assign_tab_question_prompt(agent, tab) }
      end

      def active_tab
        @tabs && @tabs[@active_tab_index]
      end

      def plugin_tab?(tab = active_tab)
        tab && tab.session.nil?
      end

      def plugin_tab_command_allowed?(command)
        name, = parse_slash_command(command)
        return true if %w[tab exit quit].include?(name)

        active_tab.driver.respond_to?(:handles_command?) && active_tab.driver.handles_command?(command)
      end

      def assign_tab_question_prompt(agent, tab)
        prompt = agent.instance_variable_get(:@tab_question_prompt) if agent
        prompt.tab = tab if prompt.respond_to?(:tab=)
      end

      def ask_tab_user_question(tab, questions, cancellation: nil)
        return @prompt.ask_user_question(questions) unless tab
        return "Error: ask_user_question requires interactive prompt support." unless @prompt.respond_to?(:ask_user_question)

        request = {
          questions: questions,
          answers: Queue.new,
          cancellation: cancellation
        }
        cancellation&.on_cancel { request[:answers] << nil }
        tab.pending_question = request
        tab.status = "waiting_for_question"
        update_prompt_tabs

        answers = request[:answers].pop
        cancellation&.raise_if_cancelled!
        answers
      ensure
        if tab&.pending_question.equal?(request)
          tab.pending_question = nil
          tab.status = "running" if tab.status == "waiting_for_question"
          update_prompt_tabs
        end
      end

      def service_active_tab_question
        tab = active_tab
        request = tab&.pending_question
        return false unless request

        tab.pending_question = nil
        answers = @prompt.ask_user_question(request[:questions])
        tab.status = "running" if tab.status == "waiting_for_question"
        update_prompt_tabs
        request[:answers] << answers
        true
      end

      def handle_tab_action(action, session_store)
        case action[:tab_action]
        when :new
          open_new_tab(session_store)
        when :close
          close_active_tab
        when :next
          switch_tab((@active_tab_index + 1) % @tabs.length) if @tabs && @tabs.length > 1
        when :previous
          switch_tab((@active_tab_index - 1) % @tabs.length) if @tabs && @tabs.length > 1
        when :select
          switch_tab(action[:index].to_i) if @tabs && action[:index].to_i < @tabs.length
        end
      end

      def open_new_tab(session_store)
        return say_sessions_unavailable unless session_store

        save_active_tab_state
        stop_tab_live_view
        session = track_session(session_store.create(provider: current_model_provider, model: current_model_id, reasoning_effort: current_reasoning_effort))
        conversation = new_conversation(workspace_root: session_store.cwd)
        session.attach(conversation)
        agent = build_tab_agent(conversation, session)
        @tabs << build_tab(session, agent, driver: SessionTabDriver.new(session: session, agent: agent), label: default_tab_label(@tabs.length))
        @active_tab_index = @tabs.length - 1
        activate_tab(@active_tab_index)
      end

      def close_active_tab
        tab = active_tab
        if tab&.running? || tab&.local_busy?
          runtime_output("Tab #{active_tab_number} is running and cannot be closed yet.")
          return nil
        end

        if @tabs.length <= 1
          @tabs.clear
          persist_tabs
          return PromptInterface::EXIT_INPUT
        end

        stop_tab_live_view
        tab.session&.delete_if_unused if tab&.session.respond_to?(:delete_if_unused)
        tab.driver.close if tab.driver.respond_to?(:close)
        @tabs.delete_at(@active_tab_index)
        @active_tab_index = [@active_tab_index, @tabs.length - 1].min
        activate_tab(@active_tab_index)
        nil
      end

      def switch_tab(index)
        return if index == @active_tab_index
        return unless index.between?(0, @tabs.length - 1)

        save_active_tab_state
        stop_tab_live_view
        @active_tab_index = index
        activate_tab(index)
      end

      def replace_active_tab_agent(agent)
        tab = active_tab
        return agent unless tab

        tab.session = @active_session
        worktree = reconcile_worktree_binding(tab, agent.conversation)
        tab.agent = build_tab_agent(agent.conversation, tab.session, worktree: worktree)
        tab.driver = SessionTabDriver.new(session: tab.session, agent: tab.agent, worktree: worktree)
        assign_tab_question_prompt(tab.agent, tab)
        tab.diff = @session_diff || (tab.session&.path ? SessionDiff.from_session_file(tab.session.path) : SessionDiff.new)
        tab.snapshot = nil
        tab.status = "idle"
        tab.error = nil
        tab.answer = nil
        tab.unread = false
        tab.error_reported = false
        tab.event_history.clear
        tab.seen_events = 0
        tab.queued_inputs.clear
        tab.steering = nil
        tab.shell = nil
        tab.stream_state = new_tab_stream_state(tab.driver)
        tab.markdown_chunks.clear
        update_prompt_tabs
        persist_tabs
        tab.agent
      end

      def save_active_tab_state
        tab = active_tab
        return unless tab

        if @prompt.respond_to?(:tab_view_snapshot)
          tab.snapshot = @prompt.tab_view_snapshot
        elsif @prompt.respond_to?(:composer_snapshot)
          tab.snapshot = @prompt.composer_snapshot
        end
        tab.diff = @session_diff
      end

      def activate_tab(index, render: true)
        tab = @tabs[index]
        return nil unless tab

        @active_session = tab.session
        @session_diff = tab.diff || SessionDiff.new
        if tab.agent
          @footer_conversation = tab.agent.conversation
          @footer_tool_registry = tab.agent.tool_registry if tab.agent.respond_to?(:tool_registry)
          update_assistant_prompt(tab.agent.conversation)
        else
          @footer_conversation = nil
          @footer_tool_registry = nil
          @assistant_prompt = "#{tab.driver.assistant_label || "Plugin"}>"
          @prompt.update_assistant_label(assistant_prompt_name) if @prompt.respond_to?(:update_assistant_label)
        end
        tab.unread = false
        restore_tab_composer_snapshot(tab.snapshot)
        @prompt.refresh_composer_status if @prompt.respond_to?(:refresh_composer_status)
        update_plugin_tab_slash_commands(tab)
        update_prompt_tabs
        render_tab(tab) if render
        start_tab_live_view(tab) if tab.running?
        @prompt.begin_busy_input("You>", activity: tab.local_busy_activity) if tab.local_busy? && @prompt.respond_to?(:begin_busy_input)
        persist_tabs
        service_active_tab_question
        tab.agent
      end

      def render_tab(tab)
        if tab.snapshot && @prompt.respond_to?(:restore_tab_view_snapshot) && (tab.running? || tab.shell)
          @prompt.restore_tab_view_snapshot(tab.snapshot)
          return
        end

        restore_prompt_transcript do
          if tab.agent && empty_tab_conversation?(tab.agent.conversation)
            print_visual_banner
          else
            render_transcript_messages(tab.driver.messages)
          end
          report_tab_runtime_error(tab) if %w[failed cancelled].include?(tab.status.to_s)
        end
        restore_tab_composer_snapshot(tab.snapshot)
      end

      def restore_tab_composer_snapshot(snapshot)
        return unless @prompt.respond_to?(:restore_composer_snapshot)

        @prompt.restore_composer_snapshot(snapshot || {})
      end

      def empty_tab_conversation?(conversation)
        conversation.messages.none? do |message|
          role = message["role"] || message[:role]
          role != "system"
        end
      end

      def report_tab_runtime_error(tab)
        return if tab.error_reported

        message = tab_runtime_error_message(tab)
        return if message.empty?

        tab.error_reported = true
        runtime_output(message)
      end

      def tab_runtime_error_message(tab)
        number = tab_number(tab)
        case tab.status.to_s
        when "failed"
          error = tab.error.to_s.strip
          error.empty? ? "Tab #{number} error." : "Tab #{number} error: #{error}"
        when "cancelled"
          "Tab #{number} cancelled."
        else
          ""
        end
      end

      def tab_number(tab)
        index = @tabs&.index(tab)
        index ? index + 1 : active_tab_number
      end

      def submit_tab_input(tab, input, display_input: nil)
        return if input.to_s.strip.empty?

        save_active_tab_state
        start_tab_turn(tab, input, display_input: display_input)
        start_tab_live_view(tab) if tab == active_tab
      end

      def start_tab_turn(tab, input, display_input: nil)
        prepare_memory_context(tab.agent.conversation, input) if tab.agent.respond_to?(:conversation)
        print_user_transcript(input, display_input: display_input) if prompt_interface?
        tab.status = "queued"
        tab.unread = false
        tab.cancellation = Cancellation.new
        tab.steering = tab.driver.supports_steering? && steering_supported? ? Steering.new : nil
        tab.error = nil
        tab.answer = nil
        tab.error_reported = false
        tab.event_history.clear
        tab.seen_events = 0
        tab.markdown_chunks.clear
        tab.stream_state = new_tab_stream_state(tab.driver)
        update_prompt_tabs
        tab.thread = Thread.new { run_tab_turn(tab, input, display_input: display_input) }
        tab.thread.report_on_exception = false
        update_prompt_tabs
      end

      def run_tab_turn(tab, input, display_input: nil)
        tab.status = "running"
        update_prompt_tabs
        tab.answer = tab.driver.submit(input, display_input: display_input, cancellation: tab.cancellation, steering: tab.steering) do |event|
          tab.record_event(event)
        end
        tab.status = "ready"
        tab.unread = tab != active_tab
      rescue Cancellation::CancelledError
        tab.status = "cancelled"
        tab.unread = false
        report_tab_runtime_error(tab)
      rescue StandardError => e
        tab.error = e.message
        tab.status = "failed"
        tab.unread = false
        report_tab_runtime_error(tab)
      ensure
        finish_tab_turn(tab)
      end

      def finish_tab_turn(tab)
        persist_memory_state(tab.agent.conversation) if tab.agent.respond_to?(:conversation)
        auto_summarize_memory(tab.agent.conversation) if tab.agent.respond_to?(:conversation) && tab.queued_inputs.empty? && tab.status == "ready"
        tab.diff = tab.session&.path ? SessionDiff.from_session_file(tab.session.path) : tab.diff
        update_prompt_tabs
      rescue StandardError
        nil
      end

      def poll_active_tab_input
        tab = active_tab
        unless tab&.running?
          input = @prompt.ask("You>")
          return { tab_action: :close } if input.nil? && tab && @tabs.length > 1

          return input
        end

        @prompt.begin_busy_input("You>") if @prompt.respond_to?(:begin_busy_input)
        loop do
          refresh_active_tab
          if service_active_tab_question
            return next_tab_queued_input(tab) if tab.idle? && !tab.queued_inputs.empty?
            return :tab_idle if tab.idle?

            next
          end
          poll_result = @prompt.poll_input
          case poll_result
          when Hash
            if poll_result[:tab_action]
              @prompt.finish_busy_input if @prompt.respond_to?(:finish_busy_input)
              return poll_result
            end
          when PromptInterface::CANCEL_INPUT
            tab.cancellation&.cancel!
            tab.thread&.raise(Cancellation::CancelledError, "cancelled") if tab.thread&.alive?
          when PromptInterface::EXIT_INPUT
            tab.queued_inputs << "/exit"
            @prompt.set_queued_count(tab.queued_inputs.length) if @prompt.respond_to?(:set_queued_count)
          when String
            return { tab_action: :busy_command } if handle_tab_busy_input(tab, poll_result) == :active_tab_changed
          end
          return next_tab_queued_input(tab) if tab.idle? && !tab.queued_inputs.empty?
          return :tab_idle if tab.idle?

          sleep 0.01 if poll_result.nil?
        end
      ensure
        @prompt.finish_busy_input if @prompt.respond_to?(:finish_busy_input) && tab&.idle?
      end

      def next_tab_queued_input(tab)
        input = tab.queued_inputs.shift
        tab.queued_inputs.reverse_each { |queued| @pending_inputs.unshift(queued) } if defined?(@pending_inputs) && @pending_inputs
        tab.queued_inputs.clear
        input
      end

      def handle_tab_busy_input(tab, input)
        if busy_queued_command?(input)
          tab.queued_inputs << input
          @prompt.set_queued_count(tab.queued_inputs.length) if @prompt.respond_to?(:set_queued_count)
          return
        elsif busy_tab_command?(input)
          handle_tab_command(input.to_s.strip.sub(%r{\A/tab(?:\s+|\z)}, ""), @session_store)
          unless active_tab.equal?(tab)
            @prompt.finish_busy_input if @prompt.respond_to?(:finish_busy_input)
            return :active_tab_changed
          end

          restore_busy_input_prompt
          return
        elsif slash_command_input?(input)
          # Slash commands are local control actions. Running or queuing them
          # from the busy composer is surprising because the state they act on
          # may have changed by the time the active turn finishes.
          return
        end

        if tab.steering && !input.to_s.strip.empty?
          begin
            tab.steering.submit(input)
            @prompt.set_steered_count(1) if @prompt.respond_to?(:set_steered_count)
            return
          rescue StandardError
            # Fall through to queueing.
          end
        end
        tab.queued_inputs << input unless input.to_s.strip.empty?
        @prompt.set_queued_count(tab.queued_inputs.length) if @prompt.respond_to?(:set_queued_count)
      end

      def busy_tab_command?(input)
        input.to_s.strip.match?(%r{\A/tab(?:\s|\z)})
      end

      def refresh_active_tab
        tab = active_tab
        return unless tab

        if tab.thread && !tab.thread.alive? && tab.running?
          tab.thread.join
          tab.status = "ready" if tab.status == "running"
        end
        update_prompt_tabs
      end

      def start_tab_live_view(tab)
        return unless prompt_interface?

        stop_tab_live_view
        @tab_live_view_stop = false
        @tab_live_view = Thread.new { run_tab_live_view(tab) }
        @tab_live_view.report_on_exception = false
      end

      def stop_tab_live_view
        @tab_live_view_stop = true
        @tab_live_view&.join(0.2)
        @tab_live_view = nil
      end

      def run_tab_live_view(tab)
        renderer = tab_live_renderer(tab)
        until @tab_live_view_stop
          events = tab.event_history[tab.seen_events..] || []
          events.each { |event| renderer.call(event, tab.driver) }
          tab.seen_events += events.length
          if tab.idle?
            renderer.call(:flush, tab.driver)
            break
          end
          sleep 0.05
        end
      ensure
        @tab_live_view_stop = false if @tab_live_view == Thread.current
      end

      def tab_live_renderer(tab)
        lambda do |event, driver|
          if event == :flush
            flush_interactive_markdown_deltas(tab.markdown_chunks, tab.stream_state, force: true)
            render_tab_answer(tab)
            @prompt.redraw if @prompt.respond_to?(:redraw)
            next
          end

          if driver.respond_to?(:conversation)
            notify_plugin_transcript_event(event, driver.conversation)
          elsif plugin_tab_type_for(driver)&.transcript_events
            notify_plugin_tab_transcript_event(event, driver)
          end
          handle_interactive_event(event, tab.markdown_chunks, tab.stream_state)
          flush_interactive_markdown_deltas(tab.markdown_chunks, tab.stream_state)
        rescue StandardError => e
          runtime_output("Tab view error: #{e.message}")
        end
      end

      def plugin_tab_type_for(driver)
        plugin_registry.tab_type_for_id(driver.descriptor["plugin_tab_type"])
      end

      def render_tab_answer(tab)
        return unless tab.status == "ready"
        return if tab.stream_state[:streamed]
        return if tab.answer.to_s.empty?

        @prompt.say("\n#{colored(assistant_output_prompt, :green, :bold)} #{render_markdown_transcript(tab.answer)}\n")
      end

      def new_tab_stream_state(driver)
        {
          streamed: false,
          last_flush: monotonic_now,
          stream_block_open: false,
          markdown_streams: {},
          defer_assistant_streaming: driver.respond_to?(:conversation) && defer_assistant_streaming?(driver.agent)
        }
      end

      def tab_labels
        @tabs.each_with_index.map do |tab, index|
          label = tab.label.to_s.empty? ? default_tab_label(index) : tab.label.to_s
          binding = worktree_binding_for(tab)
          label = "#{label} · #{binding.branch}" if binding&.active?
          { name: label, color: tab_label_color(tab) }
        end
      end

      def tab_label_color(tab)
        return :green if tab.status.to_s == "waiting_for_question"
        return :yellow if tab.running? || tab.local_busy?
        return :red if %w[failed cancelled].include?(tab.status.to_s)
        return :green if tab.unread

        nil
      end

      def default_tab_label(index)
        index.zero? ? "Main" : "Tab"
      end

      def restored_tab_label(data, index)
        label = Array(data["labels"])[index].to_s
        label.empty? ? default_tab_label(index) : label
      end

      def handle_tab_command(argument, session_store)
        action, value = argument.to_s.strip.split(/\s+/, 2)
        case action
        when nil, ""
          runtime_output(tab_usage)
          nil
        when /^\d+$/
          switch_tab_number(action)
          active_tab&.agent
        when "move"
          move_active_tab(value)
          active_tab&.agent
        when "close"
          @pending_inputs.unshift("/exit") if close_active_tab == PromptInterface::EXIT_INPUT && defined?(@pending_inputs) && @pending_inputs
          active_tab&.agent
        when "new"
          open_new_tab(session_store)
          active_tab&.agent
        when "open"
          return runtime_output("Usage: /tab open <plugin-tab>") if value.to_s.strip.empty?

          open_plugin_tab(value.strip, session_store)
          active_tab&.agent
        when "name", "rename"
          rename_active_tab(value)
          active_tab&.agent
        when "worktree"
          handle_worktree_command(value)
          active_tab&.agent
        else
          runtime_output(tab_usage)
          nil
        end
      end

      def tab_usage
        "/tab 1-n | /tab move 1-n|left|right | /tab close | /tab new | /tab open <plugin-tab> | /tab name <label> | /tab worktree [activate|detach|status|merge|remove]"
      end

      def switch_tab_number(number)
        index = number.to_i - 1
        return switch_tab(index) if @tabs && index.between?(0, @tabs.length - 1)

        runtime_output("Tab #{number} does not exist.")
      end

      def move_active_tab(value)
        return runtime_output("Usage: /tab move 1-n|left|right") unless @tabs && @tabs.length > 1

        target_index = case value.to_s.strip
                       when /^\d+$/
                         value.to_i - 1
                       when "left"
                         @active_tab_index - 1
                       when "right"
                         @active_tab_index + 1
                       else
                         return runtime_output("Usage: /tab move 1-n|left|right")
                       end
        return runtime_output("Tab #{value} does not exist.") unless target_index.between?(0, @tabs.length - 1)
        return if target_index == @active_tab_index

        save_active_tab_state
        stop_tab_live_view
        tab = @tabs.delete_at(@active_tab_index)
        @tabs.insert(target_index, tab)
        @active_tab_index = target_index
        activate_tab(@active_tab_index)
      end

      def rename_active_tab(value)
        tab = active_tab
        return unless tab

        name = value.to_s.strip
        return runtime_output("Usage: /tab name <label>") if name.empty?

        tab.label = name
        update_prompt_tabs
        persist_tabs
      end

      def active_tab_number
        @active_tab_index.to_i + 1
      end

      def update_prompt_tabs
        return unless @prompt.respond_to?(:update_tabs)

        @prompt.update_tabs(labels: tab_labels, active_index: @active_tab_index)
      end

      def stop_tabs
        stop_tab_live_view
        Array(@tabs).each do |tab|
          next unless tab&.running?

          tab.cancellation&.cancel!
          tab.thread&.raise(Cancellation::CancelledError, "cancelled") if tab.thread&.alive?
          tab.thread&.join(0.2)
        rescue StandardError
          nil
        end
      end

      def persist_tabs
        return unless @tab_store

        @tab_store.save(
          tabs: @tabs.map { |tab| tab.driver.descriptor.merge("label" => tab.label.to_s) },
          active_index: @active_tab_index
        )
      end

    end
  end
end
