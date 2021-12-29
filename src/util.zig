const std = @import("std");

pub const Case = enum { lower, upper };

fn isUtf8ControlCode(c: []const u8) bool {
    return c.len == 2 and c[0] == '\xC2' and c[1] >= '\x80' and c[1] <= '\x9F';
}

// copied from std/fmt.zig but works so that UTF8 still gets printed as a string
// Useful for avoiding things like printing the Operating System Command (0x9D) control character
// which can really break terminal printing
fn formatUtf8SliceEscapeImpl(comptime case: Case) type {
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

            var it = std.unicode.Utf8Iterator{ .bytes = bytes, .i = 0 };
            while (it.nextCodepointSlice()) |c| {
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

const formatUtf8SliceEscapeLower = formatUtf8SliceEscapeImpl(.lower).f;
const formatUtf8SliceEscapeUpper = formatUtf8SliceEscapeImpl(.upper).f;

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

/// Reader that panics if the size to read is greater than the given max size
pub fn MaxSizeReader(comptime ReaderType: type) type {
    return struct {
        child_reader: ReaderType,
        max_size: usize,

        pub const Error = ReaderType.Error;
        pub const Reader = std.io.Reader(*Self, Error, read);

        const Self = @This();

        pub fn read(self: *Self, dest: []u8) Error!usize {
            if (dest.len > self.max_size) {
                std.debug.print("tried to read size {} which is greater than max size {}\n", .{ dest.len, self.max_size });
                @panic("Read size greater than max size");
            }
            return self.child_reader.read(dest);
        }

        pub fn reader(self: *Self) Reader {
            return .{ .context = self };
        }
    };
}

pub fn maxSizeReader(max_size: usize, underlying_stream: anytype) MaxSizeReader(@TypeOf(underlying_stream)) {
    return .{ .child_reader = underlying_stream, .max_size = max_size };
}
