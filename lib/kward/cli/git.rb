require "open3"
require "pathname"

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

        previous_git_hook_conversation = @git_hook_conversation
        @git_hook_conversation = agent.conversation
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
      ensure
        @git_hook_conversation = previous_git_hook_conversation
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

        lines = output.lines.map(&:chomp)
        git_lifecycle_hook("git_status_after", root: root, payload: { status_count: lines.length })
        lines
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

        before = git_lifecycle_hook("git_diff_before", root: root, payload: { path: entry[:path], untracked: entry[:untracked] })
        if before.denied? || before.approval_required?
          return { path: entry[:path], content: "Declined: #{before.decision.message || "git diff denied"}\n" }
        end

        output = entry[:untracked] ? git_untracked_file_diff(root, entry[:path]) : git_tracked_file_diff(root, entry[:path])
        git_lifecycle_hook("git_diff_after", root: root, payload: { path: entry[:path], untracked: entry[:untracked], bytes: output.bytesize })
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

        action = entry[:staged] ? "unstage" : "stage"
        before = git_lifecycle_hook("git_stage_before", root: root, payload: { path: entry[:path], action: action })
        return if before.denied? || before.approval_required?

        command = entry[:staged] ? ["restore", "--staged", "--", entry[:path]] : ["add", "--", entry[:path]]
        output, status = Open3.capture2e("git", *command, chdir: root.to_s)
        git_lifecycle_hook("git_stage_after", root: root, payload: { path: entry[:path], action: action, success: status.success?, output: output })
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

      def git_commit_for_agent(root, message:, paths: nil)
        git_commit(root, message, paths: paths, stage_all: true, run_hooks: false)
      end

      def git_commit(root, message, paths: nil, stage_all: false, run_hooks: true)
        if run_hooks
          before = git_lifecycle_hook("git_commit_before", root: root, payload: { message: message.to_s })
          return { success: false, output: "Declined: #{before.decision.message || "git commit denied"}" } if before.denied? || before.approval_required?
        end

        return git_commit_staged(root, message, run_hooks: run_hooks) if !stage_all && paths.nil? && git_staged_changes?(root)

        add_arguments = ["git", "add", "--all"]
        add_arguments.concat(["--", *validated_git_commit_paths(root, paths)]) if paths
        add_output, add_status = Open3.capture2e(*add_arguments, chdir: root.to_s)
        return { success: false, output: add_output } unless add_status.success?

        git_commit_staged(root, message, run_hooks: run_hooks)
      rescue StandardError => e
        { success: false, output: e.message }
      end

      def validated_git_commit_paths(root, paths)
        Array(paths).map do |path|
          value = path.to_s
          expanded = File.expand_path(value, root.to_s)
          unless !value.empty? && !Pathname.new(value).absolute? && (expanded == root.to_s || expanded.start_with?("#{root}/"))
            raise ArgumentError, "Git commit path must be workspace-relative: #{value}"
          end

          value
        end
      end

      def git_staged_changes?(root)
        _output, status = Open3.capture2e("git", "diff", "--cached", "--quiet", chdir: root.to_s)
        !status.success?
      rescue StandardError
        false
      end

      def git_commit_staged(root, message, run_hooks: true)
        commit_output, commit_status = Open3.capture2e("git", "commit", "-m", message.to_s, chdir: root.to_s)
        result = { success: commit_status.success?, output: commit_output }
        if run_hooks
          git_lifecycle_hook("git_commit_after", root: root, payload: { message: message.to_s, success: result[:success], output: result[:output] })
        end
        result
      rescue StandardError => e
        { success: false, output: e.message }
      end

      def git_lifecycle_hook(name, root:, payload: {})
        conversation = @git_hook_conversation || new_conversation(workspace_root: root.to_s)
        run_lifecycle_hook(name, conversation: conversation, payload: { root: root.to_s }.merge(payload))
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
