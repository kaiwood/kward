require_relative "test_helper"

class TestSessionDiff < KwardTestCase
  def test_counts_unified_diff_lines_without_headers
    counts = Kward::SessionDiff.count(<<~DIFF)
      --- file.txt
      +++ file.txt
      @@ -1,2 +1,3 @@
       unchanged
      -old
      +new
      +extra
    DIFF

    assert_equal({ additions: 2, deletions: 1 }, counts)
  end

  def test_discounts_unchanged_lines_inside_inflated_replacement_blocks
    counts = Kward::SessionDiff.count(<<~DIFF)
      --- file.txt
      +++ file.txt
      @@ -1,5 +1,5 @@
       line 1
      -line 2
      -line 3
      -line 4
      +line 2 changed
      +line 3
      +line 4 changed
       line 5
    DIFF

    assert_equal({ additions: 2, deletions: 2 }, counts)
  end

  def test_discounts_inflated_kward_workspace_diff_for_far_apart_edits
    old_content = (1..20).map { |index| "line #{index}" }.join("\n")
    new_content = old_content.sub("line 2", "line 2 changed").sub("line 19", "line 19 changed")
    diff = Kward::Workspace.new.send(:unified_diff, "file.txt", old_content, new_content)

    assert_equal({ additions: 2, deletions: 2 }, Kward::SessionDiff.count(diff))
  end

  def test_counts_reordered_lines_as_changes
    counts = Kward::SessionDiff.count(<<~DIFF)
      --- file.txt
      +++ file.txt
      @@ -1,4 +1,4 @@
       a
      -b
      -c
      +c
      +b
       d
    DIFF

    assert_equal({ additions: 1, deletions: 1 }, counts)
  end

  def test_session_totals_are_net_for_repeated_edits_to_same_line
    diff = Kward::SessionDiff.new

    assert diff.add_diff(<<~DIFF)
      --- file.txt
      +++ file.txt
      @@ -1,3 +1,3 @@
       a
      -b
      +B
       c
    DIFF
    assert diff.add_diff(<<~DIFF)
      --- file.txt
      +++ file.txt
      @@ -1,3 +1,3 @@
       a
      -B
      +beta
       c
    DIFF

    assert_equal 1, diff.additions
    assert_equal 1, diff.deletions
  end

  def test_session_totals_cancel_reverted_changes
    diff = Kward::SessionDiff.new

    diff.add_diff("--- file.txt\n+++ file.txt\n@@ -1,1 +1,1 @@\n-old\n+new\n")
    diff.add_diff("--- file.txt\n+++ file.txt\n@@ -1,1 +1,1 @@\n-new\n+old\n")

    assert diff.empty?
  end

  def test_counts_truncated_diff_from_full_stats_marker
    counts = Kward::SessionDiff.count(<<~DIFF)
      --- file.txt
      +++ file.txt
      @@ -1,1000 +1,1000 @@
      -old 1
      -old 2
      ... diff truncated to 8192 bytes; full diff stats: +12|-34. Use read_file to inspect current content.
    DIFF

    assert_equal({ additions: 12, deletions: 34 }, counts)
  end

  def test_ignores_truncated_diff_without_full_stats
    counts = Kward::SessionDiff.count(<<~DIFF)
      --- file.txt
      +++ file.txt
      @@ -1,1000 +1,1000 @@
      -old 1
      -old 2
      ... diff truncated to 8192 bytes; use read_file to inspect current content.
    DIFF

    assert_equal({ additions: 0, deletions: 0 }, counts)
  end

  def test_add_tool_result_ignores_errors_and_no_diff_content
    diff = Kward::SessionDiff.new

    refute diff.add_tool_result("Error: refused\n--- file.txt\n+++ file.txt\n-old\n+new\n")
    refute diff.add_tool_result("Wrote 10 bytes to file.txt")

    assert diff.empty?
  end

  def test_from_session_file_prefers_normalized_tool_execution_diffs
    Dir.mktmpdir do |dir|
      path = File.join(dir, "session.jsonl")
      records = [
        { type: "session", id: "s", timestamp: Time.now.utc.iso8601(3), cwd: dir },
        { type: "message", message: { role: "tool", content: "Edited old\n--- old\n+++ old\n-old\n+new\n" } },
        { type: "tool_execution_end", isError: false, result: { isError: false, diff: "--- file.txt\n+++ file.txt\n-old\n+new\n+extra\n" } }
      ]
      File.write(path, records.map { |record| JSON.generate(record) }.join("\n"))

      diff = Kward::SessionDiff.from_session_file(path)

      assert_equal 2, diff.additions
      assert_equal 1, diff.deletions
    end
  end

  def test_content_from_session_file_returns_successful_tool_diffs_in_order
    Dir.mktmpdir do |dir|
      path = File.join(dir, "session.jsonl")
      records = [
        { type: "session", id: "s", timestamp: Time.now.utc.iso8601(3), cwd: dir },
        { type: "tool_execution_end", isError: false, result: { isError: false, diff: "--- one.txt\n+++ one.txt\n-old\n+new\n" } },
        { type: "tool_execution_end", isError: true, result: { isError: true, diff: "--- failed.txt\n+++ failed.txt\n-nope\n+nope\n" } },
        { type: "tool_execution_end", isError: false, result: { isError: false, diff: "--- two.txt\n+++ two.txt\n-old two\n+new two\n" } }
      ]
      File.write(path, records.map { |record| JSON.generate(record) }.join("\n"))

      content = Kward::SessionDiff.content_from_session_file(path)

      assert_includes content, "--- one.txt"
      assert_includes content, "+new"
      assert_includes content, "--- two.txt"
      assert_includes content, "+new two"
      refute_includes content, "failed.txt"
      assert_operator content.index("--- one.txt"), :<, content.index("--- two.txt")
    end
  end

  def test_normalized_non_mutation_tool_result_does_not_store_diff
    content = "Exit status: 0\n\nSTDOUT:\n--- file.txt\n+++ file.txt\n@@ -1,25 +0,0 @@\n" + (1..25).map { |index| "-line #{index}\n" }.join
    normalizer = Kward::RPC::ToolEventNormalizer.new(tool_call("run_shell_command", command: "git diff"), content: content)

    record = normalizer.execution_record

    refute record[:result].key?(:diff)
  end
end
