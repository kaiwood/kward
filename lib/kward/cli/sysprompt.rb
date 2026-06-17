# Namespace for the Kward CLI agent runtime.
module Kward
  # Command-line frontend that coordinates terminal interaction, sessions, tools, and model turns.
  class CLI
    # System prompt inspection command helpers.
    module Sysprompt
      private

      def print_sysprompt(arguments)
        raw = parse_sysprompt_arguments(arguments)
        conversation = new_conversation
        content = conversation.system_message.fetch(:content)
        if raw
          @prompt.say(content)
        else
          @prompt.say(render_sysprompt_sections(conversation))
        end
      end

      def parse_sysprompt_arguments(arguments)
        raw = false
        arguments.each do |argument|
          case argument
          when "--raw"
            raw = true
          else
            raise ArgumentError, command_usage("sysprompt")
          end
        end
        raw
      end

      def render_sysprompt_sections(conversation)
        sections = Prompts.prompt_sections(
          workspace_root: conversation.workspace_root,
          model: conversation.model,
          reasoning_effort: conversation.reasoning_effort,
          memory_context: conversation.memory_context,
          plugin_context: conversation.last_plugin_prompt_context
        )
        lines = ["Kward System Prompt", "", "Workspace: #{conversation.workspace_root}"]
        lines << "Model: #{[conversation.provider, conversation.model].compact.join(" / ")}" unless conversation.model.to_s.empty?
        lines << "Reasoning effort: #{conversation.reasoning_effort}" unless conversation.reasoning_effort.to_s.empty?
        lines << "Memory: not included; memory context is retrieved per user turn."
        sections.each do |section|
          lines << ""
          lines << "## #{section.fetch(:label)}"
          source = section[:source]
          lines << "Source: #{source}" unless source.to_s.empty?
          lines << ""
          lines << section.fetch(:content)
        end
        lines.join("\n")
      end
    end
  end
end
