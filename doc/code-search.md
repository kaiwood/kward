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

Tokens are used for GitHub API requests and are not included in tool output.

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

Search and read results are bounded so Kward does not load large external repositories into context by accident. Oversized and binary files are skipped.
