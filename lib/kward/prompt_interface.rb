require "thread"
require "tty-cursor"
require "tty-reader"
require "tty-screen"
require_relative "ansi"

module Kward
  class PromptInterface
    HELP_TEXT = "Enter sends • Shift+Enter inserts newline • ↑/↓ history • Ctrl+D exits empty prompt".freeze
    BUSY_HELP_TEXT = "Streaming • type next prompt • Enter queues • Shift+Enter inserts newline".freeze
    COMPOSER_MAX_INPUT_ROWS = 6
    TRANSCRIPT_BUFFER_LIMIT = 200_000
    KEYBOARD_PROTOCOL_ENABLE = "\e[>1u".freeze
    KEYBOARD_PROTOCOL_RESTORE = "\e[<u".freeze
    BRACKETED_PASTE_ENABLE = "\e[?2004h".freeze
    BRACKETED_PASTE_RESTORE = "\e[?2004l".freeze
    BRACKETED_PASTE_START = "\e[200~".freeze
    BRACKETED_PASTE_END = "\e[201~".freeze
    SHIFT_ENTER_SEQUENCES = ["\e[13;2u", "\e[13;2~", "\e[27;2;13~", "\e\r", "\e\n"].freeze
    EXIT_INPUT = :exit_input

    def initialize(input: $stdin, output: $stdout)
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
      @last_width = screen_width
      @last_height = screen_height
      @reserved_rows = 0
      @color_enabled = ANSI.enabled?(output)
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
            render_prompt_locked if handle_resize_locked
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
          render_prompt_locked if handle_resize_locked
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
          @output_io.flush
        end
      end
    end

    def write_delta(delta)
      @mutex.synchronize do
        prepare_transcript_output_locked
        write_transcript_text_locked(delta.to_s)
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
        @output_io.flush
      end
    end

    def redraw
      @mutex.synchronize do
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
        recall_previous_history
      when :down
        recall_next_history
      else
        case key
        when "\n", "\r"
          submit_input
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
        recall_previous_history
      when :down
        recall_next_history
      when :left
        @cursor -= 1 if @cursor.positive?
      when :right
        @cursor += 1 if @cursor < @input.length
      end
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

    def insert_key(key)
      return unless key.is_a?(String) && key.length == 1 && key.match?(/[[:print:]]/)

      insert_string(key)
    end

    def insert_string(string)
      return if string.empty?

      reset_history_navigation
      @input = @input[0...@cursor] + string + @input[@cursor..]
      @cursor += string.length
    end

    def delete_before_cursor
      return unless @cursor.positive?

      reset_history_navigation
      @input = @input[0...(@cursor - 1)] + @input[@cursor..]
      @cursor -= 1
    end

    def delete_at_cursor
      return unless @cursor < @input.length

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
      @output_io.flush
    end

    def render_prompt_after_output_locked
      render_prompt_locked
    end

    def render_prompt_rows_locked
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
      top = composer_top_row
      rows.each_with_index do |row, index|
        move_to_screen(top + index, 1)
        @output_io.print(TTY::Cursor.clear_line)
        @output_io.print(row)
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
      move_to_screen(composer_top_row + cursor_row, cursor_col + 1) if @asking
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

      content_width = [width - 4, 1].max
      input_layout_rows, input_cursor_row, input_cursor_col = input_layout(content_width)
      max_input_rows = max_visible_input_rows
      visible_start = [[input_cursor_row - max_input_rows + 1, 0].max, [input_layout_rows.length - max_input_rows, 0].max].min
      visible_rows = input_layout_rows[visible_start, max_input_rows] || [""]
      rows = [top_border(width)]
      rows.concat(visible_rows.map { |row| box_content_row(row, content_width) })
      rows << bottom_border(width)
      cursor_row = 1 + input_cursor_row - visible_start
      cursor_col = 2 + [input_cursor_col, content_width - 1].min
      [rows, cursor_row, cursor_col]
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
      plain_title = ANSI.strip(title)
      "#{colored("╭", :blue)}#{title}#{colored("─" * [width - plain_title.length - 2, 0].max, :blue)}#{colored("╮", :blue)}"
    end

    def composer_title
      label = @prompt_label.delete_suffix(">")
      if @busy && @queued_count.positive?
        " #{label} · #{@queued_count} queued "
      elsif @busy
        " #{label} · streaming "
      else
        " #{label} "
      end
    end

    def bottom_border(width)
      colored("╰#{"─" * [width - 2, 0].max}╯", :blue)
    end

    def box_content_row(row, content_width)
      "#{colored("│", :blue)} #{row[0, content_width].to_s.ljust(content_width)} #{colored("│", :blue)}"
    end

    def max_visible_input_rows
      [[COMPOSER_MAX_INPUT_ROWS, screen_height - 3].min, 1].max
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

    def move_cursor
      cursor_line, cursor_col = cursor_logical_position
      row_offset = 0
      input_lines.each_with_index do |line, index|
        prefix = input_prefix(index)
        available = input_text_width(screen_width, prefix)
        if index == cursor_line
          row = row_offset + (cursor_col / available)
          col = prefix.length + (cursor_col % available)
          move_to_rendered_position(row, col)
          return
        end
        row_offset += [(line.length.to_f / available).ceil, 1].max
      end
    rescue StandardError
      nil
    end

    def move_to_rendered_position(row, col)
      @output_io.print(TTY::Cursor.up(@cursor_rendered_row - row)) if @cursor_rendered_row > row
      @output_io.print(TTY::Cursor.down(row - @cursor_rendered_row)) if row > @cursor_rendered_row
      @output_io.print("\r")
      @output_io.print(TTY::Cursor.forward(col)) if col.positive?
      @cursor_rendered_row = row
    end

    def prompt_rows(width)
      input_rows(width)
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
