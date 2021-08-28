const std = @import("std");
const id3v2 = @import("id3v2.zig");
const id3v1 = @import("id3v1.zig");
const flac = @import("flac.zig");
const Allocator = std.mem.Allocator;
const fmtUtf8SliceEscapeUpper = @import("util.zig").fmtUtf8SliceEscapeUpper;
const BufferedStreamSource = @import("buffered_stream_source.zig").BufferedStreamSource;

pub fn readAll(allocator: *Allocator, stream_source: *std.io.StreamSource) !AllMetadata {
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

    var all_id3v2_metadata: ?[]ID3v2Metadata = id3v2.read(allocator, reader, seekable_stream) catch |e| switch (e) {
        error.OutOfMemory => |err| return err,
        else => null,
    };
    var id3v1_metadata: ?Metadata = id3v1.read(allocator, reader, seekable_stream) catch |e| switch (e) {
        error.OutOfMemory => |err| return err,
        else => null,
    };
    // TODO: this isnt correct for id3v2 tags at the end of a file or when a SEEK frame is used
    var pos_after_last_id3v2: usize = blk: {
        if (all_id3v2_metadata) |meta_slice| {
            if (meta_slice.len > 0) {
                var last_offset = meta_slice[meta_slice.len - 1].metadata.end_offset;
                break :blk last_offset;
            }
        }
        break :blk 0;
    };
    try seekable_stream.seekTo(pos_after_last_id3v2);
    var flac_metadata: ?Metadata = flac.read(allocator, reader, seekable_stream) catch |e| switch (e) {
        error.OutOfMemory => |err| return err,
        else => null,
    };

    return AllMetadata{
        .allocator = allocator,
        .all_id3v2 = all_id3v2_metadata,
        .id3v1 = id3v1_metadata,
        .flac = flac_metadata,
    };
}

pub const AllMetadata = struct {
    allocator: *Allocator,
    all_id3v2: ?[]ID3v2Metadata,
    id3v1: ?Metadata,
    // TODO rename? xiph? vorbis?
    flac: ?Metadata,

    pub fn deinit(self: *AllMetadata) void {
        if (self.all_id3v2) |all_id3v2| {
            for (all_id3v2) |*metadata| {
                metadata.deinit();
            }
            self.allocator.free(all_id3v2);
        }
        if (self.id3v1) |*id3v1_metadata| {
            id3v1_metadata.deinit();
        }
        if (self.flac) |*flac_metadata| {
            flac_metadata.deinit();
        }
    }

    pub fn dump(self: *const AllMetadata) void {
        if (self.all_id3v2) |all_id3v2| {
            for (all_id3v2) |*id3v2_meta| {
                std.debug.print("# ID3v2 v2.{d} 0x{x}-0x{x}\n", .{ id3v2_meta.major_version, id3v2_meta.metadata.start_offset, id3v2_meta.metadata.end_offset });
                id3v2_meta.metadata.map.dump();
            }
        }
        if (self.id3v1) |*id3v1_meta| {
            std.debug.print("# ID3v1 0x{x}-0x{x}\n", .{ id3v1_meta.start_offset, id3v1_meta.end_offset });
            id3v1_meta.map.dump();
        }
        if (self.flac) |*flac_meta| {
            std.debug.print("# FLAC 0x{x}-0x{x}\n", .{ flac_meta.start_offset, flac_meta.end_offset });
            flac_meta.map.dump();
        }
    }
};

pub const ID3v2Metadata = struct {
    metadata: Metadata,
    major_version: u8,

    pub fn init(allocator: *Allocator, major_version: u8, start_offset: usize, end_offset: usize) ID3v2Metadata {
        return .{
            .metadata = Metadata.initWithOffsets(allocator, start_offset, end_offset),
            .major_version = major_version,
        };
    }

    pub fn deinit(self: *ID3v2Metadata) void {
        self.metadata.deinit();
    }
};

pub const Metadata = struct {
    map: MetadataMap,
    start_offset: usize,
    end_offset: usize,

    pub fn init(allocator: *Allocator) Metadata {
        return Metadata.initWithOffsets(allocator, undefined, undefined);
    }

    pub fn initWithOffsets(allocator: *Allocator, start_offset: usize, end_offset: usize) Metadata {
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
    allocator: *Allocator,
    entries: EntryList,
    name_to_indexes: NameToIndexesMap,

    pub const Entry = struct {
        name: []const u8,
        value: []const u8,
    };
    const EntryList = std.ArrayListUnmanaged(Entry);
    const IndexList = std.ArrayListUnmanaged(usize);
    const NameToIndexesMap = std.StringHashMapUnmanaged(IndexList);

    pub fn init(allocator: *Allocator) MetadataMap {
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

    pub fn put(self: *MetadataMap, name: []const u8, value: []const u8) !void {
        const indexes_entry = blk: {
            if (self.name_to_indexes.getEntry(name)) |entry| {
                break :blk entry;
            } else {
                var name_dup = try self.allocator.dupe(u8, name);
                const entry = try self.name_to_indexes.getOrPutValue(self.allocator, name_dup, IndexList{});
                break :blk entry;
            }
        };

        const value_dup = try self.allocator.dupe(u8, value);
        const entry_index = self.entries.items.len;
        try self.entries.append(self.allocator, Entry{
            .name = indexes_entry.key_ptr.*,
            .value = value_dup,
        });
        try indexes_entry.value_ptr.append(self.allocator, entry_index);
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

    pub fn getAllAlloc(self: *MetadataMap, allocator: *Allocator, name: []const u8) !?[][]const u8 {
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

    pub fn getJoinedAlloc(self: *MetadataMap, allocator: *Allocator, name: []const u8, separator: []const u8) !?[]u8 {
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

    std.debug.print("{s}\n", .{joined_date});

    try metadata.putOrReplaceFirst("date", "2019");
    const new_date = metadata.getFirst("date").?;
    try std.testing.expectEqualStrings("2019", new_date);

    metadata.dump();
}
