require "cgi/escape"
require "fileutils"
require "json"
require "net/http"
require "open3"
require "pathname"
require "uri"
require_relative "../../path_guard"
require_relative "../../config_files"
require_relative "web"

# Namespace for the Kward CLI agent runtime.
module Kward
  # Package lookup and GitHub repository cache/search implementation.
  class CodeSearch
    DEFAULT_MAX_RESULTS = 10
    MAX_MAX_RESULTS = 50
    DEFAULT_CONTEXT_LINES = 2
    DEFAULT_LINE_COUNT = 200
    MAX_LINE_COUNT = 400
    MAX_FILE_BYTES = 512 * 1024
    MAX_SCANNED_FILES = 5_000
    MAX_OUTPUT_BYTES = 16 * 1024
    HTTP_TIMEOUT_SECONDS = 10
    ECOSYSTEMS = %w[rubygems npm pypi crates go].freeze
    ACTIONS = %w[package_search github_search repo_clone repo_search repo_read list_cache refresh_cache clear_cache].freeze

    # Creates an object for code search and repository cache operations.
    def initialize(cache_root: nil, http_client: WebSearch::NetHttpClient.new(user_agent: "Kward code_search"), git_runner: GitRunner.new, max_output_bytes: MAX_OUTPUT_BYTES)
      @cache_root = File.expand_path(cache_root || ConfigFiles.code_search_cache_dir)
      @http_client = http_client
      @git_runner = git_runner
      @max_output_bytes = max_output_bytes
    end

    def call(args)
      action = value(args, "action").to_s
      return "Error: action must be one of: #{ACTIONS.join(", ")}" unless ACTIONS.include?(action)

      case action
      when "package_search" then package_search(args)
      when "github_search" then github_search_action(args)
      when "repo_clone" then repo_clone(args)
      when "repo_search" then repo_search(args)
      when "repo_read" then repo_read(args)
      when "list_cache" then list_cache
      when "refresh_cache" then refresh_cache(args)
      when "clear_cache" then clear_cache(args)
      end
    rescue StandardError => e
      "Error: code_search failed: #{redact(e.message)}"
    end

    # Git command adapter used by repository cache operations.
    class GitRunner
      def run(*args, chdir: nil)
        command = ["git", *args]
        stdout, stderr, status = chdir ? Open3.capture3(*command, chdir: chdir) : Open3.capture3(*command)
        raise "git #{args.join(" ")} failed: #{stderr.strip.empty? ? stdout.strip : stderr.strip}" unless status.success?

        stdout
      rescue Errno::ENOENT
        raise "git executable not found"
      end
    end

    private

    def package_search(args)
      ecosystem = normalize_ecosystem(value(args, "ecosystem"))
      return "Error: ecosystem must be one of: #{ECOSYSTEMS.join(", ")}" unless ecosystem

      package = value(args, "package") || value(args, "query")
      return "Error: package is required" if package.to_s.strip.empty?

      data = fetch_package(ecosystem, package.to_s.strip)
      repo = normalize_github_url(data[:source_url])
      fallback = nil
      fallback = github_search(data[:name], ecosystem: ecosystem, max_results: bounded_max_results(value(args, "max_results"))).first unless repo

      lines = ["# Package search", "- Ecosystem: #{ecosystem}", "- Package: #{data[:name]}"]
      lines << "- Version: #{data[:version]}" if data[:version]
      lines << "- Description: #{data[:description]}" if data[:description]
      if repo
        lines << "- Source: #{repo[:html_url]}"
      elsif fallback
        lines << "- Source fallback: #{fallback[:html_url]}"
        lines << "- Note: registry metadata did not include a public GitHub source URL; returned a GitHub search result."
      else
        lines << "- Source: not found"
      end
      truncate(lines.join("\n"))
    end

    def github_search_action(args)
      query = value(args, "query") || value(args, "package")
      return "Error: query is required" if query.to_s.strip.empty?

      results = github_search(query.to_s.strip, ecosystem: normalize_ecosystem(value(args, "ecosystem")), max_results: bounded_max_results(value(args, "max_results")))
      return "Error: no GitHub repositories found" if results.empty?

      lines = ["# GitHub repository search"]
      results.each_with_index do |repo, index|
        lines << "#{index + 1}. #{repo[:full_name]} - #{repo[:html_url]}"
        lines << "   #{repo[:description]}" unless repo[:description].to_s.empty?
      end
      truncate(lines.join("\n"))
    end

    def repo_clone(args)
      repo = require_repo(args)
      return repo if repo.is_a?(String)

      path, created = ensure_repo(repo, refresh: false)
      "# Repository cached\n- Repository: #{repo[:full_name]}\n- Cache path: #{path}\n- Status: #{created ? "cloned" : "already cached"}"
    end

    def refresh_cache(args)
      repo = require_repo(args)
      return repo if repo.is_a?(String)

      path, = ensure_repo(repo, refresh: true)
      "# Repository refreshed\n- Repository: #{repo[:full_name]}\n- Cache path: #{path}"
    end

    def repo_search(args)
      repo = require_repo(args)
      return repo if repo.is_a?(String)
      query = value(args, "query").to_s
      return "Error: query is required" if query.strip.empty?

      path, = ensure_repo(repo, refresh: false)
      max_results = bounded_max_results(value(args, "max_results"))
      context = bounded_integer(value(args, "context_lines"), DEFAULT_CONTEXT_LINES, 0, 5)
      matches = search_files(path, query, max_results: max_results, context_lines: context)
      return "Error: no matches found in #{repo[:full_name]}" if matches.empty?

      lines = ["# Code search", "- Repository: #{repo[:full_name]}", "- Query: #{query}", ""]
      matches.each do |match|
        lines << "## #{match[:path]}:#{match[:line]}"
        lines << "```"
        lines.concat(match[:snippet])
        lines << "```"
      end
      truncate(lines.join("\n"))
    end

    def repo_read(args)
      repo = require_repo(args)
      return repo if repo.is_a?(String)
      file = value(args, "path") || value(args, "file")
      return "Error: path is required" if file.to_s.empty?

      root, = ensure_repo(repo, refresh: false)
      target = safe_existing_path(root, file.to_s)
      return "Error: path is not a file: #{file}" unless File.file?(target)
      return "Error: file is too large: #{file}" if File.size(target) > MAX_FILE_BYTES

      start_line = bounded_integer(value(args, "start_line"), 1, 1, 1_000_000)
      line_count = bounded_integer(value(args, "line_count"), DEFAULT_LINE_COUNT, 1, MAX_LINE_COUNT)
      lines = File.readlines(target, chomp: true)
      selected = lines.drop(start_line - 1).first(line_count)
      numbered = selected.each_with_index.map { |line, index| "#{start_line + index}: #{line}" }
      truncate((["# Code read", "- Repository: #{repo[:full_name]}", "- Path: #{file}", ""] + numbered).join("\n"))
    rescue ArgumentError => e
      "Error: #{e.message}"
    end

    def list_cache
      FileUtils.mkdir_p(@cache_root, mode: 0o700)
      entries = Dir.children(@cache_root).sort.select { |entry| File.directory?(File.join(@cache_root, entry, ".git")) }
      return "# Code search cache\nNo cached repositories." if entries.empty?

      lines = ["# Code search cache"]
      entries.each do |entry|
        lines << "- #{entry}"
      end
      lines.join("\n")
    end

    def clear_cache(args)
      repo = require_repo(args)
      return repo if repo.is_a?(String)

      path = cache_path(repo)
      return "# Cache clear\n- Repository: #{repo[:full_name]}\n- Status: not cached" unless inside_cache?(path) && Dir.exist?(path)

      FileUtils.rm_rf(path)
      "# Cache clear\n- Repository: #{repo[:full_name]}\n- Status: removed"
    end

    def fetch_package(ecosystem, package)
      case ecosystem
      when "rubygems"
        json = @http_client.get_json("https://rubygems.org/api/v1/gems/#{escape_path(package)}.json")
        { name: json["name"] || package, version: json["version"], description: json["info"], source_url: json["source_code_uri"] || json["homepage_uri"] || json["bug_tracker_uri"] }
      when "npm"
        json = @http_client.get_json("https://registry.npmjs.org/#{escape_path(package)}")
        latest = json.dig("dist-tags", "latest")
        version = latest && json.dig("versions", latest)
        repo = version&.dig("repository") || json["repository"]
        { name: json["name"] || package, version: latest, description: json["description"], source_url: repository_url(repo) || json["homepage"] }
      when "pypi"
        json = @http_client.get_json("https://pypi.org/pypi/#{escape_path(package)}/json")
        info = json["info"] || {}
        urls = info["project_urls"].is_a?(Hash) ? info["project_urls"].values : []
        { name: info["name"] || package, version: info["version"], description: info["summary"], source_url: ([info["project_url"], info["home_page"], *urls].find { |url| normalize_github_url(url) }) }
      when "crates"
        json = @http_client.get_json("https://crates.io/api/v1/crates/#{escape_path(package)}")
        crate = json["crate"] || {}
        { name: crate["id"] || package, version: crate["max_version"], description: crate["description"], source_url: crate["repository"] || crate["homepage"] }
      when "go"
        html = @http_client.get_text("https://pkg.go.dev/#{escape_path(package)}?tab=doc")
        { name: package, source_url: extract_github_url(html.to_s) }
      end
    end

    def github_search(query, ecosystem: nil, max_results: DEFAULT_MAX_RESULTS)
      search = [query, ecosystem, "source repository"].compact.join(" ")
      url = "https://api.github.com/search/repositories?q=#{CGI.escape(search)}&per_page=#{max_results}"
      json = @http_client.get_json(url, headers: github_headers)
      Array(json["items"]).filter_map do |item|
        full_name = item["full_name"].to_s
        next if full_name.empty?

        { full_name: full_name, html_url: item["html_url"], clone_url: item["clone_url"] || "https://github.com/#{full_name}.git", description: item["description"] }
      end
    end

    def ensure_repo(repo, refresh:)
      path = cache_path(repo)
      FileUtils.mkdir_p(@cache_root, mode: 0o700)
      if Dir.exist?(File.join(path, ".git"))
        if refresh
          @git_runner.run("fetch", "--depth", "1", "origin", chdir: path)
          @git_runner.run("reset", "--hard", "FETCH_HEAD", chdir: path)
        end
        return [path, false]
      end

      FileUtils.rm_rf(path) if Dir.exist?(path)
      @git_runner.run("clone", "--depth", "1", repo[:clone_url], path)
      [path, true]
    end

    def search_files(root, query, max_results:, context_lines:)
      matches = []
      base = File.realpath(root)
      scanned = 0
      Dir.glob(File.join(root, "**", "*"), File::FNM_DOTMATCH).sort.each do |path|
        next if matches.length >= max_results || scanned >= MAX_SCANNED_FILES
        next if skip_search_path?(base, path)

        scanned += 1
        match = first_file_match(path, query, context_lines)
        next unless match

        matches << {
          path: relative_path(root, path),
          line: match[:line],
          snippet: match[:snippet]
        }
      end
      matches
    end

    def skip_search_path?(base, path)
      return true unless File.file?(path)
      return true if File.symlink?(path)
      return true if path.include?("#{File::SEPARATOR}.git#{File::SEPARATOR}")
      return true unless inside_root?(base, File.realpath(path))
      return true if File.size(path) > MAX_FILE_BYTES

      false
    end

    def first_file_match(path, query, context_lines)
      previous = []
      line_number = 0
      File.open(path) do |file|
        while (line = file.gets&.chomp)
          line_number += 1
          if line.include?(query)
            match_line = line_number
            following = []
            context_lines.times do
              next_line = file.gets&.chomp
              break unless next_line

              line_number += 1
              following << "#{line_number}: #{next_line}"
            end
            return { line: match_line, snippet: previous + ["#{match_line}: #{line}"] + following }
          end

          previous << "#{line_number}: #{line}"
          previous.shift while previous.length > context_lines
        end
      end
      nil
    rescue ArgumentError, Encoding::InvalidByteSequenceError, Encoding::UndefinedConversionError
      nil
    end

    def require_repo(args)
      input = value(args, "repo") || value(args, "repository") || value(args, "url")
      repo = normalize_github_url(input)
      return repo if repo

      "Error: repo must be a GitHub repository URL or owner/name"
    end

    def normalize_github_url(input)
      text = input.to_s.strip
      return nil if text.empty?
      text = "https://github.com/#{text}" if text.match?(%r{\A[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\z})
      text = text.sub(%r{\Agit\+}, "")
      text = text.sub(%r{\Agit@github\.com:}, "https://github.com/")
      uri = URI(text)
      return nil unless uri.host.to_s.downcase == "github.com"

      parts = uri.path.sub(%r{\A/}, "").sub(%r{\.git\z}, "").split("/")
      return nil unless parts.length >= 2

      owner = parts[0]
      name = parts[1]
      return nil unless owner.match?(%r{\A[A-Za-z0-9_.-]+\z}) && name.match?(%r{\A[A-Za-z0-9_.-]+\z})

      full_name = "#{owner}/#{name}"
      { full_name: full_name, html_url: "https://github.com/#{full_name}", clone_url: "https://github.com/#{full_name}.git" }
    rescue URI::InvalidURIError
      nil
    end

    def cache_path(repo)
      key = repo[:full_name].downcase.gsub(%r{[^a-z0-9_.-]+}, "__")
      File.join(@cache_root, key)
    end

    def safe_join(root, path)
      raise ArgumentError, "path must be relative" if Pathname.new(path).absolute?

      base = File.realpath(root)
      target = File.expand_path(path, base)
      raise ArgumentError, "path outside repository: #{path}" unless inside_root?(base, target)

      target
    end

    def safe_existing_path(root, path)
      target = safe_join(root, path)
      return target unless File.exist?(target)

      real_target = File.realpath(target)
      raise ArgumentError, "path outside repository: #{path}" unless inside_root?(File.realpath(root), real_target)

      real_target
    end

    def inside_root?(root, path)
      PathGuard.inside?(path, root)
    end

    def inside_cache?(path)
      expanded = File.expand_path(path)
      expanded == @cache_root || expanded.start_with?(@cache_root + File::SEPARATOR)
    end

    def normalize_ecosystem(value)
      text = value.to_s.downcase
      text = "rubygems" if text == "ruby" || text == "gem"
      text = "pypi" if text == "python"
      text = "crates" if text == "rust" || text == "crates.io"
      ECOSYSTEMS.include?(text) ? text : nil
    end

    def bounded_max_results(value)
      bounded_integer(value, DEFAULT_MAX_RESULTS, 1, MAX_MAX_RESULTS)
    end

    def bounded_integer(value, default, min, max)
      integer = value.to_s.empty? ? default : value.to_i
      [[integer, min].max, max].min
    end

    def repository_url(value)
      return value["url"] || value[:url] if value.is_a?(Hash)

      value
    end

    def escape_path(value)
      value.to_s.split("/").map { |part| CGI.escape(part) }.join("/")
    end

    def extract_github_url(text)
      text[%r{https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(?:\.git)?}]
    end

    # Returns GitHub API headers, including an optional token when configured.
    def github_headers
      token = ENV["GITHUB_TOKEN"] || ENV["GH_TOKEN"]
      token.to_s.empty? ? {} : { "Authorization" => "Bearer #{token}" }
    end

    def value(args, key)
      return args[key] if args.respond_to?(:key?) && args.key?(key)
      return args[key.to_sym] if args.respond_to?(:key?) && args.key?(key.to_sym)

      nil
    end

    # Returns a cache file path relative to the cloned repository root.
    def relative_path(root, path)
      Pathname.new(path).relative_path_from(Pathname.new(root)).to_s
    end

    def truncate(text)
      return text if text.bytesize <= @max_output_bytes

      text.byteslice(0, @max_output_bytes).to_s.scrub + "\n... truncated ..."
    end

    def redact(message)
      text = message.to_s
      [ENV["GITHUB_TOKEN"], ENV["GH_TOKEN"]].each do |token|
        text = text.gsub(token, "[REDACTED]") unless token.to_s.empty?
      end
      text = text.gsub(@cache_root, "[CACHE]")
      text = text.gsub(Dir.home, "~") if Dir.respond_to?(:home)
      truncate(text)
    end
  end
end
