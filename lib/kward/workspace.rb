require "pathname"

module Kward
  class Workspace
    MAX_FILE_BYTES = 50 * 1024

    def initialize(root: Dir.pwd, max_file_bytes: MAX_FILE_BYTES)
      @root = Pathname.new(root).realpath
      @max_file_bytes = max_file_bytes
    end

    def list_directory(path)
      resolved = workspace_path(path)
      return "Error: not a directory: #{path}" unless File.directory?(resolved)

      Dir.children(resolved).sort.map do |entry|
        File.directory?(File.join(resolved, entry)) ? "#{entry}/" : entry
      end.join("\n")
    rescue SecurityError, Errno::ENOENT => e
      "Error: #{e.message}"
    end

    def read_file(path)
      resolved = workspace_path(path)
      return "Error: not a file: #{path}" unless File.file?(resolved)

      size = File.size(resolved)
      return "Error: file too large: #{path} is #{size} bytes; limit is #{@max_file_bytes} bytes" if size > @max_file_bytes

      File.read(resolved)
    rescue SecurityError, Errno::ENOENT => e
      "Error: #{e.message}"
    end

    def write_file(path, content, read_paths:)
      resolved = workspace_write_path(path)

      if File.exist?(resolved) && !read_paths.include?(resolved)
        return "Error: existing file must be read before writing: #{path}"
      end

      if block_given? && !yield(relative_path(resolved), content.bytesize)
        return "Declined: write_file was not approved for #{path}"
      end

      File.write(resolved, content)
      "Wrote #{content.bytesize} bytes to #{path}"
    rescue SecurityError, Errno::ENOENT => e
      "Error: #{e.message}"
    end

    def resolved_path(path)
      workspace_path(path)
    end

    private

    def workspace_path(path)
      target = Pathname.new(path.to_s)
      target = @root.join(target) unless target.absolute?

      expanded = target.expand_path
      raise SecurityError, "path outside workspace: #{path}" unless inside_workspace?(expanded)

      resolved = target.realpath
      raise SecurityError, "path outside workspace: #{path}" unless inside_workspace?(resolved)

      resolved.to_s
    end

    def workspace_write_path(path)
      target = Pathname.new(path.to_s)
      target = @root.join(target) unless target.absolute?

      expanded = target.expand_path
      raise SecurityError, "path outside workspace: #{path}" unless inside_workspace?(expanded)

      return workspace_path(path) if File.exist?(expanded) || File.symlink?(expanded)

      parent = expanded.dirname.realpath
      raise SecurityError, "path outside workspace: #{path}" unless inside_workspace?(parent)

      expanded.to_s
    end

    def inside_workspace?(path)
      path.to_s == @root.to_s || path.to_s.start_with?("#{@root}/")
    end

    def relative_path(path)
      Pathname.new(path).relative_path_from(@root).to_s
    end
  end
end
