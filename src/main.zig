//! ze: a small modal text editor.
//!
//! Usage: `ze PATH`. The file need not exist; it is created when written.
//! `ze zen` prints the motto; `ze ./zen` edits a file named zen.

const std = @import("std");
const Editor = @import("Editor.zig");
const terminal = @import("terminal.zig");

/// Restores the terminal before reporting a panic.
pub const panic = std.debug.FullPanic(struct {
    fn call(msg: []const u8, first_trace_addr: ?usize) noreturn {
        terminal.restore();
        std.debug.defaultPanic(msg, first_trace_addr);
    }
}.call);

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2) fatal("usage: ze PATH", .{});
    const path = args[1];
    if (std.mem.eql(u8, path, "zen"))
        return std.Io.File.stdout().writeStreamingAll(init.io, "a vi-ish editor, that gets out of the way.\n");

    if (!try std.Io.File.stdin().isTty(init.io)) fatal("ze: standard input is not a terminal", .{});
    var editor = try Editor.init(init.gpa, init.io);
    defer editor.deinit();
    editor.open(path) catch |err| fatal("ze: {s}: {t}", .{ path, err });
    try terminal.run(&editor, init.io);
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print(fmt ++ "\n", args);
    std.process.exit(1);
}

test {
    _ = Editor;
    _ = @import("text.zig");
    _ = terminal;
    _ = @import("tests.zig");
}
