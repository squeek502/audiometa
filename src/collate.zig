const std = @import("std");
const Allocator = std.mem.Allocator;
const metadata_namespace = @import("metadata.zig");
const Metadata = metadata_namespace.Metadata;
const AllMetadata = metadata_namespace.AllMetadata;
const MetadataType = metadata_namespace.MetadataType;
const TypedMetadata = metadata_namespace.TypedMetadata;
const id3v2_data = @import("id3v2_data.zig");
const ziglyph = @import("ziglyph");
const windows1251 = @import("windows1251.zig");
const latin1 = @import("latin1.zig");

pub const num_metadata_types = @typeInfo(MetadataType).Enum.fields.len;

pub const Collator = struct {
    metadata: *AllMetadata,
    allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    prioritization: Prioritization,

    const Self = @This();

    pub fn init(allocator: Allocator, metadata: *AllMetadata, prioritization: Prioritization) Self {
        return Self{
            .metadata = metadata,
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .prioritization = prioritization,
        };
    }

    pub fn deinit(self: *Self) void {
        self.arena.deinit();
    }

    fn addValuesToSet(set: *CollatedTextSet, tag: *TypedMetadata, keys: [num_metadata_types]?[]const u8) !void {
        const key = keys[@enumToInt(std.meta.activeTag(tag.*))] orelse return;
        switch (tag.*) {
            .id3v1 => |*id3v1_meta| {
                if (id3v1_meta.map.getFirst(key)) |value| {
                    try set.put(value);
                }
            },
            .flac => |*flac_meta| {
                var value_it = flac_meta.map.valueIterator(key);
                while (value_it.next()) |value| {
                    try set.put(value);
                }
            },
            .vorbis => |*vorbis_meta| {
                var value_it = vorbis_meta.map.valueIterator(key);
                while (value_it.next()) |value| {
                    try set.put(value);
                }
            },
            .id3v2 => |*id3v2_meta| {
                var value_it = id3v2_meta.metadata.map.valueIterator(key);
                while (value_it.next()) |value| {
                    try set.put(value);
                }
            },
            .ape => |*ape_meta| {
                var value_it = ape_meta.metadata.map.valueIterator(key);
                while (value_it.next()) |value| {
                    try set.put(value);
                }
            },
            .mp4 => |*mp4_meta| {
                var value_it = mp4_meta.map.valueIterator(key);
                while (value_it.next()) |value| {
                    try set.put(value);
                }
            },
        }
    }

    pub fn getValuesFromKeys(self: *Self, keys: [num_metadata_types]?[]const u8) ![][]const u8 {
        var set = CollatedTextSet.init(self.arena.allocator());
        defer set.deinit();

        for (self.prioritization.order) |meta_type| {
            const is_last_resort = self.prioritization.priority(meta_type) == .last_resort;
            if (!is_last_resort or set.count() == 0) {
                var meta_it = self.metadata.metadataOfTypeIterator(meta_type);
                while (meta_it.next()) |meta| {
                    try addValuesToSet(&set, meta, keys);
                }
            }
        }
        return try self.arena.allocator().dupe([]const u8, set.values.items);
    }

    const artist_keys = init: {
        var array = [_]?[]const u8{null} ** num_metadata_types;
        array[@enumToInt(MetadataType.id3v1)] = "artist";
        array[@enumToInt(MetadataType.flac)] = "ARTIST";
        array[@enumToInt(MetadataType.vorbis)] = "ARTIST";
        array[@enumToInt(MetadataType.id3v2)] = "TPE1";
        array[@enumToInt(MetadataType.ape)] = "Artist";
        array[@enumToInt(MetadataType.mp4)] = "\xA9ART";
        break :init array;
    };

    pub fn artists(self: *Self) ![][]const u8 {
        return self.getValuesFromKeys(artist_keys);
    }

    const album_keys = init: {
        var array = [_]?[]const u8{null} ** num_metadata_types;
        array[@enumToInt(MetadataType.id3v1)] = "album";
        array[@enumToInt(MetadataType.flac)] = "ALBUM";
        array[@enumToInt(MetadataType.vorbis)] = "ALBUM";
        array[@enumToInt(MetadataType.id3v2)] = "TALB";
        array[@enumToInt(MetadataType.ape)] = "Album";
        array[@enumToInt(MetadataType.mp4)] = "\xA9alb";
        break :init array;
    };

    pub fn albums(self: *Self) ![][]const u8 {
        return self.getValuesFromKeys(album_keys);
    }
};

pub const Prioritization = struct {
    order: [num_metadata_types]MetadataType,
    priorities: [num_metadata_types]Priority,

    pub const Priority = enum {
        normal,
        last_resort,
    };

    pub fn priority(self: Prioritization, meta_type: MetadataType) Priority {
        return self.priorities[@enumToInt(meta_type)];
    }
};

pub const default_prioritization = Prioritization{
    .order = [_]MetadataType{ .mp4, .flac, .vorbis, .id3v2, .ape, .id3v1 },
    .priorities = init: {
        var priorities = [_]Prioritization.Priority{.normal} ** num_metadata_types;
        priorities[@enumToInt(MetadataType.id3v1)] = .last_resort;
        break :init priorities;
    },
};

test "prioritization last resort" {
    var allocator = std.testing.allocator;
    var metadata_buf = std.ArrayList(TypedMetadata).init(allocator);
    defer metadata_buf.deinit();

    try metadata_buf.append(TypedMetadata{ .id3v2 = .{
        .metadata = Metadata.init(allocator),
        .user_defined = metadata_namespace.MetadataMap.init(allocator),
        .header = undefined,
        .comments = id3v2_data.FullTextMap.init(allocator),
        .unsynchronized_lyrics = id3v2_data.FullTextMap.init(allocator),
    } });
    try metadata_buf.items[0].id3v2.metadata.map.put("TPE1", "test");

    try metadata_buf.append(TypedMetadata{ .id3v1 = Metadata.init(allocator) });
    try metadata_buf.items[1].id3v1.map.put("artist", "ignored");

    var all = AllMetadata{
        .allocator = allocator,
        .tags = metadata_buf.toOwnedSlice(),
    };
    defer all.deinit();

    var collator = Collator.init(allocator, &all, default_prioritization);
    defer collator.deinit();

    const artists = try collator.artists();
    try std.testing.expectEqual(@as(usize, 1), artists.len);
    try std.testing.expectEqualStrings("test", artists[0]);
}

test "prioritization flac > ape" {
    var allocator = std.testing.allocator;
    var metadata_buf = std.ArrayList(TypedMetadata).init(allocator);
    defer metadata_buf.deinit();

    // flac is prioritized over ape, so for duplicate keys the flac casing
    // should end up in the result even if ape comes first in the file

    try metadata_buf.append(TypedMetadata{ .ape = .{
        .metadata = Metadata.init(allocator),
        .header_or_footer = undefined,
    } });
    try metadata_buf.items[0].ape.metadata.map.put("Artist", "FLACcase");

    try metadata_buf.append(TypedMetadata{ .flac = Metadata.init(allocator) });
    try metadata_buf.items[1].flac.map.put("ARTIST", "FlacCase");

    var all = AllMetadata{
        .allocator = allocator,
        .tags = metadata_buf.toOwnedSlice(),
    };
    defer all.deinit();

    var collator = Collator.init(allocator, &all, default_prioritization);
    defer collator.deinit();

    const artists = try collator.artists();
    try std.testing.expectEqual(@as(usize, 1), artists.len);
    try std.testing.expectEqualStrings("FlacCase", artists[0]);
}

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
