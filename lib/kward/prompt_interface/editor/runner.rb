require_relative "../../scratchpad_runner"
require_relative "runner_state"

# Namespace for the Kward CLI agent runtime.
module Kward
  # Coordinates execution and output viewing for editor buffers.
  class PromptInterface
    module EditorRunner
      private

      def editor_runner_config
        config = @editor_runners_source.respond_to?(:call) ? @editor_runners_source.call : {}
        config.is_a?(Hash) ? config : {}
      end

      def editor_runner_output_visible?
        @editor_runner_output_visible && @editor_runner_state
      end

      def editor_runner_running?
        @editor_runner_state&.running?
      end

      def run_editor_buffer(source: nil)
        return false unless @editor_state
        return false if @editor_state.readonly?
        if editor_runner_running?
          @editor_runner_output_visible = true
          @editor_state.status = "Runner already active · Ctrl+C cancel"
          return false
        end

        language = @editor_state.language || editor_syntax_language
        unless ScratchpadLanguages.runnable?(language)
          @editor_state.status = "No runner available for #{language || "text"}"
          return false
        end

        source = source.nil? ? @editor_state.buffer.dup : source.to_s
        source_path = @editor_state.path
        workspace_root = prompt_workspace_root
        state = EditorRunnerState.new(language: language, source: source)
        @editor_runner_state = state
        @editor_runner_output_visible = true
        clear_editor_runner_selection
        @editor_state.status = "Running #{language} · Ctrl+C cancel"
        Thread.new do
          Thread.current.report_on_exception = false
          result = ScratchpadRunner.run(
            language,
            source,
            cancelled: state.method(:cancel_requested?),
            cwd: workspace_root,
            source_path: source_path,
            runner_config: editor_runner_config
          )
          finish_editor_runner(state, result)
        rescue StandardError => e
          fail_editor_runner(state, e)
        end
        true
      end

      def finish_editor_runner(state, result)
        @mutex.synchronize do
          return unless @editor_runner_state.equal?(state) && @editor_state

          state.complete(result)
          @editor_state.status = editor_runner_result_status(result)
          render_prompt_locked if @started && @asking
        end
      end

      def fail_editor_runner(state, error)
        @mutex.synchronize do
          return unless @editor_runner_state.equal?(state) && @editor_state

          state.fail(error)
          @editor_state.status = "Run failed: #{error.message}"
          render_prompt_locked if @started && @asking
        end
      end

      def editor_runner_result_status(result)
        return "Canceled · Esc close · Ctrl+R rerun" if result.cancelled

        "Exit #{result.exit_status} · #{format_runner_duration(result.duration)} · Esc close · Ctrl+R rerun"
      end

      def format_runner_duration(duration)
        format("%.2fs", duration.to_f)
      end

      def cancel_editor_runner
        return false unless editor_runner_running?

        @editor_runner_state.cancel
        @editor_state.status = "Canceling #{@editor_runner_state.language} · please wait"
        true
      end

      def close_editor_runner_output
        @editor_runner_output_visible = false
        clear_editor_runner_selection
        true
      end

      def handle_editor_runner_output_key(key)
        mouse_result = handle_editor_runner_mouse_key(key)
        return mouse_result unless mouse_result == false
        return true if handle_bundled_key(key) { |token| handle_editor_runner_output_key(token) }

        if (sequence = parse_csi_u_key(key))
          queue_pending_keys(sequence[:remaining]) if sequence[:remaining] && !sequence[:remaining].empty?
          if sequence[:code] == 121 && !ctrl_modifier?(sequence[:modifier]) && @editor_state&.vibe? && editor_runner_selection_active?
            return copy_editor_runner_selection
          end
          normalized_code = ctrl_code(sequence[:code])
          if (ctrl_modifier?(sequence[:modifier]) || super_modifier?(sequence[:modifier])) && normalized_code == 99
            return copy_editor_runner_selection if editor_runner_selection_active?
            return cancel_editor_runner if ctrl_modifier?(sequence[:modifier]) && editor_runner_running?
          end
          if ctrl_modifier?(sequence[:modifier])
            return run_editor_buffer if normalized_code == 114
            if normalized_code == 113
              close_editor_runner_output
              return quit_editor
            end
          end
          return close_editor_runner_output if sequence[:code] == 27
        end

        key_name = key_name_for(key)
        case key_name
        when :up
          scroll_editor_runner_output(-1)
        when :down
          scroll_editor_runner_output(1)
        when :pageup
          scroll_editor_runner_output(-editor_runner_output_page_size)
        when :pagedown
          scroll_editor_runner_output(editor_runner_output_page_size)
        when :ctrl_q
          close_editor_runner_output
          quit_editor
        when :ctrl_r
          run_editor_buffer
        when :ctrl_c
          if editor_runner_selection_active?
            copy_editor_runner_selection
          else
            editor_runner_running? ? cancel_editor_runner : close_editor_runner_output
          end
        else
          case key
          when "\e", "q", "Q"
            close_editor_runner_output
          when "y"
            copy_editor_runner_selection if @editor_state&.vibe? && editor_runner_selection_active?
          when TerminalKeys::CTRL_Q
            close_editor_runner_output
            quit_editor
          when TerminalKeys::CTRL_R
            run_editor_buffer
          when TerminalKeys::CTRL_C
            if editor_runner_selection_active?
              copy_editor_runner_selection
            else
              editor_runner_running? ? cancel_editor_runner : close_editor_runner_output
            end
          end
        end
        true
      end

      def handle_editor_runner_mouse_key(key)
        event = parse_sgr_mouse_event(key)
        return false unless event

        queue_pending_keys(event[:remaining]) unless event[:remaining].empty?
        case event[:code]
        when 64
          scroll_editor_runner_output(-1)
        when 65
          scroll_editor_runner_output(1)
        else
          if event[:drag]
            update_editor_runner_selection(editor_runner_position_for_mouse_event(event))
          elsif event[:button].zero?
            event[:release] ? finish_editor_runner_selection : begin_editor_runner_selection(event)
          end
        end
        true
      end

      def begin_editor_runner_selection(event)
        position = editor_runner_position_for_mouse_event(event)
        return true unless position

        click_count = editor_runner_mouse_click_count(event)
        case click_count
        when 3..Float::INFINITY
          @editor_runner_selection_anchor = [position[0], 0]
          @editor_runner_selection_cursor = [position[0], editor_runner_line(position[0]).length]
        when 2
          range = editor_runner_word_range_at(position)
          if range
            @editor_runner_selection_anchor = [position[0], range[0]]
            @editor_runner_selection_cursor = [position[0], range[1]]
          else
            @editor_runner_selection_anchor = position
            @editor_runner_selection_cursor = position
          end
        else
          @editor_runner_selection_anchor = position
          @editor_runner_selection_cursor = position
        end
        @editor_runner_mouse_dragging = true
        true
      end

      def update_editor_runner_selection(position)
        return true unless @editor_runner_mouse_dragging && position

        @editor_runner_selection_cursor = position
        true
      end

      def finish_editor_runner_selection
        @editor_runner_mouse_dragging = false
        true
      end

      def editor_runner_mouse_click_count(event)
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        count = if @editor_runner_last_click && now - @editor_runner_last_click[:time] <= 0.5 &&
                   (@editor_runner_last_click[:column] - event[:column]).abs <= 1 &&
                   (@editor_runner_last_click[:row] - event[:row]).abs <= 1
                  @editor_runner_last_click[:count] + 1
                else
                  1
                end
        @editor_runner_last_click = { time: now, column: event[:column], row: event[:row], count: count }
        count
      end

      def editor_runner_position_for_mouse_event(event)
        row_offset = event[:row] - editor_runner_output_content_top_row
        return nil if row_offset.negative? || row_offset >= editor_runner_output_visible_count

        line_index = @editor_runner_state.scroll_row + row_offset
        line = editor_runner_line(line_index)
        return nil unless line

        column = [[event[:column] - 3, 0].max, line.length].min
        [line_index, column]
      end

      def editor_runner_output_content_top_row
        height = screen_height
        source_count, = editor_split_visible_counts(height: height, width: screen_width)
        composer_top_row(height) + source_count + 3
      end

      def editor_runner_line(line_index)
        lines = editor_runner_output_lines([screen_width - 4, 1].max)
        line = lines[line_index]
        line && ANSI.strip(line)
      end

      def editor_runner_selection_active?
        @editor_runner_selection_anchor && @editor_runner_selection_cursor &&
          @editor_runner_selection_anchor != @editor_runner_selection_cursor
      end

      def clear_editor_runner_selection
        @editor_runner_selection_anchor = nil
        @editor_runner_selection_cursor = nil
        @editor_runner_mouse_dragging = false
        @editor_runner_last_click = nil
      end

      def editor_runner_selection_bounds
        return nil unless editor_runner_selection_active?

        [@editor_runner_selection_anchor, @editor_runner_selection_cursor].minmax_by { |position| position }
      end

      def editor_runner_selection_range_for(line_index, line_length)
        bounds = editor_runner_selection_bounds
        return nil unless bounds

        first, last = bounds
        return nil if line_index < first[0] || line_index > last[0]

        start_column = line_index == first[0] ? first[1] : 0
        end_column = line_index == last[0] ? last[1] : line_length
        [start_column, end_column] if start_column < end_column
      end

      def editor_runner_word_range_at(position)
        line = editor_runner_line(position[0]).to_s
        return nil if line.empty? || TextBoundary.word_separator?(line[[position[1], line.length - 1].min])

        index = [position[1], line.length - 1].min
        start_column = index
        start_column -= 1 while start_column.positive? && !TextBoundary.word_separator?(line[start_column - 1])
        end_column = index + 1
        end_column += 1 while end_column < line.length && !TextBoundary.word_separator?(line[end_column])
        [start_column, end_column]
      end

      def editor_runner_selected_text
        bounds = editor_runner_selection_bounds
        return "" unless bounds

        first, last = bounds
        lines = (first[0]..last[0]).map { |line_index| editor_runner_line(line_index).to_s }
        if lines.length == 1
          lines[0] = lines[0][first[1]...last[1]] || ""
        else
          lines[0] = lines[0][first[1]..] || ""
          lines[-1] = lines[-1][...last[1]] || ""
        end
        lines.join("\n")
      end

      def copy_editor_runner_selection
        text = editor_runner_selected_text
        return false if text.empty?

        print_output_locked(TerminalSequences.osc52(text))
        flush_output_locked if @output_io.respond_to?(:flush)
        clear_editor_runner_selection
        @editor_state.status = "Copied selection"
        true
      end

      def scroll_editor_runner_output(delta)
        return false unless @editor_runner_state

        @editor_runner_state.scroll_by(delta, maximum: editor_runner_output_scroll_max)
        true
      end

      def editor_runner_output_page_size
        [editor_runner_output_visible_count, 1].max
      end
    end
  end
end
