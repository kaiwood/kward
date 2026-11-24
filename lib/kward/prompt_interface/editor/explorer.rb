require_relative "../../private_file"

module Kward
  class PromptInterface
    # Owns file navigation and retained buffers for one editor session.
    module EditorExplorer
      EXPLORER_TOGGLE = "[Explorer]".freeze
      EXPLORER_SPLIT_MIN_WIDTH = 64
      EXPLORER_MAX_INDENT_DEPTH = 3

      private

      def editor_explorer_available?
        return false unless @editor_state
        return false if !@editor_state.workspace_only? && (!@editor_state.path || @editor_state.readonly?)

        !@editor_save_callback &&
          !@editor_prompt_active && !@editor_save_as_active && !editor_runner_output_visible? && !editor_runner_running?
      end

      def editor_explorer_width(width = screen_width)
        return 0 unless editor_explorer_available? && @editor_explorer&.[](:visible) && width >= EXPLORER_SPLIT_MIN_WIDTH

        [width / 3, 32].min
      end

      def editor_explorer_snapshot(state = @editor_explorer)
        return unless state

        view = state.dig(:search, :origin) || state
        state.except(:motion_prefix, :search).merge(expanded: state[:expanded].dup, selected: view[:selected].dup,
                                                    offset: view[:offset], horizontal_offset: view[:horizontal_offset])
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
        view = @editor_explorer.dig(:search, :origin) || @editor_explorer
        kind, path = view[:selected]
        if kind == :buffer
          kind = :file
          path = editor_explorer_relative_path(path)
        end
        {
          "visible" => @editor_explorer[:visible],
          "expanded" => @editor_explorer[:expanded].to_a.sort,
          "selection" => path && [kind.to_s, path],
          "offset" => view[:offset]
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
        @editor_explorer[:paths] = paths
      end

      def toggle_editor_explorer
        restore_editor_explorer unless @editor_explorer
        @editor_explorer.delete(:motion_prefix)
        clear_editor_explorer_search
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
        return unless path

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
        activate_editor_buffer(state, retain_current: !@editor_state.workspace_only?)
      rescue SystemCallError, ArgumentError
        editor_explorer_error("Could not open file")
      end

      def editor_explorer_error(message)
        @editor_state.status = message
        @editor_explorer[:focused] = false
        true
      end

      def editor_explorer_rows
        if (search = @editor_explorer[:search])
          active = editor_explorer_relative_path(@editor_state.path)
          return [{ label: "No matching files" }] if search[:paths].empty?

          return search[:paths].map do |path|
            { key: [:file, path], prefix: project_browser_icon(path: path.scrub), label: path, active: path == active }
          end
        end

        buffers = ([@editor_state] + retained_editor_buffers).reject(&:workspace_only?).sort_by(&:path).map do |state|
          path = editor_explorer_relative_path(state.path) || state.path
          icon = project_browser_icon(path: path.scrub)
          { key: [:buffer, state.path], prefix: icon, label: "#{path}#{' *' if state.dirty?}",
            active: state.equal?(@editor_state), state: state }
        end
        active_path = editor_explorer_relative_path(@editor_state.path)
        tree = @editor_explorer[:tree].rows(@editor_explorer[:expanded]).map do |row|
          kind = row[:directory] ? :directory : :file
          prefix = row[:directory] ? (row[:expanded] ? "▾ " : "▸ ") : "  "
          icon = project_browser_icon(path: row[:path].scrub, directory: row[:directory])
          depth = row[:depth]
          indent = if depth > EXPLORER_MAX_INDENT_DEPTH
                     "  " * (EXPLORER_MAX_INDENT_DEPTH - 1) + "… "
                   else
                     "  " * depth
                   end
          { key: [kind, row[:path]], prefix: "#{indent}#{prefix}#{icon}", label: row[:name], expanded: row[:expanded], active: kind == :file && row[:path] == active_path }
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
        title = colored(EXPLORER_TOGGLE, heading)
        if (search = @editor_explorer[:search])
          marker = search[:direction] == :down ? "/" : "?"
          title += " #{marker}#{search[:query]}"
        end
        lines = [editor_pane_top_border(title, width)]
        [height - 2, 0].max.times do |index|
          row = rows[index]
          label = editor_explorer_row_label(row, columns: columns)
          selected = row && row[:key] && row[:key] == @editor_explorer[:selected] && @editor_explorer[:focused]
          text = visible_ljust(visible_truncate(label, columns), columns)
          text = "#{TerminalSequences::SGR_INVERSE}#{text}#{TerminalSequences::SGR_INVERSE_OFF}" if selected
          lines << box_content_row(text, columns)
        end
        lines << bottom_border(width) if height > 1
        lines
      end

      def editor_explorer_row_label(row, columns: nil)
        return "" unless row

        prefix = "#{row[:active] ? '•' : ' '} #{row[:prefix]}"
        label = ANSI.strip(row[:label].scrub).gsub(/[[:cntrl:]]/, " ")
        return prefix + label unless columns && row[:key]

        offset = @editor_explorer[:horizontal_offset].to_i
        return TerminalText.drop_cells(prefix + label, offset) if offset.positive?

        prefix + TerminalText.truncate_middle(label, columns - TerminalText.width(prefix))
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
          @editor_explorer[:search][:editing] = false if @editor_explorer[:search]
          open_editor_explorer_file(path, state: row[:state])
          @editor_explorer[:focused] = false if keyboard || editor_explorer_width.zero?
        end
        true
      end

      def handle_editor_explorer_mouse(event)
        return false unless editor_explorer_available?
        return false if @editor_mouse_dragging && (event[:drag] || event[:release])

        @editor_explorer&.delete(:motion_prefix) if editor_explorer_click?(event)

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
          @editor_explorer.delete(:motion_prefix)
          if @editor_explorer.dig(:search, :editing)
            text = ANSI.strip(paste[:content].scrub).gsub(/[[:cntrl:]]/, " ")
            update_editor_explorer_query(@editor_explorer[:search][:query] + text)
          end
          queue_pending_keys(paste[:remaining])
          return true
        end
        return true if handle_bundled_key(key) { |token| handle_editor_key(token) }

        sequence = parse_csi_u_key(key)
        queue_pending_keys(sequence[:remaining]) if sequence && !sequence[:remaining].to_s.empty?
        return true if sequence&.[](:event_type) == 3

        name = { 13 => :enter, 27 => :escape }[sequence&.[](:code)] || key_name_for(key)
        return true if @editor_state.vibe? && handle_vibe_explorer_search(key, sequence, name)

        rows = editor_explorer_rows
        index = rows.index { |row| row[:key] && row[:key] == @editor_explorer[:selected] }
        return true if @editor_state.vibe? && handle_vibe_explorer_motion(key, sequence, rows, index)

        case name
        when :up, :down
          target = editor_explorer_step(rows, index, name)
          select_editor_explorer_row(rows, target)
        when :enter, :return
          editor_explorer_activate_row(rows[index], keyboard: true) if index
        when :escape
          @editor_explorer[:focused] = false
        end
        true
      end

      def handle_vibe_explorer_search(key, sequence, name)
        search = @editor_explorer[:search]
        text = sequence ? vibe_explorer_printable_key(sequence) : key
        if search && name == :escape
          clear_editor_explorer_search
        elsif search && search[:editing]
          case name
          when :return, :enter
            if search[:query].empty?
              clear_editor_explorer_search
            else
              search[:editing] = false
            end
          when :backspace, :delete
            delete_editor_explorer_query_character
          else
            if [8, 127].include?(sequence&.[](:code)) || ["\b", "\x7f"].include?(key)
              delete_editor_explorer_query_character
            elsif printable_key?(text)
              update_editor_explorer_query(search[:query] + text)
            end
          end
        elsif ["/", "?"].include?(text) && !@editor_explorer[:motion_prefix]
          origin = search ? search[:origin] : @editor_explorer.slice(:selected, :offset).merge(horizontal_offset: @editor_explorer[:horizontal_offset])
          @editor_explorer[:search] = { origin: origin, direction: text == "/" ? :down : :up, editing: true }
          update_editor_explorer_query("")
        elsif search && ["n", "N"].include?(text) && !@editor_explorer[:motion_prefix]
          rows = editor_explorer_rows
          index = rows.index { |row| row[:key] == @editor_explorer[:selected] }
          direction = search[:direction]
          direction = direction == :down ? :up : :down if text == "N"
          target = editor_explorer_step(rows, index, direction) || editor_explorer_step(rows, nil, direction)
          select_editor_explorer_row(rows, target)
        else
          return false
        end
        true
      end

      def delete_editor_explorer_query_character
        query = @editor_explorer[:search][:query]
        update_editor_explorer_query(query[0...TerminalText.previous_grapheme_boundary(query, query.length)])
      end

      def update_editor_explorer_query(query)
        search = @editor_explorer[:search]
        search[:query] = query[0, 512]
        needle = search[:query].downcase
        pattern = TextMatcher.subsequence_pattern(needle)
        kind, folder = search[:origin][:selected]
        prefix = "#{folder}/" if kind == :directory
        search[:paths] = @editor_explorer[:paths].select do |path|
          (!prefix || path.start_with?(prefix)) && TextMatcher.subsequence?(path.scrub.downcase, needle, pattern)
        end
        @editor_explorer[:selected] = nil
        @editor_explorer[:offset] = 0
        @editor_explorer[:horizontal_offset] = 0
        rows = editor_explorer_rows
        select_editor_explorer_row(rows, editor_explorer_step(rows, nil, search[:direction]))
      end

      def clear_editor_explorer_search
        return unless (search = @editor_explorer.delete(:search))

        @editor_explorer.merge!(search[:origin])
      end

      def editor_explorer_step(rows, index, direction)
        if direction == :up
          start = (index || rows.length) - 1
          start.downto(0).find { |candidate| rows[candidate][:key] }
        else
          start = index ? index + 1 : 0
          (start...rows.length).find { |candidate| rows[candidate][:key] }
        end
      end

      def select_editor_explorer_row(rows, index)
        return unless index

        @editor_explorer[:selected] = rows[index][:key]
        count = [editor_explorer_body_height - 2, 1].max
        @editor_explorer[:offset] = @editor_explorer[:offset].clamp([index - count + 1, 0].max, index)
      end

      def handle_vibe_explorer_motion(key, sequence, rows, index)
        motion = sequence ? vibe_explorer_printable_key(sequence) : key
        prefix = @editor_explorer.delete(:motion_prefix)
        if prefix == "z"
          return scroll_vibe_explorer(motion, rows, index)
        elsif prefix == "g" && motion == "g"
          select_editor_explorer_row(rows, editor_explorer_step(rows, nil, :down))
          @editor_explorer[:offset] = 0
          return true
        end

        case motion
        when "g", "z"
          @editor_explorer[:motion_prefix] = motion unless sequence&.[](:event_type) == 2
        when "j", "k"
          direction = motion == "j" ? :down : :up
          select_editor_explorer_row(rows, editor_explorer_step(rows, index, direction))
        when "G"
          select_editor_explorer_row(rows, editor_explorer_step(rows, nil, :up))
        when "H", "M", "L"
          select_vibe_explorer_viewport_row(motion, rows)
        when "h", "l"
          move_vibe_explorer_folder(motion, rows, index) if index
        else
          return false
        end
        true
      end

      def select_vibe_explorer_viewport_row(motion, rows)
        window = editor_explorer_window(rows, editor_explorer_body_height)
        entries = window.each_index.select { |index| window[index][:key] }
        target = case motion
                 when "H" then entries.first
                 when "M" then entries.min_by { |index| (index - window.length / 2).abs }
                 when "L" then entries.last
                 end
        select_editor_explorer_row(rows, @editor_explorer[:offset] + target) if target
      end

      def vibe_explorer_printable_key(sequence)
        modifiers = (sequence[:modifier] - 1) & ~192
        return unless [0, 1].include?(modifiers)

        text = csi_u_printable_text(sequence)
        return "?" if modifiers == 1 && text == "/"

        if modifiers == 1 && text&.match?(/\A[a-z]\z/)
          text.upcase
        else
          text
        end
      end

      def move_vibe_explorer_folder(motion, rows, index)
        row = rows[index]
        kind, path = row[:key]
        expanded = @editor_explorer[:expanded]
        if motion == "l"
          expanded.add(path) if kind == :directory
        elsif row[:expanded]
          expanded.delete(path)
        elsif kind != :buffer
          parent = [:directory, File.dirname(path)]
          select_editor_explorer_row(rows, rows.index { |candidate| candidate[:key] == parent })
        end
      end

      def scroll_vibe_explorer(motion, rows, index)
        case motion
        when "z", "t", "b"
          if index
            height = [editor_explorer_body_height - 2, 1].max
            above = { "z" => height / 2, "t" => 0, "b" => height - 1 }.fetch(motion)
            @editor_explorer[:offset] = index - above
          end
        when "h", "l", "H", "L"
          columns = [(editor_explorer_width.nonzero? || screen_width) - 4, 1].max
          step = motion == motion.upcase ? [columns / 2, 1].max : 1
          step = -step if motion.downcase == "h"
          widest = rows.filter_map { |row| TerminalText.width(editor_explorer_row_label(row)) if row[:key] }.max.to_i
          @editor_explorer[:horizontal_offset] = (@editor_explorer[:horizontal_offset].to_i + step).clamp(0, [widest - columns, 0].max)
        else
          return false
        end
        true
      end
    end
  end
end
