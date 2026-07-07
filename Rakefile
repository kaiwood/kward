require "fileutils"
require "html-proofer"
require "rdoc/task"
require "webrick"
require "yard"
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
