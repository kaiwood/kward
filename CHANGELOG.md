# Changelog

All notable changes to Kward will be documented in this file.

## Unreleased

- Added Session Tree support with a CLI `/tree` command plus RPC persisted entry IDs, labels, label timestamps, and branch navigation.
- Changed session tree rendering to match Pi's active-path-first branch display, markers, tool rows, and connector prefixes.
- Changed session tree navigation so all persisted entry points are selectable without automatically running anything.
- Fixed the normal session list/resume picker to stay in recent modification-time order, delete empty unnamed sessions, return the full list by default, and avoid test-created session pollution.
- Added RPC `ui/footer` notifications for Kward plugin footers.
- Fixed RPC model selection to accept lowercase provider IDs from UI clients.
- Added `!` shell commands in the interactive CLI composer.
- Added the active persona label to RPC `runtime/state` responses.
- Fixed cloned sessions to keep the current session name after renaming.

## 0.66.0 - 2026-06-12 - Codename: Order

- Initial public release.
- Prepare RubyGems packaging for the initial public release.
