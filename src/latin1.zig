const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

/// Caller must free returned memory.
pub fn latin1ToUtf8Alloc(allocator: Allocator, latin1_text: []const u8) ![]u8 {
    var buffer = try std.ArrayList(u8).initCapacity(allocator, latin1_text.len);
    errdefer buffer.deinit();
    for (latin1_text) |c| switch (c) {
        0...127 => try buffer.append(c),
        else => {
            try buffer.append(0xC0 | (c >> 6));
            try buffer.append(0x80 | (c & 0x3f));
        },
    };
    return buffer.toOwnedSlice();
}

/// buf must be twice as big as latin1_text to ensure that it
/// can contain the converted string
pub fn latin1ToUtf8(latin1_text: []const u8, buf: []u8) []u8 {
    assert(buf.len >= latin1_text.len * 2);
    var i: usize = 0;
    for (latin1_text) |c| switch (c) {
        0...127 => {
            buf[i] = c;
            i += 1;
        },
        else => {
            buf[i] = 0xC0 | (c >> 6);
            buf[i + 1] = 0x80 | (c & 0x3f);
            i += 2;
        },
    };
    return buf[0..i];
}

/// Returns true if all codepoints in the UTF-8 string
/// are within the range of Latin-1 characters
pub fn isUtf8AllLatin1(utf8_text: []const u8) bool {
    var utf8_it = std.unicode.Utf8Iterator{
        .bytes = utf8_text,
        .i = 0,
    };
    while (utf8_it.nextCodepoint()) |codepoint| switch (codepoint) {
        0x00...0xFF => {},
        else => return false,
    };
    return true;
}

test "latin1 to utf8" {
    var buf: [512]u8 = undefined;
    const utf8 = latin1ToUtf8("a\xE0b\xE6c\xEFd", &buf);

    try std.testing.expectEqualSlices(u8, "aàbæcïd", utf8);
}

test "latin1 to utf8 alloc" {
    const utf8 = try latin1ToUtf8Alloc(std.testing.allocator, "a\xE0b\xE6c\xEFd");
    defer std.testing.allocator.free(utf8);

    try std.testing.expectEqualSlices(u8, "aàbæcïd", utf8);
}

test "is utf8 all latin1" {
    var buf: [512]u8 = undefined;
    const utf8 = latin1ToUtf8("abc\x01\x7F\x80\xFF", &buf);

    try std.testing.expect(isUtf8AllLatin1(utf8));
    try std.testing.expect(isUtf8AllLatin1("aàbæcïd"));
    try std.testing.expect(!isUtf8AllLatin1("Д"));
}
