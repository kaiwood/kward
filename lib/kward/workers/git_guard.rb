require "open3"

module Kward
  module Workers
    # Small git boundary used by write-lane workers to keep implementation work isolated.
    class GitGuard
      def initialize(root: Dir.pwd)
        @root = root.to_s
      end

      def repository?
        success?("rev-parse", "--is-inside-work-tree")
      end

      def clean?
        return true unless repository?

        status.empty?
      end

      def dirty?
        !clean?
      end

      def status
        run("status", "--porcelain").stdout
      end

      def head
        result = run("rev-parse", "--verify", "HEAD")
        result.success? ? result.stdout.strip : nil
      end

      def commit_all(message)
        add = run("add", "-A")
        return Result.new(success: false, stdout: add.stdout, stderr: add.stderr) unless add.success?

        commit = run("commit", "-m", message)
        return Result.new(success: false, stdout: commit.stdout, stderr: commit.stderr) unless commit.success?

        Result.new(success: true, stdout: commit.stdout, stderr: commit.stderr, commit: head)
      end

      def stash(message)
        before = stash_refs
        result = run("stash", "push", "--include-untracked", "-m", message)
        return Result.new(success: false, stdout: result.stdout, stderr: result.stderr) unless result.success?
        return Result.new(success: true, stdout: result.stdout, stderr: result.stderr) if result.stdout.include?("No local changes")

        ref = (stash_refs - before).first || stash_refs.first
        Result.new(success: true, stdout: result.stdout, stderr: result.stderr, commit: ref)
      end

      def apply_stash(ref)
        run("stash", "apply", ref.to_s)
      end

      def drop_stash(ref)
        run("stash", "drop", ref.to_s)
      end

      private

      Result = Struct.new(:success, :stdout, :stderr, :commit, keyword_init: true) do
        def success?
          success
        end

        def output
          [stdout, stderr].compact.reject(&:empty?).join("\n")
        end
      end

      def success?(*args)
        run(*args).success?
      end

      def stash_refs
        result = run("stash", "list", "--format=%gd")
        return [] unless result.success?

        result.stdout.lines.map(&:strip).reject(&:empty?)
      end

      def run(*args)
        stdout, stderr, status = Open3.capture3("git", "-C", @root, *args)
        Result.new(success: status.success?, stdout: stdout.to_s, stderr: stderr.to_s)
      rescue Errno::ENOENT
        Result.new(success: false, stdout: "", stderr: "git executable not found")
      end
    end
  end
end
