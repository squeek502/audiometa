const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const id3 = @import("id3v2.zig");
const fmtUtf8SliceEscapeUpper = @import("util.zig").fmtUtf8SliceEscapeUpper;
const MetadataMap = @import("metadata.zig").MetadataMap;

const flac_stream_marker = "fLaC";
const block_type_vorbis_comment = 4;

pub fn read(allocator: *Allocator, reader: anytype, seekable_stream: anytype) !MetadataMap {
    var metadata: MetadataMap = MetadataMap.init(allocator);
    errdefer metadata.deinit();

    var stream_marker = try reader.readBytesNoEof(4);

    // need to skip id3 tags if they exist
    if (std.mem.eql(u8, stream_marker[0..3], id3.id3_file_identifier)) {
        try seekable_stream.seekTo(0);
        try id3.skip(reader, seekable_stream);
        try reader.readNoEof(stream_marker[0..]);
    }

    if (!std.mem.eql(u8, stream_marker[0..], flac_stream_marker)) {
        return error.InvalidStreamMarker;
    }

    while (true) {
        const first_byte = try reader.readByte();
        const is_last_metadata_block = first_byte & @as(u8, 1 << 7) != 0;
        const block_type = first_byte & 0x7F;
        const length = try reader.readIntBig(u24);

        if (block_type == block_type_vorbis_comment) {
            var comments = try allocator.alloc(u8, length);
            defer allocator.free(comments);
            try reader.readNoEof(comments);

            const vendor_length = std.mem.readIntSliceLittle(u32, comments[0..4]);
            const vendor_string_end = 4 + vendor_length;
            const vendor_string = comments[4..vendor_string_end];
            _ = vendor_string;

            const user_comment_list_length = std.mem.readIntSliceLittle(u32, comments[vendor_string_end .. vendor_string_end + 4]);
            var user_comment_index: u32 = 0;
            var user_comment_offset: u32 = vendor_string_end + 4;
            while (user_comment_index < user_comment_list_length) : (user_comment_index += 1) {
                const comment_length = std.mem.readIntSliceLittle(u32, comments[user_comment_offset .. user_comment_offset + 4]);
                const comment_start = comments[user_comment_offset + 4 ..];
                const comment = comment_start[0..comment_length];

                var split_it = std.mem.split(u8, comment, "=");
                var field = split_it.next().?;
                var value = split_it.rest();

                // vorbis metadata fields are case-insensitive, so convert to uppercase
                // for the lookup
                var upper_field = try std.ascii.allocUpperString(allocator, field);
                defer allocator.free(upper_field);

                try metadata.put(ffmpeg_field_names.get(upper_field) orelse field, value);

                user_comment_offset += 4 + comment_length;
            }
        } else {
            try reader.skipBytes(length, .{});
        }

        if (is_last_metadata_block) break;
    }

    return metadata;
}

const ffmpeg_field_names = std.ComptimeStringMap([]const u8, .{
    .{ "ALBUMARTIST", "album_artist" },
    .{ "TRACKNUMBER", "track" },
    .{ "DISCNUMBER", "disc" },
    .{ "DESCRIPTION", "comment" },
});

fn embedReadAndDump(comptime path: []const u8) !void {
    const data = @embedFile(path);
    var stream = std.io.fixedBufferStream(data);
    var metadata = try read(std.testing.allocator, stream.reader(), stream.seekableStream());
    defer metadata.deinit();

    metadata.dump();
}

test "read flac" {
    try embedReadAndDump("02 - 死前解放 (Unleash Before Death).flac");
}

test "acursed" {
    try embedReadAndDump("01-Intro.flac");
}
