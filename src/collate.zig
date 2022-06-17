const std = @import("std");
const Allocator = std.mem.Allocator;
const AllMetadata = @import("metadata.zig").AllMetadata;
const ziglyph = @import("ziglyph");
const windows1251 = @import("windows1251.zig");
const latin1 = @import("latin1.zig");

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
    // TODO: Maybe do case-insensitivity/normalization during
    //       hash/eql instead
    normalized_set: std.StringHashMapUnmanaged(usize),
    arena: Allocator,

    const Self = @This();

    /// Allocator must be an arena that will get cleaned up outside of
    /// this struct (this struct's deinit will not handle cleaning up the arena)
    pub fn init(arena: Allocator) Self {
        return .{
            .values = std.ArrayListUnmanaged([]const u8){},
            .normalized_set = std.StringHashMapUnmanaged(usize){},
            .arena = arena,
        };
    }

    pub fn deinit(self: *Self) void {
        // TODO: If this uses an arena, this isn't necessary
        self.values.deinit(self.arena);
        self.normalized_set.deinit(self.arena);
    }

    pub fn put(self: *Self, value: []const u8) !void {
        const trimmed = std.mem.trim(u8, value, " \x00");
        if (trimmed.len == 0) return;

        var translated: ?[]u8 = null;
        if (latin1.isUtf8AllLatin1(trimmed) and windows1251.couldBeWindows1251(trimmed)) {
            const extended_ascii_str = try latin1.utf8ToLatin1Alloc(self.arena, trimmed);
            translated = try windows1251.windows1251ToUtf8Alloc(self.arena, extended_ascii_str);
        }
        const lowered = try ziglyph.toCaseFoldStr(self.arena, translated orelse trimmed);

        var normalizer = try ziglyph.Normalizer.init(self.arena);
        defer normalizer.deinit();

        const normalized = try normalizer.normalizeTo(.canon, lowered);
        const result = try self.normalized_set.getOrPut(self.arena, normalized);
        if (!result.found_existing) {
            // We need to dupe the normalized version of the string when
            // storing it because ziglyph.Normalizer creates an arena and
            // destroys the arena on normalizer.deinit(), which would
            // destroy the normalized version of the string that was
            // used as the key for the normalized_set.
            result.key_ptr.* = try self.arena.dupe(u8, normalized);

            const index = self.values.items.len;
            try self.values.append(self.arena, translated orelse trimmed);
            result.value_ptr.* = index;
        }
    }

    pub fn count(self: Self) usize {
        return self.values.items.len;
    }
};

test "CollatedTextSet utf-8 case-insensitivity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var set = CollatedTextSet.init(arena.allocator());
    defer set.deinit();

    try set.put("something");
    try set.put("someTHING");

    try std.testing.expectEqual(@as(usize, 1), set.count());

    try set.put("cyriLLic И");
    try set.put("cyrillic и");

    try std.testing.expectEqual(@as(usize, 2), set.count());
}

test "CollatedTextSet utf-8 normalization" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var set = CollatedTextSet.init(arena.allocator());
    defer set.deinit();

    try set.put("foé");
    try set.put("foe\u{0301}");

    try std.testing.expectEqual(@as(usize, 1), set.count());
}

test "CollatedTextSet windows-1251 detection" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var set = CollatedTextSet.init(arena.allocator());
    defer set.deinit();

    // Note: the Latin-1 bytes here are "\xC0\xEF\xEE\xF1\xF2\xF0\xEE\xF4"
    try set.put("Àïîñòðîô");

    try std.testing.expectEqualStrings("Апостроф", set.values.items[0]);

    try set.put("АПОСТРОФ");
    try std.testing.expectEqual(@as(usize, 1), set.count());
}
