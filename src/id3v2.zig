const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const synchsafe = @import("synchsafe.zig");
const latin1 = @import("latin1.zig");
const fmtUtf8SliceEscapeUpper = @import("util.zig").fmtUtf8SliceEscapeUpper;
const unsynch = @import("unsynch.zig");
const ID3v2Metadata = @import("metadata.zig").ID3v2Metadata;

pub const id3v2_identifier = "ID3";

pub const ID3Header = struct {
    major_version: u8,
    revision_num: u8,
    flags: u8,
    size: synchsafe.DecodedType(u32),

    pub const len: usize = 10;

    pub fn read(reader: anytype) !ID3Header {
        const header = try reader.readBytesNoEof(10);
        if (!std.mem.eql(u8, header[0..3], id3v2_identifier)) {
            return error.InvalidIdentifier;
        }
        const synchsafe_size = std.mem.readIntSliceBig(u32, header[6..10]);
        return ID3Header{
            .major_version = header[3],
            .revision_num = header[4],
            .flags = header[5],
            .size = synchsafe.decode(u32, synchsafe_size),
        };
    }

    pub fn unsynchronised(self: *const ID3Header) bool {
        return self.flags & (1 << 7) != 0;
    }
};

pub const FrameHeader = struct {
    id: [4]u8,
    size: u32,
    status_flags: u8,
    format_flags: u8,

    pub fn len(major_version: u8) usize {
        return switch (major_version) {
            0...2 => 6,
            else => 10,
        };
    }

    pub fn read(reader: anytype, major_version: u8) !FrameHeader {
        switch (major_version) {
            0...2 => {
                const header = try reader.readBytesNoEof(6);
                var size = std.mem.readIntSliceBig(u24, header[3..6]);
                return FrameHeader{
                    .id = [_]u8{ header[0], header[1], header[2], '\x00' },
                    .size = size,
                    .status_flags = 0,
                    .format_flags = 0,
                };
            },
            else => {
                const header = try reader.readBytesNoEof(10);
                var size = std.mem.readIntSliceBig(u32, header[4..8]);
                if (major_version >= 4) {
                    size = synchsafe.decode(u32, size);
                }
                return FrameHeader{
                    .id = [_]u8{ header[0], header[1], header[2], header[3] },
                    .size = size,
                    .status_flags = header[8],
                    .format_flags = header[9],
                };
            },
        }
    }

    pub fn idSlice(self: *const FrameHeader, major_version: u8) []const u8 {
        return switch (major_version) {
            0...2 => self.id[0..3],
            else => self.id[0..],
        };
    }

    pub fn validate(self: *const FrameHeader, major_version: u8, max_size: usize) !void {
        // TODO: ffmpeg doesn't have this check--it allows 0 sized frames to be read
        //const invalid_length_min: usize = if (self.has_data_length_indicator()) 4 else 0;
        //if (self.size <= invalid_length_min) return error.FrameTooShort;
        if (self.size > max_size) return error.FrameTooLong;
        for (self.idSlice(major_version)) |c, i| switch (c) {
            'A'...'Z', '0'...'9' => {},
            else => {
                // This is a hack to allow for v2.2 (3 char) ids to be read in v2.3 tags
                // which are apparently from an iTunes encoding bug.
                // TODO: document that frame ids might be nul teriminated in this case
                // or come up with a less hacky solution
                const is_id3v2_2_id_in_v2_3_frame = major_version == 3 and i == 3 and c == '\x00';
                if (!is_id3v2_2_id_in_v2_3_frame) {
                    return error.InvalidFrameID;
                }
            },
        };
    }

    pub fn unsynchronised(self: *const FrameHeader) bool {
        return self.format_flags & @as(u8, 1 << 1) != 0;
    }

    pub fn has_data_length_indicator(self: *const FrameHeader) bool {
        return self.format_flags & @as(u8, 1) != 0;
    }
};

pub fn skip(reader: anytype, seekable_stream: anytype) !void {
    const header = ID3Header.read(reader) catch {
        try seekable_stream.seekTo(0);
        return;
    };
    return seekable_stream.seekBy(header.size);
}

pub fn read(allocator: *Allocator, reader: anytype, seekable_stream: anytype) ![]ID3v2Metadata {
    var metadata_buf = std.ArrayList(ID3v2Metadata).init(allocator);
    errdefer {
        for (metadata_buf.items) |*meta| {
            meta.deinit();
        }
        metadata_buf.deinit();
    }

    var is_duplicate_tag = false;

    while (true) : (is_duplicate_tag = true) {
        const start_offset = try seekable_stream.getPos();

        std.debug.print("trying to read header at offset 0x{X}\n", .{try seekable_stream.getPos()});
        const id3_header = ID3Header.read(reader) catch |e| switch (e) {
            error.EndOfStream, error.InvalidIdentifier => |err| {
                if (is_duplicate_tag) {
                    break;
                } else {
                    return err;
                }
            },
            else => |err| return err,
        };

        try metadata_buf.append(ID3v2Metadata.init(allocator, id3_header.major_version, start_offset));
        var metadata_id3v2_container = &metadata_buf.items[metadata_buf.items.len - 1];
        var metadata_container = &metadata_id3v2_container.data;
        var metadata = &metadata_container.metadata;

        std.debug.print("tag v2.{}.{} size: 0x{X} flags: {}\n", .{ id3_header.major_version, id3_header.revision_num, id3_header.size, id3_header.flags });

        const id3_header_len = ID3Header.len;
        const frame_header_len = FrameHeader.len(id3_header.major_version);

        const tag_unsynch = id3_header.unsynchronised();
        const should_read_and_then_decode = id3_header.major_version > 3;
        const should_read_unsynch = tag_unsynch and !should_read_and_then_decode;
        std.debug.print("unsynch: {} decode separately: {}\n", .{ tag_unsynch, should_read_and_then_decode });

        var unsynch_reader = unsynch.unsynchCapableReader(should_read_unsynch, reader);
        var unsynch_capable_reader = unsynch_reader.reader();

        metadata_container.end_offset = start_offset + id3_header_len + id3_header.size;
        // Slightly hacky solution for trailing garbage/padding bytes at the end of the tag. Instead of
        // trying to read a tag that we know is invalid (since frame size has to be > 0
        // excluding the header), we can stop reading once there's not enough space left for
        // a valid tag to be read.
        const tag_end_with_enough_space_for_valid_frame: usize = metadata_container.end_offset - frame_header_len;
        std.debug.print("{} < {}\n", .{ (try seekable_stream.getPos()), tag_end_with_enough_space_for_valid_frame });
        while ((try seekable_stream.getPos()) < tag_end_with_enough_space_for_valid_frame) {
            const frame_header = try FrameHeader.read(unsynch_capable_reader, id3_header.major_version);
            std.debug.print("{} {s}\n", .{ frame_header, std.fmt.fmtSliceEscapeUpper(frame_header.idSlice(id3_header.major_version)) });

            // validate frame_header and bail out if its too crazy
            frame_header.validate(id3_header.major_version, id3_header.size) catch {
                std.debug.print("frame header failed to validate\n", .{});
                try seekable_stream.seekTo(start_offset + id3_header_len + id3_header.size);
                break;
            };

            // this is technically not valid AFAIK but ffmpeg seems to accept
            // it without failing the parse, so just skip it
            // TODO: zero sized T-type frames? would ffprobe output that?
            if (frame_header.size == 0) continue;

            // has a text encoding byte at the start
            if (frame_header.id[0] == 'T') {
                var text_data_size = frame_header.size;

                if (frame_header.has_data_length_indicator()) {
                    //const frame_data_length_raw = try unsynch_capable_reader.readIntBig(u32);
                    //const frame_data_length = synchsafe.decode(u32, frame_data_length_raw);
                    //std.debug.print("frame length from extra field: {x}\n", .{frame_data_length});
                    try unsynch_capable_reader.skipBytes(4, .{});
                    text_data_size -= 4;
                }

                const encoding_byte = try unsynch_capable_reader.readByte();
                text_data_size -= 1;

                if (text_data_size == 0) continue;

                const id = frame_header.idSlice(id3_header.major_version);
                const user_defined_id = switch (id3_header.major_version) {
                    0...2 => "TXX",
                    else => "TXXX",
                };
                const is_user_defined = std.mem.eql(u8, id, user_defined_id);

                switch (encoding_byte) {
                    0 => { // ISO-8859-1 aka latin1
                        var text_data = try allocator.alloc(u8, text_data_size);
                        defer allocator.free(text_data);

                        try unsynch_capable_reader.readNoEof(text_data);

                        if (frame_header.unsynchronised()) {
                            var decoded_text_data = try allocator.alloc(u8, text_data_size);
                            decoded_text_data = unsynch.decode(text_data, decoded_text_data);

                            allocator.free(text_data);
                            text_data = decoded_text_data;
                        }

                        var utf8_text = try latin1.latin1ToUtf8Alloc(allocator, text_data);
                        defer allocator.free(utf8_text);

                        var it = SplitIterator(u8){
                            .buffer = utf8_text,
                            .index = 0,
                            .delimiter = "\x00",
                        };

                        const text = it.next().?;
                        if (is_user_defined) {
                            const value = it.next().?;
                            try metadata.put(text, value);
                        } else {
                            try metadata.put(id, text);
                        }
                    },
                    1, 2 => { // UTF-16 (1 = with BOM, 2 = without)
                        const has_bom = encoding_byte == 1;
                        const u16_align = @alignOf(u16);
                        var text_data = try allocator.allocWithOptions(u8, text_data_size, u16_align, null);
                        defer allocator.free(text_data);

                        try unsynch_capable_reader.readNoEof(text_data);

                        if (frame_header.unsynchronised()) {
                            var decoded_text_data = try allocator.allocWithOptions(u8, text_data_size, u16_align, null);
                            decoded_text_data = @alignCast(u16_align, unsynch.decode(text_data, decoded_text_data));

                            allocator.free(text_data);
                            text_data = decoded_text_data;
                        }

                        if (text_data.len % 2 != 0) {
                            // there could be an erroneous trailing single char nul-terminator
                            // if so, just ignore it
                            if (text_data[text_data.len - 1] == '\x00') {
                                text_data = text_data[0..(text_data.len - 1)];
                            } else {
                                break;
                            }
                        }

                        var utf16_text = @alignCast(u16_align, std.mem.bytesAsSlice(u16, text_data));

                        // if this is big endian, then swap everything to little endian up front
                        // TODO: I feel like this probably won't handle big endian native architectures correctly
                        if (has_bom) {
                            const bom = utf16_text[0];
                            if (bom == 0xFFFE) {
                                for (utf16_text) |c, i| {
                                    utf16_text[i] = @byteSwap(u16, c);
                                }
                            }
                        }

                        var it = SplitIterator(u16){
                            .buffer = utf16_text,
                            .index = 0,
                            .delimiter = &[_]u16{0x0000},
                        };

                        var text = it.next().?;
                        if (has_bom) {
                            // check for byte order mark and skip it
                            assert(text[0] == 0xFEFF);
                            text = text[1..];
                        }
                        var utf8_text = try std.unicode.utf16leToUtf8Alloc(allocator, text);
                        defer allocator.free(utf8_text);

                        if (is_user_defined) {
                            var value = it.next().?;
                            if (has_bom) {
                                // check for byte order mark and skip it
                                assert(value[0] == 0xFEFF);
                                value = value[1..];
                            }
                            var utf8_value = try std.unicode.utf16leToUtf8Alloc(allocator, value);
                            defer allocator.free(utf8_value);

                            try metadata.put(utf8_text, utf8_value);
                        } else {
                            try metadata.put(id, utf8_text);
                        }
                    },
                    3 => { // UTF-8
                        var text_data = try allocator.alloc(u8, text_data_size);
                        defer allocator.free(text_data);

                        try unsynch_capable_reader.readNoEof(text_data);

                        if (frame_header.unsynchronised()) {
                            var decoded_text_data = try allocator.alloc(u8, text_data_size);
                            decoded_text_data = unsynch.decode(text_data, decoded_text_data);

                            allocator.free(text_data);
                            text_data = decoded_text_data;
                        }

                        var it = SplitIterator(u8){
                            .buffer = text_data,
                            .index = 0,
                            .delimiter = "\x00",
                        };

                        const text = it.next().?;
                        if (is_user_defined) {
                            const value = it.next().?;
                            try metadata.put(text, value);
                        } else {
                            try metadata.put(id, text);
                        }
                    },
                    else => unreachable,
                }
            } else {
                try unsynch_capable_reader.skipBytes(frame_header.size, .{});
            }
        }
    }

    return metadata_buf.toOwnedSlice();
}

// copy of std.mem.SplitIterator but with a user-supplied type
// TODO: remove if https://github.com/ziglang/zig/pull/9531 gets merged
pub fn SplitIterator(comptime T: type) type {
    return struct {
        buffer: []const T,
        index: ?usize,
        delimiter: []const T,

        const Self = @This();

        /// Returns a slice of the next field, or null if splitting is complete.
        pub fn next(self: *Self) ?[]const T {
            const start = self.index orelse return null;
            const end = if (std.mem.indexOfPos(T, self.buffer, start, self.delimiter)) |delim_start| blk: {
                self.index = delim_start + self.delimiter.len;
                break :blk delim_start;
            } else blk: {
                self.index = null;
                break :blk self.buffer.len;
            };
            return self.buffer[start..end];
        }

        /// Returns a slice of the remaining bytes. Does not affect iterator state.
        pub fn rest(self: Self) []const T {
            const end = self.buffer.len;
            const start = self.index orelse end;
            return self.buffer[start..end];
        }
    };
}

fn embedReadAndDump(comptime path: []const u8) !void {
    const data = @embedFile(path);
    var stream = std.io.fixedBufferStream(data);
    var metadata = try read(std.testing.allocator, stream.reader(), stream.seekableStream());
    defer metadata.deinit();

    metadata.dump();
}

test "mp3 read" {
    try embedReadAndDump("02 - 死前解放 (Unleash Before Death).mp3");
}

test "mp3 read 2" {
    try embedReadAndDump("Au bout de mes lèvres - Un arbre né derrière les murs - 01 Ces tours qui ne chantent plus.mp3");
}

test "latin1 tags" {
    try embedReadAndDump("01 - No Faith.....mp3");
}

test "tenc" {
    try embedReadAndDump("01 - Rosario.mp3");
}

test "v2.2" {
    try embedReadAndDump("01 - side a.mp3");
}

test "acephalix" {
    try embedReadAndDump("01 - Nothing.mp3");
}

test "auktion" {
    try embedReadAndDump("01.auktion - bomberegn.mp3");
}

test "control character in tag" {
    try embedReadAndDump("02 - Devä hráèov.mp3");
}

test "v2.4 with unsynch" {
    try embedReadAndDump("01 - Starmaker.mp3");
}

test "flac with full unsynch id3" {
    try embedReadAndDump("01 - Intro.flac");
}

test "id3v1" {
    try embedReadAndDump("(01) ... to reduce the choir to one soloist - Blind.mp3");
}
