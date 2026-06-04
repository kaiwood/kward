require_relative "test_helper"

class TestWorkspace < KwardTestCase
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

  def test_file_at_size_limit_can_be_read
    path = "max_size_test_file.tmp"
    content = "x" * Kward::Workspace::MAX_FILE_BYTES
    File.write(path, content)

    assert_equal content, Kward::Workspace.new.read_file(path)
  ensure
    File.delete(path) if path && File.exist?(path)
  end

  def test_reject_oversized_file
    path = "oversized_test_file.tmp"
    File.write(path, "x" * (Kward::Workspace::MAX_FILE_BYTES + 1))

    assert_match(/Error: file too large:/, Kward::Workspace.new.read_file(path))
  ensure
    File.delete(path) if path && File.exist?(path)
  end

  def test_existing_file_write_requires_prior_successful_read
    path = "kward_existing_requires_read.txt"
    File.write(path, "old\n")
    workspace = Kward::Workspace.new

    result = workspace.write_file(path, "new\n", read_paths: []) { true }

    assert_equal "Error: existing file must be read before writing: #{path}", result
    assert_equal "old\n", File.read(path)
  ensure
    File.delete(path) if path && File.exist?(path)
  end

  def test_accepted_write_modifies_new_file
    path = "kward_accepted_new.txt"
    workspace = Kward::Workspace.new

    result = workspace.write_file(path, "hello\n", read_paths: []) { true }

    assert_equal "Wrote 6 bytes to #{path}", result
    assert_equal "hello\n", File.read(path)
  ensure
    File.delete(path) if path && File.exist?(path)
  end

  def test_declined_write_does_not_modify_file
    path = "kward_declined_write.txt"
    workspace = Kward::Workspace.new

    result = workspace.write_file(path, "hello\n", read_paths: []) { false }

    assert_equal "Declined: write_file was not approved for #{path}", result
    refute File.exist?(path)
  ensure
    File.delete(path) if path && File.exist?(path)
  end

  def test_existing_file_can_be_written_after_successful_read_and_confirmation
    path = "kward_existing_after_read.txt"
    File.write(path, "old\n")
    workspace = Kward::Workspace.new
    conversation = Kward::Conversation.new
    content = workspace.read_file(path)
    conversation.mark_read(workspace.resolved_path(path)) unless content.start_with?("Error:")

    result = workspace.write_file(path, "new\n", read_paths: conversation.read_paths) { true }

    assert_equal "Wrote 4 bytes to #{path}", result
    assert_equal "new\n", File.read(path)
  ensure
    File.delete(path) if path && File.exist?(path)
  end

  def test_edit_file_requires_prior_successful_read
    path = "kward_edit_requires_read.txt"
    File.write(path, "old\n")
    workspace = Kward::Workspace.new

    result = workspace.edit_file(path, [{ "old_text" => "old", "new_text" => "new" }], read_paths: [])

    assert_equal "Error: existing file must be read before editing: #{path}", result
    assert_equal "old\n", File.read(path)
  ensure
    File.delete(path) if path && File.exist?(path)
  end

  def test_edit_file_applies_exact_replacement_after_read_and_returns_diff
    path = "kward_edit_exact.txt"
    File.write(path, "one\ntwo\nthree\n")
    workspace = Kward::Workspace.new
    conversation = Kward::Conversation.new
    content = workspace.read_file(path)
    conversation.mark_read(workspace.resolved_path(path)) unless content.start_with?("Error:")

    result = workspace.edit_file(path, [{ "old_text" => "two", "new_text" => "TWO" }], read_paths: conversation.read_paths)

    assert_includes result, "Edited #{path}: replaced 1 block(s)"
    assert_includes result, "--- #{path}"
    assert_includes result, "-two"
    assert_includes result, "+TWO"
    assert_equal "one\nTWO\nthree\n", File.read(path)
  ensure
    File.delete(path) if path && File.exist?(path)
  end

  def test_edit_file_applies_multiple_disjoint_edits_against_original_content
    path = "kward_edit_multiple.txt"
    File.write(path, "alpha\nbeta\ngamma\n")
    workspace = Kward::Workspace.new
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
    assert_equal "ALPHA\nbeta\nGAMMA\n", File.read(path)
  ensure
    File.delete(path) if path && File.exist?(path)
  end

  def test_edit_file_rejects_empty_duplicate_missing_and_overlapping_edits_without_changes
    path = "kward_edit_invalid.txt"
    File.write(path, "abc abc\n")
    workspace = Kward::Workspace.new
    conversation = Kward::Conversation.new
    content = workspace.read_file(path)
    conversation.mark_read(workspace.resolved_path(path)) unless content.start_with?("Error:")

    assert_equal "Error: edits[0].old_text must not be empty", workspace.edit_file(path, [{ "old_text" => "", "new_text" => "x" }], read_paths: conversation.read_paths)
    assert_match(/appears 2 times/, workspace.edit_file(path, [{ "old_text" => "abc", "new_text" => "x" }], read_paths: conversation.read_paths))
    assert_equal "Error: edits[0].old_text was not found in #{path}", workspace.edit_file(path, [{ "old_text" => "missing", "new_text" => "x" }], read_paths: conversation.read_paths)
    assert_equal "Error: edits[0] and edits[1] overlap in #{path}", workspace.edit_file(path, [{ "old_text" => "abc ", "new_text" => "x" }, { "old_text" => "bc abc", "new_text" => "y" }], read_paths: conversation.read_paths)
    assert_equal "abc abc\n", File.read(path)
  ensure
    File.delete(path) if path && File.exist?(path)
  end

  def test_symlink_escape_remains_rejected
    skip "symlinks are unavailable" unless File.respond_to?(:symlink)

    outside = File.expand_path("../kward_symlink_escape.txt", Dir.pwd)
    link = "kward_symlink_escape_link.txt"
    File.write(outside, "outside\n")
    File.symlink(outside, link)
    workspace = Kward::Workspace.new

    assert_match(/Error: path outside workspace:/, workspace.read_file(link))
    assert_match(/Error: path outside workspace:/, workspace.write_file(link, "nope\n", read_paths: []) { true })
    assert_match(/Error: path outside workspace:/, workspace.edit_file(link, [{ "old_text" => "outside", "new_text" => "nope" }], read_paths: []))
    assert_equal "outside\n", File.read(outside)
  ensure
    File.delete(link) if link && File.symlink?(link)
    File.delete(outside) if outside && File.exist?(outside)
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
