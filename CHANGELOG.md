# Changelog

All notable changes to Kward will be documented in this file.

## Unreleased

- Added colored CLI help/version commands and examples, with command names taking precedence over one-shot prompts.
- Added `--working-directory PATH` as a global option for running any CLI mode from another workspace.
- Changed memory retrieval and listing to use a global core, workspace core, workspace soft hierarchy, and added `/memory relax` for downgrading global core memories to the current workspace.
- Removed the obsolete `/crew` command reservation and unreleased RPC compatibility aliases.
- Added Session Tree support with a CLI `/tree` command plus RPC persisted entry IDs, labels, label timestamps, and branch navigation.
- Changed session tree rendering to match Pi's active-path-first branch display, markers, tool rows, and connector prefixes.
- Changed session tree navigation so all persisted entry points are selectable without automatically running anything.
- Fixed the TUI `/tree` selector to start on the current tree position, or the last item for a fresh tree.
- Fixed the normal session list/resume picker to stay in recent modification-time order, delete empty unnamed sessions, return the full list by default, and avoid test-created session pollution.
- Added RPC `ui/footer` notifications for Kward plugin footers.
- Fixed RPC model selection to accept lowercase provider IDs from UI clients.
- Added `!` shell commands in the interactive CLI composer.
- Added the active persona label to RPC `runtime/state` responses.
- Fixed cloned sessions to keep the current session name after renaming.

## 0.66.0 - 2026-06-12 - Codename: Order

- Initial public release.
- Prepare RubyGems packaging for the initial public release.
