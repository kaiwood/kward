require_relative "test_helper"

class TestCompatibilityRequirePaths < KwardTestCase
  LEGACY_REQUIRE_PATHS = %w[
    kward/adaptive_pty_output_sink
    kward/ansi
    kward/cli_transcript_formatter
    kward/clipboard
    kward/detached_run
    kward/interactive_pty_runner
    kward/kwsh
    kward/kwshrc
    kward/local_command_runner
    kward/local_pty_command_runner
    kward/path_guard
    kward/persistent_shell_session
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
    kward/shell_prompt
    kward/shell_prompt_session
    kward/terminal_image_support
    kward/terminal_keys
    kward/terminal_sequences
    kward/terminal_text
    kward/workspace
    kward/workspace_factory
  ].freeze

  def test_legacy_require_paths_load_canonical_implementations
    script = "ARGV.each { |path| require path }"

    assert system(RbConfig.ruby, "-Ilib", "-e", script, *LEGACY_REQUIRE_PATHS)
  end
end
