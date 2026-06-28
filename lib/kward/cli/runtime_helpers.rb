# Namespace for the Kward CLI agent runtime.
module Kward
  # Command-line frontend that coordinates terminal interaction, sessions, tools, and model turns.
  class CLI
    # Shared runtime construction helpers for CLI conversations, workspaces, plugins, and sessions.
    module RuntimeHelpers
      private

      def new_conversation(workspace_root: current_workspace_root)
        Conversation.new(workspace_root: workspace_root, provider: current_model_provider, model: current_model_id, reasoning_effort: current_reasoning_effort, plugin_registry: plugin_registry)
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
        @active_worker_role = "implementation"
        set_visible_worker("implementation", status: "active")
        build_worker_agent(conversation, role: "implementation")
      end

      def build_worker_agent(conversation, role: "implementation")
        conversation.plugin_registry ||= plugin_registry if conversation.respond_to?(:plugin_registry)
        workspace = configured_workspace(root: conversation.workspace_root)
        writer_id = worker_writer_id(role)
        tool_registry = ToolRegistry.new(
          workspace: workspace,
          prompt: @prompt,
          allowed_tool_names: Workers::ToolPolicy.allowed_tool_names(role),
          write_lock: @worker_write_lock,
          writer_id: writer_id
        )
        @footer_conversation = conversation
        @footer_tool_registry = tool_registry
        Agent.new(
          client: @client,
          tool_registry: tool_registry,
          conversation: conversation
        )
      end

      def set_visible_worker(id, status: nil, worker: nil)
        @visible_worker_id = id.to_s
        @visible_worker_status = status
        @visible_worker = worker
      end

      def worker_writer_id(role)
        return nil unless Workers::ToolPolicy.write_capable?(role)

        @worker_write_lock ||= Workers::WriteLock.new
        owner_id = role.to_s.empty? ? "implementation" : role.to_s
        return owner_id if @worker_write_lock.acquire(owner_id)

        nil
      end

      def refresh_implementation_writer(agent)
        return agent unless @active_worker_role == "implementation"
        return agent unless agent&.respond_to?(:tool_registry)
        return agent if agent.tool_registry.writer_id && @worker_write_lock&.owned_by?(agent.tool_registry.writer_id)

        build_interactive_agent(agent.conversation)
      end

      def release_implementation_writer
        @worker_write_lock&.release("implementation")
      end

      def handle_interactive_shell_command(input, agent)
        command = input.to_s.sub(/\A!\s*/, "")
        if command.strip.empty?
          runtime_output("Shell command is required after !")
          return true
        end

        run_busy_local_command_and_requeue(activity: "running") do
          result = configured_workspace(root: interactive_workspace_root(agent)).run_shell_command(command)
          @prompt.say("\n#{colored("Shell>", :cyan, :bold)} #{command}\n#{result}\n")
        end
        true
      end

      def shell_command_input?(input)
        input.to_s.start_with?("!")
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
        env = interactive_pty_environment(config[:env])
        cwd = interactive_workspace_root(agent)
        @prompt.say("$ #{command}\n[interactive PTY session started]\n") if @prompt.respond_to?(:say)
        result = run_interactive_pty_with_terminal_handoff(config[:shell], command, env: env, cwd: cwd)
        @prompt.say("[interactive PTY session exited with status #{result.exit_status}]\n") if @prompt.respond_to?(:say)
      rescue Errno::ENOENT => e
        runtime_output("Error: #{e.message}")
      end

      def run_interactive_pty_with_terminal_handoff(shell, command, env:, cwd:)
        runner = InteractivePtyRunner.new
        if @prompt.respond_to?(:with_terminal_handoff)
          @prompt.with_terminal_handoff do |input, output|
            runner.run(shell, "-c", command, env: env, cwd: cwd, input: input, output: output)
          end
        else
          runner.run(shell, "-c", command, env: env, cwd: cwd)
        end
      end

      def interactive_pty_environment(configured_env)
        ENV.to_h.merge(configured_env.to_h.transform_keys(&:to_s).transform_values(&:to_s)).tap do |env|
          env.delete("GIT_PAGER") if env["GIT_PAGER"] == "cat"
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
          @prompt.clear_transcript if result.clear && @prompt.respond_to?(:clear_transcript)
          @prompt.say(result.output) unless result.streamed || result.interactive_command || result.output.to_s.empty?
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
          @prompt.with_completion_provider(provider) { @prompt.ask(shell.prompt_label) }
        else
          @prompt.ask(shell.prompt_label)
        end
      end

      def run_ekwsh_interactive_pty_command(shell, result)
        @prompt.say(result.output) unless result.output.to_s.empty?
        pty_result = run_interactive_pty_with_terminal_handoff(
          shell.command_shell,
          result.interactive_command,
          env: shell.child_env(interactive: true),
          cwd: shell.cwd
        )
        @prompt.say("[interactive PTY session exited with status #{pty_result.exit_status}]\n") if @prompt.respond_to?(:say)
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

      def configured_workspace(root: current_workspace_root)
        Workspace.new(root: root, guardrails: workspace_guardrails_enabled?)
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
        @prompt.begin_busy_input("You>", activity: activity) if @prompt.respond_to?(:begin_busy_input)

        worker = Thread.new do
          result = yield
        rescue StandardError => e
          error = e
        end

        while worker.alive?
          collect_queued_input(queued_inputs)
          sleep 0.02
        end
        worker.join
        drain_queued_input(queued_inputs)
        raise error if error

        [result, queued_inputs]
      ensure
        @prompt.finish_busy_input if prompt_interface? && @prompt.respond_to?(:finish_busy_input)
      end

      def run_busy_local_command_and_requeue(activity: "loading")
        return yield unless prompt_interface?

        result, queued_inputs = run_busy_local_command(activity: activity) { yield }
        queued_inputs.reverse_each { |pending_input| @pending_inputs.unshift(pending_input) }
        result
      end

      def current_workspace_root
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
