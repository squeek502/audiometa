const std = @import("std");
const audiometa = @import("audiometa");
const AllMetadata = audiometa.metadata.AllMetadata;
const MetadataEntry = audiometa.metadata.MetadataMap.Entry;
const testing = std.testing;
const fmtUtf8SliceEscapeUpper = audiometa.util.fmtUtf8SliceEscapeUpper;

fn parseExpectedMetadata(comptime path: []const u8, expected_meta: ExpectedAllMetadata) !void {
    const data = @embedFile(path);
    var stream_source = std.io.StreamSource{ .const_buffer = std.io.fixedBufferStream(data) };
    var meta = try audiometa.metadata.readAll(testing.allocator, &stream_source);
    defer meta.deinit();

    compareAllMetadata(&expected_meta, &meta) catch |err| {
        std.debug.print("\nexpected:\n", .{});
        expected_meta.dump();
        std.debug.print("\nactual:\n", .{});
        meta.dump();
        return err;
    };
}

fn compareAllMetadata(all_expected: *const ExpectedAllMetadata, all_actual: *const AllMetadata) !void {
    if (all_expected.all_id3v2) |all_id3v2_expected| {
        if (all_actual.all_id3v2) |all_id3v2_actual| {
            try testing.expectEqual(all_id3v2_expected.len, all_id3v2_actual.len);
            for (all_id3v2_expected) |id3v2_expected, i| {
                try testing.expectEqual(id3v2_expected.major_version, all_id3v2_actual[i].major_version);
                try compareMetadata(&id3v2_expected.metadata, &all_id3v2_actual[i].metadata);
            }
        } else {
            return error.MissingID3v2;
        }
    } else if (all_actual.all_id3v2 != null) {
        return error.UnexpectedID3v2;
    }
    if (all_expected.id3v1) |*expected| {
        if (all_actual.id3v1) |*actual| {
            return compareMetadata(expected, actual);
        } else {
            return error.MissingID3v1;
        }
    } else if (all_actual.id3v1 != null) {
        return error.UnexpectedID3v1;
    }
    if (all_expected.flac) |*expected| {
        if (all_actual.flac) |*actual| {
            return compareMetadata(expected, actual);
        } else {
            return error.MissingFLAC;
        }
    } else if (all_actual.flac != null) {
        return error.UnexpectedFLAC;
    }
}

fn compareMetadata(expected: *const ExpectedMetadata, actual: *const audiometa.metadata.Metadata) !void {
    try testing.expectEqual(expected.map.len, actual.map.entries.items.len);
    try testing.expectEqual(expected.start_offset, actual.start_offset);
    try testing.expectEqual(expected.end_offset, actual.end_offset);
    expected_loop: for (expected.map) |field| {
        var found_matching_key = false;
        for (actual.map.entries.items) |entry| {
            if (std.ascii.eqlIgnoreCase(field.name, entry.name)) {
                if (std.mem.eql(u8, field.value, entry.value)) {
                    continue :expected_loop;
                }
                found_matching_key = true;
            }
        }
        std.debug.print("mismatched field: {s}\n", .{fmtUtf8SliceEscapeUpper(field.name)});
        if (found_matching_key) {
            return error.FieldValuesDontMatch;
        } else {
            return error.MissingField;
        }
    }
}

const ExpectedAllMetadata = struct {
    all_id3v2: ?[]const ExpectedID3v2Metadata,
    id3v1: ?ExpectedMetadata,
    flac: ?ExpectedMetadata,

    pub fn dump(self: *const ExpectedAllMetadata) void {
        if (self.all_id3v2) |all_id3v2| {
            for (all_id3v2) |id3v2_meta| {
                std.debug.print("# ID3v2 v2.{d} 0x{x}-0x{x}\n", .{ id3v2_meta.major_version, id3v2_meta.metadata.start_offset, id3v2_meta.metadata.end_offset });
                for (id3v2_meta.metadata.map) |entry| {
                    std.debug.print("{s}={s}\n", .{ fmtUtf8SliceEscapeUpper(entry.name), fmtUtf8SliceEscapeUpper(entry.value) });
                }
            }
        }
        if (self.id3v1) |id3v1_meta| {
            std.debug.print("# ID3v1 0x{x}-0x{x}\n", .{ id3v1_meta.start_offset, id3v1_meta.end_offset });
            for (id3v1_meta.map) |entry| {
                std.debug.print("{s}={s}\n", .{ fmtUtf8SliceEscapeUpper(entry.name), fmtUtf8SliceEscapeUpper(entry.value) });
            }
        }
        if (self.flac) |flac_meta| {
            std.debug.print("# FLAC 0x{x}-0x{x}\n", .{ flac_meta.start_offset, flac_meta.end_offset });
            for (flac_meta.map) |entry| {
                std.debug.print("{s}={s}\n", .{ fmtUtf8SliceEscapeUpper(entry.name), fmtUtf8SliceEscapeUpper(entry.value) });
            }
        }
    }
};
const ExpectedID3v2Metadata = struct {
    metadata: ExpectedMetadata,
    major_version: u8,
};
const ExpectedMetadata = struct {
    start_offset: usize,
    end_offset: usize,
    map: []const MetadataEntry,
};

test "standard id3v2.3 with UTF-16" {
    try parseExpectedMetadata("data/standard_id3v2.3.mp3", .{
        .all_id3v2 = &[_]ExpectedID3v2Metadata{
            .{
                .major_version = 3,
                .metadata = .{
                    .start_offset = 0x0,
                    .end_offset = 0x4604,
                    .map = &[_]MetadataEntry{
                        .{ .name = "TPE2", .value = "Muga" },
                        .{ .name = "TIT2", .value = "死前解放 (Unleash Before Death)" },
                        .{ .name = "TALB", .value = "Muga" },
                        .{ .name = "TYER", .value = "2002" },
                        .{ .name = "TRCK", .value = "02/11" },
                        .{ .name = "TPOS", .value = "1/1" },
                        .{ .name = "TPE1", .value = "Muga" },
                        .{ .name = "MEDIAFORMAT", .value = "CD" },
                        .{ .name = "PERFORMER", .value = "Muga" },
                    },
                },
            },
        },
        .id3v1 = .{
            .start_offset = 0x4604,
            .end_offset = 0x4684,
            .map = &[_]MetadataEntry{
                .{ .name = "title", .value = "???? (Unleash Before Death)" },
                .{ .name = "artist", .value = "Muga" },
                .{ .name = "album", .value = "Muga" },
                .{ .name = "date", .value = "2002" },
                .{ .name = "comment", .value = "EAC V1.0 beta 2, Secure Mode" },
                .{ .name = "track", .value = "2" },
            },
        },
        .flac = null,
    });
}

test "extended header id3v2.4 with crc" {
    try parseExpectedMetadata("data/extended_header_v2.4_crc.mp3", .{
        .all_id3v2 = &[_]ExpectedID3v2Metadata{
            .{
                .major_version = 4,
                .metadata = .{
                    .start_offset = 0x0,
                    .end_offset = 0x5F,
                    .map = &[_]MetadataEntry{
                        .{ .name = "TIT2", .value = "Test" },
                        .{ .name = "TPE1", .value = "Test2" },
                        .{ .name = "TPE2", .value = "Test2" },
                    },
                },
            },
        },
        .id3v1 = null,
        .flac = null,
    });
}
