const std = @import("std");
const Allocator = std.mem.Allocator;
const Metadata = @import("metadata.zig").Metadata;

// Some atoms can be "full atoms", meaning they have an additional 4 bytes
// for a version and some flags.
const FullAtomHeader = struct {
    version: u8,
    flags: u24,

    pub const len = 4;

    pub fn read(reader: anytype) !FullAtomHeader {
        return FullAtomHeader{
            .version = try reader.readByte(),
            .flags = try reader.readIntBig(u24),
        };
    }
};

/// Every atom in a MP4 file has this fixed-size header
const AtomHeader = struct {
    /// the atom size (including the header size of 8 bytes)
    size: u32,
    /// the name or type
    name: [4]u8,

    pub const len = 8;

    pub fn read(reader: anytype, seekable_stream: anytype) !AtomHeader {
        var header: AtomHeader = undefined;
        header.size = switch (try reader.readIntBig(u32)) {
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

        if (header.size < AtomHeader.len) {
            return error.AtomSizeTooSmall;
        }

        const remaining = (try seekable_stream.getEndPos()) - (try seekable_stream.getPos());
        if (header.sizeExcludingHeader() >= remaining) {
            return error.EndOfStream;
        }

        _ = try reader.readAll(&header.name);

        return header;
    }

    pub fn sizeExcludingHeader(self: AtomHeader) u32 {
        return self.size - AtomHeader.len;
    }
};

/// Generic data atom
///
/// See https://developer.apple.com/library/archive/documentation/QuickTime/QTFF/Metadata/Metadata.html#//apple_ref/doc/uid/TP40000939-CH1-SW27
const DataAtom = struct {
    header: AtomHeader,
    indicators: Indicators,

    pub fn read(reader: anytype, seekable_stream: anytype) !DataAtom {
        var data_atom: DataAtom = undefined;

        data_atom.header = try AtomHeader.read(reader, seekable_stream);
        if (!std.mem.eql(u8, "data", &data_atom.header.name)) {
            return error.InvalidDataAtom;
        }

        if (data_atom.header.sizeExcludingHeader() < Indicators.len) {
            return error.DataAtomSizeTooSmall;
        }

        data_atom.indicators = Indicators{
            .type_indicator = try reader.readIntBig(u32),
            .locale_indicator = try reader.readIntBig(u32),
        };

        return data_atom;
    }

    pub const Indicators = struct {
        type_indicator: u32,
        locale_indicator: u32,

        pub const len = 8;

        /// Returns the first byte of the "type indicator" field.
        fn getType(self: Indicators) Type {
            return @intToEnum(Type, (self.type_indicator & 0xFF000000) >> 24);
        }

        pub const Type = enum(u8) {
            well_known = 0,
            // all non-zero type bytes are considered 'reserved'
            _,
        };

        /// Returns the well-known type of the value, or null if the type indicator is reserved instead of well-known.
        ///
        /// See https://developer.apple.com/library/archive/documentation/QuickTime/QTFF/Metadata/Metadata.html#//apple_ref/doc/uid/TP40000939-CH1-SW34
        /// for a list of well-known types.
        fn getWellKnownType(self: Indicators) ?WellKnownType {
            switch (self.getType()) {
                .well_known => {
                    const well_known_type = @intCast(u24, self.type_indicator & 0x00FFFFFF);
                    return @intToEnum(WellKnownType, well_known_type);
                },
                else => return null,
            }
        }

        /// From https://developer.apple.com/library/archive/documentation/QuickTime/QTFF/Metadata/Metadata.html#//apple_ref/doc/uid/TP40000939-CH1-SW34
        pub const WellKnownType = enum(u24) {
            reserved = 0,
            utf8 = 1,
            utf16_be = 2,
            s_jis = 3,
            utf8_sort = 4,
            utf16_sort = 5,
            jpeg = 13,
            png = 14,
            be_signed_integer = 21,
            be_unsigned_integer = 22,
            be_float32 = 23,
            be_float64 = 24,
            bmp = 27,
            atom = 28,
            signed_byte = 65,
            be_16bit_signed_integer = 66,
            be_32bit_signed_integer = 67,
            be_point_f32 = 70,
            be_dimensions_f32 = 71,
            be_rect_f32 = 72,
            be_64bit_signed_integer = 74,
            unsigned_byte = 75,
            be_16bit_unsigned_integer = 76,
            be_32bit_unsigned_integer = 77,
            be_64bit_unsigned_integer = 78,
            affine_transform_f64 = 79,
            _,
        };
    };

    pub fn dataSize(self: DataAtom) u32 {
        return self.header.sizeExcludingHeader() - Indicators.len;
    }

    pub fn readValueAsBytes(self: DataAtom, allocator: Allocator, reader: anytype) ![]u8 {
        const data_size = self.dataSize();
        var value = try allocator.alloc(u8, data_size);
        errdefer allocator.free(value);

        try reader.readNoEof(value);

        return value;
    }

    pub fn skipValue(self: DataAtom, seekable_stream: anytype) !void {
        const data_size = self.dataSize();
        try seekable_stream.seekBy(data_size);
    }
};

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
    // First, we verify that the first atom is an `ftyp` atom in order to check that
    // we are actually reading a MP4 file. This is technically optional according to
    // https://developer.apple.com/library/archive/documentation/QuickTime/QTFF/QTFFChap1/qtff1.html#//apple_ref/doc/uid/TP40000939-CH203-CJBCBIFF
    // but 'strongly recommendeded.'
    //
    // This verification is done so that we can short-circuit out of non-MP4 files quickly, instead
    // of skipping around the file randomly due to happens-to-be-valid-enough data.

    var first_atom_header = try AtomHeader.read(reader, seekable_stream);
    if (!std.mem.eql(u8, "ftyp", &first_atom_header.name)) {
        return error.MissingFileTypeCompatibilityAtom;
    }
    // We don't actually care too much about the contents of the `ftyp` atom, so just skip them
    // TODO: Should we care about the contents?
    try seekable_stream.seekBy(first_atom_header.sizeExcludingHeader());

    // For our purposes of extracting the audio metadata we assume that the MP4 file
    // respects the following layout which seem to be standard:
    //
    // ftyp
    // [...] (potentially other top-level atoms)
    // moov
    //   udta
    //     meta
    //       ilst
    //         aART
    //         \xA9alb
    //         \xA9ART
    //         ...
    // [...] (potentially other top-level atoms)
    //
    // The data that interests us are the atoms under the "ilst" atom.
    //
    // We skip all top-level atoms completely until we find a `moov` atom, and
    // then drill down to the metadata we care about, still skipping anything we
    // don't care about.

    var state: enum {
        start,
        in_moov,
        in_udta,
        in_meta,
        in_ilst,
    } = .start;

    // Keep track of the end position of the atom we are currently 'inside'
    // so that we can treat that as the end position of any data we try to read,
    // since the size of atoms include the size of all of their children, too.
    var end_of_current_atom: usize = try seekable_stream.getEndPos();
    var end_of_ilst: usize = 0;

    while (true) {
        var start_pos = try seekable_stream.getPos();
        const atom_header = AtomHeader.read(reader, seekable_stream) catch |err| {
            // Because of the nature of the mp4 format, we can't really detect when
            // all of the atoms are 'done', and instead will always get some type of error
            // when reading the next header (EndOfStream or an invalid header).
            // So, if we have already read some metadata, then we treat it as a successful read
            // and return that metadata.
            // However, we also need to reset the cursor position back to where it was
            // before this particular attempt at reading a header so that
            // the cursor position is not part-way through an invalid header when potentially
            // trying to read something else after this function finishes.
            try seekable_stream.seekTo(start_pos);
            if (metadata.map.entries.items.len > 0) return metadata else return err;
        };

        end_of_current_atom = start_pos + atom_header.size;

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
                _ = try FullAtomHeader.read(reader);

                metadata.start_offset = start_pos;
                metadata.end_offset = end_of_current_atom;

                state = .in_meta;
                continue;
            },
            .in_meta => if (std.mem.eql(u8, "ilst", &atom_header.name)) {
                // Used when handling the in_ilst state to know if there are more elements in the list.
                end_of_ilst = end_of_current_atom;
                state = .in_ilst;
                continue;
            },
            .in_ilst => {
                if (getMetadataAtom(&atom_header.name)) |atom| {
                    const data_atom = try DataAtom.read(reader, seekable_stream);
                    const maybe_well_known_type = data_atom.indicators.getWellKnownType();

                    // We can do some extra verification here to avoid processing
                    // invalid atoms by checking that the reported size of the data
                    // fits inside the reported size of its containing atom.
                    const data_end_pos: usize = (try seekable_stream.getPos()) + data_atom.dataSize();
                    if (data_end_pos > end_of_current_atom) {
                        return error.DataAtomSizeTooLarge;
                    }

                    if (maybe_well_known_type) |well_known_type| {
                        switch (well_known_type) {
                            .utf8 => {
                                var value = try data_atom.readValueAsBytes(allocator, reader);
                                defer allocator.free(value);

                                try metadata.map.put(atom.export_name, value);
                            },
                            else => {
                                try data_atom.skipValue(seekable_stream);
                            },
                        }
                    } else {
                        try data_atom.skipValue(seekable_stream);
                    }
                } else {
                    // if we don't recognize the metadata, then skip it
                    try seekable_stream.seekBy(atom_header.sizeExcludingHeader());
                }

                if ((try seekable_stream.getPos()) >= end_of_ilst) {
                    state = .start;
                }
                continue;
            },
        }

        // Skip every atom we don't recognize or are not interested in.
        try seekable_stream.seekBy(atom_header.sizeExcludingHeader());
    }

    return metadata;
}

test "atom size too small" {
    const res = readData(std.testing.allocator, ftyp_test_data ++ "\x00\x00\x00\x00\xe6\x95\xbe");
    try std.testing.expectError(error.AtomSizeTooSmall, res);
}

test "data atom size too small" {
    const data = try writeTestData(std.testing.allocator, "\x00\x00\x00\x08aART\x00\x00\x00\x0Adata");
    defer std.testing.allocator.free(data);

    const res = readData(std.testing.allocator, data);
    try std.testing.expectError(error.DataAtomSizeTooSmall, res);
}

test "data atom size too large" {
    const data = try writeTestData(std.testing.allocator, "\x00\x00\x00\x10aART\x00\x00\x00\x10data\xAB\x00\x00\x00\x00\x00\x00\x00");
    defer std.testing.allocator.free(data);

    const res = readData(std.testing.allocator, data);
    try std.testing.expectError(error.DataAtomSizeTooLarge, res);
}

test "atom size too big" {
    const res = readData(std.testing.allocator, ftyp_test_data ++ "\x11\x11\x11\x11\x20\x20");
    try std.testing.expectError(error.EndOfStream, res);
}

test "data atom bad type" {
    // 0xAB is not a valid data atom type, it should be skipped
    const invalid_data = "\x00\x00\x00\x18aART\x00\x00\x00\x10data\xAB\x00\x00\x00\x00\x00\x00\x00";
    const valid_data = "\x00\x00\x00\x18\xA9nam\x00\x00\x00\x10data\x00\x00\x00\x01\x00\x00\x00\x00";
    const data = try writeTestData(std.testing.allocator, invalid_data ++ valid_data);
    defer std.testing.allocator.free(data);

    var metadata = try readData(std.testing.allocator, data);
    defer metadata.deinit();

    // the invalid atom should be skipped but the valid one should be read
    try std.testing.expectEqual(@as(usize, 1), metadata.map.entries.items.len);
}

test "data atom bad well-known type" {
    // 0xFFFFFF is not a valid data atom well-known type, it should be skipped
    const invalid_data = "\x00\x00\x00\x18aART\x00\x00\x00\x10data\x00\xFF\xFF\xFF\x00\x00\x00\x00";
    const valid_data = "\x00\x00\x00\x18\xA9nam\x00\x00\x00\x10data\x00\x00\x00\x01\x00\x00\x00\x00";
    const data = try writeTestData(std.testing.allocator, invalid_data ++ valid_data);
    defer std.testing.allocator.free(data);

    var metadata = try readData(std.testing.allocator, data);
    defer metadata.deinit();

    // the invalid atom should be skipped but the valid one should be read
    try std.testing.expectEqual(@as(usize, 1), metadata.map.entries.items.len);
}

test "unimplemented extended size" {
    const res = readData(std.testing.allocator, ftyp_test_data ++ "\x00\x00\x00\x01\xaa\xbb");
    try std.testing.expectError(error.UnimplementedExtendedSize, res);
}

const ftyp_test_data = "\x00\x00\x00\x08ftyp";

fn writeTestData(allocator: Allocator, metadata_payload: []const u8) ![]u8 {
    var data = std.ArrayList(u8).init(allocator);
    errdefer data.deinit();

    const moov_len = AtomHeader.len;
    const udta_len = AtomHeader.len;
    const meta_len = AtomHeader.len + FullAtomHeader.len;
    const ilst_len = AtomHeader.len;

    var writer = data.writer();
    try writer.writeAll(ftyp_test_data);

    var atom_len: u32 = moov_len + udta_len + meta_len + ilst_len + @intCast(u32, metadata_payload.len);
    try writer.writeIntBig(u32, atom_len);
    try writer.writeAll("moov");
    atom_len -= moov_len;
    try writer.writeIntBig(u32, atom_len);
    try writer.writeAll("udta");
    atom_len -= udta_len;
    try writer.writeIntBig(u32, atom_len);
    try writer.writeAll("meta");
    try writer.writeByte(1);
    try writer.writeIntBig(u24, 0);
    atom_len -= meta_len;
    try writer.writeIntBig(u32, atom_len);
    try writer.writeAll("ilst");

    try writer.writeAll(metadata_payload);

    return data.toOwnedSlice();
}

fn readData(allocator: Allocator, data: []const u8) !Metadata {
    var stream_source = std.io.StreamSource{ .const_buffer = std.io.fixedBufferStream(data) };
    return try read(allocator, stream_source.reader(), stream_source.seekableStream());
}
