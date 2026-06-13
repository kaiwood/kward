require "io/console"
require "thread"
require "tty-cursor"
require "tty-reader"
require "tty-screen"
require_relative "ansi"
require_relative "prompt_interface/banner"

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
      @input = ""
      @cursor = 0
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
      @stream_block = nil
      @rendered_rows = 0
      @last_composer_rows = []
      @cursor_rendered_row = 0
      @stream_col = 0
      @stream_pending_wrap = false
      @transcript_buffer = +""
      @transcript_display_rows_cache_width = nil
      @transcript_display_rows_cache = nil
      @visual_banner_count = 0
      @transcript_viewport_rows = 0
      @restoring_transcript = false
      @pending_keys = []
      @attachments = []
      @kill_buffer = ""
      @original_console_mode = nil
      @raw_mode_active = false
      @history = []
      @history_index = nil
      @history_draft = nil
      @prefill_input = nil
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
          @stream_block = nil
          next
        end

        with_synchronized_output_locked do
          clear_prompt_for_output_locked
          write_transcript_text_locked(text)
          write_transcript_text_locked("\n") unless text.end_with?("\n")
          @stream_block = nil
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
          @stream_block = nil
          render_prompt_after_output_locked
        end
        @output_io.flush
      end
    end

    def restore_transcript
      @mutex.synchronize do
        clear_prompt_for_output_locked
        @output_io.print(SYNCHRONIZED_OUTPUT_ENABLE)
        @transcript_buffer = +""
        invalidate_transcript_display_rows_cache
        @visual_banner_count = 0
        @transcript_viewport_rows = 0
        @stream_block = nil
        @stream_col = 0
        @stream_pending_wrap = false
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
        preserve_input = was_composing && !@busy && !@input.empty?
        @prompt_label = message.to_s
        unless preserve_input
          @input = @prefill_input.to_s
          @prefill_input = nil
          @cursor = @input.length
          @attachments.clear
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
        @input = ""
        @cursor = 0
        @attachments.clear
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
        @input = ""
        @cursor = 0
        @attachments.clear
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
          @stream_block = nil
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
        @transcript_buffer = +""
        invalidate_transcript_display_rows_cache
        @visual_banner_count = 0
        @transcript_viewport_rows = 0
        @stream_block = nil
        @stream_col = 0
        @stream_pending_wrap = false
        width, height = screen_size
        with_synchronized_output_locked { redraw_screen_locked(width: width, height: height) }
        @output_io.flush
      end
    end

    private

    def enter_raw_mode_locked
      return unless @input_io.respond_to?(:tty?) && @input_io.tty?
      return unless @input_io.respond_to?(:console_mode) && @input_io.respond_to?(:console_mode=)
      return if @raw_mode_active

      @original_console_mode = @input_io.console_mode
      raw_mode = @input_io.console_mode.raw
      raw_mode.echo = false
      @input_io.console_mode = raw_mode
      @raw_mode_active = true
    rescue StandardError
      @original_console_mode = nil
      @raw_mode_active = false
    end

    def restore_console_mode_locked
      return unless @raw_mode_active

      @input_io.console_mode = @original_console_mode if @original_console_mode
    ensure
      @original_console_mode = nil
      @raw_mode_active = false
    end

    def write_stream_block_locked(label, delta, finish: false)
      with_synchronized_output_locked do
        prepare_transcript_output_locked unless @restoring_transcript
        if label && @stream_block != label
          ensure_transcript_block_separator_locked
          write_transcript_text_locked("#{colored("#{transcript_label(label)}>", label_color(label), :bold)}\n")
          @stream_block = label
        end
        write_transcript_text_locked(delta) unless delta.empty?
        write_transcript_text_locked("\n") if finish && @stream_block
        @stream_block = nil if finish
        restore_composer_cursor_locked unless @restoring_transcript
      end
      @output_io.flush unless @restoring_transcript
    end

    def with_synchronized_output_locked
      if @restoring_transcript || @synchronized_output_depth.positive?
        yield
        return
      end

      synchronized = true
      @synchronized_output_depth += 1
      @output_io.print(SYNCHRONIZED_OUTPUT_ENABLE)
      yield
    ensure
      if synchronized
        @synchronized_output_depth -= 1
        @output_io.print(SYNCHRONIZED_OUTPUT_DISABLE) if @synchronized_output_depth.zero?
      end
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
      @transcript_buffer << ANSI.sanitize_transcript(text)
      invalidate_transcript_display_rows_cache
      return if @transcript_buffer.length <= TRANSCRIPT_BUFFER_LIMIT

      @transcript_buffer = @transcript_buffer[-TRANSCRIPT_BUFFER_LIMIT, TRANSCRIPT_BUFFER_LIMIT]
    end

    def invalidate_transcript_display_rows_cache
      @transcript_display_rows_cache_width = nil
      @transcript_display_rows_cache = nil
    end

    def ensure_transcript_block_separator_locked
      return if @transcript_buffer.empty? || @transcript_buffer.end_with?("\n\n")

      write_transcript_text_locked(@transcript_buffer.end_with?("\n") ? "\n" : "\n\n")
    end

    def terminal_newlines(text)
      text.gsub(/\r\n|\r|\n/, "\r\n")
    end

    def reset_spinner_locked
      @spinner_frame_index = 0
      @last_spinner_tick = monotonic_now
    end

    def normalize_busy_activity(activity)
      text = activity.to_s.gsub(/\s+/, " ").strip
      text.empty? ? "streaming" : text
    end

    def tick_spinner_locked
      return false unless @busy && @queued_count.zero? && @started && @asking

      now = monotonic_now
      elapsed = now - @last_spinner_tick
      return false if elapsed < SPINNER_INTERVAL

      steps = (elapsed / SPINNER_INTERVAL).floor
      @spinner_frame_index = (@spinner_frame_index + steps) % SPINNER_FRAMES.length
      @last_spinner_tick += steps * SPINNER_INTERVAL
      true
    end

    def spinner_frame
      SPINNER_FRAMES[@spinner_frame_index % SPINNER_FRAMES.length]
    end

    def tick_footer_locked
      return false unless @footer && @started && @asking

      now = monotonic_now
      elapsed = now - @last_footer_refresh
      return false if elapsed < FOOTER_REFRESH_INTERVAL

      steps = (elapsed / FOOTER_REFRESH_INTERVAL).floor
      @last_footer_refresh += steps * FOOTER_REFRESH_INTERVAL
      true
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def submit_input
      value = submitted_input
      add_history(@input)
      if @busy
        clear_prompt_for_output_locked
        @input = ""
        @cursor = 0
        @attachments.clear
        reset_history_navigation
        @asking = true
        render_prompt_after_output_locked
      else
        clear_prompt_locked
        @input = ""
        @cursor = 0
        @attachments.clear
        @asking = false
        @rendered_rows = 0
        @cursor_rendered_row = 0
      end
      @output_io.flush
      value
    end

    def submitted_input
      return @input if @attachments.empty?

      sources = @attachments.map { |attachment| attachment[:source_text].to_s }.reject(&:empty?)
      display_input = @input.to_s.rstrip
      full_input = [display_input, *sources].reject { |part| part.to_s.strip.empty? }.join("\n")
      SubmittedInput.new(full_input, display_input: display_input)
    end

    def exit_input
      if @busy
        clear_prompt_for_output_locked
        @input = ""
        @cursor = 0
        @attachments.clear
        @asking = true
        render_prompt_after_output_locked
      else
        clear_prompt_locked
        @input = ""
        @cursor = 0
        @attachments.clear
        @asking = false
        @rendered_rows = 0
        @cursor_rendered_row = 0
      end
      @output_io.flush
      EXIT_INPUT
    end

    def read_key(nonblock: false)
      pending = @pending_keys.shift unless @pending_keys.empty?
      return pending if pending

      @reader.read_keypress(echo: false, raw: true, nonblock: nonblock)
    rescue TTY::Reader::InputInterrupt
      "\x03"
    rescue IO::WaitReadable, Errno::EAGAIN, Errno::EWOULDBLOCK
      nil
    end

    def handle_key(key)
      return submit_input if key.nil?
      return if handle_bracketed_paste_key(key)

      csi_result = handle_csi_u_key(key)
      return csi_result unless csi_result == false
      return if handle_shift_enter_key(key)
      if key.is_a?(String) && key.length > 1
        token = next_key_token(key)
        if token.length < key.length
          queue_pending_keys(key[token.length..])
          return handle_key(token)
        end
      end

      binding_result = handle_composer_key_binding(key)
      return binding_result unless binding_result == false

      key_name = @reader.console.keys[key]
      case key_name
      when :return, :enter
        submit_input
      when :backspace
        delete_before_cursor
      when :delete
        delete_at_cursor
      when :ctrl_d
        delete_at_cursor_or_exit
      when :ctrl_c
        cancel_input_or_interrupt
      when :ctrl_a
        move_to_start_of_line
      when :ctrl_e
        move_to_end_of_line
      when :ctrl_b
        move_cursor_left
      when :ctrl_f
        move_cursor_right
      when :ctrl_w
        delete_word_before_cursor
      when :ctrl_u
        kill_line_before_cursor
      when :ctrl_k
        kill_line_after_cursor
      when :ctrl_y
        yank_kill_buffer
      when :ctrl_l
        redraw_screen_locked
      when :left
        move_cursor_left
      when :right
        move_cursor_right
      when :home
        move_to_start_of_line
      when :end
        move_to_end_of_line
      when :up
        slash_overlay_visible? ? select_previous_slash_command : recall_previous_history
      when :down
        slash_overlay_visible? ? select_next_slash_command : recall_next_history
      else
        case key
        when "\n", "\r"
          submit_input
        when "\t"
          complete_selected_slash_command || insert_key(key)
        when "\b", "\x7F"
          delete_before_cursor
        when "\x04"
          delete_at_cursor_or_exit
        when "\x03"
          cancel_input_or_interrupt
        when "\e"
          handle_escape_sequence
        else
          insert_key(key)
        end
      end
    end

    def cancel_input_or_interrupt
      return CANCEL_INPUT if @busy

      raise Interrupt
    end

    def handle_escape_sequence
      pending_sequence = read_pending_escape_sequence
      return true if pending_sequence.empty? && dismiss_slash_overlay

      full_sequence = "\e#{pending_sequence}"
      sequence = next_key_token(full_sequence)
      queue_pending_keys(full_sequence[sequence.length..]) if full_sequence.length > sequence.length
      return true if sequence == "\e" && dismiss_slash_overlay
      return true if handle_shift_enter_key(sequence)

      binding_result = handle_composer_key_binding(sequence)
      return binding_result unless binding_result == false

      key_name = @reader.console.keys[sequence]
      case key_name
      when :up
        slash_overlay_visible? ? select_previous_slash_command : recall_previous_history
      when :down
        slash_overlay_visible? ? select_next_slash_command : recall_next_history
      when :left
        move_cursor_left
      when :right
        move_cursor_right
      when :home
        move_to_start_of_line
      when :end
        move_to_end_of_line
      when :delete
        delete_at_cursor
      end
      true
    end

    def ask_single_user_question(question, index, total)
      @mutex.synchronize do
        @prompt_label = "Answer>"
        @input = ""
        @cursor = 0
        @pending_keys.clear
        @asking = true
        @busy = false
        @queued_count = 0
        @question_state = {
          question: question[:question] || question["question"],
          header: question[:header] || question["header"],
          options: question[:options] || question["options"],
          selection_index: 0,
          index: index,
          total: total
        }
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
            result = handle_question_key(key)
            render_prompt_locked unless result.is_a?(Hash) || result == SELECT_CANCEL
          end
        end

        return result if result.is_a?(Hash) || result == SELECT_CANCEL

        sleep 0.02 if key.nil?
      end
    end

    def begin_question_prompt_state
      {
        prompt_label: @prompt_label,
        input: @input,
        cursor: @cursor,
        asking: @asking,
        busy: @busy,
        queued_count: @queued_count,
        steered_count: @steered_count,
        pending_keys: @pending_keys.dup,
        select_state: @select_state
      }
    end

    def finish_question_prompt(saved_state)
      @mutex.synchronize do
        @question_state = nil
        @select_state = saved_state[:select_state]
        @prompt_label = saved_state[:prompt_label]
        @input = saved_state[:input]
        @cursor = saved_state[:cursor]
        @asking = saved_state[:asking]
        @busy = saved_state[:busy]
        @queued_count = saved_state[:queued_count]
        @steered_count = saved_state[:steered_count]
        @pending_keys = saved_state[:pending_keys]
        render_prompt_locked if @started && @asking
        @output_io.flush
      end
    end

    def handle_question_key(key)
      return if handle_question_bracketed_paste_key(key)

      csi_result = handle_question_csi_u_key(key)
      return csi_result unless csi_result == false

      if key.is_a?(String) && key.length > 1
        token = next_key_token(key)
        if token.length < key.length
          queue_pending_keys(key[token.length..])
          return handle_question_key(token)
        end
      end

      key_name = @reader.console.keys[key]
      case key_name
      when :return, :enter
        current_question_answer
      when :backspace
        question_delete_before_cursor
      when :delete
        question_delete_at_cursor
      when :left
        @cursor -= 1 if @cursor.positive?
      when :right
        @cursor += 1 if @cursor < @input.length
      when :home
        @cursor = 0
      when :end
        @cursor = @input.length
      when :up
        question_previous_choice
      when :down
        question_next_choice
      else
        case key
        when "\n", "\r"
          current_question_answer
        when "\b", "\x7F"
          question_delete_before_cursor
        when "\e"
          handle_question_escape_sequence
        else
          question_insert_key(key)
        end
      end
    end

    def handle_question_csi_u_key(key)
      match = key.to_s.match(/\A\e\[(\d+)(?:;([\d:]+))?u/)
      return false unless match

      sequence = match[0]
      code = match[1].to_i
      queue_pending_keys(key[sequence.length..]) if key.length > sequence.length

      case code
      when 13
        current_question_answer
      when 27
        SELECT_CANCEL
      when 8, 127
        question_delete_before_cursor
        nil
      else
        false
      end
    end

    def handle_question_escape_sequence
      sequence = read_pending_escape_sequence
      return SELECT_CANCEL if sequence.empty?

      key_name = @reader.console.keys["\e#{sequence}"]
      case key_name
      when :up
        question_previous_choice
      when :down
        question_next_choice
      when :left
        @cursor -= 1 if @cursor.positive?
      when :right
        @cursor += 1 if @cursor < @input.length
      end
      true
    end

    def handle_question_bracketed_paste_key(key)
      text = key.to_s
      return false unless text.start_with?(BRACKETED_PASTE_START)

      pasted = text[BRACKETED_PASTE_START.length..] || ""
      until pasted.include?(BRACKETED_PASTE_END)
        chunk = @reader.read_keypress(echo: false, raw: true)
        break if chunk.nil?

        pasted << chunk.to_s
      end

      content, remaining = pasted.split(BRACKETED_PASTE_END, 2)
      question_insert_string(normalize_paste(content || ""))
      queue_pending_keys(remaining) if remaining && !remaining.empty?
      true
    end

    def handle_select_key(key)
      return select_current_choice if key.nil?
      return if handle_select_bracketed_paste_key(key)

      csi_result = handle_select_csi_u_key(key)
      return csi_result unless csi_result == false

      if key.is_a?(String) && key.length > 1
        token = next_key_token(key)
        if token.length < key.length
          queue_pending_keys(key[token.length..])
          return handle_select_key(token)
        end
      end

      key_name = @reader.console.keys[key]
      case key_name
      when :return, :enter
        select_current_choice
      when :backspace
        select_delete_before_cursor
      when :delete
        select_delete_at_cursor
      when :left
        @cursor -= 1 if @cursor.positive?
      when :right
        @cursor += 1 if @cursor < @input.length
      when :home
        @cursor = 0
      when :end
        @cursor = @input.length
      when :up
        select_previous_choice
      when :down
        select_next_choice
      else
        case key
        when "\n", "\r"
          select_current_choice
        when "\b", "\x7F"
          select_delete_before_cursor
        when "\e"
          handle_select_escape_sequence
        else
          select_insert_key(key)
        end
      end
    end

    def handle_select_csi_u_key(key)
      match = key.to_s.match(/\A\e\[(\d+)(?:;([\d:]+))?u/)
      return false unless match

      sequence = match[0]
      code = match[1].to_i
      queue_pending_keys(key[sequence.length..]) if key.length > sequence.length

      case code
      when 13
        select_current_choice
      when 27
        SELECT_CANCEL
      when 8, 127
        select_delete_before_cursor
        nil
      else
        false
      end
    end

    def handle_select_escape_sequence
      sequence = read_pending_escape_sequence
      return SELECT_CANCEL if sequence.empty?

      key_name = @reader.console.keys["\e#{sequence}"]
      case key_name
      when :up
        select_previous_choice
      when :down
        select_next_choice
      when :left
        @cursor -= 1 if @cursor.positive?
      when :right
        @cursor += 1 if @cursor < @input.length
      end
      true
    end

    def handle_select_bracketed_paste_key(key)
      text = key.to_s
      return false unless text.start_with?(BRACKETED_PASTE_START)

      pasted = text[BRACKETED_PASTE_START.length..] || ""
      until pasted.include?(BRACKETED_PASTE_END)
        chunk = @reader.read_keypress(echo: false, raw: true)
        break if chunk.nil?

        pasted << chunk.to_s
      end

      content, remaining = pasted.split(BRACKETED_PASTE_END, 2)
      select_insert_string(normalize_paste(content || ""))
      queue_pending_keys(remaining) if remaining && !remaining.empty?
      true
    end

    def handle_bracketed_paste_key(key)
      text = key.to_s
      return false unless text.start_with?(BRACKETED_PASTE_START)

      pasted = text[BRACKETED_PASTE_START.length..] || ""
      until pasted.include?(BRACKETED_PASTE_END)
        chunk = @reader.read_keypress(echo: false, raw: true)
        break if chunk.nil?

        pasted << chunk.to_s
      end

      content, remaining = pasted.split(BRACKETED_PASTE_END, 2)
      insert_paste(normalize_paste(content || ""))
      queue_pending_keys(remaining) if remaining && !remaining.empty?
      true
    end

    def normalize_paste(content)
      content.gsub("\r\n", "\n").gsub("\r", "\n")
    end

    def handle_csi_u_key(key)
      match = key.to_s.match(/\A\e\[(\d+)(?:;([\d:]+))?u/)
      return false unless match

      sequence = match[0]
      code = match[1].to_i
      modifier = (match[2] || "1").split(":", 2).first.to_i
      queue_pending_keys(key[sequence.length..]) if key.length > sequence.length

      case code
      when 13
        modifier == 2 ? insert_string("\n") : submit_input
      when 27
        dismiss_slash_overlay || false
      when 8, 127
        alt_modifier?(modifier) ? delete_word_before_cursor : delete_before_cursor
        nil
      when 4
        delete_at_cursor_or_exit
      else
        handle_modified_csi_u_key(code, modifier)
      end
    end

    def handle_modified_csi_u_key(code, modifier)
      return false unless ctrl_modifier?(modifier) || alt_modifier?(modifier)

      normalized_code = code.to_i.chr.downcase.ord rescue code
      if ctrl_modifier?(modifier)
        case normalized_code
        when 97
          move_to_start_of_line
        when 98
          move_cursor_left
        when 99
          cancel_input_or_interrupt
        when 100
          delete_at_cursor_or_exit
        when 101
          move_to_end_of_line
        when 102
          move_cursor_right
        when 104
          delete_before_cursor
        when 107
          kill_line_after_cursor
        when 108
          redraw_screen_locked
        when 117
          kill_line_before_cursor
        when 119
          delete_word_before_cursor
        when 121
          yank_kill_buffer
        else
          false
        end
      elsif alt_modifier?(modifier)
        case normalized_code
        when 98
          move_to_previous_word
        when 100
          delete_word_after_cursor
        when 102
          move_to_next_word
        else
          false
        end
      else
        false
      end
    end

    def ctrl_modifier?(modifier)
      ((modifier.to_i - 1) & 4).positive?
    end

    def alt_modifier?(modifier)
      ((modifier.to_i - 1) & 2).positive?
    end

    def handle_shift_enter_key(key)
      sequence = shift_enter_sequence_for(key)
      return false unless sequence

      insert_string("\n")
      queue_pending_keys(key[sequence.length..]) if key.length > sequence.length
      true
    end

    def queue_pending_keys(keys)
      remaining = keys.to_s
      until remaining.empty?
        token = next_key_token(remaining)
        @pending_keys << token
        remaining = remaining[token.length..] || ""
      end
    end

    def next_key_token(keys)
      text = keys.to_s
      text.match(/\A\e\[[0-9;:]*[A-Za-z~]/)&.[](0) ||
        text.match(/\A\eO[A-Za-z]/)&.[](0) ||
        shift_enter_sequence_for(text) ||
        (text.start_with?("\e") && text.length > 1 && alt_key_sequence?(text[1]) ? text[0, 2] : text[0, 1])
    end

    def alt_key_sequence?(char)
      char = char.to_s
      char.match?(/[[:alpha:]]/) || char == "\b" || char == "\x7F"
    end

    def shift_enter_sequence_for(key)
      return nil unless key.is_a?(String)

      SHIFT_ENTER_SEQUENCES.find { |sequence| key.start_with?(sequence) }
    end

    def read_pending_escape_sequence
      sequence = +""
      until @pending_keys.empty?
        sequence << @pending_keys.shift.to_s
      end
      while (char = @reader.read_keypress(echo: false, raw: true, nonblock: true))
        sequence << char.to_s
      end
      sequence
    rescue IO::WaitReadable, Errno::EAGAIN, Errno::EWOULDBLOCK
      sequence
    end

    def current_question_answer
      choice = selected_question_choice
      return nil unless choice

      if choice[:custom]
        answer = @input.strip
        return nil if answer.empty?

        { question: current_question_text, answer: answer, custom: true }
      else
        { question: current_question_text, answer: choice[:label], custom: false }
      end
    end

    def selected_question_choice
      choices = question_choices
      return nil if choices.empty?

      choices[question_selection_index]
    end

    def question_choices
      options = Array(@question_state ? @question_state[:options] : []).map do |option|
        { label: (option[:label] || option["label"]).to_s, description: (option[:description] || option["description"]).to_s }
      end
      choices = options + [{ label: "Type something.", description: @input.strip, custom: true }]
      clamp_question_selection_index(choices.length)
      choices
    end

    def current_question_text
      (@question_state && @question_state[:question]).to_s
    end

    def question_selection_index
      @question_state ? @question_state[:selection_index].to_i : 0
    end

    def clamp_question_selection_index(count)
      return unless @question_state

      @question_state[:selection_index] = 0 if count <= 0
      @question_state[:selection_index] = count - 1 if count.positive? && question_selection_index >= count
    end

    def question_previous_choice
      choices = question_choices
      return if choices.empty?

      @question_state[:selection_index] = (question_selection_index - 1) % choices.length
    end

    def question_next_choice
      choices = question_choices
      return if choices.empty?

      @question_state[:selection_index] = (question_selection_index + 1) % choices.length
    end

    def question_insert_key(key)
      return unless key.is_a?(String) && key.length == 1 && key.match?(/[[:print:]]/)

      question_insert_string(key)
    end

    def question_insert_string(string)
      return if string.empty?

      @input = @input[0...@cursor] + string + @input[@cursor..]
      @cursor += string.length
      @question_state[:selection_index] = question_choices.length - 1 if @question_state
    end

    def question_delete_before_cursor
      return unless @cursor.positive?

      @input = @input[0...(@cursor - 1)] + @input[@cursor..]
      @cursor -= 1
      @question_state[:selection_index] = question_choices.length - 1 if @question_state && !@input.empty?
    end

    def question_delete_at_cursor
      return unless @cursor < @input.length

      @input = @input[0...@cursor] + @input[(@cursor + 1)..]
      @question_state[:selection_index] = question_choices.length - 1 if @question_state && !@input.empty?
    end

    def select_current_choice
      selected_selection_choice || custom_selection_choice || SELECT_CANCEL
    end

    def custom_selection_choice
      return nil unless @select_state && @select_state[:custom]

      value = @input.strip
      value.empty? ? nil : value
    end

    def selected_selection_choice
      matches = selection_matches
      return nil if matches.empty?

      matches[selection_index]
    end

    def select_previous_choice
      matches = selection_matches
      return if matches.empty?

      @select_state[:selection_index] = (selection_index - 1) % matches.length
    end

    def select_next_choice
      matches = selection_matches
      return if matches.empty?

      @select_state[:selection_index] = (selection_index + 1) % matches.length
    end

    def select_insert_key(key)
      return unless key.is_a?(String) && key.length == 1 && key.match?(/[[:print:]]/)

      select_insert_string(key)
    end

    def select_insert_string(string)
      return if string.empty?

      @input = @input[0...@cursor] + string + @input[@cursor..]
      @cursor += string.length
      @select_state[:selection_index] = 0 if @select_state
    end

    def select_delete_before_cursor
      return unless @cursor.positive?

      @input = @input[0...(@cursor - 1)] + @input[@cursor..]
      @cursor -= 1
      @select_state[:selection_index] = 0 if @select_state
    end

    def select_delete_at_cursor
      return unless @cursor < @input.length

      @input = @input[0...@cursor] + @input[(@cursor + 1)..]
      @select_state[:selection_index] = 0 if @select_state
    end

    def selection_matches
      choices = @select_state ? @select_state[:choices] : []
      filter = @input.downcase.strip
      matches = filter.empty? ? choices : choices.select { |choice| choice.downcase.include?(filter) }
      clamp_selection_index(matches.length)
      matches
    end

    def selection_index
      @select_state ? @select_state[:selection_index].to_i : 0
    end

    def clamp_selection_index(count)
      return unless @select_state

      @select_state[:selection_index] = 0 if count <= 0
      @select_state[:selection_index] = count - 1 if count.positive? && selection_index >= count
    end

    def finish_select_prompt
      @mutex.synchronize do
        @select_state = nil
        clear_prompt_locked
        @input = ""
        @cursor = 0
        @asking = false
        @rendered_rows = 0
        @cursor_rendered_row = 0
        @output_io.flush
      end
    end

    def insert_key(key)
      return unless key.is_a?(String) && key.length == 1 && key.match?(/[[:print:]]/)

      insert_string(key)
    end

    def insert_string(string)
      return if string.empty?

      reset_slash_selection
      reset_history_navigation
      @slash_overlay_dismissed_input = nil
      @input = @input[0...@cursor] + string + @input[@cursor..]
      @cursor += string.length
    end

    def insert_paste(string)
      parsed = parse_attachments(string)
      Array(parsed[:attachments]).each { |attachment| add_attachment(attachment) }
      insert_string(parsed[:text].to_s) unless parsed[:text].to_s.empty?
    end

    def parse_attachments(string)
      return { text: string.to_s, attachments: [] } unless @attachment_parser

      result = @attachment_parser.call(string.to_s)
      return { text: string.to_s, attachments: [] } unless result.is_a?(Hash)

      {
        text: result[:text] || result["text"] || "",
        attachments: result[:attachments] || result["attachments"] || []
      }
    rescue StandardError
      { text: string.to_s, attachments: [] }
    end

    def add_attachment(attachment)
      return unless attachment.respond_to?(:key?)

      source = attachment[:source_text] || attachment["source_text"] || attachment[:original_path] || attachment["original_path"]
      return if source.to_s.empty?
      return if @attachments.any? { |item| (item[:source_text] || item["source_text"]).to_s == source.to_s }

      @attachments << attachment
    end

    def delete_before_cursor
      if @cursor.zero?
        remove_last_attachment
        return
      end

      reset_slash_selection
      reset_history_navigation
      @input = @input[0...(@cursor - 1)] + @input[@cursor..]
      @cursor -= 1
    end

    def remove_last_attachment
      return if @attachments.empty?

      reset_slash_selection
      reset_history_navigation
      @slash_overlay_dismissed_input = nil
      @attachments.pop
    end

    def delete_at_cursor
      return unless @cursor < @input.length

      reset_slash_selection
      reset_history_navigation
      @slash_overlay_dismissed_input = nil
      @input = @input[0...@cursor] + @input[(@cursor + 1)..]
    end

    def handle_composer_key_binding(key)
      case key
      when "\x01"
        move_to_start_of_line
      when "\x02"
        move_cursor_left
      when "\x04"
        delete_at_cursor_or_exit
      when "\x05"
        move_to_end_of_line
      when "\x06"
        move_cursor_right
      when "\x0B"
        kill_line_after_cursor
      when "\x0C"
        redraw_screen_locked
      when "\x15"
        kill_line_before_cursor
      when "\x17"
        delete_word_before_cursor
      when "\x19"
        yank_kill_buffer
      when "\e[D", "\eOD"
        move_cursor_left
      when "\e[C", "\eOC"
        move_cursor_right
      when "\e[H", "\eOH", "\e[1~", "\e[7~"
        move_to_start_of_line
      when "\e[F", "\eOF", "\e[4~", "\e[8~"
        move_to_end_of_line
      when "\e[3~"
        delete_at_cursor
      when "\eb", "\eB"
        move_to_previous_word
      when "\ef", "\eF"
        move_to_next_word
      when "\ed", "\eD"
        delete_word_after_cursor
      when "\e\b", "\e\x7F"
        delete_word_before_cursor
      else
        handle_modified_ansi_key(key) || false
      end
    end

    def handle_modified_ansi_key(key)
      match = key.to_s.match(/\A\e\[(\d+);(\d+)([CDFH])\z/)
      if match
        modifier = match[2].to_i
        final = match[3]
        return false unless alt_modifier?(modifier)

        case final
        when "C"
          move_to_next_word
        when "D"
          move_to_previous_word
        when "F"
          move_to_end_of_line
        when "H"
          move_to_start_of_line
        else
          false
        end
      elsif (match = key.to_s.match(/\A\e\[3;(\d+)~\z/))
        alt_modifier?(match[1].to_i) ? delete_word_after_cursor : delete_at_cursor
      else
        false
      end
    end

    def move_cursor_left
      @cursor -= 1 if @cursor.positive?
    end

    def move_cursor_right
      @cursor += 1 if @cursor < @input.length
    end

    def move_to_start_of_line
      @cursor = 0
    end

    def move_to_end_of_line
      @cursor = @input.length
    end

    def move_to_previous_word
      @cursor = previous_word_boundary(@cursor)
    end

    def move_to_next_word
      @cursor = next_word_boundary(@cursor)
    end

    def delete_at_cursor_or_exit
      @input.empty? ? exit_input : delete_at_cursor
    end

    def delete_word_before_cursor
      start_index = previous_word_boundary(@cursor)
      kill_range(start_index, @cursor)
    end

    def delete_word_after_cursor
      end_index = next_word_boundary(@cursor)
      kill_range(@cursor, end_index)
    end

    def kill_line_before_cursor
      kill_range(0, @cursor)
    end

    def kill_line_after_cursor
      kill_range(@cursor, @input.length)
    end

    def kill_range(start_index, end_index)
      return if start_index == end_index

      reset_slash_selection
      reset_history_navigation
      @kill_buffer = @input[start_index...end_index].to_s
      @input = @input[0...start_index].to_s + @input[end_index..].to_s
      @cursor = start_index
    end

    def yank_kill_buffer
      insert_string(@kill_buffer.to_s) unless @kill_buffer.to_s.empty?
    end

    def previous_word_boundary(index)
      cursor = index
      cursor -= 1 while cursor.positive? && word_separator?(@input[cursor - 1])
      cursor -= 1 while cursor.positive? && !word_separator?(@input[cursor - 1])
      cursor
    end

    def next_word_boundary(index)
      cursor = index
      cursor += 1 while cursor < @input.length && word_separator?(@input[cursor])
      cursor += 1 while cursor < @input.length && !word_separator?(@input[cursor])
      cursor
    end

    def word_separator?(char)
      char.to_s.match?(/\s/)
    end

    def add_history(value)
      stripped = value.to_s.strip
      return if stripped.empty?
      return if @history.last == value

      @history << value
    end

    def recall_previous_history
      return if @history.empty?

      @history_draft = @input if @history_index.nil?
      @history_index = @history_index.nil? ? @history.length - 1 : [@history_index - 1, 0].max
      replace_input(@history[@history_index])
    end

    def recall_next_history
      return if @history_index.nil?

      if @history_index < @history.length - 1
        @history_index += 1
        replace_input(@history[@history_index])
      else
        replace_input(@history_draft || "")
        reset_history_navigation
      end
    end

    def replace_input(value)
      @input = value.to_s
      @cursor = @input.length
    end

    def prefill_input(value)
      @mutex.synchronize do
        @prefill_input = value.to_s
      end
    end

    def reset_history_navigation
      @history_index = nil
      @history_draft = nil
    end

    def reset_slash_selection
      @slash_selection_index = 0
    end

    def dismiss_slash_overlay
      return false unless slash_overlay_visible?

      @slash_overlay_dismissed_input = @input.dup
      reset_slash_selection
      true
    end

    def normalize_slash_commands(commands)
      commands.map do |command|
        {
          name: slash_command_value(command, :name).to_s,
          description: slash_command_value(command, :description).to_s,
          argument_hint: slash_command_value(command, :argument_hint).to_s
        }
      end.reject { |command| command[:name].empty? }.sort_by { |command| command[:name] }
    end

    def slash_command_value(command, key)
      return command[key] if command.respond_to?(:key?) && command.key?(key)
      return command[key.to_s] if command.respond_to?(:key?) && command.key?(key.to_s)
      return command.public_send(key) if command.respond_to?(key)

      ""
    end

    def slash_overlay_visible?
      @input.match?(%r{\A/[^\s/]*\z}) && @slash_overlay_dismissed_input != @input && !slash_overlay_matches.empty?
    end

    def slash_overlay_matches
      prefix = @input.delete_prefix("/").downcase
      @slash_commands.select { |command| command[:name].downcase.start_with?(prefix) }.first(8)
    end

    def selected_slash_command
      return nil unless slash_overlay_visible?

      matches = slash_overlay_matches
      return nil if matches.empty?

      matches[[@slash_selection_index, matches.length - 1].min]
    end

    def select_previous_slash_command
      matches = slash_overlay_matches
      return if matches.empty?

      @slash_selection_index = (@slash_selection_index - 1) % matches.length
    end

    def select_next_slash_command
      matches = slash_overlay_matches
      return if matches.empty?

      @slash_selection_index = (@slash_selection_index + 1) % matches.length
    end

    def complete_selected_slash_command
      command = selected_slash_command
      return false unless command

      replace_input("/#{command[:name]} ")
      reset_slash_selection
      true
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

    def hide_cursor_for_transcript_output_locked
      return unless @started && @asking

      set_cursor_visible_locked(false)
    end

    def restore_composer_cursor_locked
      return unless @started && @asking

      width, height = screen_size
      _rows, cursor_row, cursor_col = composer_layout(width, height)
      move_to_screen(composer_top_row(height) + cursor_row, cursor_col + 1)
      render_cursor_visibility_locked
    end

    def render_cursor_visibility_locked
      visible = !(@question_state && !selected_question_choice&.fetch(:custom, false))
      set_cursor_visible_locked(visible)
    end

    def set_cursor_visible_locked(visible, force: false)
      return if !force && @cursor_visible == visible

      @output_io.print(visible ? CURSOR_SHOW : CURSOR_HIDE)
      @cursor_visible = visible
    end

    def reserve_composer_region_locked(width: screen_width, height: screen_height)
      rows, = composer_layout(width, height)
      ensure_scroll_region_locked(rows.length, width: width, height: height)
    end

    def ensure_scroll_region_locked(row_count, redraw_transcript: true, width: screen_width, height: screen_height)
      new_reserved_rows = [[row_count, 1].max, [height - 1, 1].max].min
      return if @reserved_rows == new_reserved_rows && @last_height == height

      old_reserved_rows = @reserved_rows
      rows_to_clear = [old_reserved_rows, new_reserved_rows].max
      @reserved_rows = new_reserved_rows
      @output_io.print("\e[1;#{transcript_bottom_row(height)}r")
      clear_composer_region_locked(rows_to_clear, height: height)
      redraw_transcript_locked(width: width, height: height) if redraw_transcript && new_reserved_rows < old_reserved_rows
    end

    def handle_resize_locked
      current_width, current_height = screen_size
      return false if current_width == @last_width && current_height == @last_height

      old_width = @last_width
      old_height = @last_height
      old_reserved_rows = @reserved_rows
      restore_scroll_region_locked
      rows_to_clear = resize_prompt_clear_rows(old_width, current_width, old_reserved_rows)
      clear_resized_composer_region_locked(old_height, current_height, rows_to_clear)
      @reserved_rows = 0
      @last_width = current_width
      @last_height = current_height
      redraw_screen_locked(width: current_width, height: current_height)
      true
    end

    def restore_scroll_region_locked
      @output_io.print("\e[r")
      @reserved_rows = 0
    end

    def render_composer_rows_locked(rows, height: screen_height)
      top = composer_top_row(height)
      max_rows = [@last_composer_rows.length, rows.length].max
      rows_to_clear = [@reserved_rows - rows.length, 0].max

      max_rows.times do |index|
        row = rows[index]
        previous = @last_composer_rows[index]
        next if row == previous

        move_to_screen(top + index, 1)
        @output_io.print(TTY::Cursor.clear_line)
        @output_io.print(row) unless row.to_s.empty?
      end

      rows.length.upto(rows.length + rows_to_clear - 1) do |index|
        move_to_screen(top + index, 1)
        @output_io.print(TTY::Cursor.clear_line)
      end

      @last_composer_rows = rows.dup
    end

    def clear_composer_region_locked(rows_to_clear = nil, height: screen_height)
      rows_to_clear ||= [@reserved_rows, @rendered_rows].max
      clear_bottom_rows_locked(height, rows_to_clear)
      @last_composer_rows = []
    end

    def resize_prompt_clear_rows(old_width, current_width, old_reserved_rows)
      return old_reserved_rows unless old_reserved_rows.positive?

      return old_reserved_rows unless current_width < old_width

      wrapped_rows_per_row = ((old_width - 1) / current_width) + 1
      old_reserved_rows * wrapped_rows_per_row
    end

    def clear_resized_composer_region_locked(old_height, current_height, rows_to_clear)
      return unless rows_to_clear.positive?

      old_top = [old_height - rows_to_clear + 1, 1].max
      current_top = [current_height - rows_to_clear + 1, 1].max
      clear_screen_rows_locked([old_top, current_top].min, current_height)
    end

    def clear_bottom_rows_locked(height, rows_to_clear)
      return unless rows_to_clear.positive?

      bottom = height
      top = [bottom - rows_to_clear + 1, 1].max
      clear_screen_rows_locked(top, bottom)
    end

    def clear_screen_rows_locked(top, bottom)
      top.upto(bottom) do |row|
        move_to_screen(row, 1)
        @output_io.print(TTY::Cursor.clear_line)
      end
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

    def transcript_redraw_row_count(height = screen_height)
      [[@transcript_viewport_rows, transcript_bottom_row(height)].max, height].min
    end

    def remember_transcript_viewport_locked(height = screen_height)
      @transcript_viewport_rows = transcript_bottom_row(height)
    end

    def transcript_renderable?
      @visual_banner_count.positive? || !@transcript_buffer.empty?
    end

    def transcript_display_rows(width)
      return @transcript_display_rows_cache if @transcript_display_rows_cache_width == width && @transcript_display_rows_cache

      rows = []
      @visual_banner_count.times { rows.concat(banner_rows(width)) }
      rows << "" if @visual_banner_count.positive? && @transcript_buffer.empty?
      rows.concat(transcript_text_display_rows(width))
      @transcript_display_rows_cache_width = width
      @transcript_display_rows_cache = rows
    end

    def transcript_text_display_rows(width)
      @transcript_buffer.split(/\r\n|\r|\n/, -1).flat_map do |line|
        chunks = ANSI.wrap_visible(line, width)
        chunks.empty? ? [""] : chunks
      end
    end

    def reset_stream_position_from_transcript_locked(width = screen_width)
      rows = transcript_display_rows(width)
      last_length = rows.empty? ? 0 : ANSI.strip(rows.last).length
      if last_length >= width
        @stream_col = 0
        @stream_pending_wrap = true
      else
        @stream_col = last_length
        @stream_pending_wrap = false
      end
    end

    def move_to_transcript_cursor_locked(width: screen_width, height: screen_height)
      if @stream_pending_wrap
        move_to_screen(transcript_bottom_row(height), width)
      else
        move_to_screen(transcript_bottom_row(height), [@stream_col + 1, width].min)
      end
    end

    def advance_pending_stream_wrap_locked(output_text, width: screen_width, height: screen_height)
      return unless @stream_pending_wrap
      return if output_text.empty? || output_text.start_with?("\r", "\n")

      move_to_screen(transcript_bottom_row(height), width)
      @output_io.print("\r\n")
      @stream_col = 0
      @stream_pending_wrap = false
    end

    def composer_layout(width, height = screen_height)
      return compact_composer_layout(width) if height < 4
      return question_composer_layout(width, height) if @question_state

      content_width = [width - 4, 1].max
      input_layout_rows, input_cursor_row, input_cursor_col = input_layout(content_width)
      attachment_rows = attachment_badge_rows(content_width)
      overlay_rows = active_overlay_rows(width, height: height)
      footer_text = footer_text()
      max_input_rows = max_visible_input_rows(attachment_rows.length, overlay_rows.length, footer_text.empty? ? 0 : 1, height: height)
      visible_start = [[input_cursor_row - max_input_rows + 1, 0].max, [input_layout_rows.length - max_input_rows, 0].max].min
      visible_rows = input_layout_rows[visible_start, max_input_rows] || [""]
      rows = overlay_rows + [top_border(width)]
      rows.concat(attachment_rows)
      rows.concat(visible_rows.map { |row| box_content_row(row, content_width) })
      rows << footer_row(content_width, footer_text) unless footer_text.empty?
      rows << bottom_border(width)
      cursor_row = overlay_rows.length + 1 + attachment_rows.length + input_cursor_row - visible_start
      cursor_col = 2 + [input_cursor_col, content_width - 1].min
      [rows, cursor_row, cursor_col]
    end

    def question_composer_layout(width, height = screen_height)
      content_width = [width - 4, 1].max
      overlay_rows = active_overlay_rows(width, height: height)
      rows = overlay_rows + [top_border(width), box_content_row("", content_width), bottom_border(width)]
      return [rows, question_custom_cursor_row, question_custom_cursor_col(width)] if selected_question_choice&.fetch(:custom, false)

      [rows, overlay_rows.length + 1, 2]
    end

    def active_overlay_rows(width, height: screen_height)
      return question_overlay_rows(width) if @question_state
      return selection_overlay_rows(width, height: height) if @select_state

      slash_overlay_rows(width, height: height)
    end

    def banner_rows(width)
      @banner.rows(width)
    end

    def banner_logo_rows
      @banner.logo_rows(screen_width)
    end

    def question_overlay_rows(width)
      title = "Question #{@question_state[:index]}/#{@question_state[:total]} · #{@question_state[:header]}"
      lines = [
        overlay_text_line(@question_state[:question].to_s, :bold),
        overlay_text_line("↑/↓ select · Enter choose · Esc cancel", :muted),
        overlay_blank_line
      ]
      question_choices.each_with_index do |choice, index|
        selected = index == question_selection_index
        lines << overlay_choice_line(choice_text(choice, selected: selected), selected: selected)
      end
      overlay_card_rows(title, lines, width)
    end

    def slash_overlay_rows(width, height: screen_height)
      return [] unless slash_overlay_visible?

      visible = visible_slash_overlay_matches(slash_overlay_matches, height: height)
      start_index = visible[:start]
      lines = visible[:commands].each_with_index.map do |command, offset|
        index = start_index + offset
        hint = command[:argument_hint].empty? ? "" : " #{command[:argument_hint]}"
        description = command[:description].empty? ? "" : " — #{command[:description]}"
        overlay_choice_line("/#{command[:name]}#{hint}#{description}", selected: index == @slash_selection_index)
      end
      overlay_card_rows("Slash commands", lines, width)
    end

    def visible_slash_overlay_matches(matches, height: screen_height)
      max_rows = [[height - 7, 1].max, 8].min
      start = [[@slash_selection_index - max_rows + 1, 0].max, [matches.length - max_rows, 0].max].min
      { start: start, commands: matches[start, max_rows] || [] }
    end

    def selection_overlay_rows(width, height: screen_height)
      matches = selection_matches
      lines = [overlay_text_line("↑/↓ select · Enter open · Esc cancel", :muted), overlay_blank_line]
      if matches.empty?
        if @select_state && @select_state[:custom] && !@input.strip.empty?
          lines << overlay_choice_line("Use custom: #{@input.strip}", selected: true)
        else
          lines << overlay_text_line("No matches", :muted)
        end
        return overlay_card_rows(selection_overlay_title, lines, width)
      end

      visible = visible_selection_matches(matches, height: height)
      start_index = visible[:start]
      visible[:choices].each_with_index do |choice, offset|
        index = start_index + offset
        lines << overlay_choice_line(choice, selected: index == selection_index)
      end
      overlay_card_rows(selection_overlay_title, lines, width)
    end

    def selection_overlay_title
      title = @select_state && @select_state[:title].to_s
      title && !title.empty? ? title : "Sessions"
    end

    def visible_selection_matches(matches, height: screen_height)
      max_rows = [[height - 7, 1].max, 8].min
      start = [[selection_index - max_rows + 1, 0].max, [matches.length - max_rows, 0].max].min
      { start: start, choices: matches[start, max_rows] || [] }
    end

    def question_custom_cursor_row
      4 + question_choices.index { |choice| choice[:custom] }.to_i
    end

    def question_custom_cursor_col(width)
      card_width = overlay_card_width(width)
      left_padding = overlay_left_padding(width, card_width)
      custom_prefix = selected_question_choice&.fetch(:custom, false) || !@input.empty? ? "Type something: " : "Type something."
      visible_before_cursor = display_question_input(@input[0...@cursor])
      [[left_padding + 2 + 2 + custom_prefix.length + visible_before_cursor.length, width - 1].min, 0].max
    end

    def choice_text(choice, selected: false)
      if choice[:custom]
        if selected || !@input.empty?
          "Type something: #{display_question_input(@input)}"
        else
          "Type something."
        end
      else
        description = choice[:description].empty? ? "" : " — #{choice[:description]}"
        "#{choice[:label]}#{description}"
      end
    end

    def display_question_input(value)
      value.to_s.gsub(/\s+/, " ").strip
    end

    def overlay_card_rows(title, content_rows, width)
      card_width = overlay_card_width(width)
      inner_width = [card_width - 4, 1].max
      rows = [overlay_top_border(title, card_width)]
      rows.concat(content_rows.map { |row| overlay_content_row(row, inner_width) })
      rows << overlay_bottom_border(card_width)
      rows.map { |row| align_overlay_row(row, width) }
    end

    def overlay_card_width(width)
      return width if width < 32
      return width if @overlay_settings["width"] == "maximum"

      [[width - 4, 32].max, 96].min
    end

    def overlay_top_border(title, card_width)
      title = visible_truncate(title.to_s, [card_width - 4, 1].max)
      plain_length = ANSI.strip(title).length
      colored("╭", :primary_green) + " #{colored(title, :bright_accent_green, :bold)} " + colored("─" * [card_width - plain_length - 4, 0].max, :primary_green) + colored("╮", :primary_green)
    end

    def overlay_bottom_border(card_width)
      colored("╰#{"─" * [card_width - 2, 0].max}╯", :primary_green)
    end

    def overlay_content_row(row, inner_width)
      text = visible_truncate(row[:text], inner_width)
      text = colored(text, :bright_accent_green, :bold) if row[:selected]
      colored("│", :primary_green) + " " + visible_ljust(text, inner_width) + " " + colored("│", :primary_green)
    end

    def overlay_text_line(text, style = nil)
      rendered = case style
                 when :bold
                   colored(text.to_s, :bold)
                 when :muted
                   colored(text.to_s, :gray)
                 else
                   text.to_s
                 end
      { text: rendered }
    end

    def overlay_blank_line
      { text: "" }
    end

    def overlay_choice_line(text, selected: false)
      { text: "#{selected ? "›" : " "} #{text}", selected: selected }
    end

    def align_overlay_row(row, width)
      plain_length = ANSI.strip(row).length
      padding = [width - plain_length, 0].max
      left = overlay_left_padding(width, plain_length)
      right = padding - left
      (" " * left) + row + (" " * right)
    end

    def overlay_left_padding(width, row_width)
      padding = [width - row_width, 0].max
      case @overlay_settings["alignment"]
      when "left"
        0
      when "right"
        padding
      else
        padding / 2
      end
    end

    def normalize_overlay_settings(settings)
      values = { "alignment" => "center", "width" => "capped" }
      source = settings.is_a?(Hash) ? settings : {}
      alignment = (source[:alignment] || source["alignment"]).to_s
      width = (source[:width] || source["width"]).to_s
      values["alignment"] = alignment if %w[left center right].include?(alignment)
      values["width"] = width if %w[capped maximum].include?(width)
      values
    end

    def visible_ljust(text, width)
      text.to_s + (" " * [width - ANSI.strip(text.to_s).length, 0].max)
    end

    def visible_truncate(text, width)
      plain = ANSI.strip(text.to_s)
      return text.to_s if plain.length <= width

      plain[0, width]
    end

    def compact_composer_layout(width)
      cursor_line, cursor_col = cursor_logical_position
      prefix = "#{@prompt_label} "
      line = input_lines[cursor_line] || ""
      input_width = [width - prefix.length, 1].max
      visible_start = [[cursor_col - input_width + 1, 0].max, [line.length - input_width, 0].max].min
      visible = line[visible_start, input_width].to_s
      row = "#{prefix}#{visible}"[0, width].to_s.ljust(width)
      [[row], 0, [prefix.length + cursor_col - visible_start, width - 1].min]
    end

    def input_layout(content_width)
      cursor_line, cursor_col = cursor_logical_position
      rows = []
      cursor_row = 0
      rendered_row_offset = 0

      input_lines.each_with_index do |line, index|
        prefix = input_prefix(index)
        continuation_prefix = " " * prefix.length
        available = [content_width - prefix.length, 1].max
        chunks = line.scan(/.{1,#{available}}/m)
        chunks = [""] if chunks.empty?
        if index == cursor_line && cursor_col == line.length && line.length.positive? && (line.length % available).zero?
          chunks << ""
        end

        if index == cursor_line
          cursor_row = rendered_row_offset + (cursor_col / available)
        end

        chunks.each_with_index do |chunk, chunk_index|
          rows << "#{chunk_index.zero? ? prefix : continuation_prefix}#{chunk}"
        end
        rendered_row_offset += chunks.length
      end

      prefix = input_prefix(cursor_line)
      available = [content_width - prefix.length, 1].max
      cursor_col_in_row = prefix.length + (cursor_col % available)
      [rows, cursor_row, cursor_col_in_row]
    end

    def top_border(width)
      title = composer_title
      status = composer_status_text
      if status
        gap = width - 2 - ANSI.strip(title).length - ANSI.strip(status).length
        if gap >= 0
          return colored("╭", :primary_green) + title + colored("─" * gap, :primary_green) + status + colored("╮", :primary_green)
        end
      end
      plain_title = ANSI.strip(title)
      "#{colored("╭", :primary_green)}#{title}#{colored("─" * [width - plain_title.length - 2, 0].max, :primary_green)}#{colored("╮", :primary_green)}"
    end

    def composer_title
      label = @prompt_label.delete_suffix(">")
      if @busy && @queued_count.positive?
        status_composer_text(busy_title("#{label} · #{@queued_count} queued"))
      elsif @busy && @steered_count.to_i.positive?
        status_composer_text(busy_title("#{label} · #{spinner_frame} steering"))
      elsif @busy
        status_composer_text(busy_title("#{label} · #{spinner_frame} #{@busy_activity}"))
      else
        status_composer_text(label)
      end
    end

    def busy_title(text)
      @busy_help ? "#{text} · #{BUSY_HELP_TEXT}" : text
    end

    def composer_status_text
      text = @composer_status&.call.to_s
      return nil if text.empty?

      status_composer_text(text)
    end

    def status_composer_text(text)
      " #{text} "
    end

    def bottom_border(width)
      colored("╰#{"─" * [width - 2, 0].max}╯", :primary_green)
    end

    def box_content_row(row, content_width)
      "#{colored("│", :primary_green)} #{row[0, content_width].to_s.ljust(content_width)} #{colored("│", :primary_green)}"
    end

    def footer_row(content_width, text = footer_text)
      return nil if text.empty?

      box_content_row(visible_truncate(text, content_width), content_width)
    end

    def footer_text
      return "" unless @footer

      @footer.call.to_s.gsub(/\s+/, " ").strip
    rescue StandardError
      ""
    end

    def attachment_badge_rows(content_width)
      attachment_badge_texts.map { |text| box_content_row(visible_truncate(text, content_width), content_width) }
    end

    def attachment_badge_texts
      return [] unless @attachment_badges

      Array(@attachment_badges.call(@input, @attachments)).map(&:to_s).reject(&:empty?)
    rescue ArgumentError
      Array(@attachment_badges.call(@input)).map(&:to_s).reject(&:empty?)
    rescue StandardError
      []
    end

    def max_visible_input_rows(attachment_count = 0, overlay_count = active_overlay_rows(screen_width).length, footer_count = footer_text.to_s.empty? ? 0 : 1, height: screen_height)
      input_cap = [COMPOSER_MAX_INPUT_ROWS - attachment_count, 1].max
      [[input_cap, height - 3 - overlay_count - footer_count - attachment_count].min, 1].max
    end

    def composer_top_row(height = screen_height)
      [height - @reserved_rows + 1, 1].max
    end

    def transcript_bottom_row(height = screen_height)
      [height - @reserved_rows, 1].max
    end

    def move_to_screen(row, col)
      @output_io.print("\e[#{row};#{col}H")
    end

    def input_lines
      lines = @input.split("\n", -1)
      lines.empty? ? [""] : lines
    end

    def input_prefix(_index)
      ""
    end

    def cursor_logical_position
      before_cursor = @input[0...@cursor]
      [before_cursor.count("\n"), (before_cursor.split("\n", -1).last || "").length]
    end

    def update_stream_position(text, width: screen_width)
      ANSI.strip(text).each_char do |char|
        case char
        when "\n", "\r"
          @stream_col = 0
          @stream_pending_wrap = false
        else
          @stream_pending_wrap = false
          @stream_col += 1
          if @stream_col >= width
            @stream_col = 0
            @stream_pending_wrap = true
          end
        end
      end
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

    def screen_size
      [screen_width, screen_height]
    end

    def screen_width
      [TTY::Screen.width, 1].max
    end

    def screen_height
      [TTY::Screen.height, 2].max
    end
  end
end
