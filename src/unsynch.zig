const std = @import("std");
const assert = std.debug.assert;
const io = std.io;

/// buf must be at least as long as in
pub fn decode(in: []const u8, buf: []u8) []u8 {
    assert(buf.len >= in.len);
    if (in.len == 0) {
        return buf[0..0];
    }
    var i: usize = 0;
    var buf_i: usize = 0;
    while (i < in.len - 1) : ({
        i += 1;
        buf_i += 1;
    }) {
        buf[buf_i] = in[i];

        // skip the \x00 when this pattern is found
        if (in[i] == '\xFF' and in[i + 1] == '\x00') {
            i += 1;
        }
    }
    if (i < in.len) {
        buf[buf_i] = in[i];
        buf_i += 1;
    }

    return buf[0..buf_i];
}

pub fn decodeInPlace(data: []u8) []u8 {
    return decode(data, data);
}

pub fn UnsynchCapableReader(comptime ReaderType: type) type {
    return struct {
        child_reader: ReaderType,
        unsynch: bool,

        pub const Error = ReaderType.Error;
        pub const Reader = io.Reader(*Self, Error, read);

        const Self = @This();

        pub fn read(self: *Self, dest: []u8) Error!usize {
            if (self.unsynch) {
                // this is sad
                // TODO: something better
                var num_read: usize = 0;
                var prev_byte: u8 = 0;
                while (num_read < dest.len) {
                    const byte = self.child_reader.readByte() catch |e| switch (e) {
                        error.EndOfStream => return num_read,
                        else => |err| return err,
                    };
                    const should_skip = byte == '\x00' and prev_byte == '\xFF';
                    if (!should_skip) {
                        dest[num_read] = byte;
                        num_read += 1;
                    }
                    // FF0000 should be decoded as FF00, so set prev_byte
                    // for each byte, even if it's skipped, so we don't
                    // decode FF0000 all the way to just FF
                    prev_byte = byte;
                }
                return num_read;
            } else {
                return self.child_reader.read(dest);
            }
        }

        pub fn reader(self: *Self) Reader {
            return .{ .context = self };
        }
    };
}

pub fn unsynchCapableReader(unsynch: bool, underlying_stream: anytype) UnsynchCapableReader(@TypeOf(underlying_stream)) {
    return .{ .child_reader = underlying_stream, .unsynch = unsynch };
}

test "unsynch decode zero length" {
    const encoded = "";
    var buf: [encoded.len]u8 = undefined;

    const decoded = decode(encoded, &buf);

    try std.testing.expectEqual(decoded.len, 0);
    try std.testing.expectEqualSlices(u8, "", decoded);
}

test "unsynch decode" {
    const encoded = "\xFF\x00\x00\xFE\xFF\x00";
    var buf: [encoded.len]u8 = undefined;

    const decoded = decode(encoded, &buf);

    try std.testing.expectEqual(decoded.len, 4);
    try std.testing.expectEqualSlices(u8, "\xFF\x00\xFE\xFF", decoded);
}

test "unsynch decode in place" {
    const encoded = "\xFF\x00\x00\xFE\xFF\x00";
    var buf: [encoded.len]u8 = encoded.*;

    const decoded = decodeInPlace(&buf);

    try std.testing.expectEqual(decoded.len, 4);
    try std.testing.expectEqualSlices(u8, "\xFF\x00\xFE\xFF", decoded);
}

test "unsynch reader" {
    const encoded = "\xFF\x00\x00\xFE\xFF\x00";
    var buf: [encoded.len]u8 = undefined;
    var stream = std.io.fixedBufferStream(encoded);
    var unsynch_reader = unsynchCapableReader(true, stream.reader());
    var reader = unsynch_reader.reader();

    const decoded_len = try reader.read(&buf);

    try std.testing.expectEqual(decoded_len, 4);
    try std.testing.expectEqualStrings("\xFF\x00\xFE\xFF", buf[0..decoded_len]);
}
