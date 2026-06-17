# Namespace for the Kward CLI agent runtime.
module Kward
  # Command-line frontend that coordinates terminal interaction, sessions, tools, and model turns.
  class CLI
    # Adapter methods that connect the CLI coordinator to the terminal prompt interface.
    module PromptInterfaceSupport
      private

      def setup_interactive_prompt
        return unless @stdin.tty?
        return unless @prompt.is_a?(TTY::Prompt)

        prompt_interface = load_prompt_interface
        return unless prompt_interface

        banner_enabled = ConfigFiles.banner_enabled?
        @prompt = prompt_interface.new(
          slash_commands: slash_command_entries,
          overlay_settings: ConfigFiles.overlay_settings,
          footer: prompt_footer_renderer,
          composer_status: method(:composer_status_text),
          busy_help: ConfigFiles.composer_busy_help?,
          attachment_badges: method(:composer_attachment_badges),
          attachment_parser: method(:composer_attachment_parser),
          banner_pixels: banner_enabled ? Kward::PromptInterface::BANNER_LOGO_PIXELS : nil,
          banner_message: banner_enabled ? Kward::PromptInterface::BANNER_MESSAGE : nil
        )
        @prompt.start
      end

      def load_prompt_interface
        require_relative "../prompt_interface"
        PromptInterface
      rescue LoadError => e
        raise unless missing_tty_tui_load_error?(e)

        nil
      end

      def missing_tty_tui_load_error?(error)
        ["tty-cursor", "tty-reader", "tty-screen"].include?(error.path) ||
          error.message.match?(/cannot load such file -- tty-(cursor|reader|screen)/)
      end

      def prompt_interface?
        @prompt.respond_to?(:start_stream_block) && @prompt.respond_to?(:write_delta)
      end

      # Writes the visual banner output for the terminal CLI flow.
      def print_visual_banner
        @prompt.print_visual_banner if @prompt.respond_to?(:print_visual_banner)
      end

      def prompt_footer_renderer
        return nil unless plugin_registry.footer_renderer

        lambda do
          renderer = plugin_registry.footer_renderer
          next "" unless renderer

          context = plugin_context(current_footer_conversation, "")
          renderer.call(context).to_s
        rescue StandardError => e
          warn "Warning: Kward plugin footer error: #{e.message}"
          ""
        end
      end

      def composer_status_text
        conversation = current_footer_conversation
        provider = conversation.provider || (@client.respond_to?(:current_provider) ? @client.current_provider : "Codex")
        model = conversation.model || (@client.respond_to?(:current_model) ? @client.current_model : ModelInfo::DEFAULT_OPENAI_MODEL)
        reasoning = conversation.reasoning_effort || (@client.respond_to?(:current_reasoning_effort) ? @client.current_reasoning_effort : ModelInfo::DEFAULT_REASONING_EFFORT)
        reasoning = "n/a" unless ModelInfo.reasoning_supported?(provider, model) && !reasoning.to_s.empty?
        text = "#{provider} #{model} · #{reasoning}"
        parts = []
        diff = composer_session_diff_text
        parts << diff if diff
        usage = composer_context_usage(provider, model)
        parts << composer_context_percent_text(usage[:percent]) if usage
        parts << text
        parts.join(" · ")
      end

      def composer_session_diff_text
        return nil if @session_diff.nil? || @session_diff.empty?

        additions = ANSI.colorize("+#{@session_diff.additions}", :green, enabled: @color_enabled)
        deletions = ANSI.colorize("-#{@session_diff.deletions}", :red, enabled: @color_enabled)
        "#{additions}|#{deletions}"
      end

      def composer_context_percent_text(percent)
        value = percent.round
        color = if value >= 85
                  :red
                elsif value >= 50
                  :yellow
                end
        ANSI.colorize("#{value}%", color, enabled: @color_enabled)
      end

      def composer_context_window(provider = nil, model = nil)
        provider ||= current_footer_conversation.provider || (@client.respond_to?(:current_provider) ? @client.current_provider : "Codex")
        model ||= current_footer_conversation.model || (@client.respond_to?(:current_model) ? @client.current_model : ModelInfo::DEFAULT_OPENAI_MODEL)
        ModelInfo.context_window(ModelInfo.provider_label(provider), model)
      end

      def composer_context_usage(provider, model)
        context_window = composer_context_window(provider, model)
        context_parts = if @client.respond_to?(:current_context_parts)
                          @client.current_context_parts(current_footer_conversation.context_messages, footer_tool_schemas)
                        else
                          { provider: provider, model: model, messages: current_footer_conversation.context_messages, tools: footer_tool_schemas }
                        end
        @context_usage.call(
          provider: provider,
          model: model,
          context_window: context_window,
          context_parts: context_parts
        )
      end

      def footer_tool_schemas
        @footer_tool_registry&.schemas || []
      end

      def current_footer_conversation
        @footer_conversation || Conversation.new(system_message: nil)
      end

    end
  end
end
