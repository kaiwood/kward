require "fileutils"
require "open3"
require "pathname"

require_relative "path_guard"

# Namespace for the Kward CLI agent runtime.
module Kward
  # Durable association between a session tab and a linked Git worktree.
  class GitWorktreeBinding
    FIELDS = %i[repository_root origin_root path branch base_revision active owned].freeze

    attr_accessor(*FIELDS)

    def initialize(repository_root:, origin_root:, path:, branch:, base_revision:, active: true, owned: true)
      @repository_root = repository_root.to_s
      @origin_root = origin_root.to_s
      @path = path.to_s
      @branch = branch.to_s
      @base_revision = base_revision.to_s
      @active = active != false
      @owned = owned != false
    end

    def active?
      active == true
    end

    def descriptor
      {
        "repository_root" => repository_root,
        "origin_root" => origin_root,
        "path" => path,
        "branch" => branch,
        "base_revision" => base_revision,
        "active" => active?,
        "owned" => owned != false
      }
    end

    def self.from_descriptor(value)
      data = value.respond_to?(:transform_keys) ? value.transform_keys(&:to_s) : {}
      required = %w[repository_root origin_root path branch base_revision]
      return nil unless required.all? { |key| !data[key].to_s.empty? }

      new(
        repository_root: data["repository_root"],
        origin_root: data["origin_root"],
        path: data["path"],
        branch: data["branch"],
        base_revision: data["base_revision"],
        active: data.fetch("active", true),
        owned: data.fetch("owned", true)
      )
    end
  end

  # Performs safe, structured operations on linked Git worktrees.
  class GitWorktreeManager
    class Error < StandardError; end

    WorktreeInfo = Struct.new(
      :path,
      :head,
      :branch,
      :detached,
      :locked,
      :prunable,
      keyword_init: true
    )

    GitStatus = Struct.new(:entries, keyword_init: true) do
      def clean?
        entries.empty?
      end

      def dirty?
        !clean?
      end
    end

    def repository_root(path)
      output = run_git(path, "rev-parse", "--show-toplevel")
      canonical_existing_path(output.strip)
    rescue Error
      raise Error, "Not a Git repository: #{path}"
    end

    def status(path)
      output = run_git(path, "status", "--porcelain=v1", "--untracked-files=all")
      GitStatus.new(entries: output.lines(chomp: true))
    end

    def current_revision(path)
      run_git(path, "rev-parse", "HEAD").strip
    end

    def create(repository_root:, origin_root:, path:, branch:, base: "HEAD")
      repository_root = canonical_existing_path(repository_root)
      origin_root = canonical_existing_path(origin_root)
      path = planned_path(path)
      branch = branch.to_s.strip
      base = base.to_s.strip
      validate_creation!(repository_root, origin_root, path, branch, base)

      run_git(repository_root, "worktree", "add", "-b", branch, path, base)
      GitWorktreeBinding.new(
        repository_root: repository_root,
        origin_root: origin_root,
        path: path,
        branch: branch,
        base_revision: revision_for(repository_root, base),
        active: true,
        owned: true
      )
    end

    def inspect(repository_root:, path:)
      repository_root = canonical_existing_path(repository_root)
      expected_path = planned_path(path)
      worktree = list(repository_root).find { |entry| same_path?(entry.path, expected_path) }
      raise Error, "Git worktree is not registered: #{expected_path}" unless worktree

      worktree
    end

    def list(repository_root)
      output = run_git(repository_root, "worktree", "list", "--porcelain")
      parse_worktree_list(output)
    end

    def remove(repository_root:, path:, force: false)
      repository_root = canonical_existing_path(repository_root)
      expected_path = planned_path(path)
      inspect(repository_root: repository_root, path: expected_path)
      arguments = ["worktree", "remove"]
      arguments << "--force" if force
      arguments << expected_path
      run_git(repository_root, *arguments)
      true
    end

    private

    def validate_creation!(repository_root, origin_root, path, branch, base)
      raise Error, "Worktree path must be outside the repository: #{path}" if PathGuard.inside?(path, repository_root)
      raise Error, "Worktree origin must be inside the repository: #{origin_root}" unless PathGuard.inside?(origin_root, repository_root)
      raise Error, "Branch name is required" if branch.empty?
      raise Error, "Base revision is required" if base.empty?
      raise Error, "Invalid branch name: #{branch}" unless git_succeeds?(repository_root, "check-ref-format", "--branch", branch)
      raise Error, "Invalid base revision: #{base}" unless valid_revision?(repository_root, base)
      raise Error, "Worktree path is a file: #{path}" if File.file?(path)
      raise Error, "Worktree path is not empty: #{path}" if File.directory?(path) && !Dir.empty?(path)
      raise Error, "Worktree path is already registered: #{path}" if list(repository_root).any? { |entry| same_path?(entry.path, path) }

      FileUtils.mkdir_p(File.dirname(path))
    end

    def valid_revision?(repository_root, revision)
      return false if revision.start_with?("-") || revision.match?(/\s/)

      git_succeeds?(repository_root, "rev-parse", "--verify", "#{revision}^{commit}")
    end

    def revision_for(repository_root, revision)
      run_git(repository_root, "rev-parse", "--verify", "#{revision}^{commit}").strip
    end

    def parse_worktree_list(output)
      output.split(/\n\n+/).filter_map do |block|
        fields = block.lines(chomp: true).each_with_object({}) do |line, values|
          key, value = line.split(" ", 2)
          values[key] = value.to_s unless key.nil? || key.empty?
        end
        path = fields["worktree"]
        next if path.to_s.empty?

        branch = fields["branch"].to_s.delete_prefix("refs/heads/")
        WorktreeInfo.new(
          path: path,
          head: fields["HEAD"].to_s,
          branch: branch.empty? ? nil : branch,
          detached: fields.key?("detached"),
          locked: fields.key?("locked"),
          prunable: fields.key?("prunable")
        )
      end
    end

    def run_git(root, *arguments)
      output, status = Open3.capture2e("git", "-C", root.to_s, *arguments)
      return output if status.success?

      message = output.to_s.strip
      message = "git #{arguments.join(" ")} failed" if message.empty?
      raise Error, message
    rescue Errno::ENOENT => e
      raise Error, e.message
    end

    def git_succeeds?(root, *arguments)
      _output, status = Open3.capture2e("git", "-C", root.to_s, *arguments)
      status.success?
    rescue Errno::ENOENT
      false
    end

    def canonical_existing_path(path)
      File.realpath(path.to_s)
    rescue Errno::ENOENT, Errno::ENOTDIR
      raise Error, "Path does not exist: #{path}"
    end

    def planned_path(path)
      expanded = Pathname.new(path.to_s).expand_path
      return File.realpath(expanded.to_s) if File.exist?(expanded.to_s)

      ancestor = expanded
      ancestor = ancestor.parent until File.exist?(ancestor.to_s) || ancestor == ancestor.parent
      canonical_ancestor = Pathname.new(File.realpath(ancestor.to_s))
      canonical_ancestor.join(expanded.relative_path_from(ancestor)).to_s
    rescue ArgumentError, Errno::ENOENT, Errno::ENOTDIR
      raise Error, "Invalid worktree path: #{path}"
    end

    def same_path?(left, right)
      planned_path(left) == planned_path(right)
    end
  end
end
