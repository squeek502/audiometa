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

        // short circuit for impossible comment lengths to avoid
        // giant allocations that we know are impossible to read
        const max_remaining_bytes = (try seekable_stream.getEndPos()) - (try seekable_stream.getPos());
        if (length > max_remaining_bytes) {
            return error.EndOfStream;
        }

        if (block_type == block_type_vorbis_comment) {
            const start_offset = try seekable_stream.getPos();
            const end_offset = start_offset + length;

            // since we know the length, we can read it all up front
            // and then wrap it in a FixedBufferStream so that we can
            // get bounds-checking in our read calls when reading the
            // comment without any special casing
            var comments = try allocator.alloc(u8, length);
            defer allocator.free(comments);
            try reader.readNoEof(comments);

            var fixed_buffer_stream = std.io.fixedBufferStream(comments);

            var metadata = vorbis.readComment(allocator, fixed_buffer_stream.reader(), fixed_buffer_stream.seekableStream()) catch |e| switch (e) {
                error.EndOfStream => return error.EndOfCommentBlock,
                else => |err| return err,
            };
            errdefer metadata.deinit();

            metadata.start_offset = start_offset;
            metadata.end_offset = end_offset;

            // There can only be one comment block per stream, so we can return here
            return metadata;
        } else {
            // skipping bytes in the reader actually reads the bytes which is a
            // huge waste of time, this is way faster
            try seekable_stream.seekBy(length);
        }

        if (is_last_metadata_block) break;
    }

    return error.NoCommentBlock;
}
