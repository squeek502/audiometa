const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

/// Caller must free returned memory.
pub fn latin1ToUtf8Alloc(allocator: *Allocator, latin1_text: []const u8) ![]u8 {
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

test "latin1 to utf8" {
    const utf8 = try latin1ToUtf8Alloc(std.testing.allocator, "a\xE0b\xE6c\xEFd");
    defer std.testing.allocator.free(utf8);

    try std.testing.expectEqualSlices(u8, "aàbæcïd", utf8);
}
