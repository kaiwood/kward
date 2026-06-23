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
        message = @prompt.git_commit_message(status)
        return if message.nil?

        result = run_busy_local_command_and_requeue(activity: "committing") do
          git_commit_all(git_root, message)
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

      def git_commit_all(root, message)
        add_output, add_status = Open3.capture2e("git", "add", "--all", chdir: root.to_s)
        return { success: false, output: add_output } unless add_status.success?

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
