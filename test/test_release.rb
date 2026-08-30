require_relative "test_helper"
require_relative "../script/release_support"

class TestRelease < KwardTestCase
  class UnpublishedRegistry
    def published?(_version)
      false
    end
  end

  class SimulatedReleaseRunner < Kward::Release::CommandRunner
    def initialize(root:, fail_preflight: false, **options)
      super(root: root, **options)
      @root = root
      @fail_preflight = fail_preflight
    end

    def run!(*command)
      case command
      when ["bundle", "lock", "--local"]
        version = Kward::Release::VersionFile.new(File.join(@root, "lib/kward/version.rb")).current
        lockfile = File.join(@root, "Gemfile.lock")
        File.write(lockfile, File.read(lockfile).gsub(/kward \([^\)]+\)/, "kward (#{version})"))
      when ["bundle", "exec", "rake", "release:preflight"]
        raise Kward::Release::Error, "Preflight failed" if @fail_preflight
      else
        super
      end
    end
  end

  def test_changelog_promotes_unreleased_notes
    content = <<~CHANGELOG
      # Changelog

      ## [Unreleased]

      ### Added

      - Added a release command.

      ## [1.2.2] - 2026-08-20

      ### Fixed

      - Fixed an older bug.
    CHANGELOG

    released = Kward::Release::Changelog.new(content).release("1.2.3", date: Date.new(2026, 8, 21))

    assert_includes released, <<~SECTION
      ## [Unreleased]

      ## [1.2.3] - 2026-08-21

      ### Added

      - Added a release command.
    SECTION
  end

  def test_changelog_extracts_release_notes
    changelog = Kward::Release::Changelog.new(<<~CHANGELOG)
      # Changelog

      ## [Unreleased]

      ## [1.2.3] - 2026-08-21

      ### Added

      - Added a release command.

      ## [1.2.2] - 2026-08-20

      - Fixed an older bug.
    CHANGELOG

    assert_equal <<~NOTES.strip, changelog.notes("1.2.3")
      ### Added

      - Added a release command.
    NOTES
  end

  def test_changelog_requires_unreleased_entries
    changelog = Kward::Release::Changelog.new(<<~CHANGELOG)
      # Changelog

      ## [Unreleased]

      ## [1.2.2] - 2026-08-20
    CHANGELOG

    error = assert_raises(Kward::Release::Error) do
      changelog.release("1.2.3", date: Date.new(2026, 8, 21))
    end

    assert_equal "CHANGELOG.md has no [Unreleased] entries", error.message
  end

  def test_version_file_reads_and_updates_only_the_assignment
    Dir.mktmpdir do |dir|
      path = File.join(dir, "version.rb")
      File.write(path, <<~RUBY)
        module Example
          # Current version.
          VERSION = "1.2.2"
        end
      RUBY
      version_file = Kward::Release::VersionFile.new(path)

      assert_equal "1.2.2", version_file.current
      assert_equal "1.2.2", version_file.update("1.2.3")
      assert_equal <<~RUBY, File.read(path)
        module Example
          # Current version.
          VERSION = "1.2.3"
        end
      RUBY
    end
  end

  def test_release_command_commits_tags_and_atomically_pushes_prepared_files
    Dir.mktmpdir do |dir|
      root = create_release_repository(dir)
      output = StringIO.new
      runner = SimulatedReleaseRunner.new(root: root, output: output)
      command = Kward::Release::Command.new(
        root: root,
        version: "1.2.3",
        date: Date.new(2026, 8, 21),
        output: output,
        runner: runner,
        registry: UnpublishedRegistry.new
      )

      stdout, stderr = capture_subprocess_io { command.run }

      assert_empty stdout
      assert_empty stderr
      assert_equal "1.2.3", Kward::Release::VersionFile.new(File.join(root, "lib/kward/version.rb")).current
      assert_includes File.read(File.join(root, "CHANGELOG.md")), "## [1.2.3] - 2026-08-21"
      assert_equal "Release v1.2.3", git!(root, "log", "-1", "--format=%s").strip
      assert_equal "tag", git!(root, "cat-file", "-t", "v1.2.3").strip
      assert_includes git!(root, "ls-remote", "--tags", "origin", "refs/tags/v1.2.3"), "refs/tags/v1.2.3"
      assert_includes output.string, "GitHub Actions will publish the gem"
    end
  end

  def test_release_command_restores_files_when_preflight_fails
    Dir.mktmpdir do |dir|
      root = create_release_repository(dir)
      original_files = Kward::Release::Command::RELEASE_FILES.to_h do |path|
        [path, File.read(File.join(root, path))]
      end
      output = StringIO.new
      runner = SimulatedReleaseRunner.new(root: root, output: output, fail_preflight: true)
      command = Kward::Release::Command.new(
        root: root,
        version: "1.2.3",
        date: Date.new(2026, 8, 21),
        output: output,
        runner: runner,
        registry: UnpublishedRegistry.new
      )

      error = assert_raises(Kward::Release::Error) { command.run }

      assert_equal "Preflight failed", error.message
      original_files.each do |path, content|
        assert_equal content, File.read(File.join(root, path))
      end
      assert_empty git!(root, "status", "--porcelain")
      assert_includes output.string, "Restored release files."
    end
  end

  def test_registry_verifies_the_published_artifact_checksum
    Dir.mktmpdir do |dir|
      path = File.join(dir, "kward-1.2.3.gem")
      File.write(path, "gem contents")
      registry = Class.new(Kward::Release::RubyGemsRegistry) do
        private

        def version_info(_version)
          { "sha" => Digest::SHA256.hexdigest("gem contents") }
        end
      end.new

      assert_nil registry.verify_artifact!("1.2.3", path)

      File.write(path, "different contents")
      assert_raises(Kward::Release::Error) do
        registry.verify_artifact!("1.2.3", path)
      end
    end
  end

  private

  def create_release_repository(directory)
    root = File.join(directory, "kward")
    origin = File.join(directory, "origin.git")
    FileUtils.mkdir_p(File.join(root, "lib/kward"))
    File.write(File.join(root, "lib/kward/version.rb"), "module Kward\n  VERSION = \"1.2.2\"\nend\n")
    File.write(File.join(root, "Gemfile.lock"), "    kward (1.2.2)\n")
    File.write(File.join(root, "CHANGELOG.md"), <<~CHANGELOG)
      # Changelog

      ## [Unreleased]

      ### Added

      - Added a release command.

      ## [1.2.2] - 2026-08-20
    CHANGELOG

    git!(root, "init", "--initial-branch=main")
    git!(root, "config", "user.name", "Release Test")
    git!(root, "config", "user.email", "release@example.com")
    git!(root, "add", ".")
    git!(root, "commit", "-m", "Initial")
    git!(directory, "init", "--bare", origin)
    git!(root, "remote", "add", "origin", origin)
    git!(root, "push", "--set-upstream", "origin", "main")
    root
  end

  def git!(directory, *arguments)
    stdout, stderr, status = Open3.capture3("git", *arguments, chdir: directory)
    raise "git #{arguments.join(" ")} failed: #{stderr}" unless status.success?

    stdout
  end
end
