require "open3"

# Namespace for the Kward CLI agent runtime.
module Kward
  # Command-line frontend that coordinates terminal interaction, sessions, tools, and model turns.
  class CLI
    # Interactive Git status and commit helpers.
    module GitCommands
      private

      def handle_git_command(agent)
        unless @prompt.respond_to?(:git_commit_message)
          runtime_output("/git is available in the interactive overlay only.")
          return
        end

        root = interactive_workspace_root(agent)
        git_root = git_repository_root(root)
        if git_root.empty?
          runtime_output("Not a Git repository: #{root}")
          return
        end

        status = git_status_lines(git_root)
        message = @prompt.git_commit_message(status) do |action|
          result = handle_git_prompt_action(git_root, status, action)
          status = result.is_a?(Hash) && result.key?(:status_lines) ? result[:status_lines] : result
          result
        end
        return if message.nil?

        result = run_busy_local_command_and_requeue(activity: "committing") do
          git_commit(git_root, message)
        end
        print_git_commit_result(result)
      end

      def git_repository_root(root)
        output, status = Open3.capture2e("git", "rev-parse", "--show-toplevel", chdir: root.to_s)
        return "" unless status.success?

        output.lines.first.to_s.strip
      rescue StandardError
        ""
      end

      def git_status_lines(root)
        output, status = Open3.capture2e("git", "status", "--short", "--untracked-files=normal", chdir: root.to_s)
        return ["Unable to read Git status: #{output.strip}"] unless status.success?

        output.lines.map(&:chomp)
      rescue StandardError => e
        ["Unable to read Git status: #{e.message}"]
      end

      def handle_git_prompt_action(root, current_status, action)
        case action[:action]
        when :toggle_stage
          toggle_git_stage(root, current_status[action[:index].to_i])
          git_status_lines(root)
        when :open_diff
          status_line = current_status[action[:index].to_i]
          { status_lines: git_status_lines(root), diff: git_diff_view(root, status_line) }
        else
          git_status_lines(root)
        end
      end

      def git_diff_view(root, status_line)
        entry = parse_git_status_line(status_line)
        return { path: "Git diff", content: "Unable to read Git status entry.\n" } if entry.nil?

        output = entry[:untracked] ? git_untracked_file_diff(root, entry[:path]) : git_tracked_file_diff(root, entry[:path])
        { path: entry[:path], content: output.empty? ? "No diff for #{entry[:path]}\n" : output }
      end

      def git_tracked_file_diff(root, path)
        output, status = Open3.capture2e("git", "diff", "HEAD", "--", path, chdir: root.to_s)
        status.success? ? output : "Unable to read diff for #{path}:\n#{output}"
      rescue StandardError => e
        "Unable to read diff for #{path}: #{e.message}\n"
      end

      def git_untracked_file_diff(root, path)
        full_path = File.expand_path(path, root.to_s)
        content = File.file?(full_path) ? File.read(full_path) : ""
        lines = ["diff --git a/#{path} b/#{path}", "new file mode 100644", "--- /dev/null", "+++ b/#{path}", "@@ -0,0 +1,#{content.lines.length} @@"]
        lines.concat(content.lines(chomp: true).map { |line| "+#{line}" })
        lines << "\\ No newline at end of file" if !content.empty? && !content.end_with?("\n")
        lines.join("\n") + "\n"
      rescue StandardError => e
        "Unable to read diff for #{path}: #{e.message}\n"
      end

      def toggle_git_stage(root, status_line)
        entry = parse_git_status_line(status_line)
        return if entry.nil?

        command = entry[:staged] ? ["restore", "--staged", "--", entry[:path]] : ["add", "--", entry[:path]]
        Open3.capture2e("git", *command, chdir: root.to_s)
      rescue StandardError
        nil
      end

      def parse_git_status_line(line)
        text = line.to_s
        return nil if text.length < 4

        status = text[0, 2]
        path = text[3..].to_s
        path = path.split(" -> ", 2).last if status.include?("R") || status.include?("C")
        return nil if path.empty?

        { path: path, staged: status[0] != " " && status[0] != "?", untracked: status == "??" }
      end

      def git_commit(root, message)
        return git_commit_staged(root, message) if git_staged_changes?(root)

        add_output, add_status = Open3.capture2e("git", "add", "--all", chdir: root.to_s)
        return { success: false, output: add_output } unless add_status.success?

        git_commit_staged(root, message)
      rescue StandardError => e
        { success: false, output: e.message }
      end

      def git_staged_changes?(root)
        _output, status = Open3.capture2e("git", "diff", "--cached", "--quiet", chdir: root.to_s)
        !status.success?
      rescue StandardError
        false
      end

      def git_commit_staged(root, message)
        commit_output, commit_status = Open3.capture2e("git", "commit", "-m", message.to_s, chdir: root.to_s)
        { success: commit_status.success?, output: commit_output }
      rescue StandardError => e
        { success: false, output: e.message }
      end

      def print_git_commit_result(result)
        output = result[:output].to_s.strip
        output = result[:success] ? "Commit created." : "Git commit failed." if output.empty?
        status = result[:success] ? "Git commit succeeded" : "Git commit failed"
        runtime_output("#{status}\n#{output}")
      end
    end
  end
end
