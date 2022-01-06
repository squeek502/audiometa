const std = @import("std");
const Allocator = std.mem.Allocator;
const AllMetadata = @import("metadata.zig").AllMetadata;

pub const Collator = struct {
    metadata: *AllMetadata,
    allocator: Allocator,
    arena: std.heap.ArenaAllocator,

    const Self = @This();

    pub fn init(allocator: Allocator, metadata: *AllMetadata) Self {
        return Self{
            .metadata = metadata,
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.arena.deinit();
    }

    pub fn artists(self: *Self) ![][]const u8 {
        var artist_set = CollatedTextSet.init(self.arena.allocator());
        defer artist_set.deinit();

        for (self.metadata.tags) |*tag| {
            switch (tag.*) {
                .id3v1 => {},
                .flac => |*flac_meta| {
                    var artist_it = flac_meta.map.valueIterator("ARTIST");
                    while (artist_it.next()) |artist| {
                        try artist_set.put(artist);
                    }
                },
                .vorbis => |*vorbis_meta| {
                    var artist_it = vorbis_meta.map.valueIterator("ARTIST");
                    while (artist_it.next()) |artist| {
                        try artist_set.put(artist);
                    }
                },
                .id3v2 => |*id3v2_meta| {
                    var artist_it = id3v2_meta.metadata.map.valueIterator("TPE1");
                    while (artist_it.next()) |artist| {
                        try artist_set.put(artist);
                    }
                },
                .ape => |*ape_meta| {
                    var artist_it = ape_meta.metadata.map.valueIterator("Artist");
                    while (artist_it.next()) |artist| {
                        try artist_set.put(artist);
                    }
                },
            }
        }

        // id3v1 is a last resort
        if (artist_set.count() == 0) {
            if (self.metadata.getLastMetadataOfType(.id3v1)) |id3v1_meta| {
                if (id3v1_meta.map.getFirst("artist")) |artist| {
                    try artist_set.put(artist);
                }
            }
        }

        return try self.arena.allocator().dupe([]const u8, artist_set.values.items);
    }
};

// TODO: Some sort of CollatedSet that does:
//       Trimming, empty value detection, case-insensitivity,
//       maybe startsWith detection
const CollatedTextSet = struct {
    values: std.ArrayListUnmanaged([]const u8),
    // TODO: UTF-8 normalization, and/or a comparison function
    // that does proper UTF-8 case-insensitive comparisons
    normalized_set: std.StringArrayHashMapUnmanaged(usize),
    arena: Allocator,

    const Self = @This();

    /// Allocator must be an arena that will get cleaned up outside of
    /// this struct (this struct's deinit will not handle cleaning up the arena)
    pub fn init(arena: Allocator) Self {
        return .{
            .values = std.ArrayListUnmanaged([]const u8){},
            .normalized_set = std.StringArrayHashMapUnmanaged(usize){},
            .arena = arena,
        };
    }

    pub fn deinit(self: *Self) void {
        // TODO: If this uses an arena, this isn't necessary
        self.values.deinit(self.arena);
        self.normalized_set.deinit(self.arena);
    }

    pub fn put(self: *Self, value: []const u8) !void {
        const trimmed = std.mem.trim(u8, value, " ");
        if (trimmed.len != 0) {
            // TODO: this isn't actually ascii, need UTF-8 lowering/normalizing
            const normalized = try std.ascii.allocLowerString(self.arena, trimmed);
            const result = try self.normalized_set.getOrPut(self.arena, normalized);
            if (!result.found_existing) {
                const index = self.values.items.len;
                try self.values.append(self.arena, trimmed);
                result.value_ptr.* = index;
            }
        }
    }

    pub fn count(self: Self) usize {
        return self.values.items.len;
    }
};
