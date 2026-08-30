require "date"
require "digest"
require "json"
require "net/http"
require "open3"
require "openssl"
require "rubygems"
require "shellwords"
require "uri"

module Kward
  module Release
    class Error < StandardError; end

    class Changelog
      VERSION_HEADING = /^## \[([^\]]+)\](?: - .*)?[ \t]*$/.freeze

      def initialize(content)
        @content = content
      end

      def release(version, date: Date.today)
        raise Error, "CHANGELOG.md already contains #{version}" if heading(version)

        unreleased = heading("Unreleased")
        raise Error, "CHANGELOG.md is missing an [Unreleased] heading" unless unreleased
        raise Error, "CHANGELOG.md has no [Unreleased] entries" unless notes_after(unreleased).match?(/^[ \t]*- /)

        released = @content.dup
        released.insert(unreleased.end(0), "\n\n## [#{version}] - #{date.iso8601}")
        released
      end

      def notes(version)
        version_heading = heading(version)
        raise Error, "CHANGELOG.md is missing a [#{version}] heading" unless version_heading

        notes_after(version_heading).strip
      end

      private

      def heading(version)
        @content.match(/^## \[#{Regexp.escape(version)}\](?: - .*)?[ \t]*$/)
      end

      def notes_after(version_heading)
        start = version_heading.end(0)
        following_heading = @content.match(VERSION_HEADING, start)
        finish = following_heading ? following_heading.begin(0) : @content.length
        @content[start...finish]
      end
    end

    class VersionFile
      VERSION_PATTERN = /^([ \t]*VERSION[ \t]*=[ \t]*)"([^"]+)"[ \t]*$/.freeze

      def initialize(path)
        @path = path
      end

      def current
        match = content.match(VERSION_PATTERN)
        raise Error, "#{relative_path} must contain exactly one VERSION assignment" unless match && content.scan(VERSION_PATTERN).one?

        match[2]
      end

      def update(version)
        previous = current
        updated = content.sub(VERSION_PATTERN) { "#{Regexp.last_match(1)}\"#{version}\"" }
        File.write(@path, updated)
        previous
      end

      private

      def content
        @content ||= File.read(@path)
      end

      def relative_path
        @path.to_s.sub(%r{\A#{Regexp.escape(Dir.pwd)}/?}, "")
      end
    end

    class RubyGemsRegistry
      ENDPOINT = "https://rubygems.org/api/v2/rubygems/kward/versions/%s.json".freeze

      def published?(version)
        !version_info(version).nil?
      end

      def verify_artifact!(version, path)
        info = version_info(version)
        raise Error, "kward #{version} is not published on RubyGems.org" unless info

        expected = info.fetch("sha")
        actual = Digest::SHA256.file(path).hexdigest
        return if actual == expected

        raise Error, "#{path} does not match the artifact published on RubyGems.org"
      end

      private

      def version_info(version)
        escaped_version = URI.encode_www_form_component(version)
        response = Net::HTTP.get_response(URI(format(ENDPOINT, escaped_version)))
        return JSON.parse(response.body) if response.is_a?(Net::HTTPSuccess)
        return nil if response.is_a?(Net::HTTPNotFound)

        raise Error, "RubyGems.org returned HTTP #{response.code} while checking #{version}"
      rescue EOFError, IOError, JSON::ParserError, OpenSSL::SSL::SSLError, SocketError, SystemCallError, Timeout::Error => error
        raise Error, "Could not check RubyGems.org: #{error.message}"
      end
    end

    class CommandRunner
      Result = Struct.new(:stdout, :stderr, :status, keyword_init: true)

      def initialize(root:, output: $stdout)
        @root = root
        @output = output
      end

      def capture(*command)
        stdout, stderr, status = Open3.capture3(*command, chdir: @root)
        Result.new(stdout: stdout, stderr: stderr, status: status)
      end

      def capture!(*command)
        result = capture(*command)
        return result.stdout if result.status.success?

        detail = [result.stdout, result.stderr].reject(&:empty?).join
        raise Error, "#{command.shelljoin} failed#{detail.empty? ? "" : ":\n#{detail}"}"
      end

      def run!(*command)
        @output.puts "$ #{command.shelljoin}"
        raise Error, "#{command.shelljoin} failed" unless run_command(*command)
      end

      private

      def run_command(*command)
        return system(*command, chdir: @root) if @output.equal?($stdout)

        stdout, stderr, status = Open3.capture3(*command, chdir: @root)
        @output.write(stdout)
        @output.write(stderr)
        status.success?
      end
    end

    class Command
      VERSION_FORMAT = /\A\d+\.\d+\.\d+(?:\.[0-9A-Za-z]+)*\z/.freeze
      RELEASE_FILES = ["CHANGELOG.md", "Gemfile.lock", "lib/kward/version.rb"].freeze

      def initialize(root:, version:, date: Date.today, output: $stdout, runner: nil, registry: RubyGemsRegistry.new)
        @root = File.expand_path(root)
        @version = version
        @date = date
        @output = output
        @runner = runner || CommandRunner.new(root: @root, output: output)
        @registry = registry
      end

      def run
        validate_version!
        validate_repository!
        validate_release!

        prepare_release_commit!

        @runner.run!("git", "tag", "-a", tag, "-m", "Release v#{@version}")
        @runner.run!("git", "push", "--atomic", "origin", "HEAD:main", "refs/tags/#{tag}")

        @output.puts
        @output.puts "Pushed #{tag}. GitHub Actions will publish the gem and create the GitHub Release."
      end

      private

      def prepare_release_commit!
        originals = RELEASE_FILES.to_h { |path| [path, File.binread(full_path(path))] }
        committed = false

        begin
          prepare_files!
          @runner.run!("bundle", "lock", "--local")
          @runner.run!("bundle", "exec", "rake", "release:preflight")
          validate_prepared_files!
          @runner.run!("git", "add", "--", *RELEASE_FILES)
          @runner.run!("git", "commit", "-m", "Release v#{@version}")
          committed = true
        ensure
          unless committed
            @runner.capture("git", "reset", "--quiet", "HEAD", "--", *RELEASE_FILES)
            restore_files(originals)
            @output.puts "Restored release files."
          end
        end
      end

      def validate_version!
        raise Error, "Version must look like 1.2.3 or 1.2.3.pre.1" unless @version&.match?(VERSION_FORMAT)
        raise Error, "Invalid RubyGems version: #{@version}" unless Gem::Version.correct?(@version)

        current = VersionFile.new(full_path("lib/kward/version.rb")).current
        return if Gem::Version.new(@version) > Gem::Version.new(current)

        raise Error, "Version #{@version} must be newer than #{current}"
      end

      def validate_repository!
        status = @runner.capture!("git", "status", "--porcelain", "--untracked-files=all")
        raise Error, "Git working tree must be clean" unless status.empty?

        branch = @runner.capture!("git", "branch", "--show-current").strip
        raise Error, "Releases must be prepared from main, not #{branch.empty? ? "a detached HEAD" : branch}" unless branch == "main"

        @runner.run!("git", "fetch", "--quiet", "origin", "main")
        head = @runner.capture!("git", "rev-parse", "HEAD").strip
        upstream = @runner.capture!("git", "rev-parse", "origin/main").strip
        raise Error, "Local main must match origin/main before releasing" unless head == upstream

        local_tag = @runner.capture("git", "rev-parse", "--verify", "--quiet", "refs/tags/#{tag}")
        raise Error, "Tag #{tag} already exists locally" if local_tag.status.success?

        remote_tag = @runner.capture("git", "ls-remote", "--exit-code", "--tags", "origin", "refs/tags/#{tag}")
        raise Error, "Tag #{tag} already exists on origin" if remote_tag.status.success?
        raise Error, "Could not check origin for #{tag}" unless remote_tag.status.exitstatus == 2
      end

      def validate_release!
        changelog = Changelog.new(File.read(full_path("CHANGELOG.md")))
        changelog.release(@version, date: @date)
        raise Error, "kward #{@version} is already published on RubyGems.org" if @registry.published?(@version)
      end

      def prepare_files!
        VersionFile.new(full_path("lib/kward/version.rb")).update(@version)

        changelog_path = full_path("CHANGELOG.md")
        changelog = Changelog.new(File.read(changelog_path))
        File.write(changelog_path, changelog.release(@version, date: @date))
      end

      def validate_prepared_files!
        version = VersionFile.new(full_path("lib/kward/version.rb")).current
        raise Error, "Version file was not updated to #{@version}" unless version == @version

        Changelog.new(File.read(full_path("CHANGELOG.md"))).notes(@version)
        @runner.capture!("git", "diff", "--check")

        changes = @runner.capture!("git", "status", "--porcelain", "--untracked-files=all")
                         .lines
                         .map { |line| line[3..].strip }
                         .sort
        return if changes == RELEASE_FILES.sort

        raise Error, "Release preparation changed unexpected files: #{changes.join(", ")}"
      end

      def restore_files(originals)
        originals.each { |path, content| File.binwrite(full_path(path), content) }
      end

      def full_path(path)
        File.join(@root, path)
      end

      def tag
        "v#{@version}"
      end
    end
  end
end
