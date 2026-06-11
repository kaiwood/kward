require "open3"
require "pathname"
require "timeout"
require_relative "session_diff"

module Kward
  class Workspace
    MAX_FILE_BYTES = 256 * 1024
    MAX_READ_OUTPUT_BYTES = 50 * 1024
    MAX_READ_OUTPUT_LINES = 2_000
    MAX_COMMAND_OUTPUT_BYTES = 20 * 1024
    MAX_EDIT_DIFF_BYTES = 8 * 1024
    DEFAULT_COMMAND_TIMEOUT_SECONDS = 30

    def initialize(root: Dir.pwd, max_file_bytes: MAX_FILE_BYTES, max_read_output_bytes: MAX_READ_OUTPUT_BYTES, max_read_output_lines: MAX_READ_OUTPUT_LINES, max_command_output_bytes: MAX_COMMAND_OUTPUT_BYTES)
      @root = Pathname.new(root).realpath
      @max_file_bytes = max_file_bytes
      @max_read_output_bytes = max_read_output_bytes
      @max_read_output_lines = max_read_output_lines
      @max_command_output_bytes = max_command_output_bytes
    end

    attr_reader :root

    def list_directory(path)
      resolved = workspace_path(path)
      return "Error: not a directory: #{path}" unless File.directory?(resolved)

      Dir.children(resolved).sort.map do |entry|
        File.directory?(File.join(resolved, entry)) ? "#{entry}/" : entry
      end.join("\n")
    rescue SecurityError, Errno::ENOENT => e
      "Error: #{e.message}"
    end

    def read_file(path, offset: nil, limit: nil)
      resolved = workspace_path(path)
      return "Error: not a file: #{path}" unless File.file?(resolved)

      size = File.size(resolved)
      return "Error: file too large: #{path} is #{size} bytes; limit is #{@max_file_bytes} bytes" if size > @max_file_bytes

      read_file_slice(File.read(resolved), offset: offset, limit: limit)
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

      old_content = File.exist?(resolved) ? File.read(resolved) : nil
      File.write(resolved, content)
      output = "Wrote #{content.bytesize} bytes to #{path}"
      output << "\n#{truncated_diff(path, old_content, content)}" if old_content && old_content != content
      output
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
      "Edited #{path}: replaced #{result[:count]} block(s)\n#{truncated_diff(path, content, result[:content])}"
    rescue SecurityError, Errno::ENOENT => e
      "Error: #{e.message}"
    end

    def run_shell_command(command, timeout_seconds: DEFAULT_COMMAND_TIMEOUT_SECONDS, cancellation: nil)
      command = command.to_s.strip
      return "Error: command is required" if command.empty?

      timeout_seconds = timeout_seconds.to_i
      timeout_seconds = DEFAULT_COMMAND_TIMEOUT_SECONDS if timeout_seconds <= 0
      cancellation&.raise_if_cancelled!

      Open3.popen3(command, chdir: @root.to_s) do |stdin, stdout, stderr, wait_thread|
        stdin.close
        stdout_reader = Thread.new { stdout.read }
        stderr_reader = Thread.new { stderr.read }
        cancellation&.on_cancel { terminate_process(wait_thread.pid) }
        status = wait_for_process(wait_thread, timeout_seconds, cancellation)

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

    def read_file_slice(content, offset:, limit:)
      lines = content.split("\n", -1)
      lines = [""] if lines.empty?
      start_index = read_start_index(offset)
      return "Error: offset #{offset} is beyond end of file (#{lines.length} lines total)" if start_index >= lines.length

      user_limit = read_limit(limit)
      return user_limit if user_limit.is_a?(String)

      selected_end = user_limit ? [start_index + user_limit, lines.length].min : lines.length
      selected_lines = lines[start_index...selected_end]
      truncated = truncate_read_lines(selected_lines)
      return truncated[:error] if truncated[:error]

      output = truncated[:content]
      if truncated[:truncated]
        output << read_truncation_notice(
          start_index: start_index,
          output_lines: truncated[:line_count],
          total_lines: lines.length,
          truncated_by: truncated[:truncated_by]
        )
      elsif user_limit && selected_end < lines.length
        output << "\n\n[#{lines.length - selected_end} more lines in file. Use offset=#{selected_end + 1} to continue.]"
      end

      output
    end

    def read_start_index(offset)
      return 0 if offset.nil?

      [offset.to_i - 1, 0].max
    end

    def read_limit(limit)
      return nil if limit.nil?

      value = limit.to_i
      return "Error: limit must be positive" unless value.positive?

      value
    end

    def truncate_read_lines(lines)
      first_line = lines.first.to_s
      if first_line.bytesize > @max_read_output_bytes
        return {
          error: "Error: first line is #{first_line.bytesize} bytes, exceeds #{@max_read_output_bytes} byte read limit. Use run_shell_command with sed/head to inspect smaller chunks."
        }
      end

      output_lines = []
      bytes = 0
      truncated_by = nil
      lines.each do |line|
        if output_lines.length >= @max_read_output_lines
          truncated_by = "lines"
          break
        end

        separator_bytes = output_lines.empty? ? 0 : 1
        next_bytes = line.bytesize + separator_bytes
        if bytes + next_bytes > @max_read_output_bytes
          truncated_by = "bytes"
          break
        end

        output_lines << line
        bytes += next_bytes
      end

      {
        content: output_lines.join("\n"),
        line_count: output_lines.length,
        truncated: output_lines.length < lines.length,
        truncated_by: truncated_by
      }
    end

    def read_truncation_notice(start_index:, output_lines:, total_lines:, truncated_by:)
      end_line = start_index + output_lines
      next_offset = end_line + 1
      detail = truncated_by == "lines" ? "#{@max_read_output_lines} line limit" : "#{@max_read_output_bytes} byte limit"
      "\n\n[Showing lines #{start_index + 1}-#{end_line} of #{total_lines} (#{detail}). Use offset=#{next_offset} to continue.]"
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

    def truncated_diff(path, old_content, new_content)
      diff = unified_diff(path, old_content, new_content)
      return diff if diff.bytesize <= MAX_EDIT_DIFF_BYTES

      counts = SessionDiff.count(diff)
      diff.byteslice(0, MAX_EDIT_DIFF_BYTES).to_s.scrub << "\n... diff truncated to #{MAX_EDIT_DIFF_BYTES} bytes; full diff stats: +#{counts[:additions]}|-#{counts[:deletions]}. Use read_file to inspect current content."
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

    def wait_for_process(wait_thread, timeout_seconds, cancellation)
      deadline = Time.now + timeout_seconds
      loop do
        cancellation&.raise_if_cancelled!
        return wait_thread.value if wait_thread.join(0.05)
        raise Timeout::Error if Time.now >= deadline
      end
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
