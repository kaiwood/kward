# Contributing to Kward

Thank you for helping improve Kward. Small, focused changes with clear tests are the easiest to review and release.

## Before you start

- Search existing issues and pull requests for related work.
- Open an issue before a large feature, new dependency, protocol change, or broad restructuring.
- Report security concerns privately through [the security policy](SECURITY.md), not in a public issue.

## Set up the project

Kward requires Ruby 3.4 or newer.

```bash
git clone https://github.com/kaiwood/kward.git
cd kward
bundle install
bundle exec rake test
```

Run the CLI from the checkout with:

```bash
ruby lib/main.rb
ruby lib/main.rb "Explain this project"
```

See [Platform support](doc/platform-support.md) for operating-system and terminal expectations.

## Make a change

1. Keep the patch limited to one problem.
2. Follow the existing Ruby style and ownership boundaries.
3. Add focused Minitest coverage for behavior changes.
4. Update user documentation when commands, configuration, tools, protocols, or workflows change.
5. Add user-facing changes to the `[Unreleased]` section of `CHANGELOG.md`.

Avoid unrelated refactors, formatting-only churn, generated-file commits, and new dependencies unless they are necessary for the change.

## Verify the change

Run the smallest relevant test first, then the full suite before opening a pull request:

```bash
ruby -Itest test/test_cli.rb
bundle exec rake test
```

For documentation changes, also run:

```bash
bundle exec rake docs:check
```

The release preflight combines tests, documentation checks, package validation, and release metadata checks:

```bash
bundle exec rake release:preflight
```

Release preflight expects the current version and tag state to be ready for a release, so contributors normally do not need to run it for ordinary pull requests.

## Open a pull request

Describe:

- the user-visible problem;
- the chosen solution;
- tests and checks run;
- security, compatibility, or documentation implications;
- screenshots for visible UI changes.

A pull request should be understandable one commit at a time. Maintainers may ask for commits to be combined or reorganized before merge when that makes the final history clearer.
