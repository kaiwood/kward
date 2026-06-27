require "find"
require "open3"
require "pathname"

# Namespace for the Kward CLI agent runtime.
module Kward
  # Discovers project files for prompt UI features.
  module ProjectFiles
    module_function

    def list(root: Dir.pwd)
      paths = git_paths(root)
      paths = scanned_paths(root) if paths.empty?
      paths.reject { |path| path.empty? || path.end_with?("/") }.uniq.sort
    end

    def git_paths(root)
      output, status = Open3.capture2("git", "ls-files", "--cached", "--others", "--exclude-standard", chdir: root)
      return [] unless status.success?

      output.lines.map(&:chomp).reject(&:empty?)
    rescue StandardError
      []
    end

    def scanned_paths(root)
      root_path = Pathname.new(root)
      paths = []
      Find.find(root_path.to_s) do |path|
        relative = Pathname.new(path).relative_path_from(root_path).to_s
        if File.directory?(path)
          Find.prune if ignored_directory?(relative)
          next
        end

        paths << relative unless ignored_file?(relative)
      end
      paths
    rescue StandardError
      []
    end

    def ignored_directory?(relative)
      ignored_directories = %w[.git .yardoc _yardoc node_modules rdoc tmp vendor/bundle]
      ignored_directories.include?(relative) || relative.start_with?(".git/")
    end

    def ignored_file?(relative)
      relative.start_with?(".git/")
    end
  end
end
