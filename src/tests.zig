//! Tests of reading, editing and writing files through the editor's public
//! interface: files are made in a temporary directory, edited with keys and
//! read back.
//!
//! The expected contents of a written file are given by `expected` and
//! `normalized` below, independently of the editor.

const std = @import("std");
const testing = std.testing;
const linux = std.os.linux;
const posix = std.posix;
const Editor = @import("Editor.zig");
const text = @import("text.zig");

const io = testing.io;
const gpa = testing.allocator;

/// A temporary directory.
const Tmp = struct {
    tmp: testing.TmpDir,
    arena: std.heap.ArenaAllocator,

    fn init() Tmp {
        return .{ .tmp = testing.tmpDir(.{}), .arena = .init(gpa) };
    }

    fn deinit(t: *Tmp) void {
        t.arena.deinit();
        t.tmp.cleanup();
    }

    /// The path of `name` from the working directory.
    fn path(t: *Tmp, name: []const u8) []const u8 {
        return std.fmt.allocPrint(t.arena.allocator(), ".zig-cache/tmp/{s}/{s}", .{ &t.tmp.sub_path, name }) catch
            @panic("out of memory");
    }

    fn put(t: *Tmp, name: []const u8, data: []const u8) !void {
        try t.tmp.dir.writeFile(io, .{ .sub_path = name, .data = data });
    }

    fn get(t: *Tmp, name: []const u8) ![]u8 {
        return t.tmp.dir.readFileAlloc(io, name, t.arena.allocator(), .unlimited);
    }

    fn exists(t: *Tmp, name: []const u8) bool {
        t.tmp.dir.access(io, name, .{}) catch return false;
        return true;
    }

    fn mode(t: *Tmp, name: []const u8) !posix.mode_t {
        return (try t.tmp.dir.statFile(io, name, .{})).permissions.toMode() & 0o7777;
    }

    fn chmod(t: *Tmp, name: []const u8, m: posix.mode_t) !void {
        try t.tmp.dir.setFilePermissions(io, name, .fromMode(m), .{});
    }
};

/// Sends the characters of `keys` as keys.
fn typeKeys(e: *Editor, keys: []const u8) !void {
    var it = (try std.unicode.Utf8View.init(keys)).iterator();
    while (it.nextCodepoint()) |k| try e.handleKey(k);
}

/// The file written for the lines in the editor: each line followed by a
/// newline, except that a single empty line is an empty file.
fn expected(a: std.mem.Allocator, e: *const Editor) ![]const u8 {
    if (e.lineCount() == 1 and e.line(0).len == 0) return "";
    var out: std.ArrayList(u8) = .empty;
    for (0..e.lineCount()) |i| {
        try out.appendSlice(a, e.line(i));
        try out.append(a, '\n');
    }
    return out.items;
}

/// The file written for `data` read unedited: a missing final newline is
/// added, and a file holding only a newline becomes empty.
fn normalized(a: std.mem.Allocator, data: []const u8) ![]const u8 {
    if (std.mem.eql(u8, data, "\n")) return "";
    if (data.len == 0 or data[data.len - 1] == '\n') return data;
    return std.mem.concat(a, u8, &.{ data, "\n" });
}

/// Copies the lines in the editor.
fn lines(a: std.mem.Allocator, e: *const Editor) ![]const []const u8 {
    const out = try a.alloc([]const u8, e.lineCount());
    for (out, 0..) |*l, i| l.* = try a.dupe(u8, e.line(i));
    return out;
}

fn expectLines(want: []const []const u8, e: *const Editor) !void {
    try testing.expectEqual(want.len, e.lineCount());
    for (want, 0..) |l, i| try testing.expectEqualStrings(l, e.line(i));
}

fn expectFile(t: *Tmp, name: []const u8, want: []const u8) !void {
    try testing.expectEqualStrings(want, try t.get(name));
}

/// Writes the editor's file and checks that it succeeded and that the file
/// holds the editor's lines.
fn writeAndCheck(t: *Tmp, e: *Editor, name: []const u8) !void {
    try typeKeys(e, ":w\r");
    if (e.message_is_error) std.debug.print("{s}\n", .{e.message.items});
    try testing.expect(!e.message_is_error);
    try testing.expect(!e.isModified());
    try expectFile(t, name, try expected(t.arena.allocator(), e));
    try testing.expect(!t.exists(try std.mem.concat(t.arena.allocator(), u8, &.{ name, "~" })));
}

/// Opens `data` as a file, writes it unedited, and checks the result.
fn roundTrip(t: *Tmp, data: []const u8) !void {
    try t.put("f", data);
    var e = try Editor.init(gpa, io);
    defer e.deinit();
    try e.open(t.path("f"));
    try testing.expect(!e.message_is_error);
    try writeAndCheck(t, &e, "f");
    try expectFile(t, "f", try normalized(t.arena.allocator(), data));
}

test "unedited files are written back unchanged" {
    var t: Tmp = .init();
    defer t.deinit();
    const cases = [_][]const u8{
        "",                   "\n",      "\n\n",     "a",
        "a\n",                "a\n\n\n", "\n\na",    " \t \n\t",
        "a\r\nb\r\n",         "a\r",     "\r\n\r\n", "\x00\x01\x1b\x7f\n",
        "\xff\xfe\x80\xc3\n",
        "é€😀\n",
        "\xe2\x82",           "a\n\xe2", "~\n",      "line\nno newline",
    };
    for (cases) |c| try roundTrip(&t, c);

    const a = t.arena.allocator();
    const long = try a.alloc(u8, 1 << 20);
    @memset(long, 'x');
    try roundTrip(&t, long);
    var many: std.ArrayList(u8) = .empty;
    for (0..100_000) |i| try many.print(a, "{d}\n", .{i});
    try roundTrip(&t, many.items);

    // Sizes about the 64 KiB buffers used to copy and write files.
    var prng: std.Random.DefaultPrng = .init(testing.random_seed);
    for (buffer_sizes) |n| try roundTrip(&t, try randomBytes(a, prng.random(), n));
}

const buffer_sizes = [_]usize{ 65535, 65536, 65537, 131072, 300_001 };

/// Bytes for random files: more of those that need care.
const file_bytes = "ab \t\n\n\r\x00\xc3\xa9\xe2\x82\xac\xff\x80";

fn randomFile(a: std.mem.Allocator, r: std.Random, max: usize) ![]u8 {
    return randomBytes(a, r, r.uintAtMost(usize, max));
}

fn randomBytes(a: std.mem.Allocator, r: std.Random, n: usize) ![]u8 {
    const out = try a.alloc(u8, n);
    for (out) |*b| b.* = file_bytes[r.uintLessThan(usize, file_bytes.len)];
    return out;
}

test "random files are written back unchanged" {
    var t: Tmp = .init();
    defer t.deinit();
    var prng: std.Random.DefaultPrng = .init(testing.random_seed);
    for (0..300) |_| try roundTrip(&t, try randomFile(t.arena.allocator(), prng.random(), 200));
}

test "edits keep the bytes they do not touch" {
    var t: Tmp = .init();
    defer t.deinit();
    const original = "one\r\n\ttwo\x00x\n\xff\xfe three\n\xe2\x82\nlast";
    try t.put("f", original);
    var e = try Editor.init(gpa, io);
    defer e.deinit();
    try e.open(t.path("f"));

    const steps = [_]struct { []const u8, []const u8 }{
        .{ "jx", "one\r\ntwo\x00x\n\xff\xfe three\n\xe2\x82\nlast\n" },
        .{ "jdd", "one\r\ntwo\x00x\n\xe2\x82\nlast\n" },
        .{ "x", "one\r\ntwo\x00x\n\nlast\n" },
        .{ "ggA!\x1b", "one\r!\ntwo\x00x\n\nlast\n" },
        .{ "Gyyggp", "one\r!\nlast\ntwo\x00x\n\nlast\n" },
        .{ "jlrZ", "one\r!\nlast\ntZo\x00x\n\nlast\n" },
        .{ "uuuuuu", original ++ "\n" },
        .{ "UUUUUU", "one\r!\nlast\ntZo\x00x\n\nlast\n" },
    };
    for (steps) |step| {
        try typeKeys(&e, step[0]);
        try writeAndCheck(&t, &e, "f");
        try expectFile(&t, "f", step[1]);
    }
}

/// Keys for random editing: every normal-mode key but `:`, and keys for
/// insert mode and the search prompt.
const edit_keys = "hjkl\x04\x15wbe0^$gG/nuUiaIAoOxdypPr\x1b\x1b\r\x7f\t éa";

/// The lines in the editor joined by newlines.
fn joined(a: std.mem.Allocator, e: *const Editor) ![]const u8 {
    return std.mem.join(a, "\n", try lines(a, e));
}

/// `s` with `s[i..j]` replaced by `new`.
fn splice(a: std.mem.Allocator, s: []const u8, i: usize, j: usize, new: []const u8) ![]const u8 {
    return std.mem.concat(a, u8, &.{ s[0..i], new, s[j..] });
}

/// Types `key` and checks that the text changes exactly as the key
/// specifies, given the text and cursor before: motions, yanks and prompts
/// change nothing, and each other key replaces one span at the cursor.
/// Undo and redo are checked by `checkEdits`.
fn checkKey(a: std.mem.Allocator, e: *Editor, key: u21) !void {
    const before = try joined(a, e);
    const l = e.cursor.line;
    var start: usize = 0; // of the cursor line
    for (0..l) |i| start += e.line(i).len + 1;
    const end = start + e.line(l).len;
    const c = start + e.cursor.col;
    const char_end = if (c < end) text.next(before[0..end], c) else c;
    const mode = e.mode;
    const replacing = e.replacing;
    const lines_before = e.lineCount();
    var typed: std.ArrayList(u8) = .empty;
    try typed.appendSlice(a, e.pending[0..e.pending_len]);
    if (key <= 0x7f) try typed.append(a, @intCast(key));
    var buf: [4]u8 = undefined;
    const char = buf[0..try std.unicode.utf8Encode(key, &buf)];
    const printable = key >= 0x20 and key != 0x7f;

    try e.handleKey(key);
    const after = try joined(a, e);
    const reg = e.register.items;
    const want = switch (mode) {
        .command, .search => before,
        .insert => switch (key) {
            Editor.enter => try splice(a, before, c, c, "\n"),
            Editor.tab => try splice(a, before, c, c, "    "),
            Editor.backspace => if (c == 0) before else try splice(a, before, if (c == start) c - 1 else text.prev(before[start..], c - start) + start, c, ""),
            else => if (printable) try splice(a, before, c, c, char) else before,
        },
        .normal => want: {
            if (replacing) break :want if (c < end and printable) try splice(a, before, c, char_end, char) else before;
            const is = struct {
                fn f(t: []const u8, k: []const u8) bool {
                    return std.mem.eql(u8, t, k);
                }
            }.f;
            const t = typed.items;
            if (is(t, "x")) {
                if (c == end) break :want before;
                try testing.expectEqualStrings(before[c..char_end], reg);
                break :want try splice(a, before, c, char_end, "");
            }
            if (is(t, "dw")) {
                if (std.mem.eql(u8, before, after)) break :want before;
                try testing.expect(c + reg.len <= end);
                try testing.expectEqualStrings(before[c..][0..reg.len], reg);
                break :want try splice(a, before, c, c + reg.len, "");
            }
            if (is(t, "dd")) {
                try testing.expect(e.linewise);
                try testing.expectEqualStrings(before[start..end], reg);
                if (lines_before == 1) break :want "";
                if (l + 1 == lines_before) break :want try splice(a, before, start - 1, end, "");
                break :want try splice(a, before, start, end + 1, "");
            }
            if (is(t, "o")) break :want try splice(a, before, end, end, "\n");
            if (is(t, "O")) break :want try splice(a, before, start, start, "\n");
            if ((is(t, "p") or is(t, "P")) and e.has_register) {
                const after_cursor = is(t, "p");
                if (e.linewise) break :want if (after_cursor)
                    try std.mem.concat(a, u8, &.{ before[0..end], "\n", reg, before[end..] })
                else
                    try std.mem.concat(a, u8, &.{ before[0..start], reg, "\n", before[start..] });
                const at = if (after_cursor) char_end else c;
                break :want try splice(a, before, at, at, reg);
            }
            if (is(t, "u") or is(t, "U")) break :want after;
            break :want before;
        },
    };
    try testing.expectEqualStrings(want, after);
}

/// Edits `data` with keys chosen by `choices`, checking each with
/// `checkKey`, redoing any changes undone, and checks that writing gives
/// the editor's lines, that undoing every change and writing gives the
/// original file, that redoing every change gives the edited lines again,
/// and that reading the written file gives them too.
fn checkEdits(t: *Tmp, data: []const u8, choices: []const u8) !void {
    const a = t.arena.allocator();
    try t.put("f", data);
    var e = try Editor.init(gpa, io);
    defer e.deinit();
    try e.open(t.path("f"));

    for (choices[0..@min(choices.len, 100)]) |c| try checkKey(a, &e, edit_keys[c % edit_keys.len]);
    try typeKeys(&e, "\x1b\x1b");
    while (!e.message_is_error) try typeKeys(&e, "U"); // redo what random keys undid
    const edited = try lines(a, &e);
    try writeAndCheck(t, &e, "f");

    for (0..101) |_| {
        try typeKeys(&e, "u");
        if (e.message_is_error) break;
    } else return error.TooManyChanges;
    try writeAndCheck(t, &e, "f");
    try expectFile(t, "f", try normalized(a, data));

    while (!e.message_is_error) try typeKeys(&e, "U");
    try expectLines(edited, &e);
    try writeAndCheck(t, &e, "f");
    try typeKeys(&e, ":e!\r");
    try expectLines(edited, &e);
}

test "random edits are written exactly" {
    var t: Tmp = .init();
    defer t.deinit();
    var prng: std.Random.DefaultPrng = .init(testing.random_seed);
    const r = prng.random();
    var choices: [100]u8 = undefined;
    for (0..300) |_| {
        r.bytes(&choices);
        try checkEdits(&t, try randomFile(t.arena.allocator(), r, 100), &choices);
    }
}

test "fuzz edits" {
    try testing.fuzz({}, struct {
        fn testOne(_: void, smith: *testing.Smith) !void {
            var t: Tmp = .init();
            defer t.deinit();
            var data: [100]u8 = undefined;
            var choices: [100]u8 = undefined;
            const file = data[0..smith.slice(&data)];
            for (file) |*b| b.* = file_bytes[b.* % file_bytes.len];
            try checkEdits(&t, file, choices[0..smith.slice(&choices)]);
        }
    }.testOne, .{});
}

test "writing keeps symbolic links, hard links and permissions" {
    var t: Tmp = .init();
    defer t.deinit();
    try t.put("f", "old\n");
    try t.chmod("f", 0o640);
    try t.tmp.dir.symLink(io, "f", "link", .{});
    try t.tmp.dir.hardLink("f", t.tmp.dir, "hard", io, .{});

    var e = try Editor.init(gpa, io);
    defer e.deinit();
    try e.open(t.path("link"));
    try typeKeys(&e, "inew \x1b");
    try writeAndCheck(&t, &e, "link");
    try expectFile(&t, "f", "new old\n");
    try expectFile(&t, "hard", "new old\n");
    try testing.expectEqual(0o640, try t.mode("f"));
    var buf: [16]u8 = undefined;
    try testing.expectEqualStrings("f", buf[0..try t.tmp.dir.readLink(io, "link", &buf)]);
}

test "an existing backup is never replaced" {
    var t: Tmp = .init();
    defer t.deinit();
    try t.put("f", "old\n");
    try t.put("g", "victim\n");
    var e = try Editor.init(gpa, io);
    defer e.deinit();
    try e.open(t.path("f"));
    try typeKeys(&e, "x");

    try t.put("f~", "mine\n");
    try typeKeys(&e, ":w\r");
    try testing.expect(e.message_is_error);
    try testing.expect(e.isModified());
    try expectFile(&t, "f", "old\n");
    try expectFile(&t, "f~", "mine\n");

    try t.tmp.dir.deleteFile(io, "f~");
    try t.tmp.dir.symLink(io, "g", "f~", .{});
    try typeKeys(&e, ":w\r");
    try testing.expect(e.message_is_error);
    try expectFile(&t, "f", "old\n");
    try expectFile(&t, "g", "victim\n");

    try t.tmp.dir.deleteFile(io, "f~");
    try writeAndCheck(&t, &e, "f");
    try expectFile(&t, "f", "ld\n");
    try expectFile(&t, "g", "victim\n");
}

/// Limits the size of files the process may write, as a full disk would.
fn limitFileSize(n: u64) !posix.rlimit {
    const old = try posix.getrlimit(.FSIZE);
    try posix.setrlimit(.FSIZE, .{ .cur = n, .max = old.max });
    // Writing past the limit would otherwise raise SIGXFSZ, killing the process.
    posix.sigaction(.XFSZ, &.{ .handler = .{ .handler = posix.SIG.IGN }, .mask = posix.sigemptyset(), .flags = 0 }, null);
    return old;
}

const inserted: [200]u8 = @splat('x');

test "a failed write keeps the original in the backup" {
    var prng: std.Random.DefaultPrng = .init(testing.random_seed);
    for ([_]usize{3001} ++ buffer_sizes) |n| {
        var t: Tmp = .init();
        defer t.deinit();
        const a = t.arena.allocator();
        const original = try randomBytes(a, prng.random(), n);
        try t.put("f", original);
        try t.chmod("f", 0o600);
        var e = try Editor.init(gpa, io);
        defer e.deinit();
        try e.open(t.path("f"));
        try typeKeys(&e, "i" ++ inserted ++ "\x1b");

        {
            const old = try limitFileSize(n + 100);
            defer posix.setrlimit(.FSIZE, old) catch {};
            try typeKeys(&e, ":w\r");
            try testing.expect(e.message_is_error);
            try testing.expect(std.mem.indexOf(u8, e.message.items, "FileTooBig; original in") != null);
            try testing.expect(e.isModified());
            try expectFile(&t, "f~", original);
            try testing.expectEqual(0o600, try t.mode("f~"));
            try testing.expectEqual(n + 100, (try t.get("f")).len);
            try typeKeys(&e, ":q\r:x\r");
            try testing.expect(!e.quit_requested);

            // Writing again must not back up the incomplete file.
            try typeKeys(&e, ":w\r");
            try testing.expect(e.message_is_error);
            try expectFile(&t, "f~", original);
        }
        try writeAndCheck(&t, &e, "f");
        try expectFile(&t, "f", try std.mem.concat(a, u8, &.{ &inserted, try normalized(a, original) }));
        try testing.expectEqual(0o600, try t.mode("f"));
    }
}

test "a failed backup is removed and the file left unchanged" {
    var t: Tmp = .init();
    defer t.deinit();
    var prng: std.Random.DefaultPrng = .init(testing.random_seed);
    const original = try randomBytes(t.arena.allocator(), prng.random(), 200_000);
    try t.put("f", original);
    var e = try Editor.init(gpa, io);
    defer e.deinit();
    try e.open(t.path("f"));
    try typeKeys(&e, "ix\x1b");
    {
        const old = try limitFileSize(100_000);
        defer posix.setrlimit(.FSIZE, old) catch {};
        try typeKeys(&e, ":w\r");
    }
    try testing.expect(std.mem.indexOf(u8, e.message.items, "backup failed: FileTooBig") != null);
    try testing.expect(e.isModified());
    try expectFile(&t, "f", original);
    try testing.expect(!t.exists("f~"));
    try writeAndCheck(&t, &e, "f");
}

test "a file that cannot be written is left unchanged" {
    if (linux.geteuid() == 0) return error.SkipZigTest;
    var t: Tmp = .init();
    defer t.deinit();
    try t.put("f", "old\n");
    try t.chmod("f", 0o444);
    var e = try Editor.init(gpa, io);
    defer e.deinit();
    try e.open(t.path("f"));
    try typeKeys(&e, "x:wq\r");
    try testing.expect(e.message_is_error);
    try testing.expect(!e.quit_requested);
    try testing.expect(e.isModified());
    try expectFile(&t, "f", "old\n");
    try testing.expect(!t.exists("f~"));
}

test "a file in a directory that cannot be written is left unchanged" {
    if (linux.geteuid() == 0) return error.SkipZigTest;
    var t: Tmp = .init();
    defer t.deinit();
    try t.tmp.dir.createDir(io, "d", .default_dir);
    try t.put("d/f", "old\n");
    try t.chmod("d", 0o555);
    defer t.chmod("d", 0o755) catch {};
    var e = try Editor.init(gpa, io);
    defer e.deinit();
    try e.open(t.path("d/f"));
    try typeKeys(&e, "x:w\r");
    try testing.expect(e.message_is_error);
    try testing.expect(std.mem.indexOf(u8, e.message.items, "backup failed") != null);
    try expectFile(&t, "d/f", "old\n");
    try testing.expect(!t.exists("d/f~"));
}

test "a file is created only when written" {
    var t: Tmp = .init();
    defer t.deinit();
    var e = try Editor.init(gpa, io);
    defer e.deinit();
    try e.open(t.path("new"));
    try testing.expect(std.mem.endsWith(u8, e.message.items, "/new\" new file"));
    try typeKeys(&e, ":x\r");
    try testing.expect(e.quit_requested);
    try testing.expect(!t.exists("new"));
    try typeKeys(&e, ":w\r");
    try expectFile(&t, "new", "");

    try e.open(t.path("other"));
    try typeKeys(&e, "ihi\x1b:x\r");
    try expectFile(&t, "other", "hi\n");
    try testing.expect(!t.exists("other~"));
}

test "a file in a missing directory is not written" {
    var t: Tmp = .init();
    defer t.deinit();
    var e = try Editor.init(gpa, io);
    defer e.deinit();
    try e.open(t.path("missing/f"));
    try typeKeys(&e, "ix\x1b:w\r");
    try testing.expect(e.message_is_error);
    try testing.expect(e.isModified());
}

test ":x writes only if modified" {
    var t: Tmp = .init();
    defer t.deinit();
    try t.put("f", "no newline");
    var e = try Editor.init(gpa, io);
    defer e.deinit();
    try e.open(t.path("f"));
    try typeKeys(&e, ":x\r");
    try testing.expect(e.quit_requested);
    try expectFile(&t, "f", "no newline");
}

test ":e! reads the file again" {
    var t: Tmp = .init();
    defer t.deinit();
    try t.put("f", "one\n");
    var e = try Editor.init(gpa, io);
    defer e.deinit();
    try e.open(t.path("f"));
    try typeKeys(&e, "x");
    try t.put("f", "two\nthree\n");
    try typeKeys(&e, ":e\r");
    try testing.expect(e.message_is_error);
    try expectLines(&.{"ne"}, &e);
    try typeKeys(&e, ":e!\r");
    try expectLines(&.{ "two", "three" }, &e);
    try testing.expect(!e.isModified());
}
