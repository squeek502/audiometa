const std = @import("std");
const audiometa = @import("audiometa");
const id3 = audiometa.id3v2;
const flac = audiometa.flac;
const fmtUtf8SliceEscapeUpper = audiometa.util.fmtUtf8SliceEscapeUpper;
const meta = audiometa.metadata;
const MetadataMap = meta.MetadataMap;
const Metadata = meta.Metadata;
const ID3v2Metadata = meta.ID3v2Metadata;
const AllMetadata = meta.AllMetadata;
const unsynch = audiometa.unsynch;
const Allocator = std.mem.Allocator;

const start_testing_at_prefix = "";

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

        var expected_metadata = try getTagLibMetadata(allocator, entry.dir, entry.basename);
        defer expected_metadata.deinit();

        var file = try entry.dir.openFile(entry.basename, .{});
        defer file.close();

        // skip zero sized files
        const size = (try file.stat()).size;
        if (size == 0) continue;

        var stream_source = std.io.StreamSource{ .file = file };
        var metadata = try meta.readAll(allocator, &stream_source);
        defer metadata.deinit();

        try compareMetadata(allocator, &expected_metadata, &metadata);
    }
}

fn convertID3v2Alloc(allocator: *Allocator, map: *MetadataMap, id3_major_version: u8) !MetadataMap {
    var converted = MetadataMap.init(allocator);
    errdefer converted.deinit();

    for (map.entries.items) |entry| {
        // Keep the unconverted names since I don't really understand fully
        // how taglib converts things. This will make things less precise but
        // more foolproof for the type of comparisons we're trying to make
        try converted.put(entry.name, entry.value);
        if (taglibConversions.get(entry.name)) |converted_name| {
            try converted.put(converted_name, entry.value);
        }
    }

    if (id3_major_version < 4) {
        try mergeDate(&converted);
    }

    return converted;
}

const taglibConversions = std.ComptimeStringMap([]const u8, .{
    // 2.2 -> 2.4
    .{ "BUF", "RBUF" },  .{ "CNT", "PCNT" }, .{ "COM", "COMM" },  .{ "CRA", "AENC" },
    .{ "ETC", "ETCO" },  .{ "GEO", "GEOB" }, .{ "IPL", "TIPL" },  .{ "MCI", "MCDI" },
    .{ "MLL", "MLLT" },  .{ "POP", "POPM" }, .{ "REV", "RVRB" },  .{ "SLT", "SYLT" },
    .{ "STC", "SYTC" },  .{ "TAL", "TALB" }, .{ "TBP", "TBPM" },  .{ "TCM", "TCOM" },
    .{ "TCO", "TCON" },  .{ "TCP", "TCMP" }, .{ "TCR", "TCOP" },  .{ "TDY", "TDLY" },
    .{ "TEN", "TENC" },  .{ "TFT", "TFLT" }, .{ "TKE", "TKEY" },  .{ "TLA", "TLAN" },
    .{ "TLE", "TLEN" },  .{ "TMT", "TMED" }, .{ "TOA", "TOAL" },  .{ "TOF", "TOFN" },
    .{ "TOL", "TOLY" },  .{ "TOR", "TDOR" }, .{ "TOT", "TOAL" },  .{ "TP1", "TPE1" },
    .{ "TP2", "TPE2" },  .{ "TP3", "TPE3" }, .{ "TP4", "TPE4" },  .{ "TPA", "TPOS" },
    .{ "TPB", "TPUB" },  .{ "TRC", "TSRC" }, .{ "TRD", "TDRC" },  .{ "TRK", "TRCK" },
    .{ "TS2", "TSO2" },  .{ "TSA", "TSOA" }, .{ "TSC", "TSOC" },  .{ "TSP", "TSOP" },
    .{ "TSS", "TSSE" },  .{ "TST", "TSOT" }, .{ "TT1", "TIT1" },  .{ "TT2", "TIT2" },
    .{ "TT3", "TIT3" },  .{ "TXT", "TOLY" }, .{ "TXX", "TXXX" },  .{ "TYE", "TDRC" },
    .{ "UFI", "UFID" },  .{ "ULT", "USLT" }, .{ "WAF", "WOAF" },  .{ "WAR", "WOAR" },
    .{ "WAS", "WOAS" },  .{ "WCM", "WCOM" }, .{ "WCP", "WCOP" },  .{ "WPB", "WPUB" },
    .{ "WXX", "WXXX" },
    // 2.2 -> 2.4 Apple iTunes nonstandard frames
     .{ "PCS", "PCST" }, .{ "TCT", "TCAT" },  .{ "TDR", "TDRL" },
    .{ "TDS", "TDES" },  .{ "TID", "TGID" }, .{ "WFD", "WFED" },  .{ "MVN", "MVNM" },
    .{ "MVI", "MVIN" },  .{ "GP1", "GRP1" },
    // 2.3 -> 2.4
    .{ "TORY", "TDOR" }, .{ "TYER", "TDRC" },
    .{ "IPLS", "TIPL" },
});

const date_format = "YYYY-MM-DDThh:mm";

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

    var year = metadata.getFirst("TDRC");
    if (!isValidDateComponent(year)) return;
    date = date_buf[0..4];
    std.mem.copy(u8, date, (year.?)[0..4]);

    var maybe_daymonth = metadata.getFirst("TDAT");
    if (isValidDateComponent(maybe_daymonth)) {
        const daymonth = maybe_daymonth.?;
        date = date_buf[0..10];
        // TDAT is DDMM, we want -MM-DD
        var day = daymonth[0..2];
        var month = daymonth[2..4];
        _ = try std.fmt.bufPrint(date[4..10], "-{s}-{s}", .{ month, day });

        var maybe_time = metadata.getFirst("TIME");
        if (isValidDateComponent(maybe_time)) {
            const time = maybe_time.?;
            date = date_buf[0..];
            // TIME is HHMM
            var hours = time[0..2];
            var mins = time[2..4];
            _ = try std.fmt.bufPrint(date[10..], "T{s}:{s}", .{ hours, mins });
        }
    }

    try metadata.putOrReplaceFirst("TDRC", date);
}

fn compareTDRC(expected: *MetadataMap, actual: *MetadataMap) !void {
    const expected_count = expected.valueCount("TDRC").?;
    if (expected_count == 1) {
        const expected_value = expected.getFirst("TDRC").?;
        if (actual.getFirst("TDRC")) |actual_tdrc| {
            try std.testing.expectEqualStrings(expected_value, actual_tdrc);
        } else if (actual.getFirst("TYER")) |actual_tyer| {
            try std.testing.expectEqualStrings(expected_value, actual_tyer);
        } else {
            return error.MissingTDRC;
        }
    } else {
        unreachable; // TODO multiple TDRC values
    }
}

fn compareMetadataMapID3v2(allocator: *Allocator, expected: *MetadataMap, actual: *MetadataMap, id3_major_version: u8) !void {
    var actual_converted = try convertID3v2Alloc(allocator, actual, id3_major_version);
    defer actual_converted.deinit();

    for (expected.entries.items) |field| {
        // genre is messy, just skip it for now
        // TODO: dont skip it
        if (std.mem.eql(u8, field.name, "TCON")) {
            continue;
        }
        // TIPL (Involved people list) is also messy, since taglib converts from IPLS to TIPL
        else if (std.mem.eql(u8, field.name, "TIPL")) {
            continue;
        } else {
            if (actual_converted.contains(field.name)) {
                var expected_num_values = expected.valueCount(field.name).?;

                if (expected_num_values == 1) {
                    var actual_value = actual_converted.getFirst(field.name).?;

                    std.testing.expectEqualStrings(field.value, actual_value) catch |e| {
                        std.debug.print("\nfield: {s}\n", .{fmtUtf8SliceEscapeUpper(field.name)});
                        std.debug.print("\nexpected:\n", .{});
                        expected.dump();
                        std.debug.print("\nactual:\n", .{});
                        actual.dump();
                        std.debug.print("\nactual converted:\n", .{});
                        actual_converted.dump();
                        return e;
                    };
                } else {
                    const expected_values = (try expected.getAllAlloc(allocator, field.name)).?;
                    defer allocator.free(expected_values);
                    const actual_values = (try actual_converted.getAllAlloc(allocator, field.name)).?;
                    defer allocator.free(actual_values);

                    try std.testing.expectEqual(expected_values.len, actual_values.len);

                    for (expected_values) |expected_value| {
                        var found = false;
                        for (actual_values) |actual_value| {
                            if (std.mem.eql(u8, expected_value, actual_value)) {
                                found = true;
                                break;
                            }
                        }
                        if (!found) {
                            std.debug.print("\nfield: {s}\n", .{fmtUtf8SliceEscapeUpper(field.name)});
                            std.debug.print("\nexpected:\n", .{});
                            expected.dump();
                            std.debug.print("\nactual:\n", .{});
                            actual.dump();
                            std.debug.print("\nactual converted:\n", .{});
                            actual_converted.dump();
                            return error.ExpectedFieldValueNotFound;
                        }
                    }
                }
            } else {
                std.debug.print("\nmissing field {s}\n", .{field.name});
                std.debug.print("\nexpected:\n", .{});
                expected.dump();
                std.debug.print("\nactual:\n", .{});
                actual.dump();
                std.debug.print("\nactual converted:\n", .{});
                actual_converted.dump();
                return error.MissingField;
            }
        }
    }
}

fn compareMetadataMapFLAC(expected: *MetadataMap, actual: *MetadataMap) !void {
    expected_loop: for (expected.entries.items) |field| {
        var found_matching_key = false;
        for (actual.entries.items) |entry| {
            if (std.ascii.eqlIgnoreCase(field.name, entry.name)) {
                if (std.mem.eql(u8, field.value, entry.value)) {
                    continue :expected_loop;
                }
                found_matching_key = true;
            }
        }
        std.debug.print("field: {s}\n", .{fmtUtf8SliceEscapeUpper(field.name)});
        std.debug.print("\nexpected:\n", .{});
        expected.dump();
        std.debug.print("\nactual:\n", .{});
        actual.dump();
        if (found_matching_key) {
            return error.FieldValuesDontMatch;
        } else {
            return error.MissingField;
        }
    }
}

fn compareMetadata(allocator: *Allocator, all_expected: *AllMetadata, all_actual: *AllMetadata) !void {
    if (all_expected.all_id3v2) |all_id3v2_expected| {
        if (all_actual.all_id3v2) |all_id3v2_actual| {
            // taglib only parses the first id3 tag and skips the rest
            var expected = &all_id3v2_expected[0];
            var actual = &all_id3v2_actual[0];

            return compareMetadataMapID3v2(allocator, &expected.metadata.map, &actual.metadata.map, expected.major_version);
        } else {
            std.debug.print("\nexpected\n==================\n", .{});
            all_id3v2_expected[0].metadata.map.dump();
            std.debug.print("\n==================\n", .{});
            return error.MissingID3v2;
        }
    }
    if (all_expected.id3v1) |_| {
        if (all_actual.id3v1) |_| {} else {
            return error.MissingID3v1;
        }
    }
    if (all_expected.flac) |*expected| {
        if (all_actual.flac) |*actual| {
            return compareMetadataMapFLAC(&expected.map, &actual.map);
        } else {
            return error.MissingFLAC;
        }
    }
}

fn getTagLibMetadata(allocator: *std.mem.Allocator, cwd: ?std.fs.Dir, filepath: []const u8) !AllMetadata {
    const result = try std.ChildProcess.exec(.{
        .allocator = allocator,
        .argv = &[_][]const u8{
            "framelist",
            filepath,
        },
        .cwd_dir = cwd,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    var id3v2_slice: ?[]ID3v2Metadata = null;

    const maybe_metadata_start = std.mem.indexOf(u8, result.stdout, "ID3v2");
    if (maybe_metadata_start) |metadata_start| {
        var metadata_line = result.stdout[metadata_start..];
        const metadata_line_end = std.mem.indexOfScalar(u8, metadata_line, '\n').?;
        metadata_line = metadata_line[0..metadata_line_end];

        std.debug.print("metadataline: {s}\n", .{std.fmt.fmtSliceEscapeLower(metadata_line)});

        var major_version = try std.fmt.parseInt(u8, metadata_line[6..7], 10);
        // taglib doesn't render v2.2 frames AFAICT, and instead upgrades them to v2.3.
        // So bump major_version up to 3 here since we need to read the upgraded version.
        if (major_version == 2) {
            major_version = 3;
        }
        var num_frames_str = metadata_line[11..];
        const num_frames_end = std.mem.indexOfScalar(u8, num_frames_str, ' ').?;
        num_frames_str = num_frames_str[0..num_frames_end];
        const num_frames = try std.fmt.parseInt(usize, num_frames_str, 10);

        if (num_frames > 0) {
            const absolute_metadata_line_end_after_newline = metadata_start + metadata_line_end + 1;
            const frames_data = result.stdout[absolute_metadata_line_end_after_newline..];

            var fbs = std.io.fixedBufferStream(frames_data);
            var stream_source = std.io.StreamSource{ .buffer = fbs };
            var reader = stream_source.reader();
            var seekable_stream = stream_source.seekableStream();

            id3v2_slice = try allocator.alloc(ID3v2Metadata, 1);
            errdefer allocator.free(id3v2_slice.?);

            (id3v2_slice.?)[0] = ID3v2Metadata.init(allocator, major_version, 0, 0);
            var id3v2_metadata = &(id3v2_slice.?)[0];
            errdefer id3v2_metadata.deinit();

            var frame_i: usize = 0;
            while (frame_i < num_frames) : (frame_i += 1) {
                try id3.readFrame(allocator, reader, seekable_stream, id3v2_metadata, frames_data.len, false);
            }
        }
    }

    var flac_metadata: ?Metadata = null;
    errdefer if (flac_metadata != null) flac_metadata.?.deinit();

    const flac_start_string = "FLAC:::::::::\n";
    const maybe_flac_start = std.mem.indexOf(u8, result.stdout, flac_start_string);
    if (maybe_flac_start) |flac_start| {
        const flac_data_start = flac_start + flac_start_string.len;
        var flac_data = result.stdout[flac_data_start..];

        flac_metadata = Metadata.init(allocator);

        while (true) {
            var equals_index = std.mem.indexOfScalar(u8, flac_data, '=') orelse break;
            var name = flac_data[0..equals_index];
            const value_start_index = equals_index + 1;
            const start_value_string = "[====[";
            var start_quote_index = std.mem.indexOf(u8, flac_data[value_start_index..], start_value_string) orelse break;
            const abs_after_start_quote_index = value_start_index + start_quote_index + start_value_string.len;
            const end_value_string = "]====]";
            var end_quote_index = std.mem.indexOf(u8, flac_data[abs_after_start_quote_index..], end_value_string) orelse break;
            const abs_end_quote_index = abs_after_start_quote_index + end_quote_index;
            var value = flac_data[abs_after_start_quote_index..abs_end_quote_index];

            try flac_metadata.?.map.put(name, value);

            var after_linebreaks = abs_end_quote_index + end_value_string.len;
            while (after_linebreaks < flac_data.len and flac_data[after_linebreaks] == '\n') {
                after_linebreaks += 1;
            }

            flac_data = flac_data[after_linebreaks..];
        }
    }

    return AllMetadata{
        .all_id3v2 = id3v2_slice,
        .flac = flac_metadata,
        .id3v1 = null,
        .allocator = allocator,
    };
}

test "taglib compare" {
    const allocator = std.testing.allocator;
    //const filepath = "/media/drive4/music/Wolfpack - Allday Hell [EAC-FLAC]/01 - No Neo Bastards.flac";
    const filepath = "/media/drive4/music/'selvə - セルヴァ/'selvə- - セルヴァ - 01 estens.mp3";
    var probed_metadata = try getTagLibMetadata(allocator, null, filepath);
    defer probed_metadata.deinit();

    var file = try std.fs.cwd().openFile(filepath, .{});
    defer file.close();

    var stream_source = std.io.StreamSource{ .file = file };
    var metadata = try meta.readAll(allocator, &stream_source);
    defer metadata.deinit();

    try compareMetadata(allocator, &probed_metadata, &metadata);
}
