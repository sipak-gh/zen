//! Characters and screen columns within a line of bytes.
//!
//! Text is stored as raw bytes and is not validated. A character is a byte
//! that is not a UTF-8 continuation byte, together with the continuation
//! bytes that follow it. Each character occupies one screen column, except
//! a tab, which advances to the next multiple of `tab_width`.

const std = @import("std");

pub const tab_width = 4;

fn isContinuation(byte: u8) bool {
    return byte & 0xc0 == 0x80;
}

/// The offset of the character after the one at `i`; `i < s.len`.
pub fn next(s: []const u8, i: usize) usize {
    var j = i + 1;
    while (j < s.len and isContinuation(s[j])) j += 1;
    return j;
}

/// The offset of the character before offset `i`; `i > 0`.
pub fn prev(s: []const u8, i: usize) usize {
    var j = i - 1;
    while (j > 0 and isContinuation(s[j])) j -= 1;
    return j;
}

/// The screen column following a character beginning with `byte` at `col`.
pub fn advance(col: usize, byte: u8) usize {
    return if (byte == '\t') col - col % tab_width + tab_width else col + 1;
}

/// The screen column of offset `i`.
pub fn column(s: []const u8, i: usize) usize {
    var col: usize = 0;
    var j: usize = 0;
    while (j < i) : (j = next(s, j)) col = advance(col, s[j]);
    return col;
}

/// The offset of the character covering screen column `col`, or `s.len` if
/// the line is shorter.
pub fn offset(s: []const u8, col: usize) usize {
    var c: usize = 0;
    var j: usize = 0;
    while (j < s.len) : (j = next(s, j)) {
        c = advance(c, s[j]);
        if (c > col) return j;
    }
    return s.len;
}

test "characters" {
    const s = "aé\tb";
    try std.testing.expectEqual(1, next(s, 0));
    try std.testing.expectEqual(3, next(s, 1));
    try std.testing.expectEqual(1, prev(s, 3));
    try std.testing.expectEqual(4, column(s, 4));
    try std.testing.expectEqual(5, column(s, s.len));
    try std.testing.expectEqual(3, offset(s, 2));
    try std.testing.expectEqual(3, offset(s, 3));
    try std.testing.expectEqual(4, offset(s, 4));
    try std.testing.expectEqual(s.len, offset(s, 9));
}
