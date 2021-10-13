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
            try testing.expectEqual(all_id3v2_expected.len, all_id3v2_actual.tags.len);
            for (all_id3v2_expected) |id3v2_expected, i| {
                try testing.expectEqual(id3v2_expected.major_version, all_id3v2_actual.tags[i].header.major_version);
                try compareMetadata(&id3v2_expected.metadata, &all_id3v2_actual.tags[i].metadata);
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
    if (all_expected.vorbis) |*expected| {
        if (all_actual.vorbis) |*actual| {
            return compareMetadata(expected, actual);
        } else {
            return error.MissingVorbis;
        }
    } else if (all_actual.vorbis != null) {
        return error.UnexpectedVorbis;
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
    all_id3v2: ?[]const ExpectedID3v2Metadata = null,
    id3v1: ?ExpectedMetadata = null,
    flac: ?ExpectedMetadata = null,
    vorbis: ?ExpectedMetadata = null,

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
        if (self.vorbis) |vorbis_meta| {
            std.debug.print("# Vorbis 0x{x}-0x{x}\n", .{ vorbis_meta.start_offset, vorbis_meta.end_offset });
            for (vorbis_meta.map) |entry| {
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

test "standard id3v1" {
    try parseExpectedMetadata("data/id3v1.mp3", .{
        .id3v1 = .{
            .start_offset = 0x0,
            .end_offset = 0x80,
            .map = &[_]MetadataEntry{
                .{ .name = "title", .value = "Blind" },
                .{ .name = "artist", .value = "Acme" },
                .{ .name = "album", .value = "... to reduce the choir to one" },
                .{ .name = "track", .value = "1" },
                .{ .name = "genre", .value = "Blues" },
            },
        },
    });
}

test "empty (all zeros) id3v1" {
    try parseExpectedMetadata("data/id3v1_empty.mp3", .{
        .id3v1 = .{
            .start_offset = 0x0,
            .end_offset = 0x80,
            .map = &[_]MetadataEntry{
                .{ .name = "genre", .value = "Blues" },
            },
        },
    });
}

test "id3v1 with non-ASCII chars (latin1)" {
    try parseExpectedMetadata("data/id3v1_latin1_chars.mp3", .{
        .id3v1 = .{
            .start_offset = 0x0,
            .end_offset = 0x80,
            .map = &[_]MetadataEntry{
                .{ .name = "title", .value = "Introducción" },
                .{ .name = "artist", .value = "3rdage Attack" },
                .{ .name = "album", .value = "3rdage Attack" },
                .{ .name = "date", .value = "2007" },
                .{ .name = "track", .value = "1" },
            },
        },
    });
}

test "id3v2.3 with UTF-16" {
    try parseExpectedMetadata("data/id3v2.3.mp3", .{
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
    });
}

test "id3v2.3 with UTF-16 big endian" {
    try parseExpectedMetadata("data/id3v2.3_utf16_be.mp3", .{
        .all_id3v2 = &[_]ExpectedID3v2Metadata{
            .{
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
            },
        },
    });
}

test "id3v2.3 with user defined fields (TXXX)" {
    try parseExpectedMetadata("data/id3v2.3_user_defined_fields.mp3", .{
        .all_id3v2 = &[_]ExpectedID3v2Metadata{
            .{
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
            },
        },
    });
}

test "id3v2.3 with full unsynch tag" {
    try parseExpectedMetadata("data/id3v2.3_unsynch_tag.mp3", .{
        .all_id3v2 = &[_]ExpectedID3v2Metadata{
            .{
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
            },
        },
    });
}

test "id3v2.3 with id3v2.2 frame ids" {
    try parseExpectedMetadata("data/id3v2.3_with_id3v2.2_frame_ids.mp3", .{
        .all_id3v2 = &[_]ExpectedID3v2Metadata{
            .{
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
            },
        },
    });
}

test "id3v2.3 with text frame with zero size" {
    try parseExpectedMetadata("data/id3v2.3_text_frame_with_zero_size.mp3", .{
        .all_id3v2 = &[_]ExpectedID3v2Metadata{
            .{
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
            },
        },
    });
}

test "id3v2.2" {
    try parseExpectedMetadata("data/id3v2.2.mp3", .{
        .all_id3v2 = &[_]ExpectedID3v2Metadata{
            .{
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
            },
        },
    });
}

test "id3v2.4 utf16 frames with single u8 delimeters" {
    try parseExpectedMetadata("data/id3v2.4_utf16_single_u8_delimeter.mp3", .{
        .all_id3v2 = &[_]ExpectedID3v2Metadata{
            .{
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
            },
        },
    });
}

test "id3v2.3 zero size frame" {
    try parseExpectedMetadata("data/id3v2.3_zero_size_frame.mp3", .{
        .all_id3v2 = &[_]ExpectedID3v2Metadata{
            .{
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
            },
        },
    });
}

test "id3v2.4 non-synchsafe frame size" {
    try parseExpectedMetadata("data/id3v2.4_non_synchsafe_frame_size.mp3", .{
        .all_id3v2 = &[_]ExpectedID3v2Metadata{
            .{
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
            },
        },
    });
}

test "id3v2.4 extended header with crc" {
    try parseExpectedMetadata("data/id3v2.4_extended_header_crc.mp3", .{
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
    });
}

test "normal flac" {
    try parseExpectedMetadata("data/flac.flac", .{
        .all_id3v2 = null,
        .id3v1 = null,
        .flac = .{
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
        },
    });
}

test "flac with multiple date fields" {
    try parseExpectedMetadata("data/flac_multiple_dates.flac", .{
        .all_id3v2 = null,
        .id3v1 = null,
        .flac = .{
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
        },
    });
}

test "id3v2.4 unsynch text frames" {
    try parseExpectedMetadata("data/id3v2.4_unsynch_text_frames.mp3", .{
        .all_id3v2 = &[_]ExpectedID3v2Metadata{
            .{
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
            },
        },
    });
}

test "id3v2.3 malformed TXXX" {
    try parseExpectedMetadata("data/id3v2.3_malformed_txxx.mp3", .{
        .all_id3v2 = &[_]ExpectedID3v2Metadata{
            .{
                .major_version = 3,
                .metadata = .{
                    .start_offset = 0x0,
                    .end_offset = 0x43,
                    .map = &[_]MetadataEntry{},
                },
            },
        },
    });
}

test "id3v2.4 malformed TXXX" {
    try parseExpectedMetadata("data/id3v2.4_malformed_txxx.mp3", .{
        .all_id3v2 = &[_]ExpectedID3v2Metadata{
            .{
                .major_version = 4,
                .metadata = .{
                    .start_offset = 0x0,
                    .end_offset = 0x3B,
                    .map = &[_]MetadataEntry{},
                },
            },
        },
    });
}

test "id3v2.3 unsynch tag edge case" {
    // Found via fuzzing. Has a full unsynch tag that has an end frame header with
    // unsynch bytes that extends to the end of the tag. This can trigger an
    // usize underflow if it's not protected against properly.
    try parseExpectedMetadata("data/id3v2.3_unsynch_tag_edge_case.mp3", .{
        .all_id3v2 = &[_]ExpectedID3v2Metadata{
            .{
                .major_version = 3,
                .metadata = .{
                    .start_offset = 0x0,
                    .end_offset = 0x43,
                    .map = &[_]MetadataEntry{},
                },
            },
        },
    });
}

test "ogg" {
    try parseExpectedMetadata("data/vorbis.ogg", .{
        .all_id3v2 = null,
        .id3v1 = null,
        .flac = null,
        .vorbis = ExpectedMetadata{
            .start_offset = 0x6d,
            .end_offset = 0x10ff,
            .map = &[_]MetadataEntry{
                .{ .name = "ALBUM", .value = "PIRATE" },
                .{ .name = "ARTIST", .value = "TROMATISM" },
                .{ .name = "GENRE", .value = "PUNK" },
                .{ .name = "TITLE", .value = "Paria" },
                .{ .name = "TRACKNUMBER", .value = "20" },
                .{ .name = "COMMENT", .value = "http://www.sauve-qui-punk.org" },
            },
        },
    });
}
