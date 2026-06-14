require "io/console"
require "thread"
require "tty-cursor"
require "tty-reader"
require "tty-screen"
require_relative "ansi"
require_relative "prompt_interface/banner"
require_relative "prompt_interface/composer_state"
require_relative "prompt_interface/transcript_buffer"
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

module Kward
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

    def start
      @mutex.synchronize do
        return if @started

        enter_raw_mode_locked
        @started = true
        @asking = true
        @output_io.print(KEYBOARD_PROTOCOL_ENABLE)
        @output_io.print(BRACKETED_PASTE_ENABLE)
        render_prompt_locked
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
      @mutex.synchronize do
        clear_prompt_for_output_locked
        @output_io.print(SYNCHRONIZED_OUTPUT_ENABLE)
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
        @output_io.print(SYNCHRONIZED_OUTPUT_DISABLE)
        width, height = screen_size
        redraw_screen_locked(width: width, height: height)
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

    def select(message, choices, title: "Sessions", custom: false, initial_index: 0)
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
        @select_state = { choices: choice_labels, selection_index: selection_index, title: title.to_s, custom: custom }
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
            render_prompt_locked unless result.is_a?(String) || result == SELECT_CANCEL
          end
        end

        if result.is_a?(String) || result == SELECT_CANCEL
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



    def write_stream_block_locked(label, delta, finish: false)
      with_synchronized_output_locked do
        prepare_transcript_output_locked unless @restoring_transcript
        if label && @stream_state.block != label
          ensure_transcript_block_separator_locked
          write_transcript_text_locked("#{colored("#{transcript_label(label)}>", label_color(label), :bold)}\n")
          @stream_state.start_block(label)
        end
        write_transcript_text_locked(delta) unless delta.empty?
        write_transcript_text_locked("\n") if finish && @stream_state.block
        @stream_state.finish_block if finish
        restore_composer_cursor_locked unless @restoring_transcript
      end
      @output_io.flush unless @restoring_transcript
    end


    def write_transcript_text_locked(text)
      append_transcript_buffer(text.to_s)
      remember_transcript_viewport_locked unless text.to_s.empty?
      write_visual_transcript_text_locked(text)
    end

    def write_visual_transcript_text_locked(text)
      width, height = screen_size
      output_text = terminal_newlines(text.to_s)
      advance_pending_stream_wrap_locked(output_text, width: width, height: height)
      @output_io.print(output_text)
      update_stream_position(output_text, width: width)
    end

    def append_transcript_buffer(text)
      @transcript_buffer.append(text.to_s)
    end

    def invalidate_transcript_display_rows_cache
      @transcript_buffer.invalidate_display_rows_cache
    end

    def ensure_transcript_block_separator_locked
      return if @transcript_buffer.empty? || @transcript_buffer.end_with?("\n\n")

      write_transcript_text_locked(@transcript_buffer.end_with?("\n") ? "\n" : "\n\n")
    end

    def terminal_newlines(text)
      text.gsub(/\r\n|\r|\n/, "\r\n")
    end














    def submit_input
      value = submitted_input
      add_history(composer_input)
      if @busy
        clear_prompt_for_output_locked
        self.composer_input = ""
        self.composer_cursor = 0
        @composer.clear_attachments
        reset_history_navigation
        @asking = true
        render_prompt_after_output_locked
      else
        clear_prompt_locked
        self.composer_input = ""
        self.composer_cursor = 0
        @composer.clear_attachments
        @asking = false
        @rendered_rows = 0
        @cursor_rendered_row = 0
      end
      @output_io.flush
      value
    end

    def submitted_input
      return composer_input if composer_attachments.empty?

      sources = composer_attachments.map { |attachment| attachment[:source_text].to_s }.reject(&:empty?)
      display_input = composer_input.to_s.rstrip
      full_input = [display_input, *sources].reject { |part| part.to_s.strip.empty? }.join("\n")
      SubmittedInput.new(full_input, display_input: display_input)
    end

    def exit_input
      if @busy
        clear_prompt_for_output_locked
        self.composer_input = ""
        self.composer_cursor = 0
        @composer.clear_attachments
        @asking = true
        render_prompt_after_output_locked
      else
        clear_prompt_locked
        self.composer_input = ""
        self.composer_cursor = 0
        @composer.clear_attachments
        @asking = false
        @rendered_rows = 0
        @cursor_rendered_row = 0
      end
      @output_io.flush
      EXIT_INPUT
    end































































































    def render_prompt_locked
      return unless @started && @asking

      handle_resize_locked
      width, height = screen_size
      rows, cursor_row, cursor_col = composer_layout(width, height)
      ensure_scroll_region_locked(rows.length, width: width, height: height)
      @rendered_rows = rows.length
      render_composer_rows_locked(rows, height: height)
      @cursor_rendered_row = cursor_row
      @last_width = width
      @last_height = height
      move_to_screen(composer_top_row(height) + cursor_row, cursor_col + 1)
      render_cursor_visibility_locked
      @output_io.flush
    end

    def render_prompt_after_output_locked
      render_prompt_locked
    end

    def clear_prompt_locked
      handle_resize_locked
      width, height = screen_size
      clear_composer_region_locked(height: height)
      @rendered_rows = 0
      @cursor_rendered_row = 0
      redraw_transcript_locked(width: width, height: height)
    end

    def clear_prompt_for_output_locked
      handle_resize_locked
      width, height = screen_size
      reserve_composer_region_locked(width: width, height: height) if @started && @asking
      clear_composer_region_locked(height: height)
      @rendered_rows = 0
      @cursor_rendered_row = 0
      move_to_transcript_cursor_locked(width: width, height: height) if @started
    end

    def prepare_transcript_output_locked
      handle_resize_locked
      width, height = screen_size
      hide_cursor_for_transcript_output_locked
      reserve_composer_region_locked(width: width, height: height)
      move_to_transcript_cursor_locked(width: width, height: height)
    end


    def restore_composer_cursor_locked
      return unless @started && @asking

      width, height = screen_size
      _rows, cursor_row, cursor_col = composer_layout(width, height)
      move_to_screen(composer_top_row(height) + cursor_row, cursor_col + 1)
      render_cursor_visibility_locked
    end













    def redraw_screen_locked(width: screen_width, height: screen_height)
      return unless @started

      restore_scroll_region_locked
      @output_io.print(TTY::Cursor.clear_screen)
      move_to_screen(1, 1)
      @reserved_rows = 0
      @last_composer_rows = []
      rows, cursor_row, cursor_col = composer_layout(width, height)
      ensure_scroll_region_locked(rows.length, redraw_transcript: false, width: width, height: height)
      redraw_transcript_locked(width: width, height: height)
      @rendered_rows = @asking ? rows.length : 0
      render_composer_rows_locked(rows, height: height) if @asking
      @cursor_rendered_row = @asking ? cursor_row : 0
      @last_width = width
      @last_height = height
      reset_stream_position_from_transcript_locked(width)
      if @asking
        move_to_screen(composer_top_row(height) + cursor_row, cursor_col + 1)
        render_cursor_visibility_locked
      end
    end

    def redraw_transcript_locked(width: screen_width, height: screen_height)
      return unless transcript_renderable?

      rows = transcript_viewport_rows(transcript_redraw_row_count(height), width)
      clear_screen_rows_locked(1, rows.length)
      return if rows.empty?

      move_to_screen(1, 1)
      @output_io.print(terminal_newlines(rows.join("\n")))
    end

    def transcript_viewport_text(row_count, width)
      transcript_viewport_rows(row_count, width).join("\n")
    end

    def transcript_viewport_rows(row_count, width)
      return [] unless row_count.positive?

      rows = transcript_display_rows(width).last(row_count)
      rows = ([""] * (row_count - rows.length)) + rows if rows.length < row_count
      rows
    end


    def remember_transcript_viewport_locked(height = screen_height)
      @transcript_viewport_rows = transcript_bottom_row(height)
    end

    def transcript_renderable?
      @visual_banner_count.positive? || !@transcript_buffer.empty?
    end

    def transcript_display_rows(width)
      @transcript_buffer.display_rows(width, visual_banner_count: @visual_banner_count, banner_rows: method(:banner_rows))
    end

    def transcript_text_display_rows(width)
      @transcript_buffer.text_display_rows(width)
    end

    def reset_stream_position_from_transcript_locked(width = screen_width)
      @stream_state.reset_position_from_rows(transcript_display_rows(width), width)
    end

    def move_to_transcript_cursor_locked(width: screen_width, height: screen_height)
      if @stream_state.pending_wrap?
        move_to_screen(transcript_bottom_row(height), width)
      else
        move_to_screen(transcript_bottom_row(height), [@stream_state.col + 1, width].min)
      end
    end

    def advance_pending_stream_wrap_locked(output_text, width: screen_width, height: screen_height)
      return unless @stream_state.pending_wrap?
      return if output_text.empty? || output_text.start_with?("\r", "\n")

      move_to_screen(transcript_bottom_row(height), width)
      @output_io.print("\r\n")
      @stream_state.clear_pending_wrap
    end

















































    def update_stream_position(text, width: screen_width)
      @stream_state.update_position(text, width: width)
    end

    def colored(text, *styles)
      ANSI.colorize(text, *styles, enabled: @color_enabled)
    end

    def transcript_label(label)
      label == "Assistant" ? @assistant_label : label
    end

    def label_color(label)
      case label
      when "Reasoning"
        :yellow
      when "Assistant", "Kward"
        :green
      when "Tool"
        :magenta
      when "Tool output"
        :cyan
      else
        :blue
      end
    end



  end
end
