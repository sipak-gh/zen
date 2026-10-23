//! The editor: a text buffer, a cursor and the vi-like state machine that
//! edits them. It is driven by `handleKey` and knows nothing of terminals.
//!
//! The buffer is a list of lines, never empty, without their newlines. The
//! file is read whole into `data`, and each line borrows its bytes from
//! there until it is first changed, when it is given its own copy.
//! Normal-mode keys and `:` commands are bound in the tables `bindings` and
//! `commands`. A key is a Unicode code point; Ctrl with a letter is the
//! corresponding ASCII control character.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const text = @import("text.zig");

const Editor = @This();

pub const Mode = enum { normal, insert, command, search };
pub const Pos = struct { line: usize = 0, col: usize = 0 };
/// A line of text. A borrowed line has no capacity: its bytes belong to
/// `data`, which is never changed, and `own` copies them before a change.
const Line = std.ArrayList(u8);
/// A change as the lines it replaced. The lines it produced are those from
/// `top` up to the last `after` lines of the text; undoing the change puts
/// `lines` back in their place, and those lines become the change to redo.
const Change = struct {
    top: usize,
    after: usize,
    lines: std.ArrayList(Line) = .empty,
    cursor: Pos,
    version: u64,
};

pub const esc = 0x1b;
pub const enter = '\r';
pub const backspace = 0x7f;
pub const tab = '\t';

const undo_limit = 100;
const Error = Allocator.Error;
const Action = *const fn (*Editor) Error!void;

/// Normal-mode bindings: a key sequence and its action.
const bindings = [_]struct { []const u8, Action }{
    .{ "h", left },
    .{ "l", right },
    .{ "j", down },
    .{ "k", up },
    .{ "\x04", halfPageDown }, // Ctrl-d
    .{ "\x15", halfPageUp }, // Ctrl-u
    .{ "w", wordForward },
    .{ "b", wordBackward },
    .{ "e", wordEnd },
    .{ "0", lineStart },
    .{ "^", lineFirstNonBlank },
    .{ "$", lineEnd },
    .{ "gg", firstLine },
    .{ "G", lastLine },
    .{ "/", startSearch },
    .{ "n", searchNext },
    .{ "i", insert },
    .{ "a", append },
    .{ "I", insertAtFirstNonBlank },
    .{ "A", appendAtEnd },
    .{ "o", openBelow },
    .{ "O", openAbove },
    .{ "x", deleteChar },
    .{ "dw", deleteWord },
    .{ "dd", deleteLine },
    .{ "yw", yankWord },
    .{ "yy", yankLine },
    .{ "p", putAfter },
    .{ "P", putBefore },
    .{ "r", startReplace },
    .{ "u", undo },
    .{ "U", redo },
    .{ ":", startCommand },
};

/// Commands without arguments. `:e`, `:e!` and `:N` are parsed separately.
const commands = [_]struct { []const u8, Action }{
    .{ "w", writeCommand },
    .{ "q", quit },
    .{ "q!", forceQuit },
    .{ "wq", writeQuit },
    .{ "x", exit },
};

const max_binding_len = blk: {
    var n = 0;
    for (bindings) |b| n = @max(n, b[0].len);
    break :blk n;
};

gpa: Allocator,
io: Io,
/// The file as read; unchanged lines borrow their bytes from it.
data: std.ArrayList(u8) = .empty,
lines: std.ArrayList(Line) = .empty,
path: std.ArrayList(u8) = .empty,
cursor: Pos = .{},
/// The screen column that vertical motions aim for.
goal: usize = 0,
/// Set by a vertical motion so that `goal` is kept.
keep_goal: bool = false,
mode: Mode = .normal,
/// The keys typed so far of an incomplete binding.
pending: [max_binding_len]u8 = undefined,
pending_len: usize = 0,
/// Set by `r` until its replacement character arrives.
replacing: bool = false,
/// The text being typed after `:` or `/`.
prompt: std.ArrayList(u8) = .empty,
message: std.ArrayList(u8) = .empty,
message_is_error: bool = false,
/// Text stored by deletions and yanks; `linewise` if it is a whole line.
register: std.ArrayList(u8) = .empty,
linewise: bool = false,
has_register: bool = false,
pattern: std.ArrayList(u8) = .empty,
undo_stack: std.ArrayList(Change) = .empty,
redo_stack: std.ArrayList(Change) = .empty,
/// Whether the current insert session has been recorded for undo.
insert_recorded: bool = false,
/// Identifies the buffer contents; equal to `saved_version` when unmodified.
version: u64 = 0,
saved_version: u64 = 0,
versions: u64 = 0,
/// Set when writing failed after the file was truncated: the file may be
/// incomplete, and its backup holds the contents from before.
backup_kept: bool = false,
/// Number of text rows on screen, for half-page motions.
rows: usize = 24,
quit_requested: bool = false,

pub fn init(gpa: Allocator, io: Io) Error!Editor {
    var e: Editor = .{ .gpa = gpa, .io = io };
    try e.setText("");
    return e;
}

pub fn deinit(e: *Editor) void {
    for (e.lines.items) |*l| l.deinit(e.gpa);
    e.clearHistory(&e.undo_stack);
    e.clearHistory(&e.redo_stack);
    inline for (.{ &e.data, &e.lines, &e.path, &e.prompt, &e.message, &e.register, &e.pattern, &e.undo_stack, &e.redo_stack }) |list|
        list.deinit(e.gpa);
}

pub fn line(e: *const Editor, n: usize) []const u8 {
    return e.lines.items[n].items;
}

pub fn lineCount(e: *const Editor) usize {
    return e.lines.items.len;
}

pub fn isModified(e: *const Editor) bool {
    return e.version != e.saved_version;
}

/// The screen column of the cursor.
pub fn column(e: *const Editor) usize {
    return text.column(e.current(), e.cursor.col);
}

fn current(e: *const Editor) []const u8 {
    return e.line(e.cursor.line);
}

/// The cursor line, ready to be changed.
fn currentLine(e: *Editor) Error!*Line {
    const l = &e.lines.items[e.cursor.line];
    try own(e.gpa, l);
    return l;
}

/// Gives a borrowed line its own copy of its bytes.
fn own(gpa: Allocator, l: *Line) Error!void {
    if (l.capacity > 0) return;
    var copy: Line = .empty;
    try copy.appendSlice(gpa, l.items);
    l.* = copy;
}

/// A copy of a line; a borrowed line is shared, as its bytes never change.
fn copyLine(gpa: Allocator, l: Line) Error!Line {
    if (l.capacity == 0) return l;
    var copy: Line = .empty;
    try copy.appendSlice(gpa, l.items);
    return copy;
}

// Files.

/// Replaces the buffer with the file at `path`. A missing file gives an
/// empty buffer; the file is created when written.
pub fn open(e: *Editor, path: []const u8) !void {
    const data = try readFile(e.io, e.gpa, path);
    if (path.ptr != e.path.items.ptr) {
        e.path.clearRetainingCapacity();
        try e.path.appendSlice(e.gpa, path);
    }
    var bytes: std.ArrayList(u8) = data orelse .empty;
    e.load(bytes) catch |err| {
        bytes.deinit(e.gpa);
        return err;
    };
    e.cursor = .{};
    e.backup_kept = false;
    e.versions += 1;
    e.version = e.versions;
    e.saved_version = e.version;
    if (data == null) return e.say("\"{s}\" new file", .{path});
    try e.say("\"{s}\" {d} lines", .{ path, e.lineCount() });
}

/// Reads the file at `path`, or returns null if there is none.
fn readFile(io: Io, gpa: Allocator, path: []const u8) !?std.ArrayList(u8) {
    const file = Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => |other| return other,
    };
    defer file.close(io);
    var reader = file.reader(io, &.{});
    var data: std.ArrayList(u8) = try .initCapacity(gpa, try reader.getSize());
    errdefer data.deinit(gpa);
    reader.interface.appendRemaining(gpa, &data, .unlimited) catch |err| switch (err) {
        error.ReadFailed => return reader.err orelse err,
        else => |other| return other,
    };
    return data;
}

/// Writes the buffer to its file; returns whether it succeeded.
///
/// The file is overwritten in place, which keeps its permissions, owner and
/// links. Before that it is copied to a backup, `path~`, which is deleted
/// once the new contents are written and synced. If writing fails, the
/// backup is kept, and reused by the next write. A new file needs no
/// backup. An existing `path~` is never replaced.
fn write(e: *Editor) Error!bool {
    const path = e.path.items;
    const backup = try std.mem.concat(e.gpa, u8, &.{ path, "~" });
    defer e.gpa.free(backup);
    const cwd = Io.Dir.cwd();

    const made = !e.backup_kept and (copyFile(e.io, path, backup) catch |err| {
        try e.fail("\"{s}\": backup failed: {t}", .{ backup, err });
        return false;
    });
    const file = cwd.createFile(e.io, path, .{}) catch |err| {
        if (made) cwd.deleteFile(e.io, backup) catch {};
        try e.fail("\"{s}\": {t}", .{ path, err });
        return false;
    };
    defer file.close(e.io);
    e.writeSynced(file) catch |err| {
        e.backup_kept = made or e.backup_kept;
        if (e.backup_kept) {
            try e.fail("\"{s}\": {t}; original in \"{s}\"", .{ path, err, backup });
        } else try e.fail("\"{s}\": {t}", .{ path, err });
        return false;
    };
    if (made or e.backup_kept) cwd.deleteFile(e.io, backup) catch {};
    e.backup_kept = false;
    e.saved_version = e.version;
    try e.say("\"{s}\" {d} lines written", .{ path, e.lineCount() });
    return true;
}

/// Copies the file `from` to a new file `to` with the same permissions,
/// and syncs it. Returns false if `from` does not exist.
fn copyFile(io: Io, from: []const u8, to: []const u8) !bool {
    const cwd = Io.Dir.cwd();
    const source = cwd.openFile(io, from, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => |other| return other,
    };
    defer source.close(io);
    const stat = try source.stat(io);
    const file = try cwd.createFile(io, to, .{ .exclusive = true, .permissions = stat.permissions });
    defer file.close(io);
    errdefer cwd.deleteFile(io, to) catch {};
    var buffer: [64 * 1024]u8 = undefined;
    var reader = source.reader(io, &.{});
    // Plain reads and writes: sendfile reports a full disk as unexpected.
    reader.mode = reader.mode.toSimple();
    var writer = file.writerStreaming(io, &buffer);
    _ = reader.interface.streamRemaining(&writer.interface) catch |err| switch (err) {
        error.ReadFailed => return reader.err orelse err,
        error.WriteFailed => return writer.err orelse err,
    };
    writer.interface.flush() catch |err| return writer.err orelse err;
    try file.sync(io);
    return true;
}

fn writeSynced(e: *const Editor, file: Io.File) !void {
    var buffer: [64 * 1024]u8 = undefined;
    var writer = file.writerStreaming(e.io, &buffer);
    e.writeText(&writer.interface) catch |err| return writer.err orelse err;
    writer.interface.flush() catch |err| return writer.err orelse err;
    try file.sync(e.io);
}

/// Writes the buffer as file contents: every line followed by a newline,
/// except that a single empty line is an empty file.
fn writeText(e: *const Editor, w: *Io.Writer) Io.Writer.Error!void {
    if (e.lineCount() == 1 and e.line(0).len == 0) return;
    for (e.lines.items) |l| {
        try w.writeAll(l.items);
        try w.writeByte('\n');
    }
}

/// The buffer as file contents, for tests.
fn getText(e: *const Editor) Error![]u8 {
    var out: Io.Writer.Allocating = .init(e.gpa);
    defer out.deinit();
    e.writeText(&out.writer) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

/// Replaces the buffer with a copy of `bytes`, as file contents.
fn setText(e: *Editor, bytes: []const u8) Error!void {
    var data: std.ArrayList(u8) = .empty;
    try data.appendSlice(e.gpa, bytes);
    e.load(data) catch |err| {
        data.deinit(e.gpa);
        return err;
    };
}

/// Replaces the buffer with the file contents `data`, whose final newline is
/// optional, and forgets all changes. Takes `data` unless it fails.
fn load(e: *Editor, data: std.ArrayList(u8)) Error!void {
    const body = if (std.mem.endsWith(u8, data.items, "\n")) data.items[0 .. data.items.len - 1] else data.items;
    try e.lines.ensureTotalCapacityPrecise(e.gpa, std.mem.countScalar(u8, body, '\n') + 1);
    e.clearHistory(&e.undo_stack);
    e.clearHistory(&e.redo_stack);
    for (e.lines.items) |*l| l.deinit(e.gpa);
    e.lines.clearRetainingCapacity();
    e.data.deinit(e.gpa);
    e.data = data;
    var rest = body;
    while (std.mem.indexOfScalar(u8, rest, '\n')) |n| {
        e.lines.appendAssumeCapacity(borrow(rest[0..n]));
        rest = rest[n + 1 ..];
    }
    e.lines.appendAssumeCapacity(borrow(rest));
}

fn borrow(bytes: []u8) Line {
    var l: Line = .empty;
    l.items = bytes;
    return l;
}

// Keys.

pub fn handleKey(e: *Editor, key: u21) Error!void {
    switch (e.mode) {
        .normal => try e.normalKey(key),
        .insert => try e.insertKey(key),
        .command, .search => try e.promptKey(key),
    }
    if (e.mode == .normal) e.clampCursor();
    if (e.keep_goal) e.keep_goal = false else e.goal = e.column();
}

fn normalKey(e: *Editor, key: u21) Error!void {
    e.clearMessage();
    if (e.replacing) {
        e.replacing = false;
        return e.replace(key);
    }
    if (key > 0x7f) {
        e.pending_len = 0;
        return;
    }
    e.pending[e.pending_len] = @intCast(key);
    e.pending_len += 1;
    const typed = e.pending[0..e.pending_len];
    for (bindings) |b| {
        if (!std.mem.startsWith(u8, b[0], typed)) continue;
        if (b[0].len == typed.len) {
            e.pending_len = 0;
            try b[1](e);
        }
        return;
    }
    e.pending_len = 0;
}

fn insertKey(e: *Editor, key: u21) Error!void {
    e.clearMessage();
    switch (key) {
        esc => {
            e.mode = .normal;
            if (e.cursor.col > 0) e.cursor.col = text.prev(e.current(), e.cursor.col);
        },
        enter => try e.splitLine(),
        backspace => try e.deleteBackward(),
        tab => try e.insertText(&@as([text.tab_width]u8, @splat(' '))),
        else => {
            var buf: [4]u8 = undefined;
            if (isPrintable(key)) try e.insertText(encode(key, &buf));
        },
    }
}

fn promptKey(e: *Editor, key: u21) Error!void {
    switch (key) {
        esc => {
            e.mode = .normal;
            e.prompt.clearRetainingCapacity();
        },
        enter => {
            const mode = e.mode;
            e.mode = .normal;
            defer e.prompt.clearRetainingCapacity();
            if (mode == .command) return e.runCommand(e.prompt.items);
            if (e.prompt.items.len > 0) {
                e.pattern.clearRetainingCapacity();
                try e.pattern.appendSlice(e.gpa, e.prompt.items);
            }
            try e.searchNext();
        },
        backspace => {
            const s = e.prompt.items;
            if (s.len == 0) e.mode = .normal else e.prompt.shrinkRetainingCapacity(text.prev(s, s.len));
        },
        else => {
            var buf: [4]u8 = undefined;
            if (isPrintable(key)) try e.prompt.appendSlice(e.gpa, encode(key, &buf));
        },
    }
}

fn isPrintable(key: u21) bool {
    return key >= 0x20 and key != 0x7f;
}

fn encode(key: u21, buf: *[4]u8) []const u8 {
    const n = std.unicode.utf8Encode(key, buf) catch return "\u{fffd}";
    return buf[0..n];
}

/// Keeps the cursor on a character, as normal mode requires.
fn clampCursor(e: *Editor) void {
    const s = e.current();
    if (e.cursor.col >= s.len) e.cursor.col = if (s.len == 0) 0 else text.prev(s, s.len);
}

// Motions.

fn left(e: *Editor) Error!void {
    if (e.cursor.col > 0) e.cursor.col = text.prev(e.current(), e.cursor.col);
}

fn right(e: *Editor) Error!void {
    const s = e.current();
    if (e.cursor.col < s.len and text.next(s, e.cursor.col) < s.len) e.cursor.col = text.next(s, e.cursor.col);
}

/// Moves to `n`, clamped to the buffer, keeping the goal column.
fn moveToLine(e: *Editor, n: usize) void {
    e.cursor.line = @min(n, e.lineCount() - 1);
    e.cursor.col = text.offset(e.current(), e.goal);
    e.keep_goal = true;
}

fn down(e: *Editor) Error!void {
    e.moveToLine(e.cursor.line + 1);
}

fn up(e: *Editor) Error!void {
    e.moveToLine(e.cursor.line -| 1);
}

fn halfPageDown(e: *Editor) Error!void {
    e.moveToLine(e.cursor.line + @max(e.rows / 2, 1));
}

fn halfPageUp(e: *Editor) Error!void {
    e.moveToLine(e.cursor.line -| @max(e.rows / 2, 1));
}

fn lineStart(e: *Editor) Error!void {
    e.cursor.col = 0;
}

fn firstNonBlank(s: []const u8) usize {
    return std.mem.indexOfNone(u8, s, " \t") orelse s.len;
}

fn lineFirstNonBlank(e: *Editor) Error!void {
    e.cursor.col = firstNonBlank(e.current());
}

fn lineEnd(e: *Editor) Error!void {
    e.cursor.col = e.current().len;
}

fn goToLine(e: *Editor, n: usize) void {
    e.cursor.line = @min(n, e.lineCount() - 1);
    e.cursor.col = firstNonBlank(e.current());
}

fn firstLine(e: *Editor) Error!void {
    e.goToLine(0);
}

fn lastLine(e: *Editor) Error!void {
    e.goToLine(e.lineCount() - 1);
}

// Words. Positions run through the buffer with a blank at the end of each
// line, so that no word spans two lines. As in vi, `w` and `b` also stop at
// empty lines.

const Class = enum { blank, word, punctuation };

fn class(e: *const Editor, p: Pos) Class {
    const s = e.line(p.line);
    if (p.col >= s.len) return .blank;
    return switch (s[p.col]) {
        ' ', '\t' => .blank,
        'a'...'z', 'A'...'Z', '0'...'9', '_', 0x80...0xff => .word,
        else => .punctuation,
    };
}

fn forward(e: *const Editor, p: Pos) ?Pos {
    const s = e.line(p.line);
    if (p.col < s.len) return .{ .line = p.line, .col = text.next(s, p.col) };
    if (p.line + 1 < e.lineCount()) return .{ .line = p.line + 1 };
    return null;
}

fn backward(e: *const Editor, p: Pos) ?Pos {
    if (p.col > 0) return .{ .line = p.line, .col = text.prev(e.line(p.line), p.col) };
    if (p.line > 0) return .{ .line = p.line - 1, .col = e.line(p.line - 1).len };
    return null;
}

fn isEmptyLine(e: *const Editor, p: Pos) bool {
    return e.line(p.line).len == 0;
}

/// The start of the next word.
fn nextWord(e: *const Editor) Pos {
    var p = e.cursor;
    const start = e.class(p);
    if (start != .blank) while (e.class(p) == start) {
        p = e.forward(p) orelse return p;
    };
    while (e.class(p) == .blank) {
        if (p.line != e.cursor.line and e.isEmptyLine(p)) return p;
        p = e.forward(p) orelse return p;
    }
    return p;
}

/// The end of this or the next word.
fn nextWordEnd(e: *const Editor) Pos {
    var p = e.forward(e.cursor) orelse return e.cursor;
    while (e.class(p) == .blank) p = e.forward(p) orelse return p;
    const c = e.class(p);
    while (e.forward(p)) |q| : (p = q) if (e.class(q) != c) break;
    return p;
}

/// The start of this or the previous word.
fn previousWord(e: *const Editor) Pos {
    var p = e.backward(e.cursor) orelse return e.cursor;
    while (e.class(p) == .blank) {
        if (e.isEmptyLine(p)) return p;
        p = e.backward(p) orelse return p;
    }
    const c = e.class(p);
    while (e.backward(p)) |q| : (p = q) if (e.class(q) != c) break;
    return p;
}

fn wordForward(e: *Editor) Error!void {
    e.cursor = e.nextWord();
}

fn wordBackward(e: *Editor) Error!void {
    e.cursor = e.previousWord();
}

fn wordEnd(e: *Editor) Error!void {
    e.cursor = e.nextWordEnd();
}

/// The end of the span of `dw` and `yw`: the next word on this line, or
/// else the end of the line.
fn wordSpanEnd(e: *const Editor) usize {
    const p = e.nextWord();
    return if (p.line == e.cursor.line) p.col else e.current().len;
}

// Search.

fn startSearch(e: *Editor) Error!void {
    e.mode = .search;
}

/// Moves to the next occurrence of the pattern, wrapping at the end.
fn searchNext(e: *Editor) Error!void {
    const pattern = e.pattern.items;
    if (pattern.len == 0) return e.fail("no previous search", .{});
    const n = e.lineCount();
    for (0..n + 1) |i| {
        const l = (e.cursor.line + i) % n;
        const s = e.line(l);
        const from = if (i == 0) @min(e.cursor.col + 1, s.len) else 0;
        const col = std.mem.indexOfPos(u8, s, from, pattern) orelse continue;
        if (i == n and col > e.cursor.col) break;
        const wrapped = e.cursor.line + i >= n;
        e.cursor = .{ .line = l, .col = col };
        if (wrapped) try e.say("search wrapped", .{});
        return;
    }
    try e.fail("not found: {s}", .{pattern});
}

// Insert mode.

fn enterInsert(e: *Editor, col: usize) void {
    e.cursor.col = col;
    e.mode = .insert;
    e.insert_recorded = false;
}

fn insert(e: *Editor) Error!void {
    e.enterInsert(e.cursor.col);
}

fn append(e: *Editor) Error!void {
    const s = e.current();
    e.enterInsert(if (s.len == 0) 0 else text.next(s, e.cursor.col));
}

fn insertAtFirstNonBlank(e: *Editor) Error!void {
    e.enterInsert(firstNonBlank(e.current()));
}

fn appendAtEnd(e: *Editor) Error!void {
    e.enterInsert(e.current().len);
}

fn openLine(e: *Editor, n: usize) Error!void {
    try e.recordChange(n, 0);
    try e.lines.insert(e.gpa, n, .empty);
    e.cursor = .{ .line = n };
    e.mode = .insert;
    e.insert_recorded = true;
}

fn openBelow(e: *Editor) Error!void {
    try e.openLine(e.cursor.line + 1);
}

fn openAbove(e: *Editor) Error!void {
    try e.openLine(e.cursor.line);
}

/// Records a change for undo; an insert session is one change.
fn recordInsert(e: *Editor, top: usize, n: usize) Error!void {
    if (!e.insert_recorded) try e.beginChange(top);
    e.insert_recorded = true;
    try e.extendChange(top, n);
}

fn insertText(e: *Editor, bytes: []const u8) Error!void {
    try e.recordInsert(e.cursor.line, 1);
    try (try e.currentLine()).insertSlice(e.gpa, e.cursor.col, bytes);
    e.cursor.col += bytes.len;
}

fn splitLine(e: *Editor) Error!void {
    try e.recordInsert(e.cursor.line, 1);
    try own(e.gpa, &e.lines.items[e.cursor.line]);
    var tail: Line = .empty;
    errdefer tail.deinit(e.gpa);
    try tail.appendSlice(e.gpa, e.current()[e.cursor.col..]);
    try e.lines.insert(e.gpa, e.cursor.line + 1, tail);
    e.lines.items[e.cursor.line].shrinkRetainingCapacity(e.cursor.col);
    e.cursor = .{ .line = e.cursor.line + 1 };
}

/// Deletes the character before the cursor, joining lines at column 0.
fn deleteBackward(e: *Editor) Error!void {
    const p = e.cursor;
    if (p.col > 0) {
        try e.recordInsert(p.line, 1);
        const start = text.prev(e.current(), p.col);
        (try e.currentLine()).replaceRangeAssumeCapacity(start, p.col - start, "");
        e.cursor.col = start;
    } else if (p.line > 0) {
        try e.recordInsert(p.line - 1, 2);
        const above = &e.lines.items[p.line - 1];
        try own(e.gpa, above);
        const col = above.items.len;
        try above.appendSlice(e.gpa, e.current());
        var removed = e.lines.orderedRemove(p.line);
        removed.deinit(e.gpa);
        e.cursor = .{ .line = p.line - 1, .col = col };
    }
}

// Changes in normal mode.

/// Sets the register. An empty span leaves it unchanged.
fn store(e: *Editor, bytes: []const u8, linewise: bool) Error!void {
    if (bytes.len == 0 and !linewise) return;
    e.register.clearRetainingCapacity();
    try e.register.appendSlice(e.gpa, bytes);
    e.linewise = linewise;
    e.has_register = true;
}

/// Stores, then deletes, the text from the cursor to `end`.
fn cut(e: *Editor, end: usize) Error!void {
    const col = e.cursor.col;
    if (end <= col) return;
    try e.store(e.current()[col..end], false);
    try e.recordChange(e.cursor.line, 1);
    (try e.currentLine()).replaceRangeAssumeCapacity(col, end - col, "");
}

fn deleteChar(e: *Editor) Error!void {
    const s = e.current();
    if (s.len > 0) try e.cut(text.next(s, e.cursor.col));
}

fn deleteWord(e: *Editor) Error!void {
    try e.cut(e.wordSpanEnd());
}

fn deleteLine(e: *Editor) Error!void {
    try e.yankLine();
    try e.recordChange(e.cursor.line, 1);
    if (e.lineCount() == 1) {
        (try e.currentLine()).clearRetainingCapacity();
    } else {
        var removed = e.lines.orderedRemove(e.cursor.line);
        removed.deinit(e.gpa);
    }
    e.goToLine(e.cursor.line);
}

fn yankWord(e: *Editor) Error!void {
    try e.store(e.current()[e.cursor.col..e.wordSpanEnd()], false);
}

fn yankLine(e: *Editor) Error!void {
    try e.store(e.current(), true);
}

/// Puts the register after (`p`) or before (`P`) the cursor, or below or
/// above the line if it holds a line.
fn put(e: *Editor, after: bool) Error!void {
    if (!e.has_register) return e.fail("nothing to put", .{});
    const bytes = e.register.items;
    if (e.linewise) {
        const n = e.cursor.line + @intFromBool(after);
        try e.recordChange(n, 0);
        var copy: Line = .empty;
        errdefer copy.deinit(e.gpa);
        try copy.appendSlice(e.gpa, bytes);
        try e.lines.insert(e.gpa, n, copy);
        e.goToLine(n);
    } else {
        try e.recordChange(e.cursor.line, 1);
        const s = e.current();
        const at = if (after and s.len > 0) text.next(s, e.cursor.col) else e.cursor.col;
        try (try e.currentLine()).insertSlice(e.gpa, at, bytes);
        e.cursor.col = text.prev(e.current(), at + bytes.len);
    }
}

fn putAfter(e: *Editor) Error!void {
    try e.put(true);
}

fn putBefore(e: *Editor) Error!void {
    try e.put(false);
}

fn startReplace(e: *Editor) Error!void {
    e.replacing = true;
}

fn replace(e: *Editor, key: u21) Error!void {
    const s = e.current();
    if (s.len == 0 or !isPrintable(key)) return;
    var buf: [4]u8 = undefined;
    const end = text.next(s, e.cursor.col);
    try e.recordChange(e.cursor.line, 1);
    try (try e.currentLine()).replaceRange(e.gpa, e.cursor.col, end - e.cursor.col, encode(key, &buf));
}

// Undo. Before each change the lines it is about to alter are copied, as
// vim does; undoing a change exchanges those lines for the current ones.

/// Records that the `n` lines from `top` are about to change.
fn recordChange(e: *Editor, top: usize, n: usize) Error!void {
    try e.beginChange(top);
    try e.extendChange(top, n);
}

/// Starts a change that as yet covers no lines, at line `top`.
fn beginChange(e: *Editor, top: usize) Error!void {
    if (e.undo_stack.items.len == undo_limit) freeChange(e.gpa, e.undo_stack.orderedRemove(0));
    try e.undo_stack.append(e.gpa, .{
        .top = top,
        .after = e.lineCount() - top,
        .cursor = e.cursor,
        .version = e.version,
    });
    e.clearHistory(&e.redo_stack);
    e.versions += 1;
    e.version = e.versions;
}

/// Widens the newest change to cover the `n` lines from `top`, copying
/// each line it gains; the lines between are unchanged so far.
fn extendChange(e: *Editor, top: usize, n: usize) Error!void {
    const c = &e.undo_stack.items[e.undo_stack.items.len - 1];
    while (c.top > top) {
        try c.lines.ensureUnusedCapacity(e.gpa, 1);
        c.lines.insertAssumeCapacity(0, try copyLine(e.gpa, e.lines.items[c.top - 1]));
        c.top -= 1;
    }
    while (e.lineCount() - c.after < top + n) {
        try c.lines.ensureUnusedCapacity(e.gpa, 1);
        c.lines.appendAssumeCapacity(try copyLine(e.gpa, e.lines.items[e.lineCount() - c.after]));
        c.after -= 1;
    }
}

/// Undoes the newest change in `from`, recording the reverse in `to`.
fn travel(e: *Editor, from: *std.ArrayList(Change), to: *std.ArrayList(Change)) Error!void {
    const c = from.getLastOrNull() orelse return e.fail("no more changes", .{});
    const count = e.lineCount() - c.after - c.top;
    var reverse: Change = .{ .top = c.top, .after = c.after, .cursor = e.cursor, .version = e.version };
    try reverse.lines.appendSlice(e.gpa, e.lines.items[c.top..][0..count]);
    errdefer reverse.lines.deinit(e.gpa);
    try to.ensureUnusedCapacity(e.gpa, 1);
    try e.lines.ensureUnusedCapacity(e.gpa, c.lines.items.len);
    e.lines.replaceRangeAssumeCapacity(c.top, count, c.lines.items);
    to.appendAssumeCapacity(reverse);
    var old = from.pop().?;
    old.lines.deinit(e.gpa);
    e.cursor = c.cursor;
    e.version = c.version;
}

fn undo(e: *Editor) Error!void {
    try e.travel(&e.undo_stack, &e.redo_stack);
}

fn redo(e: *Editor) Error!void {
    try e.travel(&e.redo_stack, &e.undo_stack);
}

fn freeChange(gpa: Allocator, c: Change) void {
    var lines = c.lines;
    for (lines.items) |*l| l.deinit(gpa);
    lines.deinit(gpa);
}

fn clearHistory(e: *Editor, stack: *std.ArrayList(Change)) void {
    for (stack.items) |c| freeChange(e.gpa, c);
    stack.clearRetainingCapacity();
}

// Commands.

fn startCommand(e: *Editor) Error!void {
    e.mode = .command;
}

fn runCommand(e: *Editor, input: []const u8) Error!void {
    const cmd = std.mem.trim(u8, input, " ");
    if (cmd.len == 0) return;
    if (std.fmt.parseUnsigned(usize, cmd, 10)) |n| return e.goToLine(n -| 1) else |_| {}
    const end = std.mem.indexOfScalar(u8, cmd, ' ') orelse cmd.len;
    const name = cmd[0..end];
    const arg = std.mem.trimStart(u8, cmd[end..], " ");
    if (std.mem.eql(u8, name, "e") or std.mem.eql(u8, name, "e!")) return e.edit(arg, name.len == 2);
    if (arg.len == 0) for (commands) |c| {
        if (std.mem.eql(u8, c[0], name)) return c[1](e);
    };
    try e.fail("not a command: {s}", .{cmd});
}

/// `:e [path]`: opens `path`, or rereads the current file.
fn edit(e: *Editor, arg: []const u8, force: bool) Error!void {
    if (e.isModified() and !force) return e.fail("unsaved changes (:w to write, :e! to discard)", .{});
    const path = if (arg.len == 0) e.path.items else arg;
    e.open(path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => try e.fail("\"{s}\": {t}", .{ path, err }),
    };
}

fn writeCommand(e: *Editor) Error!void {
    _ = try e.write();
}

fn quit(e: *Editor) Error!void {
    if (e.isModified()) return e.fail("unsaved changes (:w to write, :q! to discard)", .{});
    e.quit_requested = true;
}

fn forceQuit(e: *Editor) Error!void {
    e.quit_requested = true;
}

fn writeQuit(e: *Editor) Error!void {
    e.quit_requested = try e.write();
}

/// `:x`: writes only if modified, then quits.
fn exit(e: *Editor) Error!void {
    if (e.isModified()) try e.writeQuit() else e.quit_requested = true;
}

// Messages.

fn clearMessage(e: *Editor) void {
    e.message.clearRetainingCapacity();
    e.message_is_error = false;
}

fn say(e: *Editor, comptime fmt: []const u8, args: anytype) Error!void {
    e.clearMessage();
    try e.message.print(e.gpa, fmt, args);
}

fn fail(e: *Editor, comptime fmt: []const u8, args: anytype) Error!void {
    try e.say(fmt, args);
    e.message_is_error = true;
}

// Tests.

const testing = std.testing;

fn testEditor(content: []const u8) !Editor {
    var e = try Editor.init(testing.allocator, testing.io);
    errdefer e.deinit();
    try e.setText(content);
    return e;
}

/// Sends the characters of `keys` as keys.
fn typeKeys(e: *Editor, keys: []const u8) !void {
    var it = (try std.unicode.Utf8View.init(keys)).iterator();
    while (it.nextCodepoint()) |k| try e.handleKey(k);
}

fn expectText(e: *const Editor, expected: []const u8) !void {
    const actual = try e.getText();
    defer testing.allocator.free(actual);
    try testing.expectEqualStrings(expected, actual);
}

fn expectCursor(e: *const Editor, l: usize, col: usize) !void {
    try testing.expectEqual(Pos{ .line = l, .col = col }, e.cursor);
}

test "motions" {
    var e = try testEditor("one two\n  three\n\nfour, five\n");
    defer e.deinit();
    try typeKeys(&e, "llll");
    try expectCursor(&e, 0, 4);
    try typeKeys(&e, "$");
    try expectCursor(&e, 0, 6);
    try typeKeys(&e, "0w");
    try expectCursor(&e, 0, 4);
    try typeKeys(&e, "w");
    try expectCursor(&e, 1, 2);
    try typeKeys(&e, "w");
    try expectCursor(&e, 2, 0);
    try typeKeys(&e, "w");
    try expectCursor(&e, 3, 0);
    try typeKeys(&e, "w");
    try expectCursor(&e, 3, 4);
    try typeKeys(&e, "bb");
    try expectCursor(&e, 2, 0);
    try typeKeys(&e, "b");
    try expectCursor(&e, 1, 2);
    try typeKeys(&e, "e");
    try expectCursor(&e, 1, 6);
    try typeKeys(&e, "0^");
    try expectCursor(&e, 1, 2);
    try typeKeys(&e, "G");
    try expectCursor(&e, 3, 0);
    try typeKeys(&e, "gg");
    try expectCursor(&e, 0, 0);
    try typeKeys(&e, "hk");
    try expectCursor(&e, 0, 0);
}

test "vertical motions keep the goal column" {
    var e = try testEditor("abcdef\nab\n\tx\nabcdef\n");
    defer e.deinit();
    try typeKeys(&e, "$j");
    try expectCursor(&e, 1, 1);
    try typeKeys(&e, "j");
    try expectCursor(&e, 2, 1); // the x, at screen column 4
    try typeKeys(&e, "j");
    try expectCursor(&e, 3, 5);
    e.rows = 4;
    try typeKeys(&e, "\x15");
    try expectCursor(&e, 1, 1);
    try typeKeys(&e, "\x04\x04");
    try expectCursor(&e, 3, 5);
}

test "insert mode" {
    var e = try testEditor("ac\n");
    defer e.deinit();
    try typeKeys(&e, "ab\x1b");
    try expectText(&e, "abc\n");
    try expectCursor(&e, 0, 1);
    try typeKeys(&e, "A\té\rx\x1b");
    try expectText(&e, "abc    é\nx\n");
    try typeKeys(&e, "I\x7f\x7f\x7f\x1b");
    try expectText(&e, "abc   x\n");
    try typeKeys(&e, "Oz\x1bjox\x1b");
    try expectText(&e, "z\nabc   x\nx\n");
    try typeKeys(&e, "ggIy\x1b");
    try expectText(&e, "yz\nabc   x\nx\n");
}

test "deleting, yanking and putting" {
    var e = try testEditor("one two  three\nfour\n");
    defer e.deinit();
    try typeKeys(&e, "dw");
    try expectText(&e, "two  three\nfour\n");
    try typeKeys(&e, "wP");
    try expectText(&e, "two  one three\nfour\n");
    try expectCursor(&e, 0, 8);
    try typeKeys(&e, "xp");
    try expectText(&e, "two  onet hree\nfour\n");
    try typeKeys(&e, "$dw");
    try expectText(&e, "two  onet hre\nfour\n");
    try typeKeys(&e, "yyjp");
    try expectText(&e, "two  onet hre\nfour\ntwo  onet hre\n");
    try expectCursor(&e, 2, 0);
    try typeKeys(&e, "ddggP");
    try expectText(&e, "two  onet hre\ntwo  onet hre\nfour\n");
    try typeKeys(&e, "Gywggp");
    try expectText(&e, "tfourwo  onet hre\ntwo  onet hre\nfour\n");
    try typeKeys(&e, "rX");
    try expectText(&e, "tfouXwo  onet hre\ntwo  onet hre\nfour\n");
    try typeKeys(&e, "dddddddd");
    try expectText(&e, "");
}

test "an empty span leaves the register unchanged" {
    var e = try testEditor("ab\n\n");
    defer e.deinit();
    try typeKeys(&e, "xjdwywxkp");
    try expectText(&e, "ba\n\n");
}

test "undo and redo" {
    var e = try testEditor("one\n");
    defer e.deinit();
    try typeKeys(&e, "Atwo\rthree\x1b");
    try typeKeys(&e, "ddx");
    try expectText(&e, "netwo\n");
    try testing.expect(e.isModified());
    try typeKeys(&e, "uu");
    try expectText(&e, "onetwo\nthree\n");
    try typeKeys(&e, "u");
    try expectText(&e, "one\n");
    try testing.expect(!e.isModified());
    try typeKeys(&e, "u");
    try testing.expect(e.message_is_error);
    try typeKeys(&e, "UUU");
    try expectText(&e, "netwo\n");
    try typeKeys(&e, "uix\x1bU");
    try testing.expect(e.message_is_error);
}

test "undo records only the lines changed" {
    var e = try testEditor("a\nb\nc\nd\n");
    defer e.deinit();
    const cases = .{
        .{ "jx", 1 }, // within a line
        .{ "dd", 1 },
        .{ "p", 0 }, // a line put below
        .{ "oxy\ry\x1b", 0 }, // lines opened
        .{ "A\rz\x1b", 1 }, // a line split
        .{ "jI\x7f\x7f\x1b", 2 }, // two lines joined
    };
    inline for (cases) |c| {
        try typeKeys(&e, c[0]);
        try testing.expectEqual(c[1], e.undo_stack.getLast().lines.items.len);
    }
    while (e.undo_stack.items.len > 0) try e.undo();
    try expectText(&e, "a\nb\nc\nd\n");
}

test "search" {
    var e = try testEditor("ab ab\nxab\n");
    defer e.deinit();
    try typeKeys(&e, "/ab\r");
    try expectCursor(&e, 0, 3);
    try typeKeys(&e, "n");
    try expectCursor(&e, 1, 1);
    try typeKeys(&e, "n");
    try expectCursor(&e, 0, 0);
    try testing.expectEqualStrings("search wrapped", e.message.items);
    try typeKeys(&e, "/zz\r");
    try testing.expect(e.message_is_error);
    try typeKeys(&e, "/a\x7f\x7f");
    try testing.expectEqual(Mode.normal, e.mode);
}

test "commands" {
    var e = try testEditor("1\n2\n3\n");
    defer e.deinit();
    try typeKeys(&e, ":3\r");
    try expectCursor(&e, 2, 0);
    try typeKeys(&e, ":0\r");
    try expectCursor(&e, 0, 0);
    try typeKeys(&e, ":nope\r");
    try testing.expect(e.message_is_error);
    try typeKeys(&e, ":q x\r");
    try testing.expect(e.message_is_error);
    try typeKeys(&e, "x:q\r");
    try testing.expect(!e.quit_requested);
    try typeKeys(&e, ":e\r");
    try testing.expect(e.message_is_error);
    try typeKeys(&e, ":q!\r");
    try testing.expect(e.quit_requested);
}

test "files" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = ".zig-cache/tmp/" ++ tmp.sub_path;
    const a = dir ++ "/a";
    const b = dir ++ "/b";

    var e = try testEditor("");
    defer e.deinit();
    try e.open(a);
    try testing.expectEqualStrings("\"" ++ a ++ "\" new file", e.message.items);
    try typeKeys(&e, "ihello\x1b:w\r");
    try testing.expect(!e.isModified());
    try typeKeys(&e, "x:e " ++ b ++ "\r");
    try testing.expect(e.message_is_error);
    try typeKeys(&e, ":wq\r");
    try testing.expect(e.quit_requested);
    try typeKeys(&e, ":e " ++ b ++ "\r");
    try testing.expectEqualStrings(b, e.path.items);
    try typeKeys(&e, "ix\x1b:e! " ++ a ++ "\r");
    try expectText(&e, "hell\n");
    try typeKeys(&e, "x:e!\r");
    try expectText(&e, "hell\n");
    try testing.expect(!e.isModified());
    try typeKeys(&e, ":e " ++ dir ++ "\r");
    try testing.expect(e.message_is_error);
    try testing.expectEqualStrings(a, e.path.items);

    var buf: [16]u8 = undefined;
    const data = try tmp.dir.readFile(testing.io, "a", &buf);
    try testing.expectEqualStrings("hell\n", data);
    try testing.expectError(error.FileNotFound, tmp.dir.access(testing.io, "b", .{}));
}

/// Keys for random testing: every normal-mode key except `:`, which could
/// write files, and some keys for insert mode and the search prompt.
const random_keys = blk: {
    @setEvalBranchQuota(10_000);
    var keys: []const u21 = &.{ esc, esc, enter, backspace, tab, ' ', 'é', '\x01' };
    for (bindings) |b| for (b[0]) |c| {
        if (c != ':' and std.mem.indexOfScalar(u21, keys, c) == null) keys = keys ++ .{@as(u21, c)};
    };
    break :blk keys[0..].*;
};

/// Types the keys chosen by `choices`, checking that the cursor stays on a
/// character and pending keys begin a binding, then checks that undoing
/// every change restores the original text and redoing them restores the
/// result.
fn checkKeys(choices: []const u8) !void {
    var e = try testEditor("one two\n\t three\n\nfour, five é\n");
    defer e.deinit();
    const original = try e.getText();
    defer testing.allocator.free(original);
    const data = try testing.allocator.dupe(u8, e.data.items);
    defer testing.allocator.free(data);

    // Each key records at most one change, so none is forgotten.
    for (choices[0..@min(choices.len, undo_limit)]) |c| {
        try e.handleKey(random_keys[c % random_keys.len]);
        const s = e.current();
        try testing.expect(e.cursor.col <= s.len);
        if (e.cursor.col < s.len) try testing.expect(s[e.cursor.col] & 0xc0 != 0x80);
        if (e.mode == .normal) try testing.expect(e.cursor.col < s.len or s.len == 0);
        const pending = e.pending[0..e.pending_len];
        for (bindings) |b| {
            if (std.mem.startsWith(u8, b[0], pending) and b[0].len > pending.len) break;
        } else try testing.expectEqual(0, pending.len);
    }
    try e.handleKey(esc);
    try e.handleKey(esc);
    while (e.redo_stack.items.len > 0) try e.redo();
    const result = try e.getText();
    defer testing.allocator.free(result);
    while (e.undo_stack.items.len > 0) try e.undo();
    try expectText(&e, original);
    try testing.expect(!e.isModified());
    while (e.redo_stack.items.len > 0) try e.redo();
    try expectText(&e, result);
    try testing.expectEqualStrings(data, e.data.items);
}

test "random keys" {
    var prng: std.Random.DefaultPrng = .init(testing.random_seed);
    var choices: [undo_limit]u8 = undefined;
    for (0..2000) |_| {
        prng.random().bytes(&choices);
        try checkKeys(&choices);
    }
}

test "fuzz keys" {
    try testing.fuzz({}, struct {
        fn testOne(_: void, smith: *testing.Smith) !void {
            var choices: [undo_limit]u8 = undefined;
            try checkKeys(choices[0..smith.slice(&choices)]);
        }
    }.testOne, .{});
}
