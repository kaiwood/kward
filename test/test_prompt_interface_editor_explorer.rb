require_relative "test_helper"

class TestPromptInterfaceEditorExplorer < KwardTestCase
  def test_explorer_has_its_own_rounded_frame_aligned_with_the_editor
    with_editor do |prompt, _root|
      toggle(prompt)
      rows = frame(prompt)
      assert_match(/\A╭ \[Explorer\] ─+╮╭ Edit /, rows.first)
      assert_match(/\A│ +Open Editors +││/, rows[1])
      assert_match(/\A╰─+╯╰─+╯\z/, rows.last)
      assert rows.all? { |row| Kward::TerminalText.width(row) == 80 }

      closing_bracket = rows.first.index("]") + 1
      click(prompt, closing_bracket, 1)
      refute_match(/Open Editors/, frame(prompt).join)
    end
  end

  def test_switching_files_and_toggling_preserve_unsaved_text_cursor_and_undo
    with_editor do |prompt, root|
      key(prompt, "X")
      toggle(prompt)
      assert_match(/Open Editors/, frame(prompt).join)
      click_row(prompt, /▸ lib/)
      click_row(prompt, /^│\s+b\.txt\s+│/)
      assert_match(/Edit lib\/b.txt/, frame(prompt).first)

      toggle(prompt)
      refute_match(/Open Editors/, frame(prompt).join)
      toggle(prompt)
      click_row(prompt, /a.txt \*\s+│/)
      assert_match(/Xalpha/, frame(prompt).join)
      assert_equal [0, 1], editor(prompt).cursor_line_and_column
      assert_equal "alpha\n", File.read(File.join(root, "a.txt"))

      click(prompt, 27 + 8, 2)
      assert_equal [0, 0], editor(prompt).cursor_line_and_column
      key(prompt, "\x1a")
      assert_equal "alpha\n", editor(prompt).buffer
    end
  end

  def test_narrow_explorer_arrow_navigation_and_enter_return_to_editor
    with_editor(width: 45) do |prompt, _root|
      toggle(prompt)
      assert_match(/Open Editors/, frame(prompt).join)
      assert_match(/\A╭ \[Explorer\] ─+╮\z/, frame(prompt).first)
      assert_match(/\A╰─+╯\z/, frame(prompt).last)
      click_row(prompt, /▸ lib/)
      key(prompt, "\e[B")
      assert_equal "alpha\n", editor(prompt).buffer
      key(prompt, "\e[13u")
      assert_match(/Edit lib\/b.txt/, frame(prompt).first)
      assert_equal "beta\n", editor(prompt).buffer
      toggle(prompt)
      assert_match(/Open Editors/, frame(prompt).join)
    end
  end

  def test_quit_from_a_clean_buffer_returns_to_an_unsaved_buffer
    with_editor do |prompt, root|
      key(prompt, "X")
      toggle(prompt)
      click_row(prompt, /▸ lib/)
      click_row(prompt, /^│\s+b\.txt\s+│/)
      toggle(prompt)
      key(prompt, "\x11")
      assert prompt.editing_file?
      assert_match(/Edit a.txt \*/, frame(prompt).first)
      key(prompt, "\x13")
      key(prompt, "\x11")
      refute prompt.editing_file?
      assert_equal "Xalpha\n", File.read(File.join(root, "a.txt"))
    end
  end

  def test_tab_snapshot_retains_sidebar_and_inactive_buffers
    with_editor do |prompt, _root|
      key(prompt, "X")
      toggle(prompt)
      click_row(prompt, /▸ lib/)
      click_row(prompt, /^│\s+b\.txt\s+│/)
      snapshot = prompt.tab_view_snapshot
      prompt.restore_tab_view_snapshot({})
      refute prompt.editing_file?
      prompt.restore_tab_view_snapshot(snapshot)
      click_row(prompt, /a.txt \*\s+│/)
      assert_equal "Xalpha\n", editor(prompt).buffer
    end
  end

  def test_workspace_tree_handles_unicode_and_rejects_binary_and_outside_symlinks
    with_editor do |prompt, root|
      assert system("git", "init", "-q", chdir: root)
      File.write(File.join(root, "grün.txt"), "German\n")
      File.binwrite(File.join(root, "binary.dat"), "sample\0data")
      File.symlink(File.expand_path(__FILE__), File.join(root, "outside.txt"))
      toggle(prompt)
      click_row(prompt, /binary.dat/)
      assert_match(/only open text files/, frame(prompt).join)
      click_row(prompt, /outside.txt/)
      assert_match(/inside the workspace/, frame(prompt).join)
      click_row(prompt, /grün.txt/)
      assert_equal "German\n", editor(prompt).buffer
    end
  end

  def test_standalone_edit_loop_opens_and_edits_a_file_from_the_explorer_in_vibe_mode
    Dir.mktmpdir do |root|
      File.write(File.join(root, "a.txt"), "alpha\n")
      File.write(File.join(root, "b.txt"), "beta\n")
      output = StringIO.new
      prompt = Kward::PromptInterface.new(input: StringIO.new, output: output, workspace_root: root, editor_mode: "vibe")
      prompt.define_singleton_method(:screen_width) { 80 }
      prompt.define_singleton_method(:screen_height) { 14 }
      events = ["\e[<0;69;1M", "\e[<0;4;6M", "\e", "i", "X", "\e", ":", "w", "q", "\r"]
      prompt.define_singleton_method(:read_key) { |nonblock:| events.shift || raise("Editor did not quit") }

      assert prompt.edit_file("a.txt", base_dir: root)
      assert_equal "Xbeta\n", File.read(File.join(root, "b.txt"))
      assert_equal "alpha\n", File.read(File.join(root, "a.txt"))
    ensure
      prompt&.close
    end
  end

  def test_restores_explorer_preferences_without_reopening_buffers
    with_editor do |prompt, root|
      toggle(prompt)
      click_row(prompt, /▸ lib/)
      click_row(prompt, /b\.txt/)
      click_row(prompt, /▾ lib/)
      click_row(prompt, /▸ lib/)
      assert prompt.send(:close_editor)

      restored = new_editor(root)
      assert_match(/Open Editors/, frame(restored).join)
      assert_match(/▾ lib/, frame(restored).join)
      assert_equal 1, frame(restored).count { |row| row.include?("b.txt") }
      assert_equal "alpha\n", editor(restored).buffer

      click(restored, 4, 12)
      key(restored, "\r")
      assert_match(/▸ lib/, frame(restored).join)
      toggle(restored)
      assert restored.send(:close_editor)
      refute_match(/Open Editors/, frame(new_editor(root)).join)
    end
  end

  def test_explorer_preferences_are_private_and_scoped_to_the_workspace
    with_editor do |prompt, root|
      toggle(prompt)
      assert prompt.send(:close_editor)
      state_path = Kward::ConfigFiles.editor_explorer_state_path(root)
      assert_equal 0o600, File.stat(state_path).mode & 0o777
      assert_equal %w[expanded offset selection visible], JSON.parse(File.read(state_path)).keys.sort

      other = File.join(root, "other")
      FileUtils.mkdir_p(other)
      File.write(File.join(other, "a.txt"), "other\n")
      refute_match(/Open Editors/, frame(new_editor(other)).join)
      File.write(state_path, "invalid JSON")
      refute_match(/Open Editors/, frame(new_editor(root)).join)
    end
  end

  def test_vibe_pane_chords_move_focus_without_moving_the_editor_cursor
    with_editor(mode: "vibe") do |prompt, _root|
      toggle(prompt)
      key(prompt, "\e[119;5:1u")
      key(prompt, "\e[119;5:2u")
      key(prompt, "\e[119;5:3u")
      key(prompt, "\e[104u")
      key(prompt, "l")
      assert_equal [0, 0], editor(prompt).cursor_line_and_column

      %w[j k].each do |direction|
        key(prompt, "\x17")
        key(prompt, direction)
        key(prompt, "l")
        assert_equal [0, 0], editor(prompt).cursor_line_and_column
      end

      key(prompt, "\e[27;5;119~")
      key(prompt, "l")
      key(prompt, "l")
      assert_equal [0, 1], editor(prompt).cursor_line_and_column

      key(prompt, "\x17")
      key(prompt, "\x17")
      key(prompt, "l")
      assert_equal [0, 1], editor(prompt).cursor_line_and_column

      key(prompt, "\x17")
      key(prompt, "\x17")
      key(prompt, "l")
      assert_equal [0, 2], editor(prompt).cursor_line_and_column
    end
  end

  def test_vibe_pane_chords_switch_the_visible_pane_at_narrow_widths
    with_editor(width: 45, mode: "vibe") do |prompt, _root|
      toggle(prompt)
      key(prompt, "\x17")
      key(prompt, "l")
      assert_match(/Edit a.txt/, frame(prompt).first)
      key(prompt, "\x17")
      key(prompt, "h")
      assert_match(/Open Editors/, frame(prompt).join)
    end
  end

  def test_vibe_insert_mode_keeps_ctrl_w_word_deletion
    with_editor(mode: "vibe") do |prompt, _root|
      toggle(prompt)
      key(prompt, "i")
      key(prompt, "w")
      key(prompt, "\x17")
      key(prompt, "h")
      assert_equal "halpha\n", editor(prompt).buffer
    end
  end

  def test_modern_mode_does_not_treat_ctrl_w_as_a_pane_prefix
    with_editor do |prompt, _root|
      toggle(prompt)
      key(prompt, "w")
      key(prompt, "\x17")
      key(prompt, "h")
      assert_equal "halpha\n", editor(prompt).buffer
    end
  end

  private

  def with_editor(width: 80, mode: "modern")
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "lib"))
      File.write(File.join(root, "a.txt"), "alpha\n")
      File.write(File.join(root, "lib/b.txt"), "beta\n")
      Dir.mktmpdir do |config|
        with_env("KWARD_CONFIG_PATH" => File.join(config, "config.json")) do
          yield new_editor(root, width: width, mode: mode), root
        end
      end
    end
  end

  def new_editor(root, width: 80, mode: "modern")
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, workspace_root: root, editor_mode: mode)
    prompt.define_singleton_method(:screen_width) { width }
    prompt.define_singleton_method(:screen_height) { 14 }
    assert prompt.send(:open_editor, "a.txt")
    prompt
  end

  def editor(prompt)
    prompt.instance_variable_get(:@editor_state)
  end

  def frame(prompt)
    width, height = prompt.send(:screen_size)
    rows, = prompt.send(:composer_layout, width, height)
    rows.map { |row| strip_ansi(row) }
  end

  def key(prompt, sequence)
    prompt.send(:handle_key, sequence)
  end

  def click(prompt, column, row)
    key(prompt, "\e[<0;#{column};#{row}M")
    key(prompt, "\e[<0;#{column};#{row}m")
  end

  def click_row(prompt, label)
    row = frame(prompt).index { |line| line.match?(label) }
    refute_nil row, frame(prompt).join("\n")
    click(prompt, 4, row + 1)
  end

  def toggle(prompt)
    column = frame(prompt).first.index("[Explorer]")
    refute_nil column
    click(prompt, column + 1, 1)
  end
end
