# Namespace for the Kward CLI agent runtime.
module Kward
  # Command-line frontend that coordinates terminal interaction, sessions, tools, and model turns.
  class CLI
    # Shared runtime construction helpers for CLI conversations, workspaces, plugins, and sessions.
    module RuntimeHelpers
      MAX_TRANSIENT_TERMINAL_OUTPUT_BYTES = 1_048_576
      UNSAFE_TRANSCRIPT_CONTROL_PATTERN = /[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/.freeze

      private

      def new_conversation(workspace_root: current_workspace_root)
        Conversation.new(
          workspace_root: workspace_root,
          provider: current_model_provider,
          model: current_model_id,
          reasoning_effort: current_reasoning_effort,
          plugin_registry: plugin_registry,
          project_skill_paths: project_skill_paths_for(workspace_root)
        )
      end

      def update_assistant_prompt(conversation)
        @assistant_prompt = assistant_prompt_label(conversation)
        @prompt.update_assistant_label(assistant_prompt_name) if @prompt.respond_to?(:update_assistant_label)
        @assistant_prompt
      end

      def assistant_prompt_label(conversation)
        label = ConfigFiles.active_persona_label(workspace_root: conversation.workspace_root, model: conversation.model)
        "#{label || "Assistant"}>"
      rescue StandardError
        "Assistant>"
      end

      def assistant_prompt_name
        assistant_output_prompt.delete_suffix(">")
      end

      def assistant_output_prompt
        @assistant_prompt || "Assistant>"
      end

      def runtime_output_prompt
        "Runtime>"
      end

      def runtime_output(text)
        content = text.to_s.chomp
        label = colored(runtime_output_prompt, :gray, :bold)
        separator = content.include?("\n") ? "\n" : " "
        @prompt.say("\n#{label}#{separator}#{content}\n")
      end

      def build_interactive_agent(conversation)
        conversation.plugin_registry ||= plugin_registry if conversation.respond_to?(:plugin_registry)
        workspace = configured_workspace(root: conversation.workspace_root)
        hook_manager = lifecycle_hook_manager(conversation)
        hook_context = lifecycle_hook_context(conversation)
        tool_registry = ToolRegistry.new(
          workspace: workspace,
          prompt: @prompt,
          skills: ConfigFiles.skills(workspace_root: conversation.workspace_root, project_skill_paths: project_skill_paths_for(conversation.workspace_root)),
          tool_approval: interactive_tool_approval_callback,
          hook_manager: hook_manager,
          hook_context: hook_context
        )
        @footer_conversation = conversation
        @footer_tool_registry = tool_registry
        Agent.new(
          client: @client,
          tool_registry: tool_registry,
          conversation: conversation,
          warning_sink: ConfigFiles.warning_sink,
          hook_manager: hook_manager,
          hook_context: hook_context
        )
      end

      def interactive_tool_approval_callback
        return nil unless @prompt.respond_to?(:ask_tool_approval)
        return nil unless ConfigFiles.permission_policy(safely_read_config.to_h).enabled?

        lambda do |tool_call:, name:, args:, cancellation:|
          @prompt.ask_tool_approval(
            tool_name: name,
            args: args,
            reason: args["hook_message"] || args[:hook_message]
          )
        end
      end

      def handle_interactive_shell_command(input, agent)
        command = input.to_s.sub(/\A!\s*/, "")
        if command.strip.empty?
          runtime_output("Shell command is required after !")
          return true
        end

        shell = bang_shell(agent)
        editor_result = shell.editor_command_result(command)
        if editor_result
          record_tab_transient_shell_output(editor_result.output, render: false)
          @prompt.say(editor_result.output) unless editor_result.output.to_s.empty?
          open_ekwsh_editor(editor_result.open_editor_path, shell) if editor_result.open_editor_path
          return true
        end

        expanded_command = shell.expand_alias(command, interactive: true)
        run_user_interactive_pty_command(
          expanded_command,
          shell: Ekwsh::DEFAULT_SHELL,
          env: interactive_pty_environment({}, preserve_git_pager: true),
          cwd: interactive_workspace_root(agent),
          intro: "$ #{command}\n"
        )
        true
      end

      def run_captured_shell_command(command, agent)
        command = command.to_s.strip
        if command.empty?
          runtime_output("Usage: /capture <command>")
          return
        end

        run_busy_local_command_and_requeue(activity: "running") do
          result = Workspace.new(root: interactive_workspace_root(agent)).run_shell_command(command)
          @prompt.say("\n#{colored("Shell>", :cyan, :bold)} #{command}\n#{result}\n")
        end
      end

      def shell_command_input?(input)
        input.to_s.start_with?("!")
      end

      def complete_bang_command(input, cursor, agent)
        value = input.to_s
        return false unless value.start_with?("!")
        return nil if cursor.to_i <= 1

        completion = bang_shell(agent).complete(value[1..], cursor.to_i - 1)
        return nil unless completion

        Ekwsh::Completion.new(
          range: (completion.range.begin + 1)...(completion.range.end + 1),
          replacement: completion.replacement,
          candidates: completion.candidates
        )
      end

      def bang_shell(agent)
        root = File.expand_path(interactive_workspace_root(agent).to_s)
        aliases = ConfigFiles.read_ekwsh_config[:aliases]
        cache_key = [root, ENV.fetch("PATH", ""), aliases.sort]
        return @bang_shell if @bang_shell_key == cache_key

        @bang_shell_key = cache_key
        @bang_shell = Ekwsh.new(cwd: root, env: ENV.to_h, aliases: aliases)
      end

      def install_bang_completion_provider(agent)
        return unless @prompt.respond_to?(:update_completion_provider)

        @bang_completion_provider_installed = true
        provider = lambda do |input, cursor|
          current_agent = if respond_to?(:active_tab, true) && active_tab&.agent
            active_tab.agent
          else
            agent
          end
          complete_bang_command(input, cursor, current_agent)
        end
        @prompt.update_completion_provider(provider)
      end

      def clear_bang_completion_provider
        return unless @bang_completion_provider_installed
        return unless @prompt.respond_to?(:update_completion_provider)

        @prompt.update_completion_provider(nil)
        @bang_completion_provider_installed = false
      end

      def run_ekwsh(agent)
        unless @prompt.respond_to?(:ask)
          runtime_output("The embedded shell is only available in interactive mode.")
          return
        end

        tab = active_tab if respond_to?(:active_tab, true)
        entering = tab.nil? || tab.shell.nil?
        shell = tab&.shell || build_ekwsh(agent)
        tab.shell = shell if tab
        runtime_output("Entering ekwsh. Type exit or press Ctrl+D on an empty prompt to return.") if entering
        run_ekwsh_loop(shell, tab: tab, history: build_ekwsh_history(agent))
      end

      def build_ekwsh(agent)
        config = ConfigFiles.read_ekwsh_config
        Ekwsh.new(
          cwd: interactive_workspace_root(agent),
          configured_env: config[:env],
          aliases: config[:aliases],
          shell: config[:shell],
          timeout_seconds: config[:timeout_seconds],
          max_output_bytes: config[:max_output_bytes]
        )
      end

      def build_ekwsh_history(agent)
        config = ConfigFiles.read_ekwsh_config
        PromptHistory.new(
          cwd: interactive_workspace_root(agent),
          limit: config[:history_limit],
          kind: "shell"
        )
      end

      def run_interactive_pty_command(command, agent)
        command = command.to_s.strip
        if command.empty?
          runtime_output("Usage: /pty <command>")
          return
        end

        config = ConfigFiles.read_ekwsh_config
        run_user_interactive_pty_command(
          command,
          shell: config[:shell],
          env: interactive_pty_environment(config[:env]),
          cwd: interactive_workspace_root(agent)
        )
      end

      def run_user_interactive_pty_command(command, shell:, env:, cwd:, intro: nil)
        intro_message = intro || "$ #{command}\n"
        record_tab_transient_shell_output(intro_message, render: false)
        if @prompt.respond_to?(:write_transcript)
          @prompt.write_transcript(intro_message)
        elsif @prompt.respond_to?(:say)
          @prompt.say(intro_message)
        end
        result = run_interactive_pty_with_terminal_handoff(shell, command, env: env, cwd: cwd) do |sink, completed_result|
          record_completed_pty_output(sink, completed_result)
        end
        refresh_composer_status
        result
      rescue Errno::ENOENT => e
        runtime_output("Error: #{e.message}")
        nil
      end

      def run_interactive_pty_with_terminal_handoff(shell, command, env:, cwd:, &on_complete)
        runner = InteractivePtyRunner.new
        run_with_sink = lambda do |input, sink|
          result = runner.run(shell, "-c", command, env: env, cwd: cwd, input: input, sink: sink)
          on_complete.call(sink, result) if on_complete
          result
        end

        if @prompt.respond_to?(:with_inline_terminal_handoff)
          @prompt.with_inline_terminal_handoff do |input, output, transition|
            sink = AdaptivePtyOutputSink.new(
              output: output,
              on_exclusive: transition,
              max_capture_bytes: MAX_TRANSIENT_TERMINAL_OUTPUT_BYTES
            )
            run_with_sink.call(input, sink)
          end
        elsif @prompt.respond_to?(:with_terminal_handoff)
          @prompt.with_terminal_handoff do |input, output|
            sink = PassthroughPtyOutputSink.new(
              output: output,
              max_capture_bytes: MAX_TRANSIENT_TERMINAL_OUTPUT_BYTES
            )
            run_with_sink.call(input, sink)
          end
        else
          sink = PassthroughPtyOutputSink.new(
            output: $stdout,
            max_capture_bytes: MAX_TRANSIENT_TERMINAL_OUTPUT_BYTES
          )
          run_with_sink.call($stdin, sink)
        end
      end

      def record_completed_pty_output(sink, result)
        classified_output = sink.respond_to?(:transcript_safe?)
        return if classified_output && !sink.transcript_safe?

        output = sink&.captured_output || +"".b
        allow_input = classified_output &&
          sink.respond_to?(:pre_input_capture_only?) &&
          sink.pre_input_capture_only?
        transcript_output = terminal_transcript_output(
          output,
          result,
          truncated: sink&.truncated? || false,
          allow_input: allow_input,
          normalize_line_controls: classified_output
        )
        return unless transcript_output

        record_tab_transient_shell_output(transcript_output, render: false)
        if @prompt.respond_to?(:record_transient_terminal_output)
          @prompt.record_transient_terminal_output(transcript_output, render: false)
        end
      end

      def terminal_transcript_output(
        output,
        result,
        truncated:,
        allow_input: false,
        normalize_line_controls: false
      )
        return if truncated || (result.input_forwarded && !allow_input)

        text = ANSI.normalize_transcript_encoding(output).gsub("\r\n", "\n")
        return if text.empty?

        if normalize_line_controls
          sanitized = PtyTranscriptNormalizer.normalize(text)
        else
          return if text.include?("\r")

          sanitized = ANSI.sanitize_transcript(text)
          return unless sanitized == text
        end
        return if sanitized.empty?
        return if ANSI.strip_control_sequences(sanitized).match?(UNSAFE_TRANSCRIPT_CONTROL_PATTERN)

        sanitized
      end

      def interactive_pty_environment(configured_env, preserve_git_pager: false)
        ENV.to_h.merge(configured_env.to_h.transform_keys(&:to_s).transform_values(&:to_s)).tap do |env|
          env.delete("GIT_PAGER") if !preserve_git_pager && env["GIT_PAGER"] == "cat"
          env["TERM"] = "xterm-256color" if env["TERM"].to_s.empty? || env["TERM"] == "dumb"
        end
      end

      def run_ekwsh_loop(shell, tab: nil, history: nil)
        with_ekwsh_history(history) do
          run_ekwsh_loop_with_history(shell, tab: tab)
        end
      end

      def run_ekwsh_loop_with_history(shell, tab: nil)
        loop do
          if @prompt.respond_to?(:editing_file?) && @prompt.editing_file?
            editor_result = @prompt.run_editor
            if editor_result.is_a?(Hash) && editor_result[:tab_action]
              (@pending_inputs ||= []).unshift(editor_result)
              return :tab_action
            end
          end

          input = ask_ekwsh(shell)
          if input.is_a?(Hash) && input[:tab_action]
            (@pending_inputs ||= []).unshift(input)
            return :tab_action
          end
          break if input.nil?

          result = run_ekwsh_command(shell, input)
          if result.clear
            clear_active_tab_transient_shell_output
            @prompt.clear_transcript if @prompt.respond_to?(:clear_transcript)
          else
            record_tab_transient_shell_output(result.output, render: false) unless result.interactive_command
            @prompt.say(result.output) unless result.streamed || result.interactive_command || result.output.to_s.empty?
          end
          return :tab_action if pending_tab_action?

          if result.open_editor_path
            editor_result = open_ekwsh_editor(result.open_editor_path, shell)
            return :tab_action if editor_result == :tab_action

            next
          end
          if result.interactive_command
            run_ekwsh_interactive_pty_command(shell, result)
            next
          end
          if result.exit_shell
            tab.shell = nil if tab
            runtime_output("Shell exited.")
            return :exited
          end
        end
        tab.shell = nil if tab
        runtime_output("Shell exited.")
        :exited
      end

      def with_ekwsh_history(history)
        if history && @prompt.respond_to?(:with_prompt_history)
          @prompt.with_prompt_history(history) { yield }
        else
          yield
        end
      end

      def open_ekwsh_editor(path, shell)
        unless @prompt.respond_to?(:edit_file)
          runtime_output("Integrated editor is unavailable in this prompt.")
          return false
        end

        result = @prompt.edit_file(path, base_dir: shell.cwd, allow_new: true)
        if result.is_a?(Hash) && result[:tab_action]
          (@pending_inputs ||= []).unshift(result)
          return :tab_action
        end

        result
      end

      def ask_ekwsh(shell)
        provider = ->(input, cursor) { shell.complete(input, cursor) }
        if @prompt.respond_to?(:with_completion_provider)
          @prompt.with_completion_provider(provider, slash_overlay: false) { @prompt.ask(shell.prompt_label) }
        else
          @prompt.ask(shell.prompt_label)
        end
      end

      def run_ekwsh_interactive_pty_command(shell, result)
        run_user_interactive_pty_command(
          result.interactive_command,
          shell: shell.command_shell,
          env: shell.child_env(interactive: true),
          cwd: shell.cwd,
          intro: result.output
        )
      end

      def run_ekwsh_command(shell, input)
        if @prompt.respond_to?(:begin_busy_input)
          @prompt.begin_busy_input(shell.prompt_label, activity: "running")
        end
        if @prompt.respond_to?(:write_transcript_delta) && @prompt.respond_to?(:poll_input)
          run_streaming_ekwsh_command(shell, input)
        elsif @prompt.respond_to?(:write_transcript_delta)
          shell.run(input) { |chunk| @prompt.write_transcript_delta(chunk) }
        else
          shell.run(input)
        end
      ensure
        @prompt.finish_busy_input if @prompt.respond_to?(:finish_busy_input)
      end

      def run_streaming_ekwsh_command(shell, input)
        cancellation = Cancellation.new
        chunks = Queue.new
        queued_inputs = []
        result = nil
        error = nil
        worker = Thread.new do
          result = shell.run(input, cancellation: cancellation) { |chunk| chunks << chunk }
        rescue StandardError => e
          error = e
        end
        worker.report_on_exception = false

        while worker.alive?
          drain_ekwsh_chunks(chunks)
          poll_result = collect_queued_input(queued_inputs)
          if poll_result == PromptInterface::CANCEL_INPUT
            cancellation.cancel!
          elsif poll_result.is_a?(Hash) && poll_result[:tab_action]
            (@pending_inputs ||= []).unshift(poll_result)
            cancellation.cancel!
          end
          sleep 0.01
        end
        worker.join
        drain_ekwsh_chunks(chunks)
        raise error if error

        queued_inputs.reverse_each { |pending_input| (@pending_inputs ||= []).unshift(pending_input) }
        result
      end

      def record_tab_transient_shell_output(text, render: true)
        value = text.to_s
        return if value.empty?

        tab = active_tab if respond_to?(:active_tab, true)
        tab&.append_transient_shell_entry(value)
        if render && @prompt.respond_to?(:record_transient_terminal_output)
          @prompt.record_transient_terminal_output(value)
        end
      end

      def clear_active_tab_transient_shell_output
        clear_active_tab_transient_shell_entries if respond_to?(:clear_active_tab_transient_shell_entries, true)
      end

      def drain_ekwsh_chunks(chunks)
        loop do
          @prompt.write_transcript_delta(chunks.pop(true))
        rescue ThreadError
          break
        end
      end

      def pending_tab_action?
        @pending_inputs&.first.is_a?(Hash) && @pending_inputs.first[:tab_action]
      end

      def configured_workspace(root: current_workspace_root, strict: false)
        WorkspaceFactory.build(root: root, guardrails: workspace_guardrails_enabled?, config: safely_read_config.to_h, strict: strict)
      end

      def workspace_guardrails_enabled?
        ConfigFiles.workspace_guardrails_enabled?(safely_read_config.to_h)
      end

      def interactive_workspace_root(agent)
        conversation = agent.conversation if agent.respond_to?(:conversation)
        return conversation.workspace_root if conversation&.respond_to?(:workspace_root)

        current_workspace_root
      end

      def run_busy_local_command(activity: "loading")
        return yield unless prompt_interface?

        queued_inputs = []
        result = nil
        error = nil
        begin_local_busy_command(activity)

        worker = Thread.new do
          result = yield
        rescue StandardError => e
          error = e
        end

        while worker.alive?
          poll_result = collect_queued_input(queued_inputs)
          handle_busy_local_tab_action(poll_result, activity: activity) if busy_local_tab_action?(poll_result)
          sleep 0.02
        end
        worker.join
        drain_queued_input(queued_inputs)
        raise error if error

        [result, queued_inputs]
      ensure
        finish_local_busy_command(activity)
      end

      def run_busy_local_command_and_requeue(activity: "loading")
        return yield unless prompt_interface?

        result, queued_inputs = run_busy_local_command(activity: activity) { yield }
        queued_inputs.reverse_each { |pending_input| @pending_inputs.unshift(pending_input) }
        result
      end

      def begin_local_busy_command(activity)
        active_tab.local_busy_activity = activity if active_tab
        @prompt.begin_busy_input("You>", activity: activity) if @prompt.respond_to?(:begin_busy_input)
        update_prompt_tabs if respond_to?(:update_prompt_tabs, true)
      end

      def finish_local_busy_command(activity)
        tab = local_busy_tab(activity)
        tab.local_busy_activity = nil if tab
        update_prompt_tabs if respond_to?(:update_prompt_tabs, true)
        @prompt.finish_busy_input if prompt_interface? && @prompt.respond_to?(:finish_busy_input) && (!active_tab || active_tab == tab)
      end

      def local_busy_tab(activity)
        Array(@tabs).find { |tab| tab.local_busy_activity.to_s == activity.to_s }
      end

      def busy_local_tab_action?(poll_result)
        poll_result.is_a?(Hash) && poll_result[:tab_action]
      end

      def handle_busy_local_tab_action(action, activity:)
        return unless respond_to?(:handle_tab_action, true)

        @prompt.finish_busy_input if @prompt.respond_to?(:finish_busy_input)
        handle_tab_action(action, @session_store)
        tab = active_tab
        return unless tab&.local_busy?

        @prompt.begin_busy_input("You>", activity: tab.local_busy_activity) if @prompt.respond_to?(:begin_busy_input)
      end

      def current_workspace_root
        conversation = active_tab&.agent&.conversation if respond_to?(:active_tab, true)
        return conversation.workspace_root if conversation&.respond_to?(:workspace_root)
        return @active_session.cwd.to_s unless @active_session&.cwd.to_s.empty?
        return @working_directory if @working_directory

        Dir.pwd
      end

      def current_model_provider
        @client.respond_to?(:current_provider) ? @client.current_provider : "Codex"
      end

      def current_model_id
        @client.respond_to?(:current_model) ? @client.current_model : ModelInfo::DEFAULT_OPENAI_MODEL
      end

      def current_reasoning_effort
        @client.respond_to?(:current_reasoning_effort) ? @client.current_reasoning_effort : ModelInfo::DEFAULT_REASONING_EFFORT
      end

      def refresh_composer_status
        if @prompt.respond_to?(:refresh_composer_status)
          @prompt.refresh_composer_status
        elsif @prompt.respond_to?(:redraw)
          @prompt.redraw
        end
      end

      def reload_client_config
        @client.reload_config if @client.respond_to?(:reload_config)
      end

      def refresh_conversation_runtime(conversation, reasoning_effort: current_reasoning_effort, refresh_system_message: true)
        return unless conversation&.respond_to?(:update_runtime_context!)

        runtime_changed = [conversation.provider, conversation.model, conversation.reasoning_effort] != [current_model_provider, current_model_id, reasoning_effort]
        conversation.update_runtime_context!(provider: current_model_provider, model: current_model_id, reasoning_effort: reasoning_effort, refresh: refresh_system_message)
        conversation.persist_runtime_context! if runtime_changed && conversation.respond_to?(:persist_runtime_context!)
        update_assistant_prompt(conversation)
      end

      def auto_name_active_session(input)
        return unless @active_session
        return unless @active_session.name.to_s.strip.empty?

        name = default_session_name(input)
        @active_session.rename(name) unless name.empty?
      end

      def default_session_name(input)
        SessionNaming.default_name(input)
      end

    end
  end
end
