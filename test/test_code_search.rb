require_relative "test_helper"

class TestCodeSearch < KwardTestCase
  class FakeHttpClient
    attr_reader :json_urls, :text_urls, :headers

    def initialize(json: {}, text: {})
      @json = json
      @text = text
      @json_urls = []
      @text_urls = []
      @headers = []
    end

    def get_json(url, headers: {})
      @json_urls << url
      @headers << headers
      @json.fetch(url)
    end

    def get_text(url, headers: {})
      @text_urls << url
      @headers << headers
      @text.fetch(url)
    end
  end

  class FakeGitRunner
    attr_reader :calls

    def initialize
      @calls = []
    end

    def run(*args, chdir: nil)
      @calls << [args, chdir]
      if args.first == "clone"
        path = args.last
        FileUtils.mkdir_p(File.join(path, ".git"))
      end
      ""
    end
  end

  def test_package_search_reads_rubygems_source_url
    http = FakeHttpClient.new(json: {
      "https://rubygems.org/api/v1/gems/kward.json" => {
        "name" => "kward",
        "version" => "1.2.3",
        "info" => "A CLI agent.",
        "source_code_uri" => "https://github.com/example/kward"
      }
    })
    search = Kward::CodeSearch.new(http_client: http, git_runner: FakeGitRunner.new)

    result = search.call("action" => "package_search", "ecosystem" => "rubygems", "package" => "kward")

    assert_includes result, "# Package search"
    assert_includes result, "- Source: https://github.com/example/kward"
    assert_empty http.json_urls.grep(/api.github.com/)
  end

  def test_package_search_still_accepts_ecosystem_aliases
    http = FakeHttpClient.new(json: {
      "https://rubygems.org/api/v1/gems/kward.json" => {
        "name" => "kward",
        "source_code_uri" => "https://github.com/example/kward"
      }
    })
    search = Kward::CodeSearch.new(http_client: http, git_runner: FakeGitRunner.new)

    result = search.call("action" => "package_search", "ecosystem" => "gem", "package" => "kward")

    assert_includes result, "- Ecosystem: rubygems"
    assert_includes result, "- Source: https://github.com/example/kward"
  end

  def test_package_search_falls_back_to_github_when_source_missing
    http = FakeHttpClient.new(json: {
      "https://pypi.org/pypi/missing/json" => {
        "info" => { "name" => "missing", "version" => "0.1", "summary" => "No source metadata." }
      },
      "https://api.github.com/search/repositories?q=missing+pypi+source+repository&per_page=10" => {
        "items" => [{ "full_name" => "example/missing", "html_url" => "https://github.com/example/missing" }]
      }
    })
    search = Kward::CodeSearch.new(http_client: http, git_runner: FakeGitRunner.new)

    result = search.call("action" => "package_search", "ecosystem" => "pypi", "package" => "missing")

    assert_includes result, "- Source fallback: https://github.com/example/missing"
  end

  def test_repo_clone_uses_git_and_cache
    Dir.mktmpdir do |dir|
      git = FakeGitRunner.new
      search = Kward::CodeSearch.new(cache_root: dir, http_client: FakeHttpClient.new, git_runner: git)

      result = search.call("action" => "repo_clone", "repo" => "example/project")

      assert_includes result, "- Repository: example/project"
      assert_includes result, "- Status: cloned"
      assert_equal [["clone", "--depth", "1", "https://github.com/example/project.git", File.join(dir, "example__project")], nil], git.calls.first
    end
  end

  def test_git_runner_allows_nil_chdir
    Dir.mktmpdir do |dir|
      git_path = File.join(dir, "git")
      File.write(git_path, "#!/bin/sh\necho ok\n")
      File.chmod(0o755, git_path)

      with_env("PATH" => "#{dir}#{File::PATH_SEPARATOR}#{ENV["PATH"]}") do
        assert_equal "ok\n", Kward::CodeSearch::GitRunner.new.run("--version")
      end
    end
  end

  def test_refresh_cache_resets_cached_repo_to_fetched_head
    Dir.mktmpdir do |dir|
      repo = File.join(dir, "example__project")
      FileUtils.mkdir_p(File.join(repo, ".git"))
      git = FakeGitRunner.new
      search = Kward::CodeSearch.new(cache_root: dir, http_client: FakeHttpClient.new, git_runner: git)

      result = search.call("action" => "refresh_cache", "repo" => "example/project")

      assert_includes result, "# Repository refreshed"
      assert_equal [["fetch", "--depth", "1", "origin"], repo], git.calls[0]
      assert_equal [["reset", "--hard", "FETCH_HEAD"], repo], git.calls[1]
    end
  end

  def test_repo_search_returns_bounded_snippets_from_cached_repo
    Dir.mktmpdir do |dir|
      repo = File.join(dir, "example__project")
      FileUtils.mkdir_p(File.join(repo, ".git"))
      FileUtils.mkdir_p(File.join(repo, "lib"))
      File.write(File.join(repo, "lib", "thing.rb"), "before\nneedle here\nafter\n")
      search = Kward::CodeSearch.new(cache_root: dir, http_client: FakeHttpClient.new, git_runner: FakeGitRunner.new)

      result = search.call("action" => "repo_search", "repo" => "example/project", "query" => "needle", "context_lines" => 1)

      assert_includes result, "## lib/thing.rb:2"
      assert_includes result, "1: before"
      assert_includes result, "2: needle here"
      assert_includes result, "3: after"
    end
  end

  def test_repo_read_rejects_path_traversal
    Dir.mktmpdir do |dir|
      repo = File.join(dir, "example__project")
      FileUtils.mkdir_p(File.join(repo, ".git"))
      File.write(File.join(dir, "secret.txt"), "secret")
      search = Kward::CodeSearch.new(cache_root: dir, http_client: FakeHttpClient.new, git_runner: FakeGitRunner.new)

      result = search.call("action" => "repo_read", "repo" => "example/project", "path" => "../secret.txt")

      assert_equal "Error: path outside repository: ../secret.txt", result
    end
  end

  def test_repo_read_rejects_symlink_escape
    Dir.mktmpdir do |dir|
      repo = File.join(dir, "example__project")
      FileUtils.mkdir_p(File.join(repo, ".git"))
      File.write(File.join(dir, "secret.txt"), "needle secret")
      File.symlink(File.join(dir, "secret.txt"), File.join(repo, "leak.txt"))
      search = Kward::CodeSearch.new(cache_root: dir, http_client: FakeHttpClient.new, git_runner: FakeGitRunner.new)

      result = search.call("action" => "repo_read", "repo" => "example/project", "path" => "leak.txt")

      assert_equal "Error: path outside repository: leak.txt", result
    end
  end

  def test_repo_search_skips_symlink_escape
    Dir.mktmpdir do |dir|
      repo = File.join(dir, "example__project")
      FileUtils.mkdir_p(File.join(repo, ".git"))
      File.write(File.join(dir, "secret.txt"), "needle secret")
      File.symlink(File.join(dir, "secret.txt"), File.join(repo, "leak.txt"))
      search = Kward::CodeSearch.new(cache_root: dir, http_client: FakeHttpClient.new, git_runner: FakeGitRunner.new)

      result = search.call("action" => "repo_search", "repo" => "example/project", "query" => "needle")

      assert_equal "Error: no matches found in example/project", result
    end
  end

  def test_repo_read_synchronizes_cached_repository_before_reading
    Dir.mktmpdir do |dir|
      repo = File.join(dir, "example__project")
      FileUtils.mkdir_p(File.join(repo, ".git"))
      File.write(File.join(repo, "README.md"), "old\n")
      git = Class.new(FakeGitRunner) do
        def run(*args, chdir: nil)
          super
          File.write(File.join(chdir, "README.md"), "fresh\n") if args.first == "reset"
          args.first == "rev-parse" ? "abc123\n" : ""
        end
      end.new
      search = Kward::CodeSearch.new(cache_root: dir, http_client: FakeHttpClient.new, git_runner: git)

      result = search.call("action" => "repo_read", "repo" => "example/project", "path" => "README.md")

      assert_includes result, "- Revision: abc123"
      assert_includes result, "1: fresh"
      assert_equal "fetch", git.calls[0][0][0]
    end
  end

  def test_repo_read_infers_path_and_ref_from_blob_url
    Dir.mktmpdir do |dir|
      repo = File.join(dir, "example__project")
      FileUtils.mkdir_p(File.join(repo, ".git"))
      FileUtils.mkdir_p(File.join(repo, "doc"))
      File.write(File.join(repo, "doc", "guide.md"), "guide\n")
      search = Kward::CodeSearch.new(cache_root: dir, http_client: FakeHttpClient.new, git_runner: FakeGitRunner.new)

      result = search.call("action" => "repo_read", "repo" => "https://github.com/example/project/blob/main/doc/guide.md")

      assert_includes result, "- Path: doc/guide.md"
    end
  end

  def test_repo_read_returns_numbered_line_range
    Dir.mktmpdir do |dir|
      repo = File.join(dir, "example__project")
      FileUtils.mkdir_p(File.join(repo, ".git", "objects"))
      File.write(File.join(repo, "README.md"), "one\ntwo\nthree\n")
      search = Kward::CodeSearch.new(cache_root: dir, http_client: FakeHttpClient.new, git_runner: FakeGitRunner.new)

      result = search.call("action" => "repo_read", "repo" => "https://github.com/example/project", "path" => "README.md", "start_line" => 2, "line_count" => 1)

      assert_includes result, "- Path: README.md"
      assert_includes result, "2: two"
      refute_includes result, "1: one"
    end
  end

  def test_github_search_uses_optional_token
    http = FakeHttpClient.new(json: {
      "https://api.github.com/search/repositories?q=agent+rubygems+source+repository&per_page=3" => {
        "items" => [{ "full_name" => "example/agent", "html_url" => "https://github.com/example/agent", "description" => "Agent." }]
      }
    })
    search = Kward::CodeSearch.new(http_client: http, git_runner: FakeGitRunner.new)

    with_env("GITHUB_TOKEN" => "secret-token") do
      result = search.call("action" => "github_search", "query" => "agent", "ecosystem" => "rubygems", "max_results" => 3)
      assert_includes result, "example/agent"
    end

    assert_equal({ "Authorization" => "Bearer secret-token" }, http.headers.last)
  end

  def test_truncate_scrubs_partial_multibyte_character
    Dir.mktmpdir do |dir|
      repo = File.join(dir, "example__project")
      FileUtils.mkdir_p(File.join(repo, ".git"))
      File.write(File.join(repo, "README.md"), "ééé\n")
      search = Kward::CodeSearch.new(cache_root: dir, http_client: FakeHttpClient.new, git_runner: FakeGitRunner.new, max_output_bytes: 55)

      result = search.call("action" => "repo_read", "repo" => "example/project", "path" => "README.md")

      assert result.valid_encoding?
      assert_includes result, "... truncated ..."
    end
  end

  def test_git_errors_redact_token_and_cache_path
    Dir.mktmpdir do |dir|
      git = Class.new do
        def initialize(dir)
          @dir = dir
        end

        def run(*, chdir: nil)
          raise "failed in #{chdir || @dir} with secret-token"
        end
      end.new(dir)
      search = Kward::CodeSearch.new(cache_root: dir, http_client: FakeHttpClient.new, git_runner: git)

      result = with_env("GITHUB_TOKEN" => "secret-token") do
        search.call("action" => "repo_clone", "repo" => "example/project")
      end

      refute_includes result, "secret-token"
      refute_includes result, dir
      assert_includes result, "[REDACTED]"
      assert_includes result, "[CACHE]"
    end
  end

  def test_cache_actions_list_and_clear_cached_repo
    Dir.mktmpdir do |dir|
      repo = File.join(dir, "example__project")
      FileUtils.mkdir_p(File.join(repo, ".git"))
      search = Kward::CodeSearch.new(cache_root: dir, http_client: FakeHttpClient.new, git_runner: FakeGitRunner.new)

      assert_includes search.call("action" => "list_cache"), "example__project"
      clear = search.call("action" => "clear_cache", "repo" => "example/project")

      assert_includes clear, "- Status: removed"
      refute Dir.exist?(repo)
    end
  end
end
