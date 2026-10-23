//! Terminal front end: raw mode, key input and drawing.
//!
//! The screen shows the text, with a status line on the last row:
//!
//! ```text
//! the text, scrolled to keep the cursor in view
//! code  // comments dimmed, by file type
//! path [+]  or a message  or the : and / prompt          12:5  340 lines
//! ```
//!
//! Each key is followed by a full redraw, sent as one synchronized update.
//! A resize interrupts the blocking read, which causes a redraw.
//! Comment prefixes for each file type are in the table `comments`.

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;
const Io = std.Io;
const Editor = @import("Editor.zig");
const text = @import("text.zig");

const Prefixes = []const []const u8;

/// Line comment prefixes by file extension, or by whole name for files
/// without one (a leading dot is part of the name). Files of other types
/// have no comments dimmed.
const comments = std.StaticStringMap(Prefixes).initComptime(.{
    .{ "zig", &.{"//"} },
    .{ "c", &.{"//"} },
    .{ "h", &.{"//"} },
    .{ "cpp", &.{"//"} },
    .{ "hpp", &.{"//"} },
    .{ "rs", &.{"//"} },
    .{ "go", &.{"//"} },
    .{ "js", &.{"//"} },
    .{ "ts", &.{"//"} },
    .{ "java", &.{"//"} },
    .{ "py", &.{"#"} },
    .{ "lua", &.{"--"} },
    .{ "sh", &.{"#"} },
    .{ "bash", &.{"#"} },
    .{ "zsh", &.{"#"} },
    .{ ".bashrc", &.{"#"} },
    .{ ".zshrc", &.{"#"} },
    .{ ".profile", &.{"#"} },
    .{ "s", &.{ "#", "//", ";" } },
    .{ "S", &.{ "#", "//", ";" } },
    .{ "asm", &.{";"} },
});

/// The comment prefixes for the file at `path`.
fn commentPrefixes(path: []const u8) Prefixes {
    const name = std.fs.path.basename(path);
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse 0;
    const key = if (dot > 0) name[dot + 1 ..] else name;
    return comments.get(key) orelse &.{};
}

const dim = "\x1b[90m";
const red = "\x1b[31m";
const reset = "\x1b[m";
const clear_line = "\x1b[K";

var original: ?posix.termios = null;

/// Runs the editor on the terminal until it quits.
pub fn run(e: *Editor, io: Io) !void {
    try enterRawMode();
    defer restore();
    posix.sigaction(.WINCH, &.{
        .handler = .{ .handler = onResize },
        .mask = posix.sigemptyset(),
        .flags = 0, // no SA_RESTART: the read returns EINTR
    }, null);

    var frame: std.ArrayList(u8) = .empty;
    defer frame.deinit(e.gpa);
    var view: View = .{};
    var input: Input = .{};
    while (!e.quit_requested) {
        frame.clearRetainingCapacity();
        try draw(&frame, e.gpa, e, &view, windowSize());
        try write(io, frame.items);
        const free = input.free();
        const rc = linux.read(posix.STDIN_FILENO, free.ptr, free.len);
        switch (linux.errno(rc)) {
            .SUCCESS => if (rc == 0) return else try input.decode(e, rc),
            .INTR => {},
            else => |err| return posix.unexpectedErrno(err),
        }
    }
}

fn onResize(_: posix.SIG) callconv(.c) void {}

fn enterRawMode() !void {
    const saved = try posix.tcgetattr(posix.STDIN_FILENO);
    var raw = saved;
    raw.iflag.BRKINT = false;
    raw.iflag.ICRNL = false;
    raw.iflag.INPCK = false;
    raw.iflag.ISTRIP = false;
    raw.iflag.IXON = false;
    raw.oflag.OPOST = false;
    raw.cflag.CSIZE = .CS8;
    raw.lflag.ECHO = false;
    raw.lflag.ICANON = false;
    raw.lflag.IEXTEN = false;
    raw.lflag.ISIG = false;
    raw.cc[@backingInt(posix.V.MIN)] = 1;
    raw.cc[@backingInt(posix.V.TIME)] = 0;
    try posix.tcsetattr(posix.STDIN_FILENO, .FLUSH, raw);
    original = saved;
    rawWrite("\x1b[?1049h"); // alternate screen
}

/// Restores the terminal saved by `run`: the mode, the cursor shape and
/// the main screen. Safe to call at any time, including from a panic.
pub fn restore() void {
    const saved = original orelse return;
    original = null;
    rawWrite("\x1b[0 q\x1b[?1049l");
    posix.tcsetattr(posix.STDIN_FILENO, .FLUSH, saved) catch {};
}

fn rawWrite(bytes: []const u8) void {
    _ = linux.write(posix.STDOUT_FILENO, bytes.ptr, bytes.len);
}

fn write(io: Io, bytes: []const u8) !void {
    try Io.File.stdout().writeStreamingAll(io, bytes);
}

/// Bytes read from the terminal, keeping the start of a character split
/// between reads.
const Input = struct {
    buf: [4096]u8 = undefined,
    kept: usize = 0,

    /// Where to read into.
    fn free(in: *Input) []u8 {
        return in.buf[in.kept..];
    }

    /// Decodes `n` bytes read into `free()`.
    fn decode(in: *Input, e: *Editor, n: usize) !void {
        const len = in.kept + n;
        const used = try feed(e, in.buf[0..len]);
        std.mem.copyForwards(u8, &in.buf, in.buf[used..len]);
        in.kept = len - used;
    }
};

/// Decodes the bytes of one read into keys and returns the number used: an
/// incomplete character at the end is left for the next read. A read
/// beginning with an escape sequence (`Esc [` or `Esc O`: arrow, function
/// and similar keys) is discarded. Malformed UTF-8 is skipped. A newline,
/// as in pasted text, is taken as Enter.
fn feed(e: *Editor, bytes: []const u8) !usize {
    if (bytes.len > 1 and bytes[0] == Editor.esc and (bytes[1] == '[' or bytes[1] == 'O')) return bytes.len;
    var i: usize = 0;
    while (i < bytes.len) {
        const n = std.unicode.utf8ByteSequenceLength(bytes[i]) catch {
            i += 1;
            continue;
        };
        if (i + n > bytes.len and isPrefix(bytes[i..])) return i;
        const key = if (i + n <= bytes.len) std.unicode.utf8Decode(bytes[i..][0..n]) catch null else null;
        if (key) |k| {
            try e.handleKey(if (k == '\n') Editor.enter else k);
            i += n;
        } else i += 1;
    }
    return i;
}

/// Whether `bytes` could begin a character: a lead byte then continuation
/// bytes.
fn isPrefix(bytes: []const u8) bool {
    for (bytes[1..]) |b| if (b & 0xc0 != 0x80) return false;
    return true;
}

const Size = struct { rows: usize, cols: usize };

fn windowSize() Size {
    var ws: posix.winsize = undefined;
    const rc = linux.ioctl(posix.STDOUT_FILENO, posix.T.IOCGWINSZ, @intFromPtr(&ws));
    if (linux.errno(rc) != .SUCCESS or ws.row < 2 or ws.col < 1) return .{ .rows = 24, .cols = 80 };
    return .{ .rows = ws.row, .cols = ws.col };
}

/// The first line and screen column shown.
const View = struct { top: usize = 0, left: usize = 0 };

/// Moves the window `[start, start + size)` as little as possible to
/// contain `pos`.
fn scroll(start: usize, pos: usize, size: usize) usize {
    if (pos < start) return pos;
    if (pos >= start + size) return pos + 1 - size;
    return start;
}

/// The byte index where a comment starts in `s`, if any. A comment prefix
/// counts at the start of the line or after whitespace, outside quotes and
/// not escaped by a backslash. A quote not closed on the line is ignored,
/// as an apostrophe or a Rust lifetime is not a quote.
fn commentStart(s: []const u8, prefixes: Prefixes) ?usize {
    if (prefixes.len == 0) return null;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        switch (s[i]) {
            '\\' => i += 1,
            '"', '\'' => if (closingQuote(s, i)) |end| {
                i = end;
            },
            else => if (i == 0 or s[i - 1] == ' ' or s[i - 1] == '\t') {
                for (prefixes) |prefix| if (isComment(s[i..], prefix)) return i;
            },
        }
    }
    return null;
}

/// The index of the quote closing the one at `start`, skipping characters
/// escaped by a backslash.
fn closingQuote(s: []const u8, start: usize) ?usize {
    var i = start + 1;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\\') {
            i += 1;
        } else if (s[i] == s[start]) return i;
    }
    return null;
}

/// Whether `s` begins with a comment: `prefix`, any more of its characters
/// or `!` (as in `///`, `//!` or `###`), then whitespace or the end of the
/// line. So `# 1` is a comment but `#1` is not.
fn isComment(s: []const u8, prefix: []const u8) bool {
    if (!std.mem.startsWith(u8, s, prefix)) return false;
    var j = prefix.len;
    while (j < s.len and (s[j] == '!' or std.mem.indexOfScalar(u8, prefix, s[j]) != null)) j += 1;
    return j == s.len or s[j] == ' ' or s[j] == '\t';
}

fn draw(out: *std.ArrayList(u8), gpa: std.mem.Allocator, e: *Editor, view: *View, size: Size) !void {
    const rows = size.rows - 1;
    e.rows = rows;
    view.top = scroll(view.top, e.cursor.line, rows);
    view.left = scroll(view.left, e.column(), size.cols);

    const prefixes = commentPrefixes(e.path.items);
    try out.appendSlice(gpa, "\x1b[?2026h\x1b[H");
    for (0..rows) |row| {
        const n = view.top + row;
        if (n < e.lineCount()) {
            const s = e.line(n);
            const start = commentStart(s, prefixes);
            try drawLine(out, gpa, s, view.left, size.cols, start);
            if (start != null) try out.appendSlice(gpa, reset);
        }
        try out.appendSlice(gpa, clear_line ++ "\r\n");
    }

    // Status line.
    var right_buf: [64]u8 = undefined;
    const right = try std.fmt.bufPrint(&right_buf, "{d}:{d}  {d} lines", .{ e.cursor.line + 1, e.column() + 1, e.lineCount() });
    const left_width = size.cols -| (right.len + 1);
    var prefix: []const u8 = "";
    var left: []const u8 = e.path.items;
    var color: []const u8 = "";
    switch (e.mode) {
        .command => {
            prefix = ":";
            left = e.prompt.items;
        },
        .search => {
            prefix = "/";
            left = e.prompt.items;
        },
        else => if (e.message.items.len > 0) {
            left = e.message.items;
            if (e.message_is_error) color = red;
        },
    }
    const modified = e.mode != .command and e.mode != .search and e.message.items.len == 0 and e.isModified();
    try out.appendSlice(gpa, color);
    try out.appendSlice(gpa, prefix);
    try drawLine(out, gpa, left, 0, left_width -| prefix.len, null);
    if (modified) try out.appendSlice(gpa, " [+]");
    try out.appendSlice(gpa, reset ++ clear_line);
    if (right.len < size.cols) try out.print(gpa, "\x1b[{d};{d}H{s}", .{ size.rows, size.cols - right.len + 1, right });

    // Cursor: a bar while typing, a block otherwise.
    const typing = e.mode != .normal;
    const y, const x = switch (e.mode) {
        .command, .search => .{ size.rows, @min(1 + text.column(e.prompt.items, e.prompt.items.len), size.cols - 1) },
        else => .{ e.cursor.line - view.top + 1, e.column() - view.left },
    };
    try out.print(gpa, "\x1b[{d};{d}H\x1b[{d} q\x1b[?2026l", .{ y, x + 1, @as(u8, if (typing) 6 else 2) });
}

/// Appends the screen columns `[left, left + width)` of `s`, expanding tabs
/// and replacing control characters and malformed UTF-8 with `?`. Text from
/// byte `dim_from` on is dimmed.
fn drawLine(out: *std.ArrayList(u8), gpa: std.mem.Allocator, s: []const u8, left: usize, width: usize, dim_from: ?usize) !void {
    var col: usize = 0;
    var i: usize = 0;
    while (i < s.len and col < left + width) {
        if (i == dim_from) try out.appendSlice(gpa, dim);
        const j = text.next(s, i);
        const end = text.advance(col, s[i]);
        if (s[i] == '\t') {
            for (@max(col, left)..@min(end, left + width)) |_| try out.append(gpa, ' ');
        } else if (col >= left) {
            const c = s[i..j];
            const ok = std.unicode.utf8ValidateSlice(c) and c[0] >= 0x20 and c[0] != 0x7f;
            try out.appendSlice(gpa, if (ok) c else "?");
        }
        col = end;
        i = j;
    }
}

test "scroll" {
    try std.testing.expectEqual(0, scroll(0, 5, 10));
    try std.testing.expectEqual(6, scroll(0, 15, 10));
    try std.testing.expectEqual(3, scroll(6, 3, 10));
}

test "comments" {
    const zig = commentPrefixes("src/main.zig");
    const lua = commentPrefixes("init.lua");
    const asm_ = commentPrefixes("esp32/hello.s");
    try std.testing.expectEqual(2, commentStart("  // note", zig));
    try std.testing.expectEqual(6, commentStart("x = 1 // note", zig));
    try std.testing.expectEqual(null, commentStart("# not zig", zig));
    try std.testing.expectEqual(0, commentStart("-- note", lua));
    try std.testing.expectEqual(null, commentStart("x = 10 // 2", lua));
    try std.testing.expectEqual(9, commentStart("movi a2, # n", asm_));
    try std.testing.expectEqual(null, commentStart("mov r0, #1", asm_));
    try std.testing.expectEqual(null, commentStart("x //2", zig));
    try std.testing.expectEqual(0, commentStart("/// doc", zig));
    try std.testing.expectEqual(0, commentStart("//! doc", zig));
    try std.testing.expectEqual(2, commentStart("  //", zig));
    try std.testing.expectEqual(0, commentStart("#### banner", commentPrefixes("run.sh")));
    try std.testing.expectEqual(4, commentStart("nop ; x", commentPrefixes("boot.asm")));
    try std.testing.expectEqual(null, commentStart("a = \"// no\" + b//c", zig));
    try std.testing.expectEqual(9, commentStart("s = \"\\\\\" // c", zig));
    try std.testing.expectEqual(15, commentStart("x: &'a str = y // c", commentPrefixes("lib.rs")));
    try std.testing.expectEqual(10, commentStart("echo it's # c", commentPrefixes("run.sh")));
    try std.testing.expectEqual(null, commentStart("echo \\# no", commentPrefixes("run.sh")));
    try std.testing.expectEqual(7, commentStart("echo ; # x", commentPrefixes("run.sh")));
    try std.testing.expectEqual(0, commentStart("# x", commentPrefixes("/home/me/.bashrc")));
    try std.testing.expectEqual(null, commentStart("# x", commentPrefixes("LICENSE")));
    try std.testing.expectEqual(null, commentStart("# Title", commentPrefixes("README.md")));
}

test "drawLine" {
    const gpa = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try drawLine(&out, gpa, "a\tbé\x01", 0, 80, null);
    try std.testing.expectEqualStrings("a   bé?", out.items);
    out.clearRetainingCapacity();
    try drawLine(&out, gpa, "a\tbcd", 2, 3, null);
    try std.testing.expectEqualStrings("  b", out.items);
    out.clearRetainingCapacity();
    try drawLine(&out, gpa, "ab # c", 0, 80, 3);
    try std.testing.expectEqualStrings("ab " ++ dim ++ "# c", out.items);
    out.clearRetainingCapacity();
    try drawLine(&out, gpa, "ab # c", 4, 80, 3);
    try std.testing.expectEqualStrings(dim ++ " c", out.items);
}

/// Sends `chunks` as successive reads from the terminal.
fn readChunks(e: *Editor, chunks: []const []const u8) !void {
    var input: Input = .{};
    for (chunks) |chunk| {
        @memcpy(input.free()[0..chunk.len], chunk);
        try input.decode(e, chunk.len);
    }
}

fn expectLines(e: *const Editor, want: []const []const u8) !void {
    try std.testing.expectEqual(want.len, e.lineCount());
    for (want, 0..) |l, i| try std.testing.expectEqualStrings(l, e.line(i));
}

test "input" {
    var e = try Editor.init(std.testing.allocator, std.testing.io);
    defer e.deinit();
    try readChunks(&e, &.{ "ia\nb\x1b", "\x1b[A", "\x1bOP", "A\xc3", "\xa9\xf0\x9f", "\x98\x80\xffc\xe2x\x1b" });
    try expectLines(&e, &.{ "a", "bé😀cx" });
}

test "random splits of pasted text" {
    const gpa = std.testing.allocator;
    const chars = [_][]const u8{ "a", " ", "é", "€", "😀", "\n" };
    var prng: std.Random.DefaultPrng = .init(std.testing.random_seed);
    const r = prng.random();
    for (0..500) |_| {
        var paste: std.ArrayList(u8) = .empty;
        defer paste.deinit(gpa);
        try paste.append(gpa, 'i');
        for (0..r.uintAtMost(usize, 60)) |_| try paste.appendSlice(gpa, chars[r.uintLessThan(usize, chars.len)]);
        var chunks: std.ArrayList([]const u8) = .empty;
        defer chunks.deinit(gpa);
        var i: usize = 0;
        while (i < paste.items.len) {
            const n = @min(r.uintAtMost(usize, 5), paste.items.len - i);
            try chunks.append(gpa, paste.items[i..][0..n]);
            i += n;
        }

        var e = try Editor.init(gpa, std.testing.io);
        defer e.deinit();
        try readChunks(&e, chunks.items);
        var it = std.mem.splitScalar(u8, paste.items[1..], '\n');
        var n: usize = 0;
        while (it.next()) |l| : (n += 1) try std.testing.expectEqualStrings(l, e.line(n));
        try std.testing.expectEqual(n, e.lineCount());
    }
}
