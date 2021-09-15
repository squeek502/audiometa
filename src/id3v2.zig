const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const synchsafe = @import("synchsafe.zig");
const latin1 = @import("latin1.zig");
const fmtUtf8SliceEscapeUpper = @import("util.zig").fmtUtf8SliceEscapeUpper;
const unsynch = @import("unsynch.zig");
const ID3v2Metadata = @import("metadata.zig").ID3v2Metadata;
const nulTerminated = @import("util.zig").nulTerminated;

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

    pub fn compressed(self: *const ID3Header) bool {
        return self.major_version <= 2 and self.flags & (1 << 6) != 0;
    }

    pub fn hasExtendedHeader(self: *const ID3Header) bool {
        return self.major_version >= 3 and self.flags & (1 << 6) != 0;
    }

    // TODO: handle footers
    pub fn hasFooter(self: *const ID3Header) bool {
        return self.major_version >= 4 and self.flags & (1 << 4) != 0;
    }

    pub fn experimental(self: *const ID3Header) bool {
        return self.major_version >= 3 and self.flags & (1 << 5) != 0;
    }

    pub fn unsynchronised(self: *const ID3Header) bool {
        return self.flags & (1 << 7) != 0;
    }
};

pub const FrameHeader = struct {
    id: [4]u8,
    size: u32,
    raw_size: u32,
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
                    .raw_size = size,
                    .status_flags = 0,
                    .format_flags = 0,
                };
            },
            else => {
                const header = try reader.readBytesNoEof(10);
                const raw_size = std.mem.readIntSliceBig(u32, header[4..8]);
                const size = if (major_version >= 4) synchsafe.decode(u32, raw_size) else raw_size;
                return FrameHeader{
                    .id = [_]u8{ header[0], header[1], header[2], header[3] },
                    .size = size,
                    .raw_size = raw_size,
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

    pub fn skipData(self: FrameHeader, unsynch_capable_reader: anytype, seekable_stream: anytype) !void {
        // TODO: this Reader.context access seems pretty gross
        if (unsynch_capable_reader.context.unsynch) {
            // if the tag is full unsynch, then we need to skip while reading
            try unsynch_capable_reader.skipBytes(self.size, .{});
        } else {
            // if the tag is not full unsynch, then we can just skip without reading
            try seekable_stream.seekBy(self.size);
        }
    }

    pub fn skipDataFromPos(self: FrameHeader, start_pos: usize, unsynch_capable_reader: anytype, seekable_stream: anytype) !void {
        try seekable_stream.seekTo(start_pos);
        return self.skipData(unsynch_capable_reader, seekable_stream);
    }
};

pub fn skip(reader: anytype, seekable_stream: anytype) !void {
    const header = ID3Header.read(reader) catch {
        try seekable_stream.seekTo(0);
        return;
    };
    return seekable_stream.seekBy(header.size);
}

/// On error, seekable_stream cursor position will be wherever the error happened, it is
/// up to the caller to determine what to do from there
pub fn readFrame(allocator: *Allocator, unsynch_capable_reader: anytype, seekable_stream: anytype, metadata_id3v2_container: *ID3v2Metadata, frame_header: *FrameHeader, remaining_tag_size: usize) !void {
    const id3_major_version = metadata_id3v2_container.header.major_version;
    var metadata = &metadata_id3v2_container.metadata;
    var metadata_map = &metadata.map;

    // this is technically not valid AFAIK but ffmpeg seems to accept
    // it without failing the parse, so just skip it
    // TODO: zero sized T-type frames? would ffprobe output that?
    if (frame_header.size == 0) {
        return error.ZeroSizeFrame;
    }

    // sometimes v2.4 encoders don't use synchsafe integers for their frame sizes
    // so we need to double check
    if (id3_major_version >= 4) {
        const cur_pos = try seekable_stream.getPos();
        synchsafe_check: {
            const after_frame_u32 = cur_pos + frame_header.raw_size;
            const after_frame_synchsafe = cur_pos + frame_header.size;

            seekable_stream.seekTo(after_frame_synchsafe) catch break :synchsafe_check;
            const next_frame_header_synchsafe = FrameHeader.read(unsynch_capable_reader, id3_major_version) catch break :synchsafe_check;

            if (next_frame_header_synchsafe.validate(id3_major_version, remaining_tag_size)) {
                break :synchsafe_check;
            } else |_| {}

            seekable_stream.seekTo(after_frame_u32) catch break :synchsafe_check;
            const next_frame_header_u32 = FrameHeader.read(unsynch_capable_reader, id3_major_version) catch break :synchsafe_check;

            next_frame_header_u32.validate(id3_major_version, remaining_tag_size) catch break :synchsafe_check;

            // if we got here then this is the better size
            frame_header.size = frame_header.raw_size;
        }
        try seekable_stream.seekTo(cur_pos);
    }

    // has a text encoding byte at the start
    if (frame_header.id[0] == 'T') {
        var text_data_size = frame_header.size;

        if (frame_header.has_data_length_indicator()) {
            if (text_data_size < 4) {
                return error.UnexpectedTextDataEnd;
            }
            //const frame_data_length_raw = try unsynch_capable_reader.readIntBig(u32);
            //const frame_data_length = synchsafe.decode(u32, frame_data_length_raw);
            try unsynch_capable_reader.skipBytes(4, .{});
            text_data_size -= 4;
        }

        if (text_data_size == 0) {
            return error.UnexpectedTextDataEnd;
        }
        const encoding_byte = try unsynch_capable_reader.readByte();
        text_data_size -= 1;

        if (text_data_size == 0) {
            return error.ZeroSizeTextData;
        }

        // Treat as NUL terminated because some v2.3 tags will use 3 length IDs
        // with a NUL as the 4th char, and we should handle those as NUL terminated
        const id = nulTerminated(frame_header.idSlice(id3_major_version));
        const user_defined_id = switch (id.len) {
            3 => "TXX",
            else => "TXXX",
        };
        const is_user_defined = std.mem.eql(u8, id, user_defined_id);

        switch (encoding_byte) {
            0, 3 => { // 0 = ISO-8859-1 aka latin1, 3 = UTF-8
                var text_data = try allocator.alloc(u8, text_data_size);
                defer allocator.free(text_data);

                try unsynch_capable_reader.readNoEof(text_data);

                if (frame_header.unsynchronised()) {
                    var decoded_text_data = try allocator.alloc(u8, text_data_size);
                    decoded_text_data = unsynch.decode(text_data, decoded_text_data);

                    allocator.free(text_data);
                    text_data = decoded_text_data;
                }

                // If the text is latin1, then convert it to UTF-8
                if (encoding_byte == 0) {
                    var utf8_text = try latin1.latin1ToUtf8Alloc(allocator, text_data);

                    allocator.free(text_data);
                    text_data = utf8_text;
                }

                var it = std.mem.split(u8, text_data, "\x00");

                const text = it.next().?;
                if (is_user_defined) {
                    const value = it.next().?;
                    try metadata_map.put(text, value);
                } else {
                    try metadata_map.put(id, text);
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
                    // or garbage. if so, just ignore it and pretend it doesn't exist
                    text_data = text_data[0..(text_data.len - 1)];
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

                var it = std.mem.split(u16, utf16_text, &[_]u16{0x0000});

                var text = it.next().?;
                if (has_bom) {
                    // check for byte order mark and skip it
                    if (text[0] != 0xFEFF) {
                        return error.InvalidUTF16BOM;
                    }
                    text = text[1..];
                }
                var utf8_text = try std.unicode.utf16leToUtf8Alloc(allocator, text);
                defer allocator.free(utf8_text);

                if (is_user_defined) {
                    var value = it.next().?;
                    if (has_bom) {
                        // check for byte order mark and skip it
                        if (value[0] != 0xFEFF) {
                            return error.InvalidUTF16BOM;
                        }
                        value = value[1..];
                    }
                    var utf8_value = try std.unicode.utf16leToUtf8Alloc(allocator, value);
                    defer allocator.free(utf8_value);

                    try metadata_map.put(utf8_text, utf8_value);
                } else {
                    try metadata_map.put(id, utf8_text);
                }
            },
            else => return error.InvalidTextEncodingByte,
        }
    } else {
        try frame_header.skipData(unsynch_capable_reader, seekable_stream);
    }
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

        const end_offset = start_offset + ID3Header.len + id3_header.size;
        try metadata_buf.append(ID3v2Metadata.init(allocator, id3_header, start_offset, end_offset));
        var metadata_id3v2_container = &metadata_buf.items[metadata_buf.items.len - 1];
        var metadata = &metadata_id3v2_container.metadata;

        // ID3v2.2 compression should just be skipped according to the spec
        if (id3_header.compressed()) {
            try seekable_stream.seekTo(end_offset);
            continue;
        }

        // Unsynchronisation is weird. As I understand it:
        //
        // For ID3v2.3:
        // - Either *all* of a tag has been unsynched or none of it has (the tag header
        //   itself has an 'unsynch' flag)
        // - The full tag size is the final size (after unsynchronization), but all data
        //   within the tag is set *before* synchronization, so that means all
        //   extra bytes added by unsynchronization must be skipped during decoding
        //  + The spec is fairly unclear about the order of operations here, but this
        //    seems to be the case for all of the unsynch 2.3 files in my collection
        // - Frame sizes are not written as synchsafe integers, so the size itself must
        //   be decoded and extra bytes must be ignored while reading it
        // This means that for ID3v2.3, unsynch tags should discard all extra bytes while
        // reading the tag (i.e. if a frame size is 4, you should read *at least* 4 bytes,
        // skipping over any extra bytes added by unsynchronization; the decoded size
        // will match the given frame size)
        //
        // For ID3v2.4:
        // - Frame headers use synchsafe integers and therefore the frame headers
        //   are guaranteed to be synchsafe.
        // - ID3v2.4 doesn't have a tag-wide 'unsynch' flag and instead frames have
        //   an 'unsynch' flag.
        // - ID3v2.4 spec states: 'size descriptor [contains] the size of
        //   the data in the final frame, after encryption, compression and
        //   unsynchronisation'
        // This means that for ID3v2.4, unsynch frames should be read using the given size
        // and then decoded (i.e. if size is 4, you should read 4 bytes and then decode them;
        // the decoded size could end up being smaller)
        const tag_unsynch = id3_header.unsynchronised();
        const should_read_and_then_decode = id3_header.major_version >= 4;
        const should_read_unsynch = tag_unsynch and !should_read_and_then_decode;
        var unsynch_reader = unsynch.unsynchCapableReader(should_read_unsynch, reader);
        var unsynch_capable_reader = unsynch_reader.reader();

        // Skip past extended header if it exists
        if (id3_header.hasExtendedHeader()) {
            const extended_header_size: u32 = try unsynch_capable_reader.readIntBig(u32);
            // In ID3v2.4, extended header size is a synchsafe integer and includes the size bytes
            // in its reported size. In earlier versions, it is not synchsafe and excludes the size bytes.
            if (id3_header.major_version >= 4) {
                const synchsafe_extended_header_size = synchsafe.decode(u32, extended_header_size);
                const remaining_extended_header_size = synchsafe_extended_header_size - 4;
                try seekable_stream.seekBy(remaining_extended_header_size);
            } else {
                try seekable_stream.seekBy(extended_header_size);
            }
        }

        const frame_header_len = FrameHeader.len(id3_header.major_version);
        // Slightly hacky solution for trailing garbage/padding bytes at the end of the tag. Instead of
        // trying to read a tag that we know is invalid (since frame size has to be > 0
        // excluding the header), we can stop reading once there's not enough space left for
        // a valid tag to be read.
        const tag_end_with_enough_space_for_valid_frame: usize = metadata.end_offset - frame_header_len;
        var cur_pos = try seekable_stream.getPos();
        while (cur_pos < tag_end_with_enough_space_for_valid_frame) : (cur_pos = try seekable_stream.getPos()) {
            var frame_header = try FrameHeader.read(unsynch_capable_reader, id3_header.major_version);

            var frame_data_start_pos = try seekable_stream.getPos();
            var remaining_tag_size = metadata.end_offset - frame_data_start_pos;

            // validate frame_header and bail out if its too crazy
            frame_header.validate(id3_header.major_version, remaining_tag_size) catch {
                try seekable_stream.seekTo(metadata.end_offset);
                break;
            };

            readFrame(allocator, unsynch_capable_reader, seekable_stream, metadata_id3v2_container, &frame_header, remaining_tag_size) catch |e| switch (e) {
                // Errors within the frame can be recovered from by skipping the frame
                error.InvalidTextEncodingByte,
                error.ZeroSizeFrame,
                error.InvalidUTF16BOM,
                error.ZeroSizeTextData,
                error.UnexpectedTextDataEnd,
                => {
                    // This is a bit weird, but go back to the start of the frame and then
                    // skip forward. This ensures that we correctly skip the frame in all
                    // circumstances (partially read, full unsynch, etc)
                    try frame_header.skipDataFromPos(frame_data_start_pos, unsynch_capable_reader, seekable_stream);
                    continue;
                },
                else => |err| return err,
            };
        }
    }

    return metadata_buf.toOwnedSlice();
}
