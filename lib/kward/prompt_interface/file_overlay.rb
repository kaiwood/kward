require_relative "../text_matcher"

# Namespace for the Kward CLI agent runtime.
module Kward
  # File-mention completion overlay behavior.
  class PromptInterface
    # Composer @file mention overlay support.
    module FileOverlay
      private

      FILE_MENTION_RESULT_LIMIT = 200

      def reset_file_selection
        @file_selection_index = 0
      end

      def dismiss_file_overlay
        return false unless file_overlay_visible?

        if file_open_overlay_visible?
          @file_open_dismissed_token = active_file_open_token
          @file_editor_open_status = nil
        else
          @file_overlay_dismissed_token = active_file_mention_token
        end
        reset_file_selection
        true
      end

      def file_overlay_visible?
        file_open_overlay_visible? || file_mention_overlay_visible?
      end

      def file_mention_overlay_visible?
        token = active_file_mention_token
        return false unless token
        return false if @file_overlay_dismissed_token == token

        true
      end

      def file_open_overlay_visible?
        token = active_file_open_token
        return false unless token
        return false if @file_open_dismissed_token == token

        true
      end

      def active_file_mention_token
        mention = active_file_mention
        return nil unless mention

        mention[:token]
      end

      def active_file_mention
        active_file_token("@")
      end

      def active_file_open_token
        open = active_file_open
        return nil unless open

        open[:token]
      end

      def active_file_open
        token = active_file_token("$")
        return nil unless token && token[:start].zero?

        token
      end

      def active_file_token(prefix)
        input = composer_input.to_s
        cursor = composer_cursor
        return nil if cursor.negative? || cursor > input.length

        before_cursor = input[0...cursor].to_s
        prefix_index = before_cursor.rindex(prefix)
        return nil unless prefix_index
        return nil if before_cursor[prefix_index...cursor].to_s.match?(/\s/)

        { start: prefix_index, finish: cursor, query: before_cursor[(prefix_index + 1)...cursor].to_s, token: before_cursor[prefix_index...cursor].to_s }
      end

      def file_overlay_matches
        token = active_file_open || active_file_mention
        return [] unless token
        unless @file_mention_paths
          start_file_mention_discovery_locked
          return []
        end

        query = token[:query].downcase
        entries = project_file_path_entries
        cache = @file_overlay_match_cache
        return cache[:matches] if cache && cache[:query] == query && cache[:entries].equal?(entries)

        pattern = TextMatcher.subsequence_pattern(query)
        matches = []
        entries.each do |entry|
          next unless TextMatcher.subsequence?(entry[:downcase], query, pattern)

          matches << entry[:path]
          break if matches.length >= FILE_MENTION_RESULT_LIMIT
        end
        @file_overlay_match_cache = { query: query, entries: entries, matches: matches }
        matches
      end

      def start_file_mention_discovery_locked
        root = prompt_workspace_root
        active_thread = @file_mention_discovery_thread
        return if active_thread&.alive? && @file_mention_discovery_root == root

        token = Object.new
        start = Queue.new
        @file_mention_discovery_root = root
        @file_mention_discovery_token = token
        worker = Thread.new do
          start.pop
          paths = discover_file_mention_paths(root)
          @mutex.synchronize do
            next unless @file_mention_discovery_token.equal?(token)

            @file_mention_discovery_thread = nil
            @file_mention_discovery_root = nil
            @file_mention_discovery_token = nil
            next unless root == prompt_workspace_root

            @file_mention_paths = paths
            @file_mention_path_entries_paths = nil
            @file_mention_path_entries = nil
            @file_overlay_match_cache = nil
            render_prompt_locked if @started && @asking && file_overlay_visible?
          end
        end
        worker.report_on_exception = false
        @file_mention_discovery_thread = worker
        start << true
      end

      def discover_file_mention_paths(root)
        ProjectFiles.list(root: root)
      end

      def finish_file_mention_discovery_locked
        root = prompt_workspace_root
        @file_mention_discovery_thread = nil
        @file_mention_discovery_root = nil
        @file_mention_discovery_token = nil
        @file_mention_paths = discover_file_mention_paths(root)
        @file_mention_path_entries_paths = nil
        @file_mention_path_entries = nil
        @file_overlay_match_cache = nil
      end

      def file_mention_discovery_loading?
        @file_mention_discovery_thread&.alive? && @file_mention_discovery_root == prompt_workspace_root
      end

      def project_file_paths(include_ignored: false)
        if include_ignored
          @project_browser_file_paths ||= discover_project_file_paths(include_ignored: true)
        else
          @file_mention_paths ||= discover_project_file_paths
        end
      end

      def project_file_path_entries
        paths = project_file_paths
        return @file_mention_path_entries if @file_mention_path_entries_paths.equal?(paths) && @file_mention_path_entries

        @file_mention_path_entries_paths = paths
        @file_mention_path_entries = paths.map { |path| { path: path, downcase: path.downcase } }
      end

      def discover_project_file_paths(include_ignored: false)
        paths = if include_ignored
                  git_project_file_paths(include_ignored: true)
                else
                  git_project_file_paths
                end
        paths = scanned_project_file_paths if paths.empty? && !git_project_repository?
        paths.reject { |path| path.empty? || path.end_with?("/") }.uniq.sort
      end

      def git_project_file_paths(include_ignored: false)
        return ProjectFiles.git_paths(prompt_workspace_root) unless include_ignored

        ProjectFiles.git_paths(prompt_workspace_root, include_ignored: true)
      end

      def git_project_repository?
        ProjectFiles.git_repository?(prompt_workspace_root)
      end

      def scanned_project_file_paths
        ProjectFiles.scanned_paths(prompt_workspace_root)
      end

      def selected_file_mention_path
        selected_file_overlay_path if file_mention_overlay_visible?
      end

      def selected_file_open_path
        selected_file_overlay_path if file_open_overlay_visible?
      end

      def selected_file_overlay_path
        return nil unless file_overlay_visible?

        finish_file_mention_discovery_locked unless @file_mention_paths
        matches = file_overlay_matches
        return nil if matches.empty?

        matches[[@file_selection_index, matches.length - 1].min]
      end

      def select_previous_file_mention
        matches = file_overlay_matches
        return if matches.empty?

        @file_selection_index = previous_list_selection_index(@file_selection_index, matches.length)
      end

      def select_next_file_mention
        matches = file_overlay_matches
        return if matches.empty?

        @file_selection_index = next_list_selection_index(@file_selection_index, matches.length)
      end

      def complete_selected_file_mention
        mention = active_file_mention
        path = selected_file_mention_path
        return false unless mention && path

        self.composer_input = composer_input[0...mention[:start]].to_s + "@#{path}" + composer_input[mention[:finish]..].to_s
        self.composer_cursor = mention[:start] + path.length + 1
        reset_file_selection
        true
      end

      def file_overlay_rows(width, height: screen_height)
        return [] unless file_overlay_visible?

        matches = file_overlay_matches
        if file_mention_discovery_loading?
          return overlay_card_rows("Files", [overlay_text_line("Loading project files…", :muted)], width)
        end
        if matches.empty?
          return overlay_card_rows("Files", [overlay_text_line("No matching files", :muted)], width)
        end

        visible = visible_file_overlay_matches(matches, height: height)
        start_index = visible[:start]
        lines = []
        lines << overlay_text_line(@file_editor_open_status, :muted) if @file_editor_open_status && file_open_overlay_visible?
        lines.concat(visible[:paths].each_with_index.map do |path, offset|
          index = start_index + offset
          overlay_choice_line(path, selected: index == @file_selection_index)
        end)
        overlay_card_rows(file_open_overlay_visible? ? "Open file" : "Files", lines, width)
      end

      def visible_file_overlay_matches(matches, height: screen_height)
        max_rows = max_overlay_list_rows(height)
        start = centered_list_window_start(@file_selection_index, matches.length, max_rows)
        { start: start, paths: matches[start, max_rows] || [] }
      end
    end
  end
end
