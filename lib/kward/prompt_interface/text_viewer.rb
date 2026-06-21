# Namespace for the Kward CLI agent runtime.
module Kward
  # Interactive terminal UI used by the CLI frontend.
  class PromptInterface
    # Read-only text viewer overlay for long generated content.
    module TextViewer
      def view_text(title:, content:)
        start
        @mutex.synchronize do
          @text_viewer_state = { title: title.to_s, lines: content.to_s.lines(chomp: true), offset: 0 }
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
              result = handle_text_viewer_key(key)
              render_prompt_locked unless result == SELECT_CANCEL
            end
          end
          break if result == SELECT_CANCEL

          sleep 0.02 if key.nil?
        end
      ensure
        @mutex.synchronize do
          @text_viewer_state = nil
          render_prompt_locked if @started && @asking
        end
      end

      private

      def handle_text_viewer_key(key)
        key_name = @reader.console.keys[key]
        case key_name
        when :up
          scroll_text_viewer(-1)
        when :down
          scroll_text_viewer(1)
        else
          case key
          when "\e", "q", "Q"
            SELECT_CANCEL
          when "\u0002" # Ctrl+B
            scroll_text_viewer(-text_viewer_page_size)
          when "\u0006" # Ctrl+F
            scroll_text_viewer(text_viewer_page_size)
          when "k"
            scroll_text_viewer(-1)
          when "j"
            scroll_text_viewer(1)
          else
            handle_text_viewer_escape_sequence(key)
          end
        end
      end

      def handle_text_viewer_escape_sequence(key)
        return false unless key == "\e"

        pending_sequence = read_pending_escape_sequence
        return SELECT_CANCEL if pending_sequence.empty?

        full_sequence = "\e#{pending_sequence}"
        case @reader.console.keys[full_sequence]
        when :up
          scroll_text_viewer(-1)
        when :down
          scroll_text_viewer(1)
        else
          true
        end
      end

      def scroll_text_viewer(delta)
        return unless @text_viewer_state

        max_offset = [@text_viewer_state.fetch(:lines).length - text_viewer_page_size, 0].max
        @text_viewer_state[:offset] = [[@text_viewer_state.fetch(:offset) + delta, 0].max, max_offset].min
        true
      end

      def text_viewer_page_size
        max_overlay_list_rows(screen_height) + 4
      end

      def text_viewer_overlay_rows(width, height: screen_height)
        state = @text_viewer_state
        page_size = [[height - 7, 3].max, 18].min
        lines = state.fetch(:lines)
        max_offset = [lines.length - page_size, 0].max
        offset = [state.fetch(:offset), max_offset].min
        state[:offset] = offset
        visible = lines[offset, page_size] || []
        content_rows = []
        content_rows << overlay_text_line("↑/↓ scroll · q/Esc close", :muted)
        content_rows << overlay_blank_line
        content_rows.concat(visible.map { |line| overlay_text_line(line) })
        if lines.length > page_size
          content_rows << overlay_blank_line
          content_rows << overlay_text_line("#{offset + 1}-#{[offset + page_size, lines.length].min} of #{lines.length}", :muted)
        end
        overlay_card_rows(state.fetch(:title), content_rows, width)
      end
    end
  end
end
