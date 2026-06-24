# Namespace for the Kward CLI agent runtime.
module Kward
  # Interactive terminal UI used by the CLI frontend.
  class PromptInterface
    # Renderer for interactive mode canvas frames. Draws the canvas buffer into
    # the composer region using the same boxed-row infrastructure as the editor.
    module InteractiveRenderer
      private

      def interactive_active_locked?
        !@interactive_state.nil?
      end

      def interactive_layout(width, height = screen_height)
        state = @interactive_state
        controller = state[:controller]
        rows = [interactive_top_border(width, state)]
        content_width = [width - 4, 1].max
        canvas_width = [content_width - 2, 1].max

        controller.cells.each do |cell_row|
          line = cell_row[0, canvas_width].map do |cell|
            char = cell[:char]
            colors = cell[:colors]
            colors.empty? ? char : colored(char, *colors)
          end.join
          rows << box_content_row(visible_ljust(line, content_width), content_width)
        end

        rows << footer_row(content_width, interactive_status_text(state))
        rows.concat(interactive_bottom_rows(width))
        cursor_row = 1
        cursor_col = 2
        [rows, cursor_row, cursor_col]
      end

      def interactive_top_border(width, state)
        title = visible_truncate(state[:title].to_s, [width - 4, 1].max)
        plain_title = ANSI.strip(title)
        "#{colored("╭", :primary_green)} #{title} #{colored("─" * [width - plain_title.length - 4, 0].max, :primary_green)}#{colored("╮", :primary_green)}"
      end

      def interactive_status_text(state)
        fps = state[:controller].fps
        "Interactive · #{fps.to_i}fps · Ctrl+C exits"
      end

      def interactive_bottom_rows(width)
        @tabs.empty? ? [bottom_border(width)] : tab_border_rows(width)
      end

      def tick_interactive_locked
        return false unless interactive_active_locked?

        controller = @interactive_state[:controller]
        return false if controller.exited?

        now = monotonic_now
        interval = 1.0 / controller.fps
        elapsed = now - @last_interactive_tick
        return false if elapsed < interval

        steps = (elapsed / interval).floor
        @last_interactive_tick += steps * interval
        result = controller.invoke_tick
        controller.exit if result == :exit
        true
      end
    end
  end
end
