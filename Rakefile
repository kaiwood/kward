require "fileutils"
require "rdoc/task"
require "yard"
require "yard/rake/yardoc_task"

task default: :test

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
  desc "Serve the YARD documentation site locally with reloads"
  task :serve do
    port = ENV.fetch("PORT", "8808")
    sh "bundle exec yard server --reload --port #{port}"
  end

  desc "Build the YARD documentation site"
  task build: :yard do
    FileUtils.touch("_yardoc/.nojekyll")
  end
end
