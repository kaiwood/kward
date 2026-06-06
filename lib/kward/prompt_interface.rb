require "thread"
require "tty-cursor"
require "tty-reader"
require "tty-screen"
require_relative "ansi"
require_relative "pixel_logo"
require_relative "resources/avatar_kward_logo"

module Kward
  class PromptInterface
    HELP_TEXT = "Enter sends • Shift+Enter inserts newline • ↑/↓ history • Ctrl+D exits empty prompt".freeze
    BUSY_HELP_TEXT = "Streaming • type next prompt • Enter queues • Shift+Enter inserts newline".freeze
    SPINNER_FRAMES = %w[⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏].freeze
    SPINNER_INTERVAL = 0.1
    FOOTER_REFRESH_INTERVAL = 1.0
    COMPOSER_MAX_INPUT_ROWS = 6
    TRANSCRIPT_BUFFER_LIMIT = 200_000
    BANNER_LOGO_WIDTH = 32
    BANNER_LOGO_PIXEL_HEIGHT = 32
    BANNER_MIN_LOGO_HEIGHT = 4
    BANNER_LOGO_PIXELS = Kward::Resources::AvatarKwardLogo::PIXELS
    BANNER_MESSAGE = "State your business.".freeze
    KEYBOARD_PROTOCOL_ENABLE = "\e[>1u".freeze
    KEYBOARD_PROTOCOL_RESTORE = "\e[<u".freeze
    BRACKETED_PASTE_ENABLE = "\e[?2004h".freeze
    BRACKETED_PASTE_RESTORE = "\e[?2004l".freeze
    BRACKETED_PASTE_START = "\e[200~".freeze
    BRACKETED_PASTE_END = "\e[201~".freeze
    CURSOR_SHOW = "\e[?25h".freeze
    CURSOR_HIDE = "\e[?25l".freeze
    SHIFT_ENTER_SEQUENCES = ["\e[13;2u", "\e[13;2~", "\e[27;2;13~", "\e\r", "\e\n"].freeze
    EXIT_INPUT = :exit_input
    SELECT_CANCEL = :select_cancel

    def initialize(input: $stdin, output: $stdout, slash_commands: [], overlay_settings: nil, footer: nil, composer_status: nil, banner_pixels: nil, banner_message: nil)
      @input_io = input
      @output_io = output
      @reader = TTY::Reader.new(input: input, output: output, interrupt: :error)
      @mutex = Mutex.new
      @input = ""
      @cursor = 0
      @started = false
      @asking = false
      @busy = false
      @queued_count = 0
      @spinner_frame_index = 0
      @last_spinner_tick = monotonic_now
      @last_footer_refresh = monotonic_now
      @prompt_label = "You>"
      @stream_block = nil
      @rendered_rows = 0
      @cursor_rendered_row = 0
      @prompt_gap_rows = 0
      @stream_col = 0
      @stream_pending_wrap = false
      @transcript_buffer = +""
      @pending_keys = []
      @history = []
      @history_index = nil
      @history_draft = nil
      @slash_commands = normalize_slash_commands(slash_commands)
      @slash_selection_index = 0
      @select_state = nil
      @question_state = nil
      @last_width = screen_width
      @last_height = screen_height
      @reserved_rows = 0
      @color_enabled = ANSI.enabled?(output)
      @cursor_visible = true
      @overlay_settings = normalize_overlay_settings(overlay_settings)
      @footer = footer
      @composer_status = composer_status
      @banner_message = banner_message.to_s
      @banner_logo_pixels = banner_pixels
      @banner_logo_cache = {}
    end

    def start
      @mutex.synchronize do
        return if @started

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
      end
    end

    def say(message)
      @mutex.synchronize do
        clear_prompt_for_output_locked
        text = message.to_s
        write_transcript_text_locked(text)
        write_transcript_text_locked("\n") unless text.end_with?("\n")
        @stream_block = nil
        render_prompt_after_output_locked
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
          @input = ""
          @cursor = 0
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

    def select(message, choices, title: "Sessions", custom: false)
      return nil if choices.empty? && !custom

      start
      @mutex.synchronize do
        @prompt_label = message.to_s
        @input = ""
        @cursor = 0
        @pending_keys.clear
        @asking = true
        @busy = false
        @queued_count = 0
        @select_state = { choices: choices.map(&:to_s), selection_index: 0, title: title.to_s, custom: custom }
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
      @mutex.synchronize { !@question_state.nil? }
    end

    def update_overlay_settings(settings)
      @mutex.synchronize do
        @overlay_settings = normalize_overlay_settings(settings)
        render_prompt_locked if @started && @asking
      end
    end

    def begin_busy_input(message = "You>")
      start
      @mutex.synchronize do
        @prompt_label = message.to_s
        @input = ""
        @cursor = 0
        @pending_keys.clear
        @asking = true
        @busy = true
        @queued_count = 0
        reset_spinner_locked
        reset_history_navigation
        render_prompt_locked
      end
    end

    def set_queued_count(count)
      @mutex.synchronize do
        @queued_count = count.to_i
        render_prompt_locked if @asking
      end
    end

    def finish_busy_input
      @mutex.synchronize do
        @busy = false
        @queued_count = 0
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
        render_prompt_locked unless result == EXIT_INPUT
        result == EXIT_INPUT ? EXIT_INPUT : result
      end
    end

    def start_stream_block(label)
      @mutex.synchronize do
        if @stream_block != label
          prepare_transcript_output_locked
          if @stream_block
            write_transcript_text_locked("\n")
          end
          write_transcript_text_locked("#{colored("#{label}>", label_color(label), :bold)}\n")
          @stream_block = label
        end
        restore_composer_cursor_locked
        @output_io.flush
      end
    end

    def write_delta(delta)
      @mutex.synchronize do
        prepare_transcript_output_locked
        write_transcript_text_locked(delta.to_s)
        restore_composer_cursor_locked
        @output_io.flush
      end
    end

    def finish_stream_block
      @mutex.synchronize do
        prepare_transcript_output_locked
        if @stream_block
          write_transcript_text_locked("\n")
        end
        @stream_block = nil
        restore_composer_cursor_locked
        @output_io.flush
      end
    end

    def redraw
      @mutex.synchronize do
        redraw_screen_locked
        @output_io.flush
      end
    end

    def clear_transcript
      @mutex.synchronize do
        @transcript_buffer = +""
        @stream_block = nil
        @stream_col = 0
        @stream_pending_wrap = false
        redraw_screen_locked
        @output_io.flush
      end
    end

    private

    def write_transcript_text_locked(text)
      append_transcript_buffer(text.to_s)
      output_text = terminal_newlines(text.to_s)
      advance_pending_stream_wrap_locked(output_text)
      @output_io.print(output_text)
      update_stream_position(output_text)
    end

    def append_transcript_buffer(text)
      @transcript_buffer << ANSI.strip(text)
      return if @transcript_buffer.length <= TRANSCRIPT_BUFFER_LIMIT

      @transcript_buffer = @transcript_buffer[-TRANSCRIPT_BUFFER_LIMIT, TRANSCRIPT_BUFFER_LIMIT]
    end

    def terminal_newlines(text)
      text.gsub(/\r\n|\r|\n/, "\r\n")
    end

    def reset_spinner_locked
      @spinner_frame_index = 0
      @last_spinner_tick = monotonic_now
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
      value = @input
      add_history(value)
      if @busy
        clear_prompt_for_output_locked
        @input = ""
        @cursor = 0
        reset_history_navigation
        @asking = true
        render_prompt_after_output_locked
      else
        clear_prompt_locked
        @input = ""
        @cursor = 0
        @asking = false
        @rendered_rows = 0
        @cursor_rendered_row = 0
      end
      @output_io.flush
      value
    end

    def exit_input
      if @busy
        clear_prompt_for_output_locked
        @input = ""
        @cursor = 0
        @asking = true
        render_prompt_after_output_locked
      else
        clear_prompt_locked
        @input = ""
        @cursor = 0
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

      key_name = @reader.console.keys[key]
      case key_name
      when :return, :enter
        submit_input
      when :backspace
        delete_before_cursor
      when :delete
        delete_at_cursor
      when :ctrl_d
        exit_input if @input.empty?
      when :left
        @cursor -= 1 if @cursor.positive?
      when :right
        @cursor += 1 if @cursor < @input.length
      when :home
        @cursor = 0
      when :end
        @cursor = @input.length
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
          exit_input if @input.empty?
        when "\e"
          handle_escape_sequence
        else
          insert_key(key)
        end
      end
    end

    def handle_escape_sequence
      sequence = "\e#{read_pending_escape_sequence}"
      return true if handle_shift_enter_key(sequence)

      key_name = @reader.console.keys[sequence]
      case key_name
      when :up
        slash_overlay_visible? ? select_previous_slash_command : recall_previous_history
      when :down
        slash_overlay_visible? ? select_next_slash_command : recall_next_history
      when :left
        @cursor -= 1 if @cursor.positive?
      when :right
        @cursor += 1 if @cursor < @input.length
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
      insert_string(normalize_paste(content || ""))
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
      when 8, 127
        delete_before_cursor
        nil
      when 4
        exit_input if @input.empty?
      else
        ctrl_d_csi_u?(code, modifier) ? (exit_input if @input.empty?) : false
      end
    end

    def ctrl_d_csi_u?(code, modifier)
      [68, 100].include?(code) && ((modifier - 1) & 4).positive?
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
      keys.match(/\A\e\[[0-9;:]*[A-Za-z~]/)&.[](0) || keys[0, 1]
    end

    def shift_enter_sequence_for(key)
      return nil unless key.is_a?(String)

      SHIFT_ENTER_SEQUENCES.find { |sequence| key.start_with?(sequence) }
    end

    def read_pending_escape_sequence
      sequence = ""
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
      @input = @input[0...@cursor] + string + @input[@cursor..]
      @cursor += string.length
    end

    def delete_before_cursor
      return unless @cursor.positive?

      reset_slash_selection
      reset_history_navigation
      @input = @input[0...(@cursor - 1)] + @input[@cursor..]
      @cursor -= 1
    end

    def delete_at_cursor
      return unless @cursor < @input.length

      reset_slash_selection
      reset_history_navigation
      @input = @input[0...@cursor] + @input[(@cursor + 1)..]
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

    def reset_history_navigation
      @history_index = nil
      @history_draft = nil
    end

    def reset_slash_selection
      @slash_selection_index = 0
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
      @input.match?(%r{\A/[^\s/]*\z}) && !slash_overlay_matches.empty?
    end

    def slash_overlay_matches
      prefix = @input.delete_prefix("/").downcase
      @slash_commands.select { |command| command[:name].downcase.start_with?(prefix) }.first(8)
    end

    def selected_slash_command
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
      rows, cursor_row, cursor_col = composer_layout(screen_width)
      ensure_scroll_region_locked(rows.length)
      render_composer_rows_locked(rows)
      @rendered_rows = rows.length
      @cursor_rendered_row = cursor_row
      @last_width = screen_width
      @last_height = screen_height
      move_to_screen(composer_top_row + cursor_row, cursor_col + 1)
      render_cursor_visibility_locked
      @output_io.flush
    end

    def render_prompt_after_output_locked
      render_prompt_locked
    end

    def clear_prompt_locked
      handle_resize_locked
      clear_composer_region_locked
      @rendered_rows = 0
      @cursor_rendered_row = 0
    end

    def clear_prompt_for_output_locked
      handle_resize_locked
      reserve_composer_region_locked if @started && @asking
      clear_composer_region_locked
      @rendered_rows = 0
      @cursor_rendered_row = 0
      @prompt_gap_rows = 0
      move_to_transcript_cursor_locked if @started
    end

    def prepare_transcript_output_locked
      handle_resize_locked
      reserve_composer_region_locked
      move_to_transcript_cursor_locked
    end

    def restore_composer_cursor_locked
      return unless @started && @asking

      _rows, cursor_row, cursor_col = composer_layout(screen_width)
      move_to_screen(composer_top_row + cursor_row, cursor_col + 1)
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

    def reserve_composer_region_locked
      rows, = composer_layout(screen_width)
      ensure_scroll_region_locked(rows.length)
    end

    def ensure_scroll_region_locked(row_count)
      new_reserved_rows = [[row_count, 1].max, [screen_height - 1, 1].max].min
      return if @reserved_rows == new_reserved_rows && @last_height == screen_height

      rows_to_clear = [@reserved_rows, new_reserved_rows].max
      @reserved_rows = new_reserved_rows
      @output_io.print("\e[1;#{transcript_bottom_row}r")
      clear_composer_region_locked(rows_to_clear)
    end

    def handle_resize_locked
      current_width = screen_width
      current_height = screen_height
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
      redraw_screen_locked
      true
    end

    def restore_scroll_region_locked
      @output_io.print("\e[r")
      @reserved_rows = 0
    end

    def render_composer_rows_locked(rows)
      clear_composer_region_locked
      top = composer_top_row
      rows.each_with_index do |row, index|
        move_to_screen(top + index, 1)
        @output_io.print(row) unless row.empty?
      end
    end

    def clear_composer_region_locked(rows_to_clear = nil)
      rows_to_clear ||= [@reserved_rows, @rendered_rows].max
      clear_bottom_rows_locked(screen_height, rows_to_clear)
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

      bottom = [height, screen_height].min
      top = [bottom - rows_to_clear + 1, 1].max
      clear_screen_rows_locked(top, bottom)
    end

    def clear_screen_rows_locked(top, bottom)
      top.upto(bottom) do |row|
        move_to_screen(row, 1)
        @output_io.print(TTY::Cursor.clear_line)
      end
    end

    def redraw_screen_locked
      return unless @started

      restore_scroll_region_locked
      @output_io.print(TTY::Cursor.clear_screen)
      move_to_screen(1, 1)
      @reserved_rows = 0
      rows, cursor_row, cursor_col = composer_layout(screen_width)
      ensure_scroll_region_locked(rows.length)
      redraw_transcript_locked
      render_composer_rows_locked(rows) if @asking
      @rendered_rows = @asking ? rows.length : 0
      @cursor_rendered_row = @asking ? cursor_row : 0
      @last_width = screen_width
      @last_height = screen_height
      reset_stream_position_from_transcript_locked
      if @asking
        move_to_screen(composer_top_row + cursor_row, cursor_col + 1)
        render_cursor_visibility_locked
      end
    end

    def redraw_transcript_locked
      visible_text = transcript_viewport_text(transcript_bottom_row, screen_width)
      return if visible_text.empty?

      move_to_screen(1, 1)
      @output_io.print(terminal_newlines(visible_text))
    end

    def transcript_viewport_text(row_count, width)
      return "" unless row_count.positive?

      transcript_display_rows(width).last(row_count).join("\n")
    end

    def transcript_display_rows(width)
      line_width = [width - 1, 1].max
      @transcript_buffer.split(/\r\n|\r|\n/, -1).flat_map do |line|
        chunks = line.scan(/.{1,#{line_width}}/m)
        chunks.empty? ? [""] : chunks
      end
    end

    def reset_stream_position_from_transcript_locked
      rows = transcript_display_rows(screen_width)
      @stream_col = rows.empty? ? 0 : rows.last.length
      @stream_pending_wrap = false
    end

    def move_to_transcript_cursor_locked
      if @stream_pending_wrap
        move_to_screen(transcript_bottom_row, screen_width)
      else
        move_to_screen(transcript_bottom_row, [@stream_col + 1, screen_width].min)
      end
    end

    def advance_pending_stream_wrap_locked(output_text)
      return unless @stream_pending_wrap
      return if output_text.empty? || output_text.start_with?("\r", "\n")

      move_to_screen(transcript_bottom_row, screen_width)
      @output_io.print("\r\n")
      @stream_col = 0
      @stream_pending_wrap = false
    end

    def composer_layout(width)
      return compact_composer_layout(width) if screen_height < 4
      return question_composer_layout(width) if @question_state

      content_width = [width - 4, 1].max
      input_layout_rows, input_cursor_row, input_cursor_col = input_layout(content_width)
      max_input_rows = max_visible_input_rows
      visible_start = [[input_cursor_row - max_input_rows + 1, 0].max, [input_layout_rows.length - max_input_rows, 0].max].min
      visible_rows = input_layout_rows[visible_start, max_input_rows] || [""]
      banner_rows = banner_rows(width)
      overlay_rows = active_overlay_rows(width)
      rows = banner_rows + overlay_rows + [top_border(width)]
      rows.concat(visible_rows.map { |row| box_content_row(row, content_width) })
      footer = footer_row(content_width)
      rows << footer if footer
      rows << bottom_border(width)
      cursor_row = banner_rows.length + overlay_rows.length + 1 + input_cursor_row - visible_start
      cursor_col = 2 + [input_cursor_col, content_width - 1].min
      [rows, cursor_row, cursor_col]
    end

    def question_composer_layout(width)
      content_width = [width - 4, 1].max
      banner_rows = banner_rows(width)
      overlay_rows = active_overlay_rows(width)
      rows = banner_rows + overlay_rows + [top_border(width), box_content_row("", content_width), bottom_border(width)]
      return [rows, banner_rows.length + question_custom_cursor_row, question_custom_cursor_col(width)] if selected_question_choice&.fetch(:custom, false)

      [rows, banner_rows.length + overlay_rows.length + 1, 2]
    end

    def active_overlay_rows(width)
      return question_overlay_rows(width) if @question_state
      return selection_overlay_rows(width) if @select_state

      slash_overlay_rows(width)
    end

    def banner_rows(width)
      return [] unless banner_visible?

      rows = []
      if banner_image_visible?
        rows.concat(centered_banner_image_rows(width))
      end
      rows << align_plain_row(@banner_message, width) unless @banner_message.empty?
      rows << ""
      rows
    end

    def banner_visible?
      !@banner_message.empty? || banner_image_visible?
    end

    def banner_image_visible?
      !banner_logo_rows.empty?
    end

    def centered_banner_image_rows(width)
      logo_width, = banner_logo_dimensions(width)
      padding = [[(width - logo_width) / 2, 0].max, width - 1].min
      banner_logo_rows.map { |row| (" " * padding) + row }
    end

    def banner_logo_rows
      logo_width, logo_height = banner_logo_dimensions(screen_width)
      return [] unless @banner_logo_pixels && max_banner_logo_height >= BANNER_MIN_LOGO_HEIGHT

      key = [logo_width, logo_height]
      @banner_logo_cache[key] ||= Kward::PixelLogo.half_block_rows_from_pixels(@banner_logo_pixels, width: logo_width, pixel_height: logo_height)
    end

    def banner_logo_dimensions(width)
      logo_width = [BANNER_LOGO_WIDTH, [width - 2, 1].max].min
      logo_height = [BANNER_LOGO_PIXEL_HEIGHT, max_banner_logo_height * 2].min
      [logo_width, logo_height]
    end

    def max_banner_logo_height
      message_rows = @banner_message.empty? ? 0 : 1
      blank_after_banner = 1
      minimum_composer_rows = 3
      transcript_row = 1
      reserved_rows = message_rows + blank_after_banner + minimum_composer_rows + transcript_row
      [screen_height - reserved_rows, 0].max
    end

    def align_plain_row(text, width)
      plain_length = ANSI.strip(text).length
      padding = [width - plain_length, 0].max / 2
      (" " * padding) + text.to_s
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

    def slash_overlay_rows(width)
      return [] unless slash_overlay_visible?

      visible = visible_slash_overlay_matches(slash_overlay_matches)
      start_index = visible[:start]
      lines = visible[:commands].each_with_index.map do |command, offset|
        index = start_index + offset
        hint = command[:argument_hint].empty? ? "" : " #{command[:argument_hint]}"
        description = command[:description].empty? ? "" : " — #{command[:description]}"
        overlay_choice_line("/#{command[:name]}#{hint}#{description}", selected: index == @slash_selection_index)
      end
      overlay_card_rows("Slash commands", lines, width)
    end

    def visible_slash_overlay_matches(matches)
      max_rows = [[screen_height - 7, 1].max, 8].min
      start = [[@slash_selection_index - max_rows + 1, 0].max, [matches.length - max_rows, 0].max].min
      { start: start, commands: matches[start, max_rows] || [] }
    end

    def selection_overlay_rows(width)
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

      visible = visible_selection_matches(matches)
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

    def visible_selection_matches(matches)
      max_rows = [[screen_height - 7, 1].max, 8].min
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
        status_composer_text("#{label} · #{@queued_count} queued")
      elsif @busy
        status_composer_text("#{label} · #{spinner_frame} streaming")
      else
        status_composer_text(label)
      end
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

    def footer_row(content_width)
      text = footer_text
      return nil if text.empty?

      box_content_row(visible_truncate(text, content_width), content_width)
    end

    def footer_text
      return "" unless @footer

      @footer.call.to_s.gsub(/\s+/, " ").strip
    rescue StandardError
      ""
    end

    def max_visible_input_rows
      banner_count = banner_rows(screen_width).length
      overlay_count = active_overlay_rows(screen_width).length
      footer_count = footer_text.to_s.empty? ? 0 : 1
      [[COMPOSER_MAX_INPUT_ROWS, screen_height - 3 - banner_count - overlay_count - footer_count].min, 1].max
    end

    def composer_top_row
      [screen_height - @reserved_rows + 1, 1].max
    end

    def transcript_bottom_row
      [screen_height - @reserved_rows, 1].max
    end

    def move_to_screen(row, col)
      @output_io.print("\e[#{row};#{col}H")
    end

    def input_rows(width)
      cursor_line, cursor_col = cursor_logical_position
      input_lines.each_with_index.flat_map do |line, index|
        prefix = input_prefix(index)
        continuation_prefix = " " * prefix.length
        available = input_text_width(width, prefix)
        chunks = line.scan(/.{1,#{available}}/m)
        chunks = [""] if chunks.empty?
        if index == cursor_line && cursor_col == line.length && line.length.positive? && (line.length % available).zero?
          chunks << ""
        end
        chunks.each_with_index.map do |chunk, chunk_index|
          "#{chunk_index.zero? ? prefix : continuation_prefix}#{chunk}"
        end
      end
    end

    def input_lines
      lines = @input.split("\n", -1)
      lines.empty? ? [""] : lines
    end

    def input_prefix(_index)
      ""
    end

    def input_text_width(width, prefix)
      [width - prefix.length - 1, 1].max
    end

    def cursor_logical_position
      before_cursor = @input[0...@cursor]
      [before_cursor.count("\n"), (before_cursor.split("\n", -1).last || "").length]
    end

    def update_stream_position(text)
      width = screen_width
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

    def label_color(label)
      case label
      when "Reasoning"
        :yellow
      when "Assistant"
        :green
      when "Tool"
        :magenta
      when "Tool output"
        :cyan
      else
        :blue
      end
    end

    def screen_width
      [TTY::Screen.width, 1].max
    end

    def screen_height
      [TTY::Screen.height, 2].max
    end
  end
end
