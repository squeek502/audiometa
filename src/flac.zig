const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const id3v2 = @import("id3v2.zig");
const fmtUtf8SliceEscapeUpper = @import("util.zig").fmtUtf8SliceEscapeUpper;
const Metadata = @import("metadata.zig").Metadata;

pub const flac_stream_marker = "fLaC";
pub const block_type_vorbis_comment = 4;

/// Expects the stream to be at the start of the FLAC stream marker (i.e. 
/// any ID3v2 tags must be skipped before calling this function)
pub fn read(allocator: *Allocator, reader: anytype, seekable_stream: anytype) !Metadata {
    var metadata: Metadata = Metadata.init(allocator);
    errdefer metadata.deinit();

    var metadata_map = &metadata.map;

    var stream_marker = try reader.readBytesNoEof(4);
    if (!std.mem.eql(u8, stream_marker[0..], flac_stream_marker)) {
        return error.InvalidStreamMarker;
    }

    while (true) {
        const first_byte = try reader.readByte();
        const is_last_metadata_block = first_byte & @as(u8, 1 << 7) != 0;
        const block_type = first_byte & 0x7F;
        const length = try reader.readIntBig(u24);

        if (block_type == block_type_vorbis_comment) {
            metadata.start_offset = try seekable_stream.getPos();
            metadata.end_offset = metadata.start_offset + length;

            if (length < 4) {
                return error.BlockLengthTooSmall;
            }

            var comments = try allocator.alloc(u8, length);
            defer allocator.free(comments);
            try reader.readNoEof(comments);

            const vendor_length = std.mem.readIntSliceLittle(u32, comments[0..4]);
            if (vendor_length >= length - 4) {
                return error.VendorLengthTooLong;
            }
            const vendor_string_end = 4 + vendor_length;
            const vendor_string = comments[4..vendor_string_end];
            _ = vendor_string;

            if (vendor_string_end >= length - 4) {
                return error.InvalidVendorLength;
            }
            const user_comment_list_length = std.mem.readIntSliceLittle(u32, comments[vendor_string_end .. vendor_string_end + 4]);
            var user_comment_index: u32 = 0;
            var user_comment_offset: u32 = vendor_string_end + 4;
            const length_with_room_for_comment = length - 4;
            while (user_comment_offset < length_with_room_for_comment and user_comment_index < user_comment_list_length) : (user_comment_index += 1) {
                const comment_length = std.mem.readIntSliceLittle(u32, comments[user_comment_offset .. user_comment_offset + 4]);
                const comment_start_offset = user_comment_offset + 4;
                if (comment_length >= length - comment_start_offset) {
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

            // There can only be one comment block per stream, so we can break here
            break;
        } else {
            // skipping bytes in the reader actually reads the bytes which is a
            // huge waste of time, this is way faster
            try seekable_stream.seekBy(length);
        }

        if (is_last_metadata_block) break;
    }

    return metadata;
}
