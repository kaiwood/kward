require "bundler/gem_tasks"
require "fileutils"
require "html-proofer"
require "open3"
require "rdoc/task"
require "rubygems/package"
require "webrick"
require "yard"
require_relative "lib/kward/version"
require "yard/rake/yardoc_task"

DOCS_WATCH_GLOBS = [
  ".yardopts",
  "CHANGELOG.md",
  "LICENSE",
  "README.md",
  "doc/**/*.md",
  "lib/**/*.rb",
  "templates/**/*"
].freeze

def docs_watch_snapshot
  DOCS_WATCH_GLOBS.flat_map { |pattern| Dir.glob(pattern) }
                  .select { |path| File.file?(path) }
                  .uniq
                  .to_h { |path| [path, File.mtime(path)] }
end

def rebuild_docs
  system({ "DOCS_SERVE_REBUILD" => "1" }, "bundle", "exec", "rake", "docs:build") || abort("Documentation rebuild failed")
end

def packaged_gem_files(gem_name)
  gem = Gem::Package.new(gem_name)
  gem.spec.files.sort
end

def verify_release_metadata
  version = Kward::VERSION
  tag = "v#{version}"
  changelog = File.read("CHANGELOG.md")
  abort("CHANGELOG.md is missing a [#{version}] release heading") unless changelog.match?(/^## \[#{Regexp.escape(version)}\] - \d{4}-\d{2}-\d{2}$/)

  if ENV["GITHUB_REF_TYPE"] == "tag" && ENV["GITHUB_REF_NAME"] != tag
    abort("GitHub tag #{ENV["GITHUB_REF_NAME"]} does not match gem version #{version}")
  end

  tag_commit, tag_status = Open3.capture2e("git", "rev-parse", "--verify", "#{tag}^{commit}")
  return unless tag_status.success?

  head_commit = `git rev-parse HEAD`.strip
  abort("Tag #{tag} does not point at HEAD") unless tag_commit.strip == head_commit
end

def verify_packaged_gem(gem_name)
  files = packaged_gem_files(gem_name)
  required = ["exe/kward", "lib/kward/version.rb"]
  missing = required - files
  abort("Packaged gem is missing: #{missing.join(", ")}") unless missing.empty?

  forbidden_prefixes = [".github/", "script/", "test/", "plan/"]
  forbidden = files.select { |file| forbidden_prefixes.any? { |prefix| file.start_with?(prefix) } }
  abort("Packaged gem includes development files: #{forbidden.join(", ")}") unless forbidden.empty?

  files
end

def rewrite_yard_markdown_links
  guide_names = Dir.glob("doc/*.md").map { |path| File.basename(path, ".md") }

  Dir.glob("_yardoc/**/*.html").each do |path|
    html = File.read(path)
    rewritten = html.gsub(/href=(["'])(?:(?:\.\.\/)?doc\/)?([a-z0-9-]+)\.md(#[^"']*)?\1/) do |match|
      quote = Regexp.last_match(1)
      guide_name = Regexp.last_match(2)
      anchor = Regexp.last_match(3).to_s
      next match unless guide_names.include?(guide_name)

      "href=#{quote}file.#{guide_name}.html#{anchor}#{quote}"
    end

    File.write(path, rewritten) unless rewritten == html
  end
end

task default: :test

desc "Run the full test suite"
task :test do
  ruby "-Itest", "-e", 'Dir["test/**/test_*.rb"].sort.each { |file| require_relative file }'
end

RDoc::Task.new do |rdoc|
  rdoc.main = "README.md"
  rdoc.rdoc_dir = "rdoc"
  rdoc.rdoc_files.include("README.md", "CHANGELOG.md", "LICENSE", "doc/**/*.md", "lib/**/*.rb")
end

YARD::Rake::YardocTask.new do |yard|
  yard.files = ["lib/**/*.rb", "-", "README.md", "CHANGELOG.md", "LICENSE", "doc/**/*.md"]
  yard.options = [
    "--readme", "README.md",
    "--output-dir", "_yardoc",
    "--markup", "markdown",
    "--template-path", "templates"
  ]
end

namespace :release do
  desc "Verify the version, changelog, and release tag agree"
  task :verify do
    verify_release_metadata
  end

  desc "Run release checks and build a local gem"
  task preflight: ["release:verify", :test, "docs:check"] do
    gem_name = File.join("pkg", "kward-#{Kward::VERSION}.gem")
    FileUtils.rm_f(gem_name)
    Rake::Task["build"].invoke
    puts verify_packaged_gem(gem_name)
  end
end

Rake::Task["release:source_control_push"].enhance(["release:verify"])
Rake::Task["release:rubygem_push"].enhance(["release:verify"])

namespace :docs do
  desc "Serve the built YARD documentation site locally and rebuild on changes"
  task serve: :build do
    port = Integer(ENV.fetch("PORT", "8808"))
    server = WEBrick::HTTPServer.new(
      BindAddress: "127.0.0.1",
      DocumentRoot: File.expand_path("_yardoc", __dir__),
      Port: port
    )

    server.mount_proc "/" do |request, response|
      WEBrick::HTTPServlet::FileHandler.new(server, File.expand_path("_yardoc", __dir__)).service(request, response)
      response["Cache-Control"] = "no-store"
    end

    watcher = Thread.new do
      snapshot = docs_watch_snapshot

      loop do
        sleep 1
        current_snapshot = docs_watch_snapshot
        next if current_snapshot == snapshot

        snapshot = current_snapshot
        puts "Documentation changed; rebuilding _yardoc/. Refresh your browser when it finishes."
        rebuild_docs
        puts "Documentation rebuilt."
      rescue StandardError => error
        warn "Documentation rebuild failed: #{error.class}: #{error.message}"
      end
    end

    trap("INT") { server.shutdown }
    trap("TERM") { server.shutdown }

    puts "Serving documentation at http://localhost:#{port}/"
    puts "Watching documentation sources for changes. Refresh your browser after rebuilds."
    server.start
  ensure
    watcher&.kill
  end

  desc "Build the YARD documentation site"
  task build: :yard do
    rewrite_yard_markdown_links
    FileUtils.touch("_yardoc/.nojekyll")
  end

  desc "Check generated documentation links and images"
  task check: :build do
    options = {
      checks: ["Images", "Links", "Scripts"],
      allow_missing_href: true,
      disable_external: ENV["DOCS_CHECK_EXTERNAL"] != "1",
      enforce_https: false,
      ignore_urls: [/^$/]
    }

    HTMLProofer.check_directory("_yardoc", options).run
  end
end
