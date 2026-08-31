require_relative "test_helper"

class TestCompatibilityRequirePaths < KwardTestCase
  LEGACY_REQUIRE_PATHS = %w[
    kward/adaptive_pty_output_sink
    kward/ansi
    kward/cli_transcript_formatter
    kward/clipboard
    kward/detached_run
    kward/diff_view_mode
    kward/editor_mode
    kward/editor_prompt
    kward/editor_prompt_session
    kward/export_path
    kward/git_worktree_manager
    kward/interactive_pty_runner
    kward/kwsh
    kward/kwshrc
    kward/local_command_runner
    kward/local_pty_command_runner
    kward/markdown_code_block
    kward/markdown_transcript
    kward/openrouter_model_cache
    kward/path_guard
    kward/persistent_shell_session
    kward/plugin_chat_runtime
    kward/plugin_registry
    kward/project_files
    kward/pty_output_sink
    kward/pty_transcript_normalizer
    kward/session_catalog
    kward/session_diff
    kward/session_naming
    kward/session_store
    kward/session_trash
    kward/session_tree_nodes
    kward/session_tree_renderer
    kward/session_tree_tool_display
    kward/scratchpad_languages
    kward/scratchpad_runner
    kward/shell_prompt
    kward/shell_prompt_session
    kward/terminal_image_support
    kward/terminal_keys
    kward/terminal_sequences
    kward/tab_driver
    kward/tab_store
    kward/terminal_text
    kward/transcript_export
    kward/workspace
    kward/workspace_factory
  ].freeze

  def test_legacy_require_paths_load_canonical_implementations
    script = "ARGV.each { |path| require path }"

    assert system(RbConfig.ruby, "-Ilib", "-e", script, *LEGACY_REQUIRE_PATHS)
  end
end
