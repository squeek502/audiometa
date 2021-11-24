const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const fmtUtf8SliceEscapeUpper = @import("util.zig").fmtUtf8SliceEscapeUpper;

/// Like MetadataMap, but uses description/language as the keys
/// so it works for ID3v2 comments/unsynchronized lyrics
pub const FullTextMap = struct {
    allocator: *Allocator,
    entries: EntryList,
    language_to_indexes: LanguageToIndexesMap,
    description_to_indexes: DescriptionToIndexesMap,

    pub const Entry = struct {
        language: []const u8,
        description: []const u8,
        value: []const u8,
    };
    const EntryList = std.ArrayListUnmanaged(Entry);
    const IndexList = std.ArrayListUnmanaged(usize);
    const LanguageToIndexesMap = std.StringHashMapUnmanaged(IndexList);
    const DescriptionToIndexesMap = std.StringHashMapUnmanaged(IndexList);

    pub fn init(allocator: *Allocator) FullTextMap {
        return .{
            .allocator = allocator,
            .entries = .{},
            .language_to_indexes = .{},
            .description_to_indexes = .{},
        };
    }

    pub fn deinit(self: *FullTextMap) void {
        for (self.entries.items) |item| {
            self.allocator.free(item.value);
        }
        self.entries.deinit(self.allocator);

        var lang_it = self.language_to_indexes.iterator();
        while (lang_it.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
            self.allocator.free(entry.key_ptr.*);
        }
        self.language_to_indexes.deinit(self.allocator);

        var desc_it = self.description_to_indexes.iterator();
        while (desc_it.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
            self.allocator.free(entry.key_ptr.*);
        }
        self.description_to_indexes.deinit(self.allocator);
    }

    pub const LangAndDescEntries = struct {
        lang: LanguageToIndexesMap.Entry,
        desc: DescriptionToIndexesMap.Entry,
    };

    pub fn getOrPutIndexesEntries(self: *FullTextMap, language: []const u8, description: []const u8) !LangAndDescEntries {
        var lang_entry = lang_entry: {
            if (self.language_to_indexes.getEntry(language)) |entry| {
                break :lang_entry entry;
            } else {
                var lang_dup = try self.allocator.dupe(u8, language);
                errdefer self.allocator.free(lang_dup);

                const entry = try self.language_to_indexes.getOrPutValue(self.allocator, lang_dup, IndexList{});
                break :lang_entry entry;
            }
        };
        var desc_entry = desc_entry: {
            if (self.description_to_indexes.getEntry(description)) |entry| {
                break :desc_entry entry;
            } else {
                var desc_dup = try self.allocator.dupe(u8, description);
                errdefer self.allocator.free(desc_dup);

                const entry = try self.description_to_indexes.getOrPutValue(self.allocator, desc_dup, IndexList{});
                break :desc_entry entry;
            }
        };
        return LangAndDescEntries{
            .lang = lang_entry,
            .desc = desc_entry,
        };
    }

    pub fn appendToEntries(self: *FullTextMap, entries: LangAndDescEntries, value: []const u8) !void {
        const entry_index = entry_index: {
            const value_dup = try self.allocator.dupe(u8, value);
            errdefer self.allocator.free(value_dup);

            const entry_index = self.entries.items.len;
            try self.entries.append(self.allocator, Entry{
                .language = entries.lang.key_ptr.*,
                .description = entries.desc.key_ptr.*,
                .value = value_dup,
            });
            break :entry_index entry_index;
        };
        try entries.lang.value_ptr.append(self.allocator, entry_index);
        try entries.desc.value_ptr.append(self.allocator, entry_index);
    }

    pub fn put(self: *FullTextMap, language: []const u8, description: []const u8, value: []const u8) !void {
        const indexes_entries = try self.getOrPutIndexesEntries(language, description);
        try self.appendToEntries(indexes_entries, value);
    }

    pub fn dump(self: *const FullTextMap) void {
        for (self.entries.items) |entry| {
            std.debug.print("{s},{s}={s}\n", .{ fmtUtf8SliceEscapeUpper(entry.language), fmtUtf8SliceEscapeUpper(entry.description), fmtUtf8SliceEscapeUpper(entry.value) });
        }
    }
};
