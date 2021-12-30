const std = @import("std");
const id3v2 = @import("id3v2.zig");
const id3v2_data = @import("id3v2_data.zig");
const id3v1 = @import("id3v1.zig");
const flac = @import("flac.zig");
const vorbis = @import("vorbis.zig");
const ape = @import("ape.zig");
const Allocator = std.mem.Allocator;
const fmtUtf8SliceEscapeUpper = @import("util.zig").fmtUtf8SliceEscapeUpper;
const BufferedStreamSource = @import("buffered_stream_source.zig").BufferedStreamSource;
const time = std.time;
const Timer = time.Timer;

var timer: Timer = undefined;

pub fn readAll(allocator: Allocator, stream_source: *std.io.StreamSource) !AllMetadata {
    timer = try Timer.start();

    // Note: Using a buffered stream source here doesn't actually seem to make much
    // difference performance-wise for most files. However, it probably does give a performance
    // boost when reading unsynch files, since UnsynchCapableReader reads byte-by-byte
    // when it's reading ID3v2.3 unsynch tags.
    //
    // TODO: unsynch ID3v2.3 tags might be rare enough that the buffering is just
    // not necessary
    //
    // Also, if the buffer is too large then it seems to actually start slowing things down,
    // presumably because it starts filling the buffer with bytes that are going to be skipped
    // anyway so it's just doing extra work for no reason.
    const buffer_size = 512;
    var buffered_stream_source = BufferedStreamSource(buffer_size).init(stream_source);
    var reader = buffered_stream_source.reader();
    var seekable_stream = buffered_stream_source.seekableStream();

    var all_metadata = std.ArrayList(TypedMetadata).init(allocator);
    errdefer {
        var cleanup_helper = AllMetadata{
            .allocator = allocator,
            .tags = all_metadata.toOwnedSlice(),
        };
        cleanup_helper.deinit();
    }

    var time_taken = timer.read();
    std.debug.print("setup: {}us\n", .{time_taken / time.ns_per_us});
    timer.reset();

    // TODO: this won't handle id3v2 when a SEEK frame is used

    while (true) {
        const initial_pos = try seekable_stream.getPos();

        var id3v2_meta: ?ID3v2Metadata = id3v2.read(allocator, reader, seekable_stream) catch |e| switch (e) {
            error.OutOfMemory => |err| return err,
            else => null,
        };
        if (id3v2_meta != null) {
            {
                errdefer id3v2_meta.?.deinit();
                try all_metadata.append(TypedMetadata{ .id3v2 = id3v2_meta.? });
            }
            continue;
        }

        try seekable_stream.seekTo(initial_pos);
        var flac_metadata: ?Metadata = flac.read(allocator, reader, seekable_stream) catch |e| switch (e) {
            error.OutOfMemory => |err| return err,
            else => null,
        };
        if (flac_metadata != null) {
            {
                errdefer flac_metadata.?.deinit();
                try all_metadata.append(TypedMetadata{ .flac = flac_metadata.? });
            }
            continue;
        }

        try seekable_stream.seekTo(initial_pos);
        var vorbis_metadata: ?Metadata = vorbis.read(allocator, reader, seekable_stream) catch |e| switch (e) {
            error.OutOfMemory => |err| return err,
            else => null,
        };
        if (vorbis_metadata != null) {
            {
                errdefer vorbis_metadata.?.deinit();
                try all_metadata.append(TypedMetadata{ .vorbis = vorbis_metadata.? });
            }
            continue;
        }

        try seekable_stream.seekTo(initial_pos);
        var ape_metadata: ?APEMetadata = ape.readFromHeader(allocator, reader, seekable_stream) catch |e| switch (e) {
            error.OutOfMemory => |err| return err,
            else => null,
        };
        if (ape_metadata != null) {
            {
                errdefer ape_metadata.?.deinit();
                try all_metadata.append(TypedMetadata{ .ape = ape_metadata.? });
            }
            continue;
        }

        // if we get here, then we're out of valid tag headers to parse
        break;
    }

    time_taken = timer.read();
    std.debug.print("prefixed tags: {}us\n", .{time_taken / time.ns_per_us});
    timer.reset();

    const end_pos = try seekable_stream.getEndPos();
    try seekable_stream.seekTo(end_pos);

    const last_tag_end_offset: ?usize = offset: {
        if (all_metadata.items.len == 0) break :offset null;
        const last_tag = all_metadata.items[all_metadata.items.len - 1];
        break :offset switch (last_tag) {
            .id3v1, .flac, .vorbis => |v| v.end_offset,
            .id3v2 => |v| v.metadata.end_offset,
            .ape => |v| v.metadata.end_offset,
        };
    };

    while (true) {
        const initial_pos = try seekable_stream.getPos();

        // we don't want to read any tags that have already been read, so
        // if we're going to read into the last already read tag, then bail out
        if (last_tag_end_offset != null and try seekable_stream.getPos() <= last_tag_end_offset.?) {
            break;
        }
        var id3v1_metadata: ?Metadata = id3v1.read(allocator, reader, seekable_stream) catch |e| switch (e) {
            error.OutOfMemory => |err| return err,
            else => null,
        };
        if (id3v1_metadata != null) {
            {
                errdefer id3v1_metadata.?.deinit();
                try all_metadata.append(TypedMetadata{ .id3v1 = id3v1_metadata.? });
            }
            try seekable_stream.seekTo(id3v1_metadata.?.start_offset);
            continue;
        }

        try seekable_stream.seekTo(initial_pos);
        var ape_metadata: ?APEMetadata = ape.readFromFooter(allocator, reader, seekable_stream) catch |e| switch (e) {
            error.OutOfMemory => |err| return err,
            else => null,
        };
        if (ape_metadata != null) {
            {
                errdefer ape_metadata.?.deinit();
                try all_metadata.append(TypedMetadata{ .ape = ape_metadata.? });
            }
            try seekable_stream.seekTo(ape_metadata.?.metadata.start_offset);
            continue;
        }

        try seekable_stream.seekTo(initial_pos);
        var id3v2_metadata: ?ID3v2Metadata = id3v2.readFromFooter(allocator, reader, seekable_stream) catch |e| switch (e) {
            error.OutOfMemory => |err| return err,
            else => null,
        };
        if (id3v2_metadata != null) {
            {
                errdefer id3v2_metadata.?.deinit();
                try all_metadata.append(TypedMetadata{ .id3v2 = id3v2_metadata.? });
            }
            try seekable_stream.seekTo(id3v2_metadata.?.metadata.start_offset);
            continue;
        }

        // if we get here, then we're out of valid tag headers to parse
        break;
    }

    time_taken = timer.read();
    std.debug.print("suffixed tags: {}us\n", .{time_taken / time.ns_per_us});
    timer.reset();

    return AllMetadata{
        .allocator = allocator,
        .tags = all_metadata.toOwnedSlice(),
    };
}

pub const MetadataType = enum {
    id3v1,
    id3v2,
    ape,
    flac,
    vorbis,
};

pub const TypedMetadata = union(MetadataType) {
    id3v1: Metadata,
    id3v2: ID3v2Metadata,
    ape: APEMetadata,
    flac: Metadata,
    vorbis: Metadata,

    /// Convenience function to get the Metadata for any TypedMetadata
    pub fn getMetadata(typed_meta: TypedMetadata) Metadata {
        return switch (typed_meta) {
            .id3v1, .flac, .vorbis => |val| val,
            .id3v2 => |val| val.metadata,
            .ape => |val| val.metadata,
        };
    }
};

pub const AllMetadata = struct {
    allocator: Allocator,
    tags: []TypedMetadata,

    pub fn deinit(self: *AllMetadata) void {
        for (self.tags) |*tag| {
            // using a pointer and then deferencing it allows
            // the final capture to be non-const
            // TODO: this feels hacky
            switch (tag.*) {
                .id3v1, .flac, .vorbis => |*metadata| {
                    metadata.deinit();
                },
                .id3v2 => |*id3v2_metadata| {
                    id3v2_metadata.deinit();
                },
                .ape => |*ape_metadata| {
                    ape_metadata.deinit();
                },
            }
        }
        self.allocator.free(self.tags);
    }

    pub fn dump(self: *const AllMetadata) void {
        for (self.tags) |tag| {
            switch (tag) {
                .id3v1 => |*id3v1_meta| {
                    std.debug.print("# ID3v1 0x{x}-0x{x}\n", .{ id3v1_meta.start_offset, id3v1_meta.end_offset });
                    id3v1_meta.map.dump();
                },
                .flac => |*flac_meta| {
                    std.debug.print("# FLAC 0x{x}-0x{x}\n", .{ flac_meta.start_offset, flac_meta.end_offset });
                    flac_meta.map.dump();
                },
                .vorbis => |*vorbis_meta| {
                    std.debug.print("# Vorbis 0x{x}-0x{x}\n", .{ vorbis_meta.start_offset, vorbis_meta.end_offset });
                    vorbis_meta.map.dump();
                },
                .id3v2 => |*id3v2_meta| {
                    std.debug.print("# ID3v2 v2.{d} 0x{x}-0x{x}\n", .{ id3v2_meta.header.major_version, id3v2_meta.metadata.start_offset, id3v2_meta.metadata.end_offset });
                    id3v2_meta.dump();
                },
                .ape => |*ape_meta| {
                    std.debug.print("# APEv{d} 0x{x}-0x{x}\n", .{ ape_meta.header_or_footer.version, ape_meta.metadata.start_offset, ape_meta.metadata.end_offset });
                    ape_meta.metadata.map.dump();
                },
            }
        }
    }

    /// Returns an allocated slice of pointers to all metadata of the given type.
    /// Caller is responsible for freeing the slice's memory.
    pub fn getAllMetadataOfType(self: AllMetadata, allocator: Allocator, comptime tag_type: MetadataType) ![]*std.meta.TagPayload(TypedMetadata, tag_type) {
        const T = std.meta.TagPayload(TypedMetadata, tag_type);
        var buf = std.ArrayList(*T).init(allocator);
        errdefer buf.deinit();

        for (self.tags) |*tag| {
            if (@as(MetadataType, tag.*) == tag_type) {
                var val = &@field(tag.*, @tagName(tag_type));
                try buf.append(val);
            }
        }

        return buf.toOwnedSlice();
    }

    pub fn getFirstMetadataOfType(self: AllMetadata, comptime tag_type: MetadataType) ?*std.meta.TagPayload(TypedMetadata, tag_type) {
        for (self.tags) |*tag| {
            if (@as(MetadataType, tag.*) == tag_type) {
                return &@field(tag.*, @tagName(tag_type));
            }
        }
        return null;
    }

    pub fn getLastMetadataOfType(self: AllMetadata, comptime tag_type: MetadataType) ?*std.meta.TagPayload(TypedMetadata, tag_type) {
        var i = self.tags.len;
        while (i != 0) {
            i -= 1;
            if (@as(MetadataType, self.tags[i]) == tag_type) {
                return &@field(self.tags[i], @tagName(tag_type));
            }
        }
        return null;
    }
};

pub const AllID3v2Metadata = struct {
    allocator: Allocator,
    tags: []ID3v2Metadata,

    pub fn deinit(self: *AllID3v2Metadata) void {
        for (self.tags) |*tag| {
            tag.deinit();
        }
        self.allocator.free(self.tags);
    }
};

pub const ID3v2Metadata = struct {
    metadata: Metadata,
    header: id3v2.ID3Header,
    comments: id3v2_data.FullTextMap,
    unsynchronized_lyrics: id3v2_data.FullTextMap,

    pub fn init(allocator: Allocator, header: id3v2.ID3Header, start_offset: usize, end_offset: usize) ID3v2Metadata {
        return .{
            .metadata = Metadata.initWithOffsets(allocator, start_offset, end_offset),
            .header = header,
            .comments = id3v2_data.FullTextMap.init(allocator),
            .unsynchronized_lyrics = id3v2_data.FullTextMap.init(allocator),
        };
    }

    pub fn deinit(self: *ID3v2Metadata) void {
        self.metadata.deinit();
        self.comments.deinit();
        self.unsynchronized_lyrics.deinit();
    }

    pub fn dump(self: ID3v2Metadata) void {
        self.metadata.map.dump();
        if (self.comments.entries.items.len > 0) {
            std.debug.print("-- COMM --\n", .{});
            self.comments.dump();
        }
        if (self.unsynchronized_lyrics.entries.items.len > 0) {
            std.debug.print("-- USLT --\n", .{});
            self.unsynchronized_lyrics.dump();
        }
    }
};

pub const AllAPEMetadata = struct {
    allocator: Allocator,
    tags: []APEMetadata,

    pub fn deinit(self: *AllAPEMetadata) void {
        for (self.tags) |*tag| {
            tag.deinit();
        }
        self.allocator.free(self.tags);
    }
};

pub const APEMetadata = struct {
    metadata: Metadata,
    header_or_footer: ape.APEHeader,

    pub fn init(allocator: Allocator, header_or_footer: ape.APEHeader, start_offset: usize, end_offset: usize) APEMetadata {
        return .{
            .metadata = Metadata.initWithOffsets(allocator, start_offset, end_offset),
            .header_or_footer = header_or_footer,
        };
    }

    pub fn deinit(self: *APEMetadata) void {
        self.metadata.deinit();
    }
};

pub const Metadata = struct {
    map: MetadataMap,
    start_offset: usize,
    end_offset: usize,

    pub fn init(allocator: Allocator) Metadata {
        return Metadata.initWithOffsets(allocator, undefined, undefined);
    }

    pub fn initWithOffsets(allocator: Allocator, start_offset: usize, end_offset: usize) Metadata {
        return .{
            .map = MetadataMap.init(allocator),
            .start_offset = start_offset,
            .end_offset = end_offset,
        };
    }

    pub fn deinit(self: *Metadata) void {
        self.map.deinit();
    }
};

/// HashMap-like but can handle multiple values with the same key.
pub const MetadataMap = struct {
    allocator: Allocator,
    entries: EntryList,
    name_to_indexes: NameToIndexesMap,

    pub const Entry = struct {
        name: []const u8,
        value: []const u8,
    };
    const EntryList = std.ArrayListUnmanaged(Entry);
    const IndexList = std.ArrayListUnmanaged(usize);
    const NameToIndexesMap = std.StringHashMapUnmanaged(IndexList);

    pub fn init(allocator: Allocator) MetadataMap {
        return .{
            .allocator = allocator,
            .entries = .{},
            .name_to_indexes = .{},
        };
    }

    pub fn deinit(self: *MetadataMap) void {
        for (self.entries.items) |item| {
            self.allocator.free(item.value);
        }
        self.entries.deinit(self.allocator);

        var map_it = self.name_to_indexes.iterator();
        while (map_it.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
            self.allocator.free(entry.key_ptr.*);
        }
        self.name_to_indexes.deinit(self.allocator);
    }

    pub fn getOrPutEntry(self: *MetadataMap, name: []const u8) !NameToIndexesMap.GetOrPutResult {
        return blk: {
            if (self.name_to_indexes.getEntry(name)) |entry| {
                break :blk NameToIndexesMap.GetOrPutResult{
                    .key_ptr = entry.key_ptr,
                    .value_ptr = entry.value_ptr,
                    .found_existing = true,
                };
            } else {
                var name_dup = try self.allocator.dupe(u8, name);
                errdefer self.allocator.free(name_dup);

                const entry = try self.name_to_indexes.getOrPutValue(self.allocator, name_dup, IndexList{});
                break :blk NameToIndexesMap.GetOrPutResult{
                    .key_ptr = entry.key_ptr,
                    .value_ptr = entry.value_ptr,
                    .found_existing = false,
                };
            }
        };
    }

    pub fn getOrPutEntryNoDupe(self: *MetadataMap, name: []const u8) !NameToIndexesMap.GetOrPutResult {
        return blk: {
            if (self.name_to_indexes.getEntry(name)) |entry| {
                break :blk NameToIndexesMap.GetOrPutResult{
                    .key_ptr = entry.key_ptr,
                    .value_ptr = entry.value_ptr,
                    .found_existing = true,
                };
            } else {
                const entry = try self.name_to_indexes.getOrPutValue(self.allocator, name, IndexList{});
                break :blk NameToIndexesMap.GetOrPutResult{
                    .key_ptr = entry.key_ptr,
                    .value_ptr = entry.value_ptr,
                    .found_existing = false,
                };
            }
        };
    }

    pub fn appendToEntry(self: *MetadataMap, entry: NameToIndexesMap.GetOrPutResult, value: []const u8) !void {
        const entry_index = entry_index: {
            const value_dup = try self.allocator.dupe(u8, value);
            errdefer self.allocator.free(value_dup);

            const entry_index = self.entries.items.len;
            try self.entries.append(self.allocator, Entry{
                .name = entry.key_ptr.*,
                .value = value_dup,
            });
            break :entry_index entry_index;
        };
        try entry.value_ptr.append(self.allocator, entry_index);
    }

    pub fn appendToEntryNoDupe(self: *MetadataMap, entry: NameToIndexesMap.GetOrPutResult, value: []const u8) !void {
        const entry_index = entry_index: {
            const entry_index = self.entries.items.len;
            try self.entries.append(self.allocator, Entry{
                .name = entry.key_ptr.*,
                .value = value,
            });
            break :entry_index entry_index;
        };
        try entry.value_ptr.append(self.allocator, entry_index);
    }

    pub fn put(self: *MetadataMap, name: []const u8, value: []const u8) !void {
        const indexes_entry = try self.getOrPutEntry(name);
        try self.appendToEntry(indexes_entry, value);
    }

    pub fn putNoDupe(self: *MetadataMap, name: []const u8, value: []const u8) !void {
        const indexes_entry = try self.getOrPutEntryNoDupe(name);
        try self.appendToEntryNoDupe(indexes_entry, value);
    }

    pub fn putOrReplaceFirst(self: *MetadataMap, name: []const u8, new_value: []const u8) !void {
        const maybe_entry_index_list = self.name_to_indexes.getPtr(name);
        if (maybe_entry_index_list == null or maybe_entry_index_list.?.items.len == 0) {
            return self.put(name, new_value);
        }
        const entry_index_list = maybe_entry_index_list.?;

        const entry_index = entry_index_list.items[0];
        var entry = &self.entries.items[entry_index];

        const new_value_dup = try self.allocator.dupe(u8, new_value);
        self.allocator.free(entry.value);
        entry.value = new_value_dup;
    }

    pub fn contains(self: *MetadataMap, name: []const u8) bool {
        return self.name_to_indexes.contains(name);
    }

    pub fn valueCount(self: *MetadataMap, name: []const u8) ?usize {
        const entry_index_list = (self.name_to_indexes.getPtr(name)) orelse return null;
        return entry_index_list.items.len;
    }

    pub fn getAllAlloc(self: *MetadataMap, allocator: Allocator, name: []const u8) !?[][]const u8 {
        const entry_index_list = (self.name_to_indexes.getPtr(name)) orelse return null;
        if (entry_index_list.items.len == 0) return null;

        const buf = try allocator.alloc([]const u8, entry_index_list.items.len);
        for (entry_index_list.items) |entry_index, i| {
            buf[i] = self.entries.items[entry_index].value;
        }
        return buf;
    }

    pub fn getFirst(self: *MetadataMap, name: []const u8) ?[]const u8 {
        const entry_index_list = (self.name_to_indexes.getPtr(name)) orelse return null;
        if (entry_index_list.items.len == 0) return null;

        const entry_index = entry_index_list.items[0];
        return self.entries.items[entry_index].value;
    }

    pub fn getJoinedAlloc(self: *MetadataMap, allocator: Allocator, name: []const u8, separator: []const u8) !?[]u8 {
        const entry_index_list = (self.name_to_indexes.getPtr(name)) orelse return null;
        if (entry_index_list.items.len == 0) return null;
        if (entry_index_list.items.len == 1) {
            const entry_index = entry_index_list.items[0];
            const duped_value = try allocator.dupe(u8, self.entries.items[entry_index].value);
            return duped_value;
        } else {
            var values = try allocator.alloc([]const u8, entry_index_list.items.len);
            defer allocator.free(values);

            for (entry_index_list.items) |entry_index, i| {
                values[i] = self.entries.items[entry_index].value;
            }

            const joined = try std.mem.join(allocator, separator, values);
            return joined;
        }
    }

    pub fn dump(metadata: *const MetadataMap) void {
        for (metadata.entries.items) |entry| {
            std.debug.print("{s}={s}\n", .{ fmtUtf8SliceEscapeUpper(entry.name), fmtUtf8SliceEscapeUpper(entry.value) });
        }
    }
};

test "metadata map" {
    var allocator = std.testing.allocator;
    var metadata = MetadataMap.init(allocator);
    defer metadata.deinit();

    try std.testing.expect(!metadata.contains("date"));

    try metadata.put("date", "2018");
    try metadata.put("date", "2018-04-25");

    const joined_date = (try metadata.getJoinedAlloc(allocator, "date", ";")).?;
    defer allocator.free(joined_date);

    try std.testing.expectEqualStrings("2018;2018-04-25", joined_date);
    try std.testing.expect(metadata.contains("date"));
    try std.testing.expect(!metadata.contains("missing"));

    try metadata.putOrReplaceFirst("date", "2019");
    const new_date = metadata.getFirst("date").?;
    try std.testing.expectEqualStrings("2019", new_date);
}

test "AllMetadata.getXOfType" {
    var allocator = std.testing.allocator;
    var metadata_buf = std.ArrayList(TypedMetadata).init(allocator);
    defer metadata_buf.deinit();

    try metadata_buf.append(TypedMetadata{ .id3v2 = ID3v2Metadata{
        .metadata = undefined,
        .header = undefined,
        .comments = undefined,
        .unsynchronized_lyrics = undefined,
    } });
    try metadata_buf.append(TypedMetadata{ .id3v2 = ID3v2Metadata{
        .metadata = undefined,
        .header = undefined,
        .comments = undefined,
        .unsynchronized_lyrics = undefined,
    } });
    try metadata_buf.append(TypedMetadata{ .flac = undefined });
    try metadata_buf.append(TypedMetadata{ .id3v1 = undefined });
    try metadata_buf.append(TypedMetadata{ .id3v1 = undefined });

    var all = AllMetadata{
        .allocator = allocator,
        .tags = metadata_buf.toOwnedSlice(),
    };
    defer all.deinit();

    const all_id3v2 = try all.getAllMetadataOfType(allocator, .id3v2);
    defer allocator.free(all_id3v2);
    try std.testing.expectEqual(@as(usize, 2), all_id3v2.len);

    const first_id3v2 = all.getFirstMetadataOfType(.id3v2);
    try std.testing.expect(first_id3v2 == &all.tags[0].id3v2);

    const last_id3v2 = all.getLastMetadataOfType(.id3v2).?;
    try std.testing.expect(last_id3v2 == &all.tags[1].id3v2);

    const last_id3v1 = all.getLastMetadataOfType(.id3v1).?;
    try std.testing.expect(last_id3v1 == &all.tags[all.tags.len - 1].id3v1);

    try std.testing.expect(null == all.getFirstMetadataOfType(.vorbis));
}
