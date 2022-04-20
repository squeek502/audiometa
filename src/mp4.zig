const std = @import("std");
const Allocator = std.mem.Allocator;
const Metadata = @import("metadata.zig").Metadata;

// Some atoms can be "full atoms", meaning they have an additional 4 bytes
// for a version and some flags.
const FullAtomHeader = struct {
    version: u8,
    flags: u24,
};

fn readFullAtomHeader(reader: anytype) !FullAtomHeader {
    return FullAtomHeader{
        .version = try reader.readByte(),
        .flags = try reader.readIntBig(u24),
    };
}

/// Every atom in a MP4 file has this fixed-size header
const AtomHeader = struct {
    /// the atom size (including the header size of 8 bytes)
    size: u32,
    /// the name or type
    name: [4]u8,
};

fn readAtomHeader(reader: anytype, seekable_stream: anytype) !AtomHeader {
    const size = switch (try reader.readIntBig(u32)) {
        0 => blk: {
            // a size of 0 means the atom extends to end of file

            const remaining = (try seekable_stream.getEndPos()) - (try seekable_stream.getPos());

            break :blk @intCast(u32, remaining);
        },
        1 => {
            // a size of 1 means the atom header has an extended size field
            // TODO: implement this if relevant ?

            return error.UnimplementedExtendedSize;
        },
        else => |n| n,
    };

    var name: [4]u8 = undefined;
    _ = try reader.readAll(&name);

    return AtomHeader{
        .size = size,
        .name = name,
    };
}

/// Generic data atom
///
/// Its value should be interpreted based on the type indicator and locale indicator.
/// For our purposes it's probably enough to treat them as UTF-8 strings.
const DataAtom = struct {
    type_indicator: u32,
    locale_indicator: u32,
    value: []u8,
};

fn readDataAtom(allocator: Allocator, reader: anytype, seekable_stream: anytype) !DataAtom {
    const atom_header = try readAtomHeader(reader, seekable_stream);
    if (atom_header.size < 8) return error.InvalidDataAtom;
    if (!std.mem.eql(u8, "data", &atom_header.name)) return error.InvalidDataAtom;

    // -8 for the atom header size
    // -8 for the data atom "metadata" (type indicator and locale indicator)
    const data_size = atom_header.size - 8 - 8;

    var res = DataAtom{
        .type_indicator = try reader.readIntBig(u32),
        .locale_indicator = try reader.readIntBig(u32),
        .value = try allocator.alloc(u8, data_size),
    };
    errdefer allocator.free(res.value);

    const n = try reader.readAll(res.value);
    if (n < data_size) return error.EndOfStream;

    return res;
}

const MetadataAtom = struct {
    name: []const u8,
    export_name: []const u8 = "",
};

// zig fmt: off
const metadata_atoms = &[_]MetadataAtom{
    .{ .name = "\xA9nam", .export_name = "track"        },
    .{ .name = "\xA9alb", .export_name = "album"        },
    .{ .name = "\xA9ART", .export_name = "artist"       },
    .{ .name = "aART"   , .export_name = "album_artist" },
    .{ .name = "\xA9des", .export_name = "description"  },
    .{ .name = "\xA9day", .export_name = "release_date" },
    .{ .name = "\xA9cmt", .export_name = "comment"      },
    .{ .name = "\xA9too", .export_name = "tool"         },
    .{ .name = "\xA9gen", .export_name = "genre"        },
    .{ .name = "\xA9wrt", .export_name = "composer"     },
    .{ .name = "\xA9cpy", .export_name = "copyright"    },
};
// zig fmt: on

fn getMetadataAtom(name: []const u8) ?MetadataAtom {
    inline for (metadata_atoms) |atom| {
        if (std.mem.eql(u8, atom.name, name)) return atom;
    }
    return null;
}

/// Reads the metadata from an MP4 file.
///
/// MP4 is defined in ISO/IEC 14496-14 but MP4 files are essentially identical to QuickTime container files.
/// See https://wiki.multimedia.cx/index.php/QuickTime_container for information.
///
/// This function does just enough to extract the metadata relevant to an audio file
pub fn read(allocator: Allocator, reader: anytype, seekable_stream: anytype) !Metadata {
    var metadata: Metadata = Metadata.init(allocator);
    errdefer metadata.deinit();

    // A MP4 file is a tree of atoms. An "atom" is the building block of a MP4 container.
    //
    // For our purposes of extracting the audio metadata we assume that the MP4 file
    // respects the following layout which seem to be standard:
    //
    // moov
    //   udta
    //     meta
    //       ilst
    //         aART
    //         \xA9alb
    //         \xA9ART
    //
    // The data that interests us are the atoms under the "ilst" atom.
    //
    // The following parser code expects this layout and if it doesn't exist it just fails.

    var state: enum {
        start,
        in_moov,
        in_udta,
        in_meta,
        in_ilst,
    } = .start;

    // Keep track of the size in bytes of the "ilst" atom and how much we already read.
    var ilst_size: usize = 0;
    var ilst_read: usize = 0;

    while (true) {
        const atom_header = readAtomHeader(reader, seekable_stream) catch |err| switch (err) {
            error.EndOfStream => if (metadata.map.entries.items.len > 0) return metadata else return err,
            else => return err,
        };

        switch (state) {
            .start => if (std.mem.eql(u8, "moov", &atom_header.name)) {
                state = .in_moov;
                continue;
            },
            .in_moov => if (std.mem.eql(u8, "udta", &atom_header.name)) {
                state = .in_udta;
                continue;
            },
            .in_udta => if (std.mem.eql(u8, "meta", &atom_header.name)) {
                // The full atom header doesn't interest us but it has to be read.
                _ = try readFullAtomHeader(reader);

                // The "meta" atom started at the current stream position minus the standard and full atom header.
                metadata.start_offset = (try seekable_stream.getPos()) - 8 - 4;
                metadata.end_offset = metadata.start_offset + atom_header.size;

                state = .in_meta;
                continue;
            },
            .in_meta => if (std.mem.eql(u8, "ilst", &atom_header.name)) {
                // Used when handling the in_ilst state to know if there are more elements in the list.
                ilst_size = atom_header.size - 8;

                state = .in_ilst;
                continue;
            },
            .in_ilst => {
                // Determine if there's more to read in the "ilst" atom.
                ilst_read += atom_header.size;
                if (ilst_read >= ilst_size) {
                    ilst_read = 0;
                    ilst_size = 0;
                    state = .start;
                }

                if (getMetadataAtom(&atom_header.name)) |atom| {
                    const data_atom = try readDataAtom(allocator, reader, seekable_stream);
                    defer allocator.free(data_atom.value);

                    try metadata.map.put(atom.export_name, data_atom.value);

                    continue;
                }
            },
        }

        // Skip every atom we don't recognize or are not interested in.

        try seekable_stream.seekBy(atom_header.size - 8);
    }

    return metadata;
}

test "unimplemented extended size" {
    const res = readData(std.testing.allocator, "\x00\x00\x00\x01\xaa\xbb");
    try std.testing.expectError(error.UnimplementedExtendedSize, res);
}

fn readData(allocator: Allocator, data: []const u8) !void {
    var stream_source = std.io.StreamSource{ .const_buffer = std.io.fixedBufferStream(data) };
    _ = try read(allocator, stream_source.reader(), stream_source.seekableStream());
}
