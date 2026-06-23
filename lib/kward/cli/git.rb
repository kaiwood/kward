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
          status = handle_git_prompt_action(git_root, status, action)
        end
        return if message.nil?

        result = run_busy_local_command_and_requeue(activity: "committing") do
          git_commit_staged(git_root, message)
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
        end
        git_status_lines(root)
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

        { path: path, staged: status[0] != " " && status[0] != "?" }
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
