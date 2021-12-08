const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const synchsafe = @import("synchsafe.zig");
const latin1 = @import("latin1.zig");
const fmtUtf8SliceEscapeUpper = @import("util.zig").fmtUtf8SliceEscapeUpper;
const unsynch = @import("unsynch.zig");
const AllID3v2Metadata = @import("metadata.zig").AllID3v2Metadata;
const ID3v2Metadata = @import("metadata.zig").ID3v2Metadata;

pub const id3v2_identifier = "ID3";
pub const id3v2_footer_identifier = "3DI";

pub const ID3Header = struct {
    major_version: u8,
    revision_num: u8,
    flags: u8,
    /// Includes the size of the extended header, the padding, and the frames
    /// after unsynchronization. Does not include the header or the footer (if
    /// present).
    size: synchsafe.DecodedType(u32),

    pub const len: usize = 10;

    pub fn read(reader: anytype) !ID3Header {
        return readWithIdentifier(reader, id3v2_identifier);
    }

    pub fn readFooter(reader: anytype) !ID3Header {
        return readWithIdentifier(reader, id3v2_footer_identifier);
    }

    fn readWithIdentifier(reader: anytype, comptime identifier: []const u8) !ID3Header {
        assert(identifier.len == 3);
        const header = try reader.readBytesNoEof(ID3Header.len);
        if (!std.mem.eql(u8, header[0..3], identifier)) {
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

    pub fn hasDataLengthIndicator(self: *const FrameHeader) bool {
        return self.format_flags & @as(u8, 1) != 0;
    }

    pub fn skipData(self: FrameHeader, unsynch_capable_reader: anytype, seekable_stream: anytype, full_unsynch: bool) !void {
        if (full_unsynch) {
            // if the tag is full unsynch, then we need to skip while reading
            try unsynch_capable_reader.skipBytes(self.size, .{});
        } else {
            // if the tag is not full unsynch, then we can just skip without reading
            try seekable_stream.seekBy(self.size);
        }
    }

    pub fn skipDataFromPos(self: FrameHeader, start_pos: usize, unsynch_capable_reader: anytype, seekable_stream: anytype, full_unsynch: bool) !void {
        try seekable_stream.seekTo(start_pos);
        return self.skipData(unsynch_capable_reader, seekable_stream, full_unsynch);
    }
};

pub const TextEncoding = enum(u8) {
    iso_8859_1 = 0,
    utf16_with_bom = 1,
    utf16_no_bom = 2,
    utf8 = 3,

    pub fn fromByte(byte: u8) error{InvalidTextEncodingByte}!TextEncoding {
        return std.meta.intToEnum(TextEncoding, byte) catch error.InvalidTextEncodingByte;
    }

    pub fn charSize(encoding: TextEncoding) u8 {
        return switch (encoding) {
            .iso_8859_1, .utf8 => 1,
            .utf16_with_bom, .utf16_no_bom => 2,
        };
    }

    pub fn delimiter(comptime T: type) []const T {
        return &[_]T{0};
    }
};

pub const EncodedTextIterator = struct {
    text_bytes: []const u8,
    index: ?usize,
    encoding: TextEncoding,
    raw_text_data: []const u8,
    /// Buffer for UTF-8 data when converting from UTF-16
    /// TODO: Is this actually useful performance-wise?
    utf8_buf: []u8,
    allocator: *Allocator,

    const Self = @This();

    const u16_align = @alignOf(u16);

    pub const Options = struct {
        encoding: TextEncoding,
        text_data_size: usize,
        frame_is_unsynch: bool,
    };

    pub fn init(allocator: *Allocator, reader: anytype, options: Options) !Self {
        // always align to u16 just so that UTF-16 data is easy to work with
        // but alignCast it back to u8 so that it's also easy to work with non-UTF-16 data
        var raw_text_data = @alignCast(1, try allocator.allocWithOptions(u8, options.text_data_size, u16_align, null));
        errdefer allocator.free(raw_text_data);

        try reader.readNoEof(raw_text_data);

        var text_bytes = raw_text_data;
        if (options.frame_is_unsynch) {
            // This is safe since unsynch decoding is guaranteed to
            // never shift the beginning of the slice, so the alignment
            // can't change
            text_bytes = unsynch.decodeInPlace(text_bytes);
        }

        if (options.encoding.charSize() == 2) {
            if (text_bytes.len % 2 != 0) {
                // there could be an erroneous trailing single char nul-terminator
                // or garbage. if so, just ignore it and pretend it doesn't exist
                text_bytes.len -= 1;
            }
        }

        // If the text is latin1, then convert it to UTF-8
        if (options.encoding == .iso_8859_1) {
            var utf8_text = try latin1.latin1ToUtf8Alloc(allocator, text_bytes);

            // the utf8 data is now the raw_text_data
            allocator.free(raw_text_data);
            raw_text_data = utf8_text;

            text_bytes = utf8_text;
        }

        // if this is big endian, then swap everything to little endian up front
        // TODO: I feel like this probably won't handle big endian native architectures correctly
        if (options.encoding == .utf16_with_bom) {
            var bytes_as_utf16 = std.mem.bytesAsSlice(u16, text_bytes);
            if (text_bytes.len == 0) {
                return error.UnexpectedTextDataEnd;
            }
            const bom = bytes_as_utf16[0];
            if (bom == 0xFFFE) {
                for (bytes_as_utf16) |c, i| {
                    bytes_as_utf16[i] = @byteSwap(u16, c);
                }
            }
        }

        const utf8_buf = switch (options.encoding.charSize()) {
            1 => &[_]u8{},
            // In the worst case, a single UTF-16 u16 can take up 3 bytes when
            // converted to UTF-8 (e.g. 0xFFFF as UTF-16 is 0xEF 0xBF 0xBF as UTF-8)
            // UTF-16 len * 3 should therefore be large enough to always store any
            // conversion.
            2 => try allocator.alloc(u8, text_bytes.len / 2 * 3),
            else => unreachable,
        };
        errdefer allocator.free(utf8_buf);

        return Self{
            .allocator = allocator,
            .text_bytes = text_bytes,
            .encoding = options.encoding,
            .index = 0,
            .utf8_buf = utf8_buf,
            .raw_text_data = raw_text_data,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.raw_text_data);
        self.allocator.free(self.utf8_buf);
    }

    pub const TerminatorType = enum {
        optional,
        required,
    };

    pub fn next(self: *Self, terminator: TerminatorType) error{ InvalidUTF16BOM, InvalidUTF16Data }!?[]const u8 {
        // The idea here is that we want to handle lists of null-terminated
        // values but also potentially malformed single values, i.e.
        // a zero length text with no null-termination
        const start = self.index orelse return null;
        const end: usize = end: {
            switch (self.encoding.charSize()) {
                1 => {
                    const delimiter = TextEncoding.delimiter(u8);
                    if (std.mem.indexOfPos(u8, self.text_bytes, start, delimiter)) |delim_start| {
                        self.index = delim_start + delimiter.len;
                        break :end delim_start;
                    }
                },
                2 => {
                    var bytes_as_utf16 = @alignCast(u16_align, std.mem.bytesAsSlice(u16, self.text_bytes));
                    const delimiter = TextEncoding.delimiter(u16);
                    if (std.mem.indexOfPos(u16, bytes_as_utf16, start / 2, delimiter)) |delim_start| {
                        self.index = (delim_start + delimiter.len) * 2;
                        break :end delim_start * 2;
                    }
                },
                else => unreachable,
            }
            const is_first_value_or_more_to_read = start == 0 or start < self.text_bytes.len;
            if (terminator == .optional or is_first_value_or_more_to_read) {
                self.index = null;
                break :end self.text_bytes.len;
            } else {
                // if a terminator is required and we're not at the start,
                // then the lack of a null-terminator should return null immediately
                // since there's no value to be read, i.e. "a\x00" should not give
                // "a" and then ""
                return null;
            }
        };
        const utf8_val = try self.nextToUtf8(self.text_bytes[start..end]);
        return utf8_val;
    }

    /// Always returns UTF-8.
    /// When converting from UTF-16, the returned data is temporary
    /// and will be overwritten on subsequent calls to `next`.
    fn nextToUtf8(self: Self, val_bytes: []const u8) error{ InvalidUTF16BOM, InvalidUTF16Data }![]const u8 {
        if (self.encoding.charSize() == 2) {
            const bytes_as_utf16 = @alignCast(u16_align, std.mem.bytesAsSlice(u16, val_bytes));
            var val_no_bom = bytes_as_utf16;
            if (self.encoding == .utf16_with_bom) {
                // check for byte order mark and skip it
                if (bytes_as_utf16.len == 0 or bytes_as_utf16[0] != 0xFEFF) {
                    return error.InvalidUTF16BOM;
                }
                val_no_bom = bytes_as_utf16[1..];
            }
            const utf8_end = std.unicode.utf16leToUtf8(self.utf8_buf, val_no_bom) catch return error.InvalidUTF16Data;
            return self.utf8_buf[0..utf8_end];
        }
        return val_bytes;
    }
};

pub fn skip(reader: anytype, seekable_stream: anytype) !void {
    const header = ID3Header.read(reader) catch {
        try seekable_stream.seekTo(0);
        return;
    };
    return seekable_stream.seekBy(header.size);
}

pub const TextFrame = struct {
    size_remaining: usize,
    encoding: TextEncoding,
};

pub fn readTextFrameCommon(unsynch_capable_reader: anytype, frame_header: *FrameHeader) !TextFrame {
    var text_data_size = frame_header.size;

    if (frame_header.hasDataLengthIndicator()) {
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
    const encoding = try TextEncoding.fromByte(encoding_byte);
    text_data_size -= 1;

    return TextFrame{
        .size_remaining = text_data_size,
        .encoding = encoding,
    };
}

/// On error, seekable_stream cursor position will be wherever the error happened, it is
/// up to the caller to determine what to do from there
pub fn readFrame(allocator: *Allocator, unsynch_capable_reader: anytype, seekable_stream: anytype, metadata_id3v2_container: *ID3v2Metadata, frame_header: *FrameHeader, remaining_tag_size: usize, full_unsynch: bool) !void {
    _ = allocator;

    const id3_major_version = metadata_id3v2_container.header.major_version;
    var metadata = &metadata_id3v2_container.metadata;
    var metadata_map = &metadata.map;
    var comments_map = &metadata_id3v2_container.comments;
    var unsynchronized_lyrics_map = &metadata_id3v2_container.unsynchronized_lyrics;

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

    // Treat as NUL terminated because some v2.3 tags will (erroneously) use v2.2 IDs
    // with a NUL as the 4th char, and we should handle those as NUL terminated
    const id = std.mem.sliceTo(frame_header.idSlice(id3_major_version), '\x00');

    // TODO: I think it's possible for a ID3v2.4 frame that has the unsynch flag set
    // to need more comprehensive decoding to ensure that we always read the full
    // frame correctly. Right now we do the unsynch decoding in the EncodedTextIterator
    // which means for COMM/USLT frames we don't decode the language characters.
    // This isn't a huge problem since any language string that needs decoding
    // will be invalid, but it might be best to handle that edge case anyway.

    if (frame_header.id[0] == 'T') {
        const text_frame = try readTextFrameCommon(unsynch_capable_reader, frame_header);
        const is_user_defined = std.mem.eql(u8, id, if (id.len == 3) "TXX" else "TXXX");

        // we can handle this as a special case
        if (text_frame.size_remaining == 0) {
            // if this is a user-defined frame, then there's no way it's valid,
            // since there has to be a nul terminator between the name and the value
            if (is_user_defined) {
                return error.InvalidUserDefinedTextFrame;
            }

            return metadata_map.put(id, "");
        }

        if (is_user_defined) {
            var text_iterator = try EncodedTextIterator.init(allocator, unsynch_capable_reader, .{
                .text_data_size = text_frame.size_remaining,
                .encoding = text_frame.encoding,
                .frame_is_unsynch = frame_header.unsynchronised(),
            });
            defer text_iterator.deinit();

            const field = (try text_iterator.next(.required)) orelse return error.UnexpectedTextDataEnd;
            const entry = try metadata_map.getOrPutEntry(field);

            const value = (try text_iterator.next(.optional)) orelse return error.UnexpectedTextDataEnd;
            try metadata_map.appendToEntry(entry, value);
        } else {
            // From section 4.2 of https://id3.org/id3v2.4.0-frames:
            // > All text information frames supports multiple strings,
            // > stored as a null separated list, where null is reperesented
            // > by the termination code for the charater encoding.
            //
            // This technically only applies to 2.4, but we do it unconditionally
            // to accomidate buggy encoders that encode 2.3 as if it were 2.4.
            // TODO: Is this behavior for 2.3 and 2.2 okay?
            var text_iterator = try EncodedTextIterator.init(allocator, unsynch_capable_reader, .{
                .text_data_size = text_frame.size_remaining,
                .encoding = text_frame.encoding,
                .frame_is_unsynch = frame_header.unsynchronised(),
            });
            defer text_iterator.deinit();

            const entry = try metadata_map.getOrPutEntry(id);
            while (try text_iterator.next(.required)) |text| {
                try metadata_map.appendToEntry(entry, text);
            }
        }
    } else if (std.mem.eql(u8, id, if (id.len == 3) "ULT" else "USLT")) {
        var text_frame = try readTextFrameCommon(unsynch_capable_reader, frame_header);
        if (text_frame.size_remaining < 3) {
            return error.UnexpectedTextDataEnd;
        }
        const language = try unsynch_capable_reader.readBytesNoEof(3);
        text_frame.size_remaining -= 3;

        var text_iterator = try EncodedTextIterator.init(allocator, unsynch_capable_reader, .{
            .text_data_size = text_frame.size_remaining,
            .encoding = text_frame.encoding,
            .frame_is_unsynch = frame_header.unsynchronised(),
        });
        defer text_iterator.deinit();

        const description = (try text_iterator.next(.required)) orelse return error.UnexpectedTextDataEnd;
        const entries = try unsynchronized_lyrics_map.getOrPutIndexesEntries(&language, description);

        const value = (try text_iterator.next(.optional)) orelse return error.UnexpectedTextDataEnd;
        try unsynchronized_lyrics_map.appendToEntries(entries, value);
    } else if (std.mem.eql(u8, id, if (id.len == 3) "COM" else "COMM")) {
        var text_frame = try readTextFrameCommon(unsynch_capable_reader, frame_header);
        if (text_frame.size_remaining < 3) {
            return error.UnexpectedTextDataEnd;
        }
        const language = try unsynch_capable_reader.readBytesNoEof(3);
        text_frame.size_remaining -= 3;

        var text_iterator = try EncodedTextIterator.init(allocator, unsynch_capable_reader, .{
            .text_data_size = text_frame.size_remaining,
            .encoding = text_frame.encoding,
            .frame_is_unsynch = frame_header.unsynchronised(),
        });
        defer text_iterator.deinit();

        const description = (try text_iterator.next(.required)) orelse return error.UnexpectedTextDataEnd;
        const entries = try comments_map.getOrPutIndexesEntries(&language, description);

        const value = (try text_iterator.next(.optional)) orelse return error.UnexpectedTextDataEnd;
        try comments_map.appendToEntries(entries, value);
    } else {
        try frame_header.skipData(unsynch_capable_reader, seekable_stream, full_unsynch);
    }
}

pub fn read(allocator: *Allocator, reader: anytype, seekable_stream: anytype) !ID3v2Metadata {
    const start_offset = try seekable_stream.getPos();
    const id3_header = try ID3Header.read(reader);

    const footer_size = if (id3_header.hasFooter()) ID3Header.len else 0;
    const end_offset = start_offset + ID3Header.len + id3_header.size + footer_size;
    if (end_offset > try seekable_stream.getEndPos()) {
        return error.EndOfStream;
    }

    var metadata_id3v2_container = ID3v2Metadata.init(allocator, id3_header, start_offset, end_offset);
    errdefer metadata_id3v2_container.deinit();
    var metadata = &metadata_id3v2_container.metadata;

    // ID3v2.2 compression should just be skipped according to the spec
    if (id3_header.compressed()) {
        try seekable_stream.seekTo(end_offset);
        return metadata_id3v2_container;
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

    // Slightly hacky solution for trailing garbage/padding bytes at the end of the tag. Instead of
    // trying to read a tag that we know is invalid (since frame size has to be > 0
    // excluding the header), we can stop reading once there's not enough space left for
    // a valid tag to be read.
    const tag_end_with_enough_space_for_valid_frame: usize = metadata.end_offset - FrameHeader.len(id3_header.major_version);

    // Skip past extended header if it exists
    if (id3_header.hasExtendedHeader()) {
        const extended_header_size: u32 = try unsynch_capable_reader.readIntBig(u32);
        // In ID3v2.4, extended header size is a synchsafe integer and includes the size bytes
        // in its reported size. In earlier versions, it is not synchsafe and excludes the size bytes.
        const remaining_extended_header_size = remaining: {
            if (id3_header.major_version >= 4) {
                const synchsafe_extended_header_size = synchsafe.decode(u32, extended_header_size);
                if (synchsafe_extended_header_size < 4) {
                    return error.InvalidExtendedHeaderSize;
                }
                break :remaining synchsafe_extended_header_size - 4;
            }
            break :remaining extended_header_size;
        };
        if ((try seekable_stream.getPos()) + remaining_extended_header_size > tag_end_with_enough_space_for_valid_frame) {
            return error.InvalidExtendedHeaderSize;
        }
        try seekable_stream.seekBy(remaining_extended_header_size);
    }

    var cur_pos = try seekable_stream.getPos();
    while (cur_pos < tag_end_with_enough_space_for_valid_frame) : (cur_pos = try seekable_stream.getPos()) {
        var frame_header = try FrameHeader.read(unsynch_capable_reader, id3_header.major_version);

        var frame_data_start_pos = try seekable_stream.getPos();
        // It's possible for full unsynch tags to advance the position more than
        // the frame header length since the header itself is decoded while it's
        // read. If we read such that `frame_data_start_pos > metadata.end_offset`,
        // then treat it as 0 remaining size.
        var remaining_tag_size = std.math.sub(usize, metadata.end_offset, frame_data_start_pos) catch 0;

        // validate frame_header and bail out if its too crazy
        frame_header.validate(id3_header.major_version, remaining_tag_size) catch {
            try seekable_stream.seekTo(metadata.end_offset);
            break;
        };

        readFrame(allocator, unsynch_capable_reader, seekable_stream, &metadata_id3v2_container, &frame_header, remaining_tag_size, unsynch_reader.unsynch) catch |e| switch (e) {
            // Errors within the frame can be recovered from by skipping the frame
            error.InvalidTextEncodingByte,
            error.ZeroSizeFrame,
            error.InvalidUTF16BOM,
            error.UnexpectedTextDataEnd,
            error.InvalidUserDefinedTextFrame,
            error.InvalidUTF16Data,
            => {
                // This is a bit weird, but go back to the start of the frame and then
                // skip forward. This ensures that we correctly skip the frame in all
                // circumstances (partially read, full unsynch, etc)
                try frame_header.skipDataFromPos(frame_data_start_pos, unsynch_capable_reader, seekable_stream, unsynch_reader.unsynch);
                continue;
            },
            else => |err| return err,
        };
    }

    if (id3_header.hasFooter()) {
        _ = try ID3Header.readFooter(reader);
    }

    return metadata_id3v2_container;
}

/// Expects the seekable_stream position to be at the end of the footer that is being read.
pub fn readFromFooter(allocator: *Allocator, reader: anytype, seekable_stream: anytype) !ID3v2Metadata {
    var end_pos = try seekable_stream.getPos();
    if (end_pos < ID3Header.len) {
        return error.EndOfStream;
    }

    try seekable_stream.seekBy(-@intCast(i64, ID3Header.len));
    const footer = try ID3Header.readFooter(reader);

    // header len + size + footer len
    const full_tag_size = ID3Header.len + footer.size + ID3Header.len;

    if (end_pos < full_tag_size) {
        return error.EndOfStream;
    }

    const start_of_header = end_pos - full_tag_size;
    try seekable_stream.seekTo(start_of_header);

    return read(allocator, reader, seekable_stream);
}

/// Untested, probably no real reason to keep around
/// TODO: probably remove
pub fn readAll(allocator: *Allocator, reader: anytype, seekable_stream: anytype) !AllID3v2Metadata {
    var metadata_buf = std.ArrayList(ID3v2Metadata).init(allocator);
    errdefer {
        for (metadata_buf.items) |*meta| {
            meta.deinit();
        }
        metadata_buf.deinit();
    }

    var is_duplicate_tag = false;

    while (true) : (is_duplicate_tag = true) {
        var id3v2_meta = read(allocator, reader, seekable_stream) catch |e| switch (e) {
            error.EndOfStream, error.InvalidIdentifier => |err| {
                if (is_duplicate_tag) {
                    break;
                } else {
                    return err;
                }
            },
            else => |err| return err,
        };
        errdefer id3v2_meta.deinit();

        try metadata_buf.append(id3v2_meta);
    }

    return AllID3v2Metadata{
        .allocator = allocator,
        .tags = metadata_buf.toOwnedSlice(),
    };
}

fn testTextIterator(comptime encoding: TextEncoding, input: []const u8, expected_strings: []const []const u8) !void {
    var fbs = std.io.fixedBufferStream(input);

    var text_iterator = try EncodedTextIterator.init(std.testing.allocator, fbs.reader(), .{
        .text_data_size = input.len,
        .encoding = encoding,
        .frame_is_unsynch = false,
    });
    defer text_iterator.deinit();

    var num_texts: usize = 0;
    for (expected_strings) |expected_string| {
        const text = (try text_iterator.next(.required)).?;
        try std.testing.expectEqualStrings(expected_string, text);
        num_texts += 1;
    }
    try std.testing.expectEqual(expected_strings.len, num_texts);
}

test "UTF-8 EncodedTextIterator null terminated lists" {
    try testTextIterator(.utf8, "", &[_][]const u8{""});
    try testTextIterator(.utf8, "\x00", &[_][]const u8{""});
    try testTextIterator(.utf8, "hello", &[_][]const u8{"hello"});
    try testTextIterator(.utf8, "hello\x00", &[_][]const u8{"hello"});
    try testTextIterator(.utf8, "hello\x00\x00", &[_][]const u8{ "hello", "" });
}

test "UTF-16 EncodedTextIterator null terminated lists" {
    try testTextIterator(.utf16_with_bom, &[_]u8{ '\xFF', '\xFE', '\x00', '\x00' }, &[_][]const u8{""});
    try testTextIterator(.utf16_with_bom, &[_]u8{ '\xFF', '\xFE' }, &[_][]const u8{""});
    try testTextIterator(.utf16_no_bom, std.mem.sliceAsBytes(std.unicode.utf8ToUtf16LeStringLiteral("\x00")), &[_][]const u8{""});
    try testTextIterator(.utf16_no_bom, std.mem.sliceAsBytes(std.unicode.utf8ToUtf16LeStringLiteral("hello")), &[_][]const u8{"hello"});
    try testTextIterator(.utf16_no_bom, std.mem.sliceAsBytes(std.unicode.utf8ToUtf16LeStringLiteral("hello\x00")), &[_][]const u8{"hello"});
    try testTextIterator(.utf16_no_bom, std.mem.sliceAsBytes(std.unicode.utf8ToUtf16LeStringLiteral("hello\x00\x00")), &[_][]const u8{ "hello", "" });
}
