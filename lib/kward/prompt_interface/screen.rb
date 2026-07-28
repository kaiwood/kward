# Namespace for the Kward CLI agent runtime.
module Kward
  # Terminal screen lifecycle and escape-sequence management.
  class PromptInterface
    # Terminal screen control and escape-sequence helpers.
    module Screen
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

      def hide_cursor_for_transcript_output_locked
        return unless @started && @asking

        set_cursor_visible_locked(false)
      end

      def render_cursor_visibility_locked
        visible = !(@question_state && !selected_question_choice&.fetch(:custom, false))
        visible = select_editing_active? if @select_state
        visible = git_composing? if @git_state
        visible = project_browser_search_active? if project_browser_visible?
        set_cursor_visible_locked(visible)
      end

      def set_cursor_visible_locked(visible, force: false)
        return if !force && @cursor_visible == visible

        @output_io.print(visible ? CURSOR_SHOW : CURSOR_HIDE)
        @cursor_visible = visible
      end

      def set_editor_bar_cursor_locked
        return if @editor_bar_cursor_active

        @output_io.print(CURSOR_SHAPE_BAR)
        @editor_bar_cursor_active = true
      end

      def restore_editor_cursor_shape_locked
        return unless @editor_bar_cursor_active

        @output_io.print(CURSOR_SHAPE_DEFAULT)
        @editor_bar_cursor_active = false
      end

      def reserve_composer_region_locked(width: screen_width, height: screen_height)
        rows, = composer_layout(width, height)
        ensure_scroll_region_locked(rows.length, width: width, height: height)
      end

      def make_room_for_composer_after_handoff_locked
        rows, = composer_layout(screen_width, screen_height)
        @output_io.print("\r\n" * rows.length)
      end

      def ensure_scroll_region_locked(row_count, redraw_transcript: true, width: screen_width, height: screen_height)
        new_reserved_rows = [[row_count, 1].max, [height - 1, 1].max].min
        return if @reserved_rows == new_reserved_rows && @last_height == height

        old_reserved_rows = @reserved_rows
        old_top = [height - old_reserved_rows + 1, 1].max
        @reserved_rows = new_reserved_rows
        new_top = composer_top_row(height)
        @output_io.print(TerminalSequences.scroll_region(1, transcript_bottom_row(height)))
        clear_screen_rows_locked(old_top, new_top - 1) if new_top > old_top
        @last_composer_rows = []
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
        if interactive_active_locked?
          @interactive_state[:controller].resize(width: interactive_canvas_width(current_width))
        end
        redraw_screen_locked(width: current_width, height: current_height)
        true
      end

      def restore_scroll_region_locked
        @output_io.print(TerminalSequences.restore_scroll_region)
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
          if row
            @output_io.print(row)
          else
            @output_io.print(TTY::Cursor.clear_line)
          end
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

      def move_to_screen(row, col)
        @output_io.print(TerminalSequences.move_to(row, col))
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
end
