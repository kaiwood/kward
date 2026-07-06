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

  def test_open_diff_viewer_honors_explicit_unified_mode_on_wide_terminal
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, diff_view: "unified")
    prompt.define_singleton_method(:screen_width) { 160 }
    content = "@@ -1 +1 @@\n-old\n+new\n"

    prompt.send(:open_diff_viewer, "example.txt", content)

    state = prompt.instance_variable_get(:@editor_state)
    assert_equal Kward::DiffViewMode::UNIFIED, state.diff_view
    assert_equal ["@@ -1 +1 @@", "-old", "+new", ""], state.lines
  end
end
