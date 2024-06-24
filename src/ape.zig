const std = @import("std");
const APEMetadata = @import("metadata.zig").APEMetadata;
const Allocator = std.mem.Allocator;

pub const APEHeader = struct {
    version: u32,
    /// Tag size in bytes including footer and all tag items
    tag_size: u32,
    item_count: u32,
    flags: APETagFlags,

    pub const len: usize = 32;
    pub const identifier = "APETAGEX";

    pub fn read(reader: anytype) !APEHeader {
        const header = try reader.readBytesNoEof(APEHeader.len);
        if (!std.mem.eql(u8, header[0..8], identifier)) {
            return error.InvalidIdentifier;
        }
        return APEHeader{
            .version = std.mem.readInt(u32, header[8..12], .little),
            .tag_size = std.mem.readInt(u32, header[12..16], .little),
            .item_count = std.mem.readInt(u32, header[16..20], .little),
            .flags = APETagFlags{ .flags = std.mem.readInt(u32, header[20..24], .little) },
            // last 8 bytes are reserved, we can just assume they are zero
            // since erroring if they are non-zero seems unnecessary
        };
    }

    pub fn sizeIncludingHeader(self: APEHeader) usize {
        return self.tag_size + (if (self.flags.hasHeader()) APEHeader.len else 0);
    }
};

/// Shared between APE headers, footers, and items
pub const APETagFlags = struct {
    flags: u32,

    pub fn hasHeader(self: APETagFlags) bool {
        return self.flags & (1 << 31) != 0;
    }

    pub fn hasFooter(self: APETagFlags) bool {
        return self.flags & (1 << 30) != 0;
    }

    pub fn isHeader(self: APETagFlags) bool {
        return self.flags & (1 << 29) != 0;
    }

    pub fn isReadOnly(self: APETagFlags) bool {
        return self.flags & 1 != 0;
    }

    pub const ItemDataType = enum {
        utf8,
        binary,
        external,
        reserved,
    };

    pub fn itemDataType(self: APETagFlags) ItemDataType {
        const data_type_bits = (self.flags & 6) >> 1;
        return switch (data_type_bits) {
            0 => .utf8,
            1 => .binary,
            2 => .external,
            3 => .reserved,
            else => unreachable,
        };
    }
};

pub fn readFromHeader(allocator: Allocator, reader: anytype, seekable_stream: anytype) !APEMetadata {
    const start_offset = try seekable_stream.getPos();
    const header = try APEHeader.read(reader);
    const end_offset = start_offset + APEHeader.len + header.tag_size;

    if (end_offset > try seekable_stream.getEndPos()) {
        return error.EndOfStream;
    }

    var ape_metadata = APEMetadata.init(allocator, header, start_offset, end_offset);
    errdefer ape_metadata.deinit();

    const footer_size = if (header.flags.hasFooter()) APEHeader.len else 0;
    const end_of_items_offset = ape_metadata.metadata.end_offset - footer_size;

    try readItems(allocator, reader, seekable_stream, &ape_metadata, end_of_items_offset);

    if (header.flags.hasFooter()) {
        _ = try APEHeader.read(reader);
    }

    return ape_metadata;
}

/// Expects the seekable_stream position to be at the end of the footer that is being read.
pub fn readFromFooter(allocator: Allocator, reader: anytype, seekable_stream: anytype) !APEMetadata {
    const end_pos = try seekable_stream.getPos();
    if (end_pos < APEHeader.len) {
        return error.EndOfStream;
    }

    try seekable_stream.seekBy(-@as(i64, @intCast(APEHeader.len)));
    const footer = try APEHeader.read(reader);

    // the size is meant to include the footer, so if it doesn't
    // have room for the footer we just read, it's invalid
    if (footer.tag_size < APEHeader.len) {
        return error.InvalidSize;
    }

    var ape_metadata = APEMetadata.init(allocator, footer, 0, 0);
    errdefer ape_metadata.deinit();

    var metadata = &ape_metadata.metadata;

    metadata.end_offset = try seekable_stream.getPos();
    const total_size = footer.sizeIncludingHeader();
    if (total_size > metadata.end_offset) {
        return error.EndOfStream;
    }
    metadata.start_offset = metadata.end_offset - total_size;

    try seekable_stream.seekTo(metadata.start_offset);
    if (footer.flags.hasHeader()) {
        _ = try APEHeader.read(reader);
    }

    const end_of_items_offset = metadata.end_offset - APEHeader.len;
    try readItems(allocator, reader, seekable_stream, &ape_metadata, end_of_items_offset);

    return ape_metadata;
}

pub fn readItems(allocator: Allocator, reader: anytype, seekable_stream: anytype, ape_metadata: *APEMetadata, end_of_items_offset: usize) !void {
    var metadata_map = &ape_metadata.metadata.map;

    if (end_of_items_offset < 9) {
        return error.EndOfStream;
    }

    // The `- 9` comes from (u32 size + u32 flags + \x00 item key terminator)
    const end_of_items_offset_with_space_for_item = end_of_items_offset - 9;
    var i: usize = 0;
    while (i < ape_metadata.header_or_footer.item_count and try seekable_stream.getPos() < end_of_items_offset_with_space_for_item) : (i += 1) {
        const value_size = try reader.readInt(u32, .little);

        // short circuit for impossibly long values, no need to actually
        // allocate and try reading them
        const cur_pos = try seekable_stream.getPos();
        if (cur_pos + value_size > end_of_items_offset) {
            return error.EndOfStream;
        }

        const item_flags = APETagFlags{ .flags = try reader.readInt(u32, .little) };
        switch (item_flags.itemDataType()) {
            .utf8 => {
                const key = try reader.readUntilDelimiterAlloc(allocator, '\x00', end_of_items_offset - try seekable_stream.getPos());
                defer allocator.free(key);
                const value = try allocator.alloc(u8, value_size);
                defer allocator.free(value);
                try reader.readNoEof(value);

                // reject invalid UTF-8
                // TODO: key could potentially be more restricted to ASCII or a subset of ASCII
                if (!std.unicode.utf8ValidateSlice(key) or !std.unicode.utf8ValidateSlice(value)) {
                    continue;
                }

                try metadata_map.put(key, value);
            },
            // TODO: Maybe do something with binary/external data, for now
            // we're only interested in text metadata though
            .binary, .external, .reserved => {
                try reader.skipUntilDelimiterOrEof('\x00');
                try seekable_stream.seekBy(value_size);
            },
        }
    }

    // TODO: seems like we should do some validation here,
    // like checking that i == item_count or that we've read the
    // full data?
}
