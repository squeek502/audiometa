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

pub fn utf8ToLatin1Alloc(allocator: Allocator, utf8_text: []const u8) ![]u8 {
    assert(isUtf8AllLatin1(utf8_text));

    var buffer = try std.ArrayList(u8).initCapacity(allocator, utf8_text.len);
    errdefer buffer.deinit();

    var utf8_it = std.unicode.Utf8Iterator{ .bytes = utf8_text, .i = 0 };
    while (utf8_it.nextCodepoint()) |codepoint| {
        // this cast is guaranteed to work since we know the UTF-8 is made up
        // of all Latin-1 characters
        try buffer.append(@intCast(codepoint));
    }

    return buffer.toOwnedSlice();
}

/// buf must be at least 1/2 the size of utf8_text
pub fn utf8ToLatin1(utf8_text: []const u8, buf: []u8) []u8 {
    assert(isUtf8AllLatin1(utf8_text));
    assert(buf.len >= utf8_text.len / 2);

    var i: usize = 0;
    var utf8_it = std.unicode.Utf8Iterator{ .bytes = utf8_text, .i = 0 };
    while (utf8_it.nextCodepoint()) |codepoint| {
        // this cast is guaranteed to work since we know the UTF-8 is made up
        // of all Latin-1 characters
        buf[i] = @intCast(codepoint);
        i += 1;
    }

    return buf[0..i];
}

test "latin1 to utf8 and back" {
    var utf8_buf: [512]u8 = undefined;
    var latin1_buf: [512]u8 = undefined;

    const latin1 = "a\xE0b\xE6c\xEFd";
    const utf8 = latin1ToUtf8(latin1, &utf8_buf);
    try std.testing.expectEqualSlices(u8, "aàbæcïd", utf8);

    const latin1_converted = utf8ToLatin1(utf8, &latin1_buf);
    try std.testing.expectEqualSlices(u8, latin1, latin1_converted);
}

test "latin1 to utf8 alloc and back" {
    const latin1 = "a\xE0b\xE6c\xEFd";
    const utf8 = try latin1ToUtf8Alloc(std.testing.allocator, latin1);
    defer std.testing.allocator.free(utf8);

    try std.testing.expectEqualSlices(u8, "aàbæcïd", utf8);

    const latin1_converted = try utf8ToLatin1Alloc(std.testing.allocator, utf8);
    defer std.testing.allocator.free(latin1_converted);

    try std.testing.expectEqualSlices(u8, latin1, latin1_converted);
}

test "is utf8 all latin1" {
    var buf: [512]u8 = undefined;
    const utf8 = latin1ToUtf8("abc\x01\x7F\x80\xFF", &buf);

    try std.testing.expect(isUtf8AllLatin1(utf8));
    try std.testing.expect(isUtf8AllLatin1("aàbæcïd"));
    try std.testing.expect(!isUtf8AllLatin1("Д"));
}
