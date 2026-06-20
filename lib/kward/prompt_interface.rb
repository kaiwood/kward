require "io/console"
require "thread"
require "tty-cursor"
require "tty-reader"
require "tty-screen"
require_relative "ansi"
require_relative "prompt_interface/banner"
require_relative "prompt_interface/composer_state"
require_relative "prompt_interface/transcript_buffer"
require_relative "prompt_interface/transcript_renderer"
require_relative "prompt_interface/prompt_renderer"
require_relative "prompt_interface/stream_state"
require_relative "prompt_interface/slash_overlay"
require_relative "prompt_interface/selection_prompt"
require_relative "prompt_interface/question_prompt"
require_relative "prompt_interface/overlay_renderer"
require_relative "prompt_interface/composer_renderer"
require_relative "prompt_interface/composer_controller"
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
    COMPOSER_MAX_INPUT_ROWS = 6
    TRANSCRIPT_BUFFER_LIMIT = 200_000
    BANNER_LOGO_PIXELS = Banner::LOGO_PIXELS
    BANNER_MESSAGE = Banner::MESSAGE

    include SlashOverlay
    include SelectionPrompt
    include QuestionPrompt
    include OverlayRenderer
    include ComposerRenderer
    include ComposerController
    include Layout
    include Screen
    include KeyHandler
    include RuntimeState
    include TranscriptRenderer
    include PromptRenderer
    KEYBOARD_PROTOCOL_ENABLE = "\e[>1u".freeze
    KEYBOARD_PROTOCOL_RESTORE = "\e[<u".freeze
    BRACKETED_PASTE_ENABLE = "\e[?2004h".freeze
    BRACKETED_PASTE_RESTORE = "\e[?2004l".freeze
    BRACKETED_PASTE_START = "\e[200~".freeze
    BRACKETED_PASTE_END = "\e[201~".freeze
    SYNCHRONIZED_OUTPUT_ENABLE = "\e[?2026h".freeze
    SYNCHRONIZED_OUTPUT_DISABLE = "\e[?2026l".freeze
    CURSOR_SHOW = "\e[?25h".freeze
    CURSOR_HIDE = "\e[?25l".freeze
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

    def initialize(input: $stdin, output: $stdout, slash_commands: [], overlay_settings: nil, footer: nil, composer_status: nil, busy_help: true, attachment_badges: nil, attachment_parser: nil, banner_pixels: nil, banner_message: nil)
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
      @prompt_label = "You>"
      @assistant_label = "Assistant"
      @stream_state = StreamState.new
      @rendered_rows = 0
      @last_composer_rows = []
      @cursor_rendered_row = 0
      @transcript_buffer = TranscriptBuffer.new(limit: TRANSCRIPT_BUFFER_LIMIT)
      @visual_banner_count = 0
      @transcript_viewport_rows = 0
      @restoring_transcript = false
      @pending_keys = []
      @original_console_mode = nil
      @raw_mode_active = false
      @slash_commands = normalize_slash_commands(slash_commands)
      @slash_selection_index = 0
      @slash_overlay_dismissed_input = nil
      @select_state = nil
      @question_state = nil
      @last_width = screen_width
      @last_height = screen_height
      @reserved_rows = 0
      @color_enabled = ANSI.enabled?(output)
      @cursor_visible = true
      @synchronized_output_depth = 0
      @overlay_settings = normalize_overlay_settings(overlay_settings)
      @footer = footer
      @composer_status = composer_status
      @busy_help = busy_help
      @attachment_badges = attachment_badges
      @attachment_parser = attachment_parser
      @banner = Banner.new(message: banner_message, pixels: banner_pixels, screen_height: method(:screen_height))
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
        @visual_banner_count = 0
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
        return result if result.is_a?(String)
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
        @prompt_label = message.to_s
        self.composer_input = ""
        self.composer_cursor = 0
        @composer.clear_attachments
                  @pending_keys.clear
        @asking = true
        @busy = false
        @queued_count = 0
        choice_labels = choices.map(&:to_s)
        selection_index = choice_labels.empty? ? 0 : [[initial_index.to_i, 0].max, choice_labels.length - 1].min
        @select_state = { choices: choice_labels, selection_index: selection_index, title: title.to_s, custom: custom, action_keys: normalized_select_action_keys(action_keys) }
        reset_history_navigation
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
            render_prompt_locked unless result.is_a?(String) || select_action_result?(result) || result == SELECT_CANCEL
          end
        end

        if select_action_result?(result) && select_action_handler(result, action_handlers)
          action_result = run_select_action(result, select_action_handler(result, action_handlers))
          next if action_result == SELECT_CONTINUE

          return action_result
        end

        if result.is_a?(String) || select_action_result?(result) || result == SELECT_CANCEL
          finish_select_prompt
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
      @mutex.synchronize { saved_state = begin_question_prompt_state }

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
      @mutex.synchronize { !@question_state.nil? || !@select_state.nil? }
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
        if key.nil?
          resized = handle_resize_locked
          spun = tick_spinner_locked
          footer_refreshed = tick_footer_locked
          render_prompt_locked if resized || spun || footer_refreshed
          return nil
        end

        result = handle_key(key)
        render_prompt_locked unless [EXIT_INPUT, CANCEL_INPUT].include?(result)
        [EXIT_INPUT, CANCEL_INPUT].include?(result) ? result : result
      end
    end

    def update_assistant_label(label)
      @mutex.synchronize do
        @assistant_label = label.to_s.empty? ? "Assistant" : label.to_s
      end
    end

    def print_visual_banner
      @mutex.synchronize do
        width, height = screen_size
        rows = banner_rows(width)
        return if rows.empty?

        with_synchronized_output_locked do
          prepare_transcript_output_locked
          rows.each do |row|
            write_visual_transcript_text_locked(row)
            write_visual_transcript_text_locked("\n")
          end
          @visual_banner_count += 1
          invalidate_transcript_display_rows_cache
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
        @visual_banner_count = 0
        @transcript_viewport_rows = 0
        @stream_state.finish_block
        @stream_state.reset
        width, height = screen_size
        with_synchronized_output_locked { redraw_screen_locked(width: width, height: height) }
        @output_io.flush
      end
    end

    private














































































































































































































  end
end
