# Integrated Editor

<quote>
Three Modes for the Elven-kings under the sky,<br>
Seven Keymaps for the Dwarf-lords in their halls of stone,<br>
Nine Editors for Mortal Men doomed to compile,<br>
One Kward to rule them all,<br>
One Kward to find them,<br>
One Kward to bring them all and in the transcript bind them<br>
In the Land of Ruby where the agents lie.<br>
</quote>

Kward includes a terminal editor with 3 editing modes to choose from: Modern, Emacs and Vibe. It opens inside the chat composer, so you can jump into a file, make a change, save it, and return to the conversation without switching tools.

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

- Syntax highlighting for common languages, including Ruby, Crystal, Elixir, Julia, JavaScript, TypeScript, JSON, Markdown, YAML, Shell, Makefile, HTML, CSS, SCSS, Python, Go, Rust, Java, C#, C, C++, Swift, Kotlin, Lua, and SQL. Unknown file types render as plain text.
- Auto-indent, enabled by default. New lines inherit indentation, obvious closing tokens are re-indented, and Backspace in leading whitespace removes one indentation unit when possible. For Ruby, Crystal, Elixir, Julia, Lua, Makefiles, and shell scripts, Enter after a block opener inserts the matching closing keyword; Ctrl+Enter also works from the middle of the line in terminals that report modified Enter keys.
- Undo and redo, with up to 100 history entries per buffer.
- Incremental search forward and backward.
- Selection, copy, cut, and paste. Copy and cut also write to the terminal clipboard through OSC 52 when the terminal supports it.
- A line-number gutter and a status line that shows the current mode and prompts.
- Soft-wrap, enabled by default so long lines wrap within the editor width instead of scrolling sideways. Disable it with `editor.soft_wrap: false`.

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

Line numbers are absolute by default. Set `editor.line_numbers` to `relative` to show distances from the cursor line in editable buffers while keeping the current line absolute.

Editable editor buffers request a vertical bar cursor by default. Set `editor.bar_cursor` to `false` if you want Kward to leave the terminal cursor shape alone.

See [Configuration](configuration.md#editor-settings) for the full editor settings reference.

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
| `Alt+Up` on macOS, `Ctrl+Up` elsewhere | Move up by indentation level          |
| `Alt+Down` on macOS, `Ctrl+Down` elsewhere | Move down by indentation level    |
| `Alt+Right` on macOS, `Ctrl+Right` elsewhere | Move to indentation, then word end |
| `Alt+Shift+Up` on macOS, `Ctrl+Shift+Up` elsewhere | Select up by indentation level |
| `Alt+Shift+Down` on macOS, `Ctrl+Shift+Down` elsewhere | Select down by indentation level |
| `Alt+Shift+Right` on macOS, `Ctrl+Shift+Right` elsewhere | Select to indentation, then word end |
| `Ctrl+Left`           | Move to start of line                             |
| `Alt+Shift+Left`      | Extend selection to previous word boundary        |
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
| `C-f`                 | Move right                                  |
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

Vibe mode is a modal editor built for Kward, inspired by classic Vi and Vim. If you already know Vim, you will feel at home here. Files open in normal mode, where keys run commands. Press `i`, `a`, `o`, or another insert command to type text, then press `Esc` to return to normal mode.

It supports a compact but practical modal-editing set: counts, operators with motions, visual selection, search, repeat (`.`), and `:` commands. It is not a full Vim clone — there are no macros, registers, splits, or ex-mode scripting. What it does cover is the everyday editing flow: move, change, delete, yank, paste, search, and save, all without leaving the keyboard or the conversation.

The status line always shows the current mode (`NORMAL`, `INSERT`, `VISUAL`, `REPLACE`, or `:`) so you never lose track of where you are.

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
| `zz`                    | Center cursor line in viewport                  |
| `zt`                    | Scroll cursor line to top of viewport           |
| `zb`                    | Scroll cursor line to bottom of viewport         |
| `+` / `Enter`           | Move to first non-blank of next line            |
| `-`                     | Move to first non-blank of previous line        |
| `_`                     | Move to first non-blank of current line         |
| `Ctrl+J`                | Move down by indentation level                  |
| `Ctrl+K`                | Move up by indentation level                    |
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
| `diw` / `yiw` / `ciw`   | Delete / yank / change inner word               |
| `daw` / `yaw` / `caw`   | Delete / yank / change a word plus spacing      |
| `di(`/`ci(`/`yi(`       | Delete / change / yank inside a pair            |
| `da(`/`ca(`/`ya(`       | Delete / change / yank around a pair            |
| `dib` / `ciB`           | Pair aliases for parentheses/braces             |
| `dip` / `cip` / `yip`   | Delete / change / yank inside a paragraph       |
| `dap` / `cap` / `yap`   | Delete / change / yank around a paragraph       |
| `dir` / `cir` / `yir`   | Delete / change / yank inside a Ruby block      |
| `dar` / `car` / `yar`   | Delete / change / yank around a Ruby block      |
| `yy`                    | Yank line                                       |
| `p`                     | Paste after cursor                              |
| `P`                     | Paste before cursor                             |
| `u`                     | Undo                                            |
| `Ctrl+R`                | Redo                                            |
| `%`                     | Jump to matching pair                           |
| `f`/`F`/`t`/`T`         | Find character on current line                  |
| `df)` / `ct,` / `d%`    | Use character and pair motions with operators   |
| `;` / `,`               | Repeat character find forward/backward          |
| `U`                     | Restore current line                            |
| `.`                     | Repeat last change                              |
| `v`                     | Visual character mode                           |
| `V`                     | Visual line mode                                |
| `o`                     | Switch active end of visual selection           |
| `G` / `N`motion         | Extend visual selection with counts/motions     |
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

In insert mode, typed characters are inserted at the cursor. Press `Esc` or `Ctrl+C` to return to normal mode. Arrow keys move the cursor without leaving insert mode.

Vibe insert mode also supports readline-style shortcuts for efficient editing without dropping back to normal mode:

| Key              | Action                                   |
| ---------------- | ---------------------------------------- |
| type text        | Insert characters                        |
| `Enter`          | Insert newline                           |
| `Backspace`      | Delete before cursor                     |
| `Delete`         | Delete character at cursor               |
| `Ctrl+A`         | Move to start of line                    |
| `Ctrl+E`         | Move to end of line                      |
| `Ctrl+B`         | Move left                                |
| `Ctrl+F`         | Move right                               |
| `Ctrl+D`         | Delete character at cursor               |
| `Ctrl+K`         | Kill to end of line                      |
| `Ctrl+U`         | Kill to start of line                    |
| `Ctrl+W`         | Delete word before cursor                |
| `Ctrl+Y`         | Paste kill buffer                        |
| `Alt+B`          | Move to previous word                    |
| `Alt+F`          | Move to next word                        |
| `Alt+D`          | Delete word after cursor                 |
| `Alt+Backspace`  | Delete word before cursor                |
| `Arrow keys`     | Move cursor                              |
| `Home` / `End`   | Move to start / end of line              |
| `Esc` / `Ctrl+C` | Return to normal mode                    |

### Replace mode

Replace mode overwrites characters at the cursor instead of inserting. Each typed character replaces the character under the cursor and advances. Press `Esc` or `Ctrl+C` to return to normal mode.

| Key              | Action                      |
| ---------------- | --------------------------- |
| type text        | Replace character at cursor |
| `Enter`          | Insert newline              |
| `Backspace`      | Delete before cursor        |
| `Esc` / `Ctrl+C` | Return to normal mode       |

### Visual mode

Enter visual mode with `v` for character selection or `V` for line selection. Move the cursor to extend the selection, then choose an action.

| Key                      | Action                              |
| ------------------------ | ----------------------------------- |
| `Arrow keys` / `h j k l` | Extend selection                    |
| `y`                      | Yank selection                       |
| `d` / `x`                | Delete selection                     |
| `c`                      | Change selection (delete and insert) |
| `p`                      | Paste over selection                 |
| auto-close opener        | Wrap selection in matching pair       |
| `Esc` / `Ctrl+C`         | Cancel visual mode                   |

Typing an opening bracket (`(`, `[`, `{`) or quote (`"`, `'`, `` ` ``) in visual mode wraps the selection in the matching pair, then returns to normal mode.

### Command mode

Enter command mode with `:` from normal mode. Type a command and press `Enter`. Press `Esc` or `Ctrl+C` to cancel.

| Command | Action                                     |
| ------- | ------------------------------------------ |
| `:w`    | Save                                       |
| `:q`    | Quit; refuses if there are unsaved changes |
| `:q!`   | Quit and discard changes                   |
| `:wq`   | Save and quit                              |
| `:x`    | Save if changed, then quit                 |
| `:N`    | Go to line `N`                             |

### Vibe design notes

Vibe mode is not trying to be Vim. It is a focused subset designed for quick edits inside a chat-based coding agent. Here is what to expect:

- **Counts work with commands and motions**: `3dd` deletes three lines, `2w` moves two words, `5x` deletes five characters.
- **`.` repeats the last change**: after `cw word Esc`, pressing `.` changes the next word the same way. Insert-mode keystrokes are recorded as part of the change.
- **`/` and `?` search forward and backward**: `n` and `N` repeat the last search. `*` and `#` search for the word under the cursor.
- **Operators with motions**: `d`, `y`, and `c` work with `w` (word), `e` (end of word), `b` (back word), `$` (end of line), `0` (start of line), and `^` (first non-blank).
- **Yanks copy to the terminal clipboard**: when OSC 52 is supported, yanked text is also sent to the system clipboard, so you can paste into other applications.
- **No registers, macros, or ex-mode**: these are intentionally omitted to keep the editor compact. If you need them, use your full terminal editor and reload the file in Kward.
- **Viewport commands**: `zz`, `zt`, and `zb` reposition the cursor line to the center, top, or bottom of the viewport without moving the cursor itself — the same as Vim.
- **Indentation navigation**: `Ctrl+J` and `Ctrl+K` jump to the next or previous indentation level, which is useful for navigating nested code blocks in Ruby and other indented languages.
