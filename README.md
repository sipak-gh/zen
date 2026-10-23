# zen-editor

`ze` is a small modal text editor for the Linux terminal, written in Zig.
It implements a minimal subset of vi and nothing further. The intent is a
program short enough to be read in one sitting and owned by its user.

```
ze PATH
```

The file need not exist; it is created when first written. `ze zen`
prints the motto instead; to edit a file named `zen`, give `ze ./zen`.

## Screen

The text occupies every row but the last. The last row is the status
line: on the left the file name (with `[+]` when modified), a message, or
the `:` or `/` prompt; on the right the cursor position `LINE:COLUMN` and
the number of lines.

Comments are drawn dimmed: from a comment prefix followed by a space or
the end of the line, at the start of a line or after whitespace, outside
quoted strings, to the end of the line. So `# 1` is a comment but `#1`
is not; `///`, `//!` and `###` count as their prefix. The prefixes
depend on the file type: `//` for C, C++, Java, JavaScript, TypeScript,
Zig, Rust and Go, `#` for Python and shell, `--` for Lua, and `#`, `//`
or `;` for assembly; files of other types have no dimming. There is no
other highlighting. Tabs are displayed four columns wide; control
characters and malformed UTF-8 are displayed as `?`. Long lines scroll
horizontally.

## Keys

Normal mode:

| Keys          | Action                                        |
| ------------- | --------------------------------------------- |
| `h` `j` `k` `l` | left, down, up, right                       |
| `Ctrl-d` `Ctrl-u` | half a screen down, up                    |
| `w` `b` `e`   | next word, previous word, end of word         |
| `0` `^` `$`   | line start, first non-blank, line end         |
| `gg` `G`      | first line, last line                         |
| `/` `n`       | search forward, repeat search                 |
| `i` `a`       | insert before, after the cursor               |
| `I` `A`       | insert at first non-blank, at line end        |
| `o` `O`       | open a line below, above                      |
| `x`           | delete character                              |
| `dw` `dd`     | delete word, line                             |
| `yw` `yy`     | yank word, line                               |
| `p` `P`       | put after, before                             |
| `r`           | replace character                             |
| `u` `U`       | undo, redo                                    |
| `:`           | command                                       |

There are no counts, operators or text objects beyond those listed. Keys
are bound in the table `bindings` at the top of `src/Editor.zig`.

Insert mode: typed characters are inserted; `Enter` splits the line;
`Backspace` deletes the previous character, joining lines at the start of a
line; `Tab` inserts four spaces; `Esc` returns to normal mode. Arrow and
function keys are ignored in every mode.

Deleted and yanked text goes to a single internal register, used by `p`
and `P`. Text yanked by `yy` or deleted by `dd` is put as whole lines.

## Commands

| Command       | Action                                        |
| ------------- | --------------------------------------------- |
| `:w`          | write                                         |
| `:q`          | quit, refusing if modified                    |
| `:q!`         | quit, discarding changes                      |
| `:wq`         | write and quit                                |
| `:x`          | write if modified, and quit                   |
| `:N`          | go to line N                                  |
| `:e PATH`     | edit PATH, refusing if modified               |
| `:e! PATH`    | edit PATH, discarding changes                 |
| `:e` `:e!`    | reread the current file                       |

There are no buffers: `:e` replaces the file being edited. A file opened
with `:e` that does not exist is created when written.

## Behaviour

Files are read whole, as vi does, into one buffer; each line refers to
its bytes there until it is first changed, when it is copied. Memory is
the file size plus 24 bytes a line, and the file is written from the
lines through a small buffer. A 1 GB file opens in under a second.

Files are read as bytes and written back unchanged except where edited.
Every line is written with a terminating newline, as in vi; a file with
no text is written empty.

Writing follows vim: the file is first copied to `PATH~` and synced, then
overwritten in place and synced, and the copy removed. Overwriting in
place keeps the owner, permissions, hard links and any symbolic link. An
existing `PATH~` is never replaced; the write is refused instead. If the
overwrite fails (a full disk, say) the copy is kept, the error names it,
and later writes leave it untouched until one succeeds. The copy is made
beside the file, so the directory must be writable.

Input is decoded as UTF-8 across reads, so a character split between two
reads of pasted text is kept; malformed bytes are dropped. Characters are
UTF-8; each occupies one screen column, so wide characters misalign the
cursor.

Undo works as in vim: before each change the lines it is about to alter
are copied, and undoing exchanges the copies for the current lines, which
become the change to redo. A change costs only the lines it touched. Each
insertion, from entering insert mode until `Esc`, is one change. The last
100 changes are kept.

## Source

| File               | Contents                                       |
| ------------------ | ---------------------------------------------- |
| `src/main.zig`     | arguments and start-up                         |
| `src/Editor.zig`   | the text, the key bindings, commands and undo  |
| `src/terminal.zig` | raw mode, key input and drawing                |
| `src/text.zig`     | characters and screen columns within a line    |
| `src/tests.zig`    | tests of reading, editing and writing files    |

`Editor` knows nothing of the terminal: it receives keys as code points
and exposes the text and cursor to be drawn. The terminal module redraws
the whole screen after every read, as one write.

## Building

Requires Zig 0.17.0.

```
zig build -Doptimize=ReleaseSafe     # zig-out/bin/ze
zig build -Dtiny                     # zig-out/bin/ze-tiny
zig build test
```

`ze-tiny` is optimised for size and stripped: about 170 KB against
4 MB, at the cost of the safety checks and the symbols for a stack trace.

The tests include unit tests and a randomised test that types 2000
sequences of 100 random keys, checking after each key that the cursor is
on a character and pending keys begin a binding, and at the end that
undoing every change restores the original text and redoing them restores
the result, and that the bytes read from the file were never changed.

`src/tests.zig` tests files end to end, in a temporary directory. Files
of every awkward form (empty, without final newline, CRLF, NUL bytes,
malformed UTF-8, a 1 MB line, 100 000 lines, sizes about the 64 KiB I/O
buffers) and random files must be written back byte for byte. Random
edits are checked key by key against an independent model of what each
key does; the result must be written exactly, undoing everything must
write the original, and rereading must give the same text. Further tests
cover links, permissions, the backup copy, unwritable files and
directories, and a disk that fills during the backup or the write,
simulated with `RLIMIT_FSIZE`. Input is fed in random splits to check
the decoder. Randomised tests draw from the test runner's seed, so each
run tries new cases and a failure is repeated with its `--seed`. The
editing checks also run under the fuzzer:

```
zig build test -Doptimize=ReleaseSafe --fuzz=10K
```

(Fuzzing requires the LLVM backend, hence the release mode. 10K runs take
about two minutes; without a limit it runs until stopped.)

## License

[0BSD](LICENSE)
