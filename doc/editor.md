```
Three Modes for the Elven-kings under the sky,
Seven Keymaps for the Dwarf-lords in their halls of stone,
Nine Editors for Mortal Men doomed to compile,
One Kward to rule them all,
One Kward to find them,
One Kward to bring them all and in the transcript bind them
In the Land of Ruby where the agents lie.
```

# Integrated Editor

Kward includes a small terminal editor with 3 editing modes to choose from: Modern, Emacs and Vibe. It opens inside the chat composer, so you can jump into a file, make a change, save it, and return to the conversation without switching tools.

Use it when you want to make a small edit while staying in Kward. For larger refactors, a full editor may still be more comfortable.

The editor is scoped to the current workspace. It only opens files inside that directory, which helps keep edits tied to the project you started Kward in.

## Quick start

Open the file picker by typing `$` as the first character in the composer:

```text
$lib/kward/agent.rb
```

As you type, Kward shows matching files. Use the arrow keys to choose one and press `Enter` to open it.

You can also type a relative path yourself and press `Enter`. If the file does not exist, Kward asks whether to create it.

A few things to know:

- `$` only opens the editor when it is the first character in the composer.
- Once a file opens, the composer becomes the editor.
- Save or quit to return to normal chat.
- If the file changed on disk while you were editing, Kward asks before overwriting it.
- If you quit with unsaved changes, Kward asks before discarding them.

## Example workflow

```text
$doc/editor.md
```

1. Type `$doc/editor.md` in the composer.
2. Pick the file from the matching results, or press `Enter` if the path is already complete.
3. Edit the file.
4. Save with `Ctrl+S` in Modern mode, `C-x C-s` in Emacs mode, or `:w` in Vibe mode.
5. Quit with `Ctrl+Q`, `C-x C-c`, or `:q`.
6. Continue chatting with Kward.

## What the editor supports

The editor is intentionally compact, but it covers the basics you need for quick changes:

- Syntax highlighting for common languages, including Ruby, JavaScript, TypeScript, JSON, Markdown, YAML, Shell, HTML, CSS, SCSS, Python, Go, Rust, Java, C#, C, C++, Swift, Kotlin, Lua, and SQL. Unknown file types render as plain text.
- Auto-indent, enabled by default. New lines inherit indentation, obvious closing tokens are re-indented, and Backspace in leading whitespace removes one indentation unit when possible.
- Undo and redo, with up to 100 history entries per buffer.
- Incremental search forward and backward.
- Selection, copy, cut, and paste. Copy and cut also write to the terminal clipboard through OSC 52 when the terminal supports it.
- A line-number gutter and a status line that shows the current mode and prompts.

## Choosing an editor mode

The editor has three keybinding modes:

- **Modern**: default mode, with familiar shortcuts like `Ctrl+S`, `Ctrl+Q`, `/` search, and `?` reverse search.
- **Emacs**: non-modal Emacs-style chords, including `C-x C-s`, `C-x C-c`, and a per-buffer kill ring.
- **Vibe**: modal editing inspired by classic vi/vim workflows, with normal, insert, replace, visual, and command modes.

Change the mode from:

```text
/settings > Interface > Editor mode
```

New editor buffers use the updated setting immediately. You do not need to restart Kward.

You can also configure it in `config.json`:

```json
{
  "editor": {
    "mode": "modern"
  }
}
```

`mode` can be `modern`, `emacs`, or `vibe`. The old `default` value is still accepted as an alias for `modern`.

To disable auto-indent or auto-close pairs:

```json
{
  "editor": {
    "auto_indent": false,
    "auto_close_pairs": false
  }
}
```

Auto-close pairs inserts matching `()`, `[]`, `{}`, quotes, and backticks while editing.

Editable editor buffers request a vertical bar cursor by default. Set `editor.bar_cursor` to `false` if you want Kward to leave the terminal cursor shape alone.

See [Configuration](configuration.md) for the full editor settings reference.

## Modern mode

Modern mode is the default and is the easiest place to start. It uses common terminal-editor shortcuts and supports Shift+Arrow selection.

| Key                   | Action                                            |
| --------------------- | ------------------------------------------------- |
| `Ctrl+S`              | Save                                              |
| `Ctrl+Q`              | Quit; press again to discard unsaved changes      |
| `/`                   | Search forward                                    |
| `?`                   | Search backward                                   |
| `Ctrl+C`              | Copy selection, or cancel search                  |
| `Ctrl+X`              | Cut selection                                     |
| `Ctrl+V`              | Paste kill buffer                                 |
| `Ctrl+Y`              | Copy selection, or paste if there is no selection |
| `Ctrl+Z`              | Undo                                              |
| `Ctrl+Shift+Z`        | Redo                                              |
| `Ctrl+Space`          | Begin selection                                   |
| `Shift+Arrow`         | Extend selection                                  |
| `Ctrl+Right`          | Move to end of line                               |
| `Ctrl+Left`           | Move to start of line                             |
| `Ctrl+Up`             | Move to beginning of document                     |
| `Ctrl+Down`           | Move to end of document                           |
| `Alt+Shift+Left`      | Extend selection to previous word boundary        |
| `Alt+Shift+Right`     | Extend selection to next word boundary            |
| `Ctrl+A`              | Move to start of line                             |
| `Ctrl+E`              | Move to end of line                               |
| `Ctrl+B`              | Move left                                         |
| `Ctrl+F`              | Move right                                        |
| `Ctrl+N`              | Move down                                         |
| `Ctrl+P`              | Move up                                           |
| `Ctrl+K`              | Kill to end of line                               |
| `Ctrl+U`              | Kill to start of line                             |
| `Ctrl+W`              | Delete word before cursor                         |
| `Ctrl+D`              | Delete character at cursor                        |
| `Alt+B`               | Move to previous word                             |
| `Alt+F`               | Move to next word                                 |
| `Alt+D`               | Delete word after cursor                          |
| `Alt+Backspace`       | Delete word before cursor                         |
| `Arrow keys`          | Move cursor                                       |
| `Home` / `End`        | Move to start / end of line                       |
| `PageUp` / `PageDown` | Scroll                                            |
| `Enter`               | Insert newline, or confirm search                 |
| `Tab`                 | Insert two spaces                                 |
| `Backspace`           | Delete before cursor                              |
| `Delete`              | Delete character at cursor                        |
| `Esc`                 | Cancel search or clear selection                  |

## Emacs mode

Emacs mode is for users who prefer classic Emacs-style non-modal editing. Save and quit use two-key `C-x` commands, and kills are stored in a per-buffer kill ring so you can yank and cycle recent kills.

| Key                   | Action                                       |
| --------------------- | -------------------------------------------- |
| `C-x C-s`             | Save                                         |
| `C-x C-c`             | Quit; press again to discard unsaved changes |
| `C-s`                 | Search forward                               |
| `C-r`                 | Search backward                              |
| `C-g`                 | Cancel search, pending command, or selection |
| `Esc`                 | Clear selection, or cancel search            |
| `C-Space`             | Set the mark and begin a region              |
| `C-w`                 | Kill region, or delete word before cursor    |
| `M-w`                 | Copy region                                  |
| `C-y`                 | Yank from kill ring                          |
| `M-y`                 | Cycle kill ring after a yank                 |
| `C-a`                 | Move to start of line                        |
| `C-e`                 | Move to end of line                          |
| `C-b`                 | Move left                                    |
| `C-f`                 | Move right                                   |
| `C-n`                 | Move down                                    |
| `C-p`                 | Move up                                      |
| `C-k`                 | Kill to end of line                          |
| `C-u`                 | Kill to start of line                        |
| `M-d`                 | Delete word after cursor                     |
| `M-Backspace`         | Delete word before cursor                    |
| `M-b`                 | Move to previous word                        |
| `M-f`                 | Move to next word                            |
| `C-v`                 | Page down                                    |
| `M-v`                 | Page up                                      |
| `Arrow keys`          | Move cursor                                  |
| `Home` / `End`        | Move to start / end of line                  |
| `PageUp` / `PageDown` | Scroll                                       |
| `Enter`               | Insert newline, or confirm search            |
| `Tab`                 | Insert two spaces                            |
| `Backspace`           | Delete before cursor                         |
| `Delete` / `C-d`      | Delete character at cursor                   |

## Vibe mode

Vibe mode is a modal editor aiming for feature parity of classic Vi. Files open in normal mode, where keys run commands. Press `i`, `a`, `o`, or another insert command to type text, then press `Esc` to return to normal mode.

It supports a compact modal-editing set: counts, operators with motions, visual selection, search, repeat, and `:` commands.

### Normal mode

| Key                     | Action                                          |
| ----------------------- | ----------------------------------------------- |
| `h` / `←` / `Backspace` | Move left                                       |
| `j` / `↓` / `Ctrl+N`    | Move down                                       |
| `k` / `↑` / `Ctrl+P`    | Move up                                         |
| `l` / `Space`           | Move right                                      |
| `0` / `Home`            | Move to start of line                           |
| `^`                     | Move to first non-blank character               |
| `$` / `End`             | Move to end of line                             |
| `w`                     | Move to next word                               |
| `e`                     | Move to end of word                             |
| `b`                     | Move to previous word                           |
| `gg`                    | Move to start of file                           |
| `G`                     | Move to end of file                             |
| `N G`                   | Move to line `N`                                |
| `H`                     | Move to top of screen                           |
| `M`                     | Move to middle of screen                        |
| `L`                     | Move to bottom of screen                        |
| `+` / `Enter`           | Move to first non-blank of next line            |
| `-`                     | Move to first non-blank of previous line        |
| `_`                     | Move to first non-blank of current line         |
| `Ctrl+F`                | Page down                                       |
| `Ctrl+B`                | Page up                                         |
| `Ctrl+D`                | Half page down                                  |
| `Ctrl+U`                | Half page up                                    |
| `Ctrl+E`                | Scroll down one line                            |
| `Ctrl+Y`                | Scroll up one line                              |
| `i`                     | Insert before cursor                            |
| `I`                     | Insert at first non-blank of line               |
| `a`                     | Insert after cursor                             |
| `A`                     | Insert at end of line                           |
| `o`                     | Open line below and insert                      |
| `O`                     | Open line above and insert                      |
| `x`                     | Delete character at cursor                      |
| `X`                     | Delete character before cursor                  |
| `dd`                    | Delete line                                     |
| `D`                     | Delete to end of line                           |
| `C`                     | Change to end of line                           |
| `cc`                    | Change line                                     |
| `s`                     | Substitute character                            |
| `S`                     | Change line                                     |
| `J`                     | Join lines                                      |
| `r` then char           | Replace character                               |
| `R`                     | Replace mode                                    |
| `dw` / `yw` / `cw`      | Delete / yank / change with motion              |
| `yy`                    | Yank line                                       |
| `p`                     | Paste after cursor                              |
| `P`                     | Paste before cursor                             |
| `u`                     | Undo                                            |
| `Ctrl+R`                | Redo                                            |
| `U`                     | Restore current line                            |
| `.`                     | Repeat last change                              |
| `v`                     | Visual character mode                           |
| `V`                     | Visual line mode                                |
| `/`                     | Search forward                                  |
| `?`                     | Search backward                                 |
| `n`                     | Repeat search                                   |
| `N`                     | Repeat search in opposite direction             |
| `*`                     | Search word under cursor forward                |
| `#`                     | Search word under cursor backward               |
| `:`                     | Enter command mode                              |
| `Esc` / `Ctrl+C`        | Cancel pending command                          |
| `N`command              | Repeat command `N` times, such as `3dd` or `2w` |

### Insert mode

| Key              | Action                     |
| ---------------- | -------------------------- |
| type text        | Insert characters          |
| `Enter`          | Insert newline             |
| `Backspace`      | Delete before cursor       |
| `Delete`         | Delete character at cursor |
| `Arrow keys`     | Move cursor                |
| `Esc` / `Ctrl+C` | Return to normal mode      |

### Replace mode

| Key              | Action                      |
| ---------------- | --------------------------- |
| type text        | Replace character at cursor |
| `Enter`          | Insert newline              |
| `Backspace`      | Delete before cursor        |
| `Esc` / `Ctrl+C` | Return to normal mode       |

### Visual mode

Enter visual mode with `v` for character selection or `V` for line selection. Move the cursor to extend the selection, then choose an action.

| Key                      | Action               |
| ------------------------ | -------------------- |
| `Arrow keys` / `h j k l` | Extend selection     |
| `y`                      | Yank selection       |
| `d` / `x`                | Delete selection     |
| `c`                      | Change selection     |
| `p`                      | Paste over selection |
| `Esc` / `Ctrl+C`         | Cancel visual mode   |

### Command mode

Enter command mode with `:` from normal mode. Type a command and press `Enter`.

| Command | Action                                     |
| ------- | ------------------------------------------ |
| `:w`    | Save                                       |
| `:q`    | Quit; refuses if there are unsaved changes |
| `:q!`   | Quit and discard changes                   |
| `:wq`   | Save and quit                              |
| `:x`    | Save if changed, then quit                 |
| `:N`    | Go to line `N`                             |
