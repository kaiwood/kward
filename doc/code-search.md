# Code search

Kward exposes a `code_search` tool so the agent can inspect public open-source code for implementation guidance.

The tool can:

- look up packages from RubyGems, npm, PyPI, crates.io, and Go package documentation
- find public GitHub source repositories from package metadata
- fall back to GitHub repository search when registry metadata has no source URL
- clone public GitHub repositories into Kward's cache
- search cached repository files and return bounded snippets with paths and line numbers
- read bounded line ranges from cached repository files
- list, refresh, and clear cached repositories

## Cache

Repositories are cloned under:

```text
~/.kward/cache/code_search
```

If `KWARD_CONFIG_PATH` points at another config location, the cache is stored next to that config directory under `cache/code_search`.

The tool keeps cloned repositories outside the current workspace. It uses safe cache keys derived from GitHub `owner/name` identifiers and rejects absolute paths or path traversal when reading files.

## GitHub access

`code_search` uses live network access and the local `git` executable. GitHub authentication is optional. If either `GITHUB_TOKEN` or `GH_TOKEN` is set, the token is sent to GitHub API requests. Without a token, GitHub requests are unauthenticated and may hit lower rate limits.

Tokens are not included in tool output.

## Actions

The tool has one schema with an `action` parameter:

- `package_search` - find package metadata and likely source repository
- `github_search` - search public GitHub repositories
- `repo_clone` - clone a GitHub repository into cache if needed
- `repo_search` - search cached repository files for text
- `repo_read` - read a bounded line range from a cached repository file
- `list_cache` - list cached repositories
- `refresh_cache` - fetch updates for a cached repository
- `clear_cache` - remove one cached repository

Search and read output is bounded to avoid loading excessive external source into context. Oversized and binary files are skipped.
