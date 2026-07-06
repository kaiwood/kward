# Namespace for the Kward CLI agent runtime.
module Kward
  # Command-line frontend that coordinates terminal interaction, sessions, tools, and model turns.
  class CLI
    # Plugin command loading and execution helpers mixed into the CLI frontend.
    module Plugins
      private

      def prompt_templates
        @prompt_templates ||= ConfigFiles.prompt_templates(reserved_commands: builtin_slash_command_names)
      end

      def plugin_registry
        @plugin_registry ||= PluginRegistry.load(reserved_commands: reserved_slash_command_names)
      end

      def plugin_commands
        plugin_registry.commands
      end

      def plugin_command_for(command)
        plugin_registry.command_for(command)
      end

      def interactive_commands
        plugin_registry.interactive_commands
      end

      def interactive_command_for(command)
        plugin_registry.interactive_command_for(command)
      end

      def reload_plugins(conversation)
        @plugin_registry = PluginRegistry.load(reserved_commands: reserved_slash_command_names)
        conversation.plugin_registry = @plugin_registry if conversation.respond_to?(:plugin_registry=)
        conversation.refresh_system_message! if conversation.respond_to?(:refresh_system_message!)
        runtime_output("Plugins reloaded.")
      end

      def lifecycle_hook_manager(conversation)
        manager = Hooks::ConfigLoader.new(ConfigFiles.read_config).manager
        plugin_registry.hook_handlers.each do |hook|
          manager.register(hook.event, id: hook.id, source: hook.path, order: hook.order, match: hook.match, failure_policy: hook.failure_policy) do |event, context|
            hook.handler.call(event, context)
          end
        end
        manager
      end

      def lifecycle_hook_context(conversation)
        plugin_context(conversation, "")
      end

      def run_lifecycle_hook(name, conversation:, payload: {}, session: @active_session)
        lifecycle_hook_manager(conversation).run(Hooks::Event.new(
          name: name,
          session: session_payload(session),
          workspace: { root: conversation.respond_to?(:workspace_root) ? conversation.workspace_root : current_workspace_root },
          payload: payload
        ), context: lifecycle_hook_context(conversation))
      end

      def session_payload(session)
        return {} unless session

        {
          id: session.respond_to?(:id) ? session.id : nil,
          name: session.respond_to?(:name) ? session.name : nil,
          path: session.respond_to?(:path) ? session.path : nil
        }.compact
      end

      def reserved_slash_command_names
        builtin_slash_command_names + prompt_templates.map(&:command)
      end

      def run_interactive_command(name, argument, agent)
        command = interactive_command_for(name)
        return [false, nil] unless command
        return [false, nil] unless prompt_interface? && @prompt.respond_to?(:start_interactive)

        context = plugin_context(agent.conversation, argument)
        controller = @prompt.start_interactive(title: "/#{name}", rows: command.rows, fps: command.fps)
        command.handler.call(controller, context)
        run_interactive_loop
        [true, nil]
      rescue StandardError => e
        @prompt.finish_interactive if @prompt.respond_to?(:finish_interactive)
        runtime_output("Interactive command /#{name} error: #{e.message}")
        [true, nil]
      end

      def run_interactive_loop
        loop do
          result = @prompt.poll_input
          if result == :interactive_exited || @prompt.interactive_exited?
            @prompt.finish_interactive
            break
          end
          sleep 0.01
        end
      end

      def slash_command_entries
        prompt_entries = prompt_templates.map do |template|
          {
            name: template.command,
            description: template.description,
            argument_hint: template.argument_hint
          }
        end
        skill_entries = ConfigFiles.skills.map do |skill|
          {
            name: "skill:#{skill.name}",
            description: skill.description,
            argument_hint: ""
          }
        end
        plugin_entries = plugin_commands.map(&:entry)
        interactive_entries = interactive_commands.map(&:entry)
        builtin_slash_commands + prompt_entries + skill_entries + plugin_entries + interactive_entries
      end

      def prompt_template_for(command)
        prompt_templates.find { |template| template.command == command }
      end

      def builtin_slash_commands
        return BUILTIN_SLASH_COMMANDS if experimental_workers_enabled?

        BUILTIN_SLASH_COMMANDS.reject { |command| %w[workers queue].include?(command[:name]) }
      end

      def builtin_slash_command_names
        builtin_slash_commands.map { |command| command[:name] }
      end

      def experimental_workers_enabled?
        @experimental_workers == true
      end

      def expand_prompt_template(input)
        PromptCommands.expand(input, templates: prompt_templates, reserved_commands: builtin_slash_command_names)
      end

      def run_plugin_command(name, argument, agent)
        command = plugin_command_for(name)
        return [false, nil] unless command

        agent.conversation.plugin_registry ||= plugin_registry if agent.conversation.respond_to?(:plugin_registry)
        context = plugin_context(agent.conversation, argument)
        command.handler.call(argument, context)
        [true, nil]
      rescue StandardError => e
        runtime_output("Plugin command /#{name} error: #{e.message}")
        [true, nil]
      end

      def plugin_context(conversation, args)
        PluginRegistry::Context.new(
          conversation: conversation,
          args: args,
          session: @active_session,
          workspace_root: conversation.workspace_root,
          say_callback: lambda { |message| runtime_output(message) }
        )
      end

      def selected_slash_command_input(input)
        return nil if prompt_interface?
        return nil unless @prompt.respond_to?(:select)
        return nil unless input.match?(%r{\A/[^\s/]*\z})
        return nil if prompt_template_for(input.delete_prefix("/"))

        prefix = input.delete_prefix("/").downcase
        return nil if slash_command_entries.any? { |entry| entry[:name].downcase == prefix }

        matches = slash_command_entries.select { |entry| entry[:name].downcase.start_with?(prefix) }
        return nil if matches.empty?

        labels = matches.map { |entry| slash_command_label(entry) }
        choice = @prompt.select("Slash command>", labels)
        entry = matches[labels.index(choice)]
        entry ? "/#{entry[:name]}" : nil
      end

      def slash_command_label(entry)
        hint = entry[:argument_hint].to_s.empty? ? "" : " #{entry[:argument_hint]}"
        description = entry[:description].to_s.empty? ? "" : " - #{entry[:description]}"
        "/#{entry[:name]}#{hint}#{description}"
      end

      def notify_plugin_transcript_event(event, conversation)
        return unless conversation
        return if plugin_registry.transcript_event_handlers.empty?

        plugin_registry.notify_transcript_event(event, plugin_context(conversation, ""))
      end

    end
  end
end
