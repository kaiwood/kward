require "find"
require "io/console"
require "pathname"
require "rbconfig"
require "thread"
require_relative "project_files"
require_relative "prompt_history"
require "tty-cursor"
require "tty-reader"
require "tty-screen"
require_relative "ansi"
require_relative "terminal_sequences"
require_relative "terminal_keys"
require_relative "editor_mode"
require_relative "diff_view_mode"
require_relative "prompt_interface/banner"
require_relative "prompt_interface/composer_state"
require_relative "prompt_interface/editor/state"
require_relative "prompt_interface/transcript_buffer"
require_relative "prompt_interface/transcript_renderer"
require_relative "prompt_interface/prompt_renderer"
require_relative "prompt_interface/stream_state"
require_relative "prompt_interface/slash_overlay"
require_relative "prompt_interface/file_overlay"
require_relative "prompt_interface/project_browser"
require_relative "prompt_interface/selection_prompt"
require_relative "prompt_interface/question_prompt"
require_relative "prompt_interface/approval_prompt"
require_relative "prompt_interface/git_prompt"
require_relative "prompt_interface/overlay_renderer"
require_relative "prompt_interface/editor/renderer"
require_relative "prompt_interface/editor/syntax_highlighter"
require_relative "prompt_interface/editor/auto_close_pairs"
require_relative "prompt_interface/editor/endwise"
require_relative "prompt_interface/editor/auto_indent"
require_relative "prompt_interface/composer_renderer"
require_relative "prompt_interface/composer_controller"
require_relative "prompt_interface/editor/modes/modern"
require_relative "prompt_interface/editor/modes/emacs"
require_relative "prompt_interface/editor/modes/vibe_insert_readline"
require_relative "prompt_interface/editor/modes/vibe"
require_relative "prompt_interface/editor/controller"
require_relative "prompt_interface/interactive/controller"
require_relative "prompt_interface/interactive/renderer"
require_relative "prompt_interface/interactive/state"
require_relative "prompt_interface/layout"
require_relative "prompt_interface/screen"
require_relative "prompt_interface/key_handler"
require_relative "prompt_interface/runtime_state"

# Namespace for the Kward CLI agent runtime.
module Kward
  # Interactive terminal UI used by the CLI frontend.
  #
  # `PromptInterface` owns terminal mechanics: keyboard input, composer state,
  # transcript rendering, overlays, footer updates, and terminal escape sequence
  # setup/restore. It should not own agent turns, sessions, model calls, or tool
  # policy; `CLI` coordinates those and calls this object for display/input.
  #
  # The implementation is split into small mixin modules under
  # `prompt_interface/` to keep rendering, layout, keyboard handling, and runtime
  # state readable while sharing one terminal state object.
  class PromptInterface
    HELP_TEXT = "Enter sends • Shift+Enter inserts newline • ↑/↓ history • Ctrl+D exits empty prompt".freeze
    BUSY_HELP_TEXT = "Ctrl+C cancels".freeze
    SPINNER_FRAMES = %w[⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏].freeze
    SPINNER_INTERVAL = 0.1
    FOOTER_REFRESH_INTERVAL = 1.0
    COMPOSER_STATUS_REFRESH_INTERVAL = 1.0
    COMPOSER_MAX_INPUT_ROWS = 6
    TRANSCRIPT_BUFFER_LIMIT = 200_000
    BANNER_MESSAGE = Banner::MESSAGE

    include SlashOverlay
    include FileOverlay
    include ProjectBrowser
    include SelectionPrompt
    include QuestionPrompt
    include ApprovalPrompt
    include GitPrompt
    include OverlayRenderer
    include EditorRenderer
    include EditorSyntaxHighlighter
    include EditorAutoClosePairs
    include EditorEndwise
    include EditorAutoIndent
    include ComposerRenderer
    include ComposerController
    include ModernEditorMode
    include EmacsEditorMode
    include VibeInsertReadline
    include VibeEditorMode
    include EditorController
    include InteractiveRenderer
    include InteractiveState
    include Layout
    include Screen
    include KeyHandler
    include RuntimeState
    include TranscriptRenderer
    include PromptRenderer
    KEYBOARD_PROTOCOL_ENABLE = TerminalSequences::KEYBOARD_PROTOCOL_ENABLE
    KEYBOARD_PROTOCOL_RESTORE = TerminalSequences::KEYBOARD_PROTOCOL_RESTORE
    BRACKETED_PASTE_ENABLE = TerminalSequences::BRACKETED_PASTE_ENABLE
    BRACKETED_PASTE_RESTORE = TerminalSequences::BRACKETED_PASTE_RESTORE
    BRACKETED_PASTE_START = TerminalSequences::BRACKETED_PASTE_START
    BRACKETED_PASTE_END = TerminalSequences::BRACKETED_PASTE_END
    SYNCHRONIZED_OUTPUT_ENABLE = TerminalSequences::SYNCHRONIZED_OUTPUT_ENABLE
    SYNCHRONIZED_OUTPUT_DISABLE = TerminalSequences::SYNCHRONIZED_OUTPUT_DISABLE
    CURSOR_SHOW = TerminalSequences::CURSOR_SHOW
    CURSOR_HIDE = TerminalSequences::CURSOR_HIDE
    CURSOR_SHAPE_DEFAULT = TerminalSequences::CURSOR_SHAPE_DEFAULT
    CURSOR_SHAPE_BAR = TerminalSequences::CURSOR_SHAPE_BAR
    SHIFT_ENTER_SEQUENCES = TerminalKeys::SHIFT_ENTER
    EXIT_INPUT = :exit_input
    CANCEL_INPUT = :cancel_input
    SELECT_CANCEL = :select_cancel
    SELECT_CONTINUE = :select_continue
    SELECT_ACTION_MINIMUM_BUSY_SECONDS = 1.0

    # Submitted input string carrying optional display text for transcripts.
    class SubmittedInput < String
      attr_reader :display_input

      def initialize(value, display_input: nil)
        super(value.to_s)
        @display_input = display_input
      end
    end

    def initialize(input: $stdin, output: $stdout, slash_commands: [], overlay_settings: nil, project_browser_icon_theme: "off", footer: nil, composer_status: nil, busy_help: true, attachment_badges: nil, attachment_parser: nil, banner_message: nil, tab_keybindings: nil, prompt_history: nil, workspace_root: Dir.pwd, editor_mode: nil, editor_mode_source: nil, editor_auto_indent: true, editor_auto_indent_source: nil, editor_auto_close_pairs: true, editor_auto_close_pairs_source: nil, editor_soft_wrap: true, editor_soft_wrap_source: nil, editor_bar_cursor: true, editor_bar_cursor_source: nil, editor_line_numbers: "absolute", editor_line_numbers_source: nil, diff_view: "auto", diff_view_source: nil, redraw_handler: nil)
      @input_io = input
      @output_io = output
      @reader = TTY::Reader.new(input: input, output: output, interrupt: :error)
      @mutex = Mutex.new
      @prompt_history = prompt_history
      @workspace_root = File.expand_path(workspace_root.to_s.empty? ? Dir.pwd : workspace_root)
      @composer = ComposerState.new
      load_history(@prompt_history.values) if @prompt_history
      self.composer_input = @composer.input
      self.composer_cursor = @composer.cursor
      @started = false
      @asking = false
      @busy = false
      @busy_activity = "streaming"
      @queued_count = 0
      @steered_count = 0
      @spinner_frame_index = 0
      @last_spinner_tick = monotonic_now
      @last_footer_refresh = nil
      @cached_footer_text = nil
      @last_composer_status_refresh = 0.0
      @cached_composer_status_text = nil
      @prompt_label = "You>"
      @assistant_label = "Assistant"
      @stream_state = StreamState.new
      @rendered_rows = 0
      @last_composer_rows = []
      @cursor_rendered_row = 0
      @transcript_buffer = TranscriptBuffer.new(limit: TRANSCRIPT_BUFFER_LIMIT)
      @transcript_viewport_rows = 0
      @restoring_transcript = false
      @pending_keys = []
      @completion_provider = nil
      @completion_cycle = nil
      @redraw_handler = redraw_handler
      @transcript_redraw_requested = false
      @original_console_mode = nil
      @raw_mode_active = false
      @slash_commands = normalize_slash_commands(slash_commands)
      @slash_selection_index = 0
      @slash_overlay_dismissed_input = nil
      @slash_overlay_disabled = false
      @file_selection_index = 0
      @file_overlay_dismissed_token = nil
      @file_open_dismissed_token = nil
      @file_editor_open_status = nil
      @file_mention_paths = nil
      @project_browser_state = nil
      @project_browser_restore_after_editor = false
      @editor_state = nil
      @interactive_state = nil
      @last_interactive_tick = monotonic_now
      @select_state = nil
      @question_state = nil
      @question_prompt_active = false
      @git_state = nil
      @last_width = screen_width
      @last_height = screen_height
      @reserved_rows = 0
      @color_enabled = ANSI.enabled?(output)
      @cursor_visible = true
      @editor_bar_cursor_active = false
      @synchronized_output_depth = 0
      @overlay_settings = normalize_overlay_settings(overlay_settings)
      @project_browser_icon_theme = normalize_project_browser_icon_theme(project_browser_icon_theme)
      @footer = footer
      @composer_status = composer_status
      @busy_help = busy_help
      @attachment_badges = attachment_badges
      @attachment_parser = attachment_parser
      @banner = Banner.new(message: banner_message, screen_height: method(:screen_height))
      @tabs = []
      @active_tab_index = 0
      @tab_keybindings = normalize_tab_keybindings(tab_keybindings)
      @editor_mode = normalize_editor_mode(editor_mode)
      @editor_mode_source = editor_mode_source
      @editor_auto_indent = editor_auto_indent != false
      @editor_auto_indent_source = editor_auto_indent_source
      @editor_auto_close_pairs = editor_auto_close_pairs != false
      @editor_auto_close_pairs_source = editor_auto_close_pairs_source
      @editor_soft_wrap = editor_soft_wrap != false
      @editor_soft_wrap_source = editor_soft_wrap_source
      @editor_bar_cursor = editor_bar_cursor != false
      @editor_bar_cursor_source = editor_bar_cursor_source
      @editor_line_numbers = normalize_editor_line_numbers(editor_line_numbers)
      @editor_line_numbers_source = editor_line_numbers_source
      @diff_view = DiffViewMode.normalize(diff_view)
      @diff_view_source = diff_view_source
    end

    def update_slash_commands(commands)
      @mutex.synchronize do
        @slash_commands = normalize_slash_commands(commands)
        reset_slash_selection
        @slash_overlay_dismissed_input = nil
        render_prompt_locked if @started
      end
    end

    def start(render: true)
      @mutex.synchronize do
        return if @started

        enter_raw_mode_locked
        @started = true
        @asking = true
        disable_editor_mouse_reporting(force: true) unless editor_active?
        @output_io.print(KEYBOARD_PROTOCOL_ENABLE)
        @output_io.print(BRACKETED_PASTE_ENABLE)
        render_prompt_locked if render
      end
    end

    def close
      @mutex.synchronize do
        return unless @started

        clear_prompt_for_output_locked
        restore_scroll_region_locked
        disable_editor_mouse_reporting(force: true)
        @output_io.print(BRACKETED_PASTE_RESTORE)
        @output_io.print(KEYBOARD_PROTOCOL_RESTORE)
        restore_editor_cursor_shape_locked
        set_cursor_visible_locked(true, force: true)
        @output_io.puts
        @output_io.flush
        @started = false
        restore_console_mode_locked
      end
    end

    def say(message)
      @mutex.synchronize do
        text = message.to_s
        if @restoring_transcript
          write_transcript_text_locked(text)
          write_transcript_text_locked("\n") unless text.end_with?("\n")
          @stream_state.finish_block
          next
        end

        with_synchronized_output_locked do
          clear_prompt_for_output_locked
          write_transcript_text_locked(text)
          write_transcript_text_locked("\n") unless text.end_with?("\n")
          @stream_state.finish_block
          render_prompt_after_output_locked
        end
        @output_io.flush
      end
    end

    def say_visual(message)
      @mutex.synchronize do
        return if @restoring_transcript

        with_synchronized_output_locked do
          clear_prompt_for_output_locked
          text = message.to_s
          write_visual_transcript_text_locked(text)
          write_visual_transcript_text_locked("\n") unless text.end_with?("\n")
          @stream_state.finish_block
          render_prompt_after_output_locked
        end
        @output_io.flush
      end
    end

    def restore_transcript
      start(render: false) unless @started
      @mutex.synchronize do
        @output_io.print(SYNCHRONIZED_OUTPUT_ENABLE)
        clear_prompt_for_output_locked unless @rendered_rows.zero? && @last_composer_rows.empty?
        @transcript_buffer.clear
        @transcript_viewport_rows = 0
        @stream_state.finish_block
        @stream_state.reset
        @restoring_transcript = true
      end

      yield
    ensure
      @mutex.synchronize do
        @restoring_transcript = false
        width, height = screen_size
        redraw_screen_locked(width: width, height: height)
        @output_io.print(SYNCHRONIZED_OUTPUT_DISABLE)
        @output_io.flush
      end
    end

    def with_completion_provider(provider, slash_overlay: true)
      previous_provider = @completion_provider
      previous_slash_overlay_disabled = @slash_overlay_disabled
      @completion_provider = provider
      @slash_overlay_disabled = !slash_overlay
      yield
    ensure
      @completion_provider = previous_provider
      @slash_overlay_disabled = previous_slash_overlay_disabled
    end

    def update_completion_provider(provider, slash_overlay: true)
      @mutex.synchronize do
        @completion_provider = provider
        @completion_cycle = nil
        @slash_overlay_disabled = !slash_overlay
        render_prompt_locked if @started
      end
    end

    def with_prompt_history(history)
      previous_history = @prompt_history
      @prompt_history = history
      load_history(@prompt_history.values) if @prompt_history
      yield
    ensure
      @prompt_history = previous_history
      load_history(@prompt_history.values) if @prompt_history
    end

    def editing_file?
      @mutex.synchronize { editor_active? }
    end

    def update_workspace_root(root, prompt_history: nil)
      @mutex.synchronize do
        expanded_root = File.expand_path(root.to_s.empty? ? Dir.pwd : root)
        return false if expanded_root == @workspace_root

        @workspace_root = expanded_root
        @prompt_history = prompt_history if prompt_history
        load_history(@prompt_history.values) if @prompt_history
        reset_workspace_file_state_locked
        true
      end
    end

    def edit_file(path, base_dir: nil, allow_new: true)
      start(render: false)
      opened = @mutex.synchronize do
        open_editor(path, allow_new: allow_new, base_dir: base_dir || prompt_workspace_root, restrict_to_workspace: false).tap do
          render_prompt_locked
        end
      end
      return false unless opened

      run_editor
    end

    def scratchpad(language = :text)
      start(render: false)
      opened = @mutex.synchronize do
        open_scratchpad(language).tap do
          render_prompt_locked
        end
      end
      return false unless opened

      run_editor
    end

    # Opens an in-memory document editor. The callback receives edited content
    # when the user saves; return an error message to keep the editor open.
    def review_document(title:, content:, &on_save)
      raise ArgumentError, "review_document requires a save callback" unless on_save

      start(render: false)
      opened = @mutex.synchronize do
        @editor_save_callback = on_save
        open_scratchpad(:markdown, content: content).tap do
          @editor_state.status = "#{title} · Ctrl+S save · Ctrl+Q cancel"
          render_prompt_locked
        end
      end
      return false unless opened

      run_editor
    end

    def run_editor
      loop do
        key = read_key(nonblock: true)
        action = nil
        editor_open = @mutex.synchronize do
          if key.nil?
            resized = handle_resize_locked
            footer_refreshed = tick_footer_locked
            render_prompt_locked if resized || footer_refreshed
          else
            result = handle_key(key)
            action = result if prompt_action_result?(result)
            render_prompt_locked unless result.is_a?(String) || result == EXIT_INPUT || prompt_action_result?(result)
          end
          editor_active?
        end
        return action if action
        break unless editor_open

        sleep 0.02 if key.nil?
      end
      true
    end

    def ask(message = "You>")
      was_composing = @started && @asking
      start
      @mutex.synchronize do
        preserve_input = was_composing && !@busy && !composer_input.empty?
        @prompt_label = message.to_s
        unless preserve_input
          self.composer_input = @composer.prefill_input.to_s
          @composer.prefill_input = nil
          self.composer_cursor = composer_input.length
          @composer.clear_attachments
          reset_history_navigation
        end
        @pending_keys.clear
        @asking = true
        @busy = false
        @queued_count = 0
        render_prompt_locked
      end

      loop do
        key = read_key(nonblock: true)
        result = nil
        @mutex.synchronize do
          if key.nil?
            resized = handle_resize_locked
            footer_refreshed = tick_footer_locked
            render_prompt_locked if resized || footer_refreshed
          else
            result = handle_key(key)
            render_prompt_locked unless result.is_a?(String) || result == EXIT_INPUT || prompt_action_result?(result)
          end
        end
        return result if result.is_a?(String) || prompt_action_result?(result)
        return nil if result == EXIT_INPUT

        sleep 0.02 if key.nil?
      end
    ensure
      perform_pending_transcript_redraw
    end

    def yes?(message, default: false)
      answer = ask("#{message} #{default ? "[Y/n]" : "[y/N]"}")
      return default if answer.nil?

      answer = answer.strip.downcase
      return default if answer.empty?

      answer.start_with?("y")
    end

    def picker_choice_width
      [overlay_card_width(screen_width) - 6, 1].max
    end

    def select(message, choices, title: "Sessions", custom: false, initial_index: 0, action_keys: {}, action_handlers: {})
      return nil if choices.empty? && !custom

      start
      @mutex.synchronize do
        prepare_modal_input_locked(message, clear_attachments: true)
        choice_labels = choices.map(&:to_s)
        selection_index = choice_labels.empty? ? 0 : [[initial_index.to_i, 0].max, choice_labels.length - 1].min
        @select_state = { choices: choice_labels, selection_index: selection_index, title: title.to_s, custom: custom, action_keys: normalized_select_action_keys(action_keys), search_active: false }
        render_prompt_locked
      end

      loop do
        key = read_key(nonblock: true)
        result = nil
        @mutex.synchronize do
          if key.nil?
            resized = handle_resize_locked
            footer_refreshed = tick_footer_locked
            render_prompt_locked if resized || footer_refreshed
          else
            result = handle_select_key(key)
            result = drain_pending_select_keys_locked(result)
            render_prompt_locked unless result.is_a?(String) || select_action_result?(result) || result == SELECT_CANCEL
          end
        end

        if select_action_result?(result) && select_action_handler(result, action_handlers)
          action_result = run_select_action(result, select_action_handler(result, action_handlers))
          next if action_result == SELECT_CONTINUE

          return action_result
        end

        if result.is_a?(String) || select_action_result?(result) || result == SELECT_CANCEL
          finish_select_prompt(render: !select_deferred_finish_render?(result))
          return result == SELECT_CANCEL ? nil : result
        end

        sleep 0.02 if key.nil?
      end
    end

    def ask_user_question(questions)
      return [] if questions.empty?

      start
      saved_state = nil
      answers = []
      @mutex.synchronize do
        @question_prompt_active = true
        saved_state = begin_question_prompt_state
      end

      questions.each_with_index do |question, index|
        answer = ask_single_user_question(question, index + 1, questions.length)
        if answer == SELECT_CANCEL
          finish_question_prompt(saved_state)
          return nil
        end
        answers << answer
      end

      finish_question_prompt(saved_state)
      answers
    rescue StandardError
      finish_question_prompt(saved_state) if saved_state
      raise
    end

    def modal_active?
      @mutex.synchronize { modal_active_locked? }
    end

    def interactive_active?
      @mutex.synchronize { interactive_active_locked? }
    end

    def interactive_exited?
      @mutex.synchronize do
        return false unless @interactive_state

        @interactive_state[:controller].exited?
      end
    end

    def finish_interactive
      @mutex.synchronize do
        return unless @interactive_state

        snapshot = @interactive_state[:snapshot]
        @interactive_state = nil
        restore_composer_snapshot_locked(snapshot)
        redraw_screen_locked if @started
        @output_io.flush
      end
    end

    def with_terminal_handoff
      start
      input = nil
      output = nil
      @mutex.synchronize do
        clear_prompt_for_output_locked
        restore_scroll_region_locked
        disable_editor_mouse_reporting(force: true)
        @output_io.print(BRACKETED_PASTE_RESTORE)
        @output_io.print(KEYBOARD_PROTOCOL_RESTORE)
        restore_editor_cursor_shape_locked
        set_cursor_visible_locked(true, force: true)
        @output_io.flush
        restore_console_mode_locked
        input = @input_io
        output = @output_io
      end

      yield(input, output)
    ensure
      @mutex.synchronize do
        enter_raw_mode_locked
        @output_io.print(KEYBOARD_PROTOCOL_ENABLE)
        @output_io.print(BRACKETED_PASTE_ENABLE)
        @last_composer_rows = []
        render_prompt_locked if @started && @asking
        @output_io.flush
      end
    end

    def start_interactive(title:, rows:, fps:)
      snapshot = composer_snapshot
      controller = InteractiveController.new(width: interactive_canvas_width, height: rows, fps: fps)
      start
      @mutex.synchronize do
        @interactive_state = {
          title: title.to_s,
          rows: rows,
          controller: controller,
          snapshot: snapshot
        }
        @last_interactive_tick = monotonic_now
        @asking = true
        @busy = false
        @last_composer_rows = []
        render_prompt_locked
      end
      controller
    end

    def update_tabs(labels:, active_index: 0)
      @mutex.synchronize do
        normalized_labels = Array(labels).map { |label| normalize_tab_label(label) }
        normalized_index = active_index.to_i
        return false if @tabs == normalized_labels && @active_tab_index == normalized_index

        @tabs = normalized_labels
        @active_tab_index = normalized_index
        render_prompt_locked if @started && @asking
        true
      end
    end

    def composer_snapshot
      @mutex.synchronize do
        {
          composer: @composer,
          prompt_label: @prompt_label
        }
      end
    end

    def tab_view_snapshot(include_transcript: true)
      @mutex.synchronize do
        snapshot = {
          composer: @composer.dup,
          prompt_label: @prompt_label.dup,
          editor_state: @editor_state&.dup
        }
        if include_transcript
          snapshot[:transcript_buffer] = @transcript_buffer.dup
          snapshot[:transcript_viewport_rows] = @transcript_viewport_rows
          snapshot[:stream_state] = @stream_state.dup
        end
        snapshot
      end
    end

    def restore_composer_snapshot(snapshot)
      @mutex.synchronize do
        restore_composer_snapshot_locked(snapshot)
        restore_editor_snapshot_locked(snapshot)
        redraw_screen_locked if @started
      end
    end

    def restore_tab_view_snapshot(snapshot)
      @mutex.synchronize do
        restore_composer_snapshot_locked(snapshot)
        restore_editor_snapshot_locked(snapshot)
        @transcript_buffer = snapshot[:transcript_buffer] || TranscriptBuffer.new(limit: TRANSCRIPT_BUFFER_LIMIT)
        @transcript_viewport_rows = snapshot[:transcript_viewport_rows].to_i
        @stream_state = snapshot[:stream_state] || StreamState.new
        @last_composer_rows = []
        redraw_screen_locked if @started
      end
    end

    def restore_composer_snapshot_locked(snapshot)
      @composer = snapshot[:composer] || new_composer_state_with_history
      @prompt_label = snapshot[:prompt_label].to_s.empty? ? "You>" : snapshot[:prompt_label].to_s
      self.composer_input = @composer.input
      self.composer_cursor = @composer.cursor
      @last_composer_rows = []
    end

    def new_composer_state_with_history
      composer = ComposerState.new
      composer.load_history(@prompt_history.values) if @prompt_history
      composer
    end

    def restore_editor_snapshot_locked(snapshot)
      editor_was_active = editor_active?
      @editor_state = snapshot[:editor_state]&.dup
      editor_is_active = editor_active?

      if editor_is_active
        enable_editor_mouse_reporting unless editor_was_active
      else
        disable_editor_mouse_reporting(force: true)
      end
    end

    def update_overlay_settings(settings)
      @mutex.synchronize do
        @overlay_settings = normalize_overlay_settings(settings)
        render_prompt_locked if @started && @asking
      end
    end

    def update_project_browser_icon_theme(theme)
      @mutex.synchronize do
        @project_browser_icon_theme = normalize_project_browser_icon_theme(theme)
        render_prompt_locked if @started && @asking && project_browser_visible?
      end
    end

    def begin_busy_input(message = "You>", activity: "streaming")
      start
      @mutex.synchronize do
        @prompt_label = message.to_s
        @busy_activity = normalize_busy_activity(activity)
        self.composer_input = ""
        self.composer_cursor = 0
        @composer.clear_attachments
                  @pending_keys.clear
        @asking = true
        @busy = true
        @queued_count = 0
        @steered_count = 0
        reset_spinner_locked
        reset_history_navigation
        render_prompt_locked
      end
    end

    def set_queued_count(count)
      @mutex.synchronize do
        @queued_count = count.to_i
        @steered_count = 0 if @queued_count.positive?
        render_prompt_locked if @asking
      end
    end

    def set_steered_count(count)
      @mutex.synchronize do
        @steered_count = count.to_i
        @queued_count = 0 if @steered_count.positive?
        render_prompt_locked if @asking
      end
    end

    def clear_steered_count
      @mutex.synchronize do
        @steered_count = 0
        @busy_activity = "streaming"
        render_prompt_locked if @asking
      end
    end

    def finish_busy_input
      @mutex.synchronize do
        @busy = false
        @busy_activity = "streaming"
        @queued_count = 0
        @steered_count = 0
        @asking = true
        render_prompt_locked
      end
    end

    def poll_input
      key = read_key(nonblock: true)
      @mutex.synchronize do
        if interactive_active_locked?
          if key.nil?
            resized = handle_resize_locked
            ticked = tick_interactive_locked
            render_prompt_locked if resized || ticked
            return :interactive_exited if @interactive_state[:controller].exited?
            return nil
          end

          route_interactive_key(key)
          ticked = tick_interactive_locked
          render_prompt_locked if ticked
          return :interactive_exited if @interactive_state[:controller].exited?
          return nil
        end

        if key.nil?
          resized = handle_resize_locked
          spun = tick_spinner_locked
          footer_refreshed = tick_footer_locked
          render_prompt_locked if resized || spun || footer_refreshed
          return nil
        end

        if modal_active_locked?
          queue_pending_keys(key)
          return nil
        end

        result = handle_key(key)
        render_prompt_locked unless [EXIT_INPUT, CANCEL_INPUT].include?(result) || prompt_action_result?(result)
        [EXIT_INPUT, CANCEL_INPUT].include?(result) ? result : result
      end
    ensure
      perform_pending_transcript_redraw
    end

    def update_assistant_label(label)
      @mutex.synchronize do
        @assistant_label = label.to_s.empty? ? "Assistant" : label.to_s
      end
    end

    def print_visual_banner(message = nil)
      @mutex.synchronize do
        width, height = screen_size
        rows = banner_rows(width, message: message)
        return if rows.empty?

        with_synchronized_output_locked do
          prepare_transcript_output_locked
          write_transcript_text_locked(rows.join("\n"))
          write_transcript_text_locked("\n")
          remember_transcript_viewport_locked(height)
          @stream_state.finish_block
          restore_composer_cursor_locked
        end
        @output_io.flush
      end
    end

    def start_stream_block(label)
      @mutex.synchronize do
        write_stream_block_locked(label, "", finish: false)
      end
    end

    def write_delta(delta)
      @mutex.synchronize do
        write_stream_block_locked(nil, delta.to_s, finish: false)
      end
    end

    def finish_stream_block
      @mutex.synchronize do
        write_stream_block_locked(nil, "", finish: true)
      end
    end

    def write_transcript_delta(delta)
      @mutex.synchronize do
        with_synchronized_output_locked do
          prepare_transcript_output_locked unless @restoring_transcript
          write_transcript_text_locked(delta.to_s)
          restore_composer_cursor_locked unless @restoring_transcript
        end
        @output_io.flush unless @restoring_transcript
      end
    end

    def write_stream_block(label, delta, finish: false)
      @mutex.synchronize do
        write_stream_block_locked(label, delta.to_s, finish: finish)
      end
    end

    def redraw
      @mutex.synchronize do
        width, height = screen_size
        with_synchronized_output_locked { redraw_screen_locked(width: width, height: height) }
        @output_io.flush
      end
    end

    def refresh_composer_status
      @mutex.synchronize do
        @cached_footer_text = nil
        @last_footer_refresh = nil
        @cached_composer_status_text = nil
        @last_composer_status_refresh = 0.0
        render_prompt_locked if @started && @asking
      end
    end

    def clear_transcript
      @mutex.synchronize do
        @transcript_buffer.clear
        @transcript_viewport_rows = 0
        @stream_state.finish_block
        @stream_state.reset
        width, height = screen_size
        with_synchronized_output_locked { redraw_screen_locked(width: width, height: height) }
        @output_io.flush
      end
    end

    private

    def request_transcript_redraw
      redraw_screen_locked
      @transcript_redraw_requested = true
    end

    def perform_pending_transcript_redraw
      requested = @mutex.synchronize do
        pending = @transcript_redraw_requested
        @transcript_redraw_requested = false
        pending
      end
      @redraw_handler&.call if requested
    end

    def prompt_workspace_root
      @workspace_root
    end

    def reset_workspace_file_state_locked
      @file_mention_paths = nil
      @file_mention_path_entries_paths = nil
      @file_mention_path_entries = nil
      @project_browser_state = nil
      @project_browser_tree_paths = nil
      @project_browser_tree = nil
      @file_overlay_dismissed_token = nil
      @file_open_dismissed_token = nil
      @file_editor_open_status = nil
    end

    def modal_active_locked?
      @question_prompt_active || !@question_state.nil? || !@select_state.nil? || !@git_state.nil?
    end
  end
end
