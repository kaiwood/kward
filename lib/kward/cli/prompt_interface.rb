require "open3"

# Namespace for the Kward CLI agent runtime.
module Kward
  # Command-line frontend that coordinates terminal interaction, sessions, tools, and model turns.
  class CLI
    # Adapter methods that connect the CLI coordinator to the terminal prompt interface.
    module PromptInterfaceSupport
      private

      def setup_interactive_prompt(defer_warnings: false)
        return unless @stdin.tty?
        return unless @prompt.is_a?(TTY::Prompt)

        prompt_interface = load_prompt_interface
        return unless prompt_interface

        @interactive_warning_sink_active = true
        @interactive_warning_output_ready = !defer_warnings
        ConfigFiles.warning_sink = interactive_warning_sink
        @prompt = prompt_interface.new(
          slash_commands: slash_command_entries,
          overlay_settings: ConfigFiles.overlay_settings,
          project_browser_icon_theme: ConfigFiles.project_browser_icon_theme,
          footer: prompt_footer_renderer,
          composer_status: method(:composer_status_text),
          busy_help: ConfigFiles.composer_busy_help?,
          attachment_badges: method(:composer_attachment_badges),
          attachment_parser: method(:composer_attachment_parser),
          banner_message: Kward::PromptInterface::BANNER_MESSAGE,
          tab_keybindings: ConfigFiles.composer_tab_keybindings,
          prompt_history: PromptHistory.new(cwd: current_workspace_root),
          workspace_root: current_workspace_root,
          editor_mode: ConfigFiles.editor_mode,
          editor_mode_source: -> { ConfigFiles.editor_mode },
          editor_auto_indent: ConfigFiles.editor_auto_indent?,
          editor_auto_indent_source: -> { ConfigFiles.editor_auto_indent? },
          editor_auto_close_pairs: ConfigFiles.editor_auto_close_pairs?,
          editor_auto_close_pairs_source: -> { ConfigFiles.editor_auto_close_pairs? },
          editor_soft_wrap: ConfigFiles.editor_soft_wrap?,
          editor_soft_wrap_source: -> { ConfigFiles.editor_soft_wrap? },
          editor_bar_cursor: ConfigFiles.editor_bar_cursor?,
          editor_bar_cursor_source: -> { ConfigFiles.editor_bar_cursor? },
          editor_line_numbers: ConfigFiles.editor_line_numbers,
          editor_line_numbers_source: -> { ConfigFiles.editor_line_numbers },
          diff_view: ConfigFiles.diff_view,
          diff_view_source: -> { ConfigFiles.diff_view },
          editor_runners_source: -> { ConfigFiles.editor_runners },
          redraw_handler: method(:redraw_interactive_prompt)
        )
        if @prompt.method(:start).parameters.any? { |kind, name| [:key, :keyreq].include?(kind) && name == :render }
          @prompt.start(render: false)
        else
          @prompt.start
        end
        flush_interactive_warnings if @interactive_warning_output_ready
      end

      def enable_interactive_warnings
        @interactive_warning_output_ready = true
        flush_interactive_warnings
      end

      def interactive_warning_sink
        @interactive_warning_sink ||= lambda do |message|
          unless @interactive_warning_sink_active
            warn message
            next
          end

          if @interactive_warning_output_ready && prompt_interface?
            runtime_output(message)
          else
            (@pending_interactive_warnings ||= []) << message
          end
        end
      end

      def flush_interactive_warnings
        warnings = @pending_interactive_warnings
        @pending_interactive_warnings = []
        Array(warnings).each { |message| runtime_output(message) }
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

      def open_editor_for_agent(path, base_dir:, allow_new:)
        return false unless prompt_interface?
        return false unless @prompt.respond_to?(:edit_file)

        @prompt.edit_file(path, base_dir: base_dir, allow_new: allow_new)
      end

      def emit_warning(message)
        sink = ConfigFiles.warning_sink
        sink ? sink.call(message) : warn(message)
      end

      def clear_interactive_warning_sink
        ConfigFiles.warning_sink = nil
        @interactive_warning_sink_active = false
        @interactive_warning_output_ready = false
        @pending_interactive_warnings = nil
        @interactive_warning_sink = nil
      end

      def update_prompt_workspace_root(root)
        return unless @prompt.respond_to?(:update_workspace_root)

        @prompt.update_workspace_root(root, prompt_history: PromptHistory.new(cwd: root))
      end

      # Writes the startup info screen output for the terminal CLI flow.
      def print_visual_banner
        return unless @prompt.respond_to?(:print_visual_banner)

        @prompt.print_visual_banner(startup_info_screen(refresh_update_check: prompt_interface?))
      end

      def startup_info_screen(refresh_update_check: false)
        [
          startup_status_line(refresh_update_check: refresh_update_check),
          *startup_update_notice_lines,
          *startup_authentication_notice_lines,
          "",
          startup_info_line("Workspace", startup_workspace_label),
          startup_info_line("Branch", startup_branch_value),
          startup_info_line("Plugins", startup_plugins_value),
          "",
          startup_brand_line
        ].join("\n")
      end

      def startup_workspace_label
        root = File.expand_path(current_workspace_root)
        home = begin
          Dir.home
        rescue StandardError
          nil
        end
        if home && (root == home || root.start_with?("#{home}/"))
          relative = root.delete_prefix(home).sub(%r{\A/}, "")
          return "~" if relative.empty?
          return "~/#{relative}" unless relative.include?("/")
        end

        parent = File.basename(File.dirname(root))
        name = File.basename(root)
        parent.empty? || parent == "." ? name : "#{parent}/#{name}"
      end

      def startup_branch_value
        git_root = startup_git_root(current_workspace_root)
        return "not a repository" if git_root.to_s.empty?

        branch = startup_git_output(%w[git branch --show-current], root: git_root)
        branch = startup_git_output(%w[git rev-parse --short HEAD], root: git_root) if branch.empty?
        branch.empty? ? "unknown" : branch
      end

      def startup_plugins_value
        filenames = plugin_registry.paths.map { |path| startup_plugin_name(path) }
        filenames.empty? ? "none" : filenames.join(", ")
      end

      def startup_plugin_name(path)
        plugin_root = ConfigFiles.plugin_dir
        prefix = "#{plugin_root}#{File::SEPARATOR}"
        path.start_with?(prefix) ? path.delete_prefix(prefix) : File.basename(path)
      end

      def startup_status_line(refresh_update_check: false)
        color = startup_update_notice(refresh: refresh_update_check) ? :yellow : :green
        "#{ANSI.colorize("●", color, enabled: @color_enabled)} Kward v#{Kward::VERSION} is online."
      end

      def startup_update_notice_lines
        notice = startup_update_notice
        return [] unless notice

        [
          "  New version available: #{notice.latest_version}",
          "  Run: gem update kward"
        ]
      end

      def startup_update_notice(refresh: false)
        return @startup_update_notice if defined?(@startup_update_notice) && !refresh

        @startup_update_check ||= UpdateCheck.new(current_version: Kward::VERSION)
        @startup_update_notice = @startup_update_check.notice(refresh: refresh)
      end

      def startup_authentication_notice_lines
        return [] unless startup_authentication_required?

        [
          ANSI.colorize("  No model provider is connected.", :yellow, enabled: @color_enabled),
          "  Run /login to sign in, or /model to configure a local server."
        ]
      end

      def startup_authentication_required?
        return false unless @client.is_a?(Client)
        return false if @client.current_provider == "Local"

        auth_credentials.none? { |credential| credential.fetch(:configured) }
      rescue StandardError
        false
      end

      def startup_info_line(label, value)
        "#{ANSI.colorize(label.ljust(12), :gray, enabled: @color_enabled)}#{ANSI.colorize(value, :cyan, enabled: @color_enabled)}"
      end

      def startup_brand_line
        ANSI.colorize(Kward::PromptInterface::BANNER_MESSAGE, :bold, enabled: @color_enabled)
      end

      def startup_git_root(root)
        startup_git_output(%w[git rev-parse --show-toplevel], root: root)
      end

      def startup_git_output(command, root:)
        output, status = Open3.capture2e(*command, chdir: root.to_s)
        return "" unless status.success?

        output.lines.first.to_s.strip
      rescue StandardError
        ""
      end

      def prompt_footer_renderer
        return nil unless plugin_registry.footer_renderer

        lambda do
          renderer = plugin_registry.footer_renderer
          next "" unless renderer

          context = plugin_context(current_footer_conversation, "")
          renderer.call(context).to_s
        rescue StandardError => e
          emit_warning "Warning: Kward plugin footer error: #{e.message}"
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
        git = composer_git_branch_text
        parts << git if git
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

      def composer_git_branch_text
        git_root = startup_git_root(current_workspace_root)
        return nil if git_root.to_s.empty?

        branch = startup_git_output(%w[git branch --show-current], root: git_root)
        branch = startup_git_output(%w[git rev-parse --short HEAD], root: git_root) if branch.empty?
        branch = "unknown" if branch.empty?
        color = composer_git_dirty?(git_root) ? :yellow : nil
        ANSI.colorize(branch, color, enabled: @color_enabled)
      end

      def composer_git_dirty?(git_root)
        !startup_git_output(%w[git status --porcelain --untracked-files=normal], root: git_root).empty?
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
        provider = ModelInfo.provider_label(provider)
        return @client.context_window(provider, model) if @client.respond_to?(:context_window) && @client.method(:context_window).arity != 0

        ModelInfo.context_window(provider, model)
      end

      def composer_context_usage(provider, model)
        context_window = composer_context_window(provider, model)
        context_parts = if @client.respond_to?(:current_context_parts)
                          @client.current_context_parts(current_footer_conversation.context_messages, footer_tool_schemas, provider: provider, model: model)
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
