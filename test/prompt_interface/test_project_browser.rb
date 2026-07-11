require_relative "../test_helper"

class TestPromptInterfaceProjectBrowser < KwardTestCase
  def test_prompt_interface_shows_file_overlay_and_completes_selection
    input, writer = IO.pipe
    output = StringIO.new
    writer.write("@li\t\r")
    writer.close
    prompt = Kward::PromptInterface.new(input: input, output: output)
    prompt.instance_variable_set(:@file_mention_paths, ["README.md", "lib/main.rb"])

    assert_equal "@lib/main.rb", prompt.ask("You>")
    stripped = strip_ansi(output.string)
    assert_includes stripped, "╭ Files"
    assert_includes stripped, "› lib/main.rb"
    assert_includes stripped, "╰"
  ensure
    input&.close unless input&.closed?
  end

  def test_prompt_interface_file_overlay_completes_active_mention_in_middle_of_input
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs")
    prompt.instance_variable_set(:@file_mention_paths, ["doc/api.md", "lib/main.rb"])
    prompt.send(:composer_input=, "read @api please")
    prompt.send(:composer_cursor=, 9)

    assert prompt.send(:complete_selected_file_mention)
    assert_equal "read @doc/api.md please", prompt.send(:composer_input)
    assert_equal "read @doc/api.md".length, prompt.send(:composer_cursor)
  end

  def test_prompt_interface_file_overlay_down_selects_next_match
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs")
    prompt.instance_variable_set(:@file_mention_paths, ["README.md", "lib/main.rb"])
    prompt.send(:composer_input=, "@")
    prompt.send(:composer_cursor=, 1)

    prompt.send(:handle_key, "\e[B")

    assert_equal "lib/main.rb", prompt.send(:selected_file_mention_path)
  end

  def test_prompt_interface_file_overlay_shows_no_matches
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs")
    prompt.instance_variable_set(:@file_mention_paths, ["README.md"])
    prompt.send(:composer_input=, "@missing")
    prompt.send(:composer_cursor=, 8)

    rows = prompt.send(:file_overlay_rows, 80)

    assert_includes strip_ansi(rows.join("\n")), "No matching files"
  end

  def test_prompt_interface_file_overlay_limits_matches
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs")
    prompt.instance_variable_set(:@file_mention_paths, 250.times.map { |index| "lib/file#{index}.rb" })
    prompt.send(:composer_input=, "@")
    prompt.send(:composer_cursor=, 1)

    matches = prompt.send(:file_overlay_matches)

    assert_equal Kward::PromptInterface::FileOverlay::FILE_MENTION_RESULT_LIMIT, matches.length
    assert_equal "lib/file199.rb", matches.last
  end

  def test_prompt_interface_project_browser_renders_nested_tree_and_opens_file
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "lib", "kward"))
      File.write(File.join(dir, "lib", "kward", "agent.rb"), "agent\n")
      File.write(File.join(dir, "README.md"), "readme\n")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs")
        prompt.instance_variable_set(:@file_mention_paths, ["README.md", "lib/kward/agent.rb"])

        assert prompt.open_project_browser
        rows = strip_ansi(prompt.send(:project_browser_rows, 80).join("\n"))

        assert_includes rows, "▾ lib/"
        assert_includes rows, "▾ kward/"
        assert_includes rows, "agent.rb"

        prompt.send(:select_next_project_browser_row)
        prompt.send(:select_next_project_browser_row)
        prompt.send(:open_or_toggle_selected_project_browser_row)

        editor = prompt.instance_variable_get(:@editor_state)
        assert_equal File.realpath(File.join(dir, "lib", "kward", "agent.rb")), editor.path
      end
    end
  end

  def test_prompt_interface_project_browser_renders_nerd_font_icons_when_enabled
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs", project_browser_icon_theme: "nerd-font")

    assert_equal "▾  lib/", prompt.send(:project_browser_row_text, { name: "lib", path: "lib", depth: 0, directory: true, expanded: true })
    assert_equal "   main.rb", prompt.send(:project_browser_row_text, { name: "main.rb", path: "lib/main.rb", depth: 0, directory: false })
    assert_equal "   README.md", prompt.send(:project_browser_row_text, { name: "README.md", path: "README.md", depth: 0, directory: false })
    assert_equal "   notes.txt", prompt.send(:project_browser_row_text, { name: "notes.txt", path: "notes.txt", depth: 0, directory: false })
  end

  def test_prompt_interface_project_browser_restores_after_editor_closes
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "lib", "kward"))
      File.write(File.join(dir, "lib", "kward", "agent.rb"), "agent\n")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs")
        prompt.instance_variable_set(:@file_mention_paths, ["lib/kward/agent.rb"])
        prompt.open_project_browser
        prompt.send(:select_next_project_browser_row)
        prompt.send(:select_next_project_browser_row)
        prompt.send(:open_or_toggle_selected_project_browser_row)

        refute prompt.send(:project_browser_visible?)
        prompt.send(:close_editor)

        assert prompt.send(:project_browser_visible?)
        assert_equal "lib/kward/agent.rb", prompt.send(:selected_project_browser_row)[:path]
      end
    end
  end

  def test_prompt_interface_project_browser_restores_search_input_after_editor_closes
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "lib"))
      File.write(File.join(dir, "lib", "main.rb"), "main\n")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs")
        prompt.instance_variable_set(:@file_mention_paths, ["README.md", "lib/main.rb"])
        prompt.open_project_browser
        prompt.send(:handle_project_browser_key, "/")
        prompt.send(:handle_project_browser_key, "m")
        prompt.send(:handle_project_browser_key, "a")
        prompt.send(:open_or_toggle_selected_project_browser_row)

        prompt.send(:close_editor)

        assert prompt.send(:project_browser_visible?)
        assert prompt.send(:project_browser_search_active?)
        assert_equal "ma", prompt.instance_variable_get(:@project_browser_state)[:query]
        assert_equal "ma", prompt.send(:composer_input)
      end
    end
  end

  def test_prompt_interface_project_browser_restores_tree_state_across_instances
    Dir.mktmpdir do |config_dir|
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models"))
        FileUtils.mkdir_p(File.join(dir, "app", "controllers"))
        File.write(File.join(dir, "app", "models", "user.rb"), "user\n")
        File.write(File.join(dir, "app", "controllers", "home.rb"), "home\n")
        with_env("KWARD_CONFIG_PATH" => File.join(config_dir, "config.json")) do
          Dir.chdir(dir) do
            prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs")
            prompt.instance_variable_set(:@file_mention_paths, ["app/controllers/home.rb", "app/models/user.rb"])
            prompt.open_project_browser
            rows = prompt.send(:project_browser_visible_rows)
            prompt.instance_variable_get(:@project_browser_state)[:selection_index] = rows.index { |row| row[:path] == "app/models" }

            prompt.send(:collapse_selected_project_browser_row)
            prompt.send(:dismiss_project_browser)

            restored = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs")
            restored.instance_variable_set(:@file_mention_paths, ["app/controllers/home.rb", "app/models/user.rb"])
            restored.open_project_browser

            assert_equal "app/models", restored.send(:selected_project_browser_row)[:path]
            refute restored.instance_variable_get(:@project_browser_state)[:expanded].include?("app/models")
            refute_includes restored.send(:project_browser_visible_rows).map { |row| row[:path] }, "app/models/user.rb"
          end
        end
      end
    end
  end

  def test_prompt_interface_project_browser_restores_missing_selection_to_visible_parent
    Dir.mktmpdir do |config_dir|
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models"))
        File.write(File.join(dir, "app", "models", "user.rb"), "user\n")
        with_env("KWARD_CONFIG_PATH" => File.join(config_dir, "config.json")) do
          Dir.chdir(dir) do
            prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs")
            prompt.instance_variable_set(:@file_mention_paths, ["app/models/user.rb"])
            prompt.open_project_browser
            rows = prompt.send(:project_browser_visible_rows)
            prompt.instance_variable_get(:@project_browser_state)[:selection_index] = rows.index { |row| row[:path] == "app/models/user.rb" }
            prompt.send(:dismiss_project_browser)

            File.delete(File.join(dir, "app", "models", "user.rb"))
            File.write(File.join(dir, "app", "models", "order.rb"), "order\n")
            restored = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs")
            restored.instance_variable_set(:@file_mention_paths, ["app/models/order.rb"])
            restored.open_project_browser

            assert_equal "app/models", restored.send(:selected_project_browser_row)[:path]
          end
        end
      end
    end
  end

  def test_prompt_interface_project_browser_does_not_restore_search_state
    Dir.mktmpdir do |config_dir|
      with_env("KWARD_CONFIG_PATH" => File.join(config_dir, "config.json")) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs")
        prompt.instance_variable_set(:@file_mention_paths, ["README.md", "lib/main.rb"])
        prompt.open_project_browser
        prompt.send(:handle_project_browser_key, "/")
        prompt.send(:handle_project_browser_key, "m")
        prompt.send(:handle_project_browser_key, "a")
        prompt.send(:dismiss_project_browser)

        restored = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs")
        restored.instance_variable_set(:@file_mention_paths, ["README.md", "lib/main.rb"])
        restored.open_project_browser

        refute restored.send(:project_browser_search_active?)
        assert_equal "", restored.instance_variable_get(:@project_browser_state)[:query]
        assert_equal "", restored.send(:composer_input)
      end
    end
  end

  def test_prompt_interface_project_browser_csi_u_escape_closes_browser
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs")
    prompt.instance_variable_set(:@file_mention_paths, ["README.md"])
    prompt.open_project_browser

    prompt.send(:handle_key, "\e[27;1u")

    refute prompt.send(:project_browser_visible?)
  end

  def test_prompt_interface_project_browser_csi_u_enter_opens_file
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "README.md"), "readme\n")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs")
        prompt.instance_variable_set(:@file_mention_paths, ["README.md"])
        prompt.open_project_browser

        prompt.send(:handle_key, "\e[13;1u")

        editor = prompt.instance_variable_get(:@editor_state)
        assert_equal File.realpath(File.join(dir, "README.md")), editor.path
      end
    end
  end

  def test_prompt_interface_project_browser_bundled_search_filters_and_inserts_mention
    input, writer = IO.pipe
    output = StringIO.new
    writer.write("/ma@\r")
    writer.close
    prompt = Kward::PromptInterface.new(input: input, output: output, editor_mode: "emacs")
    prompt.instance_variable_set(:@file_mention_paths, ["README.md", "lib/main.rb"])
    prompt.open_project_browser

    assert_equal "@lib/main.rb", prompt.ask("You>")
  ensure
    input&.close unless input&.closed?
  end

  def test_prompt_interface_project_browser_open_renders_hidden_cursor
    output = StringIO.new
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: output, editor_mode: "emacs")
    prompt.instance_variable_set(:@file_mention_paths, ["README.md"])
    prompt.start
    output.truncate(0)
    output.rewind
    prompt.instance_variable_set(:@cursor_visible, true)

    prompt.open_project_browser

    assert_includes output.string, Kward::PromptInterface::CURSOR_HIDE
  end

  def test_prompt_interface_project_browser_tab_starts_search
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs")
    prompt.instance_variable_set(:@file_mention_paths, ["README.md", "lib/main.rb"])
    prompt.open_project_browser

    prompt.send(:handle_key, "\t")
    prompt.send(:handle_key, "m")
    prompt.send(:handle_key, "a")

    assert prompt.send(:project_browser_search_active?)
    assert_equal "ma", prompt.instance_variable_get(:@project_browser_state)[:query]
    assert_equal "ma", prompt.send(:composer_input)
    assert_equal "lib/main.rb", prompt.send(:selected_project_browser_row)[:path]
  end

  def test_prompt_interface_project_browser_tab_exits_search_like_escape
    output = StringIO.new
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: output, editor_mode: "emacs")
    prompt.instance_variable_set(:@file_mention_paths, ["README.md", "lib/main.rb"])
    prompt.open_project_browser
    prompt.send(:handle_key, "\t")
    prompt.send(:handle_key, "m")
    prompt.send(:handle_key, "a")
    prompt.instance_variable_set(:@cursor_visible, true)

    prompt.send(:handle_key, "\t")
    prompt.send(:render_cursor_visibility_locked)

    refute prompt.send(:project_browser_search_active?)
    assert_equal "", prompt.instance_variable_get(:@project_browser_state)[:query]
    assert_equal "", prompt.send(:composer_input)
    assert_includes output.string, Kward::PromptInterface::CURSOR_HIDE
  end

  def test_prompt_interface_project_browser_csi_u_tab_exits_search_like_escape
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs")
    prompt.instance_variable_set(:@file_mention_paths, ["README.md", "lib/main.rb"])
    prompt.open_project_browser
    prompt.send(:handle_key, "\e[9u")
    prompt.send(:handle_key, "m")
    prompt.send(:handle_key, "a")

    prompt.send(:handle_key, "\e[9u")

    refute prompt.send(:project_browser_search_active?)
    assert_equal "", prompt.instance_variable_get(:@project_browser_state)[:query]
    assert_equal "", prompt.send(:composer_input)
  end

  def test_prompt_interface_project_browser_csi_u_tab_starts_search
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs")
    prompt.instance_variable_set(:@file_mention_paths, ["README.md", "lib/main.rb"])
    prompt.open_project_browser

    prompt.send(:handle_key, "\e[9u")
    prompt.send(:handle_key, "\e[109u")
    prompt.send(:handle_key, "\e[97u")

    assert prompt.send(:project_browser_search_active?)
    assert_equal "ma", prompt.instance_variable_get(:@project_browser_state)[:query]
    assert_equal "ma", prompt.send(:composer_input)
    assert_equal "lib/main.rb", prompt.send(:selected_project_browser_row)[:path]
  end

  def test_prompt_interface_project_browser_csi_u_slash_starts_search
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs")
    prompt.instance_variable_set(:@file_mention_paths, ["README.md", "lib/main.rb"])
    prompt.open_project_browser

    prompt.send(:handle_key, "\e[47u")
    prompt.send(:handle_key, "\e[109u")
    prompt.send(:handle_key, "\e[97u")

    assert prompt.send(:project_browser_search_active?)
    assert_equal "ma", prompt.instance_variable_get(:@project_browser_state)[:query]
    assert_equal "lib/main.rb", prompt.send(:selected_project_browser_row)[:path]
  end

  def test_prompt_interface_project_browser_cursor_is_visible_only_while_searching
    output = StringIO.new
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: output, editor_mode: "emacs")
    prompt.instance_variable_set(:@file_mention_paths, ["README.md"])
    prompt.open_project_browser
    prompt.instance_variable_set(:@cursor_visible, true)

    prompt.send(:render_cursor_visibility_locked)

    assert_includes output.string, Kward::PromptInterface::CURSOR_HIDE

    output.truncate(0)
    output.rewind
    prompt.send(:handle_key, "\e[47u")
    prompt.send(:render_cursor_visibility_locked)

    assert_includes output.string, Kward::PromptInterface::CURSOR_SHOW
  end

  def test_prompt_interface_project_browser_search_and_at_insert_mention
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs")
    prompt.instance_variable_set(:@file_mention_paths, ["README.md", "lib/main.rb"])
    prompt.open_project_browser

    prompt.send(:handle_project_browser_key, "/")
    prompt.send(:handle_project_browser_key, "m")
    prompt.send(:handle_project_browser_key, "a")

    assert_equal "ma", prompt.send(:composer_input)
    rows = strip_ansi(prompt.send(:composer_layout, 80, 20).first.join("\n"))
    assert_includes rows, "│ ma"
    refute_includes rows, "│ /ma"
    assert_equal "lib/main.rb", prompt.send(:selected_project_browser_row)[:path]
    prompt.send(:handle_project_browser_key, "@")

    assert_equal "@lib/main.rb", prompt.send(:composer_input)
    refute prompt.send(:project_browser_visible?)
  end

  def test_prompt_interface_project_browser_escape_from_search_clears_filter_input
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs")
    prompt.instance_variable_set(:@file_mention_paths, ["README.md", "lib/main.rb"])
    prompt.open_project_browser

    prompt.send(:handle_project_browser_key, "/")
    prompt.send(:handle_project_browser_key, "m")
    prompt.send(:handle_project_browser_key, "\e")

    refute prompt.send(:project_browser_search_active?)
    assert_equal "", prompt.send(:composer_input)
    assert prompt.send(:project_browser_visible?)
  end

  def test_prompt_interface_dollar_file_overlay_opens_editor
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "lib"))
      File.write(File.join(dir, "lib", "main.rb"), "puts :hi\n")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs")
        prompt.instance_variable_set(:@file_mention_paths, ["README.md", "lib/main.rb"])
        prompt.send(:composer_input=, "$li")
        prompt.send(:composer_cursor=, 3)

        assert prompt.send(:open_selected_file_in_editor)

        editor = prompt.instance_variable_get(:@editor_state)
        assert_equal File.realpath(File.join(dir, "lib", "main.rb")), editor.path
        assert_equal "puts :hi\n", editor.buffer
      end
    end
  end

  def test_prompt_interface_dollar_file_overlay_only_works_at_prompt_start
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs")
    prompt.instance_variable_set(:@file_mention_paths, ["README.md"])
    prompt.send(:composer_input=, "open $README")
    prompt.send(:composer_cursor=, "open $README".length)

    refute prompt.send(:file_open_overlay_visible?)
    refute prompt.send(:file_overlay_visible?)
  end

  def test_prompt_interface_persists_resolved_dollar_file_open_history
    Dir.mktmpdir do |config_dir|
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "lib"))
        File.write(File.join(dir, "lib", "main.rb"), "puts :hi\n")
        Dir.chdir(dir) do
          history = Kward::PromptHistory.new(config_dir: config_dir, cwd: dir)
          prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, prompt_history: history, editor_mode: "emacs")
          prompt.instance_variable_set(:@file_mention_paths, ["README.md", "lib/main.rb"])
          prompt.send(:composer_input=, "$li")
          prompt.send(:composer_cursor=, 3)

          assert prompt.send(:open_selected_file_in_editor)
          assert_equal ["$lib/main.rb"], Kward::PromptHistory.new(config_dir: config_dir, cwd: dir).values
        end
      end
    end
  end

  def test_prompt_interface_does_not_persist_failed_dollar_file_open_history
    Dir.mktmpdir do |config_dir|
      Dir.mktmpdir do |dir|
        Dir.chdir(dir) do
          history = Kward::PromptHistory.new(config_dir: config_dir, cwd: dir)
          prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, prompt_history: history, editor_mode: "emacs")
          prompt.instance_variable_set(:@file_mention_paths, [])
          prompt.send(:composer_input=, "$missing/new.txt")
          prompt.send(:composer_cursor=, "$missing/new.txt".length)

          refute prompt.send(:open_selected_file_in_editor, fallback_to_typed_path: true)
          assert_empty Kward::PromptHistory.new(config_dir: config_dir, cwd: dir).values
        end
      end
    end
  end

  def test_prompt_interface_enter_opens_typed_existing_file_outside_narrowdown
    Dir.mktmpdir do |dir|
      dir = File.realpath(dir)
      path = File.join(dir, "ignored.log")
      File.write(path, "ignored\n")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs")
        prompt.instance_variable_set(:@file_mention_paths, [])
        prompt.send(:composer_input=, "$ignored.log")
        prompt.send(:composer_cursor=, "$ignored.log".length)

        assert prompt.send(:open_selected_file_in_editor, fallback_to_typed_path: true)

        editor = prompt.instance_variable_get(:@editor_state)
        assert_equal path, editor.path
        assert_equal "ignored\n", editor.buffer
      end
    end
  end

  def test_prompt_interface_enter_opens_new_file_without_creating_until_save
    Dir.mktmpdir do |dir|
      dir = File.realpath(dir)
      path = File.join(dir, "new.txt")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs")
        prompt.instance_variable_set(:@file_mention_paths, [])
        prompt.send(:composer_input=, "$new.txt")
        prompt.send(:composer_cursor=, "$new.txt".length)

        assert prompt.send(:open_selected_file_in_editor, fallback_to_typed_path: true)
        refute File.exist?(path)

        editor = prompt.instance_variable_get(:@editor_state)
        assert editor.new_file
        assert_equal "", editor.buffer
        prompt.send(:handle_editor_key, "h")
        prompt.send(:handle_editor_key, "i")
        prompt.send(:handle_editor_key, "\x18")
        prompt.send(:handle_editor_key, "\x13")

        assert_equal "hi", File.read(path)
      end
    end
  end

  def test_prompt_interface_named_enter_opens_typed_new_file
    Dir.mktmpdir do |dir|
      dir = File.realpath(dir)
      FileUtils.mkdir_p(File.join(dir, "plan"))
      path = File.join(dir, "plan", "editor.md")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs")
        prompt.instance_variable_set(:@file_mention_paths, [])
        prompt.send(:composer_input=, "$plan/editor.md")
        prompt.send(:composer_cursor=, "$plan/editor.md".length)

        assert_equal :return, prompt.send(:key_name_for, "\r")
        assert prompt.send(:handle_key, "\r")
        refute File.exist?(path)

        editor = prompt.instance_variable_get(:@editor_state)
        assert editor.new_file
        assert_equal path, editor.path
      end
    end
  end

  def test_prompt_interface_refuses_new_file_with_missing_parent
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs")
        prompt.instance_variable_set(:@file_mention_paths, [])
        prompt.send(:composer_input=, "$missing/new.txt")
        prompt.send(:composer_cursor=, "$missing/new.txt".length)

        refute prompt.send(:open_selected_file_in_editor, fallback_to_typed_path: true)
        assert_nil prompt.instance_variable_get(:@editor_state)
        assert_includes prompt.instance_variable_get(:@file_editor_open_status), "parent directory is missing"
      end
    end
  end

  def test_prompt_interface_tab_does_not_open_typed_missing_file
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs")
        prompt.instance_variable_set(:@file_mention_paths, [])
        prompt.send(:composer_input=, "$new.txt")
        prompt.send(:composer_cursor=, "$new.txt".length)

        refute prompt.send(:open_selected_file_in_editor)
        assert_nil prompt.instance_variable_get(:@editor_state)
      end
    end
  end

  def test_prompt_interface_file_overlay_uses_git_ignored_project_files
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "lib"))
      File.write(File.join(dir, "lib", "main.rb"), "")
      File.write(File.join(dir, "ignored.log"), "")
      File.write(File.join(dir, ".gitignore"), "ignored.log\n")
      system("git", "init", "--quiet", chdir: dir)
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs")

        paths = prompt.send(:project_file_paths)

        assert_includes paths, "lib/main.rb"
        assert_includes paths, ".gitignore"
        refute_includes paths, "ignored.log"
      end
    end
  end

  def test_prompt_interface_file_overlay_fallback_scan_prunes_heavy_directories
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "lib"))
      FileUtils.mkdir_p(File.join(dir, "node_modules", "pkg"))
      FileUtils.mkdir_p(File.join(dir, "tmp"))
      File.write(File.join(dir, "lib", "main.rb"), "")
      File.write(File.join(dir, "node_modules", "pkg", "index.js"), "")
      File.write(File.join(dir, "tmp", "cache.txt"), "")
      Dir.chdir(dir) do
        prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new, editor_mode: "emacs")
        prompt.define_singleton_method(:git_project_file_paths) { [] }

        paths = prompt.send(:project_file_paths)

        assert_includes paths, "lib/main.rb"
        refute_includes paths, "node_modules/pkg/index.js"
        refute_includes paths, "tmp/cache.txt"
      end
    end
  end

end
