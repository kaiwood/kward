# Namespace for the Kward CLI agent runtime.
module Kward
  # Command-line frontend that coordinates terminal interaction, sessions, tools, and model turns.
  class CLI
    # Shared runtime construction helpers for CLI conversations, workspaces, plugins, and sessions.
    module RuntimeHelpers
      private

      def new_conversation(workspace_root: current_workspace_root)
        Conversation.new(workspace_root: workspace_root, model: current_model_id, reasoning_effort: current_reasoning_effort, plugin_registry: plugin_registry)
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

      def build_interactive_agent(conversation)
        conversation.plugin_registry ||= plugin_registry if conversation.respond_to?(:plugin_registry)
        workspace = configured_workspace(root: conversation.workspace_root)
        tool_registry = ToolRegistry.new(workspace: workspace, prompt: @prompt)
        @footer_conversation = conversation
        @footer_tool_registry = tool_registry
        Agent.new(
          client: @client,
          tool_registry: tool_registry,
          conversation: conversation
        )
      end

      def handle_interactive_shell_command(input, agent)
        command = input.to_s.sub(/\A!\s*/, "")
        if command.strip.empty?
          @prompt.say("\nShell command is required after !\n")
          return true
        end

        run_busy_local_command_and_requeue(activity: "running") do
          result = configured_workspace(root: interactive_workspace_root(agent)).run_shell_command(command)
          @prompt.say("\n#{colored("Shell>", :green, :bold)} #{command}\n#{result}\n")
        end
        true
      end

      def shell_command_input?(input)
        input.to_s.start_with?("!")
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

      def refresh_conversation_runtime(conversation)
        return unless conversation&.respond_to?(:update_runtime_context!)

        conversation.update_runtime_context!(model: current_model_id, reasoning_effort: current_reasoning_effort)
        @active_session.update_runtime(model: conversation.model, reasoning_effort: conversation.reasoning_effort) if @active_session&.respond_to?(:update_runtime)
        update_assistant_prompt(conversation)
      end

      def auto_name_active_session(input)
        return unless @active_session
        return unless @active_session.name.to_s.strip.empty?

        name = default_session_name(input)
        @active_session.rename(name) unless name.empty?
      end

      def default_session_name(input)
        input.to_s.gsub(/\s+/, " ").strip.slice(0, 120).to_s
      end

    end
  end
end
