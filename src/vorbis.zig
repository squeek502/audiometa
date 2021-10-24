const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const id3v2 = @import("id3v2.zig");
const ogg = @import("ogg.zig");
const fmtUtf8SliceEscapeUpper = @import("util.zig").fmtUtf8SliceEscapeUpper;
const Metadata = @import("metadata.zig").Metadata;

pub const codec_id = "vorbis";

// bit flags for the header type (used in the first byte of a page's data)
// from https://xiph.org/vorbis/doc/Vorbis_I_spec.html#x1-620004.2.1
pub const PacketType = enum(u8) {
    audio = 0,
    identification = 1,
    comment = 3,
    setup = 5,
};

// From 'header_type_flag' of https://xiph.org/ogg/doc/framing.html
const fresh_packet = 0x00;
const first_page_of_logical_bitstream = 0x02;

pub fn readComment(allocator: *Allocator, reader: anytype, seekable_stream: anytype) !Metadata {
    var metadata: Metadata = Metadata.init(allocator);
    errdefer metadata.deinit();

    var metadata_map = &metadata.map;

    const vendor_length = try reader.readIntLittle(u32);
    try reader.skipBytes(vendor_length, .{});

    const user_comment_list_length = try reader.readIntLittle(u32);
    var user_comment_index: u32 = 0;
    while (user_comment_index < user_comment_list_length) : (user_comment_index += 1) {
        const comment_length = try reader.readIntLittle(u32);

        // short circuit for impossible comment lengths to avoid
        // giant allocations that we know are impossible to read
        const max_remaining_bytes = (try seekable_stream.getEndPos()) - (try seekable_stream.getPos());
        if (comment_length > max_remaining_bytes) {
            return error.EndOfStream;
        }

        var comment = try allocator.alloc(u8, comment_length);
        defer allocator.free(comment);
        try reader.readNoEof(comment);

        var split_it = std.mem.split(u8, comment, "=");
        var field = split_it.next() orelse return error.InvalidCommentField;
        var value = split_it.rest();

        try metadata_map.put(field, value);
    }

    return metadata;
}

/// Expects the stream to be at the start of the Ogg bitstream (i.e. 
/// any ID3v2 tags must be skipped before calling this function)
pub fn read(allocator: *Allocator, reader: anytype, seekable_stream: anytype) !Metadata {
    _ = seekable_stream;

    const ogg_page_reader = ogg.oggPageReader(reader).reader();

    // identification
    const id_header_type = try ogg_page_reader.readByte();
    if (id_header_type != @enumToInt(PacketType.identification)) {
        return error.UnexpectedHeaderType;
    }
    const id_signature = try ogg_page_reader.readBytesNoEof(codec_id.len);
    if (!std.mem.eql(u8, &id_signature, codec_id)) {
        return error.UnexpectedCodec;
    }
    _ = try ogg_page_reader.skipBytes(22, .{});
    const id_framing_bit = try ogg_page_reader.readByte();
    if (id_framing_bit & 1 != 1) {
        return error.MissingFramingBit;
    }

    // comment
    const header_type = try ogg_page_reader.readByte();
    if (header_type != @enumToInt(PacketType.comment)) {
        return error.UnexpectedHeaderType;
    }
    const comment_signature = try ogg_page_reader.readBytesNoEof(codec_id.len);
    if (!std.mem.eql(u8, &comment_signature, codec_id)) {
        return error.UnexpectedCodec;
    }

    const start_offset = try seekable_stream.getPos();
    var metadata = try readComment(allocator, ogg_page_reader, seekable_stream);
    errdefer metadata.deinit();

    metadata.start_offset = start_offset;
    metadata.end_offset = try seekable_stream.getPos();

    // verify framing bit
    const comment_framing_bit = try ogg_page_reader.readByte();
    if (comment_framing_bit & 1 != 1) {
        return error.MissingFramingBit;
    }

    return metadata;
}
