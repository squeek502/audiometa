//! MetadataType -> field name lookup tables for known/common metadata fields

const std = @import("std");
const MetadataType = @import("metadata.zig").MetadataType;

// Check that artist has non-null for all MetadataType's to ensure that
// adding a new MetadataType without modifying these lookup tables
// causes a compile error. This should not cause any false positives
// since it's assumed any MetadataType will at least have an artist field.
comptime {
    inline for (@typeInfo(MetadataType).Enum.fields) |enum_field| {
        if (artist[enum_field.value] == null) {
            const msg = std.fmt.comptimePrint("Found null field name for MetadataType '{s}' in artist lookup table. Note: Also double check that all other field lookup tables are populated correctly for this MetadataType, as the artist lookup table is used as a canary in a coal mine.", .{enum_field.name});
            @compileError(msg);
        }
    }
}

pub const NameLookups = [MetadataType.num_types]?[]const []const u8;

pub const artist = init: {
    var array = [_]?[]const []const u8{null} ** MetadataType.num_types;
    array[@enumToInt(MetadataType.id3v1)] = &.{"artist"};
    array[@enumToInt(MetadataType.flac)] = &.{"ARTIST"};
    array[@enumToInt(MetadataType.vorbis)] = &.{"ARTIST"};
    array[@enumToInt(MetadataType.id3v2)] = &.{ "TPE1", "TP1" };
    array[@enumToInt(MetadataType.ape)] = &.{"Artist"};
    array[@enumToInt(MetadataType.mp4)] = &.{"\xA9ART"};
    break :init array;
};

pub const album = init: {
    var array = [_]?[]const []const u8{null} ** MetadataType.num_types;
    array[@enumToInt(MetadataType.id3v1)] = &.{"album"};
    array[@enumToInt(MetadataType.flac)] = &.{"ALBUM"};
    array[@enumToInt(MetadataType.vorbis)] = &.{"ALBUM"};
    array[@enumToInt(MetadataType.id3v2)] = &.{ "TALB", "TAL" };
    array[@enumToInt(MetadataType.ape)] = &.{"Album"};
    array[@enumToInt(MetadataType.mp4)] = &.{"\xA9alb"};
    break :init array;
};

pub const title = init: {
    var array = [_]?[]const []const u8{null} ** MetadataType.num_types;
    array[@enumToInt(MetadataType.id3v1)] = &.{"title"};
    array[@enumToInt(MetadataType.flac)] = &.{"TITLE"};
    array[@enumToInt(MetadataType.vorbis)] = &.{"TITLE"};
    array[@enumToInt(MetadataType.id3v2)] = &.{ "TIT2", "TT2" };
    array[@enumToInt(MetadataType.ape)] = &.{"Title"};
    array[@enumToInt(MetadataType.mp4)] = &.{"\xA9nam"};
    break :init array;
};

/// These can include either just the track number or be of the format
/// <track number>/<total tracks>
pub const track_number = init: {
    var array = [_]?[]const []const u8{null} ** MetadataType.num_types;
    array[@enumToInt(MetadataType.id3v1)] = &.{"track"};
    array[@enumToInt(MetadataType.flac)] = &.{"TRACKNUMBER"};
    array[@enumToInt(MetadataType.vorbis)] = &.{"TRACKNUMBER"};
    array[@enumToInt(MetadataType.id3v2)] = &.{ "TRCK", "TRK" };
    array[@enumToInt(MetadataType.ape)] = &.{"Track"};
    array[@enumToInt(MetadataType.mp4)] = &.{"trkn"};
    break :init array;
};

/// Only includes tag types that specify the total track count in a separate field from
/// the track number
pub const track_total = init: {
    var array = [_]?[]const []const u8{null} ** MetadataType.num_types;
    array[@enumToInt(MetadataType.flac)] = &.{ "TRACKTOTAL", "TOTALTRACKS" };
    array[@enumToInt(MetadataType.vorbis)] = &.{ "TRACKTOTAL", "TOTALTRACKS" };
    break :init array;
};
