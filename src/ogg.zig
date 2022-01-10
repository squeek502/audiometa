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
        };

        pub const OggHeaderReadError = error{
            InvalidStreamMarker,
            UnknownStreamStructureVersion,
            ZeroLengthPage,
        };
        pub const Error = error{EndOfStream} || OggHeaderReadError || ReaderType.Error;
        pub const Reader = io.Reader(*Self, Error, read);

        const Self = @This();

        pub fn read(self: *Self, dest: []u8) Error!usize {
            var num_read: usize = 0;
            while (true) {
                switch (self.read_state) {
                    .header => {
                        var stream_marker = try self.child_reader.readBytesNoEof(4);
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
                            const byte = try self.child_reader.readByte();
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
