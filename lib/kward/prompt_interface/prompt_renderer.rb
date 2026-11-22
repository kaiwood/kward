# Namespace for the Kward CLI agent runtime.
module Kward
  # Prompt label and composer chrome renderer.
  class PromptInterface
    # Renderer for prompt labels and composer prompt chrome.
    module PromptRenderer
      private

      def render_prompt_locked
        return unless @started && @asking && !terminal_owned_by_child_locked?

        width, height = screen_size
        unless handle_resize_locked(width: width, height: height)
          rows, cursor_row, cursor_col = composer_layout(width, height)
          if composer_frame_needs_sync?(rows, cursor_row)
            with_synchronized_output_locked { render_prompt_layout_locked(rows, cursor_row, cursor_col, width, height) }
          else
            render_prompt_layout_locked(rows, cursor_row, cursor_col, width, height)
          end
        end
        flush_output_locked unless @restoring_transcript || @synchronized_output_depth.positive?
      end

      def composer_frame_needs_sync?(rows, cursor_row)
        return true if rows.length != @reserved_rows

        # Keep ordinary typing fast, but don't expose cursor travel to other rows.
        rows.each_index.any? { |index| index != cursor_row && rows[index] != @last_composer_rows[index] }
      end

      def render_prompt_layout_locked(rows, cursor_row, cursor_col, width, height)
        ensure_scroll_region_locked(rows.length, width: width, height: height)
        @rendered_rows = rows.length
        render_composer_rows_locked(rows, height: height)
        @last_width = width
        @last_height = height
        @rendered_composer_cursor = [composer_top_row(height) + cursor_row, cursor_col + 1]
        restore_composer_cursor_locked
      end

      def render_prompt_after_output_locked
        render_prompt_locked
      end

      def clear_prompt_locked
        return if terminal_owned_by_child_locked?

        handle_resize_locked
        width, height = screen_size
        clear_composer_region_locked(height: height)
        @rendered_rows = 0
        redraw_transcript_locked(width: width, height: height)
      end

      def clear_prompt_for_output_locked
        return if terminal_owned_by_child_locked?

        handle_resize_locked
        width, height = screen_size
        reserve_composer_region_locked(width: width, height: height) if @started && @asking
        clear_composer_region_locked(height: height)
        @rendered_rows = 0
        move_to_transcript_cursor_locked(width: width, height: height) if @started
      end

      def prepare_transcript_output_locked
        return if terminal_owned_by_child_locked?

        handle_resize_locked
        width, height = screen_size
        # Stream against the painted frame, not a layout that may have unpainted status changes.
        if @started && @asking
          render_prompt_locked if @last_composer_rows.empty?
        elsif @reserved_rows.zero?
          reserve_composer_region_locked(width: width, height: height)
        end
        return if transcript_region_hidden?(height)

        hide_cursor_for_transcript_output_locked
        move_to_transcript_cursor_locked(width: width, height: height)
      end

      def restore_composer_cursor_locked
        return unless @started && @asking && @rendered_composer_cursor && !terminal_owned_by_child_locked?

        move_to_screen(*@rendered_composer_cursor)
        render_cursor_visibility_locked
      end

      def redraw_screen_locked(width: screen_width, height: screen_height)
        return unless @started && !terminal_owned_by_child_locked?

        clear_image_viewer_output_locked if image_viewer_active?
        restore_scroll_region_locked
        print_output_locked(TTY::Cursor.clear_screen)
        move_to_screen(1, 1)
        @reserved_rows = 0
        @last_composer_rows = []
        rows, cursor_row, cursor_col = composer_layout(width, height)
        ensure_scroll_region_locked(rows.length, redraw_transcript: false, width: width, height: height)
        redraw_transcript_locked(width: width, height: height)
        @rendered_rows = @asking ? rows.length : 0
        render_composer_rows_locked(rows, height: height) if @asking
        @last_width = width
        @last_height = height
        reset_stream_position_from_transcript_locked(width)
        @rendered_composer_cursor = @asking ? [composer_top_row(height) + cursor_row, cursor_col + 1] : nil
        restore_composer_cursor_locked
      end

    end
  end
end
