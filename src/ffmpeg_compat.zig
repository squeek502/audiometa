const std = @import("std");
const meta = @import("metadata.zig");
const AllMetadata = meta.AllMetadata;
const MetadataMap = meta.MetadataMap;
const Allocator = std.mem.Allocator;

pub fn coalesceMetadata(allocator: *Allocator, metadata: *AllMetadata) !MetadataMap {
    var coalesced = meta.MetadataMap.init(allocator);
    errdefer coalesced.deinit();

    if (metadata.flac_metadata) |*flac_metadata| {
        // since flac allows for duplicate fields, ffmpeg concats them with ;
        // because ffmpeg has a 'no duplicate fields' rule
        var names_it = flac_metadata.metadata.name_to_indexes.keyIterator();
        while (names_it.next()) |raw_name| {
            // vorbis metadata fields are case-insensitive, so convert to uppercase
            // for the lookup
            var upper_field = try std.ascii.allocUpperString(allocator, raw_name.*);
            defer allocator.free(upper_field);

            const name = flac_field_names.get(upper_field) orelse raw_name.*;
            var joined_value = (try flac_metadata.metadata.getJoinedAlloc(allocator, raw_name.*, ";")).?;
            defer allocator.free(joined_value);

            try coalesced.put(name, joined_value);
        }
    } else {
        if (metadata.id3v2_metadata) |id3v2_metadata_list| {
            for (id3v2_metadata_list) |*id3v2_metadata_container| {
                const id3v2_metadata = &id3v2_metadata_container.data.metadata;
                for (id3v2_metadata.entries.items) |entry| {
                    const name = convert_id_to_name(entry.name, id3v2_metadata_container.major_version) orelse entry.name;
                    if (!coalesced.contains(name)) {
                        try coalesced.put(name, entry.value);
                    }
                }
                if (!coalesced.contains("date")) {
                    try mergeDate(&coalesced);
                }
            }
        } else if (metadata.id3v1_metadata) |*id3v1_metadata| {
            // just a clone
            for (id3v1_metadata.metadata.entries.items) |entry| {
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

    var maybe_daymonth = metadata.getFirst("TDAT") orelse metadata.getFirst("TDA");
    if (isValidDateComponent(maybe_daymonth)) {
        const daymonth = maybe_daymonth.?;
        date = date_buf[0..10];
        // TDAT is DDMM, we want -MM-DD
        var day = daymonth[0..2];
        var month = daymonth[2..4];
        _ = try std.fmt.bufPrint(date[4..10], "-{s}-{s}", .{ month, day });

        var maybe_time = metadata.getFirst("TIME") orelse metadata.getFirst("TIM");
        if (isValidDateComponent(maybe_time)) {
            const time = maybe_time.?;
            date = date_buf[0..];
            // TIME is HHMM
            var hours = time[0..2];
            var mins = time[2..4];
            _ = try std.fmt.bufPrint(date[10..], " {s}:{s}", .{ hours, mins });
        }
    }

    try metadata.put("date", date);
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

fn convert_id_to_name(id: []const u8, major_version: u8) ?[]const u8 {
    switch (major_version) {
        0...2 => return id3v2_2_name_lookup.get(id),
        //3 => return id3v2_34_name_lookup.get(id),
        else => return id3v2_4_name_lookup.get(id) orelse id3v2_34_name_lookup.get(id),
    }
}
