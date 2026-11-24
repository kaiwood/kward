require_relative "../../source/outline"

module Kward
  class PromptInterface
    # Owns the active editor's Outline pane and its revision-scoped results.
    module EditorOutline
      OUTLINE_TOGGLE = "[Outline]".freeze
      OUTLINE_MIN_WIDTH = 100
      OUTLINE_DELAY = 0.15

      private

      def editor_outline_available?(width = screen_width)
        width >= OUTLINE_MIN_WIDTH && editor_explorer_available?
      end

      def editor_outline_width(width = screen_width)
        editor_outline_available?(width) && @editor_outline_visible ? 26 : 0
      end

      def editor_outline_focused?
        @editor_outline_focused && editor_outline_width.positive?
      end

      def editor_outline_toggle_label(width)
        editor_outline_available?(width) && !@editor_outline_visible ? " #{OUTLINE_TOGGLE} " : ""
      end

      def toggle_editor_outline
        @editor_outline_visible = !@editor_outline_visible
        @editor_outline_focused = false
        @editor_outline_request = nil unless @editor_outline_visible
        true
      end

      def cancel_editor_outline
        @editor_outline_job&.last&.kill&.join
        @editor_outline_job = @editor_outline_request = nil
      end

      def editor_outline_request
        buffer = @editor_state.buffer
        path = @editor_state.path
        request = @editor_outline_request
        return request if request && request[:buffer].equal?(buffer) && request[:path] == path

        @editor_outline_request = { buffer: buffer, path: path, due: monotonic_now + OUTLINE_DELAY, index: 0, offset: 0 }
      end

      def tick_editor_outline_locked
        return false unless editor_outline_width.positive? && !@editor_state.workspace_only?

        request = editor_outline_request
        if @editor_outline_job && !@editor_outline_job.last.alive?
          completed, worker = @editor_outline_job
          @editor_outline_job = nil
          if completed.equal?(request)
            request[:symbols] = worker.value
            return true
          end
        end
        return false if @editor_outline_job || request[:symbols] || monotonic_now < request[:due]

        provider = (@editor_outline_provider ||= SourceOutline.new)
        path, buffer = request.values_at(:path, :buffer)
        worker = Thread.new { provider.symbols(path, buffer) }
        @editor_outline_job = [request, worker]
        false
      end

      def editor_outline_layout(width, height)
        return [] unless height.positive?

        request = editor_outline_request unless @editor_state.workspace_only?
        symbols = request&.[](:symbols)
        if request
          request[:offset] = [request[:offset], [symbols.to_a.length - [height - 2, 1].max, 0].max].min
        end
        offset = request ? request[:offset] : 0
        heading = colored(OUTLINE_TOGGLE, editor_outline_focused? ? :bold : :primary_green)
        rows = [editor_pane_top_border(heading, width)]
        [height - 2, 0].max.times do |index|
          position = offset + index
          entry = symbols&.[](position)
          text = if entry
                   editor_outline_label(entry, width - 4)
                 elsif request && index.zero? && symbols.to_a.empty?
                   symbols ? "No symbols found" : "Scanning…"
                 else
                   ""
                 end
          if entry && editor_outline_focused? && request[:index] == position
            text = TerminalSequences::SGR_INVERSE + visible_ljust(text, width - 4) + TerminalSequences::SGR_INVERSE_OFF
          end
          rows << box_content_row(text, width - 4)
        end
        rows << bottom_border(width) if height > 1
        rows
      end

      def editor_outline_label(entry, columns)
        name = ANSI.strip(entry[:name].to_s.scrub).gsub(/[[:cntrl:]]/, " ")
        depth = entry[:scope] ? 1 : (entry[:indent].to_i + 1) / 2
        indent = " " * [depth, 3].min
        indent + TerminalText.truncate_middle(name, columns - indent.length)
      end

      def handle_editor_outline_mouse(event)
        return false unless editor_outline_available?
        return false if @editor_mouse_dragging && (event[:drag] || event[:release])

        width = editor_outline_width
        if width.zero?
          return false unless event[:row] == 1 && event[:column].between?(screen_width - OUTLINE_TOGGLE.length - 1, screen_width - 2)

          toggle_editor_outline if editor_explorer_click?(event)
          return true
        end
        if event[:column] <= screen_width - width
          @editor_outline_focused = false if editor_explorer_click?(event)
          return false
        end
        if event[:row] == 1 && editor_explorer_click?(event)
          column = event[:column] - (screen_width - width)
          return toggle_editor_outline if column.between?(3, OUTLINE_TOGGLE.length + 2)
        end
        if !@editor_state.workspace_only? && event[:row].between?(2, editor_explorer_body_height - 1)
          request = editor_outline_request
          if editor_explorer_click?(event)
            focus_editor_pane(:outline)
            jump_to_editor_outline_symbol(request[:offset] + event[:row] - 2)
          elsif [64, 65].include?(event[:code])
            move_editor_outline_selection(event[:code] == 64 ? -3 : 3)
          end
        end
        true
      end

      def handle_editor_outline_key(key)
        return false unless editor_outline_focused?
        if (paste = read_bracketed_paste(key))
          queue_pending_keys(paste[:remaining])
          return true
        end
        return true if handle_bundled_key(key) { |token| handle_editor_key(token) }

        sequence = parse_csi_u_key(key)
        return true if sequence&.[](:event_type) == 3

        name = { 13 => :enter, 27 => :escape }[sequence&.[](:code)] || key_name_for(key)
        motion = @editor_state.vibe? && (sequence ? vibe_explorer_printable_key(sequence) : key)
        if name == :up || motion == "k"
          move_editor_outline_selection(-1)
        elsif name == :down || motion == "j"
          move_editor_outline_selection(1)
        elsif [:enter, :return].include?(name)
          jump_to_editor_outline_symbol(editor_outline_request[:index])
        elsif name == :escape || motion == ":"
          focus_editor_pane(:source)
          vibe_begin_command if motion == ":"
        end
        true
      end

      def move_editor_outline_selection(delta)
        request = editor_outline_request
        size = request[:symbols].to_a.length
        return if size.zero?

        index = request[:index] = (request[:index] + delta).clamp(0, size - 1)
        count = [editor_explorer_body_height - 2, 1].max
        request[:offset] = request[:offset].clamp([index - count + 1, 0].max, index)
      end

      def jump_to_editor_outline_symbol(index)
        entry = editor_outline_request[:symbols]&.[](index)
        return unless entry

        @editor_state.clear_selection
        line = @editor_state.lines[entry[:line] - 1]
        @editor_state.set_cursor_line_and_column(entry[:line] - 1, line[/\A[ \t]*/].length)
        editor_position_cursor_line(:center)
        focus_editor_pane(:source)
      end

      def editor_navigation_panes
        panes = [:source]
        panes.unshift(:explorer) if editor_explorer_available? && @editor_explorer&.[](:visible)
        panes << :outline if editor_outline_width.positive? && !@editor_state.workspace_only?
        panes
      end

      def focus_editor_pane(pane)
        @editor_explorer[:focused] = pane == :explorer if @editor_explorer
        @editor_outline_focused = pane == :outline
      end
    end
  end
end
