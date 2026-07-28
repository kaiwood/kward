require_relative "../test_helper"

class TestPromptInterfaceDiffViewer < KwardTestCase
  def test_open_diff_viewer_uses_unified_mode_when_auto_is_narrow
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, diff_view: "auto")
    prompt.define_singleton_method(:screen_width) { 100 }
    content = "@@ -1 +1 @@\n-old\n+new\n"

    prompt.send(:open_diff_viewer, "example.txt", content)

    state = prompt.instance_variable_get(:@editor_state)
    assert_equal Kward::DiffViewMode::UNIFIED, state.diff_view
    assert_equal ["@@ -1 +1 @@", "-old", "+new", ""], state.lines
  end

  def test_open_diff_viewer_uses_side_by_side_mode_when_auto_is_wide
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, diff_view: "auto")
    prompt.define_singleton_method(:screen_width) { 140 }
    content = "@@ -1,2 +1,2 @@\n unchanged\n-old\n+new\n"

    prompt.send(:open_diff_viewer, "example.txt", content)

    state = prompt.instance_variable_get(:@editor_state)
    assert_equal Kward::DiffViewMode::SIDE_BY_SIDE, state.diff_view
    assert_equal "@@ -1,2 +1,2 @@", state.lines[0]
    assert_includes state.lines[1], "unchanged"
    assert_includes state.lines[1], " │ "
    assert_includes state.lines[2], "old"
    assert_includes state.lines[2], "new"
    assert_includes state.lines[2], " │ "
  end

  def test_side_by_side_diff_wraps_each_column_when_soft_wrap_is_enabled
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, diff_view: "side_by_side", editor_soft_wrap: true)
    prompt.define_singleton_method(:screen_width) { 140 }
    deleted = "old #{"x" * 140}"
    added = "new #{"y" * 140}"

    prompt.send(:open_diff_viewer, "example.txt", "-#{deleted}\n+#{added}\n")

    rows = prompt.instance_variable_get(:@editor_state).lines.grep(/ │ /)
    assert_operator rows.length, :>, 1
    assert_equal deleted, rows.map { |row| row.split(" │ ", 2).first.delete_prefix("- ").rstrip }.join
    assert_equal added, rows.map { |row| row.split(" │ ", 2).last.delete_prefix("+ ").rstrip }.join
  end

  def test_side_by_side_diff_truncates_columns_when_soft_wrap_is_disabled
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, diff_view: "side_by_side", editor_soft_wrap: false)
    prompt.define_singleton_method(:screen_width) { 140 }
    added = "new #{"y" * 140}"

    prompt.send(:open_diff_viewer, "example.txt", "+#{added}\n")

    rows = prompt.instance_variable_get(:@editor_state).lines.grep(/ │ /)
    assert_equal 1, rows.length
    refute_includes rows.first, added
  end

  def test_open_diff_viewer_honors_explicit_unified_mode_on_wide_terminal
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, diff_view: "unified")
    prompt.define_singleton_method(:screen_width) { 160 }
    content = "@@ -1 +1 @@\n-old\n+new\n"

    prompt.send(:open_diff_viewer, "example.txt", content)

    state = prompt.instance_variable_get(:@editor_state)
    assert_equal Kward::DiffViewMode::UNIFIED, state.diff_view
    assert_equal ["@@ -1 +1 @@", "-old", "+new", ""], state.lines
  end

  def test_open_diff_viewer_ctrl_q_closes_with_csi_u_input
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new)
    prompt.send(:open_diff_viewer, "example.txt", "-old\n+new\n")

    prompt.send(:handle_editor_key, "\e[113;5u")

    refute prompt.send(:editor_active?)
  end
end
