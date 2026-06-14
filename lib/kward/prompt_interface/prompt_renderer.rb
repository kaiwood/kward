# Namespace for the Kward CLI agent runtime.
module Kward
  # Prompt label and composer chrome renderer.
  class PromptInterface
    # Renderer for prompt labels and composer prompt chrome.
    module PromptRenderer
      private

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

    end
  end
end
