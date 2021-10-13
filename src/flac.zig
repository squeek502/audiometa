const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const id3v2 = @import("id3v2.zig");
const fmtUtf8SliceEscapeUpper = @import("util.zig").fmtUtf8SliceEscapeUpper;
const Metadata = @import("metadata.zig").Metadata;
const vorbis = @import("vorbis.zig");

pub const flac_stream_marker = "fLaC";
pub const block_type_vorbis_comment = 4;

/// Expects the stream to be at the start of the FLAC stream marker (i.e. 
/// any ID3v2 tags must be skipped before calling this function)
pub fn read(allocator: *Allocator, reader: anytype, seekable_stream: anytype) !Metadata {
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
            // There can only be one comment block per stream, so we can return here
            return vorbis.readComment(allocator, reader, seekable_stream, length);
        } else {
            // skipping bytes in the reader actually reads the bytes which is a
            // huge waste of time, this is way faster
            try seekable_stream.seekBy(length);
        }

        if (is_last_metadata_block) break;
    }

    return error.NoCommentBlock;
}
