const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const id3v2 = @import("id3v2.zig");
const fmtUtf8SliceEscapeUpper = @import("util.zig").fmtUtf8SliceEscapeUpper;
const Metadata = @import("metadata.zig").Metadata;

pub const ogg_stream_marker = "OggS";
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

pub fn readComment(allocator: *Allocator, reader: anytype, seekable_stream: anytype, length: u32) !Metadata {
    var metadata: Metadata = Metadata.init(allocator);
    errdefer metadata.deinit();

    var metadata_map = &metadata.map;

    metadata.start_offset = try seekable_stream.getPos();
    metadata.end_offset = metadata.start_offset + length;

    if (length < 4) {
        return error.BlockLengthTooSmall;
    }

    var comments = try allocator.alloc(u8, length);
    defer allocator.free(comments);
    try reader.readNoEof(comments);

    const vendor_length = std.mem.readIntSliceLittle(u32, comments[0..4]);
    if (vendor_length > length - 4) {
        return error.VendorLengthTooLong;
    }
    const vendor_string_end = 4 + vendor_length;
    const vendor_string = comments[4..vendor_string_end];
    _ = vendor_string;

    if (vendor_string_end > length - 4) {
        return error.InvalidVendorLength;
    }
    const user_comment_list_length = std.mem.readIntSliceLittle(u32, comments[vendor_string_end .. vendor_string_end + 4]);
    var user_comment_index: u32 = 0;
    var user_comment_offset: u32 = vendor_string_end + 4;
    const length_with_room_for_comment = length - 4;
    while (user_comment_offset < length_with_room_for_comment and user_comment_index < user_comment_list_length) : (user_comment_index += 1) {
        const comment_length = std.mem.readIntSliceLittle(u32, comments[user_comment_offset .. user_comment_offset + 4]);
        const comment_start_offset = user_comment_offset + 4;
        if (comment_length > length - comment_start_offset) {
            return error.CommentLengthTooLong;
        }
        const comment_start = comments[comment_start_offset..];
        const comment = comment_start[0..comment_length];

        var split_it = std.mem.split(u8, comment, "=");
        var field = split_it.next() orelse return error.InvalidCommentField;
        var value = split_it.rest();

        try metadata_map.put(field, value);

        user_comment_offset += 4 + comment_length;
    }

    return metadata;
}

/// Expects the stream to be at the start of the Ogg bitstream (i.e. 
/// any ID3v2 tags must be skipped before calling this function)
pub fn read(allocator: *Allocator, reader: anytype, seekable_stream: anytype) !Metadata {
    // TODO: This whole implementation is flawed. It works for the few .ogg files
    // that I have but that is a coincidence. The comment is able to span
    // across multiple pages if it's big enough, and that is not something that is accounted for
    // at all here.
    //
    // One fix would be to convert readComment into a streaming version instead of
    // allocating/reading the entire length up front, and then write a io.Reader
    // that can read Ogg pages and get the data from them.

    const first_page_size = try readHeaderExpectingType(reader, seekable_stream, first_page_of_logical_bitstream, .identification);
    try seekable_stream.seekBy(first_page_size);

    const second_page_size = try readHeaderExpectingType(reader, seekable_stream, fresh_packet, .comment);
    // read and verify the signature
    const actual_string = try reader.readBytesNoEof(codec_id.len);
    if (!std.mem.eql(u8, &actual_string, codec_id)) {
        return error.UnexpectedCodec;
    }
    const metadata_size = second_page_size - @as(u16, codec_id.len);
    var metadata = try readComment(allocator, reader, seekable_stream, metadata_size);
    errdefer metadata.deinit();

    return metadata;
}

/// Reads a page header and returns the length with the reader position at the start of the data
fn readHeaderExpectingType(reader: anytype, seekable_stream: anytype, expected_type_flag: u8, expected_type: PacketType) !u16 {
    var stream_marker = try reader.readBytesNoEof(4);
    if (!std.mem.eql(u8, stream_marker[0..], ogg_stream_marker)) {
        return error.InvalidStreamMarker;
    }

    const stream_structure_version = try reader.readByte();
    if (stream_structure_version != 0) {
        return error.UnknownStreamStructureVersion;
    }

    const header_type_flag = try reader.readByte();
    if (header_type_flag != expected_type_flag) {
        return error.UnexpectedHeaderTypeFlag;
    }

    // absolute granule position + stream serial number + page sequence number + page checksum
    try seekable_stream.seekBy(8 + 4 + 4 + 4);

    const page_segments = try reader.readByte();
    if (page_segments == 0) {
        return error.ZeroLengthPage;
    }

    var segment_table_buf: [255]u8 = undefined;
    const segment_table = segment_table_buf[0..page_segments];
    try reader.readNoEof(segment_table);

    // max is 255 * 255
    var length: u16 = 0;
    for (segment_table) |val| {
        length += val;
    }

    if (length == 0) {
        return error.ZeroLengthPage;
    }

    const header_type = try reader.readByte();
    if (header_type != @enumToInt(expected_type)) {
        return error.UnexpectedHeaderType;
    }

    // Header type is included in length, so subtract it out since we already read it.
    // This can't underflow because we already checked that length is non-zero.
    return length - 1;
}
