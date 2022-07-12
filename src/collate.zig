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
const fields = @import("fields.zig");

pub const Collator = struct {
    metadata: *AllMetadata,
    allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    config: Config,
    tag_indexes_by_priority: []usize,

    const Self = @This();

    pub const Config = struct {
        prioritization: Prioritization = default_prioritization,
        duplicate_tag_strategy: DuplicateTagStrategy = .prioritize_best,

        pub const DuplicateTagStrategy = enum {
            /// Use a heuristic to prioritize the 'best' tag for any tag types with multiple tags,
            /// and fall back to second best, etc.
            ///
            /// TODO: Improve the heuristic; right now it uses largest number of fields in the tag.
            prioritize_best,
            /// Always prioritize the first tag for each tag type, and fall back
            /// to subsequent tags of that type (in file order)
            ///
            /// Note: This is how ffmpeg/libavformat handles duplicate ID3v2 tags.
            prioritize_first,
            /// Only look at the first tag (in file order) for each tag type, ignoring all
            /// duplicate tags entirely.
            ///
            /// Note: This is how TagLib handles duplicate ID3v2 tags.
            ignore_duplicates,
        };
    };

    pub fn init(allocator: Allocator, metadata: *AllMetadata, config: Config) !Self {
        var collator = Self{
            .metadata = metadata,
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .config = config,
            .tag_indexes_by_priority = &[_]usize{},
        };
        switch (config.duplicate_tag_strategy) {
            .prioritize_best => {
                collator.tag_indexes_by_priority = try collator.arena.allocator().alloc(usize, metadata.tags.len);
                determineBestTagPriorities(metadata, config.prioritization, collator.tag_indexes_by_priority);
            },
            .prioritize_first => {
                collator.tag_indexes_by_priority = try collator.arena.allocator().alloc(usize, metadata.tags.len);
                determineFileOrderTagPriorities(metadata, config.prioritization, collator.tag_indexes_by_priority, .include_duplicates);
            },
            .ignore_duplicates => {
                const count_ignoring_duplicates = metadata.countIgnoringDuplicates();
                collator.tag_indexes_by_priority = try collator.arena.allocator().alloc(usize, count_ignoring_duplicates);
                determineFileOrderTagPriorities(metadata, config.prioritization, collator.tag_indexes_by_priority, .ignore_duplicates);
            },
        }
        return collator;
    }

    pub fn deinit(self: *Self) void {
        self.arena.deinit();
    }

    fn determineBestTagPriorities(metadata: *AllMetadata, prioritization: Prioritization, tag_indexes_by_priority: []usize) void {
        var priority_index: usize = 0;
        for (prioritization.order) |metadata_type| {
            const first_index = priority_index;
            var meta_index_it = metadata.metadataOfTypeIndexIterator(metadata_type);
            while (meta_index_it.next()) |meta_index| {
                // For each tag of the current type, we compare backwards with all
                // tags of the same type that have been inserted already and find
                // its insertion point in prioritization order. We then shift things
                // forward as needed in order to insert the current tag into the
                // correct place.
                var insertion_index = priority_index;
                if (priority_index > first_index) {
                    const meta = &metadata.tags[meta_index];
                    var compare_index = priority_index - 1;
                    while (compare_index >= first_index) {
                        const compare_meta_index = tag_indexes_by_priority[compare_index];
                        const compare_meta = &metadata.tags[compare_meta_index];
                        if (compareTagsForPrioritization(meta, compare_meta) == .gt) {
                            insertion_index = compare_index;
                        }
                        if (compare_index == 0) break;
                        compare_index -= 1;
                    }
                    if (insertion_index != priority_index) {
                        var to_shift = tag_indexes_by_priority[insertion_index..priority_index];
                        var dest = tag_indexes_by_priority[insertion_index + 1 .. priority_index + 1];
                        std.mem.copyBackwards(usize, dest, to_shift);
                    }
                }
                tag_indexes_by_priority[insertion_index] = meta_index;
                priority_index += 1;
            }
        }
        std.debug.assert(priority_index == tag_indexes_by_priority.len);
    }

    fn determineFileOrderTagPriorities(metadata: *AllMetadata, prioritization: Prioritization, tag_indexes_by_priority: []usize, duplicate_handling: enum { include_duplicates, ignore_duplicates }) void {
        var priority_index: usize = 0;
        for (prioritization.order) |metadata_type| {
            var meta_index_it = metadata.metadataOfTypeIndexIterator(metadata_type);
            while (meta_index_it.next()) |meta_index| {
                tag_indexes_by_priority[priority_index] = meta_index;
                priority_index += 1;
                if (duplicate_handling == .ignore_duplicates) {
                    break;
                }
            }
        }
        std.debug.assert(priority_index == tag_indexes_by_priority.len);
    }

    fn compareTagsForPrioritization(a: *const TypedMetadata, b: *const TypedMetadata) std.math.Order {
        const a_count = fieldCountForPrioritization(a);
        const b_count = fieldCountForPrioritization(b);
        return std.math.order(a_count, b_count);
    }

    fn fieldCountForPrioritization(meta: *const TypedMetadata) usize {
        switch (meta.*) {
            .id3v1 => return meta.id3v1.map.entries.items.len,
            .id3v2 => return meta.id3v2.metadata.map.entries.items.len,
            .flac => return meta.flac.map.entries.items.len,
            .vorbis => return meta.vorbis.map.entries.items.len,
            .ape => return meta.ape.metadata.map.entries.items.len,
            .mp4 => return meta.mp4.map.entries.items.len,
        }
    }

    /// Returns a single value gotten from the tag with the highest priority,
    /// or null if no values exist for the relevant keys in any of the tags.
    pub fn getPrioritizedValue(self: *Self, keys: fields.NameLookups) !?[]const u8 {
        for (self.tag_indexes_by_priority) |tag_index| {
            const tag = &self.metadata.tags[tag_index];
            const tag_keys = keys[@enumToInt(std.meta.activeTag(tag.*))] orelse continue;
            inner: for (tag_keys) |key| {
                const value = tag.getMetadata().map.getFirst(key) orelse continue :inner;
                const ameliorated_value = (try ameliorateCanonical(self.arena.allocator(), value)) orelse continue :inner;
                return ameliorated_value;
            }
        }
        return null;
    }

    fn addValuesToSet(set: *CollatedTextSet, tag: *TypedMetadata, keys: fields.NameLookups) !void {
        const tag_keys = keys[@enumToInt(std.meta.activeTag(tag.*))] orelse return;
        for (tag_keys) |key| {
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
    }

    pub fn getValuesFromKeys(self: *Self, keys: fields.NameLookups) ![][]const u8 {
        var set = CollatedTextSet.init(self.arena.allocator());
        defer set.deinit();

        for (self.config.prioritization.order) |meta_type| {
            const is_last_resort = self.config.prioritization.priority(meta_type) == .last_resort;
            if (!is_last_resort or set.count() == 0) {
                var meta_it = self.metadata.metadataOfTypeIterator(meta_type);
                while (meta_it.next()) |meta| {
                    try addValuesToSet(&set, meta, keys);
                }
            }
        }
        return try self.arena.allocator().dupe([]const u8, set.values.items);
    }

    pub fn artists(self: *Self) ![][]const u8 {
        return self.getValuesFromKeys(fields.artist);
    }

    /// Using this function is discouraged, as it may return incorrect results
    /// when the metadata contains multiple artists. It is recommended to
    /// use `artists` instead to ensure that multiple values can be handled.
    /// TODO: Recommend `albumArtist` as an alternative for getting a singular 'artist' value.
    pub fn artist(self: *Self) !?[]const u8 {
        return self.getPrioritizedValue(fields.artist);
    }

    pub fn albums(self: *Self) ![][]const u8 {
        return self.getValuesFromKeys(fields.album);
    }

    pub fn album(self: *Self) !?[]const u8 {
        return self.getPrioritizedValue(fields.album);
    }

    pub fn titles(self: *Self) ![][]const u8 {
        return self.getValuesFromKeys(fields.title);
    }

    pub fn title(self: *Self) !?[]const u8 {
        return self.getPrioritizedValue(fields.title);
    }

    pub const TrackNumber = struct {
        number: ?u32,
        total: ?u32,
    };

    pub fn trackNumber(self: *Self) !TrackNumber {
        const maybe_track_number_as_string = try self.getPrioritizedValue(fields.track_number);
        var track_number = TrackNumber{ .number = null, .total = null };
        from_track_number: {
            var as_string = maybe_track_number_as_string orelse break :from_track_number;
            track_number = splitTrackNumber(as_string);
        }

        if (track_number.total == null) {
            const maybe_track_total_as_string = try self.getPrioritizedValue(fields.track_total);
            from_track_total: {
                var as_string = maybe_track_total_as_string orelse break :from_track_total;
                track_number.total = parseNumberDisallowingZero(u32, as_string);
            }
        }

        return track_number;
    }

    fn parseNumberDisallowingZero(comptime T: type, number_as_string: ?[]const u8) ?T {
        const number: ?T = if (number_as_string != null)
            (std.fmt.parseUnsigned(u32, number_as_string.?, 10) catch null)
        else
            null;
        if (number != null and number.? == 0) return null;
        return number;
    }

    fn splitTrackNumber(as_string: []const u8) TrackNumber {
        var track_number: TrackNumber = undefined;
        var split_it = std.mem.split(u8, as_string, "/");

        const number_str = split_it.next();
        track_number.number = parseNumberDisallowingZero(u32, number_str);

        const total_str = split_it.next();
        track_number.total = parseNumberDisallowingZero(u32, total_str);

        return track_number;
    }

    pub const TrackNumbers = struct {
        numbers: []u32,
        totals: []u32,
    };

    pub fn trackNumbers(self: *Self) !TrackNumbers {
        var track_number_set = std.AutoArrayHashMapUnmanaged(u32, void){};
        defer track_number_set.deinit(self.allocator);
        var track_total_set = std.AutoArrayHashMapUnmanaged(u32, void){};
        defer track_total_set.deinit(self.allocator);

        for (self.config.prioritization.order) |meta_type| {
            const is_last_resort = self.config.prioritization.priority(meta_type) == .last_resort;

            var meta_it = self.metadata.metadataOfTypeIterator(meta_type);
            while (meta_it.next()) |meta| {
                track_numbers: {
                    if (is_last_resort and track_number_set.count() != 0) break :track_numbers;

                    const tag_keys = fields.track_number[@enumToInt(meta_type)] orelse break :track_numbers;
                    for (tag_keys) |key| {
                        var value_it = meta.getMetadata().map.valueIterator(key);
                        while (value_it.next()) |track_number_as_string| {
                            const track_number = splitTrackNumber(track_number_as_string);
                            if (track_number.number) |number| {
                                try track_number_set.put(self.allocator, number, {});
                            }
                            if (track_number.total) |total| {
                                try track_total_set.put(self.allocator, total, {});
                            }
                        }
                    }
                }
                track_totals: {
                    if (is_last_resort and track_total_set.count() != 0) break :track_totals;

                    const tag_keys = fields.track_total[@enumToInt(meta_type)] orelse break :track_totals;
                    for (tag_keys) |key| {
                        var value_it = meta.getMetadata().map.valueIterator(key);
                        while (value_it.next()) |track_total_as_string| {
                            const maybe_total: ?u32 = parseNumberDisallowingZero(u32, track_total_as_string);
                            if (maybe_total) |total| {
                                try track_total_set.put(self.allocator, total, {});
                            }
                        }
                    }
                }
            }
        }

        var numbers = try self.arena.allocator().dupe(u32, track_number_set.keys());
        var totals = try self.arena.allocator().dupe(u32, track_total_set.keys());

        return TrackNumbers{
            .numbers = numbers,
            .totals = totals,
        };
    }
};

pub const Prioritization = struct {
    order: [MetadataType.num_types]MetadataType,
    priorities: [MetadataType.num_types]Priority,

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
        var priorities = [_]Prioritization.Priority{.normal} ** MetadataType.num_types;
        priorities[@enumToInt(MetadataType.id3v1)] = .last_resort;
        break :init priorities;
    },
};

test "id3v2.2 frames work" {
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
    try metadata_buf.items[0].id3v2.metadata.map.put("TP1", "test");

    var all = AllMetadata{
        .allocator = allocator,
        .tags = metadata_buf.toOwnedSlice(),
    };
    defer all.deinit();

    var collator = try Collator.init(allocator, &all, .{});
    defer collator.deinit();

    const artists = try collator.artists();
    try std.testing.expectEqual(@as(usize, 1), artists.len);
    try std.testing.expectEqualStrings("test", artists[0]);
}

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

    var collator = try Collator.init(allocator, &all, .{});
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

    var collator = try Collator.init(allocator, &all, .{});
    defer collator.deinit();

    const artists = try collator.artists();
    try std.testing.expectEqual(@as(usize, 1), artists.len);
    try std.testing.expectEqualStrings("FlacCase", artists[0]);
}

test "prioritize_best for single values" {
    var allocator = std.testing.allocator;
    var metadata_buf = std.ArrayList(TypedMetadata).init(allocator);
    defer metadata_buf.deinit();

    try metadata_buf.append(TypedMetadata{ .ape = .{
        .metadata = Metadata.init(allocator),
        .header_or_footer = undefined,
    } });
    try metadata_buf.items[0].ape.metadata.map.put("Album", "ape album");

    try metadata_buf.append(TypedMetadata{ .flac = Metadata.init(allocator) });
    try metadata_buf.items[1].flac.map.put("ALBUM", "bad album");

    try metadata_buf.append(TypedMetadata{ .flac = Metadata.init(allocator) });
    try metadata_buf.items[2].flac.map.put("ALBUM", "good album");
    try metadata_buf.items[2].flac.map.put("ARTIST", "artist");

    try metadata_buf.append(TypedMetadata{ .flac = Metadata.init(allocator) });
    try metadata_buf.items[3].flac.map.put("ALBUM", "best album");
    try metadata_buf.items[3].flac.map.put("ARTIST", "artist");
    try metadata_buf.items[3].flac.map.put("TITLE", "song");

    var all = AllMetadata{
        .allocator = allocator,
        .tags = metadata_buf.toOwnedSlice(),
    };
    defer all.deinit();

    var collator = try Collator.init(allocator, &all, .{
        .duplicate_tag_strategy = .prioritize_best,
    });
    defer collator.deinit();

    const album = try collator.album();
    try std.testing.expectEqualStrings("best album", album.?);
}

test "prioritize_first for single values" {
    var allocator = std.testing.allocator;
    var metadata_buf = std.ArrayList(TypedMetadata).init(allocator);
    defer metadata_buf.deinit();

    try metadata_buf.append(TypedMetadata{ .ape = .{
        .metadata = Metadata.init(allocator),
        .header_or_footer = undefined,
    } });
    try metadata_buf.items[0].ape.metadata.map.put("Album", "ape album");

    try metadata_buf.append(TypedMetadata{ .flac = Metadata.init(allocator) });
    try metadata_buf.items[1].flac.map.put("ALBUM", "first album");

    try metadata_buf.append(TypedMetadata{ .flac = Metadata.init(allocator) });
    try metadata_buf.items[2].flac.map.put("ALBUM", "second album");
    try metadata_buf.items[2].flac.map.put("TITLE", "title  "); // extra spaces at the end to test trimming

    var all = AllMetadata{
        .allocator = allocator,
        .tags = metadata_buf.toOwnedSlice(),
    };
    defer all.deinit();

    var collator = try Collator.init(allocator, &all, .{
        .duplicate_tag_strategy = .prioritize_first,
    });
    defer collator.deinit();

    const album = try collator.album();
    try std.testing.expectEqualStrings("first album", album.?);

    // should get the title from the second FLAC tag
    const title = try collator.title();
    try std.testing.expectEqualStrings("title", title.?);
}

test "ignore_duplicates for single values" {
    var allocator = std.testing.allocator;
    var metadata_buf = std.ArrayList(TypedMetadata).init(allocator);
    defer metadata_buf.deinit();

    try metadata_buf.append(TypedMetadata{ .ape = .{
        .metadata = Metadata.init(allocator),
        .header_or_footer = undefined,
    } });
    try metadata_buf.items[0].ape.metadata.map.put("Album", "ape album");

    try metadata_buf.append(TypedMetadata{ .flac = Metadata.init(allocator) });
    try metadata_buf.items[1].flac.map.put("ALBUM", "first album");

    try metadata_buf.append(TypedMetadata{ .flac = Metadata.init(allocator) });
    try metadata_buf.items[2].flac.map.put("ALBUM", "second album");
    try metadata_buf.items[2].flac.map.put("TITLE", "title");

    var all = AllMetadata{
        .allocator = allocator,
        .tags = metadata_buf.toOwnedSlice(),
    };
    defer all.deinit();

    var collator = try Collator.init(allocator, &all, .{
        .duplicate_tag_strategy = .ignore_duplicates,
    });
    defer collator.deinit();

    const album = try collator.album();
    try std.testing.expectEqualStrings("first album", album.?);

    // should ignore the second FLAC tag, so shouldn't find a title
    const title = try collator.title();
    try std.testing.expect(title == null);
}

test "track numbers" {
    var allocator = std.testing.allocator;
    var metadata_buf = std.ArrayList(TypedMetadata).init(allocator);
    defer metadata_buf.deinit();

    try metadata_buf.append(TypedMetadata{ .ape = .{
        .metadata = Metadata.init(allocator),
        .header_or_footer = undefined,
    } });
    try metadata_buf.items[0].ape.metadata.map.put("Track", "5/15");

    try metadata_buf.append(TypedMetadata{ .flac = Metadata.init(allocator) });
    try metadata_buf.items[1].flac.map.put("TRACKNUMBER", "1");

    try metadata_buf.append(TypedMetadata{ .flac = Metadata.init(allocator) });
    try metadata_buf.items[2].flac.map.put("TRACKTOTAL", "5");
    try metadata_buf.items[2].flac.map.put("TRACKTOTAL", "0"); // should be ignored
    try metadata_buf.items[2].flac.map.put("TRACKNUMBER", "5");
    try metadata_buf.items[2].flac.map.put("TRACKNUMBER", "0"); // should be ignored

    var all = AllMetadata{
        .allocator = allocator,
        .tags = metadata_buf.toOwnedSlice(),
    };
    defer all.deinit();

    var collator = try Collator.init(allocator, &all, .{
        .duplicate_tag_strategy = .prioritize_first,
    });
    defer collator.deinit();

    const track_numbers = try collator.trackNumbers();
    try std.testing.expectEqual(@as(usize, 2), track_numbers.numbers.len);
    try std.testing.expectEqual(@as(u32, 1), track_numbers.numbers[0]);
    try std.testing.expectEqual(@as(u32, 5), track_numbers.numbers[1]);

    try std.testing.expectEqual(@as(usize, 2), track_numbers.totals.len);
    try std.testing.expectEqual(@as(u32, 5), track_numbers.totals[0]);
    try std.testing.expectEqual(@as(u32, 15), track_numbers.totals[1]);
}

/// Function that:
/// - Trims spaces and NUL from both sides of inputs
/// - Converts inputs to inferred character encodings (e.g. Windows-1251)
///
/// Returns null if the ameliorated value becomes empty.
///
/// Note: Return value may or may not be allocated by the allocator, this API basically
///       assumes that you pass an arena allocator.
pub fn ameliorateCanonical(arena: Allocator, value: []const u8) !?[]const u8 {
    const trimmed = std.mem.trim(u8, value, " \x00");
    if (trimmed.len == 0) return null;

    var translated: ?[]u8 = null;
    if (windows1251.couldUtf8BeWindows1251(trimmed)) {
        translated = windows1251.windows1251AsUtf8ToUtf8Alloc(arena, trimmed) catch |err| switch (err) {
            error.InvalidWindows1251Character => unreachable,
            error.OutOfMemory => return error.OutOfMemory,
        };
    }
    return translated orelse trimmed;
}

test "ameliorateCanonical" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();

    try std.testing.expectEqual(@as(?[]const u8, null), try ameliorateCanonical(arena, " \x00 "));
    try std.testing.expectEqualStrings("trimmed", (try ameliorateCanonical(arena, "trimmed \x00")).?);
    // Note: the Latin-1 bytes here are "\xC0\xEF\xEE\xF1\xF2\xF0\xEE\xF4"
    try std.testing.expectEqualStrings("Апостроф", (try ameliorateCanonical(arena, "Àïîñòðîô")).?);
}

/// Set that:
/// - Runs the inputs through ameliorateCanonical
/// - De-duplicates via UTF-8 normalization and case normalization
/// - Ignores empty values
///
/// Canonical values in the set are stored in an ArrayList
///
/// TODO: Maybe startsWith detection of some kind (but this might lead to false positives)
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
        const ameliorated_canonical = (try ameliorateCanonical(self.arena, value)) orelse return;
        const lowered = try ziglyph.toCaseFoldStr(self.arena, ameliorated_canonical);

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
            try self.values.append(self.arena, ameliorated_canonical);
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
