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

    def edit_file(path, edits, read_paths:)
      resolved = workspace_path(path)
      return "Error: not a file: #{path}" unless File.file?(resolved)
      return "Error: existing file must be read before editing: #{path}" unless read_paths.include?(resolved)

      size = File.size(resolved)
      return "Error: file too large: #{path} is #{size} bytes; limit is #{@max_file_bytes} bytes" if size > @max_file_bytes

      content = File.read(resolved)
      result = apply_edits(path, content, edits)
      return result[:error] if result[:error]

      File.write(resolved, result[:content])
      "Edited #{path}: replaced #{result[:count]} block(s)\n#{unified_diff(path, content, result[:content])}"
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

    def apply_edits(path, content, edits)
      return { error: "Error: edits must contain at least one replacement" } unless edits.is_a?(Array) && !edits.empty?

      replacements = []
      edits.each_with_index do |edit, index|
        old_text = edit_value(edit, "old_text")
        new_text = edit_value(edit, "new_text")
        return { error: "Error: edits[#{index}].old_text must be a string" } unless old_text.is_a?(String)
        return { error: "Error: edits[#{index}].new_text must be a string" } unless new_text.is_a?(String)
        return { error: "Error: edits[#{index}].old_text must not be empty" } if old_text.empty?

        matches = match_indexes(content, old_text)
        return { error: "Error: edits[#{index}].old_text was not found in #{path}" } if matches.empty?
        if matches.length > 1
          return { error: "Error: edits[#{index}].old_text appears #{matches.length} times in #{path}; provide more context" }
        end

        replacements << { index: index, start: matches.first, length: old_text.length, new_text: new_text }
      end

      replacements.sort_by! { |replacement| replacement[:start] }
      replacements.each_cons(2) do |left, right|
        if left[:start] + left[:length] > right[:start]
          return { error: "Error: edits[#{left[:index]}] and edits[#{right[:index]}] overlap in #{path}" }
        end
      end

      new_content = content.dup
      replacements.reverse_each do |replacement|
        new_content[replacement[:start], replacement[:length]] = replacement[:new_text]
      end
      return { error: "Error: no changes made to #{path}" } if new_content == content

      { content: new_content, count: replacements.length }
    end

    def edit_value(edit, key)
      return nil unless edit.is_a?(Hash)

      edit[key] || edit[key.to_sym]
    end

    def match_indexes(content, needle)
      indexes = []
      offset = 0
      while (index = content.index(needle, offset))
        indexes << index
        offset = index + needle.length
      end
      indexes
    end

    def unified_diff(path, old_content, new_content)
      old_lines = old_content.lines(chomp: true)
      new_lines = new_content.lines(chomp: true)
      prefix = 0
      prefix += 1 while prefix < old_lines.length && prefix < new_lines.length && old_lines[prefix] == new_lines[prefix]

      old_suffix = old_lines.length - 1
      new_suffix = new_lines.length - 1
      while old_suffix >= prefix && new_suffix >= prefix && old_lines[old_suffix] == new_lines[new_suffix]
        old_suffix -= 1
        new_suffix -= 1
      end

      context_start = [prefix - 3, 0].max
      old_context_end = [old_suffix + 3, old_lines.length - 1].min
      new_context_end = [new_suffix + 3, new_lines.length - 1].min
      old_hunk_length = old_context_end >= context_start ? old_context_end - context_start + 1 : 0
      new_hunk_length = new_context_end >= context_start ? new_context_end - context_start + 1 : 0

      lines = ["--- #{path}", "+++ #{path}", "@@ -#{context_start + 1},#{old_hunk_length} +#{context_start + 1},#{new_hunk_length} @@"]
      old_lines[context_start...prefix].to_a.each { |line| lines << " #{line}" }
      old_lines[prefix..old_suffix].to_a.each { |line| lines << "-#{line}" }
      new_lines[prefix..new_suffix].to_a.each { |line| lines << "+#{line}" }
      old_lines[(old_suffix + 1)..old_context_end].to_a.each { |line| lines << " #{line}" }
      lines.join("\n")
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
