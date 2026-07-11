require "json"
require "set"
require_relative "../config_files"
require_relative "../private_file"

# Namespace for the Kward CLI agent runtime.
module Kward
  # Nested project file browser overlay behavior.
  class PromptInterface
    # Modal tree browser for project files.
    module ProjectBrowser
      PROJECT_BROWSER_ROOT = "".freeze
      PROJECT_BROWSER_RESULT_LIMIT = 200
      PROJECT_BROWSER_STATE_VERSION = 1
      PROJECT_BROWSER_FILENAME_ICONS = {
        ".gitignore" => "",
        "Gemfile" => "",
        "Rakefile" => "",
        "README" => "",
        "README.md" => "",
        "package.json" => ""
      }.freeze
      PROJECT_BROWSER_EXTENSION_ICONS = {
        "css" => "",
        "html" => "",
        "js" => "",
        "json" => "",
        "md" => "",
        "rb" => "",
        "sh" => "",
        "ts" => "",
        "yaml" => "",
        "yml" => ""
      }.freeze
      PROJECT_BROWSER_DIRECTORY_ICON = ""
      PROJECT_BROWSER_FILE_ICON = ""

      def open_project_browser
        @mutex.synchronize do
          open_project_browser_locked
          render_prompt_locked if @started && @asking
        end
        true
      end

      def open_project_browser_locked
        paths = project_file_paths
        saved_state = saved_project_browser_state
        @project_browser_state = {
          paths: paths,
          expanded: restored_project_browser_expanded_paths(paths, saved_state),
          selection_index: 0,
          search_active: false,
          query: ""
        }
        restore_project_browser_selection(saved_state["selected_path"])
        self.composer_input = ""
        self.composer_cursor = 0
        @pending_keys.clear
        @asking = true
      end

      private

      def project_browser_visible?
        !@project_browser_state.nil? && !editor_active?
      end

      def dismiss_project_browser
        return false unless project_browser_visible?

        persist_project_browser_state unless project_browser_search_active?
        @project_browser_state = nil
        true
      end

      def handle_project_browser_key(key)
        return true if handle_bundled_key(key) { |token| handle_project_browser_key(token) }

        csi_result = handle_project_browser_csi_u_key(key)
        return csi_result unless csi_result == false

        case key_name_for(key)
        when :return, :enter
          open_or_toggle_selected_project_browser_row
        when :backspace
          project_browser_delete_search_character
        when :ctrl_l
          redraw_screen_locked
        when :left
          collapse_selected_project_browser_row
        when :right
          expand_selected_project_browser_row
        when :up
          select_previous_project_browser_row
        when :down
          select_next_project_browser_row
        else
          handle_project_browser_raw_key(key)
        end
        true
      end

      def handle_project_browser_csi_u_key(key)
        sequence = parse_csi_u_key(key)
        return false unless sequence

        queue_pending_keys(sequence[:remaining]) if sequence[:remaining] && !sequence[:remaining].empty?
        case sequence[:code]
        when 13
          open_or_toggle_selected_project_browser_row
        when 27
          project_browser_escape
        when 8, 127
          project_browser_delete_search_character
        when 9
          return false if ctrl_modifier?(sequence[:modifier]) || alt_modifier?(sequence[:modifier]) || super_modifier?(sequence[:modifier])

          toggle_project_browser_search
        else
          text = csi_u_printable_text(sequence)
          return false unless text

          if text == "@"
            insert_selected_project_browser_mention
          elsif text == "/" && !project_browser_search_active?
            activate_project_browser_search
          elsif project_browser_search_active?
            project_browser_append_search(text)
          else
            return false
          end
        end
        true
      end

      def handle_project_browser_raw_key(key)
        case key
        when "\n", "\r"
          open_or_toggle_selected_project_browser_row
        when "\b", "\x7F"
          project_browser_delete_search_character
        when "\e"
          project_browser_escape
        when "@"
          insert_selected_project_browser_mention
        when "\t"
          toggle_project_browser_search
        when "/"
          activate_project_browser_search
        else
          project_browser_append_search(key) if project_browser_search_active? && printable_key?(key)
        end
      end

      def project_browser_escape
        if project_browser_search_active?
          deactivate_project_browser_search
        else
          dismiss_project_browser
        end
      end

      def toggle_project_browser_search
        project_browser_search_active? ? deactivate_project_browser_search : activate_project_browser_search
      end

      def activate_project_browser_search
        @project_browser_state[:search_active] = true
        @project_browser_state[:query] = ""
        @project_browser_state[:selection_index] = 0
        sync_project_browser_query_input
      end

      def deactivate_project_browser_search
        @project_browser_state[:search_active] = false
        @project_browser_state[:query] = ""
        sync_project_browser_query_input
        clamp_project_browser_selection
        persist_project_browser_state
      end

      def project_browser_append_search(key)
        @project_browser_state[:query] += key
        @project_browser_state[:selection_index] = 0
        sync_project_browser_query_input
      end

      def project_browser_delete_search_character
        return unless project_browser_search_active?
        return if @project_browser_state[:query].empty?

        @project_browser_state[:query] = @project_browser_state[:query][0...-1]
        sync_project_browser_query_input
        clamp_project_browser_selection
      end

      def sync_project_browser_query_input
        self.composer_input = project_browser_search_active? ? @project_browser_state[:query].to_s : ""
        self.composer_cursor = composer_input.length
      end

      def project_browser_search_active?
        @project_browser_state && @project_browser_state[:search_active]
      end

      def select_previous_project_browser_row
        rows = project_browser_visible_rows
        return if rows.empty?

        @project_browser_state[:selection_index] = previous_list_selection_index(@project_browser_state[:selection_index], rows.length)
        persist_project_browser_state unless project_browser_search_active?
      end

      def select_next_project_browser_row
        rows = project_browser_visible_rows
        return if rows.empty?

        @project_browser_state[:selection_index] = next_list_selection_index(@project_browser_state[:selection_index], rows.length)
        persist_project_browser_state unless project_browser_search_active?
      end

      def open_or_toggle_selected_project_browser_row
        row = selected_project_browser_row
        return false unless row

        if row[:directory]
          toggle_project_browser_directory(row[:path])
          true
        else
          persist_project_browser_state unless project_browser_search_active?
          @project_browser_restore_after_editor = true if open_editor(row[:path])
          true
        end
      end

      def expand_selected_project_browser_row
        row = selected_project_browser_row
        return false unless row&.fetch(:directory, false)

        @project_browser_state[:expanded].add(row[:path])
        persist_project_browser_state
        true
      end

      def collapse_selected_project_browser_row
        row = selected_project_browser_row
        return false unless row

        if row[:directory] && @project_browser_state[:expanded].include?(row[:path])
          @project_browser_state[:expanded].delete(row[:path]) unless row[:path] == PROJECT_BROWSER_ROOT
          clamp_project_browser_selection
          persist_project_browser_state
          true
        else
          select_project_browser_parent(row[:path])
        end
      end

      def toggle_project_browser_directory(path)
        expanded = @project_browser_state[:expanded]
        if expanded.include?(path)
          expanded.delete(path) unless path == PROJECT_BROWSER_ROOT
        else
          expanded.add(path)
        end
        clamp_project_browser_selection
        persist_project_browser_state
      end

      def select_project_browser_parent(path)
        parent = File.dirname(path.to_s)
        parent = PROJECT_BROWSER_ROOT if parent == "."
        rows = project_browser_visible_rows
        index = rows.index { |row| row[:directory] && row[:path] == parent }
        return unless index

        @project_browser_state[:selection_index] = index
        persist_project_browser_state unless project_browser_search_active?
      end

      def insert_selected_project_browser_mention
        row = selected_project_browser_row
        return false unless row && !row[:directory]

        persist_project_browser_state unless project_browser_search_active?
        self.composer_input = "@#{row[:path]}"
        self.composer_cursor = composer_input.length
        dismiss_project_browser
        true
      end

      def restore_project_browser_after_editor_close
        return unless @project_browser_restore_after_editor

        @project_browser_restore_after_editor = false
        unless @project_browser_state
          paths = project_file_paths
          saved_state = saved_project_browser_state
          @project_browser_state = {
            paths: paths,
            expanded: restored_project_browser_expanded_paths(paths, saved_state),
            selection_index: 0,
            search_active: false,
            query: ""
          }
          restore_project_browser_selection(saved_state["selected_path"])
        end
        sync_project_browser_query_input
        clamp_project_browser_selection
      end

      def project_browser_rows(width, height: screen_height)
        return [] unless project_browser_visible?

        rows = project_browser_visible_rows
        lines = []
        title = project_browser_title
        if rows.empty?
          lines << overlay_text_line(project_browser_empty_message, :muted)
        else
          visible = visible_project_browser_rows(rows, height: height)
          visible[:rows].each_with_index do |row, offset|
            index = visible[:start] + offset
            lines << overlay_choice_line(project_browser_row_text(row), selected: index == @project_browser_state[:selection_index])
          end
        end
        lines << overlay_blank_line
        lines << overlay_text_line(project_browser_help_text, :muted)
        overlay_card_rows(title, lines, width)
      end

      def project_browser_title
        query = @project_browser_state[:query].to_s
        project_browser_search_active? ? "Project files — Search: #{query}" : "Project files"
      end

      def project_browser_empty_message
        project_browser_search_active? ? "No matching files" : "No project files"
      end

      def project_browser_help_text
        if project_browser_search_active?
          "Type search • Esc tree • Enter open • @ mention"
        else
          "Enter open/toggle • ←/→ collapse/expand • Tab or / search • @ mention • Esc close"
        end
      end

      def project_browser_visible_rows
        return [] unless @project_browser_state
        return project_browser_search_rows if project_browser_search_active?

        tree = project_browser_tree
        directory_children = tree[:directories].fetch(PROJECT_BROWSER_ROOT, [])
        file_children = tree[:files].fetch(PROJECT_BROWSER_ROOT, [])
        rows = []
        append_project_browser_rows(rows, directory_children, file_children, tree, 0)
        rows
      end

      def append_project_browser_rows(rows, directories, files, tree, depth)
        directories.each do |directory|
          expanded = @project_browser_state[:expanded].include?(directory)
          rows << { path: directory, name: File.basename(directory), depth: depth, directory: true, expanded: expanded }
          next unless expanded

          append_project_browser_rows(
            rows,
            tree[:directories].fetch(directory, []),
            tree[:files].fetch(directory, []),
            tree,
            depth + 1
          )
        end
        files.each do |file|
          rows << { path: file, name: File.basename(file), depth: depth, directory: false }
        end
      end

      def project_browser_search_rows
        query = @project_browser_state[:query].downcase
        matches = []
        project_file_path_entries.each do |entry|
          next unless file_mention_match?(entry[:downcase], query)

          matches << { path: entry[:path], name: entry[:path], depth: 0, directory: false }
          break if matches.length >= PROJECT_BROWSER_RESULT_LIMIT
        end
        matches
      end

      def project_browser_tree
        paths = @project_browser_state[:paths]
        return @project_browser_tree if @project_browser_tree_paths.equal?(paths) && @project_browser_tree

        directories = Hash.new { |hash, key| hash[key] = Set.new }
        files = Hash.new { |hash, key| hash[key] = [] }
        paths.each do |path|
          parts = path.split("/")
          parent = PROJECT_BROWSER_ROOT
          parts[0...-1].each do |part|
            directory = parent.empty? ? part : "#{parent}/#{part}"
            directories[parent].add(directory)
            parent = directory
          end
          files[parent] << path
        end

        @project_browser_tree_paths = paths
        @project_browser_tree = {
          directories: directories.transform_values { |values| values.to_a.sort },
          files: files.transform_values(&:sort)
        }
      end

      def project_browser_row_text(row)
        indent = "  " * row[:depth]
        marker = if row[:directory]
                   row[:expanded] ? "▾ " : "▸ "
                 else
                   "  "
                 end
        icon = project_browser_icon(row)
        suffix = row[:directory] ? "/" : ""
        "#{indent}#{marker}#{icon}#{row[:name]}#{suffix}"
      end

      def project_browser_icon(row)
        return "" unless @project_browser_icon_theme == "nerd-font"

        icon = if row[:directory]
                 PROJECT_BROWSER_DIRECTORY_ICON
               else
                 project_browser_file_icon(row[:path])
               end
        "#{icon} "
      end

      def project_browser_file_icon(path)
        name = File.basename(path.to_s)
        PROJECT_BROWSER_FILENAME_ICONS[name] || PROJECT_BROWSER_EXTENSION_ICONS[File.extname(name).delete_prefix(".").downcase] || PROJECT_BROWSER_FILE_ICON
      end

      def saved_project_browser_state
        workspaces = read_project_browser_state_file["workspaces"]
        state = workspaces[project_browser_workspace_root] if workspaces.is_a?(Hash)
        state.is_a?(Hash) ? state : {}
      end

      def persist_project_browser_state
        return unless @project_browser_state

        data = read_project_browser_state_file
        workspaces = data["workspaces"].is_a?(Hash) ? data["workspaces"] : {}
        row = selected_project_browser_row
        workspaces[project_browser_workspace_root] = {
          "expanded" => @project_browser_state[:expanded].to_a.sort,
          "selected_path" => row && row[:path]
        }
        data["version"] = PROJECT_BROWSER_STATE_VERSION
        data["workspaces"] = workspaces
        PrivateFile.write_json(ConfigFiles.project_browser_state_path, data)
      rescue StandardError
        nil
      end

      def read_project_browser_state_file
        path = ConfigFiles.project_browser_state_path
        return { "version" => PROJECT_BROWSER_STATE_VERSION, "workspaces" => {} } unless File.exist?(path)

        data = JSON.parse(File.read(path))
        data.is_a?(Hash) ? data : { "version" => PROJECT_BROWSER_STATE_VERSION, "workspaces" => {} }
      rescue JSON::ParserError
        { "version" => PROJECT_BROWSER_STATE_VERSION, "workspaces" => {} }
      end

      def project_browser_workspace_root
        ConfigFiles.canonical_workspace_root(Dir.pwd)
      end

      def restored_project_browser_expanded_paths(paths, saved_state)
        directories = project_browser_directory_paths(paths)
        saved_expanded = saved_state["expanded"]
        expanded = if saved_expanded.is_a?(Array)
                     Set.new(saved_expanded.select { |path| directories.include?(path.to_s) })
                   else
                     default_project_browser_expanded_paths(paths)
                   end
        expanded.add(PROJECT_BROWSER_ROOT)
        expanded
      end

      def project_browser_directory_paths(paths)
        directories = Set.new([PROJECT_BROWSER_ROOT])
        paths.each do |path|
          parent = PROJECT_BROWSER_ROOT
          path.split("/")[0...-1].each do |part|
            parent = parent.empty? ? part : "#{parent}/#{part}"
            directories.add(parent)
          end
        end
        directories
      end

      def restore_project_browser_selection(path)
        rows = project_browser_visible_rows
        return @project_browser_state[:selection_index] = 0 if rows.empty?

        index = project_browser_selection_fallback_paths(path).filter_map do |candidate|
          rows.index { |row| row[:path] == candidate }
        end.first
        @project_browser_state[:selection_index] = index || 0
      end

      def project_browser_selection_fallback_paths(path)
        current = path.to_s
        candidates = []
        until current.empty? || current == "."
          candidates << current
          current = File.dirname(current)
        end
        candidates
      end

      def selected_project_browser_row
        rows = project_browser_visible_rows
        return nil if rows.empty?

        rows[[@project_browser_state[:selection_index], rows.length - 1].min]
      end

      def clamp_project_browser_selection
        rows = project_browser_visible_rows
        @project_browser_state[:selection_index] = 0 if rows.empty?
        @project_browser_state[:selection_index] = [[@project_browser_state[:selection_index], 0].max, rows.length - 1].min unless rows.empty?
      end

      def visible_project_browser_rows(rows, height: screen_height)
        max_rows = max_project_browser_rows(height)
        start = centered_list_window_start(@project_browser_state[:selection_index], rows.length, max_rows)
        { start: start, rows: rows[start, max_rows] || [] }
      end

      def max_project_browser_rows(height)
        [[height - 8, 4].max, 20].min
      end

      def default_project_browser_expanded_paths(paths)
        expanded = Set.new([PROJECT_BROWSER_ROOT])
        paths.each do |path|
          parts = path.split("/")
          parent = PROJECT_BROWSER_ROOT
          parts[0...-1].first(2).each do |part|
            parent = parent.empty? ? part : "#{parent}/#{part}"
            expanded.add(parent)
          end
        end
        expanded
      end
    end
  end
end
