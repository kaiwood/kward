require "open3"

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

        @file_overlay_dismissed_token = active_file_mention_token
        reset_file_selection
        true
      end

      def file_overlay_visible?
        token = active_file_mention_token
        return false unless token
        return false if @file_overlay_dismissed_token == token

        true
      end

      def active_file_mention_token
        mention = active_file_mention
        return nil unless mention

        mention[:token]
      end

      def active_file_mention
        input = composer_input.to_s
        cursor = composer_cursor
        return nil if cursor.negative? || cursor > input.length

        before_cursor = input[0...cursor].to_s
        at_index = before_cursor.rindex("@")
        return nil unless at_index
        return nil if before_cursor[at_index...cursor].to_s.match?(/\s/)

        { start: at_index, finish: cursor, query: before_cursor[(at_index + 1)...cursor].to_s, token: before_cursor[at_index...cursor].to_s }
      end

      def file_overlay_matches
        mention = active_file_mention
        return [] unless mention

        query = mention[:query].downcase
        matches = project_file_paths.select do |path|
          file_mention_match?(path.downcase, query)
        end
        matches.first(FILE_MENTION_RESULT_LIMIT)
      end

      def file_mention_match?(path, query)
        return true if query.empty?
        return true if path.include?(query)

        query_chars = query.chars
        query_chars.all? do |char|
          index = path.index(char)
          if index
            path = path[(index + 1)..].to_s
            true
          else
            false
          end
        end
      end

      def project_file_paths
        @file_mention_paths ||= discover_project_file_paths
      end

      def discover_project_file_paths
        paths = git_project_file_paths
        paths = scanned_project_file_paths if paths.empty?
        paths.reject { |path| path.empty? || path.end_with?("/") }.uniq.sort
      end

      def git_project_file_paths
        output, status = Open3.capture2("git", "ls-files", "--cached", "--others", "--exclude-standard", chdir: Dir.pwd)
        return [] unless status.success?

        output.lines.map(&:chomp).reject(&:empty?)
      rescue StandardError
        []
      end

      def scanned_project_file_paths
        root = Pathname.new(Dir.pwd)
        paths = []
        Find.find(root.to_s) do |path|
          relative = Pathname.new(path).relative_path_from(root).to_s
          if File.directory?(path)
            Find.prune if ignored_project_directory?(relative)
            next
          end

          paths << relative unless ignored_project_file?(relative)
        end
        paths
      rescue StandardError
        []
      end

      def ignored_project_directory?(relative)
        relative == "." || relative == ".git" || relative.start_with?(".git/")
      end

      def ignored_project_file?(relative)
        relative.start_with?(".git/")
      end

      def selected_file_mention_path
        return nil unless file_overlay_visible?

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
        if matches.empty?
          return overlay_card_rows("Files", [overlay_text_line("No matching files", :muted)], width)
        end

        visible = visible_file_overlay_matches(matches, height: height)
        start_index = visible[:start]
        lines = visible[:paths].each_with_index.map do |path, offset|
          index = start_index + offset
          overlay_choice_line(path, selected: index == @file_selection_index)
        end
        overlay_card_rows("Files", lines, width)
      end

      def visible_file_overlay_matches(matches, height: screen_height)
        max_rows = max_overlay_list_rows(height)
        start = centered_list_window_start(@file_selection_index, matches.length, max_rows)
        { start: start, paths: matches[start, max_rows] || [] }
      end
    end
  end
end
