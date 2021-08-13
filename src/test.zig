const std = @import("std");
const id3 = @import("id3v2.zig");
const flac = @import("flac.zig");
const fmtUtf8SliceEscapeUpper = @import("util.zig").fmtUtf8SliceEscapeUpper;
const meta = @import("metadata.zig");
const MetadataMap = meta.MetadataMap;
const Metadata = meta.Metadata;
const unsynch = @import("unsynch.zig");
const ffmpeg_compat = @import("ffmpeg_compat.zig");
const Allocator = std.mem.Allocator;

const start_testing_at_prefix = "Conflict - 1985";

test "music folder" {
    const allocator = std.testing.allocator;
    var dir = try std.fs.cwd().openDir("/media/drive4/music/", .{ .iterate = true });
    var walker = try dir.walk(allocator);
    defer walker.deinit();

    var testing_started = false;
    while (try walker.next()) |entry| {
        if (!testing_started) {
            if (std.mem.startsWith(u8, entry.path, start_testing_at_prefix)) {
                testing_started = true;
            } else {
                continue;
            }
        }
        if (entry.kind != .File) continue;

        const extension = std.fs.path.extension(entry.basename);
        const is_mp3 = std.mem.eql(u8, extension, ".mp3");
        const is_flac = std.mem.eql(u8, extension, ".flac");
        const readable = is_mp3 or is_flac;
        if (!readable) continue;

        std.debug.print("\n{s}\n", .{fmtUtf8SliceEscapeUpper(entry.path)});

        var expected_metadata = getFFProbeMetadata(allocator, entry.dir, entry.basename) catch |e| switch (e) {
            error.NoMetadataFound => MetadataArray.init(allocator),
            else => return e,
        };
        defer expected_metadata.deinit();

        var file = try entry.dir.openFile(entry.basename, .{});
        defer file.close();

        // skip zero sized files
        const size = (try file.stat()).size;
        if (size == 0) continue;

        var stream_source = std.io.StreamSource{ .file = file };
        var metadata = try meta.readAll(allocator, &stream_source);
        defer metadata.deinit();

        var coalesced_metadata = try ffmpeg_compat.coalesceMetadata(allocator, &metadata);
        defer coalesced_metadata.deinit();

        try compareMetadata(allocator, &expected_metadata, &coalesced_metadata);
    }
}

const ignored_fields = std.ComptimeStringMap(void, .{
    .{"encoder"},
    .{"comment"}, // TODO
    .{"UNSYNCEDLYRICS"}, // TODO multiline ffprobe parsing
    .{"genre"}, // TODO parse (n) at start and convert it to genre
    .{"Track"}, // weird Track:Comment field name that explodes things
    .{"ID3v1 Comment"}, // this came from a COMM frame
    .{"MusicMatch_TrackArtist"}, // this came from a COMM frame
});

fn compareMetadata(allocator: *Allocator, expected: *MetadataArray, actual: *MetadataMap) !void {
    for (expected.array.items) |field| {
        if (ignored_fields.get(field.name) != null) continue;
        if (std.mem.startsWith(u8, field.name, "id3v2_priv.")) continue;
        if (std.mem.startsWith(u8, field.name, "lyrics")) continue;
        if (std.mem.startsWith(u8, field.name, "iTun")) continue;

        if (actual.contains(field.name)) {
            var num_values = actual.valueCount(field.name).?;
            var value_needs_free = false;
            var actual_value: []const u8 = blk: {
                if (num_values == 1) {
                    break :blk actual.getFirst(field.name).?;
                } else {
                    // hacky, but ffmpeg will not join with ; if all values are empty
                    // so handle that case here
                    var all_values = (try actual.getAllAlloc(allocator, field.name)).?;
                    defer allocator.free(all_values);
                    var all_empty = all_empty: {
                        for (all_values) |value| {
                            if (value.len != 0) break :all_empty false;
                        }
                        break :all_empty true;
                    };
                    if (all_empty) {
                        break :blk "";
                    } else {
                        var joined_value = (try actual.getJoinedAlloc(allocator, field.name, ";")).?;
                        value_needs_free = true;
                        break :blk joined_value;
                    }
                }
            };
            defer if (value_needs_free) allocator.free(actual_value);

            std.testing.expectEqualStrings(field.value, actual_value) catch |e| {
                std.debug.print("\nexpected:\n", .{});
                for (expected.array.items) |_field| {
                    std.debug.print("{s} = {s}\n", .{ fmtUtf8SliceEscapeUpper(_field.name), fmtUtf8SliceEscapeUpper(_field.value) });
                }
                std.debug.print("\nactual:\n", .{});
                actual.dump();
                return e;
            };
        } else {
            std.debug.print("\nmissing field {s}\n", .{field.name});
            std.debug.print("\nexpected:\n", .{});
            for (expected.array.items) |_field| {
                std.debug.print("{s} = {s}\n", .{ fmtUtf8SliceEscapeUpper(_field.name), fmtUtf8SliceEscapeUpper(_field.value) });
            }
            std.debug.print("\nactual:\n", .{});
            actual.dump();
            return error.MissingField;
        }
    }
}

const MetadataArray = struct {
    allocator: *std.mem.Allocator,
    array: std.ArrayList(Field),

    const Field = struct {
        name: []const u8,
        value: []const u8,
    };

    pub fn init(allocator: *std.mem.Allocator) MetadataArray {
        return .{
            .allocator = allocator,
            .array = std.ArrayList(Field).init(allocator),
        };
    }

    pub fn deinit(self: *MetadataArray) void {
        for (self.array.items) |field| {
            self.allocator.free(field.name);
            self.allocator.free(field.value);
        }
        self.array.deinit();
    }

    pub fn append(self: *MetadataArray, field: Field) !void {
        return self.array.append(field);
    }
};

fn getFFProbeMetadata(allocator: *std.mem.Allocator, cwd: ?std.fs.Dir, filepath: []const u8) !MetadataArray {
    var metadata = MetadataArray.init(allocator);
    errdefer metadata.deinit();

    const result = try std.ChildProcess.exec(.{
        .allocator = allocator,
        .argv = &[_][]const u8{
            "ffprobe",
            "-hide_banner",
            filepath,
        },
        .cwd_dir = cwd,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    const metadata_start_string = "Metadata:\n";
    const maybe_metadata_start = std.mem.indexOf(u8, result.stderr, metadata_start_string);
    if (maybe_metadata_start == null) {
        return error.NoMetadataFound;
    }

    const metadata_line_start = (std.mem.lastIndexOfScalar(u8, result.stderr[0..maybe_metadata_start.?], '\n') orelse 0) + 1;
    const metadata_line_indent_size = maybe_metadata_start.? - metadata_line_start;
    const metadata_start = maybe_metadata_start.? + metadata_start_string.len;
    const metadata_text = result.stderr[metadata_start..];

    var indentation = try allocator.alloc(u8, metadata_line_indent_size + 2);
    defer allocator.free(indentation);
    std.mem.set(u8, indentation, ' ');

    var line_it = std.mem.split(u8, metadata_text, "\n");
    while (line_it.next()) |line| {
        if (!std.mem.startsWith(u8, line, indentation)) break;

        var field_it = std.mem.split(u8, line, ":");
        var name = std.mem.trim(u8, field_it.next().?, " ");
        if (name.len == 0) continue;
        // TODO multiline values
        var value = field_it.rest()[1..];

        try metadata.append(MetadataArray.Field{
            .name = try allocator.dupe(u8, name),
            .value = try allocator.dupe(u8, value),
        });
    }

    return metadata;
}

test "ffprobe compare" {
    const allocator = std.testing.allocator;
    const filepath = "/media/drive4/music/Catharsis - 1997- Samsara [v0]/01 - i. One Minute Closer the the Hour of Your Death.mp3";
    var probed_metadata = getFFProbeMetadata(allocator, null, filepath) catch |e| switch (e) {
        error.NoMetadataFound => MetadataArray.init(allocator),
        else => return e,
    };
    defer probed_metadata.deinit();

    var file = try std.fs.cwd().openFile(filepath, .{});
    defer file.close();

    var data = try file.readToEndAlloc(allocator, 100 * 1024 * 1024);
    defer allocator.free(data);

    // var decoded_unsynch_buffer = try allocator.alloc(u8, data.len);
    // defer allocator.free(decoded_unsynch_buffer);

    // var decoded = unsynch.decode(data, decoded_unsynch_buffer);

    var fixed_buffer_stream = std.io.fixedBufferStream(data);

    var stream_source = std.io.StreamSource{ .buffer = fixed_buffer_stream };
    var metadata = try meta.readAll(allocator, &stream_source);
    defer metadata.deinit();

    var coalesced_metadata = try ffmpeg_compat.coalesceMetadata(allocator, &metadata);
    defer coalesced_metadata.deinit();

    try compareMetadata(allocator, &probed_metadata, &coalesced_metadata);
}
