const std = @import("std");
const audiometa = @import("audiometa");
const AllMetadata = audiometa.metadata.AllMetadata;
const MetadataEntry = audiometa.metadata.MetadataMap.Entry;
const FullTextEntry = audiometa.id3v2_data.FullTextMap.Entry;
const testing = std.testing;
const fmtUtf8SliceEscapeUpper = audiometa.util.fmtUtf8SliceEscapeUpper;
const Allocator = std.mem.Allocator;

pub const log_level: std.log.Level = .debug;

fn parseExpectedMetadata(comptime path: []const u8, expected_meta: ExpectedAllMetadata) !void {
    std.log.debug("{s}\n", .{path});
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
    try testing.expectEqual(all_expected.tags.len, all_actual.tags.len);
    for (all_expected.tags) |expected_tag, i| {
        const actual_tag = all_actual.tags[i];
        try testing.expectEqual(std.meta.activeTag(expected_tag), std.meta.activeTag(actual_tag));
        switch (expected_tag) {
            .id3v2 => {
                try testing.expectEqual(expected_tag.id3v2.major_version, actual_tag.id3v2.header.major_version);
                try testing.expectEqual(expected_tag.id3v2.comments.len, actual_tag.id3v2.comments.entries.items.len);
                for (expected_tag.id3v2.comments) |expected_comment, comment_i| {
                    const actual_comment = actual_tag.id3v2.comments.entries.items[comment_i];
                    try compareFullText(expected_comment, actual_comment);
                }
                for (expected_tag.id3v2.unsynchronized_lyrics) |expected_lyrics, lyrics_i| {
                    const actual_lyrics = actual_tag.id3v2.unsynchronized_lyrics.entries.items[lyrics_i];
                    try compareFullText(expected_lyrics, actual_lyrics);
                }
            },
            .ape => {
                try testing.expectEqual(expected_tag.ape.version, actual_tag.ape.header_or_footer.version);
            },
            else => {},
        }
        try compareMetadata(expected_tag.getMetadata(), actual_tag.getMetadata());
    }
}

fn compareFullText(expected: FullTextEntry, actual: FullTextEntry) !void {
    try testing.expectEqualStrings(expected.language, actual.language);
    try testing.expectEqualStrings(expected.description, actual.description);
    try testing.expectEqualStrings(expected.value, actual.value);
}

fn compareMetadata(expected: ExpectedMetadata, actual: audiometa.metadata.Metadata) !void {
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

pub const ExpectedTypedMetadata = union(audiometa.metadata.MetadataType) {
    id3v1: ExpectedMetadata,
    id3v2: ExpectedID3v2Metadata,
    ape: ExpectedAPEMetadata,
    flac: ExpectedMetadata,
    vorbis: ExpectedMetadata,

    /// Convenience function to get the ExpectedMetadata for any TypedMetadata
    pub fn getMetadata(typed_meta: ExpectedTypedMetadata) ExpectedMetadata {
        return switch (typed_meta) {
            .id3v1, .flac, .vorbis => |val| val,
            .id3v2 => |val| val.metadata,
            .ape => |val| val.metadata,
        };
    }
};
const ExpectedAllMetadata = struct {
    tags: []const ExpectedTypedMetadata,

    pub fn dump(self: *const ExpectedAllMetadata) void {
        for (self.tags) |tag| {
            switch (tag) {
                .id3v1 => |*id3v1_meta| {
                    std.debug.print("# ID3v1 0x{x}-0x{x}\n", .{ id3v1_meta.start_offset, id3v1_meta.end_offset });
                    id3v1_meta.dump();
                },
                .flac => |*flac_meta| {
                    std.debug.print("# FLAC 0x{x}-0x{x}\n", .{ flac_meta.start_offset, flac_meta.end_offset });
                    flac_meta.dump();
                },
                .vorbis => |*vorbis_meta| {
                    std.debug.print("# Vorbis 0x{x}-0x{x}\n", .{ vorbis_meta.start_offset, vorbis_meta.end_offset });
                    vorbis_meta.dump();
                },
                .id3v2 => |*id3v2_meta| {
                    std.debug.print("# ID3v2 v2.{d} 0x{x}-0x{x}\n", .{ id3v2_meta.major_version, id3v2_meta.metadata.start_offset, id3v2_meta.metadata.end_offset });
                    id3v2_meta.metadata.dump();
                },
                .ape => |*ape_meta| {
                    std.debug.print("# APEv{d} 0x{x}-0x{x}\n", .{ ape_meta.version, ape_meta.metadata.start_offset, ape_meta.metadata.end_offset });
                    ape_meta.metadata.dump();
                },
            }
        }
    }
};
const ExpectedID3v2Metadata = struct {
    metadata: ExpectedMetadata,
    major_version: u8,
    comments: []const FullTextEntry = &[_]FullTextEntry{},
    unsynchronized_lyrics: []const FullTextEntry = &[_]FullTextEntry{},
};
const ExpectedAPEMetadata = struct {
    version: u32,
    metadata: ExpectedMetadata,
};
const ExpectedMetadata = struct {
    start_offset: usize,
    end_offset: usize,
    map: []const MetadataEntry,

    pub fn dump(metadata: *const ExpectedMetadata) void {
        for (metadata.map) |entry| {
            std.debug.print("{s}={s}\n", .{ fmtUtf8SliceEscapeUpper(entry.name), fmtUtf8SliceEscapeUpper(entry.value) });
        }
    }
};

test "standard id3v1" {
    try parseExpectedMetadata("data/id3v1.mp3", .{ .tags = &.{
        .{ .id3v1 = .{
            .start_offset = 0x0,
            .end_offset = 0x80,
            .map = &[_]MetadataEntry{
                .{ .name = "title", .value = "Blind" },
                .{ .name = "artist", .value = "Acme" },
                .{ .name = "album", .value = "... to reduce the choir to one" },
                .{ .name = "track", .value = "1" },
                .{ .name = "genre", .value = "Blues" },
            },
        } },
    } });
}

test "empty (all zeros) id3v1" {
    try parseExpectedMetadata("data/id3v1_empty.mp3", .{ .tags = &.{
        .{ .id3v1 = .{
            .start_offset = 0x0,
            .end_offset = 0x80,
            .map = &[_]MetadataEntry{
                .{ .name = "genre", .value = "Blues" },
            },
        } },
    } });
}

test "id3v1 with non-ASCII chars (latin1)" {
    try parseExpectedMetadata("data/id3v1_latin1_chars.mp3", .{ .tags = &.{
        .{ .id3v1 = .{
            .start_offset = 0x0,
            .end_offset = 0x80,
            .map = &[_]MetadataEntry{
                .{ .name = "title", .value = "Introducción" },
                .{ .name = "artist", .value = "3rdage Attack" },
                .{ .name = "album", .value = "3rdage Attack" },
                .{ .name = "date", .value = "2007" },
                .{ .name = "track", .value = "1" },
            },
        } },
    } });
}

test "id3v2.3 with UTF-16" {
    try parseExpectedMetadata("data/id3v2.3.mp3", .{ .tags = &.{
        .{ .id3v2 = .{
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
            .comments = &.{.{
                .language = "eng",
                .description = "",
                .value = "EAC V1.0 beta 2, Secure Mode, Test & Copy, AccurateRip, FLAC -8",
            }},
        } },
        .{ .id3v1 = .{
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
        } },
    } });
}

test "id3v2.3 with UTF-16 big endian" {
    try parseExpectedMetadata("data/id3v2.3_utf16_be.mp3", .{ .tags = &.{
        .{ .id3v2 = .{
            .major_version = 3,
            .metadata = .{
                .start_offset = 0x0,
                .end_offset = 0x120,
                .map = &[_]MetadataEntry{
                    .{ .name = "TSSE", .value = "LAME 32bits version 3.98 (http://www.mp3dev.org/)" },
                    .{ .name = "TIT2", .value = "No Island of Dreams" },
                    .{ .name = "TPE1", .value = "Conflict" },
                    .{ .name = "TALB", .value = "It's Time To See Who's Who Now" },
                    .{ .name = "TCON", .value = "Punk" },
                    .{ .name = "TRCK", .value = "2" },
                    .{ .name = "TYER", .value = "1985" },
                    .{ .name = "TLEN", .value = "168000" },
                },
            },
        } },
    } });
}

test "id3v2.3 with user defined fields (TXXX)" {
    try parseExpectedMetadata("data/id3v2.3_user_defined_fields.mp3", .{ .tags = &.{
        .{ .id3v2 = .{
            .major_version = 3,
            .metadata = .{
                .start_offset = 0x0,
                .end_offset = 0x937,
                .map = &[_]MetadataEntry{
                    .{ .name = "TLAN", .value = "eng" },
                    .{ .name = "TRCK", .value = "1/14" },
                    .{ .name = "TPE1", .value = "Acephalix" },
                    .{ .name = "TIT2", .value = "Immanent" },
                    .{ .name = "Rip date", .value = "2010-09-20" },
                    .{ .name = "TYER", .value = "2010" },
                    .{ .name = "TDAT", .value = "0000" },
                    .{ .name = "Source", .value = "CD" },
                    .{ .name = "TSSE", .value = "LAME 3.97 (-V2 --vbr-new)" },
                    .{ .name = "Release type", .value = "Normal release" },
                    .{ .name = "TCON", .value = "Hardcore" },
                    .{ .name = "TPUB", .value = "Prank Records" },
                    .{ .name = "Catalog #", .value = "Prank 110" },
                    .{ .name = "TALB", .value = "Aporia" },
                },
            },
        } },
    } });
}

test "id3v2.3 with full unsynch tag" {
    try parseExpectedMetadata("data/id3v2.3_unsynch_tag.mp3", .{ .tags = &.{
        .{ .id3v2 = .{
            .major_version = 3,
            .metadata = .{
                .start_offset = 0x0,
                .end_offset = 0x11D3,
                .map = &[_]MetadataEntry{
                    .{ .name = "TIT2", .value = "Intro" },
                    .{ .name = "TPE1", .value = "Disgust" },
                    .{ .name = "TALB", .value = "Brutality of War" },
                    .{ .name = "TRCK", .value = "01/15" },
                    .{ .name = "TLEN", .value = "68173" },
                    .{ .name = "TCON", .value = "Other" },
                    .{ .name = "TENC", .value = "Exact Audio Copy   (Secure mode)" },
                    .{ .name = "TSSE", .value = "flac.exe -V -8 -T \"artist=Disgust\" -T \"title=Intro\" -T \"album=Brutality of War\" -T \"date=\" -T \"tracknumber=01\" -T \"genre=Other\"" },
                },
            },
            .comments = &.{.{ .language = "eng", .description = "", .value = "Track 1" }},
        } },
    } });
}

test "id3v2.3 with id3v2.2 frame ids" {
    try parseExpectedMetadata("data/id3v2.3_with_id3v2.2_frame_ids.mp3", .{ .tags = &.{
        .{ .id3v2 = .{
            .major_version = 3,
            .metadata = .{
                .start_offset = 0x0,
                .end_offset = 0x1154,
                .map = &[_]MetadataEntry{
                    .{ .name = "TENC", .value = "iTunes v7.6.1" },
                    .{ .name = "TIT2", .value = "Religion Is Fear" },
                    .{ .name = "TYER", .value = "2008" },
                    .{ .name = "TCON", .value = "Grindcore" },
                    .{ .name = "TALB", .value = "Trap Them & Extreme Noise Terror Split 7\"EP" },
                    .{ .name = "TRCK", .value = "1" },
                    .{ .name = "TPE1", .value = "Extreme Noise Terror" },
                    .{ .name = "TCP", .value = "1" },
                },
            },
            .comments = &.{
                .{
                    .language = "eng",
                    .description = "",
                    .value = "0",
                },
                .{
                    .language = "eng",
                    .description = "",
                    .value = " 000028FD 00002EAF 000060E8 00008164 00005997 00005997 00008E2B 00008E97 000125C6 00011263",
                },
                .{
                    .language = "eng",
                    .description = "",
                    .value = " 00000000 00000210 00000978 00000000003E6478 00000000 0021E72F 00000000 00000000 00000000 00000000 00000000 00000000",
                },
                .{
                    .language = "eng",
                    .description = "",
                    .value = "www.deathwishinc.com",
                },
            },
        } },
    } });
}

test "id3v2.3 with text frame with zero size" {
    try parseExpectedMetadata("data/id3v2.3_text_frame_with_zero_size.mp3", .{ .tags = &.{
        .{ .id3v2 = .{
            .major_version = 3,
            .metadata = .{
                .start_offset = 0x0,
                .end_offset = 0x183,
                .map = &[_]MetadataEntry{
                    .{ .name = "TCON", .value = "(129)Hardcore" },
                    .{ .name = "TRCK", .value = "1" },
                    .{ .name = "TYER", .value = "2004" },
                    .{ .name = "TALB", .value = "Italian Girls (The Best In The World)" },
                    .{ .name = "TPE1", .value = "A Taste For Murder" },
                    .{ .name = "TIT2", .value = "Rosario" },
                    .{ .name = "TENC", .value = "" },
                    .{ .name = "TCOP", .value = "" },
                    .{ .name = "TOPE", .value = "" },
                    .{ .name = "TCOM", .value = "" },
                },
            },
            .comments = &.{.{
                .language = "eng",
                .description = "",
                .value = "                            ",
            }},
        } },
    } });
}

test "id3v2.2" {
    try parseExpectedMetadata("data/id3v2.2.mp3", .{ .tags = &.{
        .{ .id3v2 = .{
            .major_version = 2,
            .metadata = .{
                .start_offset = 0x0,
                .end_offset = 0x86E,
                .map = &[_]MetadataEntry{
                    .{ .name = "TT2", .value = "side a" },
                    .{ .name = "TP1", .value = "a warm gun" },
                    .{ .name = "TAL", .value = "escape" },
                    .{ .name = "TRK", .value = "1" },
                    .{ .name = "TEN", .value = "iTunes 8.0.1.11" },
                },
            },
            .comments = &.{
                .{
                    .language = "eng",
                    .description = "iTunPGAP",
                    .value = "0",
                },
                .{
                    .language = "eng",
                    .description = "iTunNORM",
                    .value = " 00000318 0000031C 00001032 00000A21 00014C8D 0001F4D0 00004B10 0000430B 0000E61A 00003A43",
                },
                .{
                    .language = "eng",
                    .description = "iTunSMPB",
                    .value = " 00000000 00000210 00000726 00000000014408CA 00000000 0092E82A 00000000 00000000 00000000 00000000 00000000 00000000",
                },
            },
        } },
    } });
}

test "id3v2.4 utf16 frames with single u8 delimeters" {
    try parseExpectedMetadata("data/id3v2.4_utf16_single_u8_delimeter.mp3", .{ .tags = &.{
        .{ .id3v2 = .{
            .major_version = 4,
            .metadata = .{
                .start_offset = 0x0,
                .end_offset = 0x980,
                .map = &[_]MetadataEntry{
                    .{ .name = "TDRC", .value = "2010" },
                    .{ .name = "TRCK", .value = "1/9" },
                    .{ .name = "TPOS", .value = "1/1" },
                    .{ .name = "TCOM", .value = "Mar de Grises" },
                    .{ .name = "PERFORMER", .value = "Mar de Grises" },
                    .{ .name = "ALBUM ARTIST", .value = "Mar de Grises" },
                    .{ .name = "TIT2", .value = "Starmaker" },
                    .{ .name = "TPE1", .value = "Mar de Grises" },
                    .{ .name = "TALB", .value = "Streams Inwards" },
                    .{ .name = "TCOM", .value = "" },
                    .{ .name = "TPE3", .value = "" },
                    .{ .name = "TPE2", .value = "Mar de Grises" },
                    .{ .name = "TCON", .value = "Death Metal, doom metal, atmospheric" },
                },
            },
        } },
    } });
}

test "id3v2.3 zero size frame" {
    try parseExpectedMetadata("data/id3v2.3_zero_size_frame.mp3", .{ .tags = &.{
        .{ .id3v2 = .{
            .major_version = 3,
            .metadata = .{
                .start_offset = 0x0,
                .end_offset = 0x1000,
                .map = &[_]MetadataEntry{
                    .{ .name = "TFLT", .value = "audio/mp3" },
                    .{ .name = "TIT2", .value = "the global cannibal" },
                    .{ .name = "TALB", .value = "Global Cannibal, The" },
                    .{ .name = "TRCK", .value = "1" },
                    .{ .name = "TYER", .value = "2004" },
                    .{ .name = "TCON", .value = "Crust" },
                    .{ .name = "TPE1", .value = "Behind Enemy Lines" },
                    .{ .name = "TENC", .value = "" },
                    .{ .name = "TCOP", .value = "" },
                    .{ .name = "TCOM", .value = "" },
                    .{ .name = "TOPE", .value = "" },
                },
            },
            .comments = &.{
                .{ .language = "eng", .description = "", .value = "" },
                .{ .language = "\x00\x00\x00", .description = "", .value = "" },
            },
        } },
    } });
}

test "id3v2.4 non-synchsafe frame size" {
    try parseExpectedMetadata("data/id3v2.4_non_synchsafe_frame_size.mp3", .{ .tags = &.{
        .{ .id3v2 = .{
            .major_version = 4,
            .metadata = .{
                .start_offset = 0x0,
                .end_offset = 0xD6C,
                .map = &[_]MetadataEntry{
                    .{ .name = "TLEN", .value = "302813" },
                    .{ .name = "TIT2", .value = "Inevitable" },
                    .{ .name = "TPE1", .value = "Mushroomhead" },
                    .{ .name = "TALB", .value = "M3" },
                    .{ .name = "TRCK", .value = "4" },
                    .{ .name = "TDRC", .value = "1999" },
                    .{ .name = "TCON", .value = "(12)" },
                },
            },
        } },
    } });
}

test "id3v2.4 extended header with crc" {
    try parseExpectedMetadata("data/id3v2.4_extended_header_crc.mp3", .{ .tags = &.{
        .{ .id3v2 = .{
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
        } },
    } });
}

test "id3v2.4 footer" {
    try parseExpectedMetadata("data/id3v2.4_footer.mp3", .{ .tags = &.{
        .{ .id3v2 = .{
            .major_version = 4,
            .metadata = .{
                .start_offset = 0x0,
                .end_offset = 0x5D,
                .map = &[_]MetadataEntry{
                    .{ .name = "TIT2", .value = "Test" },
                    .{ .name = "TPE1", .value = "Test2" },
                    .{ .name = "TPE2", .value = "Test2" },
                },
            },
        } },
    } });
}

test "id3v2.4 appended tag" {
    try parseExpectedMetadata("data/id3v2.4_appended.mp3", .{ .tags = &.{
        .{ .id3v2 = .{
            .major_version = 4,
            .metadata = .{
                .start_offset = 0x18,
                .end_offset = 0x75,
                .map = &[_]MetadataEntry{
                    .{ .name = "TIT2", .value = "Test" },
                    .{ .name = "TPE1", .value = "Test2" },
                    .{ .name = "TPE2", .value = "Test2" },
                },
            },
        } },
    } });
}

test "normal flac" {
    try parseExpectedMetadata("data/flac.flac", .{ .tags = &.{
        .{ .flac = .{
            .start_offset = 0x8,
            .end_offset = 0x14C,
            .map = &[_]MetadataEntry{
                .{ .name = "ALBUM", .value = "Muga" },
                .{ .name = "ALBUMARTIST", .value = "Muga" },
                .{ .name = "ARTIST", .value = "Muga" },
                .{ .name = "COMMENT", .value = "EAC V1.0 beta 2, Secure Mode, Test & Copy, AccurateRip, FLAC -8" },
                .{ .name = "DATE", .value = "2002" },
                .{ .name = "DISCNUMBER", .value = "1" },
                .{ .name = "MEDIAFORMAT", .value = "CD" },
                .{ .name = "PERFORMER", .value = "Muga" },
                .{ .name = "TITLE", .value = "死前解放 (Unleash Before Death)" },
                .{ .name = "DISCTOTAL", .value = "1" },
                .{ .name = "TRACKTOTAL", .value = "11" },
                .{ .name = "TRACKNUMBER", .value = "02" },
            },
        } },
    } });
}

test "flac with multiple date fields" {
    try parseExpectedMetadata("data/flac_multiple_dates.flac", .{ .tags = &.{
        .{ .flac = .{
            .start_offset = 0x8,
            .end_offset = 0x165,
            .map = &[_]MetadataEntry{
                .{ .name = "TITLE", .value = "The Echoes Waned" },
                .{ .name = "TRACKTOTAL", .value = "6" },
                .{ .name = "DISCTOTAL", .value = "1" },
                .{ .name = "LENGTH", .value = "389" },
                .{ .name = "ISRC", .value = "USA2Z1810265" },
                .{ .name = "BARCODE", .value = "647603399720" },
                .{ .name = "ITUNESADVISORY", .value = "0" },
                .{ .name = "COPYRIGHT", .value = "(C) 2018 The Flenser" },
                .{ .name = "Album", .value = "The Unraveling" },
                .{ .name = "Artist", .value = "Ails" },
                .{ .name = "Genre", .value = "Metal" },
                .{ .name = "ALBUMARTIST", .value = "Ails" },
                .{ .name = "DISCNUMBER", .value = "1" },
                .{ .name = "DATE", .value = "2018" },
                .{ .name = "DATE", .value = "2018-04-20" },
                .{ .name = "TRACKNUMBER", .value = "1" },
            },
        } },
    } });
}

test "id3v2.4 unsynch text frames" {
    try parseExpectedMetadata("data/id3v2.4_unsynch_text_frames.mp3", .{ .tags = &.{
        .{ .id3v2 = .{
            .major_version = 4,
            .metadata = .{
                .start_offset = 0x0,
                .end_offset = 0x2170,
                .map = &[_]MetadataEntry{
                    .{ .name = "TCON", .value = "Alternative" },
                    .{ .name = "TDRC", .value = "1997" },
                    .{ .name = "TRCK", .value = "1" },
                    .{ .name = "TALB", .value = "Bruiser Queen" },
                    .{ .name = "TPE1", .value = "Cake Like" },
                    .{ .name = "TLEN", .value = "137000" },
                    .{ .name = "TPUB", .value = "Vapor Records" },
                    .{ .name = "TIT2", .value = "The New Girl" },
                },
            },
        } },
    } });
}

test "id3v2.3 malformed TXXX" {
    try parseExpectedMetadata("data/id3v2.3_malformed_txxx.mp3", .{ .tags = &.{
        .{ .id3v2 = .{
            .major_version = 3,
            .metadata = .{
                .start_offset = 0x0,
                .end_offset = 0x43,
                .map = &[_]MetadataEntry{},
            },
        } },
    } });
}

test "id3v2.4 malformed TXXX" {
    try parseExpectedMetadata("data/id3v2.4_malformed_txxx.mp3", .{ .tags = &.{
        .{ .id3v2 = .{
            .major_version = 4,
            .metadata = .{
                .start_offset = 0x0,
                .end_offset = 0x3B,
                .map = &[_]MetadataEntry{},
            },
        } },
    } });
}

test "id3v2.3 unsynch tag edge case" {
    // Found via fuzzing. Has a full unsynch tag that has an end frame header with
    // unsynch bytes that extends to the end of the tag. This can trigger an
    // usize underflow if it's not protected against properly.
    try parseExpectedMetadata("data/id3v2.3_unsynch_tag_edge_case.mp3", .{ .tags = &.{
        .{ .id3v2 = .{
            .major_version = 3,
            .metadata = .{
                .start_offset = 0x0,
                .end_offset = 0x43,
                .map = &[_]MetadataEntry{},
            },
        } },
    } });
}

test "id3v2.4 text frame with multiple terminated values" {
    try parseExpectedMetadata("data/id3v2.4_text_frame_with_multiple_terminated_values.mp3", .{ .tags = &.{
        .{ .id3v2 = .{
            .major_version = 4,
            .metadata = .{
                .start_offset = 0x0,
                .end_offset = 0x1ba,
                .map = &[_]MetadataEntry{
                    .{ .name = "TCON", .value = "Hardcore" },
                    .{ .name = "TDRC", .value = "2006" },
                    .{ .name = "TRCK", .value = "2" },
                    .{ .name = "TCOM", .value = "Aram Arslanian" },
                    .{ .name = "TCOM", .value = "Todd Jones" },
                    .{ .name = "COMMENT", .value = " 00001E45 000026CD 00006B50 00008F5A 0001AB0A 00001ED0 00008611 000087E7 0000976D 00002AC1" },
                    .{ .name = "COMMENT", .value = " 00000000 00000210 00000924 000000000063EC4C 00000000 00000000 00000000 00000000 00000000 00000000 00000000 00000000" },
                    .{ .name = "COMMENT", .value = "D708EF10+171732+16+150+5249+16386+24551+36270+46625+54484+66325+79815+92681+96508+105514+119240+130979+146268+158072" },
                    .{ .name = "COMMENT", .value = "2" },
                },
            },
        } },
    } });
}

test "id3v2.4 incorrectly encoded (non-synchsafe) frame size edge cases" {
    // frame with non-synchsafe byte in the size
    try parseExpectedMetadata("data/id3v2.4_non_synchsafe_frame_size_bytes.mp3", .{ .tags = &.{
        .{ .id3v2 = .{
            .major_version = 4,
            .metadata = .{
                .start_offset = 0x0,
                .end_offset = 0x3f8,
                .map = &[_]MetadataEntry{},
            },
            .unsynchronized_lyrics = &.{.{
                .language = "eng",
                .description = "",
                .value = "Lorem ipsum dolor sit amet, consectetur adipiscing elit. Quisque convallis ut nunc sit amet fringilla. Pellentesque tempor posuere dui, at commodo urna porttitor quis. Nunc tristique mollis lacus, ut ullamcorper odio finibus nec. Integer imperdiet orci a dolor maximus molestie. Maecenas quis faucibus odio. Donec molestie lectus magna, ac consequat ex posuere vitae. Praesent mauris diam, tempus et tempus in, dictum sit amet metus. Vestibulum ante ipsum primis in faucibus orci luctus et ultrices posuere cubilia curae;\n\nUt non arcu pretium libero rutrum commodo. Mauris arcu ante, feugiat non vestibulum vitae, venenatis ac dui. Sed commodo magna vitae id.",
            }},
        } },
    } });
    // incorrectly encoded frame size that runs up against padding
    try parseExpectedMetadata("data/id3v2.4_non_synchsafe_frame_size_padding.mp3", .{ .tags = &.{
        .{ .id3v2 = .{
            .major_version = 4,
            .metadata = .{
                .start_offset = 0x0,
                .end_offset = 0x262,
                .map = &[_]MetadataEntry{},
            },
            .unsynchronized_lyrics = &.{.{
                .language = "eng",
                .description = "",
                .value = "Lorem ipsum dolor sit amet, consectetur adipiscing elit. Quisque convallis ut nunc sit amet fringilla. Pellentesque tempor posuere dui, at commodo urna porttitor quis. Nunc tristique mollis lacus, ut ullamcorper odio finibus nec. Integer imperdiet orci",
            }},
        } },
    } });
    // incorrectly encoded frame size that runs up against EOF exactly
    try parseExpectedMetadata("data/id3v2.4_non_synchsafe_frame_size_eof.mp3", .{ .tags = &.{
        .{ .id3v2 = .{
            .major_version = 4,
            .metadata = .{
                .start_offset = 0x0,
                .end_offset = 0x115,
                .map = &[_]MetadataEntry{},
            },
            .unsynchronized_lyrics = &.{.{
                .language = "eng",
                .description = "",
                .value = "Lorem ipsum dolor sit amet, consectetur adipiscing elit. Quisque convallis ut nunc sit amet fringilla. Pellentesque tempor posuere dui, at commodo urna porttitor quis. Nunc tristique mollis lacus, ut ullamcorper odio finibus nec. Integer imperdiet orci",
            }},
        } },
    } });
}

test "id3v2.4 correctly encoded frame size edge cases" {
    // correctly encoded frame that runs up against padding
    try parseExpectedMetadata("data/id3v2.4_synchsafe_frame_size_padding.mp3", .{ .tags = &.{
        .{ .id3v2 = .{
            .major_version = 4,
            .metadata = .{
                .start_offset = 0x0,
                .end_offset = 0x262,
                .map = &[_]MetadataEntry{},
            },
            .unsynchronized_lyrics = &.{.{
                .language = "eng",
                .description = "",
                .value = "Lorem ipsum dolor sit amet, consectetur adipiscing elit. Quisque convallis ut nunc sit amet fringilla. Pellentesque tempor posuere dui, at commodo urna porttitor quis. Nunc tristique mollis lacus, ut ullamcorper odio finibus nec. Integer imperdiet orci",
            }},
        } },
    } });
    // correctly encoded frame that runs up against EOF exactly
    try parseExpectedMetadata("data/id3v2.4_synchsafe_frame_size_eof.mp3", .{ .tags = &.{
        .{ .id3v2 = .{
            .major_version = 4,
            .metadata = .{
                .start_offset = 0x0,
                .end_offset = 0x115,
                .map = &[_]MetadataEntry{},
            },
            .unsynchronized_lyrics = &.{.{
                .language = "eng",
                .description = "",
                .value = "Lorem ipsum dolor sit amet, consectetur adipiscing elit. Quisque convallis ut nunc sit amet fringilla. Pellentesque tempor posuere dui, at commodo urna porttitor quis. Nunc tristique mollis lacus, ut ullamcorper odio finibus nec. Integer imperdiet orci",
            }},
        } },
    } });
}

test "ogg" {
    try parseExpectedMetadata("data/vorbis.ogg", .{ .tags = &.{
        .{ .vorbis = .{
            .start_offset = 0x6d,
            .end_offset = 0x10e,
            .map = &[_]MetadataEntry{
                .{ .name = "ALBUM", .value = "PIRATE" },
                .{ .name = "ARTIST", .value = "TROMATISM" },
                .{ .name = "GENRE", .value = "PUNK" },
                .{ .name = "TITLE", .value = "Paria" },
                .{ .name = "TRACKNUMBER", .value = "20" },
                .{ .name = "COMMENT", .value = "http://www.sauve-qui-punk.org" },
            },
        } },
    } });
}

test "ogg with vorbis comment data spanning multiple pages" {
    try parseExpectedMetadata("data/vorbis_comment_spanning_pages.ogg", .{ .tags = &.{
        .{ .vorbis = .{
            .start_offset = 0x5d,
            .end_offset = 0x11a,
            .map = &[_]MetadataEntry{
                .{ .name = "ALBUM", .value = "PIRATE" },
                .{ .name = "ARTIST", .value = "TROMATISM" },
                .{ .name = "GENRE", .value = "PUNK" },
                .{ .name = "TITLE", .value = "Paria" },
                .{ .name = "TRACKNUMBER", .value = "20" },
                .{ .name = "COMMENT", .value = "http://www.sauve-qui-punk.org" },
            },
        } },
    } });
}

test "ape" {
    try parseExpectedMetadata("data/ape.mp3", .{ .tags = &.{
        .{ .ape = .{
            .version = 2000,
            .metadata = .{
                .start_offset = 0x0,
                .end_offset = 0xce,
                .map = &[_]MetadataEntry{
                    .{ .name = "MP3GAIN_MINMAX", .value = "151,190" },
                    .{ .name = "MP3GAIN_UNDO", .value = "-006,-006,N" },
                    .{ .name = "REPLAYGAIN_TRACK_GAIN", .value = "-11.27000 dB" },
                    .{ .name = "REPLAYGAIN_TRACK_PEAK", .value = "2.003078" },
                },
            },
        } },
    } });
}

test "ape with id3v2 and id3v1 tags" {
    try parseExpectedMetadata("data/ape_and_id3.mp3", .{ .tags = &.{
        .{ .id3v2 = .{
            .major_version = 3,
            .metadata = .{
                .start_offset = 0x0,
                .end_offset = 0x998,
                .map = &[_]MetadataEntry{
                    .{ .name = "TLAN", .value = "rus" },
                    .{ .name = "TRCK", .value = "1/7" },
                    .{ .name = "TPE1", .value = "Axidance" },
                    .{ .name = "Rip date", .value = "2012-08-10" },
                    .{ .name = "TYER", .value = "2012" },
                    .{ .name = "TDAT", .value = "0000" },
                    .{ .name = "Source", .value = "Vinyl" },
                    .{ .name = "TSSE", .value = "LAME v3.98.4 with preset -V0" },
                    .{ .name = "Ripping tool", .value = "Sony Sound Forge Pro v10.0a" },
                    .{ .name = "Release type", .value = "Split 12inch" },
                    .{ .name = "TCON", .value = "Hardcore" },
                    .{ .name = "Language 2-letter", .value = "RU" },
                    .{ .name = "TPUB", .value = "pure heart" },
                    .{ .name = "VA Artist", .value = "Axidance" },
                    .{ .name = "TALB", .value = "Gattaca" },
                    .{ .name = "TIT2", .value = "Aeon I - The Great Enemy" },
                },
            },
        } },
        .{ .ape = .{
            .version = 2000,
            .metadata = .{
                .start_offset = 0x998,
                .end_offset = 0xba4,
                .map = &[_]MetadataEntry{
                    .{ .name = "Language", .value = "Russian" },
                    .{ .name = "Disc", .value = "1" },
                    .{ .name = "Track", .value = "1" },
                    .{ .name = "Artist", .value = "Axidance" },
                    .{ .name = "Rip Date", .value = "2012-08-10" },
                    .{ .name = "Year", .value = "2012" },
                    .{ .name = "Retail Date", .value = "2012-00-00" },
                    .{ .name = "Media", .value = "Vinyl" },
                    .{ .name = "Encoder", .value = "LAME v3.98.4 with preset -V0" },
                    .{ .name = "Ripping Tool", .value = "Sony Sound Forge Pro v10.0a" },
                    .{ .name = "Release Type", .value = "Split 12inch" },
                    .{ .name = "Genre", .value = "Hardcore" },
                    .{ .name = "Language 2-letter", .value = "RU" },
                    .{ .name = "Publisher", .value = "pure heart" },
                    .{ .name = "Album Artist", .value = "Axidance" },
                    .{ .name = "Album", .value = "Gattaca" },
                    .{ .name = "Title", .value = "Aeon I - The Great Enemy" },
                },
            },
        } },
        .{ .id3v1 = .{
            .start_offset = 0xba4,
            .end_offset = 0xc24,
            .map = &[_]MetadataEntry{
                .{ .name = "title", .value = "Aeon I - The Great Enemy" },
                .{ .name = "artist", .value = "Axidance" },
                .{ .name = "album", .value = "Gattaca" },
                .{ .name = "date", .value = "2012" },
                .{ .name = "track", .value = "1" },
                .{ .name = "genre", .value = "Hardcore Techno" },
            },
        } },
    } });
}
