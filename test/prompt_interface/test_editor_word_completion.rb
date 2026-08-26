require_relative "../test_helper"

class TestPromptInterfaceEditorWordCompletion < KwardTestCase
  def test_tab_completes_a_word_from_earlier_in_the_buffer
    with_editor("calculate_total value\ncal") do |prompt, editor|
      editor.cursor = editor.buffer.length

      prompt.send(:handle_editor_key, "\t")

      assert_equal "calculate_total value\ncalculate_total", editor.buffer
      assert_equal "Completion 1/1: calculate_total", editor.status
    end
  end

  def test_tab_completes_a_word_from_later_in_the_buffer
    with_editor("cal\ncalculate_total") do |prompt, editor|
      editor.cursor = 3

      prompt.send(:handle_editor_key, "\t")

      assert_equal "calculate_total\ncalculate_total", editor.buffer
      assert_equal 15, editor.cursor
    end
  end

  def test_repeated_tab_cycles_candidates_by_proximity
    with_editor("alpha alpine albatross\nal") do |prompt, editor|
      editor.cursor = editor.buffer.length

      prompt.send(:handle_editor_key, "\t")
      assert_equal "alpha alpine albatross\nalbatross", editor.buffer

      prompt.send(:handle_editor_key, "\t")
      assert_equal "alpha alpine albatross\nalpine", editor.buffer
      assert_equal "Completion 2/3: alpine", editor.status

      prompt.send(:handle_editor_key, "\t")
      assert_equal "alpha alpine albatross\nalpha", editor.buffer

      prompt.send(:handle_editor_key, "\t")
      assert_equal "alpha alpine albatross\nalbatross", editor.buffer
    end
  end

  def test_non_tab_key_ends_the_completion_cycle
    with_editor("alpha alpine\nal") do |prompt, editor|
      editor.cursor = editor.buffer.length
      original_status = editor.status

      prompt.send(:handle_editor_key, "\t")
      prompt.send(:handle_editor_key, "\e[D")
      prompt.send(:handle_editor_key, "\e[C")
      prompt.send(:handle_editor_key, "\t")

      assert_equal "alpha alpine\nalpine  ", editor.buffer
      assert_equal original_status, editor.status
    end
  end

  def test_tab_navigation_ends_the_completion_cycle
    with_editor("alpha alpine\nal") do |prompt, editor|
      prompt.instance_variable_set(:@tabs, [Object.new, Object.new])
      prompt.instance_variable_set(:@tab_keybindings, "ctrl")
      editor.cursor = editor.buffer.length
      original_status = editor.status

      prompt.send(:handle_editor_key, "\t")
      result = prompt.send(:handle_key, "\e[9;5u")

      assert_equal({ tab_action: :next }, result)
      assert_equal original_status, editor.status
    end
  end

  def test_completion_replaces_the_rest_of_the_word_after_the_cursor
    with_editor("calculate_total\ncalx") do |prompt, editor|
      editor.cursor = editor.buffer.rindex("calx") + 3

      prompt.send(:handle_editor_key, "\t")

      assert_equal "calculate_total\ncalculate_total", editor.buffer
      assert_equal editor.buffer.length, editor.cursor
    end
  end

  def test_completion_supports_unicode_words
    with_editor("caféine\ncaf") do |prompt, editor|
      editor.cursor = editor.buffer.length

      prompt.send(:handle_editor_key, "\t")

      assert_equal "caféine\ncaféine", editor.buffer
    end
  end

  def test_csi_u_tab_completes_the_word
    with_editor("completion\ncomp") do |prompt, editor|
      editor.cursor = editor.buffer.length

      prompt.send(:handle_editor_key, "\e[9u")

      assert_equal "completion\ncompletion", editor.buffer
    end
  end

  def test_completion_uses_each_editor_mode
    %w[modern emacs vibe].each do |mode|
      with_editor("completion\ncomp", mode: mode) do |prompt, editor|
        editor.vibe_mode = "insert" if mode == "vibe"
        editor.cursor = editor.buffer.length

        prompt.send(:handle_editor_key, "\t")

        assert_equal "completion\ncompletion", editor.buffer, "expected completion in #{mode} mode"
      end
    end
  end

  def test_tab_keeps_selection_indentation_behavior
    with_editor("completion\ncomp") do |prompt, editor|
      editor.cursor = editor.buffer.length
      editor.selection_anchor = editor.cursor - 4

      prompt.send(:handle_editor_key, "\t")

      assert_equal "completion\n  ", editor.buffer
    end
  end

  def test_modern_mode_can_undo_completion
    with_editor("completion\ncomp") do |prompt, editor|
      editor.cursor = editor.buffer.length

      prompt.send(:handle_editor_key, "\t")
      prompt.send(:handle_editor_key, Kward::TerminalKeys::CTRL_Z)

      assert_equal "completion\ncomp", editor.buffer
    end
  end

  private

  def with_editor(content, mode: "modern")
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "example.txt"), content)
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: mode)
        assert prompt.send(:open_editor, "example.txt")
        yield prompt, prompt.instance_variable_get(:@editor_state)
      end
    end
  end
end
