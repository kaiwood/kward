require "rdoc/task"
require "yard"
require "yard/rake/yardoc_task"

task default: :test

task :test do
  ruby "-Itest", "-e", 'Dir["test/**/test_*.rb"].sort.each { |file| require_relative file }'
end

RDoc::Task.new do |rdoc|
  rdoc.main = "README.md"
  rdoc.rdoc_files.include("README.md", "CHANGELOG.md", "LICENSE", "doc/**/*.md", "lib/**/*.rb")
end

YARD::Rake::YardocTask.new do |yard|
  yard.files = ["README.md", "CHANGELOG.md", "LICENSE", "doc/**/*.md", "lib/**/*.rb"]
end
