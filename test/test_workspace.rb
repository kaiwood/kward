require_relative "test_helper"
require_relative "../lib/kward/cancellation"

class TestWorkspace < KwardTestCase
  def with_temp_workspace
    Dir.mktmpdir do |dir|
      yield Kward::Workspace.new(root: dir), dir
    end
  end

  def test_list_directory_and_read_file_still_work
    workspace = Kward::Workspace.new

    assert_includes workspace.list_directory("."), "README.md"
    assert_includes workspace.read_file("README.md"), "# Kward"
  end

  def test_outside_workspace_reads_and_writes_are_rejected
    workspace = Kward::Workspace.new

    assert_match(/Error: path outside workspace:/, workspace.read_file("../Gemfile"))
    assert_match(/Error: path outside workspace:/, workspace.write_file("../outside.txt", "nope", read_paths: []))
    assert_match(/Error: path outside workspace:/, workspace.edit_file("../Gemfile", [{ "old_text" => "x", "new_text" => "y" }], read_paths: []))
  end

  def test_disabled_guardrails_allow_file_tools_outside_workspace
    Dir.mktmpdir do |parent|
      root = File.join(parent, "workspace")
      Dir.mkdir(root)
      outside = File.join(parent, "outside.txt")
      File.write(outside, "outside\n")
      workspace = Kward::Workspace.new(root: root, guardrails: false)

      assert_equal "outside\n", workspace.read_file(outside)
      assert_match(/Wrote 8 bytes to #{Regexp.escape(File.join(parent, "new.txt"))}/, workspace.write_file(File.join(parent, "new.txt"), "created\n", read_paths: []))
      assert_equal "created\n", File.read(File.join(parent, "new.txt"))
    end
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

  def test_summarize_file_structure_returns_source_outline
    with_temp_workspace do |workspace, dir|
      File.write(File.join(dir, "structure.rb"), "module BigThing\n  class Runner\n    def call\n    end\n  end\nend\n")

      result = workspace.summarize_file_structure("structure.rb")

      assert_includes result, "# File structure: structure.rb"
      assert_includes result, "- Lines: 7"
      assert_includes result, "line 1: module BigThing (range 1-6, module)"
      assert_includes result, "line 2:   class Runner (range 2-6, class)"
      assert_includes result, "line 3:     def call (range 3-6, function)"
    end
  end

  def test_summarize_file_structure_recognizes_common_language_declarations
    with_temp_workspace do |workspace, dir|
      File.write(File.join(dir, "structure.ts"), <<~TS)
        export class Runner {
          constructor(private readonly name: string) {}
          async call(): Promise<void> {
          }
        }
        export const helper = () => true
        export interface Config { enabled: boolean }
      TS

      result = workspace.summarize_file_structure("structure.ts")

      assert_includes result, "line 1: export class Runner { (range 1-5, class)"
      assert_includes result, "line 2:   constructor(private readonly name: string) {} (method)"
      assert_includes result, "line 3:   async call(): Promise<void> { (range 3-5, method)"
      assert_includes result, "line 6: export const helper = () => true (function)"
      assert_includes result, "line 7: export interface Config { enabled: boolean } (interface)"
    end
  end

  def test_read_file_returns_outline_for_large_source_files
    with_temp_workspace do |workspace, dir|
      lines = ["module BigThing", "  class Runner", "    def call", "    end", "  end", "end"] + Array.new(2_100) { |index| "# filler #{index}" }
      File.write(File.join(dir, "big_source.rb"), lines.join("\n"))

      result = workspace.read_file("big_source.rb")

      assert_includes result, "File has 2106 lines"
      assert_includes result, "Outline:"
      assert_includes result, "line 1: module BigThing"
      assert_includes result, "line 2:   class Runner"
      assert_includes result, "line 3:     def call"
      assert_includes result, "First 120 lines:"
      assert_includes result, "Use read_file with mode=\"range\", offset=121"
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

  def test_read_file_modes_control_context_budget
    with_temp_workspace do |workspace, dir|
      File.write(File.join(dir, "budgeted.rb"), "class Budgeted\n  def call\n  end\nend\n# filler\n")
      workspace = Kward::Workspace.new(root: dir, max_read_output_bytes: 100, max_read_output_lines: 100)

      assert_equal "class Budgeted\n  def call\n  end\nend\n# filler\n", workspace.read_file("budgeted.rb", mode: "full")
      assert_equal "class Budgeted\n  def call\n\n[Showing lines 1-2 of 6 (25 byte limit). Use offset=3 to continue.]", workspace.read_file("budgeted.rb", mode: "range", max_bytes: 25)
      assert_includes workspace.read_file("budgeted.rb", mode: "outline"), "line 2:   def call"
      assert_equal "Error: mode must be one of preview, outline, range, full", workspace.read_file("budgeted.rb", mode: "everything")
    end
  end

  def test_read_file_preview_mode_defaults_to_short_slice
    with_temp_workspace do |workspace, dir|
      File.write(File.join(dir, "preview.tmp"), (1..150).map { |index| "line #{index}" }.join("\n"))
      workspace = Kward::Workspace.new(root: dir, max_read_output_bytes: 5_000, max_read_output_lines: 500)

      result = workspace.read_file("preview.tmp", mode: "preview")

      assert_includes result, "line 120"
      assert_includes result, "[30 more lines in file. Use offset=121 to continue.]"
      refute_includes result, "line 121"
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

  def test_read_file_rejects_binary_content
    with_temp_workspace do |workspace, dir|
      File.binwrite(File.join(dir, "binary_read.tmp"), "text\x00binary")

      assert_equal "Error: not a text file: binary_read.tmp", workspace.read_file("binary_read.tmp")
    end
  end

  def test_existing_file_write_requires_prior_successful_read
    with_temp_workspace do |workspace, dir|
      path = "kward_existing_requires_read.txt"
      File.write(File.join(dir, path), "old\n")

      result = workspace.write_file(path, "new\n", read_paths: [])

      assert_equal "Error: existing file must be read before writing: #{path}", result
      assert_equal "old\n", File.read(File.join(dir, path))
    end
  end

  def test_accepted_write_modifies_new_file
    with_temp_workspace do |workspace, dir|
      path = "kward_accepted_new.txt"

      result = workspace.write_file(path, "hello\n", read_paths: [])

      assert_equal "Wrote 6 bytes to #{path}", result
      assert_equal "hello\n", File.read(File.join(dir, path))
    end
  end

  def test_existing_file_can_be_written_after_successful_read
    with_temp_workspace do |workspace, dir|
      path = "kward_existing_after_read.txt"
      File.write(File.join(dir, path), "old\n")
      conversation = Kward::Conversation.new
      content = workspace.read_file(path)
      conversation.mark_read(workspace.resolved_path(path)) unless content.start_with?("Error:")

      result = workspace.write_file(path, "new\n", read_paths: conversation.read_paths)

      assert_includes result, "Wrote 4 bytes to #{path}"
      assert_includes result, "--- #{path}"
      assert_includes result, "-old"
      assert_includes result, "+new"
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
      assert_includes result, "diff truncated to #{Kward::Workspace::MAX_EDIT_DIFF_BYTES} bytes; full diff stats: +600|-600"
      assert_operator result.bytesize, :<, Kward::Workspace::MAX_EDIT_DIFF_BYTES + 200
      assert_equal({ additions: 600, deletions: 600 }, Kward::SessionDiff.count(result[/--- .*\z/m]))
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

  def test_run_shell_command_cancelled_raises_cancellation
    cancellation = Kward::Cancellation.new
    error = nil
    worker = Thread.new do
      Kward::Workspace.new.run_shell_command("ruby -e 'sleep 10'", cancellation: cancellation)
    rescue StandardError => e
      error = e
    end

    sleep 0.1
    cancellation.cancel!
    worker.join(2)

    refute worker.alive?, "expected cancelled command to finish"
    assert_instance_of Kward::Cancellation::CancelledError, error
  ensure
    worker&.kill if worker&.alive?
  end

end
