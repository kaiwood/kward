require "tty-cursor"
require "tty-reader"
require "tty-screen"

module Kward
  class PromptInterface
    HELP_TEXT = "Enter sends • Shift+Enter inserts newline • PgUp/PgDn scroll • /exit quits".freeze

    def initialize(input: $stdin, output: $stdout)
      @input_io = input
      @output_io = output
      @reader = TTY::Reader.new(input: input, output: output, interrupt: :error)
      @output_lines = []
      @stream_block = nil
      @input = ""
      @cursor = 0
      @scroll_offset = 0
      @started = false
      @prompt_label = "You>"
    end

    def start
      return if @started

      @output_io.print(TTY::Cursor.clear_screen)
      @started = true
      render
    end

    def close
      return unless @started

      @output_io.print(TTY::Cursor.move_to(0, screen_height - 1))
      @output_io.print(TTY::Cursor.clear_line)
      @output_io.puts
      @output_io.flush
      @started = false
    end

    def say(message)
      append_output(message.to_s)
      append_output("\n") unless message.to_s.end_with?("\n")
      @stream_block = nil
      render
    end

    def ask(message = "You>")
      start
      @prompt_label = message.to_s
      @input = ""
      @cursor = 0
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
        when :page_up
          scroll_output(page_size)
        when :page_down
          scroll_output(-page_size)
        when :ctrl_up
          scroll_output(1)
        when :ctrl_down
          scroll_output(-1)
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

      append_output("\n") unless @output_lines.empty? && current_output_line.empty?
      append_output("#{label}>\n")
      @stream_block = label
      render
    end

    def write_delta(delta)
      append_output(delta.to_s)
      render
    end

    def finish_stream_block
      append_output("\n") if @stream_block
      @stream_block = nil
      render
    end

    private

    def submit_input
      value = @input
      @input = ""
      @cursor = 0
      render
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

    def append_output(text)
      text.each_char do |char|
        if char == "\n"
          @output_lines << String.new
          @scroll_offset += 1 if @scroll_offset.positive?
        else
          current_output_line << char
        end
      end
      clamp_scroll_offset
    end

    def current_output_line
      @output_lines << String.new if @output_lines.empty?
      @output_lines[-1]
    end

    def render
      return unless @started

      height = screen_height
      width = screen_width
      input_lines = @input.split("\n", -1)
      input_lines = [""] if input_lines.empty?
      prompt_rows = input_lines.length + 2
      output_height = [height - prompt_rows, 0].max
      clamp_scroll_offset(output_height)

      @output_io.print(TTY::Cursor.move_to(0, 0))
      @output_io.print(TTY::Cursor.clear_screen_down)
      visible_output_lines(output_height).each_with_index do |line, row|
        draw(row, 0, line, width)
      end

      separator_row = output_height
      draw(separator_row, 0, "─" * width, width) if separator_row < height
      input_lines.each_with_index do |line, index|
        label = index.zero? ? @prompt_label : " " * @prompt_label.length
        draw(separator_row + 1 + index, 0, "#{label} #{line}", width)
      end
      draw(height - 1, 0, HELP_TEXT, width) if height.positive?
      move_cursor(separator_row + 1, width)
      @output_io.flush
    end

    def visible_output_lines(output_height)
      return [] unless output_height.positive?

      start = [@output_lines.length - output_height - @scroll_offset, 0].max
      @output_lines[start, output_height] || []
    end

    def scroll_output(lines)
      @scroll_offset += lines
      clamp_scroll_offset
    end

    def page_size
      [screen_height - @input.split("\n", -1).length - 2, 1].max
    end

    def clamp_scroll_offset(output_height = nil)
      output_height ||= page_size
      @scroll_offset = [[@scroll_offset, 0].max, max_scroll_offset(output_height)].min
    end

    def max_scroll_offset(output_height)
      [@output_lines.length - output_height, 0].max
    end

    def draw(row, col, text, width)
      return if row.negative? || row >= screen_height

      @output_io.print(TTY::Cursor.move_to(col, row))
      @output_io.print(text.to_s[0, width])
    end

    def move_cursor(input_start_row, width)
      before_cursor = @input[0...@cursor]
      row_offset = before_cursor.count("\n")
      col_offset = (before_cursor.split("\n", -1).last || "").length
      last_input_row = screen_height > 1 ? screen_height - 2 : 0
      row = [input_start_row + row_offset, last_input_row].min
      col = [@prompt_label.length + 1 + col_offset, width - 1].min
      @output_io.print(TTY::Cursor.move_to(col, row))
    rescue StandardError
      nil
    end

    def screen_height
      [TTY::Screen.height, 1].max
    end

    def screen_width
      [TTY::Screen.width, 1].max
    end
  end
end
