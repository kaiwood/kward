# Changelog

All notable changes to Kward will be documented in this file.

## [Unreleased]

### Fixed

- Fixed RPC session listing so it no longer deletes the active empty session file while UI clients are starting a first turn.

## [0.67.0] - 2026-06-13

### Added

- Added optional startup resume for the last active session in each workspace through `sessions.auto_resume: true`, including immediate restored transcript/persona data for RPC clients.
- Added `tools.workspace_guardrails: false` config support for allowing file tools to access paths outside the active workspace.
- Added `banner.enabled: false` config support for hiding the interactive terminal banner.
- Added colored CLI help/version commands, command-specific help, and stricter command precedence over one-shot prompts.
- Added `--working-directory PATH` as a global option for running any CLI mode from another workspace.
- Added `kward init` for installing the starter pack; `--install-starter-pack` remains as a compatibility alias.
- Added `kward doctor` to check local config, workspace, auth hints, Pan credentials, and writable directories.
- Added `--` as a prompt delimiter so option-like text can be sent as a one-shot prompt.
- Added `kward auth status` and `kward auth logout` for checking and clearing saved credentials without printing secrets.
- Added `/reload` and RPC runtime reload support for reloading installed plugins without restarting Kward.
- Added Session Tree support with a CLI `/tree` command plus RPC persisted entry IDs, labels, label timestamps, and branch navigation.
- Added RPC `ui/footer` notifications for Kward plugin footers.
- Added `!` shell commands in the interactive CLI composer.
- Added the active persona label to RPC `runtime/state` responses.

### Changed

- Expanded the interactive `/settings` command into categorized settings for model, accounts, memory, interface, tools, compaction, personalization, logging, and advanced config info.
- Changed RPC session deletion to use the OS trash/recycle bin when available before falling back to permanent file deletion.
- Changed automatic session naming to persist the first visible user turn, keeping slash prompt names unexpanded while still saving expanded prompt content.
- Changed Pan mode to start with the `kward pan` command; `--pan-mode` remains as a compatibility alias.
- Changed memory retrieval and listing to use a global core, workspace core, workspace soft hierarchy, and added `/memory relax` for downgrading global core memories to the current workspace.
- Changed session tree rendering to match Pi's active-path-first branch display, markers, tool rows, and connector prefixes.
- Changed session tree navigation so all persisted entry points are selectable without automatically running anything.

### Fixed

- Fixed RPC session deletion so empty unnamed sessions are explicitly deleted instead of being consumed by unused-session cleanup first.
- Fixed the TUI `/tree` selector to start on the current tree position, or the last item for a fresh tree.
- Fixed the normal session list/resume picker to stay in recent modification-time order, delete empty unnamed sessions, return the full list by default, and avoid test-created session pollution.
- Fixed RPC model selection to accept lowercase provider IDs from UI clients.
- Fixed cloned sessions to keep the current session name after renaming.

### Removed

- Removed the obsolete `/crew` command reservation and unreleased RPC compatibility aliases.

## [0.66.0] - 2026-06-12 - Codename: Order

### Added

- Initial public release.
- Prepare RubyGems packaging for the initial public release.
