task default: :test

task :test do
  ruby "-Itest", "-e", 'Dir["test/**/test_*.rb"].sort.each { |file| require_relative file }'
end
