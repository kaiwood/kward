require_relative "../../private_file"

module Kward
  class PromptInterface
    # Owns file navigation and retained buffers for one editor session.
    module EditorExplorer
      EXPLORER_TOGGLE = "[Explorer]".freeze
      EXPLORER_SPLIT_MIN_WIDTH = 64

      private

      def editor_explorer_available?
        @editor_state&.path && !@editor_state.readonly? && !@editor_save_callback &&
          !@editor_prompt_active && !@editor_save_as_active && !editor_runner_output_visible? && !editor_runner_running?
      end

      def editor_explorer_width(width = screen_width)
        return 0 unless editor_explorer_available? && @editor_explorer&.[](:visible) && width >= EXPLORER_SPLIT_MIN_WIDTH

        [width / 3, 32].min
      end

      def editor_explorer_snapshot(state = @editor_explorer)
        state&.merge(expanded: state[:expanded].dup, selected: state[:selected].dup)
      end

      def editor_explorer_header_label(width)
        editor_explorer_header_hit?(width - 2, width) ? " #{EXPLORER_TOGGLE} " : ""
      end

      def editor_explorer_header_hit?(column, width)
        return false unless editor_explorer_available? && width >= EXPLORER_TOGGLE.length + 8
        return false if @editor_explorer&.[](:visible) && screen_width >= EXPLORER_SPLIT_MIN_WIDTH

        column.between?(width - EXPLORER_TOGGLE.length - 1, width - 2)
      end

      def editor_pane_width
        screen_width - editor_explorer_width
      end

      def editor_explorer_focused?
        editor_explorer_available? && @editor_explorer&.[](:visible) && @editor_explorer[:focused]
      end

      def restore_editor_explorer
        state_path = ConfigFiles.editor_explorer_state_path(prompt_workspace_root)
        saved = read_editor_explorer_preferences(state_path)
        path = editor_explorer_relative_path(@editor_state.path)
        parts = path ? path.split("/")[0...-1] : []
        expanded = parts.each_index.map { |index| parts[0..index].join("/") }
        expanded = saved["expanded"].grep(String) if saved["expanded"].is_a?(Array)
        selection = saved["selection"]
        kind = { "file" => :file, "directory" => :directory }[selection.first] if selection.is_a?(Array)
        selected = kind && selection[1].is_a?(String) ? [kind, selection[1]] : [:file, path]
        offset = saved["offset"].is_a?(Integer) ? [saved["offset"], 0].max : 0

        @editor_explorer = { visible: saved["visible"] == true, expanded: expanded.to_set, selected: selected,
                             offset: offset, state_path: state_path }
        @editor_explorer[:saved_preferences] = editor_explorer_preferences
        load_editor_explorer_tree if @editor_explorer[:visible]
      end

      def read_editor_explorer_preferences(path)
        data = JSON.parse(File.read(path))
        data.is_a?(Hash) ? data : {}
      rescue SystemCallError, JSON::ParserError
        {}
      end

      def editor_explorer_preferences
        kind, path = @editor_explorer[:selected]
        if kind == :buffer
          kind = :file
          path = editor_explorer_relative_path(path)
        end
        {
          "visible" => @editor_explorer[:visible],
          "expanded" => @editor_explorer[:expanded].to_a.sort,
          "selection" => path && [kind.to_s, path],
          "offset" => @editor_explorer[:offset]
        }
      end

      def persist_editor_explorer
        return unless @editor_explorer

        preferences = editor_explorer_preferences
        return if preferences == @editor_explorer[:saved_preferences]

        PrivateFile.write_json(@editor_explorer[:state_path], preferences)
        @editor_explorer[:saved_preferences] = preferences
      rescue SystemCallError, IOError, JSON::GeneratorError
        nil
      end

      def load_editor_explorer_tree
        paths = ProjectFiles.list(root: prompt_workspace_root, literal_names: true)
        @editor_explorer[:tree] = ProjectFileTree.new(paths)
      end

      def toggle_editor_explorer
        restore_editor_explorer unless @editor_explorer
        visible = @editor_explorer[:visible] = !@editor_explorer[:visible]
        @editor_explorer[:focused] = visible && editor_explorer_width.zero?
        load_editor_explorer_tree if visible
        true
      end

      def retained_editor_buffers
        @retained_editor_buffers ||= []
      end

      def activate_editor_buffer(state, retain_current: true)
        retained_editor_buffers.delete(state)
        retained_editor_buffers << @editor_state if retain_current
        @editor_state = state
        @editor_state.quit_confirmed = false
        @editor_text_width = nil
        finish_editor_mouse_drag
        @editor_last_click = nil
        reset_editor_word_completion
        true
      end

      def editor_explorer_relative_path(path)
        relative = Pathname.new(path).relative_path_from(Pathname.new(prompt_workspace_root)).to_s
        relative unless relative == ".." || relative.start_with?("../")
      end

      def open_editor_explorer_file(path, state: nil)
        full_path = File.expand_path(path, prompt_workspace_root)
        state ||= ([@editor_state] + retained_editor_buffers).find { |buffer| buffer.path == full_path }
        return true if state.equal?(@editor_state)

        unless state
          root = File.realpath(prompt_workspace_root)
          real_path = File.realpath(full_path)
          root_prefix = root == "/" ? root : "#{root}/"
          unless real_path.start_with?(root_prefix) && File.file?(real_path)
            return editor_explorer_error("Explorer can only open files inside the workspace")
          end

          state = ([@editor_state] + retained_editor_buffers).find do |buffer|
            buffer.path && File.realpath(buffer.path) == real_path
          rescue SystemCallError
            false
          end
          return true if state.equal?(@editor_state)

          unless state
            content = File.binread(real_path).force_encoding(Encoding.default_external)
            return editor_explorer_error("Explorer can only open text files") unless content.valid_encoding? && !content.include?("\0")

            workspace_path = File.join(prompt_workspace_root, real_path.delete_prefix(root_prefix))
            state = EditorState.new(path: workspace_path, content: content, editor_mode: @editor_state.editor_mode)
          end
        end
        activate_editor_buffer(state)
      rescue SystemCallError, ArgumentError
        editor_explorer_error("Could not open file")
      end

      def editor_explorer_error(message)
        @editor_state.status = message
        @editor_explorer[:focused] = false
        true
      end

      def editor_explorer_rows
        buffers = ([@editor_state] + retained_editor_buffers).sort_by(&:path).map do |state|
          { key: [:buffer, state.path], label: "#{editor_explorer_relative_path(state.path) || state.path}#{' *' if state.dirty?}",
            active: state.equal?(@editor_state), state: state }
        end
        active_path = editor_explorer_relative_path(@editor_state.path)
        tree = @editor_explorer[:tree].rows(@editor_explorer[:expanded]).map do |row|
          kind = row[:directory] ? :directory : :file
          prefix = row[:directory] ? (row[:expanded] ? "▾ " : "▸ ") : "  "
          { key: [kind, row[:path]], label: "#{'  ' * row[:depth]}#{prefix}#{row[:name]}", active: kind == :file && row[:path] == active_path }
        end
        [{ label: "Open Editors" }, *buffers, { label: "Workspace" }, *tree]
      end

      def editor_explorer_window(rows, height)
        count = [height - 2, 0].max
        @editor_explorer[:offset] = @editor_explorer[:offset].clamp(0, [rows.length - count, 0].max)
        rows.slice(@editor_explorer[:offset], count) || []
      end

      def editor_explorer_layout(width, height)
        return [] unless height.positive?
        return Array.new(height, " " * width) if width < 5

        rows = editor_explorer_window(editor_explorer_rows, height)
        heading = @editor_explorer[:focused] ? :bold : :primary_green
        columns = width - 4
        lines = [editor_pane_top_border(colored(EXPLORER_TOGGLE, heading), width)]
        [height - 2, 0].max.times do |index|
          row = rows[index]
          label = row ? "#{row[:active] ? '•' : ' '} #{row[:label]}" : ""
          label = ANSI.strip(label.scrub).gsub(/[[:cntrl:]]/, " ")
          selected = row && row[:key] && row[:key] == @editor_explorer[:selected] && @editor_explorer[:focused]
          text = visible_ljust(visible_truncate(label, columns), columns)
          text = "#{TerminalSequences::SGR_INVERSE}#{text}#{TerminalSequences::SGR_INVERSE_OFF}" if selected
          lines << box_content_row(text, columns)
        end
        lines << bottom_border(width) if height > 1
        lines
      end

      def editor_explorer_body_height(height = screen_height, width = screen_width)
        @tabs.empty? ? height : height - editor_bottom_rows(width).length
      end

      def editor_explorer_activate_row(row, keyboard: false)
        return true unless row && row[:key]

        kind, path = @editor_explorer[:selected] = row[:key]
        if kind == :directory
          expanded = @editor_explorer[:expanded]
          expanded.delete?(path) || expanded.add(path)
        else
          open_editor_explorer_file(path, state: row[:state])
          @editor_explorer[:focused] = false if keyboard || editor_explorer_width.zero?
        end
        true
      end

      def handle_editor_explorer_mouse(event)
        return false unless editor_explorer_available?
        return false if @editor_mouse_dragging && (event[:drag] || event[:release])

        width = editor_explorer_width
        focused = editor_explorer_focused?
        if width.zero? && !focused
          if event[:row] == 1 && editor_explorer_header_hit?(event[:column], screen_width)
            if editor_explorer_click?(event)
              if @editor_explorer&.[](:visible)
                @editor_explorer[:focused] = true
              else
                toggle_editor_explorer
              end
            end
            return true
          end
          return false
        end

        height = editor_explorer_body_height
        in_pane = event[:row] <= height && (width.zero? || event[:column] <= width)
        unless in_pane
          @editor_explorer[:focused] = false if editor_explorer_click?(event)
          return false
        end
        return toggle_editor_explorer if event[:row] == 1 && editor_explorer_click?(event) && event[:column].between?(3, EXPLORER_TOGGLE.length + 2)

        rows = editor_explorer_rows
        window = editor_explorer_window(rows, height)
        case event[:code]
        when 64, 65
          @editor_explorer[:offset] += event[:code] == 64 ? -3 : 3
        else
          if editor_explorer_click?(event)
            @editor_explorer[:focused] = true
            editor_explorer_activate_row(window[event[:row] - 2]) if event[:row].between?(2, height - 1)
          end
        end
        true
      end

      def editor_explorer_click?(event)
        event[:button].zero? && !event[:drag] && !event[:release] && event[:code] < 64
      end

      def handle_editor_explorer_key(key)
        return false unless editor_explorer_focused?
        if (paste = read_bracketed_paste(key))
          queue_pending_keys(paste[:remaining])
          return true
        end
        return true if handle_bundled_key(key) { |token| handle_editor_key(token) }

        sequence = parse_csi_u_key(key)
        queue_pending_keys(sequence[:remaining]) if sequence && !sequence[:remaining].to_s.empty?
        name = { 13 => :enter, 27 => :escape }[sequence&.[](:code)] || key_name_for(key)
        rows = editor_explorer_rows
        index = rows.index { |row| row[:key] && row[:key] == @editor_explorer[:selected] }
        case name
        when :up, :down
          indices = rows.each_index.select { |candidate| rows[candidate][:key] }
          target = if name == :up
                     indices.reverse.find { |candidate| !index || candidate < index }
                   else
                     indices.find { |candidate| !index || candidate > index }
                   end
          if target
            @editor_explorer[:selected] = rows[target][:key]
            count = [editor_explorer_body_height - 2, 1].max
            @editor_explorer[:offset] = @editor_explorer[:offset].clamp([target - count + 1, 0].max, target)
          end
        when :enter, :return
          editor_explorer_activate_row(rows[index], keyboard: true) if index
        when :escape
          @editor_explorer[:focused] = false
        end
        true
      end
    end
  end
end
