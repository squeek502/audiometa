const std = @import("std");
const io = std.io;

pub const ogg_stream_marker = "OggS";

// From 'header_type_flag' of https://xiph.org/ogg/doc/framing.html
// Potentially useful for the below
// "TODO: validate header type flag potentially"
//const fresh_packet = 0x00;
//const first_page_of_logical_bitstream = 0x02;

/// A wrapping reader that reads (and skips past) Ogg page headers and returns the
/// data within them
pub fn OggPageReader(comptime ReaderType: type) type {
    return struct {
        child_reader: ReaderType,
        read_state: ReadState = .header,
        data_remaining: usize = 0,

        const ReadState = enum {
            header,
            data,
            done,
        };

        pub const OggPageReadError = error{
            InvalidStreamMarker,
            UnknownStreamStructureVersion,
            ZeroLengthPage,
            TruncatedHeader,
            TruncatedData,
        };
        pub const Error = OggPageReadError || ReaderType.Error;
        pub const Reader = io.Reader(*Self, Error, read);

        const Self = @This();

        pub fn read(self: *Self, dest: []u8) Error!usize {
            return self.readEofOnTruncatedHeader(dest) catch |err| switch (err) {
                error.EndOfStream => return error.TruncatedHeader,
                else => |e| return e,
            };
        }

        // This is separated out only as a convenience, in order to be able to translate all
        // EndOfStream errors to TruncatedHeader errors at the callsite
        fn readEofOnTruncatedHeader(self: *Self, dest: []u8) (error{EndOfStream} || Error)!usize {
            var num_read: usize = 0;
            while (true) {
                switch (self.read_state) {
                    .header => {
                        // Getting EOF while reading the first bytes of the header just means that
                        // there is no data left to read. After we've read a stream marker, though,
                        // hitting EOF is treated as fatal.
                        var stream_marker = self.child_reader.readBytesNoEof(4) catch |err| switch (err) {
                            error.EndOfStream => {
                                self.read_state = .done;
                                continue;
                            },
                            else => |e| return e,
                        };
                        if (!std.mem.eql(u8, stream_marker[0..], ogg_stream_marker)) {
                            return error.InvalidStreamMarker;
                        }

                        const stream_structure_version = try self.child_reader.readByte();
                        if (stream_structure_version != 0) {
                            return error.UnknownStreamStructureVersion;
                        }

                        // TODO: validate header type flag potentially
                        _ = try self.child_reader.readByte();

                        // absolute granule position + stream serial number + page sequence number + page checksum
                        const bytes_to_skip = 8 + 4 + 4 + 4;
                        try self.child_reader.skipBytes(bytes_to_skip, .{ .buf_size = bytes_to_skip });

                        const page_segments = try self.child_reader.readByte();
                        if (page_segments == 0) {
                            return error.ZeroLengthPage;
                        }

                        var segment_table_buf: [255]u8 = undefined;
                        const segment_table = segment_table_buf[0..page_segments];
                        try self.child_reader.readNoEof(segment_table);

                        // max is 255 * 255
                        var length: u16 = 0;
                        for (segment_table) |val| {
                            length += val;
                        }

                        if (length == 0) {
                            return error.ZeroLengthPage;
                        }

                        self.read_state = .data;
                        self.data_remaining = length;
                    },
                    .data => {
                        while (self.data_remaining > 0 and num_read < dest.len) {
                            const byte = self.child_reader.readByte() catch |err| switch (err) {
                                error.EndOfStream => return error.TruncatedData,
                                else => |e| return e,
                            };
                            dest[num_read] = byte;
                            num_read += 1;
                            self.data_remaining -= 1;
                        }
                        if (num_read == dest.len) {
                            break;
                        } else {
                            self.read_state = .header;
                        }
                    },
                    .done => {
                        return num_read;
                    },
                }
            }
            return num_read;
        }

        pub fn reader(self: *Self) Reader {
            return .{ .context = self };
        }
    };
}

pub fn oggPageReader(underlying_stream: anytype) OggPageReader(@TypeOf(underlying_stream)) {
    return .{ .child_reader = underlying_stream };
}

test oggPageReader {
    const data = "OggS\x00\x02\x00\x00\x00\x00\x00\x00\x00\x00\xbc\xf2O\x00\x00\x00\x00\x00\xbe\x9d\xbfd\x01\x1e\x01vorbis\x00\x00\x00\x00\x02D\xac\x00\x00\x00\x00\x00\x00\x03q\x02\x00\x00\x00\x00\x00\xb8\x01OggS\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\xbc\xf2O\x00\x01\x00\x00\x00\x11\r\xc6\xa1\x01?\x03vorbis\x1d\x00\x00\x00Xiph.Org libVorbis I 20020717\x06\x00\x00\x00\x0b\x00\x00\x00TITLE=Paria\x10\x00\x00\x00OggS\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\xbc\xf2O\x00\x01\x00\x00\x00\x11\r\xc6\xa1\x01jARTIST=TROMATISM\x0c\x00\x00\x00ALBUM=PIRATE\n\x00\x00\x00GENRE=PUNK%\x00\x00\x00COMMENT=http://www.sauve-qui-punk.org\x0e\x00\x00\x00TRACKNUMBER=20\x01";
    var fbs = std.io.fixedBufferStream(data);

    var ogg_page_reader = oggPageReader(fbs.reader());
    var buf_reader = std.io.bufferedReader(ogg_page_reader.reader());
    const reader = buf_reader.reader();

    const result = try reader.readAllAlloc(std.testing.allocator, std.math.maxInt(usize));
    defer std.testing.allocator.free(result);

    try std.testing.expectEqualSlices(
        u8,
        "\x01vorbis\x00\x00\x00\x00\x02D\xac\x00\x00\x00\x00\x00\x00\x03q\x02\x00\x00\x00\x00\x00\xb8\x01\x03vorbis\x1d\x00\x00\x00Xiph.Org libVorbis I 20020717\x06\x00\x00\x00\x0b\x00\x00\x00TITLE=Paria\x10\x00\x00\x00ARTIST=TROMATISM\x0c\x00\x00\x00ALBUM=PIRATE\n\x00\x00\x00GENRE=PUNK%\x00\x00\x00COMMENT=http://www.sauve-qui-punk.org\x0e\x00\x00\x00TRACKNUMBER=20\x01",
        result,
    );
}
