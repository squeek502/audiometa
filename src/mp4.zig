const std = @import("std");
const Allocator = std.mem.Allocator;
const Metadata = @import("metadata.zig").Metadata;
const id3v1 = @import("id3v1.zig"); // needed for genre ID lookup for gnre atom

// Some atoms can be "full atoms", meaning they have an additional 4 bytes
// for a version and some flags.
pub const FullAtomHeader = struct {
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
pub const AtomHeader = struct {
    /// the atom size (including the header)
    size: u64,
    /// the name or type
    name: [4]u8,
    /// whether or not this atom has its size speicfied in an extended size field
    extended_size: bool,

    pub const len = 8;
    pub const extended_size_field_len = 8;

    pub fn read(reader: anytype, seekable_stream: anytype) !AtomHeader {
        var header: AtomHeader = undefined;
        header.extended_size = false;
        const size_field = try reader.readIntBig(u32);
        try reader.readNoEof(&header.name);

        header.size = switch (size_field) {
            0 => blk: {
                // a size of 0 means the atom extends to end of file
                const remaining = (try seekable_stream.getEndPos()) - (try seekable_stream.getPos());
                break :blk remaining;
            },
            1 => blk: {
                // a size of 1 means the atom header has an extended size field
                header.extended_size = true;
                break :blk try reader.readIntBig(u64);
            },
            else => |size| size,
        };

        if (header.size < AtomHeader.len) {
            return error.AtomSizeTooSmall;
        }

        const remaining = (try seekable_stream.getEndPos()) - (try seekable_stream.getPos());
        if (header.sizeExcludingHeader() > remaining) {
            return error.EndOfStream;
        }

        return header;
    }

    pub fn sizeExcludingHeader(self: AtomHeader) u64 {
        const extended_len: u64 = if (self.extended_size) AtomHeader.extended_size_field_len else 0;
        return self.size - AtomHeader.len - extended_len;
    }
};

/// Generic data atom
///
/// See https://developer.apple.com/library/archive/documentation/QuickTime/QTFF/Metadata/Metadata.html#//apple_ref/doc/uid/TP40000939-CH1-SW27
pub const DataAtom = struct {
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
            be_signed_integer = 21, // 1, 2, 3, or 4 bytes
            be_unsigned_integer = 22, // 1, 2, 3, or 4 bytes
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

    pub fn dataSize(self: DataAtom) u64 {
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
        try seekByExtended(seekable_stream, data_size);
    }
};

/// Reads a single `ilst` data atom and adds it to the metadata if it's valid
pub fn readIlstData(allocator: Allocator, reader: anytype, seekable_stream: anytype, metadata: *Metadata, atom_header: AtomHeader, end_of_containing_atom: usize) !void {
    const data_atom = try DataAtom.read(reader, seekable_stream);
    const maybe_well_known_type = data_atom.indicators.getWellKnownType();

    // We can do some extra verification here to avoid processing
    // invalid atoms by checking that the reported size of the data
    // fits inside the reported size of its containing atom.
    const data_end_pos: usize = (try seekable_stream.getPos()) + data_atom.dataSize();
    if (data_end_pos > end_of_containing_atom) {
        return error.DataAtomSizeTooLarge;
    }

    if (maybe_well_known_type) |well_known_type| {
        switch (well_known_type) {
            .utf8 => {
                var value = try data_atom.readValueAsBytes(allocator, reader);
                defer allocator.free(value);

                try metadata.map.put(&atom_header.name, value);
            },
            // TODO: Verify that the UTF-16 case works correctly--I didn't have any
            //       files with UTF-16 data atoms.
            .utf16_be => {
                // data size must be divisible by 2
                if (data_atom.dataSize() % 2 != 0) {
                    return error.InvalidUTF16Data;
                }
                var value_bytes = try allocator.alignedAlloc(u8, @alignOf(u16), data_atom.dataSize());
                defer allocator.free(value_bytes);

                try reader.readNoEof(value_bytes);

                var value_utf16 = std.mem.bytesAsSlice(u16, value_bytes);

                // swap the bytes to make it little-endian instead of big-endian
                for (value_utf16) |c, i| {
                    value_utf16[i] = @byteSwap(u16, c);
                }

                // convert to UTF-8
                var value_utf8 = std.unicode.utf16leToUtf8Alloc(allocator, value_utf16) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return error.InvalidUTF16Data,
                };
                defer allocator.free(value_utf8);

                try metadata.map.put(&atom_header.name, value_utf8);
            },
            .be_signed_integer, .be_unsigned_integer => {
                var size = data_atom.dataSize();
                if (size == 0 or size > 4) {
                    return error.InvalidDataAtom;
                }
                var value_buf: [4]u8 = undefined;
                var value_bytes = value_buf[0..size];
                try reader.readNoEof(value_bytes);

                // TODO: There's probably a better way to do this
                const value_int: i64 = switch (well_known_type) {
                    .be_unsigned_integer => switch (size) {
                        1 => std.mem.readIntSliceBig(u8, value_bytes),
                        2 => std.mem.readIntSliceBig(u16, value_bytes),
                        3 => std.mem.readIntSliceBig(u24, value_bytes),
                        4 => std.mem.readIntSliceBig(u32, value_bytes),
                        else => unreachable,
                    },
                    .be_signed_integer => switch (size) {
                        1 => std.mem.readIntSliceBig(i8, value_bytes),
                        2 => std.mem.readIntSliceBig(i16, value_bytes),
                        3 => std.mem.readIntSliceBig(i24, value_bytes),
                        4 => std.mem.readIntSliceBig(i32, value_bytes),
                        else => unreachable,
                    },
                    else => unreachable,
                };

                const longest_possible_string = "-2147483648";
                var int_string_buf: [longest_possible_string.len]u8 = undefined;
                const value_utf8 = std.fmt.bufPrintIntToSlice(&int_string_buf, value_int, 10, .lower, .{});

                try metadata.map.put(&atom_header.name, value_utf8);
            },
            .reserved => {
                // these atoms have two 16-bit integer values
                if (std.mem.eql(u8, "trkn", &atom_header.name) or std.mem.eql(u8, "disk", &atom_header.name)) {
                    if (data_atom.dataSize() < 4) {
                        return error.InvalidDataAtom;
                    }
                    const longest_possible_string = "65535/65535";
                    var utf8_buf: [longest_possible_string.len]u8 = undefined;
                    var utf8_fbs = std.io.fixedBufferStream(&utf8_buf);
                    var utf8_writer = utf8_fbs.writer();

                    // the first 16 bits are unknown
                    _ = try reader.readIntBig(u16);
                    // second 16 bits is the 'current' number
                    const current = try reader.readIntBig(u16);
                    // after that is the 'total' number (if present)
                    const maybe_total: ?u16 = total: {
                        if (data_atom.dataSize() >= 6) {
                            const val = try reader.readIntBig(u16);
                            break :total if (val != 0) val else null;
                        } else {
                            break :total null;
                        }
                    };
                    // there can be trailing bytes as well that are unknown, so
                    // just skip to the end
                    try seekable_stream.seekTo(end_of_containing_atom);

                    if (maybe_total) |total| {
                        utf8_writer.print("{}/{}", .{ current, total }) catch unreachable;
                    } else {
                        utf8_writer.print("{}", .{current}) catch unreachable;
                    }

                    try metadata.map.put(&atom_header.name, utf8_fbs.getWritten());
                } else if (std.mem.eql(u8, "gnre", &atom_header.name)) {
                    if (data_atom.dataSize() != 2) {
                        return error.InvalidDataAtom;
                    }
                    // Note: The first byte having any non-zero value
                    // will make the genre lookup impossible, since ID3v1
                    // genres are limited to a u8, so reading it as a u16
                    // will better exclude invalid gnre atoms.
                    //
                    // TODO: This needs verification that this is the correct
                    //       data type / handling of the value (ffmpeg skips
                    //       the first byte, and TagLib reads it as a i16).
                    const genre_id_plus_one = try reader.readIntBig(u16);
                    if (genre_id_plus_one > 0 and genre_id_plus_one <= id3v1.id3v1_genre_names.len) {
                        const genre_id = genre_id_plus_one - 1;
                        const genre_name = id3v1.id3v1_genre_names[genre_id];
                        try metadata.map.put(&atom_header.name, genre_name);
                    }
                } else {
                    // any other reserved type is unknown, though
                    try data_atom.skipValue(seekable_stream);
                }
            },
            else => {
                try data_atom.skipValue(seekable_stream);
            },
        }
    } else {
        try data_atom.skipValue(seekable_stream);
    }
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
    try seekByExtended(seekable_stream, first_atom_header.sizeExcludingHeader());

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
                readIlstData(allocator, reader, seekable_stream, &metadata, atom_header, end_of_current_atom) catch |err| switch (err) {
                    // Some errors within the ilst can be recovered from by skipping the invalid atom
                    error.DataAtomSizeTooLarge,
                    error.DataAtomSizeTooSmall,
                    error.InvalidDataAtom,
                    error.AtomSizeTooSmall,
                    error.InvalidUTF16Data,
                    => {
                        try seekable_stream.seekTo(end_of_current_atom);
                    },
                    else => |e| return e,
                };

                if ((try seekable_stream.getPos()) >= end_of_ilst) {
                    state = .start;
                }
                continue;
            },
        }

        // Skip every atom we don't recognize or are not interested in.
        try seekByExtended(seekable_stream, atom_header.sizeExcludingHeader());
    }

    return metadata;
}

/// SeekableStream.seekBy wrapper that allows for u64 sizes
fn seekByExtended(seekable_stream: anytype, amount: u64) !void {
    if (std.math.cast(u32, amount)) |seek_amount| {
        try seekable_stream.seekBy(seek_amount);
    } else |_| {
        try seekable_stream.seekBy(@intCast(u32, amount & 0xFFFFFFFF));
        try seekable_stream.seekBy(@intCast(u32, amount >> 32));
    }
}

test "atom size too small" {
    const res = readData(std.testing.allocator, ftyp_test_data ++ "\x00\x00\x00\x03moov");
    try std.testing.expectError(error.AtomSizeTooSmall, res);
}

test "data atom size too small" {
    // 0x0A is too small of a size for the data atom, so it should be skipped
    const invalid_data = "\x00\x00\x00\x10aART\x00\x00\x00\x0Adata";
    const valid_data = "\x00\x00\x00\x18\xA9nam\x00\x00\x00\x10data\x00\x00\x00\x01\x00\x00\x00\x00";
    const data = try writeTestData(std.testing.allocator, invalid_data ++ valid_data);
    defer std.testing.allocator.free(data);

    var metadata = try readData(std.testing.allocator, data);
    defer metadata.deinit();

    // the invalid atom should be skipped but the valid one should be read
    try std.testing.expectEqual(@as(usize, 1), metadata.map.entries.items.len);
}

test "data atom size too large" {
    // data atom's reported size is too large to be contained in its containing atom, so it should be skipped
    const invalid_data = "\x00\x00\x00\x10aART\x00\x00\x00\x10data";
    const valid_data = "\x00\x00\x00\x18\xA9nam\x00\x00\x00\x10data\x00\x00\x00\x01\x00\x00\x00\x00";

    const data = try writeTestData(std.testing.allocator, invalid_data ++ valid_data);
    defer std.testing.allocator.free(data);

    var metadata = try readData(std.testing.allocator, data);
    defer metadata.deinit();

    // the invalid atom should be skipped but the valid one should be read
    try std.testing.expectEqual(@as(usize, 1), metadata.map.entries.items.len);
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

test "extended size" {
    const valid_data_with_extended_size = "\x00\x00\x00\x01\xA9nam\x00\x00\x00\x00\x00\x00\x00\x20\x00\x00\x00\x10data\x00\x00\x00\x01\x00\x00\x00\x00";
    const data = try writeTestData(std.testing.allocator, valid_data_with_extended_size);
    defer std.testing.allocator.free(data);

    var metadata = try readData(std.testing.allocator, data);
    defer metadata.deinit();

    // the valid atom should be read
    try std.testing.expectEqual(@as(usize, 1), metadata.map.entries.items.len);
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
