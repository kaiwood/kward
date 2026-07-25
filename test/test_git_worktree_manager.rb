require "open3"
require_relative "test_helper"
require_relative "../lib/kward/git_worktree_manager"

class TestGitWorktreeManager < KwardTestCase
  def test_discovers_repository_and_reports_dirty_entries
    with_git_repository do |root|
      manager = Kward::GitWorktreeManager.new

      assert_equal File.realpath(root), manager.repository_root(root)
      assert manager.status(root).clean?

      File.write(File.join(root, "tracked.txt"), "changed\n")
      File.write(File.join(root, "untracked.txt"), "new\n")

      status = manager.status(root)
      assert status.dirty?
      assert_includes status.entries, " M tracked.txt"
      assert_includes status.entries, "?? untracked.txt"
    end
  end

  def test_creates_inspects_and_removes_a_worktree
    with_git_repository do |root|
      manager = Kward::GitWorktreeManager.new
      parent = Dir.mktmpdir("kward-worktree-parent")
      path = File.join(parent, "linked")

      binding = manager.create(
        repository_root: root,
        origin_root: root,
        path: path,
        branch: "kward/example"
      )

      assert_equal File.realpath(root), binding.repository_root
      assert_equal File.realpath(root), binding.origin_root
      assert_equal File.realpath(path), binding.path
      assert_equal "kward/example", binding.branch
      assert_equal binding.branch, git("branch", "--show-current", chdir: path).strip
      assert_equal binding.base_revision, git("rev-parse", "HEAD", chdir: path).strip

      info = manager.inspect(repository_root: root, path: path)
      assert_equal binding.path, info.path
      assert_equal binding.branch, info.branch
      refute info.detached

      manager.remove(repository_root: root, path: path)

      refute File.exist?(path)
      assert_equal "kward/example", git("branch", "--list", "kward/example", chdir: root).strip
    ensure
      FileUtils.remove_entry(parent) if parent && Dir.exist?(parent)
    end
  end

  def test_refuses_to_remove_a_dirty_worktree
    with_git_repository do |root|
      manager = Kward::GitWorktreeManager.new
      parent = Dir.mktmpdir("kward-worktree-parent")
      path = File.join(parent, "linked")
      manager.create(repository_root: root, origin_root: root, path: path, branch: "kward/dirty")
      File.write(File.join(path, "untracked.txt"), "keep me\n")

      error = assert_raises(Kward::GitWorktreeManager::Error) do
        manager.remove(repository_root: root, path: path)
      end

      assert_match(/contains modified|untracked|clean/i, error.message)
      assert File.exist?(path)
    ensure
      FileUtils.remove_entry(parent) if parent && Dir.exist?(parent)
    end
  end

  def test_merges_a_worktree_branch_into_the_target_checkout
    with_git_repository do |root|
      manager = Kward::GitWorktreeManager.new
      parent = Dir.mktmpdir("kward-worktree-parent")
      path = File.join(parent, "linked")
      binding = manager.create(repository_root: root, origin_root: root, path: path, branch: "kward/merge")
      File.write(File.join(path, "feature.txt"), "feature\n")
      git("add", "feature.txt", chdir: path)
      git("commit", "-m", "add feature", chdir: path)

      result = manager.merge(repository_root: root, target_path: root, source_branch: binding.branch)

      assert result.merged?
      refute result.conflicted?
      assert_equal "kward/merge", manager.current_branch(path)
      assert_equal "feature\n", File.read(File.join(root, "feature.txt"))
      assert manager.status(root).clean?
    ensure
      FileUtils.remove_entry(parent) if parent && Dir.exist?(parent)
    end
  end

  def test_reports_conflicts_and_can_abort_a_merge
    with_git_repository do |root|
      manager = Kward::GitWorktreeManager.new
      parent = Dir.mktmpdir("kward-worktree-parent")
      path = File.join(parent, "linked")
      binding = manager.create(repository_root: root, origin_root: root, path: path, branch: "kward/conflict")
      File.write(File.join(path, "tracked.txt"), "feature change\n")
      git("add", "tracked.txt", chdir: path)
      git("commit", "-m", "feature change", chdir: path)
      File.write(File.join(root, "tracked.txt"), "target change\n")
      git("add", "tracked.txt", chdir: root)
      git("commit", "-m", "target change", chdir: root)

      result = manager.merge(repository_root: root, target_path: root, source_branch: binding.branch)

      assert result.conflicted?
      assert_equal ["tracked.txt"], result.conflicts
      assert manager.merge_in_progress?(root)
      manager.abort_merge(root)
      refute manager.merge_in_progress?(root)
      assert_equal "target change\n", File.read(File.join(root, "tracked.txt"))
    ensure
      FileUtils.remove_entry(parent) if parent && Dir.exist?(parent)
    end
  end

  def test_rejects_merge_when_one_is_already_in_progress
    with_git_repository do |root|
      manager = Kward::GitWorktreeManager.new
      parent = Dir.mktmpdir("kward-worktree-parent")
      path = File.join(parent, "linked")
      binding = manager.create(repository_root: root, origin_root: root, path: path, branch: "kward/conflict")
      File.write(File.join(path, "tracked.txt"), "feature change\n")
      git("add", "tracked.txt", chdir: path)
      git("commit", "-m", "feature change", chdir: path)
      File.write(File.join(root, "tracked.txt"), "target change\n")
      git("add", "tracked.txt", chdir: root)
      git("commit", "-m", "target change", chdir: root)
      manager.merge(repository_root: root, target_path: root, source_branch: binding.branch)

      error = assert_raises(Kward::GitWorktreeManager::Error) do
        manager.merge(repository_root: root, target_path: root, source_branch: binding.branch)
      end

      assert_match(/already in progress/, error.message)
    ensure
      manager.abort_merge(root) if manager&.merge_in_progress?(root)
      FileUtils.remove_entry(parent) if parent && Dir.exist?(parent)
    end
  end

  def test_rejects_a_worktree_inside_the_repository
    with_git_repository do |root|
      manager = Kward::GitWorktreeManager.new
      error = assert_raises(Kward::GitWorktreeManager::Error) do
        manager.create(
          repository_root: root,
          origin_root: root,
          path: File.join(root, "nested-worktree"),
          branch: "kward/nested"
        )
      end

      assert_match(/outside the repository/, error.message)
    end
  end

  private

  def with_git_repository
    Dir.mktmpdir("kward-git-repository") do |root|
      git("init", "-q", chdir: root)
      git("config", "user.email", "kward@example.test", chdir: root)
      git("config", "user.name", "Kward Test", chdir: root)
      File.write(File.join(root, "tracked.txt"), "initial\n")
      git("add", "tracked.txt", chdir: root)
      git("commit", "-m", "initial", chdir: root)
      yield root
    end
  end

  def git(*arguments, chdir:)
    output, status = Open3.capture2e("git", *arguments, chdir: chdir)
    flunk "git #{arguments.join(" ")} failed: #{output}" unless status.success?

    output
  end
end
