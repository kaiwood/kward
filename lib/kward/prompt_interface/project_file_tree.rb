require "set"

module Kward
  class PromptInterface
    # The filesystem-independent tree shared by /files and the editor Explorer.
    class ProjectFileTree
      def initialize(paths, directories: [])
        @directories = Hash.new { |hash, key| hash[key] = Set.new }
        @files = Hash.new { |hash, key| hash[key] = [] }
        directories.each { |path| add_directories(path.split("/")) }
        paths.each do |path|
          parent = add_directories(path.split("/")[0...-1])
          @files[parent] << path
        end
        @directories.transform_values! { |children| children.to_a.sort }
        @files.each_value(&:sort!)
      end

      def rows(expanded)
        append_rows([], "", expanded, 0)
      end

      private

      def add_directories(parts)
        parts.reduce("") do |parent, part|
          directory = parent.empty? ? part : "#{parent}/#{part}"
          @directories[parent].add(directory)
          directory
        end
      end

      def append_rows(rows, parent, expanded, depth)
        @directories.fetch(parent, []).each do |path|
          open = expanded.include?(path)
          rows << { path: path, name: File.basename(path), depth: depth, directory: true, expanded: open }
          append_rows(rows, path, expanded, depth + 1) if open
        end
        @files.fetch(parent, []).each do |path|
          rows << { path: path, name: File.basename(path), depth: depth, directory: false }
        end
        rows
      end
    end
  end
end
