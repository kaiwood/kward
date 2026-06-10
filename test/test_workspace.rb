require_relative "test_helper"

class TestWorkspace < KwardTestCase
  def with_temp_workspace
    Dir.mktmpdir do |dir|
      yield Kward::Workspace.new(root: dir), dir
    end
  end

  def test_list_directory_and_read_file_still_work
    workspace = Kward::Workspace.new

    assert_includes workspace.list_directory("."), "README.md"
    assert_includes workspace.read_file("README.md"), "# Ruby CLI Agent"
  end

  def test_outside_workspace_reads_and_writes_are_rejected
    workspace = Kward::Workspace.new

    assert_match(/Error: path outside workspace:/, workspace.read_file("../Gemfile"))
    assert_match(/Error: path outside workspace:/, workspace.write_file("../outside.txt", "nope", read_paths: []))
    assert_match(/Error: path outside workspace:/, workspace.edit_file("../Gemfile", [{ "old_text" => "x", "new_text" => "y" }], read_paths: []))
  end

  def test_file_at_size_limit_is_accepted_but_read_output_is_capped
    with_temp_workspace do |workspace, dir|
      path = File.join(dir, "max_size_test_file.tmp")
      content = "x\n" * (Kward::Workspace::MAX_FILE_BYTES / 2)
      File.write(path, content)

      result = workspace.read_file("max_size_test_file.tmp")

      assert_includes result, "[Showing lines 1-2000 of"
      assert_operator result.bytesize, :<, Kward::Workspace::MAX_READ_OUTPUT_BYTES
    end
  end

  def test_read_file_allows_empty_files
    with_temp_workspace do |workspace, dir|
      File.write(File.join(dir, "empty_read.tmp"), "")

      assert_equal "", workspace.read_file("empty_read.tmp")
    end
  end

  def test_read_file_truncates_by_byte_limit_with_offset_hint
    with_temp_workspace do |workspace, dir|
      File.write(File.join(dir, "byte_limited_read.tmp"), "alpha\nbeta\ngamma")
      workspace = Kward::Workspace.new(root: dir, max_read_output_bytes: 12, max_read_output_lines: 100)

      result = workspace.read_file("byte_limited_read.tmp")

      assert_equal "alpha\nbeta\n\n[Showing lines 1-2 of 3 (12 byte limit). Use offset=3 to continue.]", result
    end
  end

  def test_read_file_supports_offset_and_limit
    with_temp_workspace do |workspace, dir|
      File.write(File.join(dir, "offset_limited_read.tmp"), "alpha\nbeta\ngamma")
      workspace = Kward::Workspace.new(root: dir, max_read_output_bytes: 100, max_read_output_lines: 100)

      result = workspace.read_file("offset_limited_read.tmp", offset: 2, limit: 1)

      assert_equal "beta\n\n[1 more lines in file. Use offset=3 to continue.]", result
    end
  end

  def test_read_file_truncates_by_line_limit
    with_temp_workspace do |workspace, dir|
      File.write(File.join(dir, "line_limited_read.tmp"), "one\ntwo\nthree")
      workspace = Kward::Workspace.new(root: dir, max_read_output_bytes: 100, max_read_output_lines: 2)

      result = workspace.read_file("line_limited_read.tmp")

      assert_equal "one\ntwo\n\n[Showing lines 1-2 of 3 (2 line limit). Use offset=3 to continue.]", result
    end
  end

  def test_reject_oversized_file
    with_temp_workspace do |workspace, dir|
      File.write(File.join(dir, "oversized_test_file.tmp"), "x" * (Kward::Workspace::MAX_FILE_BYTES + 1))

      assert_match(/Error: file too large:/, workspace.read_file("oversized_test_file.tmp"))
    end
  end

  def test_existing_file_write_requires_prior_successful_read
    with_temp_workspace do |workspace, dir|
      path = "kward_existing_requires_read.txt"
      File.write(File.join(dir, path), "old\n")

      result = workspace.write_file(path, "new\n", read_paths: []) { true }

      assert_equal "Error: existing file must be read before writing: #{path}", result
      assert_equal "old\n", File.read(File.join(dir, path))
    end
  end

  def test_accepted_write_modifies_new_file
    with_temp_workspace do |workspace, dir|
      path = "kward_accepted_new.txt"

      result = workspace.write_file(path, "hello\n", read_paths: []) { true }

      assert_equal "Wrote 6 bytes to #{path}", result
      assert_equal "hello\n", File.read(File.join(dir, path))
    end
  end

  def test_declined_write_does_not_modify_file
    with_temp_workspace do |workspace, dir|
      path = "kward_declined_write.txt"

      result = workspace.write_file(path, "hello\n", read_paths: []) { false }

      assert_equal "Declined: write_file was not approved for #{path}", result
      refute File.exist?(File.join(dir, path))
    end
  end

  def test_existing_file_can_be_written_after_successful_read_and_confirmation
    with_temp_workspace do |workspace, dir|
      path = "kward_existing_after_read.txt"
      File.write(File.join(dir, path), "old\n")
      conversation = Kward::Conversation.new
      content = workspace.read_file(path)
      conversation.mark_read(workspace.resolved_path(path)) unless content.start_with?("Error:")

      result = workspace.write_file(path, "new\n", read_paths: conversation.read_paths) { true }

      assert_equal "Wrote 4 bytes to #{path}", result
      assert_equal "new\n", File.read(File.join(dir, path))
    end
  end

  def test_edit_file_requires_prior_successful_read
    with_temp_workspace do |workspace, dir|
      path = "kward_edit_requires_read.txt"
      File.write(File.join(dir, path), "old\n")

      result = workspace.edit_file(path, [{ "old_text" => "old", "new_text" => "new" }], read_paths: [])

      assert_equal "Error: existing file must be read before editing: #{path}", result
      assert_equal "old\n", File.read(File.join(dir, path))
    end
  end

  def test_edit_file_applies_exact_replacement_after_read_and_returns_diff
    with_temp_workspace do |workspace, dir|
      path = "kward_edit_exact.txt"
      File.write(File.join(dir, path), "one\ntwo\nthree\n")
      conversation = Kward::Conversation.new
      content = workspace.read_file(path)
      conversation.mark_read(workspace.resolved_path(path)) unless content.start_with?("Error:")

      result = workspace.edit_file(path, [{ "old_text" => "two", "new_text" => "TWO" }], read_paths: conversation.read_paths)

      assert_includes result, "Edited #{path}: replaced 1 block(s)"
      assert_includes result, "--- #{path}"
      assert_includes result, "-two"
      assert_includes result, "+TWO"
      assert_equal "one\nTWO\nthree\n", File.read(File.join(dir, path))
    end
  end

  def test_edit_file_applies_multiple_disjoint_edits_against_original_content
    with_temp_workspace do |workspace, dir|
      path = "kward_edit_multiple.txt"
      File.write(File.join(dir, path), "alpha\nbeta\ngamma\n")
      conversation = Kward::Conversation.new
      content = workspace.read_file(path)
      conversation.mark_read(workspace.resolved_path(path)) unless content.start_with?("Error:")

      result = workspace.edit_file(
        path,
        [
          { "old_text" => "alpha", "new_text" => "ALPHA" },
          { "old_text" => "gamma", "new_text" => "GAMMA" }
        ],
        read_paths: conversation.read_paths
      )

      assert_includes result, "Edited #{path}: replaced 2 block(s)"
      assert_equal "ALPHA\nbeta\nGAMMA\n", File.read(File.join(dir, path))
    end
  end

  def test_edit_file_truncates_large_diff_output
    with_temp_workspace do |workspace, dir|
      path = "kward_edit_large_diff.txt"
      old_text = (1..600).map { |index| "old #{index}" }.join("\n")
      new_text = (1..600).map { |index| "new #{index}" }.join("\n")
      File.write(File.join(dir, path), old_text)
      conversation = Kward::Conversation.new
      content = workspace.read_file(path)
      conversation.mark_read(workspace.resolved_path(path)) unless content.start_with?("Error:")

      result = workspace.edit_file(path, [{ "old_text" => old_text, "new_text" => new_text }], read_paths: conversation.read_paths)

      assert_includes result, "Edited #{path}: replaced 1 block(s)"
      assert_includes result, "diff truncated to #{Kward::Workspace::MAX_EDIT_DIFF_BYTES} bytes"
      assert_operator result.bytesize, :<, Kward::Workspace::MAX_EDIT_DIFF_BYTES + 200
      assert_equal new_text, File.read(File.join(dir, path))
    end
  end

  def test_edit_file_rejects_empty_duplicate_missing_and_overlapping_edits_without_changes
    with_temp_workspace do |workspace, dir|
      path = "kward_edit_invalid.txt"
      File.write(File.join(dir, path), "abc abc\n")
      conversation = Kward::Conversation.new
      content = workspace.read_file(path)
      conversation.mark_read(workspace.resolved_path(path)) unless content.start_with?("Error:")

      assert_equal "Error: edits[0].old_text must not be empty", workspace.edit_file(path, [{ "old_text" => "", "new_text" => "x" }], read_paths: conversation.read_paths)
      assert_match(/appears 2 times/, workspace.edit_file(path, [{ "old_text" => "abc", "new_text" => "x" }], read_paths: conversation.read_paths))
      assert_equal "Error: edits[0].old_text was not found in #{path}", workspace.edit_file(path, [{ "old_text" => "missing", "new_text" => "x" }], read_paths: conversation.read_paths)
      assert_equal "Error: edits[0] and edits[1] overlap in #{path}", workspace.edit_file(path, [{ "old_text" => "abc ", "new_text" => "x" }, { "old_text" => "bc abc", "new_text" => "y" }], read_paths: conversation.read_paths)
      assert_equal "abc abc\n", File.read(File.join(dir, path))
    end
  end

  def test_symlink_escape_remains_rejected
    skip "symlinks are unavailable" unless File.respond_to?(:symlink)

    Dir.mktmpdir do |parent|
      root = File.join(parent, "root")
      FileUtils.mkdir_p(root)
      outside = File.join(parent, "kward_symlink_escape.txt")
      link = File.join(root, "kward_symlink_escape_link.txt")
      File.write(outside, "outside\n")
      File.symlink(outside, link)
      workspace = Kward::Workspace.new(root: root)

      assert_match(/Error: path outside workspace:/, workspace.read_file("kward_symlink_escape_link.txt"))
      assert_match(/Error: path outside workspace:/, workspace.write_file("kward_symlink_escape_link.txt", "nope\n", read_paths: []) { true })
      assert_match(/Error: path outside workspace:/, workspace.edit_file("kward_symlink_escape_link.txt", [{ "old_text" => "outside", "new_text" => "nope" }], read_paths: []))
      assert_equal "outside\n", File.read(outside)
    end
  end

  def test_run_shell_command_runs_in_workspace
    output = Kward::Workspace.new.run_shell_command("ruby -e 'puts Dir.pwd; puts 2 + 2'")

    assert_includes output, "Exit status: 0"
    assert_includes output, Dir.pwd
    assert_includes output, "4"
  end

  def test_run_shell_command_times_out
    output = Kward::Workspace.new.run_shell_command("ruby -e 'sleep 2'", timeout_seconds: 1)

    assert_equal "Error: command timed out after 1 seconds", output
  end

end
