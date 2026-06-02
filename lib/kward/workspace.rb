require "open3"
require "pathname"
require "timeout"

module Kward
  class Workspace
    MAX_FILE_BYTES = 50 * 1024
    MAX_COMMAND_OUTPUT_BYTES = 20 * 1024
    DEFAULT_COMMAND_TIMEOUT_SECONDS = 30

    def initialize(root: Dir.pwd, max_file_bytes: MAX_FILE_BYTES, max_command_output_bytes: MAX_COMMAND_OUTPUT_BYTES)
      @root = Pathname.new(root).realpath
      @max_file_bytes = max_file_bytes
      @max_command_output_bytes = max_command_output_bytes
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

    def run_shell_command(command, timeout_seconds: DEFAULT_COMMAND_TIMEOUT_SECONDS)
      command = command.to_s.strip
      return "Error: command is required" if command.empty?

      timeout_seconds = timeout_seconds.to_i
      timeout_seconds = DEFAULT_COMMAND_TIMEOUT_SECONDS if timeout_seconds <= 0

      Open3.popen3(command, chdir: @root.to_s) do |stdin, stdout, stderr, wait_thread|
        stdin.close
        stdout_reader = Thread.new { stdout.read }
        stderr_reader = Thread.new { stderr.read }
        status = Timeout.timeout(timeout_seconds) { wait_thread.value }

        output = +"Exit status: #{status.exitstatus}\n"
        output << "\nSTDOUT:\n#{stdout_reader.value}" unless stdout_reader.value.empty?
        output << "\nSTDERR:\n#{stderr_reader.value}" unless stderr_reader.value.empty?
        truncate_output(output)
      rescue Timeout::Error
        terminate_process(wait_thread.pid)
        "Error: command timed out after #{timeout_seconds} seconds"
      ensure
        stdout_reader&.kill if stdout_reader&.alive?
        stderr_reader&.kill if stderr_reader&.alive?
      end
    rescue Errno::ENOENT, ArgumentError => e
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

    def truncate_output(output)
      return output if output.bytesize <= @max_command_output_bytes

      output.byteslice(0, @max_command_output_bytes) << "\n... truncated to #{@max_command_output_bytes} bytes"
    end

    def terminate_process(pid)
      Process.kill("TERM", pid)
      sleep 0.2
      Process.kill("KILL", pid)
    rescue Errno::ESRCH
      nil
    end
  end
end
