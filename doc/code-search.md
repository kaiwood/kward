# Code search

Code search lets Kward inspect public open-source repositories while working on your project.

Use it when examples from real packages would make an answer better:

- checking how a library API is actually used,
- finding test patterns before adding tests,
- comparing implementation approaches,
- reading source for a dependency,
- investigating a public bug fix or release.

Example prompts:

```text
Look up how tty-prompt handles key bindings before changing our composer.
Find examples of Faraday retry middleware usage.
Inspect how Rails structures generator tests.
Check the source for this gem before recommending an API call.
```

## How it works

The `code_search` tool can:

1. find package metadata from registries,
2. discover likely GitHub repositories,
3. clone public repositories into a local cache,
4. search cached files,
5. read bounded line ranges from cached files.

Kward should use this when the best answer depends on how another project actually implemented something.

## Supported ecosystems

`package_search` and `github_search` accept an `ecosystem` parameter to narrow results:

- `rubygems` — RubyGems
- `npm` — npm registry
- `pypi` — Python Package Index
- `crates` — crates.io (Rust)
- `go` — Go module documentation

When omitted, `package_search` requires a `package` name and infers the registry from the ecosystem. `github_search` uses the ecosystem as an optional hint alongside the search query.

## Cache location

Repositories are cached outside your workspace:

```text
~/.kward/cache/code_search
```

If `KWARD_CONFIG_PATH` points elsewhere, the cache lives beside that config directory under:

```text
cache/code_search
```

The cache is intentionally separate from your project. Kward uses GitHub `owner/name` cache keys and rejects absolute paths or path traversal when reading cached files.

## GitHub access

Code search uses live network access and the local `git` executable.

GitHub authentication is optional. To raise rate limits, set either:

```bash
GITHUB_TOKEN=...
```

or:

```bash
GH_TOKEN=...
```

Tokens are used for GitHub API requests and are not included in tool output. See [Configuration](configuration.md) for the full environment variable reference.

## Tool actions

The tool uses an `action` parameter:

| Action | Use it to... |
| --- | --- |
| `package_search` | find package metadata and likely source repositories. |
| `github_search` | search public GitHub repositories. |
| `repo_clone` | clone a GitHub repository into cache. |
| `repo_search` | search files in a cached repository. |
| `repo_read` | read a bounded line range from a cached file. |
| `list_cache` | show cached repositories. |
| `refresh_cache` | fetch updates for a cached repository. |
| `clear_cache` | remove a cached repository. |

### Action arguments

| Action | Required arguments | Optional arguments |
| --- | --- | --- |
| `package_search` | `ecosystem`, `package` | — |
| `github_search` | `query` | `ecosystem`, `max_results` |
| `repo_clone` | `repo` | — |
| `repo_search` | `repo`, `query` | `max_results`, `context_lines` |
| `repo_read` | `repo`, `path` | `start_line`, `line_count` |
| `list_cache` | — | — |
| `refresh_cache` | `repo` | — |
| `clear_cache` | `repo` | — |

- `repo` is a GitHub URL or `owner/name`.
- `query` is a plain-text search string (not regex). Matching is case-sensitive substring.
- `start_line` is 1-indexed.
- `context_lines` controls how many lines before and after a match are included in search snippets.

## Limits

Search and read results are bounded so Kward does not load large external repositories into context by accident:

- Search results: default 10 per query, max 50.
- Context lines in search snippets: default 2, max 5.
- Lines returned by `repo_read`: default 200, max 400.
- File size limit: 512 KB. Files larger than this are skipped during search and rejected on read.
- Scanned files in `repo_search`: max 5,000 files per scan. Files in `.git` directories, symlinks, files outside the repo root, and oversized files are skipped. Binary files fail gracefully via encoding detection and are skipped.
- Output truncation: 16 KB total per tool result.
- HTTP timeout: 10 seconds for all network requests.
