# Integrated editor

Kward includes a terminal editor with three modes: Modern, Emacs, and Vibe. It opens inside the chat composer, so you can jump into a file, make a change, save it, and return to the conversation without switching tools.

The editor opens only files inside the current workspace, which keeps edits tied to the project where you started Kward.

<quote>
Three Modes for the Elven-kings under the sky,<br>
Seven Keymaps for the Dwarf-lords in their halls of stone,<br>
Nine Editors for Mortal Men doomed to compile,<br>
One Kward to rule them all,<br>
One Kward to find them,<br>
One Kward to bring them all and in the transcript bind them<br>
In the Land of Ruby where the agents lie.<br>
</quote>

## Quick start

Open a file directly from your shell:

```bash
cd ~/code/my-project
kward edit lib/kward/agent.rb
```

Kward uses the current directory as the workspace, opens the file in the integrated editor, and exits when you close the editor. During an interactive chat session, you can also ask Kward to open a workspace file for you; it uses the `open_editor` tool when that capability is available. Opening the editor does not change or save the file unless you choose to do so. Use `--working-directory` when the file belongs to another workspace:

```bash
kward --working-directory ~/code/my-project edit lib/kward/agent.rb
```

From an interactive Kward session, open the file picker by typing `$` as the first character in the composer:

```text
$lib/kward/agent.rb
```

As you type, Kward shows matching files. Use the arrow keys to choose one and press `Enter` to open it.

For a nested project tree, run:

```text
/files
```

In the tree browser, use `↑`/`↓` to move, `←`/`→` to collapse or expand directories, `Enter` to toggle a directory or open a file, `Tab` or `/` to search, `i` to show or hide Git-ignored files, `f` to create a file, `d` to create a directory, `r` to rename the selected entry, `Backspace` to delete after confirmation, `@` to insert the selected file as an `@path` mention, and `Esc` to close. Create and rename names are entered in the prompt and must be single entry names. When you open a file from `/files`, quitting the editor returns to the browser at the same position.

For an unsaved buffer, open a scratchpad:

```text
/scratchpad
/scratchpad markdown
/scratchpad js
/scratchpad python
/scratchpad help
```

Scratchpads accept canonical language names and familiar file-extension shortcuts. For example, `js` selects JavaScript, `py` selects Python, `rb` selects Ruby, `yml` selects YAML, `cs` selects C#, and `cpp` selects C++. Use `/scratchpad help` to print the complete list of names and aliases.

All 26 built-in syntax-highlighted languages are available: Ruby, ERB, Crystal, Elixir, Julia, JavaScript, TypeScript, JSON, Markdown, YAML, Shell, Makefile, HTML, CSS, SCSS, Python, Go, Rust, Java, C#, C, C++, Swift, Kotlin, Lua, and SQL. Markdown buffers also apply the tagged language highlighter, auto-indentation, and endwise behavior inside fenced code blocks, such as a fence tagged `ruby` or `js`; unknown tags remain readable as plain text. Scratchpads use a matching virtual filename such as `scratchpad.js` or `scratchpad.py`; in Vibe mode, save one to a real file with `:w filename`.

Supported editable buffers can run with `:run` in Vibe mode or `Ctrl+R` in Modern mode. This works for both scratchpads and normal editor files. Kward runs the current in-memory buffer, including unsaved changes, without saving the file automatically. It opens a read-only output pane in the lower half of the editor with the captured output, exit status, and duration. Drag with the mouse to make a virtual selection inside the output, then press `Ctrl+C` or `Cmd+C` to copy it (`y` in Vibe mode). Only the selected output text is copied; pane borders are excluded. `Cmd+C` requires the terminal to forward the Command key to Kward. Press `Esc` to return to editing, use the arrow or page keys to scroll, and press `Ctrl+C` without a selection to cancel a running buffer. Runnable languages are Ruby, JavaScript, TypeScript, Python, Shell, Lua, Julia, Elixir, Crystal, Go, and Swift; other languages currently provide editing and highlighting only.

```ruby
puts "foo"

__END__
foo
```

The next run receives the current `__END__` section as Ruby `DATA`; the output window is refreshed without changing the source buffer.

You can also type a relative path yourself and press `Enter`. If the file does not exist, Kward asks whether to create it.

A few things to know:

- `$` only opens the editor when it is the first character in the composer.
- `/scratchpad` opens a plain-text scratchpad; pass a language name or shortcut to select syntax highlighting. `/scratchpad help` lists the available choices.
- Once a file or scratchpad opens, the composer becomes the editor.
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
4. In Vibe normal mode, use `:prompt <instruction>` to ask the agent to update the current in-memory buffer. In Modern mode, press `Ctrl+.` and type the instruction in the editor prompt line. For example, `write a HelloWorld class`.
5. The editor stays visible while the agent works; its status line shows a spinner. Review the generated buffer and save with `Ctrl+S` in Modern mode, `C-x C-s` in Emacs mode, or `:w` in Vibe mode. For an unsaved scratchpad in Vibe mode, use `:w filename`.
6. Quit with `Ctrl+Q`, `C-x C-c`, or `:q`.
7. Continue chatting with Kward.

## What the editor supports

The editor is intentionally compact, but it covers the basics you need for quick changes:

- Syntax highlighting for common languages, including Ruby, ERB templates, Crystal, Elixir, Julia, JavaScript, TypeScript, JSON, Markdown, YAML, Shell, Makefile, HTML, CSS, SCSS, Python, Go, Rust, Java, C#, C, C++, Swift, Kotlin, Lua, and SQL. ERB highlights template HTML outside ERB tags and Ruby inside `<% ... %>` tags. Unknown file types render as plain text.
- Current-buffer word completion. After a partial word, Tab completes from words elsewhere in the active buffer; repeated Tab presses cycle nearby matches. Completion is case-sensitive and recognizes letters, numbers, and underscores. No project files or external sources are searched.
- Auto-indent, enabled by default. New lines inherit indentation. When word completion does not apply, Tab jumps to the expected indentation or the next indentation stop. Shift+Tab moves indentation back, obvious closing tokens are re-indented, and Backspace in leading whitespace removes one indentation unit when possible. ERB recognizes common inline Ruby control tags and HTML opening tags when calculating the next indentation. For Ruby, Crystal, Elixir, Julia, Lua, Makefiles, and shell scripts, Enter after a block opener inserts the matching closing keyword; Ctrl+Enter also works from the middle of the line in terminals that report modified Enter keys.
- Undo and redo, with up to 100 history entries per buffer.
- Incremental search forward and backward.
- Selection, copy, cut, and paste. Copy and cut also write to the terminal clipboard through OSC 52 when the terminal supports it.
- A line-number gutter and a status line that shows the current mode and prompts.
- Soft-wrap, enabled by default so long lines wrap within the editor width instead of scrolling sideways. Disable it with `editor.soft_wrap: false`.
- Vibe `:prompt <instruction>` and Modern `Ctrl+.` prompt lines send the complete current buffer and document metadata to a dedicated, transient editor agent. The agent can replace the in-memory buffer through an explicit editor tool; it does not save files automatically.
- Editor prompts and their tool activity are not added to the normal chat transcript or session history.
- The editor remains visible and locked for editing while the agent runs. Its status line displays progress and a spinner; `Ctrl+C` cancels the request.

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
    "mode": "modern",
    "agent": {
      "model": "gpt-5.5",
      "reasoning_effort": "medium"
    }
  }
}
```

`mode` can be `modern`, `emacs`, or `vibe`. The optional `editor.agent.model` and `editor.agent.reasoning_effort` settings configure the dedicated Vibe editor agent. They use the active tab's provider. When either value is omitted, it falls back to the active tab's setting and then the client default. Editor-agent turns use a dedicated system prompt and are not persisted in the active tab transcript. The old `default` value is still accepted as an alias for `modern`.

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

See [Configuration](configuration.md) for the full editor settings reference.

## Modern mode

Modern mode is the default and is the easiest place to start. It uses common terminal-editor shortcuts and supports Shift+Arrow selection.

| Key                   | Action                                            |
| --------------------- | ------------------------------------------------- |
| `Ctrl+S`              | Save                                              |
| `Ctrl+Q`              | Quit; press again to discard unsaved changes      |
| `Ctrl+.`              | Open the editor-agent prompt line                 |
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
| `Tab`                 | Complete a buffer word, or smart-indent when no match exists |
| `Shift+Tab`           | Move indentation back by one stop                 |
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
| `Tab`                 | Complete a buffer word, or smart-indent when no match exists |
| `Shift+Tab`           | Move indentation back by one stop            |
| `Backspace`           | Delete before cursor                         |
| `Delete` / `C-d`      | Delete character at cursor                   |

## Vibe mode

Vibe mode is a modal editor built for Kward, inspired by classic Vi and Vim. If you already know Vim, you will feel at home here. Files open in normal mode, where keys run commands. Press `i`, `a`, `o`, or another insert command to type text, then press `Esc` to return to normal mode.

It supports a compact but practical modal-editing set: counts, operators with motions, visual selections, multi-cursor and visual block edits, marks, registers, macros, search, repeat (`.`), Ruby-aware navigation, and `:` commands. It is not a full Vim clone — there are no splits or ex-mode scripting — but it covers everyday keyboard editing inside the conversation.

The status line always shows the current mode (`NORMAL`, `INSERT`, `VISUAL`, `REPLACE`, or `:`) so you never lose track of where you are.

### Normal mode

Use normal mode for movement, operators, marks, registers, macros, search, and command mode. Visual-mode-specific commands are listed in their own section below.

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
| `Ctrl+D`                | Select the next occurrence and enter insert mode |
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
| `==`                    | Reindent current line                           |
| `={motion}`             | Reindent lines covered by a motion or text object |
| `"ayy` / `"ap`         | Yank / paste with named registers               |
| `p`                     | Paste after cursor                              |
| `P`                     | Paste before cursor                             |
| `u`                     | Undo                                            |
| `Ctrl+R`                | Redo                                            |
| `%`                     | Jump to matching pair                           |
| `f`/`F`/`t`/`T`         | Find character on current line                  |
| `{` / `}`               | Move by paragraph                               |
| `]m` / `[m`             | Jump to next / previous Ruby method             |
| `df)` / `ct,` / `d%`    | Use character and pair motions with operators   |
| `;` / `,`               | Repeat character find forward/backward          |
| `U`                     | Restore current line                            |
| `.`                     | Repeat last change                              |
| `v`                     | Visual character mode                           |
| `V`                     | Visual line mode                                |
| `Ctrl+V`                | Visual block mode                               |
| `gv`                    | Restore previous visual selection               |
| `ma` / `` `a `` / `'a`  | Set and jump to marks                           |
| `qa` / `@a` / `@@`      | Record and replay macros                        |
| `/`                     | Search forward                                  |
| `?`                     | Search backward                                 |
| `n`                     | Repeat search                                   |
| `N`                     | Repeat search in opposite direction             |
| `*`                     | Search word under cursor forward                |
| `#`                     | Search word under cursor backward               |
| `:`                     | Enter command mode                              |
| `:%s/a/b/g`             | Substitute text across command ranges           |
| `Esc` / `Ctrl+C`        | Cancel pending command                          |
| `N`command              | Repeat command `N` times, such as `3dd` or `2w` |

### Visual mode

Visual mode uses the same motion language as normal mode where practical. Arrow keys and plain `h`/`j`/`k`/`l` extend the selection. Start characterwise visual mode with `v`, linewise mode with `V`, or visual block mode with `Ctrl+V`.

| Key                     | Action                                          |
| ----------------------- | ----------------------------------------------- |
| `o`                     | Switch active end of visual selection           |
| `Ctrl+h` / `Ctrl+l`     | Outdent / indent selected lines                 |
| `Ctrl+j` / `Ctrl+k`     | Move selected lines down / up                   |
| `G` / `gg` / `N`motion  | Extend visual selection with counts/motions     |
| `%`, `f`/`F`/`t`/`T`    | Extend visual selection with advanced motions   |
| `iw` / `a(` / `ip`      | Select visual text objects                      |
| `>` / `<`               | Indent / outdent selected lines                 |
| `=`                     | Reindent selected lines                         |
| `I` / `A`               | Insert cursors at the start / end of each selected line |
| `Ctrl+D`                | Add the next occurrence of a characterwise selection |
| `J`                     | Join selected lines                             |
| `~` / `u` / `U`         | Swapcase / lowercase / uppercase selection      |
| `/` / `?` / `n` / `N`   | Extend visual selection with search             |
| `y` / `d` / `c` / `p`   | Yank / delete / change / paste selection        |

### Insert mode

In insert mode, typed characters are inserted at the cursor. Press `Esc` or `Ctrl+C` to return to normal mode. Arrow keys move the cursor without leaving insert mode.

Vibe insert mode also supports readline-style shortcuts for efficient editing without dropping back to normal mode:

| Key              | Action                                   |
| ---------------- | ---------------------------------------- |
| type text        | Insert characters                        |
| `Enter`          | Insert newline                           |
| `Tab`            | Complete a buffer word, or smart-indent when no match exists |
| `Shift+Tab`      | Move indentation back by one stop        |
| `Backspace`      | Delete before cursor                     |
| `Delete`         | Delete character at cursor               |
| `Ctrl+A`         | Move to start of line                    |
| `Ctrl+E`         | Move to end of line                      |
| `Ctrl+B`         | Move left                                |
| `Ctrl+F`         | Move right                               |
| `Ctrl+D`         | Select the next occurrence                |
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

Typing an opening bracket (`(`, `[`, `{`) or quote (`"`, `'`, `` ` ``) in visual mode wraps the selection in the matching pair, then returns to normal mode.

### Command mode

Enter command mode with `:` from normal mode. Type a command and press `Enter`. Press `Esc` or `Ctrl+C` to cancel. From visual mode, `:` starts the command with the selected line range (`'<,'>`), as in Vim.

| Command | Action                                     |
| ------- | ------------------------------------------ |
| `:w`    | Save                                       |
| `:q`    | Quit; refuses if there are unsaved changes |
| `:q!`   | Quit and discard changes                   |
| `:wq`   | Save and quit                              |
| `:x`    | Save if changed, then quit                 |
| `:N`    | Go to line `N`                             |
| `:run`  | Run the complete current supported editor buffer; inside a Markdown fence, run that block into its `<output>` field |
| `:run all` | Run every runnable Markdown fenced block sequentially into its `<output>` field |
| `:prompt instruction` | Ask the editor agent to update the buffer |
| `:s/a/b/g` | Substitute `a` with `b`                   |
| `:'<,'>s/a/b/g` | Substitute only across the visual selection |

Visual line ranges apply to `:s` and `:run`. For `:run`, select the body or complete fence of one Markdown code block with a runnable language, or place the cursor inside that block without making a selection; Kward runs that block and inserts or replaces a formatted `<output>` field without opening the output pane. `:run all` executes every runnable fenced block in document order, skips unlabeled or unsupported fences, continues after failures, and writes each runner error into that block's output field. An existing output field is searched for after the block until the next code fence, so inline fields are reformatted too. Without a matching output field, one is inserted directly below the block with one blank line. Other commands retain their normal save, navigation, file, and quit behavior.

### Vibe design notes

Vibe mode is not trying to be Vim. It is a focused subset designed for quick edits inside a chat-based coding agent. Here is what to expect:

- **Counts work with commands and motions**: `3dd` deletes three lines, `2w` moves two words, `5x` deletes five characters.
- **`.` repeats the last change**: after `cw word Esc`, pressing `.` changes the next word the same way. Insert-mode keystrokes are recorded as part of the change.
- **`/` and `?` search forward and backward**: `n` and `N` repeat the last search. `*` and `#` search for the word under the cursor.
- **Operators with motions**: `d`, `y`, `c`, and `=` work with `w` (word), `e` (end of word), `b` (back word), `$` (end of line), `0` (start of line), and `^` (first non-blank). `=` uses Kward's built-in language-aware auto-indent rules.
- **Yanks copy to the terminal clipboard**: when OSC 52 is supported, yanked text is also sent to the system clipboard, so you can paste into other applications.
- **Registers and macros are supported**: named registers work with yank/delete/paste flows, and `q`/`@` record and replay simple macros for repeated edits.
- **Viewport commands**: `zz`, `zt`, and `zb` reposition the cursor line to the center, top, or bottom of the viewport without moving the cursor itself — the same as Vim.
- **Indentation navigation**: `Ctrl+J` and `Ctrl+K` jump to the next or previous indentation level, which is useful for navigating nested code blocks in Ruby and other indented languages.
