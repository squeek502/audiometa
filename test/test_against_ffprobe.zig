const std = @import("std");
const audiometa = @import("audiometa");
const fmtUtf8SliceEscapeUpper = audiometa.util.fmtUtf8SliceEscapeUpper;
const meta = audiometa.metadata;
const AllMetadata = meta.AllMetadata;
const MetadataMap = meta.MetadataMap;
const Allocator = std.mem.Allocator;

const start_testing_at_prefix = "";

// ffmpeg fails to parse unsynchronised tags correctly
// in these files, its a MCDI frame followed by a TLEN frame
// ffmpeg reads len bytes directly instead of unsynching and then reading len bytes
// so it falls (num unsynched bytes in the frame) short when reading the next frame
// this is the relevant bug but it was closed as invalid (incorrectly, AFAICT):
// https://trac.ffmpeg.org/ticket/4
const ffmpeg_unsync_bugged_files = std.ComptimeStringMap(void, .{
    .{"Doomed Future Today/14 - Bombs (Version).mp3"},
    .{"Living Through The End Time/13 - Imaginary Friend.mp3"},
});

const ffprobe_unusable_output_files = std.ComptimeStringMap(void, .{
    // TODO: possible outputting issue, ? in ffprobe output
    .{"Simbiose - 2009 - Fake Dimension/13-simbiose-evolucao_e_regressao.mp3"},
});

test "music folder" {
    const allocator = std.testing.allocator;
    var dir = try std.fs.cwd().openIterableDir("/media/drive4/music/", .{});
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

        if (ffmpeg_unsync_bugged_files.has(entry.path)) continue;
        if (ffprobe_unusable_output_files.has(entry.path)) continue;
        // TODO: fairly unsolvable, these use a TXXX field with "album  " as the name, which is impossible
        // to distinguish from "album" when parsing the ffprobe output. Maybe using ffmpeg -f ffmetadata
        // might be better?
        if (std.mem.startsWith(u8, entry.path, "Sonic Cathedrals Vol. XLVI Curated by Age of Collapse/")) continue;

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

        var coalesced_metadata = try coalesceMetadata(allocator, &metadata);
        defer coalesced_metadata.deinit();

        try compareMetadata(allocator, &expected_metadata, &coalesced_metadata);
    }
}

const ignored_fields = std.ComptimeStringMap(void, .{
    .{"encoder"},
    .{"comment"}, // TODO
    .{"UNSYNCEDLYRICS"}, // TODO multiline ffprobe parsing
    .{"unsyncedlyrics"}, // ^
    .{"LYRICS"}, //         ^
    .{"COVERART"}, // multiline but also binary, so probably more than just multiline parsing is needed, see Deathrats - 7 inch/
    .{"CODING_HISTORY"}, // TODO multiline ffprobe parsing, see Miserable-Uncontrollable-2016-WEB-FLAC/05 Stranger.flac
    .{"genre"}, // TODO parse (n) at start and convert it to genre
    .{"Track"}, // weird Track:Comment field name that explodes things
    .{"ID3v1 Comment"}, // this came from a COMM frame
    .{"MusicMatch_TrackArtist"}, // this came from a COMM frame
    .{"CDDB Disc ID"}, // this came from a COMM frame
    .{"ID3v1"}, // this came from a COMM frame
    .{"c0"}, // this came from a COMM frame
    .{"Media Jukebox"}, // this came from a COMM frame
    .{"l assault cover"}, // this came from a weird COMM frame
    .{"http"}, // this came from a weird COMM frame
    .{"MusicMatch_Preference"}, // this came from a COMM frame
    .{"Songs-DB_Custom1"}, // this came from a COMM frame
    .{"Comments"}, // this came from a COMM frame
    .{"Checksum"}, // this came from a COMM frame
    .{"Songs-DB_Custom5"}, // this came from a COMM frame
    .{"oso"}, // this came from a COMM frame
});

pub fn coalesceMetadata(allocator: Allocator, metadata: *AllMetadata) !MetadataMap {
    var coalesced = meta.MetadataMap.init(allocator);
    errdefer coalesced.deinit();

    if (metadata.flac) |*flac_metadata| {
        // since flac allows for duplicate fields, ffmpeg concats them with ;
        // because ffmpeg has a 'no duplicate fields' rule
        var names_it = flac_metadata.map.name_to_indexes.keyIterator();
        while (names_it.next()) |raw_name| {
            // vorbis metadata fields are case-insensitive, so convert to uppercase
            // for the lookup
            const upper_field = try std.ascii.allocUpperString(allocator, raw_name.*);
            defer allocator.free(upper_field);

            const name = flac_field_names.get(upper_field) orelse raw_name.*;
            const joined_value = (try flac_metadata.map.getJoinedAlloc(allocator, raw_name.*, ";")).?;
            defer allocator.free(joined_value);

            try coalesced.put(name, joined_value);
        }
    }

    if (coalesced.entries.items.len == 0) {
        if (metadata.all_id3v2) |all_id3v2| {
            // Here's an overview of how ffmpeg does things:
            // 1. add all fields with their unconverted ID without overwriting
            //    (this means that all duplicate fields are ignored)
            // 2. once all tags are finished reading, convert IDs to their 'ffmpeg name',
            //    allowing overwrites
            // also it seems like empty values are exempt from overwriting things
            // even if they would otherwise? I'm not sure where this is coming from, but
            // it seems like that's the case from the output of ffprobe
            //
            // So, we need to basically do the same thing here using a temporary
            // MetadataMap

            var metadata_tmp = meta.MetadataMap.init(allocator);
            defer metadata_tmp.deinit();

            for (all_id3v2.tags) |*id3v2_metadata_container| {
                const id3v2_metadata = &id3v2_metadata_container.metadata.map;

                for (id3v2_metadata.entries.items) |entry| {
                    if (metadata_tmp.contains(entry.name)) continue;
                    try metadata_tmp.put(entry.name, entry.value);
                }
            }

            for (metadata_tmp.entries.items) |entry| {
                const converted_name = convertIdToName(entry.name);
                const name = converted_name orelse entry.name;
                try coalesced.putOrReplaceFirst(name, entry.value);
            }
            try mergeDate(&coalesced);
        }
    }

    if (coalesced.entries.items.len == 0) {
        if (metadata.id3v1) |*id3v1_metadata| {
            // just a clone
            for (id3v1_metadata.map.entries.items) |entry| {
                try coalesced.put(entry.name, entry.value);
            }
        }
    }

    return coalesced;
}

const date_format = "YYYY-MM-DD hh:mm";

fn isValidDateComponent(maybe_date: ?[]const u8) bool {
    if (maybe_date == null) return false;
    const date = maybe_date.?;
    if (date.len != 4) return false;
    // only 0-9 allowed
    for (date) |byte| switch (byte) {
        '0'...'9' => {},
        else => return false,
    };
    return true;
}

fn mergeDate(metadata: *MetadataMap) !void {
    var date_buf: [date_format.len]u8 = undefined;
    var date: []u8 = date_buf[0..0];

    var year = metadata.getFirst("TYER") orelse metadata.getFirst("TYE");
    if (!isValidDateComponent(year)) return;
    date = date_buf[0..4];
    std.mem.copy(u8, date, (year.?)[0..4]);

    const maybe_daymonth = metadata.getFirst("TDAT") orelse metadata.getFirst("TDA");
    if (isValidDateComponent(maybe_daymonth)) {
        const daymonth = maybe_daymonth.?;
        date = date_buf[0..10];
        // TDAT is DDMM, we want -MM-DD
        const day = daymonth[0..2];
        const month = daymonth[2..4];
        _ = try std.fmt.bufPrint(date[4..10], "-{s}-{s}", .{ month, day });

        const maybe_time = metadata.getFirst("TIME") orelse metadata.getFirst("TIM");
        if (isValidDateComponent(maybe_time)) {
            const time = maybe_time.?;
            date = date_buf[0..];
            // TIME is HHMM
            const hours = time[0..2];
            const mins = time[2..4];
            _ = try std.fmt.bufPrint(date[10..], " {s}:{s}", .{ hours, mins });
        }
    }

    try metadata.putOrReplaceFirst("date", date);
}

const flac_field_names = std.ComptimeStringMap([]const u8, .{
    .{ "ALBUMARTIST", "album_artist" },
    .{ "TRACKNUMBER", "track" },
    .{ "DISCNUMBER", "disc" },
    .{ "DESCRIPTION", "comment" },
});

const id3v2_34_name_lookup = std.ComptimeStringMap([]const u8, .{
    .{ "TALB", "album" },
    .{ "TCOM", "composer" },
    .{ "TCON", "genre" },
    .{ "TCOP", "copyright" },
    .{ "TENC", "encoded_by" },
    .{ "TIT2", "title" },
    .{ "TLAN", "language" },
    .{ "TPE1", "artist" },
    .{ "TPE2", "album_artist" },
    .{ "TPE3", "performer" },
    .{ "TPOS", "disc" },
    .{ "TPUB", "publisher" },
    .{ "TRCK", "track" },
    .{ "TSSE", "encoder" },
    .{ "USLT", "lyrics" },
});

const id3v2_4_name_lookup = std.ComptimeStringMap([]const u8, .{
    .{ "TCMP", "compilation" },
    .{ "TDRC", "date" },
    .{ "TDRL", "date" },
    .{ "TDEN", "creation_time" },
    .{ "TSOA", "album-sort" },
    .{ "TSOP", "artist-sort" },
    .{ "TSOT", "title-sort" },
});

const id3v2_2_name_lookup = std.ComptimeStringMap([]const u8, .{
    .{ "TAL", "album" },
    .{ "TCO", "genre" },
    .{ "TCP", "compilation" },
    .{ "TT2", "title" },
    .{ "TEN", "encoded_by" },
    .{ "TP1", "artist" },
    .{ "TP2", "album_artist" },
    .{ "TP3", "performer" },
    .{ "TRK", "track" },
});

fn convertIdToName(id: []const u8) ?[]const u8 {
    // this is the order of precedence that ffmpeg does this
    // it also does not care about the major version, it just converts things unconditionally
    return id3v2_34_name_lookup.get(id) orelse id3v2_2_name_lookup.get(std.mem.sliceTo(id, '\x00')) orelse id3v2_4_name_lookup.get(id);
}

fn compareMetadata(allocator: Allocator, expected: *MetadataArray, actual: *MetadataMap) !void {
    for (expected.array.items) |field| {
        if (ignored_fields.get(field.name) != null) continue;
        if (std.mem.startsWith(u8, field.name, "id3v2_priv.")) continue;
        if (std.mem.startsWith(u8, field.name, "lyrics")) continue;
        if (std.mem.startsWith(u8, field.name, "iTun")) continue;
        if (std.mem.startsWith(u8, field.name, "Songs-DB")) continue;

        if (actual.contains(field.name)) {
            const num_values = actual.valueCount(field.name).?;
            // all duplicates should already be coalesced, since ffmpeg hates duplicates
            std.testing.expectEqual(num_values, 1) catch |e| {
                std.debug.print("\nexpected:\n", .{});
                for (expected.array.items) |_field| {
                    if (std.mem.eql(u8, _field.name, field.name)) {
                        std.debug.print("{s} = {s}\n", .{ fmtUtf8SliceEscapeUpper(_field.name), fmtUtf8SliceEscapeUpper(_field.value) });
                    }
                }
                std.debug.print("\nactual:\n", .{});
                const values = (try actual.getAllAlloc(allocator, field.name)).?;
                defer allocator.free(values);

                for (values) |val| {
                    std.debug.print("{s} = {s}\n", .{ fmtUtf8SliceEscapeUpper(field.name), fmtUtf8SliceEscapeUpper(val) });
                }
                return e;
            };
            const actual_value = actual.getFirst(field.name).?;

            std.testing.expectEqualStrings(field.value, actual_value) catch |e| {
                std.debug.print("field: {s}\n", .{fmtUtf8SliceEscapeUpper(field.name)});
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
    allocator: Allocator,
    array: std.ArrayList(Field),

    const Field = struct {
        name: []const u8,
        value: []const u8,
    };

    pub fn init(allocator: Allocator) MetadataArray {
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

fn getFFProbeMetadata(allocator: Allocator, cwd: ?std.fs.Dir, filepath: []const u8) !MetadataArray {
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

    const indentation = try allocator.alloc(u8, metadata_line_indent_size + 2);
    defer allocator.free(indentation);
    std.mem.set(u8, indentation, ' ');

    var line_it = std.mem.split(u8, metadata_text, "\n");
    while (line_it.next()) |line| {
        if (!std.mem.startsWith(u8, line, indentation)) break;

        var field_it = std.mem.split(u8, line, ":");
        const name = std.mem.trim(u8, field_it.next().?, " ");
        if (name.len == 0) continue;
        // TODO multiline values
        const value = field_it.rest()[1..];

        try metadata.append(MetadataArray.Field{
            .name = try allocator.dupe(u8, name),
            .value = try allocator.dupe(u8, value),
        });
    }

    return metadata;
}

test "ffprobe compare" {
    const allocator = std.testing.allocator;
    const filepath = "/media/drive4/music/Doomed Future Today/14 - Bombs (Version).mp3";
    var probed_metadata = getFFProbeMetadata(allocator, null, filepath) catch |e| switch (e) {
        error.NoMetadataFound => MetadataArray.init(allocator),
        else => return e,
    };
    defer probed_metadata.deinit();

    var file = try std.fs.cwd().openFile(filepath, .{});
    defer file.close();

    var stream_source = std.io.StreamSource{ .file = file };
    var metadata = try meta.readAll(allocator, &stream_source);
    defer metadata.deinit();

    var coalesced_metadata = try coalesceMetadata(allocator, &metadata);
    defer coalesced_metadata.deinit();

    try compareMetadata(allocator, &probed_metadata, &coalesced_metadata);
}
