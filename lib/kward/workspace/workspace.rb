require "pathname"
require_relative "../pty/local_command_runner"
require_relative "../sandbox"
require_relative "../sessions/diff"

require_relative "path_guard"

# Namespace for the Kward CLI agent runtime.
module Kward
  # Filesystem and shell-command boundary for workspace tools.
  #
  # `Workspace` is deliberately low-level: it validates paths, enforces output
  # limits, applies exact edits, writes files, and runs shell commands from one
  # root directory. It should not know about model prompts, sessions, telemetry,
  # or UI confirmation. Tool wrappers and frontends provide those policies.
  #
  # Guardrails are enabled by default and require all file paths to resolve under
  # `root`. RPC may report when guardrails are disabled, but callers should avoid
  # bypassing this class for local filesystem mutation so read-before-write and
  # path safety remain consistent.
  class Workspace
    MAX_FILE_BYTES = 256 * 1024
    MAX_READ_OUTPUT_BYTES = 50 * 1024
    MAX_READ_OUTPUT_LINES = 2_000
    MAX_COMMAND_OUTPUT_BYTES = 128 * 1024
    MAX_EDIT_DIFF_BYTES = 8 * 1024
    DEFAULT_COMMAND_TIMEOUT_SECONDS = 30
    EXPECTED_FILE_ERRORS = [SecurityError, Errno::ENOENT, Errno::EACCES, Errno::EPERM, Errno::EISDIR, Errno::ENOTDIR].freeze

    # Creates an object for workspace filesystem and shell operations.
    def initialize(root: Dir.pwd, max_file_bytes: MAX_FILE_BYTES, max_read_output_bytes: MAX_READ_OUTPUT_BYTES, max_read_output_lines: MAX_READ_OUTPUT_LINES, max_command_output_bytes: MAX_COMMAND_OUTPUT_BYTES, guardrails: true, command_runner: nil)
      @root = Pathname.new(root).realpath
      @guardrails = guardrails
      @max_file_bytes = max_file_bytes
      @max_read_output_bytes = max_read_output_bytes
      @max_read_output_lines = max_read_output_lines
      @max_command_output_bytes = max_command_output_bytes
      @command_runner = command_runner
    end

    # @return [Pathname] canonical workspace root used as the base for file and shell tools
    attr_reader :root

    # Lists immediate directory children after resolving `path` through workspace guardrails.
    def list_directory(path)
      resolved = workspace_path(path)
      return "Error: not a directory: #{path}" unless File.directory?(resolved)

      Dir.children(resolved).sort.map do |entry|
        File.directory?(File.join(resolved, entry)) ? "#{entry}/" : entry
      end.join("\n")
    rescue *EXPECTED_FILE_ERRORS => e
      "Error: #{e.message}"
    end

    # Reads a bounded text slice from a workspace file.
    #
    # The returned string is user/model-facing and includes continuation notices
    # when output is truncated. Errors are returned as `"Error: ..."` strings so
    # tool calls can be persisted in the conversation without raising.
    def read_file(path, offset: nil, limit: nil, mode: nil, max_bytes: nil)
      resolved = workspace_path(path)
      return "Error: not a file: #{path}" unless File.file?(resolved)

      size = File.size(resolved)
      return "Error: file too large: #{path} is #{size} bytes; limit is #{@max_file_bytes} bytes" if size > @max_file_bytes

      content = File.read(resolved)
      return "Error: not a text file: #{path}" if binary_content?(content)

      read_mode = normalize_read_mode(mode)
      return read_mode if read_mode.is_a?(String)

      output_budget = read_output_budget(max_bytes)
      return output_budget if output_budget.is_a?(String)

      case read_mode
      when :outline
        file_structure_summary(path, content)
      when :preview
        read_file_slice(content, offset: offset, limit: limit || 120, max_bytes: output_budget)
      when :range
        read_file_slice(content, offset: offset, limit: limit, max_bytes: output_budget)
      when :full
        read_file_slice(content, offset: offset, limit: limit, max_bytes: output_budget)
      else
        large_file_outline_response(path, content, offset: offset, limit: limit) || read_file_slice(content, offset: offset, limit: limit, max_bytes: output_budget)
      end
    rescue *EXPECTED_FILE_ERRORS => e
      "Error: #{e.message}"
    end

    # Returns a compact outline of recognizable source-code declarations.
    def summarize_file_structure(path)
      resolved = workspace_path(path)
      return "Error: not a file: #{path}" unless File.file?(resolved)

      size = File.size(resolved)
      return "Error: file too large: #{path} is #{size} bytes; limit is #{@max_file_bytes} bytes" if size > @max_file_bytes

      content = File.read(resolved)
      return "Error: not a text file: #{path}" if binary_content?(content)

      file_structure_summary(path, content)
    rescue *EXPECTED_FILE_ERRORS => e
      "Error: #{e.message}"
    end

    # Writes complete file content after enforcing read-before-write for
    # existing files.
    #
    # `read_paths` must contain resolved paths previously observed by
    # `ReadFile`; this keeps tool-driven edits explicit and prevents overwriting
    # unseen user files.
    def write_file(path, content, read_paths:)
      resolved = workspace_write_path(path)

      if File.exist?(resolved) && !read_paths.include?(resolved)
        return "Error: existing file must be read before writing: #{path}"
      end

      old_content = File.exist?(resolved) ? File.read(resolved) : nil
      File.write(resolved, content)
      output = "Wrote #{content.bytesize} bytes to #{path}"
      output << "\n#{truncated_diff(path, old_content, content)}" if old_content && old_content != content
      output
    rescue *EXPECTED_FILE_ERRORS => e
      "Error: #{e.message}"
    end

    # Applies exact non-overlapping replacements to a previously read file.
    #
    # Each `old_text` must match exactly once. This favors predictable model edits
    # over fuzzy patching and returns readable error strings when more context is
    # needed.
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
    rescue *EXPECTED_FILE_ERRORS => e
      "Error: #{e.message}"
    end

    # Runs a shell command from the workspace root with timeout, cancellation,
    # and bounded combined output.
    #
    # This method intentionally does not ask for confirmation; CLI/RPC policy
    # must decide whether a command is allowed before reaching this boundary.
    def run_shell_command(command, timeout_seconds: DEFAULT_COMMAND_TIMEOUT_SECONDS, cancellation: nil)
      command = command.to_s.strip
      return "Error: command is required" if command.empty?

      timeout_seconds = timeout_seconds.to_i
      timeout_seconds = DEFAULT_COMMAND_TIMEOUT_SECONDS if timeout_seconds <= 0
      cancellation&.raise_if_cancelled!

      result = command_runner.run(
        command,
        cwd: @root.to_s,
        timeout_seconds: timeout_seconds,
        max_output_bytes: @max_command_output_bytes,
        cancellation: cancellation
      )
      return "Error: command timed out after #{timeout_seconds} seconds" if result.timed_out

      output = +"Exit status: #{result.exit_status}\n"
      output << "\nSTDOUT:\n#{result.stdout}" unless result.stdout.empty?
      output << "\nSTDERR:\n#{result.stderr}" unless result.stderr.empty?
      output << "\n... truncated to #{@max_command_output_bytes} bytes" if result.truncated
      truncate_output(output)
    rescue Errno::ENOENT, ArgumentError, Sandbox::UnavailableError => e
      "Error: #{e.message}"
    end

    # Resolves a path with the same guardrails used by file tools.
    def resolved_path(path)
      workspace_path(path)
    end

    private

    def command_runner
      @command_runner ||= Sandbox::PassthroughRunner.new(
        policy: Sandbox::Policy.new(workspace_root: @root),
        capabilities: Sandbox::RunnerFactory.off_capabilities
      )
    end

    def workspace_path(path)
      target = Pathname.new(path.to_s)
      target = @root.join(target) unless target.absolute?

      expanded = target.expand_path
      raise SecurityError, "path outside workspace: #{path}" if guardrails_enabled? && !inside_workspace?(expanded)

      resolved = target.realpath
      raise SecurityError, "path outside workspace: #{path}" if guardrails_enabled? && !inside_workspace?(resolved)

      resolved.to_s
    end

    def workspace_write_path(path)
      target = Pathname.new(path.to_s)
      target = @root.join(target) unless target.absolute?

      expanded = target.expand_path
      raise SecurityError, "path outside workspace: #{path}" if guardrails_enabled? && !inside_workspace?(expanded)

      return workspace_path(path) if File.exist?(expanded) || File.symlink?(expanded)

      parent = expanded.dirname.realpath
      raise SecurityError, "path outside workspace: #{path}" if guardrails_enabled? && !inside_workspace?(parent)

      expanded.to_s
    end

    def guardrails_enabled?
      @guardrails != false
    end

    def inside_workspace?(path)
      PathGuard.inside?(path, @root)
    end

    def relative_path(path)
      Pathname.new(path).relative_path_from(@root).to_s
    end

    def large_file_outline_response(path, content, offset:, limit:)
      return nil unless offset.nil? && limit.nil?
      lines = content.split("\n", -1)
      return nil unless lines.length > @max_read_output_lines || content.bytesize > @max_read_output_bytes

      outline = source_outline(lines)
      return nil if outline.empty?

      preview_limit = [120, @max_read_output_lines].min
      preview = lines.first(preview_limit).join("\n")
      [
        "File has #{lines.length} lines (#{content.bytesize} bytes). Showing an outline and the first #{preview_limit} lines to reduce model context.",
        "",
        "Outline:",
        outline.join("\n"),
        "",
        "First #{preview_limit} lines:",
        preview,
        "",
        "[Use read_file with mode=\"range\", offset=#{preview_limit + 1}, and limit to continue; mode=\"outline\" for only the outline; or request a specific section from the outline.]"
      ].join("\n")
    end

    def file_structure_summary(path, content)
      lines = content.split("\n", -1)
      outline = source_outline(lines)
      return "No recognizable source structure found in #{path}." if outline.empty?

      (["# File structure: #{path}", "- Lines: #{lines.length}", "- Bytes: #{content.bytesize}", "", "## Outline"] + outline).join("\n")
    end

    def source_outline(lines)
      entries = source_outline_entries(lines)
      entries.first(80).map do |entry|
        range = entry[:end_line] && entry[:end_line] != entry[:line] ? " (range #{entry[:line]}-#{entry[:end_line]}, #{entry[:kind]})" : " (#{entry[:kind]})"
        "line #{entry[:line]}: #{'  ' * [entry[:indent] / 2, 6].min}#{entry[:signature]}#{range}"
      end
    end

    def source_outline_entries(lines)
      candidates = []
      lines.each_with_index do |line, index|
        declaration = source_declaration(line.strip)
        next unless declaration

        candidates << declaration.merge(line: index + 1, indent: line[/\A\s*/].to_s.length)
      end
      candidates.each_with_index do |entry, index|
        following = candidates[(index + 1)..]&.find { |candidate| candidate[:indent] <= entry[:indent] }
        entry[:end_line] = following ? following[:line] - 1 : last_content_line(lines)
      end
      candidates
    end

    def source_declaration(stripped)
      case stripped
      when /\A(module)\s+(.+)/
        { kind: "module", signature: stripped }
      when /\A(class)\s+(.+)/
        { kind: "class", signature: stripped }
      when /\A(async\s+def|def)\s+(.+)/
        { kind: "function", signature: stripped }
      when /\A(export\s+)?(async\s+)?function\s+(.+)/
        { kind: "function", signature: stripped }
      when /\A(async\s+)?(?:get\s+|set\s+)?(?:constructor|[A-Za-z_$][\w$]*)\s*\([^;]*\)\s*(?::\s*[^{}]+)?\s*(?:\{\}|\{|=>)?\z/
        { kind: "method", signature: stripped } unless stripped.match?(/\A(if|for|while|switch|catch)\b/)
      when /\A(export\s+)?(class|interface|type|enum)\s+(.+)/
        { kind: Regexp.last_match(2), signature: stripped }
      when /\A(?:export\s+)?(?:const|let|var)\s+\w+\s*=.*=>/
        { kind: "function", signature: stripped }
      when /\Afunc\s+(.+)/
        { kind: "function", signature: stripped }
      when /\Atype\s+\w+\s+(struct|interface)\b/
        { kind: Regexp.last_match(1), signature: stripped }
      when /\A(pub\s+)?(async\s+)?fn\s+(.+)/
        { kind: "function", signature: stripped }
      when /\A(pub\s+)?(struct|enum|trait|impl)\b(.+)?/
        { kind: Regexp.last_match(2), signature: stripped }
      when /\A(?:public|private|protected|internal|static|final|abstract|async|override|virtual|sealed|readonly|partial|\s)+\s*(class|interface|enum|record)\s+(.+)/
        { kind: Regexp.last_match(1), signature: stripped }
      when /\A(?:public|private|protected|internal|static|final|abstract|async|override|virtual|sealed|readonly|partial|\s)+\s*\S[^{;=]*\w+\s*\([^;]*\)\s*(?:\{|=>)?\z/
        { kind: "method", signature: stripped }
      end
    end

    def last_content_line(lines)
      index = lines.rindex { |line| !line.strip.empty? }
      index ? index + 1 : lines.length
    end

    def normalize_read_mode(mode)
      return nil if mode.nil? || mode.to_s.empty?

      value = mode.to_s.downcase
      return value.to_sym if %w[preview outline range full].include?(value)

      "Error: mode must be one of preview, outline, range, full"
    end

    def read_output_budget(max_bytes)
      return @max_read_output_bytes if max_bytes.nil?

      value = max_bytes.to_i
      return "Error: max_bytes must be positive" unless value.positive?

      [value, @max_read_output_bytes].min
    end

    def read_file_slice(content, offset:, limit:, max_bytes: @max_read_output_bytes)
      lines = content.split("\n", -1)
      lines = [""] if lines.empty?
      start_index = read_start_index(offset)
      return "Error: offset #{offset} is beyond end of file (#{lines.length} lines total)" if start_index >= lines.length

      user_limit = read_limit(limit)
      return user_limit if user_limit.is_a?(String)

      selected_end = user_limit ? [start_index + user_limit, lines.length].min : lines.length
      selected_lines = lines[start_index...selected_end]
      truncated = truncate_read_lines(selected_lines, max_bytes: max_bytes)
      return truncated[:error] if truncated[:error]

      output = truncated[:content]
      if truncated[:truncated]
        output << read_truncation_notice(
          start_index: start_index,
          output_lines: truncated[:line_count],
          total_lines: lines.length,
          truncated_by: truncated[:truncated_by],
          max_bytes: max_bytes
        )
      elsif user_limit && selected_end < lines.length
        output << "\n\n[#{lines.length - selected_end} more lines in file. Use offset=#{selected_end + 1} to continue.]"
      end

      output
    end

    def binary_content?(content)
      content.include?("\x00")
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

    def truncate_read_lines(lines, max_bytes: @max_read_output_bytes)
      first_line = lines.first.to_s
      if first_line.bytesize > max_bytes
        return {
          error: "Error: first line is #{first_line.bytesize} bytes, exceeds #{max_bytes} byte read limit. Use run_shell_command with sed/head to inspect smaller chunks."
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
        if bytes + next_bytes > max_bytes
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

    def read_truncation_notice(start_index:, output_lines:, total_lines:, truncated_by:, max_bytes: @max_read_output_bytes)
      end_line = start_index + output_lines
      next_offset = end_line + 1
      detail = truncated_by == "lines" ? "#{@max_read_output_lines} line limit" : "#{max_bytes} byte limit"
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

  end
end
