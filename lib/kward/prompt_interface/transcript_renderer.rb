# Namespace for the Kward CLI agent runtime.
module Kward
  # Terminal transcript rendering helpers.
  class PromptInterface
    # Renderer for transcript entries in the terminal prompt interface.
    module TranscriptRenderer
      private

      def write_stream_block_locked(label, delta, finish: false)
        with_synchronized_output_locked do
          prepare_transcript_output_locked unless @restoring_transcript
          clear_stream_caret_locked
          if label && @stream_state.block != label
            ensure_transcript_block_separator_locked
            write_transcript_text_locked("#{colored("#{transcript_label(label)}>", *label_styles(label))} ")
            @stream_state.start_block(label)
          end
          write_transcript_text_locked(delta) unless delta.empty?
          write_transcript_text_locked("\n") if finish && @stream_state.block && !@transcript_buffer.end_with?("\n")
          @stream_state.finish_block if finish
          render_stream_caret_locked unless finish
          restore_composer_cursor_locked unless @restoring_transcript
        end
        flush_output_locked unless @restoring_transcript
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
        print_output_locked(output_text)
        update_stream_position(output_text, width: width)
      end

      def append_transcript_buffer(text)
        @transcript_buffer.append(text.to_s)
      end

      def render_stream_caret_locked
        return if @restoring_transcript
        return unless @stream_caret_enabled
        return unless %w[Assistant Reasoning].include?(@stream_state.block)
        return if @stream_state.pending_wrap?

        print_output_locked(colored("▍", :activity))
        @stream_caret_visible = true
      end

      def clear_stream_caret_locked
        return unless @stream_caret_visible

        print_output_locked(ERASE_CHARACTER)
        @stream_caret_visible = false
      end

      def ensure_transcript_block_separator_locked
        return if @transcript_buffer.empty? || @transcript_buffer.end_with?("\n\n")

        write_transcript_text_locked(@transcript_buffer.end_with?("\n") ? "\n" : "\n\n")
      end

      def terminal_newlines(text)
        text.gsub(/\r\n|\r|\n/, "\r\n")
      end

      def redraw_transcript_locked(width: screen_width, height: screen_height)
        return unless transcript_renderable?

        rows = transcript_viewport_rows(transcript_redraw_row_count(height), width)
        clear_screen_rows_locked(1, rows.length)
        return if rows.empty?

        move_to_screen(1, 1)
        print_output_locked(terminal_newlines(rows.join("\n")))
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
        !@transcript_buffer.empty?
      end

      def transcript_display_rows(width)
        @transcript_buffer.display_rows(width)
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
        print_output_locked("\r\n")
        @stream_state.clear_pending_wrap
      end

      def update_stream_position(text, width: screen_width)
        @stream_state.update_position(text, width: width)
      end

      def transcript_label(label)
        case label
        when "Assistant"
          @assistant_label
        when "Tool failed"
          "Tool"
        else
          label
        end
      end

      def label_styles(label)
        case label
        when "Reasoning", "Compaction summary"
          [:metadata, :bold]
        when "Assistant", "Kward"
          [:activity, :bold]
        when "Tool", "Tool output"
          [:tool, :bold]
        when "Tool failed"
          [:failure, :bold]
        when "Retry"
          [:caution, :bold]
        else
          [:metadata, :bold]
        end
      end

    end
  end
end
