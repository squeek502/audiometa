const std = @import("std");
const io = std.io;
const testing = std.testing;

// This matches std.io.bufferedReader's buffer size
pub const default_buffer_size = 4096;
pub const DefaultBufferedStreamSource = BufferedStreamSource(default_buffer_size);

/// A reader-only version of std.io.StreamSource that provides a seekable
/// std.io.BufferedReader for files.
/// Necessary because normally if a buffered reader is seeked, then the buffer
/// will give incorrect data on the next read.
pub fn BufferedStreamSource(comptime buffer_size: usize) type {
    return struct {
        stream_source: *io.StreamSource,
        buffered_reader: ?BufferedReaderType,

        const BufferedReaderType = io.BufferedReader(buffer_size, io.StreamSource.Reader);
        const Self = @This();

        pub fn init(stream_source: *io.StreamSource) Self {
            return Self{
                .stream_source = stream_source,
                .buffered_reader = switch (stream_source.*) {
                    .buffer, .const_buffer => null,
                    .file => BufferedReaderType{ .unbuffered_reader = stream_source.reader() },
                },
            };
        }

        pub const ReadError = io.StreamSource.ReadError;
        pub const SeekError = io.StreamSource.SeekError;
        pub const GetSeekPosError = io.StreamSource.GetSeekPosError;

        pub const Reader = io.Reader(*Self, ReadError, read);
        pub const SeekableStream = io.SeekableStream(*Self, SeekError, GetSeekPosError, seekTo, seekBy, getPos, getEndPos);

        pub fn read(self: *Self, dest: []u8) ReadError!usize {
            if (self.buffered_reader) |*buffered_reader| {
                return buffered_reader.read(dest);
            } else {
                return self.stream_source.read(dest);
            }
        }

        pub fn seekTo(self: *Self, pos: u64) SeekError!void {
            if (self.stream_source.seekTo(pos)) {
                if (self.buffered_reader) |*buffered_reader| {
                    // just discard the buffer completely
                    buffered_reader.start = buffered_reader.end;
                }
            } else |err| {
                return err;
            }
        }

        pub fn seekBy(self: *Self, amt: i64) SeekError!void {
            if (self.buffered_reader) |*buffered_reader| {
                const amount_buffered = buffered_reader.end - buffered_reader.start;
                // If we can just skip ahead in the buffer, then do that instead of
                // actually seeking
                if (amt > 0 and amt <= amount_buffered) {
                    buffered_reader.start += @intCast(amt);
                }
                // Otherwise, we need to seek (adjusted by the amount buffered)
                // and then discard the buffer if the seek succeeds
                else if (amt != 0) {
                    if (self.stream_source.seekBy(amt - @as(i64, @intCast(amount_buffered)))) {
                        buffered_reader.start += amount_buffered;
                    } else |err| {
                        return err;
                    }
                }
            } else {
                return self.stream_source.seekBy(amt);
            }
        }

        pub fn getEndPos(self: *Self) GetSeekPosError!u64 {
            return self.stream_source.getEndPos();
        }

        pub fn getPos(self: *Self) GetSeekPosError!u64 {
            if (self.stream_source.getPos()) |pos| {
                // the 'real' pos is offset by the current buffer count
                if (self.buffered_reader) |*buffered_reader| {
                    return pos - (buffered_reader.end - buffered_reader.start);
                }
                return pos;
            } else |err| {
                return err;
            }
        }

        pub fn reader(self: *Self) Reader {
            return .{ .context = self };
        }

        pub fn seekableStream(self: *Self) SeekableStream {
            return .{ .context = self };
        }
    };
}

pub fn bufferedStreamSource(stream_source: *io.StreamSource) DefaultBufferedStreamSource {
    return DefaultBufferedStreamSource.init(stream_source);
}

test "BufferedStreamSource with file" {
    const full_contents = "123456789" ** 2;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "testfile", .data = full_contents });

    var file = try tmp.dir.openFile("testfile", .{});
    defer file.close();

    var stream_source = std.io.StreamSource{ .file = file };
    // small buffer to test all seekBy branches
    var buffered_stream_source = BufferedStreamSource(4).init(&stream_source);

    const reader = buffered_stream_source.reader();
    const seekable_stream = buffered_stream_source.seekableStream();

    const first_few_bytes = try reader.readBytesNoEof(3);
    try testing.expectEqual(@as(u64, 3), try seekable_stream.getPos());

    try seekable_stream.seekTo(0);
    try testing.expectEqual(@as(u64, 0), try seekable_stream.getPos());

    const first_few_bytes_again = try reader.readBytesNoEof(3);
    try testing.expectEqual(@as(u64, 3), try seekable_stream.getPos());

    try testing.expectEqualSlices(u8, first_few_bytes[0..], first_few_bytes_again[0..]);

    try seekable_stream.seekBy(-3);
    try testing.expectEqual(@as(u64, 0), try seekable_stream.getPos());

    const first_few_bytes_yet_again = try reader.readBytesNoEof(3);
    try testing.expectEqual(@as(u64, 3), try seekable_stream.getPos());

    try testing.expectEqualSlices(u8, first_few_bytes[0..], first_few_bytes_yet_again[0..]);

    try seekable_stream.seekBy(1);
    try testing.expectEqual(@as(u64, 4), try seekable_stream.getPos());

    try seekable_stream.seekBy(4);
    try testing.expectEqual(@as(u64, 8), try seekable_stream.getPos());

    const four_bytes = try reader.readBytesNoEof(4);
    try testing.expectEqual(@as(u64, 12), try seekable_stream.getPos());

    try testing.expectEqualSlices(u8, full_contents[8..12], four_bytes[0..]);
}
