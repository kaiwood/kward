require "shellwords"
require_relative "../test_helper"

class TestCLIGit < KwardTestCase
  class BusyPrompt < FakePrompt
    def initialize(inputs)
      super(inputs)
      @busy = false
    end

    def begin_busy_input(_message, activity: "streaming")
      @busy = true
    end

    def finish_busy_input
      @busy = false
    end

    def poll_input
      @inputs.shift
    end

    def start_stream_block(_label)
    end

    def write_delta(_delta)
    end

    def finish_stream_block
    end

    def close
    end
  end

  class GitPrompt < BusyPrompt
    attr_reader :git_status_lines, :action_results

    def initialize(message, actions: [])
      super(["/git", "/exit"])
      @message = message
      @actions = actions
      @git_status_lines = nil
      @action_results = []
    end

    def ask(_message)
      @inputs.shift
    end

    def git_commit_message(status_lines)
      @git_status_lines = status_lines
      @actions.each do |action|
        result = yield(action)
        @action_results << result
        @git_status_lines = result.is_a?(Hash) && result.key?(:status_lines) ? result[:status_lines] : result
      end
      @message
    end
  end

  def test_git_slash_command_commits_all_changes_when_nothing_is_staged
    Dir.mktmpdir do |dir|
      system("git", "init", chdir: dir, out: File::NULL, err: File::NULL)
      system("git", "config", "user.email", "test@example.com", chdir: dir)
      system("git", "config", "user.name", "Test User", chdir: dir)
      File.write(File.join(dir, "tracked.txt"), "old\n")
      system("git", "add", "tracked.txt", chdir: dir)
      system("git", "commit", "-m", "initial", chdir: dir, out: File::NULL, err: File::NULL)
      File.write(File.join(dir, "tracked.txt"), "new\n")
      File.write(File.join(dir, "untracked.txt"), "new\n")
      prompt = GitPrompt.new("ship changes")
      client = RecordingClient.new([])

      Dir.chdir(dir) do
        cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client)
        agent = Kward::Agent.new(client: client, tool_registry: Kward::ToolRegistry.new(prompt: prompt), conversation: Kward::Conversation.new(workspace_root: dir))
        cli.interactive_loop(agent: agent)
      end

      assert_includes prompt.git_status_lines, " M tracked.txt"
      assert_includes prompt.git_status_lines, "?? untracked.txt"
      assert_equal "ship changes", `git -C #{Shellwords.escape(dir)} log -1 --pretty=%s`.strip
      assert_empty `git -C #{Shellwords.escape(dir)} status --short`.strip
      assert_equal "new", File.read(File.join(dir, "tracked.txt")).strip
      assert_includes prompt.output.join("\n"), "Git commit succeeded"
    end
  end

  def test_git_slash_command_commits_staged_changes_when_any_file_is_staged
    Dir.mktmpdir do |dir|
      system("git", "init", chdir: dir, out: File::NULL, err: File::NULL)
      system("git", "config", "user.email", "test@example.com", chdir: dir)
      system("git", "config", "user.name", "Test User", chdir: dir)
      File.write(File.join(dir, "tracked.txt"), "old\n")
      system("git", "add", "tracked.txt", chdir: dir)
      system("git", "commit", "-m", "initial", chdir: dir, out: File::NULL, err: File::NULL)
      File.write(File.join(dir, "tracked.txt"), "new\n")
      File.write(File.join(dir, "untracked.txt"), "new\n")
      system("git", "add", "tracked.txt", chdir: dir)
      prompt = GitPrompt.new("ship staged")
      client = RecordingClient.new([])

      Dir.chdir(dir) do
        cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client)
        agent = Kward::Agent.new(client: client, tool_registry: Kward::ToolRegistry.new(prompt: prompt), conversation: Kward::Conversation.new(workspace_root: dir))
        cli.interactive_loop(agent: agent)
      end

      assert_equal "ship staged", `git -C #{Shellwords.escape(dir)} log -1 --pretty=%s`.strip
      assert_equal "?? untracked.txt", `git -C #{Shellwords.escape(dir)} status --short`.strip
      assert_equal "new", File.read(File.join(dir, "tracked.txt")).strip
    end
  end

  def test_git_diff_view_includes_working_tree_against_head
    Dir.mktmpdir do |dir|
      system("git", "init", chdir: dir, out: File::NULL, err: File::NULL)
      system("git", "config", "user.email", "test@example.com", chdir: dir)
      system("git", "config", "user.name", "Test User", chdir: dir)
      File.write(File.join(dir, "tracked.txt"), "old\n")
      system("git", "add", "tracked.txt", chdir: dir)
      system("git", "commit", "-m", "initial", chdir: dir, out: File::NULL, err: File::NULL)
      File.write(File.join(dir, "tracked.txt"), "new\n")
      prompt = GitPrompt.new(nil)
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: RecordingClient.new([]))

      diff = cli.send(:git_diff_view, dir, " M tracked.txt")

      assert_equal "tracked.txt", diff[:path]
      assert_includes diff[:content], "-old"
      assert_includes diff[:content], "+new"
    end
  end

  def test_git_slash_command_can_open_multiple_diffs_in_sequence
    Dir.mktmpdir do |dir|
      system("git", "init", chdir: dir, out: File::NULL, err: File::NULL)
      system("git", "config", "user.email", "test@example.com", chdir: dir)
      system("git", "config", "user.name", "Test User", chdir: dir)
      File.write(File.join(dir, "one.txt"), "old one\n")
      File.write(File.join(dir, "two.txt"), "old two\n")
      system("git", "add", "one.txt", "two.txt", chdir: dir)
      system("git", "commit", "-m", "initial", chdir: dir, out: File::NULL, err: File::NULL)
      File.write(File.join(dir, "one.txt"), "new one\n")
      File.write(File.join(dir, "two.txt"), "new two\n")
      prompt = GitPrompt.new(nil, actions: [{ action: :open_diff, index: 0 }, { action: :open_diff, index: 1 }])
      client = RecordingClient.new([])

      Dir.chdir(dir) do
        cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client)
        agent = Kward::Agent.new(client: client, tool_registry: Kward::ToolRegistry.new(prompt: prompt), conversation: Kward::Conversation.new(workspace_root: dir))
        cli.interactive_loop(agent: agent)
      end

      assert_equal 2, prompt.action_results.length
      second_diff = prompt.action_results.last[:diff]
      assert_equal "two.txt", second_diff[:path]
      refute_includes second_diff[:content], "Unable to read Git status entry"
      assert_includes second_diff[:content], "-old two"
      assert_includes second_diff[:content], "+new two"
    end
  end

  def test_git_diff_view_supports_untracked_files_as_added_diff
    Dir.mktmpdir do |dir|
      system("git", "init", chdir: dir, out: File::NULL, err: File::NULL)
      File.write(File.join(dir, "new.txt"), "hello\n")
      prompt = GitPrompt.new(nil)
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: RecordingClient.new([]))

      diff = cli.send(:git_diff_view, dir, "?? new.txt")

      assert_equal "new.txt", diff[:path]
      assert_includes diff[:content], "--- /dev/null"
      assert_includes diff[:content], "+++ b/new.txt"
      assert_includes diff[:content], "+hello"
    end
  end

  def test_git_slash_command_can_stage_selected_untracked_file
    Dir.mktmpdir do |dir|
      system("git", "init", chdir: dir, out: File::NULL, err: File::NULL)
      system("git", "config", "user.email", "test@example.com", chdir: dir)
      system("git", "config", "user.name", "Test User", chdir: dir)
      File.write(File.join(dir, "new.txt"), "new\n")
      prompt = GitPrompt.new("ship file", actions: [{ action: :toggle_stage, index: 0 }])
      client = RecordingClient.new([])

      Dir.chdir(dir) do
        cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client)
        agent = Kward::Agent.new(client: client, tool_registry: Kward::ToolRegistry.new(prompt: prompt), conversation: Kward::Conversation.new(workspace_root: dir))
        cli.interactive_loop(agent: agent)
      end

      assert_empty `git -C #{Shellwords.escape(dir)} status --short`.strip
      assert_equal "ship file", `git -C #{Shellwords.escape(dir)} log -1 --pretty=%s`.strip
    end
  end

  def test_git_slash_command_commits_all_after_unstaging_last_staged_file
    Dir.mktmpdir do |dir|
      system("git", "init", chdir: dir, out: File::NULL, err: File::NULL)
      system("git", "config", "user.email", "test@example.com", chdir: dir)
      system("git", "config", "user.name", "Test User", chdir: dir)
      File.write(File.join(dir, "file.txt"), "old\n")
      system("git", "add", "file.txt", chdir: dir)
      system("git", "commit", "-m", "initial", chdir: dir, out: File::NULL, err: File::NULL)
      File.write(File.join(dir, "file.txt"), "new\n")
      system("git", "add", "file.txt", chdir: dir)
      prompt = GitPrompt.new("ship all", actions: [{ action: :toggle_stage, index: 0 }])
      client = RecordingClient.new([])

      Dir.chdir(dir) do
        cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client)
        agent = Kward::Agent.new(client: client, tool_registry: Kward::ToolRegistry.new(prompt: prompt), conversation: Kward::Conversation.new(workspace_root: dir))
        cli.interactive_loop(agent: agent)
      end

      assert_equal "ship all", `git -C #{Shellwords.escape(dir)} log -1 --pretty=%s`.strip
      assert_empty `git -C #{Shellwords.escape(dir)} status --short`.strip
      assert_includes prompt.output.join("\n"), "Git commit succeeded"
    end
  end

  def test_git_slash_command_surfaces_blank_message_failure
    Dir.mktmpdir do |dir|
      system("git", "init", chdir: dir, out: File::NULL, err: File::NULL)
      system("git", "config", "user.email", "test@example.com", chdir: dir)
      system("git", "config", "user.name", "Test User", chdir: dir)
      File.write(File.join(dir, "file.txt"), "new\n")
      prompt = GitPrompt.new("")
      client = RecordingClient.new([])

      Dir.chdir(dir) do
        cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client)
        agent = Kward::Agent.new(client: client, tool_registry: Kward::ToolRegistry.new(prompt: prompt), conversation: Kward::Conversation.new(workspace_root: dir))
        cli.interactive_loop(agent: agent)
      end

      assert_includes prompt.output.join("\n"), "Git commit failed"
      refute_empty `git -C #{Shellwords.escape(dir)} status --short`.strip
    end
  end

end
