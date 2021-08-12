const std = @import("std");
const Allocator = std.mem.Allocator;
const fmtUtf8SliceEscapeUpper = @import("util.zig").fmtUtf8SliceEscapeUpper;

pub const Metadata = struct {
    metadata: MetadataMap,
    start_offset: usize,
    end_offset: usize,

    pub fn deinit(self: *Metadata) void {
        self.metadata.deinit();
    }
};

pub const MetadataMap = struct {
    allocator: *Allocator,
    entries: EntryList,
    name_to_indexes: NameToIndexesMap,

    const Entry = struct {
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

    pub fn contains(self: *MetadataMap, name: []const u8) bool {
        return self.name_to_indexes.contains(name);
    }

    pub fn getFirst(self: *MetadataMap, name: []const u8) ?[]const u8 {
        const entry_index_list = (self.name_to_indexes.getPtr(name)) orelse return null;
        if (entry_index_list.items.len == 0) return null;
        const entry_index = entry_index_list.items[0];
        return self.entries.items[entry_index].value;
    }

    pub fn getJoinedAlloc(self: *MetadataMap, allocator: *Allocator, name: []const u8, separator: []const u8) !?[]u8 {
        const entry_index_list = (self.name_to_indexes.getPtr(name)) orelse return null;
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

    const date_format = "YYYY-MM-DD hh:mm";

    pub fn mergeDate(metadata: *MetadataMap) !void {
        var date_buf: [date_format.len]u8 = undefined;
        var date: []u8 = date_buf[0..0];

        var year = metadata.getFirst("TYER") orelse metadata.getFirst("TYE");
        if (year == null) return;
        date = date_buf[0..4];
        std.mem.copy(u8, date, (year.?)[0..4]);

        var maybe_daymonth = metadata.getFirst("TDAT") orelse metadata.getFirst("TDA");
        if (maybe_daymonth) |daymonth| {
            date = date_buf[0..10];
            // TDAT is DDMM, we want -MM-DD
            var day = daymonth[0..2];
            var month = daymonth[2..4];
            _ = try std.fmt.bufPrint(date[4..10], "-{s}-{s}", .{ month, day });
        }

        var maybe_time = metadata.getFirst("TIME") orelse metadata.getFirst("TIM");
        if (maybe_time) |time| {
            date = date_buf[0..];
            // TIME is HHMM
            var hours = time[0..2];
            var mins = time[2..4];
            _ = try std.fmt.bufPrint(date[10..], " {s}:{s}", .{ hours, mins });
        }

        try metadata.put("date", date);
    }

    pub fn dump(metadata: *MetadataMap) void {
        for (metadata.entries.items) |entry| {
            std.debug.print("{s}={s}\n", .{ fmtUtf8SliceEscapeUpper(entry.name), fmtUtf8SliceEscapeUpper(entry.value) });
        }
    }
};

test "metadata map" {
    var allocator = std.testing.allocator;
    var metadata = MetadataMap.init(allocator);
    defer metadata.deinit();

    try metadata.put("date", "2018");
    try metadata.put("date", "2018-04-25");

    const joined_date = (try metadata.getJoinedAlloc(allocator, "date", ";")).?;
    defer allocator.free(joined_date);

    try std.testing.expectEqualStrings("2018;2018-04-25", joined_date);

    std.debug.print("{s}\n", .{joined_date});

    metadata.dump();
}
