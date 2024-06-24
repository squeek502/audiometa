const std = @import("std");
const io = std.io;
const testing = std.testing;

/// Wrapper over a Reader/SeekableStream pair that returns an error if
/// we ever try reading/seeking past the end of the constrained end position
pub fn ConstrainedStream(comptime ReaderType: type, comptime SeekableStreamType: type) type {
    return struct {
        underlying_reader: ReaderType,
        underlying_seekable_stream: SeekableStreamType,
        // Need to keep track of this separately so we don't introduce possible
        // failure in `read` when getting the current position
        pos: usize,
        constrained_end_pos: ?usize = null,

        const Self = @This();

        pub const Error = error{
            EndOfConstrainedStream,
        };
        pub const ReadError = Error || ReaderType.Error;
        pub const SeekError = Error || SeekableStreamType.SeekError;
        pub const GetSeekPosError = SeekableStreamType.GetSeekPosError;

        pub const Reader = io.Reader(*Self, ReadError, read);
        pub const SeekableStream = io.SeekableStream(
            *Self,
            SeekError,
            GetSeekPosError,
            seekTo,
            seekBy,
            getPos,
            getEndPos,
        );

        pub fn read(self: *Self, dest: []u8) ReadError!usize {
            if (self.constrained_end_pos) |constrained_end_pos| {
                if (self.pos + dest.len > constrained_end_pos) {
                    return error.EndOfConstrainedStream;
                }
            }
            const bytes_read = try self.underlying_reader.read(dest);
            self.pos += bytes_read;
            return bytes_read;
        }

        pub fn seekTo(self: *Self, pos: u64) SeekError!void {
            if (self.constrained_end_pos) |constrained_end_pos| {
                if (pos > constrained_end_pos) {
                    return error.EndOfConstrainedStream;
                }
            }
            try self.underlying_seekable_stream.seekTo(pos);
            self.pos = pos;
        }

        pub fn seekBy(self: *Self, amt: i64) SeekError!void {
            // TODO: there's probably a better way to do this
            const seek_pos = if (amt >= 0)
                (self.pos + @as(usize, @intCast(amt)))
            else
                (self.pos - @abs(amt));
            if (self.constrained_end_pos) |constrained_end_pos| {
                if (seek_pos > constrained_end_pos) {
                    return error.EndOfConstrainedStream;
                }
            }
            try self.underlying_seekable_stream.seekBy(amt);
            self.pos = seek_pos;
        }

        /// Returns the current constrained end pos or the underlying end pos if not currently constrained
        pub fn getEndPos(self: *Self) GetSeekPosError!u64 {
            if (self.constrained_end_pos) |constrained_end_pos| {
                return constrained_end_pos;
            }
            return self.underlying_seekable_stream.getEndPos();
        }

        pub fn getPos(self: *Self) GetSeekPosError!u64 {
            return self.underlying_seekable_stream.getPos();
        }

        pub fn reader(self: *Self) Reader {
            return .{ .context = self };
        }

        pub fn seekableStream(self: *Self) SeekableStream {
            return .{ .context = self };
        }
    };
}

pub fn constrainedStream(current_pos: usize, underlying_reader: anytype, underlying_seekable_stream: anytype) ConstrainedStream(@TypeOf(underlying_reader), @TypeOf(underlying_seekable_stream)) {
    return .{
        .underlying_reader = underlying_reader,
        .underlying_seekable_stream = underlying_seekable_stream,
        .pos = current_pos,
    };
}

test "ConstrainedStream with file" {
    const full_contents = "123456789" ** 2;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "testfile", .data = full_contents });

    var file = try tmp.dir.openFile("testfile", .{});
    defer file.close();

    var stream_source = std.io.StreamSource{ .file = file };
    var constrained_stream = constrainedStream(0, stream_source.reader(), stream_source.seekableStream());

    const reader = constrained_stream.reader();
    const seekable_stream = constrained_stream.seekableStream();

    _ = try reader.readBytesNoEof(3);
    try testing.expectEqual(@as(u64, 3), try seekable_stream.getPos());

    try seekable_stream.seekTo(0);
    try testing.expectEqual(@as(u64, 0), try seekable_stream.getPos());

    constrained_stream.constrained_end_pos = 2;

    // read exactly to end
    _ = try reader.readBytesNoEof(2);
    try testing.expectEqual(@as(u64, 2), try seekable_stream.getPos());

    try seekable_stream.seekTo(0);
    try testing.expectEqual(@as(u64, 0), try seekable_stream.getPos());

    // reading past end gives an error
    const first_few_bytes_again = reader.readBytesNoEof(3);
    try testing.expectError(error.EndOfConstrainedStream, first_few_bytes_again);
}
