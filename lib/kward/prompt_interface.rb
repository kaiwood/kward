require "tty-cursor"
require "tty-reader"
require "tty-screen"

module Kward
  class PromptInterface
    HELP_TEXT = "Enter sends • Shift+Enter inserts newline • Ctrl+D exits empty prompt • /exit quits".freeze
    KEYBOARD_PROTOCOL_ENABLE = "\e[>1u".freeze
    KEYBOARD_PROTOCOL_RESTORE = "\e[<u".freeze
    SHIFT_ENTER_SEQUENCES = ["\e[13;2u", "\e[13;2~", "\e[27;2;13~", "\e\r", "\e\n"].freeze
    EXIT_INPUT = :exit_input

    def initialize(input: $stdin, output: $stdout)
      @input_io = input
      @output_io = output
      @reader = TTY::Reader.new(input: input, output: output, interrupt: :error)
      @input = ""
      @cursor = 0
      @started = false
      @asking = false
      @prompt_label = "You>"
      @stream_block = nil
      @rendered_rows = 0
      @cursor_rendered_row = 0
      @pending_keys = []
    end

    def start
      return if @started

      @started = true
      @asking = true
      @output_io.print(KEYBOARD_PROTOCOL_ENABLE)
      @output_io.puts HELP_TEXT
      render
    end

    def close
      return unless @started

      clear_prompt
      @output_io.print(KEYBOARD_PROTOCOL_RESTORE)
      @output_io.puts
      @output_io.flush
      @started = false
    end

    def say(message)
      clear_prompt
      @output_io.print(message.to_s)
      @output_io.print("\n") unless message.to_s.end_with?("\n")
      @stream_block = nil
      render
    end

    def ask(message = "You>")
      start
      @prompt_label = message.to_s
      @input = ""
      @cursor = 0
      @pending_keys.clear
      @asking = true
      render

      loop do
        key = read_key
        result = handle_key(key)
        return result if result.is_a?(String)
        return nil if result == EXIT_INPUT

        render
      end
    end

    def yes?(message, default: false)
      answer = ask("#{message} #{default ? "[Y/n]" : "[y/N]"}")
      return default if answer.nil?

      answer = answer.strip.downcase
      return default if answer.empty?

      answer.start_with?("y")
    end

    def start_stream_block(label)
      return if @stream_block == label

      clear_prompt
      @output_io.puts if @stream_block
      @output_io.puts "#{label}>"
      @stream_block = label
      @output_io.flush
    end

    def write_delta(delta)
      clear_prompt
      @output_io.print(delta.to_s)
      @output_io.flush
    end

    def finish_stream_block
      clear_prompt
      @output_io.puts if @stream_block
      @stream_block = nil
      render
    end

    private

    def submit_input
      value = @input
      clear_prompt
      @output_io.flush
      @input = ""
      @cursor = 0
      @asking = false
      @rendered_rows = 0
      @cursor_rendered_row = 0
      value
    end

    def exit_input
      clear_prompt
      @output_io.flush
      @input = ""
      @cursor = 0
      @asking = false
      @rendered_rows = 0
      @cursor_rendered_row = 0
      EXIT_INPUT
    end

    def read_key
      @pending_keys.shift || @reader.read_keypress(echo: false, raw: true)
    end

    def handle_key(key)
      return submit_input if key.nil?
      csi_result = handle_csi_u_key(key)
      return csi_result unless csi_result == false
      return if handle_shift_enter_key(key)

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
      handle_shift_enter_key("\e#{read_pending_escape_sequence}")
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
    end

    def insert_key(key)
      return unless key.is_a?(String) && key.length == 1 && key.match?(/[[:print:]]/)

      insert_string(key)
    end

    def insert_string(string)
      @input = @input[0...@cursor] + string + @input[@cursor..]
      @cursor += string.length
    end

    def delete_before_cursor
      return unless @cursor.positive?

      @input = @input[0...(@cursor - 1)] + @input[@cursor..]
      @cursor -= 1
    end

    def delete_at_cursor
      return unless @cursor < @input.length

      @input = @input[0...@cursor] + @input[(@cursor + 1)..]
    end

    def render
      return unless @started && @asking

      clear_prompt
      rows = input_rows(screen_width)
      @output_io.print(rows.join("\n"))
      @rendered_rows = rows.length
      @cursor_rendered_row = @rendered_rows - 1
      move_cursor
      @output_io.flush
    end

    def clear_prompt
      return unless @rendered_rows.positive?

      @output_io.print(TTY::Cursor.up(@cursor_rendered_row)) if @cursor_rendered_row.positive?
      @output_io.print("\r")
      @output_io.print(TTY::Cursor.clear_screen_down)
      @rendered_rows = 0
      @cursor_rendered_row = 0
    end

    def move_cursor_to_end
      return unless @rendered_rows.positive?

      rows = input_rows(screen_width)
      row = rows.length - 1
      col = rows.last.to_s.length
      move_to_rendered_position(row, col)
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

    def input_prefix(index)
      "#{index.zero? ? @prompt_label : " " * @prompt_label.length} "
    end

    def input_text_width(width, prefix)
      [width - prefix.length - 1, 1].max
    end

    def cursor_logical_position
      before_cursor = @input[0...@cursor]
      [before_cursor.count("\n"), (before_cursor.split("\n", -1).last || "").length]
    end

    def screen_width
      [TTY::Screen.width, 1].max
    end
  end
end
