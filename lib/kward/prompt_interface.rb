require "base64"
require "find"
require "io/console"
require "pathname"
require "rbconfig"
require "thread"
require "tty-cursor"
require "tty-reader"
require "tty-screen"
require_relative "ansi"
require_relative "editor_mode"
require_relative "prompt_interface/banner"
require_relative "prompt_interface/composer_state"
require_relative "prompt_interface/editor/state"
require_relative "prompt_interface/transcript_buffer"
require_relative "prompt_interface/transcript_renderer"
require_relative "prompt_interface/prompt_renderer"
require_relative "prompt_interface/stream_state"
require_relative "prompt_interface/slash_overlay"
require_relative "prompt_interface/file_overlay"
require_relative "prompt_interface/selection_prompt"
require_relative "prompt_interface/question_prompt"
require_relative "prompt_interface/git_prompt"
require_relative "prompt_interface/overlay_renderer"
require_relative "prompt_interface/editor/renderer"
require_relative "prompt_interface/editor/syntax_highlighter"
require_relative "prompt_interface/editor/auto_close_pairs"
require_relative "prompt_interface/editor/auto_indent"
require_relative "prompt_interface/composer_renderer"
require_relative "prompt_interface/composer_controller"
require_relative "prompt_interface/editor/modes/modern"
require_relative "prompt_interface/editor/modes/emacs"
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
    include SelectionPrompt
    include QuestionPrompt
    include GitPrompt
    include OverlayRenderer
    include EditorRenderer
    include EditorSyntaxHighlighter
    include EditorAutoClosePairs
    include EditorAutoIndent
    include ComposerRenderer
    include ComposerController
    include ModernEditorMode
    include EmacsEditorMode
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
    KEYBOARD_PROTOCOL_ENABLE = "\e[>25u".freeze
    KEYBOARD_PROTOCOL_RESTORE = "\e[<u".freeze
    BRACKETED_PASTE_ENABLE = "\e[?2004h".freeze
    BRACKETED_PASTE_RESTORE = "\e[?2004l".freeze
    BRACKETED_PASTE_START = "\e[200~".freeze
    BRACKETED_PASTE_END = "\e[201~".freeze
    SYNCHRONIZED_OUTPUT_ENABLE = "\e[?2026h".freeze
    SYNCHRONIZED_OUTPUT_DISABLE = "\e[?2026l".freeze
    CURSOR_SHOW = "\e[?25h".freeze
    CURSOR_HIDE = "\e[?25l".freeze
    CURSOR_SHAPE_DEFAULT = "\e[0 q".freeze
    CURSOR_SHAPE_BAR = "\e[6 q".freeze
    SHIFT_ENTER_SEQUENCES = ["\e[13;2u", "\e[13;2~", "\e[27;2;13~", "\e\r", "\e\n"].freeze
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

    def initialize(input: $stdin, output: $stdout, slash_commands: [], overlay_settings: nil, footer: nil, composer_status: nil, busy_help: true, attachment_badges: nil, attachment_parser: nil, banner_message: nil, tab_keybindings: nil, editor_mode: nil, editor_mode_source: nil, editor_auto_indent: true, editor_auto_indent_source: nil, editor_auto_close_pairs: true, editor_auto_close_pairs_source: nil, editor_soft_wrap: true, editor_soft_wrap_source: nil, editor_bar_cursor: true, editor_bar_cursor_source: nil)
      @input_io = input
      @output_io = output
      @reader = TTY::Reader.new(input: input, output: output, interrupt: :error)
      @mutex = Mutex.new
      @composer = ComposerState.new
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
      @last_footer_refresh = monotonic_now
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
      @original_console_mode = nil
      @raw_mode_active = false
      @slash_commands = normalize_slash_commands(slash_commands)
      @slash_selection_index = 0
      @slash_overlay_dismissed_input = nil
      @file_selection_index = 0
      @file_overlay_dismissed_token = nil
      @file_open_dismissed_token = nil
      @file_editor_open_status = nil
      @file_mention_paths = nil
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
    end

    def start(render: true)
      @mutex.synchronize do
        return if @started

        enter_raw_mode_locked
        @started = true
        @asking = true
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
            render_prompt_locked unless result.is_a?(String) || result == EXIT_INPUT
          end
        end
        return result if result.is_a?(String) || tab_action_result?(result)
        return nil if result == EXIT_INPUT

        sleep 0.02 if key.nil?
      end
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
        @tabs = Array(labels).map { |label| normalize_tab_label(label) }
        @active_tab_index = active_index.to_i
        render_prompt_locked if @started && @asking
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

    def tab_view_snapshot
      @mutex.synchronize do
        {
          composer: @composer.dup,
          prompt_label: @prompt_label.dup,
          editor_state: @editor_state&.dup,
          transcript_buffer: @transcript_buffer.dup,
          transcript_viewport_rows: @transcript_viewport_rows,
          stream_state: @stream_state.dup
        }
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
      @composer = snapshot[:composer] || ComposerState.new
      @prompt_label = snapshot[:prompt_label].to_s.empty? ? "You>" : snapshot[:prompt_label].to_s
      self.composer_input = @composer.input
      self.composer_cursor = @composer.cursor
      @last_composer_rows = []
    end

    def restore_editor_snapshot_locked(snapshot)
      @editor_state = snapshot[:editor_state]&.dup
    end

    def update_overlay_settings(settings)
      @mutex.synchronize do
        @overlay_settings = normalize_overlay_settings(settings)
        render_prompt_locked if @started && @asking
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
        render_prompt_locked unless [EXIT_INPUT, CANCEL_INPUT].include?(result) || tab_action_result?(result)
        [EXIT_INPUT, CANCEL_INPUT].include?(result) ? result : result
      end
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

    def modal_active_locked?
      @question_prompt_active || !@question_state.nil? || !@select_state.nil? || !@git_state.nil?
    end












































































































































































































  end
end
