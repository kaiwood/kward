require "tty-cursor"
require "tty-reader"
require "tty-screen"

module Kward
  class PromptInterface
    HELP_TEXT = "Enter sends • Shift+Enter inserts newline • /exit quits".freeze

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
    end

    def start
      return if @started

      @started = true
      @asking = true
      @output_io.puts HELP_TEXT
      render
    end

    def close
      return unless @started

      clear_prompt
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
      @asking = true
      render

      loop do
        key = @reader.read_keypress(echo: false, raw: true)
        key_name = @reader.console.keys[key]
        case key_name
        when :return, :enter
          return submit_input
        when :backspace
          delete_before_cursor
        when :delete
          delete_at_cursor
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
            return submit_input
          when "\b", "\x7F"
            delete_before_cursor
          when "\e"
            handle_escape_sequence
          else
            insert_key(key)
          end
        end
        render
      end
    end

    def yes?(message, default: false)
      answer = ask("#{message} #{default ? "[Y/n]" : "[y/N]"}").strip.downcase
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
      move_cursor_to_end
      @output_io.puts
      @output_io.flush
      @input = ""
      @cursor = 0
      @asking = false
      @rendered_rows = 0
      @cursor_rendered_row = 0
      value
    end

    def handle_escape_sequence
      sequence = read_pending_escape_sequence
      insert_string("\n") if shift_enter_sequence?(sequence)
    end

    def read_pending_escape_sequence
      sequence = ""
      while (char = @reader.read_keypress(echo: false, raw: true, nonblock: true))
        sequence << char.to_s
      end
      sequence
    end

    def shift_enter_sequence?(sequence)
      ["[13;2u", "[27;2;13~"].include?(sequence)
    end

    def insert_key(key)
      return unless key.is_a?(String) && key.match?(/[[:print:]]/)

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
