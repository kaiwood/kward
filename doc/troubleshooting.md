# Troubleshooting

This page collects environment-specific issues that can affect Kward but are not caused by Kward itself.

## `gem install kward` succeeds, but `kward` is not found with rbenv

When using rbenv, RubyGems installs gem executables into the active Ruby version's `bin` directory. rbenv then exposes those executables through shims in `$RBENV_ROOT/shims`.

If `gem install kward` succeeds but `kward` is not available on your `PATH`, first check whether RubyGems installed the executable:

```bash
rbenv which kward
```

If that prints a path such as:

```text
/Users/you/.rbenv/versions/4.0.3/bin/kward
```

then the gem executable exists and the missing command is likely an rbenv shim issue.

Regenerate shims:

```bash
rbenv rehash
```

Then verify the shim exists:

```bash
test -x "$RBENV_ROOT/shims/kward"
```

If `rbenv rehash` fails with an error like:

```text
rbenv: cannot rehash: /Users/you/.rbenv/shims/.rbenv-shim exists
```

remove the stale rbenv prototype shim and rehash again:

```bash
rm -f "$RBENV_ROOT/shims/.rbenv-shim"
rbenv rehash
```

After that, `kward` should be available through the rbenv shim:

```bash
which kward
kward --help
```

This stale `.rbenv-shim` file can be left behind by an interrupted `rbenv rehash` or gem installation. It is local rbenv state, not a Kward packaging issue.
