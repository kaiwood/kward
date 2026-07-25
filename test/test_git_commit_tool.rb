require "shellwords"
require_relative "test_helper"

class TestGitCommitTool < KwardTestCase
  def test_git_commit_tool_is_only_advertised_when_a_committer_is_configured
    without_git = Kward::ToolRegistry.new(web_search_enabled: false)
    assert_nil without_git.schemas.find { |schema| schema.dig(:function, :name) == "git_commit" }

    calls = []
    committer = lambda do |message:, paths:|
      calls << { message: message, paths: paths }
      { success: true, output: "[feature abc123] #{message}\n" }
    end
    registry = Kward::ToolRegistry.new(web_search_enabled: false, git_committer: committer)
    conversation = Kward::Conversation.new(system_message: nil)

    result = registry.dispatch(tool_call("git_commit", { message: "ship it", paths: ["doc/git.md"] }), conversation)

    assert_includes registry.schemas.map { |schema| schema.dig(:function, :name) }, "git_commit"
    assert_equal "Git commit succeeded\n[feature abc123] ship it", result
    assert_equal [{ message: "ship it", paths: ["doc/git.md"] }], calls
  end

  def test_git_commit_tool_validates_message_and_paths
    calls = 0
    committer = lambda do |**_arguments|
      calls += 1
      { success: true, output: "created" }
    end
    registry = Kward::ToolRegistry.new(web_search_enabled: false, git_committer: committer)
    conversation = Kward::Conversation.new(system_message: nil)

    assert_equal "Error: commit message is required", registry.dispatch(tool_call("git_commit", { message: " " }), conversation)
    assert_equal "Error: paths must be an array", registry.dispatch(tool_call("git_commit", { message: "ship", paths: "README.md" }), conversation)
    assert_equal 0, calls
  end

  def test_git_commit_tool_commits_changes_in_a_linked_worktree
    Dir.mktmpdir("kward-git-commit") do |parent|
      repository = File.join(parent, "repository")
      worktree = File.join(parent, "worktree")
      initialize_repository(repository)
      run_git(repository, "worktree", "add", "-q", "-b", "feature", worktree)
      File.write(File.join(worktree, "change.txt"), "change\n")

      cli = Kward::CLI.new(argv: [], stdin: StringIO.new, prompt: Object.new, client: Object.new)
      committer = ->(message:, paths:) { cli.send(:git_commit_for_agent, worktree, message: message, paths: paths) }
      registry = Kward::ToolRegistry.new(
        workspace: Kward::Workspace.new(root: worktree),
        web_search_enabled: false,
        git_committer: committer
      )
      conversation = Kward::Conversation.new(system_message: nil, workspace_root: worktree)

      result = registry.dispatch(tool_call("git_commit", { message: "agent commit", paths: ["change.txt"] }), conversation)

      assert_includes result, "Git commit succeeded"
      assert_equal "agent commit", `git -C #{Shellwords.escape(worktree)} log -1 --pretty=%s`.strip
      assert_empty `git -C #{Shellwords.escape(worktree)} status --short`.strip
    end
  end

  private

  def initialize_repository(path)
    FileUtils.mkdir_p(path)
    run_git(path, "init", "-q")
    run_git(path, "config", "user.email", "test@example.invalid")
    run_git(path, "config", "user.name", "Test")
    File.write(File.join(path, "README.md"), "base\n")
    run_git(path, "add", "README.md")
    run_git(path, "commit", "-qm", "initial")
  end

  def run_git(path, *arguments)
    success = system("git", "-C", path, *arguments, out: File::NULL, err: File::NULL)
    assert success, "git #{arguments.join(" ")} failed"
  end
end
