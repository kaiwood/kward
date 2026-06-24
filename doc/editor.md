# Integrated Editor

Kward ships with a built-in terminal file editor. It lives inside the composer area, so you can open a file, make a quick change, save, and return to chatting without leaving Kward or reaching for an external editor.

The editor is workspace-scoped: it only opens files inside the current workspace directory, so you cannot accidentally wander outside the project.

## Opening an editor with `$`

Type `$` at the very start of the composer input to open the file-narrowing overlay:

```text
$lib/kward/agent.rb
```

As you type a path after the `$`, Kward shows matching project files in a compact card. Use the arrow keys to highlight a match and press `Enter` to open it. You can also type a full or relative path yourself and press `Enter`; if the file does not exist yet, Kward offers to create it.

The `$` prefix only triggers the editor when it is the first character of the composer input. It does not work mid-line.

Once a file is open, the composer is replaced by the full-height editor. Save or quit to return to the normal composer.

## Editor features

The integrated editor is small but practical:

- **Syntax highlighting** for Ruby, JavaScript, TypeScript, JSON, Markdown, YAML, Shell, HTML, CSS, SCSS, Python, Go, Rust, Java, C#, C, C++, Swift, Kotlin, Lua, and SQL when terminal color is enabled. Unknown file types render as plain text.
- **Auto-indent** (on by default). Pressing `Enter` copies the current line's indentation, detects the file's indentation unit when possible, and applies lightweight syntax-based indentation for recognized file types. Typing obvious closing tokens such as `}`, Ruby/Lua `end`, and shell `fi`/`done`/`esac` re-indents the current line. Backspace in leading indentation removes one detected indentation unit instead of a single character.
- **Undo and redo** with a per-buffer history of up to 100 entries.
- **Incremental search** forward and backward, with repeat and word-under-cursor search in vi mode.
- **Selection and clipboard**. Copy and cut write to the terminal clipboard via OSC 52 when supported, so pasted text is available in other applications.
- **Two-step protection**. Saving a file that changed on disk asks you to confirm the overwrite. Quitting with unsaved changes asks you to confirm you want to discard them.
- **Line-number gutter** and a status line that reflects the active mode and any prompts.

## Choosing a mode

The editor has three keybinding modes. Modern is the default. You can change the active mode at any time from `/settings` > Interface > Editor mode; newly opened editor buffers pick up the setting immediately, so there is no need to restart Kward.

You can also set the mode in `config.json`:

```json
{
  "editor": {
    "mode": "modern"
  }
}
```

`mode` can be `modern`, `emacs`, or `vi`. The old `default` value is still accepted as an alias for `modern`.

To disable auto-indent:

```json
{
  "editor": {
    "auto_indent": false
  }
}
```

See [Configuration](configuration.md) for the full editor settings reference.

The three modes are described below in the order Modern, Emacs, then Vi (Vibe).

## Modern mode

Modern mode is the default keymap. It uses familiar composer-style chord keys: `Ctrl+S` saves, `Ctrl+Q` quits, `Ctrl+F` searches, and Shift plus an arrow extends the selection. It is the most conventional choice if you are not already an Emacs or vi user.

| Key | Action |
| --- | --- |
| `Ctrl+S` | Save |
| `Ctrl+Q` | Quit (press again to discard unsaved changes) |
| `Ctrl+F` | Search forward |
| `Ctrl+C` | Copy selection (or cancel search) |
| `Ctrl+X` | Cut selection |
| `Ctrl+V` | Paste kill buffer |
| `Ctrl+Y` | Copy selection, or paste if no selection |
| `Ctrl+Z` | Undo |
| `Ctrl+Shift+Z` | Redo |
| `Ctrl+Space` | Begin selection |
| `Shift+Arrow` | Extend selection |
| `Ctrl+A` | Move to start of line |
| `Ctrl+E` | Move to end of line |
| `Ctrl+B` | Move left |
| `Ctrl+N` | Move down |
| `Ctrl+P` | Move up |
| `Ctrl+K` | Kill to end of line |
| `Ctrl+U` | Kill to start of line |
| `Ctrl+W` | Delete word before cursor |
| `Ctrl+D` | Delete character at cursor |
| `Alt+B` | Move to previous word |
| `Alt+F` | Move to next word |
| `Alt+D` | Delete word after cursor |
| `Alt+Backspace` | Delete word before cursor |
| `Arrow keys` | Move cursor |
| `Home` / `End` | Move to start / end of line |
| `PageUp` / `PageDown` | Scroll |
| `Enter` | Insert newline (or confirm search) |
| `Tab` | Insert two spaces |
| `Backspace` | Delete before cursor |
| `Delete` | Delete character at cursor |
| `Esc` | Cancel search or clear selection |

## Emacs mode

Emacs mode uses classic Emacs-style non-modal chords. The defining difference is that save and quit are two-step `C-x` sequences, and the editor keeps a per-buffer kill ring so you can yank back recent kills and cycle through them with `M-y`.

| Key | Action |
| --- | --- |
| `C-x C-s` | Save |
| `C-x C-c` | Quit (press again to discard unsaved changes) |
| `C-s` | Search forward |
| `C-r` | Search backward |
| `C-g` | Cancel search, pending command, or selection |
| `Esc` | Clear selection (or cancel search) |
| `C-Space` | Set the mark (begin region) |
| `C-w` | Kill region (or delete word before cursor) |
| `M-w` | Copy region |
| `C-y` | Yank from kill ring |
| `M-y` | Cycle kill ring after a yank |
| `C-a` | Move to start of line |
| `C-e` | Move to end of line |
| `C-b` | Move left |
| `C-f` | Move right |
| `C-n` | Move down |
| `C-p` | Move up |
| `C-k` | Kill to end of line |
| `C-u` | Kill to start of line |
| `M-d` | Delete word after cursor |
| `M-Backspace` | Delete word before cursor |
| `M-b` | Move to previous word |
| `M-f` | Move to next word |
| `C-v` | Page down |
| `M-v` | Page up |
| `Arrow keys` | Move cursor |
| `Home` / `End` | Move to start / end of line |
| `PageUp` / `PageDown` | Scroll |
| `Enter` | Insert newline (or confirm search) |
| `Tab` | Insert two spaces |
| `Backspace` | Delete before cursor |
| `Delete` / `C-d` | Delete character at cursor |

## Vi (Vibe) mode

Vi mode is the modal keymap. Files open in normal mode, where keys are commands rather than inserted text. You enter insert mode to type, then press `Esc` to return to normal mode. It supports a compact classic-vi subset including counts, operators with motions, visual selection, and the `:` command line.

The internal codename for this mode is Vibe, but it is selected and configured as `vi`.

### Normal mode

Normal mode is the default when a file is opened in vi mode.

| Key | Action |
| --- | --- |
| `h` / `←` / `Backspace` | Move left |
| `j` / `↓` / `Ctrl+N` | Move down |
| `k` / `↑` / `Ctrl+P` | Move up |
| `l` / `Space` | Move right |
| `0` / `Home` | Move to start of line |
| `^` | Move to first non-blank character |
| `$` / `End` | Move to end of line |
| `w` | Move to next word |
| `e` | Move to end of word |
| `b` | Move to previous word |
| `gg` | Move to start of file |
| `G` | Move to end of file |
| `N`G | Move to line `N` |
| `H` | Move to top of screen |
| `M` | Move to middle of screen |
| `L` | Move to bottom of screen |
| `+` / `Enter` | Move to first non-blank of next line |
| `-` | Move to first non-blank of previous line |
| `_` | Move to first non-blank of current line |
| `Ctrl+F` | Page down |
| `Ctrl+B` | Page up |
| `Ctrl+D` | Half page down |
| `Ctrl+U` | Half page up |
| `Ctrl+E` | Scroll down one line |
| `Ctrl+Y` | Scroll up one line |
| `i` | Insert before cursor |
| `I` | Insert at first non-blank of line |
| `a` | Insert after cursor |
| `A` | Insert at end of line |
| `o` | Open line below and insert |
| `O` | Open line above and insert |
| `x` | Delete character at cursor |
| `X` | Delete character before cursor |
| `dd` | Delete line |
| `D` | Delete to end of line |
| `C` | Change to end of line |
| `cc` | Change line |
| `s` | Substitute character |
| `S` | Change line |
| `J` | Join lines |
| `r`char | Replace character |
| `R` | Replace mode |
| `dw` / `yw` / `cw` | Delete / yank / change with motion |
| `yy` | Yank line |
| `p` | Paste after cursor |
| `P` | Paste before cursor |
| `u` | Undo |
| `Ctrl+R` | Redo |
| `U` | Restore current line |
| `.` | Repeat last change |
| `v` | Visual character mode |
| `V` | Visual line mode |
| `/` | Search forward |
| `?` | Search backward |
| `n` | Repeat search |
| `N` | Repeat search in opposite direction |
| `*` | Search word under cursor forward |
| `#` | Search word under cursor backward |
| `:` | Enter command mode |
| `Esc` / `Ctrl+C` | Cancel pending command |
| `N`command | Repeat command `N` times (e.g. `3dd`, `2w`) |

### Insert mode

Entered with `i`, `I`, `a`, `A`, `o`, `O`, or after a change command.

| Key | Action |
| --- | --- |
| type text | Insert characters |
| `Enter` | Insert newline |
| `Backspace` | Delete before cursor |
| `Delete` | Delete character at cursor |
| `Arrow keys` | Move cursor |
| `Esc` / `Ctrl+C` | Return to normal mode |

### Replace mode

Entered with `R`. Each character typed replaces the character at the cursor.

| Key | Action |
| --- | --- |
| type text | Replace character at cursor |
| `Enter` | Insert newline |
| `Backspace` | Delete before cursor |
| `Esc` / `Ctrl+C` | Return to normal mode |

### Visual mode

Entered with `v` (character) or `V` (line). Move the cursor to extend the selection, then act on it.

| Key | Action |
| --- | --- |
| `Arrow keys` / `h j k l` | Extend selection |
| `y` | Yank selection |
| `d` / `x` | Delete selection |
| `c` | Change selection |
| `p` | Paste over selection |
| `Esc` / `Ctrl+C` | Cancel visual mode |

### Command mode

Entered with `:` from normal mode. Type a command and press `Enter`.

| Command | Action |
| --- | --- |
| `:w` | Save |
| `:q` | Quit (refuses if unsaved) |
| `:q!` | Quit and discard changes |
| `:wq` | Save and quit |
| `:x` | Save if changed, then quit |
| `:N` | Go to line `N` |
