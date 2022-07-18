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
const fields = @import("fields.zig");

pub const Collator = struct {
    metadata: *AllMetadata,
    allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    config: Config,
    tag_indexes_by_priority: []usize,
    normalizer: ?*ziglyph.Normalizer,

    const Self = @This();

    pub const Config = struct {
        prioritization: Prioritization = default_prioritization,
        duplicate_tag_strategy: DuplicateTagStrategy = .prioritize_best,
        /// If a normalizer is provided, it will allow for de-duplicating across
        /// different-but-equal UTF-8 grapheme forms. For example:
        /// - é (U+00E9 LATIN SMALL LETTER E WITH ACUTE)
        /// - e (U+0065 LATIN SMALL LETTER E) followed by U+0301 COMBINING ACUTE ACCENT
        ///
        /// However, the normalizer has a heavy cost to initialize, so:
        /// - It is optional, so that it only needs to be constructed if normalization
        ///   is desired
        /// - It is taken as a pointer so that it's possible to re-use the same
        ///   Normalizer instance across multiple Collator instances
        utf8_normalizer: ?*ziglyph.Normalizer = null,

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
            .normalizer = config.utf8_normalizer,
        };
        errdefer collator.deinit();

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

    pub const PrioritizedValueIterator = struct {
        collator: *const Collator,
        priority_index: usize = 0,
        key_index: usize = 0,
        value_iterator: ?metadata_namespace.MetadataMap.ValueIterator = null,
        keys: fields.NameLookups,

        pub const Entry = struct {
            tag_index: usize,
            value: []const u8,
        };

        pub fn next(self: *PrioritizedValueIterator) ?Entry {
            while (true) {
                // if we're out of tags, then return null
                if (self.priority_index >= self.collator.tag_indexes_by_priority.len) return null;

                const tag_index = self.collator.tag_indexes_by_priority[self.priority_index];
                const tag = &self.collator.metadata.tags[tag_index];
                const tag_keys = self.keys[@enumToInt(std.meta.activeTag(tag.*))];

                if (self.value_iterator) |*value_iterator| {
                    if (value_iterator.next()) |value| {
                        return Entry{
                            .tag_index = tag_index,
                            .value = value,
                        };
                    }
                    // if we're out of values, then move on to the next key index
                    self.value_iterator = null;
                    self.key_index += 1;
                }

                // if we're out of keys, then move on to the next priority index
                if (tag_keys == null or self.key_index >= tag_keys.?.len) {
                    self.priority_index += 1;
                    self.key_index = 0;
                    self.value_iterator = null;
                    continue;
                }

                const key = (tag_keys.?)[self.key_index];
                self.value_iterator = tag.getMetadataPtr().map.valueIterator(key);
            }
        }
    };

    pub fn prioritizedValueIterator(self: *const Collator, keys: fields.NameLookups) PrioritizedValueIterator {
        return .{
            .collator = self,
            .keys = keys,
        };
    }

    /// Returns a single value gotten from the tag with the highest priority,
    /// or null if no values exist for the relevant keys in any of the tags.
    pub fn getPrioritizedValue(self: *Self, keys: fields.NameLookups) Allocator.Error!?[]const u8 {
        var value_it = self.prioritizedValueIterator(keys);
        while (value_it.next()) |entry| {
            const ameliorated_value = (try ameliorateCanonical(self.arena.allocator(), entry.value)) orelse continue;
            return ameliorated_value;
        }
        return null;
    }

    pub fn getValuesFromKeys(self: *Self, keys: fields.NameLookups) Allocator.Error![][]const u8 {
        var set = CollatedTextSet.init(self.arena.allocator(), self.config.utf8_normalizer);
        defer set.deinit();

        var value_it = self.prioritizedValueIterator(keys);
        while (value_it.next()) |entry| {
            const tag = &self.metadata.tags[entry.tag_index];
            const meta_type = std.meta.activeTag(tag.*);
            const is_last_resort = self.config.prioritization.priority(meta_type) == .last_resort;
            if (!is_last_resort or set.count() == 0) {
                try set.put(entry.value);
            }
        }
        return try self.arena.allocator().dupe([]const u8, set.values.items);
    }

    pub fn artists(self: *Self) Allocator.Error![][]const u8 {
        return self.getValuesFromKeys(fields.artist);
    }

    /// Using this function is discouraged, as it may return incorrect results
    /// when the metadata contains multiple artists. It is recommended to
    /// use `artists` instead to ensure that multiple values can be handled.
    /// TODO: Recommend `albumArtist` as an alternative for getting a singular 'artist' value.
    pub fn artist(self: *Self) Allocator.Error!?[]const u8 {
        return self.getPrioritizedValue(fields.artist);
    }

    pub fn albums(self: *Self) Allocator.Error![][]const u8 {
        return self.getValuesFromKeys(fields.album);
    }

    pub fn album(self: *Self) Allocator.Error!?[]const u8 {
        return self.getPrioritizedValue(fields.album);
    }

    pub fn titles(self: *Self) Allocator.Error![][]const u8 {
        return self.getValuesFromKeys(fields.title);
    }

    pub fn title(self: *Self) Allocator.Error!?[]const u8 {
        return self.getPrioritizedValue(fields.title);
    }

    pub const TrackNumber = struct {
        number: ?u32,
        total: ?u32,
    };

    pub fn trackNumber(self: *Self) Allocator.Error!TrackNumber {
        var track_number = TrackNumber{ .number = null, .total = null };

        var track_number_it = self.prioritizedValueIterator(fields.track_number);
        while (track_number_it.next()) |entry| {
            const split_track_number = splitTrackNumber(entry.value);
            if (track_number.number == null and split_track_number.number != null) {
                track_number.number = split_track_number.number;
            }
            if (track_number.total == null and split_track_number.total != null) {
                track_number.total = split_track_number.total;
            }
            // Only break if both number and total are set, to ensure that we end up
            // getting the total if we encounter values like "5" and then "5/15"
            if (track_number.number != null and track_number.total != null) {
                break;
            }
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
            (std.fmt.parseUnsigned(T, number_as_string.?, 10) catch null)
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

    pub fn trackNumbers(self: *Self) Allocator.Error!TrackNumbers {
        var track_number_set = std.AutoArrayHashMapUnmanaged(u32, void){};
        defer track_number_set.deinit(self.allocator);
        var track_total_set = std.AutoArrayHashMapUnmanaged(u32, void){};
        defer track_total_set.deinit(self.allocator);

        for (self.tag_indexes_by_priority) |tag_index| {
            const tag = &self.metadata.tags[tag_index];
            const meta_type = std.meta.activeTag(tag.*);
            const is_last_resort = self.config.prioritization.priority(meta_type) == .last_resort;

            track_numbers: {
                if (is_last_resort and track_number_set.count() != 0) break :track_numbers;

                const tag_keys = fields.track_number[@enumToInt(meta_type)] orelse break :track_numbers;
                for (tag_keys) |key| {
                    var value_it = tag.getMetadata().map.valueIterator(key);
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
                    var value_it = tag.getMetadata().map.valueIterator(key);
                    while (value_it.next()) |track_total_as_string| {
                        const maybe_total: ?u32 = parseNumberDisallowingZero(u32, track_total_as_string);
                        if (maybe_total) |total| {
                            try track_total_set.put(self.allocator, total, {});
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

fn buildMetadata(allocator: Allocator, comptime types: []const MetadataType, comptime values: anytype) !AllMetadata {
    var metadata_buf = std.ArrayList(TypedMetadata).init(allocator);
    defer metadata_buf.deinit();

    inline for (types) |meta_type, i| {
        switch (meta_type) {
            .id3v2 => {
                try metadata_buf.append(TypedMetadata{ .id3v2 = .{
                    .metadata = Metadata.init(allocator),
                    .user_defined = metadata_namespace.MetadataMap.init(allocator),
                    .header = undefined,
                    .comments = id3v2_data.FullTextMap.init(allocator),
                    .unsynchronized_lyrics = id3v2_data.FullTextMap.init(allocator),
                } });
            },
            .id3v1 => {
                try metadata_buf.append(TypedMetadata{ .id3v1 = Metadata.init(allocator) });
            },
            .ape => {
                try metadata_buf.append(TypedMetadata{ .ape = .{
                    .metadata = Metadata.init(allocator),
                    .header_or_footer = undefined,
                } });
            },
            .flac => {
                try metadata_buf.append(TypedMetadata{ .flac = Metadata.init(allocator) });
            },
            .mp4 => {
                try metadata_buf.append(TypedMetadata{ .mp4 = Metadata.init(allocator) });
            },
            .vorbis => {
                try metadata_buf.append(TypedMetadata{ .vorbis = Metadata.init(allocator) });
            },
        }
        const tag_values = values[i];
        inline for (tag_values) |entry| {
            try metadata_buf.items[i].getMetadataPtr().map.put(entry[0], entry[1]);
        }
    }

    return AllMetadata{
        .allocator = allocator,
        .tags = metadata_buf.toOwnedSlice(),
    };
}

test "PrioritizedValueIterator" {
    var allocator = std.testing.allocator;
    var all = try buildMetadata(
        allocator,
        &[_]MetadataType{
            .ape,
            .flac,
            .flac,
            .flac,
        },
        .{
            .{.{ "Album", "ape album" }},
            .{.{ "ALBUM", "bad album" }},
            .{
                .{ "ALBUM", "best album" },
                .{ "ALBUM", "second best album" },
                .{ "ARTIST", "artist" },
                .{ "TITLE", "song" },
            },
            .{
                .{ "ALBUM", "good album" },
                .{ "ARTIST", "artist" },
            },
        },
    );
    defer all.deinit();

    var collator = try Collator.init(allocator, &all, .{
        .duplicate_tag_strategy = .prioritize_best,
    });
    defer collator.deinit();

    const prioritized_values: []const []const u8 = &.{
        "best album",
        "second best album",
        "good album",
        "bad album",
        "ape album",
    };

    var prioritized_it = collator.prioritizedValueIterator(fields.album);
    var i: usize = 0;
    while (prioritized_it.next()) |entry| {
        const expected = prioritized_values[i];
        try std.testing.expectEqualStrings(expected, entry.value);
        i += 1;
    }
}

test "id3v2.2 frames work" {
    var allocator = std.testing.allocator;
    var all = try buildMetadata(
        allocator,
        &[_]MetadataType{
            .id3v2,
        },
        .{
            .{.{ "TP1", "test" }},
        },
    );
    defer all.deinit();

    var collator = try Collator.init(allocator, &all, .{});
    defer collator.deinit();

    const artists = try collator.artists();
    try std.testing.expectEqual(@as(usize, 1), artists.len);
    try std.testing.expectEqualStrings("test", artists[0]);
}

test "prioritization last resort" {
    var allocator = std.testing.allocator;
    var all = try buildMetadata(
        allocator,
        &[_]MetadataType{
            .id3v2,
            .id3v1,
        },
        .{
            .{.{ "TP1", "test" }},
            .{.{ "artist", "ignored" }},
        },
    );
    defer all.deinit();

    var collator = try Collator.init(allocator, &all, .{});
    defer collator.deinit();

    const artists = try collator.artists();
    try std.testing.expectEqual(@as(usize, 1), artists.len);
    try std.testing.expectEqualStrings("test", artists[0]);
}

test "prioritization flac > ape" {
    var allocator = std.testing.allocator;
    var all = try buildMetadata(
        allocator,
        &[_]MetadataType{
            .ape,
            .flac,
        },
        .{
            .{.{ "Artist", "FLACcase" }},
            .{.{ "ARTIST", "FlacCase" }},
        },
    );
    defer all.deinit();

    var collator = try Collator.init(allocator, &all, .{});
    defer collator.deinit();

    // flac is prioritized over ape, so for duplicate keys the flac casing
    // should end up in the result even if ape comes first in the file

    const artists = try collator.artists();
    try std.testing.expectEqual(@as(usize, 1), artists.len);
    try std.testing.expectEqualStrings("FlacCase", artists[0]);
}

test "duplicate_tag_strategy: prioritize_best" {
    var allocator = std.testing.allocator;
    var all = try buildMetadata(
        allocator,
        &[_]MetadataType{
            .ape,
            .flac,
            .flac,
            .flac,
        },
        .{
            .{.{ "Album", "ape album" }},
            .{.{ "ALBUM", "bad album" }},
            .{
                .{ "ALBUM", "good album" },
                .{ "ARTIST", "artist" },
            },
            .{
                .{ "ALBUM", "best album" },
                .{ "ARTIST", "artist" },
                .{ "TITLE", "song" },
            },
        },
    );
    defer all.deinit();

    var collator = try Collator.init(allocator, &all, .{
        .duplicate_tag_strategy = .prioritize_best,
    });
    defer collator.deinit();

    const album = try collator.album();
    try std.testing.expectEqualStrings("best album", album.?);

    const albums = try collator.albums();
    // should get one from all 4 tags
    try std.testing.expectEqual(@as(usize, 4), albums.len);
    // highest priority should be the last FLAC tag
    try std.testing.expectEqualStrings("best album", albums[0]);
    try std.testing.expectEqualStrings("good album", albums[1]);
    try std.testing.expectEqualStrings("bad album", albums[2]);
    try std.testing.expectEqualStrings("ape album", albums[3]);
}

test "duplicate_tag_strategy: prioritize_first" {
    var allocator = std.testing.allocator;
    var all = try buildMetadata(
        allocator,
        &[_]MetadataType{
            .ape,
            .flac,
            .flac,
        },
        .{
            .{.{ "Album", "ape album" }},
            .{.{ "ALBUM", "first album" }},
            .{
                .{ "ALBUM", "second album" },
                .{ "TITLE", "title  " }, // extra spaces at the end to test trimming
            },
        },
    );
    defer all.deinit();

    var collator = try Collator.init(allocator, &all, .{
        .duplicate_tag_strategy = .prioritize_first,
    });
    defer collator.deinit();

    const album = try collator.album();
    try std.testing.expectEqualStrings("first album", album.?);

    const albums = try collator.albums();
    // should get one from all 3 tags
    try std.testing.expectEqual(@as(usize, 3), albums.len);
    // highest priority should be the first FLAC tag
    try std.testing.expectEqualStrings("first album", albums[0]);
    try std.testing.expectEqualStrings("second album", albums[1]);
    try std.testing.expectEqualStrings("ape album", albums[2]);

    // should get the title from the second FLAC tag
    const title = try collator.title();
    try std.testing.expectEqualStrings("title", title.?);
}

test "duplicate_tag_strategy: ignore_duplicates" {
    var allocator = std.testing.allocator;
    var all = try buildMetadata(
        allocator,
        &[_]MetadataType{
            .ape,
            .flac,
            .flac,
        },
        .{
            .{.{ "Album", "ape album" }},
            .{.{ "ALBUM", "first album" }},
            .{
                .{ "ALBUM", "second album" },
                .{ "TITLE", "title" },
                .{ "TRACKNUMBER", "1" },
            },
        },
    );
    defer all.deinit();

    var collator = try Collator.init(allocator, &all, .{
        .duplicate_tag_strategy = .ignore_duplicates,
    });
    defer collator.deinit();

    const album = try collator.album();
    try std.testing.expectEqualStrings("first album", album.?);

    // should get one from the first FLAC and one from APE
    const albums = try collator.albums();
    try std.testing.expectEqual(@as(usize, 2), albums.len);
    // highest priority should be the first FLAC tag
    try std.testing.expectEqualStrings("first album", albums[0]);
    try std.testing.expectEqualStrings("ape album", albums[1]);

    // should ignore the second FLAC tag, so shouldn't find a title or track number
    const title = try collator.title();
    try std.testing.expect(title == null);
    const track_number = try collator.trackNumber();
    try std.testing.expect(track_number.number == null);
    try std.testing.expect(track_number.total == null);
}

test "track number" {
    var allocator = std.testing.allocator;
    var all = try buildMetadata(
        allocator,
        &[_]MetadataType{
            .ape,
        },
        .{
            .{
                .{ "Track", "5" },
                .{ "Track", "5/15" },
            },
        },
    );
    defer all.deinit();

    var collator = try Collator.init(allocator, &all, .{});
    defer collator.deinit();

    const track_number = try collator.trackNumber();
    try std.testing.expectEqual(@as(u32, 5), track_number.number.?);
    try std.testing.expectEqual(@as(u32, 15), track_number.total.?);
}

test "track number but total is separate" {
    var allocator = std.testing.allocator;
    var all = try buildMetadata(
        allocator,
        &[_]MetadataType{
            .flac,
        },
        .{
            .{
                .{ "TRACKNUMBER", "5" },
                .{ "TRACKTOTAL", "15" },
            },
        },
    );
    defer all.deinit();

    var collator = try Collator.init(allocator, &all, .{});
    defer collator.deinit();

    const track_number = try collator.trackNumber();
    try std.testing.expectEqual(@as(u32, 5), track_number.number.?);
    try std.testing.expectEqual(@as(u32, 15), track_number.total.?);
}

test "track numbers" {
    var allocator = std.testing.allocator;
    var all = try buildMetadata(
        allocator,
        &[_]MetadataType{
            .ape,
            .flac,
            .flac,
        },
        .{
            .{.{ "Track", "5/15" }},
            .{.{ "TRACKNUMBER", "1" }},
            .{
                .{ "TRACKTOTAL", "5" },
                .{ "TRACKTOTAL", "0" }, // should be ignored
                .{ "TRACKNUMBER", "5" },
                .{ "TRACKNUMBER", "0" }, // should be ignored
                .{ "TRACKNUMBER", "15" },
            },
        },
    );
    defer all.deinit();

    var collator = try Collator.init(allocator, &all, .{
        .duplicate_tag_strategy = .prioritize_first,
    });
    defer collator.deinit();

    const track_numbers = try collator.trackNumbers();
    try std.testing.expectEqual(@as(usize, 3), track_numbers.numbers.len);
    try std.testing.expectEqual(@as(u32, 1), track_numbers.numbers[0]);
    try std.testing.expectEqual(@as(u32, 5), track_numbers.numbers[1]);
    try std.testing.expectEqual(@as(u32, 15), track_numbers.numbers[2]);

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
    normalizer: ?*ziglyph.Normalizer,
    arena: Allocator,

    const Self = @This();

    /// Allocator must be an arena that will get cleaned up outside of
    /// this struct (this struct's deinit will not handle cleaning up the arena)
    pub fn init(arena: Allocator, normalizer: ?*ziglyph.Normalizer) Self {
        return .{
            .values = std.ArrayListUnmanaged([]const u8){},
            .normalized_set = std.StringHashMapUnmanaged(usize){},
            .normalizer = normalizer,
            .arena = arena,
        };
    }

    pub fn deinit(self: *Self) void {
        // TODO: If this uses an arena, this isn't necessary
        self.values.deinit(self.arena);
        self.normalized_set.deinit(self.arena);
    }

    pub fn put(self: *Self, value: []const u8) Allocator.Error!void {
        const ameliorated_canonical = (try ameliorateCanonical(self.arena, value)) orelse return;
        const lowered = ziglyph.toCaseFoldStr(self.arena, ameliorated_canonical) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            // Assert that the Utf-8 is valid
            error.Utf8CannotEncodeSurrogateHalf,
            error.CodepointTooLarge,
            error.InvalidUtf8,
            => unreachable,
        };

        // Only normalize if we have a normalizer
        const normalized = normalized: {
            if (self.normalizer) |normalizer| {
                break :normalized normalizer.normalizeTo(.canon, lowered) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    // normalizeTo uses anyerror for unknown reasons, this might
                    // be wrong but I'm assuming that they are all related to
                    // invalid Utf-8 which this assumes to be impossible to hit
                    else => unreachable,
                };
            }
            break :normalized lowered;
        };
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

    var set = CollatedTextSet.init(arena.allocator(), null);
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

    var normalizer = try ziglyph.Normalizer.init(std.testing.allocator);
    defer normalizer.deinit();

    var set = CollatedTextSet.init(arena.allocator(), &normalizer);
    defer set.deinit();

    try set.put("foé");
    try set.put("foe\u{0301}");

    try std.testing.expectEqual(@as(usize, 1), set.count());
}

test "CollatedTextSet windows-1251 detection" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var set = CollatedTextSet.init(arena.allocator(), null);
    defer set.deinit();

    // Note: the Latin-1 bytes here are "\xC0\xEF\xEE\xF1\xF2\xF0\xEE\xF4"
    try set.put("Àïîñòðîô");

    try std.testing.expectEqualStrings("Апостроф", set.values.items[0]);

    try set.put("АПОСТРОФ");
    try std.testing.expectEqual(@as(usize, 1), set.count());
}
