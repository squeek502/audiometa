const std = @import("std");
const print = std.debug.print;

pub const Case = enum { lower, upper };

fn isUtf8ControlCode(c: []const u8) bool {
    return c.len == 2 and c[0] == '\xC2' and c[1] >= '\x80' and c[1] <= '\x9F';
}

/// Like std.unicode.Utf8Iterator, but handles invalid UTF-8 without panicing
pub const InvalidUtf8Iterator = struct {
    bytes: []const u8,
    i: usize,

    /// On invalid UTF-8, returns an error
    pub fn nextCodepointSlice(it: *InvalidUtf8Iterator) !?[]const u8 {
        if (it.i >= it.bytes.len) {
            return null;
        }

        const cp_len = try std.unicode.utf8ByteSequenceLength(it.bytes[it.i]);
        it.i += cp_len;
        return it.bytes[it.i - cp_len .. it.i];
    }
};

/// Copied from std/fmt.zig but works so that UTF8 still gets printed as a string
/// Useful for avoiding things like printing the Operating System Command (0x9D) control character
/// which can really break terminal printing
/// Also allows invalid UTF-8 to be printed (the invalid bytes will likely be escaped).
fn FormatUtf8SliceEscape(comptime case: Case) type {
    const charset = "0123456789" ++ if (case == .upper) "ABCDEF" else "abcdef";

    return struct {
        pub fn f(
            bytes: []const u8,
            comptime fmt: []const u8,
            options: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            _ = fmt;
            _ = options;
            var buf: [4]u8 = undefined;

            buf[0] = '\\';
            buf[1] = 'x';

            var it = InvalidUtf8Iterator{ .bytes = bytes, .i = 0 };
            while (it.nextCodepointSlice() catch c: {
                // On invalid UTF-8, treat the first byte as the 'codepoint slice'
                // and then move past that char.
                // This should always write an escaped character within the loop.
                it.i += 1;
                break :c it.bytes[it.i - 1 .. it.i];
            }) |c| {
                if (c.len == 1) {
                    if (std.ascii.isPrint(c[0])) {
                        try writer.writeByte(c[0]);
                    } else {
                        buf[2] = charset[c[0] >> 4];
                        buf[3] = charset[c[0] & 15];
                        try writer.writeAll(&buf);
                    }
                } else {
                    if (!isUtf8ControlCode(c)) {
                        try writer.writeAll(c);
                    } else {
                        buf[2] = charset[c[1] >> 4];
                        buf[3] = charset[c[1] & 15];
                        try writer.writeAll(&buf);
                    }
                }
            }
        }
    };
}

const formatUtf8SliceEscapeLower = FormatUtf8SliceEscape(.lower).f;
const formatUtf8SliceEscapeUpper = FormatUtf8SliceEscape(.upper).f;

/// Return a Formatter for a []const u8 where every C0 and C1 control
/// character is escaped as \xNN, where NN is the character in lowercase
/// hexadecimal notation.
pub fn fmtUtf8SliceEscapeLower(bytes: []const u8) std.fmt.Formatter(formatUtf8SliceEscapeLower) {
    return .{ .data = bytes };
}

/// Return a Formatter for a []const u8 where every C0 and C1 control
/// character is escaped as \xNN, where NN is the character in uppercase
/// hexadecimal notation.
pub fn fmtUtf8SliceEscapeUpper(bytes: []const u8) std.fmt.Formatter(formatUtf8SliceEscapeUpper) {
    return .{ .data = bytes };
}
