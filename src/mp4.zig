const std = @import("std");
const Allocator = std.mem.Allocator;
const Metadata = @import("metadata.zig").Metadata;
const id3v1 = @import("id3v1.zig"); // needed for genre ID lookup for gnre atom
const constrainedStream = @import("constrained_stream.zig").constrainedStream;

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

    /// Length of a normal atom header (without an extended size field)
    pub const len = 8;
    /// Length of an extended size field (if it exists)
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

        if (header.size < header.headerSize()) {
            return error.AtomSizeTooSmall;
        }

        const remaining = (try seekable_stream.getEndPos()) - (try seekable_stream.getPos());
        if (header.sizeExcludingHeader() > remaining) {
            return error.AtomSizeTooLarge;
        }

        return header;
    }

    pub fn headerSize(self: AtomHeader) u64 {
        const extended_len: u64 = if (self.extended_size) AtomHeader.extended_size_field_len else 0;
        return AtomHeader.len + extended_len;
    }

    pub fn sizeExcludingHeader(self: AtomHeader) u64 {
        return self.size - self.headerSize();
    }
};

/// Generic data atom
///
/// See the iTunes Metadata Format Specification
pub const DataAtom = struct {
    header: AtomHeader,
    indicators: Indicators,

    pub fn read(reader: anytype, seekable_stream: anytype) !DataAtom {
        const header = try AtomHeader.read(reader, seekable_stream);
        return readIndicatorsGivenHeader(header, reader);
    }

    pub fn readIndicatorsGivenHeader(header: AtomHeader, reader: anytype) !DataAtom {
        if (!std.mem.eql(u8, "data", &header.name)) {
            return error.InvalidDataAtom;
        }

        if (header.sizeExcludingHeader() < Indicators.len) {
            return error.DataAtomSizeTooSmall;
        }

        return DataAtom{
            .header = header,
            .indicators = Indicators{
                .type_indicator = try reader.readIntBig(u32),
                .locale_indicator = try reader.readIntBig(u32),
            },
        };
    }

    pub const Indicators = struct {
        type_indicator: u32,
        locale_indicator: u32,

        pub const len = 8;

        /// Returns the 'type set' identifier of the "type indicator" field.
        fn getTypeSet(self: Indicators) TypeSet {
            return @intToEnum(TypeSet, (self.type_indicator & 0x0000FF00) >> 8);
        }

        pub const TypeSet = enum(u8) {
            basic = 0,
            // anything besides 0 is unknown
            _,
        };

        /// Returns the basic type of the value, or null if the type set is unknown instead of basic.
        ///
        /// See the iTunes Metadata Format Specification
        fn getBasicType(self: Indicators) ?BasicType {
            switch (self.getTypeSet()) {
                .basic => {
                    const basic_type = @intCast(u8, self.type_indicator & 0x000000FF);
                    return @intToEnum(BasicType, basic_type);
                },
                else => return null,
            }
        }

        /// From the iTunes Metadata Format Specification
        pub const BasicType = enum(u8) {
            implicit = 0,
            utf8 = 1,
            utf16_be = 2,
            s_jis = 3,
            html = 6,
            xml = 7,
            uuid = 8,
            isrc = 9, // as UTF-8
            mi3p = 10, // as UTF-8
            gif = 12,
            jpeg = 13,
            png = 14,
            url = 15,
            duration = 16, // milliseconds as a u32
            date_time = 17, // in UTC, seconds since midnight 1 Jan 1904, 32 or 64 bits
            genres = 18, // list of genre ids
            be_signed_integer = 21, // 1, 2, 3, 4, or 8 bytes
            riaa_pa = 24,
            upc = 25, // as UTF-8
            bmp = 27,
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

/// Reads a single metadata item within an `ilst` and adds its value(s) to the metadata if it's valid
pub fn readMetadataItem(allocator: Allocator, reader: anytype, seekable_stream: anytype, metadata: *Metadata, atom_header: AtomHeader, end_of_containing_atom: usize) !void {
    // used as the name when the metadata item is of type ----
    var full_meaning_name: ?[]u8 = null;
    defer if (full_meaning_name != null) allocator.free(full_meaning_name.?);

    var maybe_unhandled_header: ?AtomHeader = unhandled_header: {
        // ---- is a special metadata item that has a 'mean' and an optional 'name' atom
        // that describe the meaning as a string
        if (std.mem.eql(u8, "----", &atom_header.name)) {
            var meaning_string = meaning_string: {
                const mean_header = try AtomHeader.read(reader, seekable_stream);
                if (!std.mem.eql(u8, "mean", &mean_header.name)) {
                    return error.InvalidDataAtom;
                }
                if (mean_header.sizeExcludingHeader() < FullAtomHeader.len) {
                    return error.InvalidDataAtom;
                }
                // mean atoms are FullAtoms, so read the extra bits
                _ = try FullAtomHeader.read(reader);

                const data_size = mean_header.sizeExcludingHeader() - FullAtomHeader.len;
                var meaning_string = try allocator.alloc(u8, data_size);
                errdefer allocator.free(meaning_string);

                try reader.readNoEof(meaning_string);

                if (!std.unicode.utf8ValidateSlice(meaning_string)) {
                    return error.InvalidUTF8Data;
                }

                break :meaning_string meaning_string;
            };
            var should_free_meaning_string = true;
            defer if (should_free_meaning_string) allocator.free(meaning_string);

            var name_string = name_string: {
                const name_header = try AtomHeader.read(reader, seekable_stream);
                if (!std.mem.eql(u8, "name", &name_header.name)) {
                    // name is optional, so bail out and try reading the rest as a DataAtom
                    // we also want to save the meaning string for after the break
                    full_meaning_name = meaning_string;
                    // so we also need to stop it from getting freed in the defer
                    should_free_meaning_string = false;
                    break :unhandled_header name_header;
                }
                if (name_header.sizeExcludingHeader() < FullAtomHeader.len) {
                    return error.InvalidDataAtom;
                }
                // name atoms are FullAtoms, so read the extra bits
                _ = try FullAtomHeader.read(reader);

                const data_size = name_header.sizeExcludingHeader() - FullAtomHeader.len;
                var name_string = try allocator.alloc(u8, data_size);
                errdefer allocator.free(name_string);

                try reader.readNoEof(name_string);

                if (!std.unicode.utf8ValidateSlice(name_string)) {
                    return error.InvalidUTF8Data;
                }

                break :name_string name_string;
            };
            defer allocator.free(name_string);

            // to get the full meaning string, the name is appended to the meaning with a '.' separator
            full_meaning_name = try std.mem.join(allocator, ".", &.{ meaning_string, name_string });
            break :unhandled_header null;
        } else {
            break :unhandled_header null;
        }
    };

    // If this is a ---- item, use the full meaning name, otherwise use the metadata item atom's name
    // TODO: Potentially store the two different ways of naming things
    //       in separate maps, like ID3v2.user_defined
    const metadata_item_name: []const u8 = full_meaning_name orelse &atom_header.name;

    // There can be more than 1 data atom per metadata item
    while ((try seekable_stream.getPos()) < end_of_containing_atom) {
        const data_atom = data_atom: {
            if (maybe_unhandled_header) |unhandled_header| {
                const data_atom = try DataAtom.readIndicatorsGivenHeader(unhandled_header, reader);
                maybe_unhandled_header = null;
                break :data_atom data_atom;
            } else {
                break :data_atom try DataAtom.read(reader, seekable_stream);
            }
        };
        const maybe_basic_type = data_atom.indicators.getBasicType();

        // We can do some extra verification here to avoid processing
        // invalid atoms by checking that the reported size of the data
        // fits inside the reported size of its containing atom.
        const data_end_pos: usize = (try seekable_stream.getPos()) + data_atom.dataSize();
        if (data_end_pos > end_of_containing_atom) {
            return error.DataAtomSizeTooLarge;
        }

        if (maybe_basic_type) |basic_type| {
            switch (basic_type) {
                .utf8 => {
                    var value = try data_atom.readValueAsBytes(allocator, reader);
                    defer allocator.free(value);

                    if (!std.unicode.utf8ValidateSlice(value)) {
                        return error.InvalidUTF8Data;
                    }

                    try metadata.map.put(metadata_item_name, value);
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
                        value_utf16[i] = @byteSwap(c);
                    }

                    // convert to UTF-8
                    var value_utf8 = std.unicode.utf16leToUtf8Alloc(allocator, value_utf16) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        else => return error.InvalidUTF16Data,
                    };
                    defer allocator.free(value_utf8);

                    try metadata.map.put(metadata_item_name, value_utf8);
                },
                .be_signed_integer => {
                    var size = data_atom.dataSize();
                    switch (size) {
                        1...4, 8 => {},
                        else => return error.InvalidDataAtom,
                    }
                    var value_buf: [8]u8 = undefined;
                    var value_bytes = value_buf[0..size];
                    try reader.readNoEof(value_bytes);

                    const value_int: i64 = switch (size) {
                        1 => std.mem.readIntSliceBig(i8, value_bytes),
                        2 => std.mem.readIntSliceBig(i16, value_bytes),
                        3 => std.mem.readIntSliceBig(i24, value_bytes),
                        4 => std.mem.readIntSliceBig(i32, value_bytes),
                        8 => std.mem.readIntSliceBig(i64, value_bytes),
                        else => unreachable,
                    };

                    const longest_possible_string = "-9223372036854775808";
                    var int_string_buf: [longest_possible_string.len]u8 = undefined;
                    const value_utf8 = std.fmt.bufPrintIntToSlice(&int_string_buf, value_int, 10, .lower, .{});

                    try metadata.map.put(metadata_item_name, value_utf8);
                },
                .implicit => {
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

                        try metadata.map.put(metadata_item_name, utf8_fbs.getWritten());
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
                            try metadata.map.put(metadata_item_name, genre_name);
                        }
                    } else {
                        // any other implicit type is unknown, though
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
}

pub const AtomTreeIterator = struct {
    atom_stack: std.ArrayList(AtomInfo),

    pub const AtomInfo = struct {
        header: AtomHeader,
        end_pos: usize,
    };

    const Self = @This();

    pub fn init(allocator: Allocator) Self {
        return AtomTreeIterator{
            .atom_stack = std.ArrayList(AtomInfo).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.atom_stack.deinit();
    }

    /// Reads an atom header and returns its header + end position, while keeping track
    /// of the current stack of atoms. The caller should either skip to the end of the
    /// returned atom or otherwise set up the iterator for the next read. For example, if
    /// this function returns a `moov` atom and we're interested in reading the children
    /// of the `moov` atom, we would do nothing and call `next` immediately. However, if
    /// it was a `meta` atom then we'd need to read the FullAtom header before calling
    /// next in order to read its children. If we were not interested in the entire tree
    /// of the returned atom, then we'd skip to the returned `end_pos`.
    ///
    /// Returns `null` once the entire tree of the first-read-atom has been read.
    pub fn next(self: *Self, reader: anytype, seekable_stream: anytype) !?AtomInfo {
        const start_pos = try seekable_stream.getPos();
        if (self.atom_stack.items.len > 0) {
            // pop off any parent atoms that end at the same spot
            while (self.atom_stack.items.len > 0 and
                start_pos >= self.atom_stack.items[self.atom_stack.items.len - 1].end_pos)
            {
                _ = self.atom_stack.pop();
            }
            // if we popped everything off the stack, then we've read the entire tree
            if (self.atom_stack.items.len == 0) {
                return null;
            }
        }

        const atom_header = try AtomHeader.read(reader, seekable_stream);

        const atom_info = AtomInfo{
            .header = atom_header,
            .end_pos = start_pos + atom_header.size,
        };
        try self.atom_stack.append(atom_info);
        return atom_info;
    }

    pub fn peekRemainingAtomAtPos(self: Self, cur_pos: usize) ?AtomInfo {
        if (self.atom_stack.items.len == 0) return null;
        var index: usize = self.atom_stack.items.len - 1;
        while (true) {
            if (cur_pos < self.atom_stack.items[index].end_pos) {
                return self.atom_stack.items[index];
            }
            if (index == 0) {
                return null;
            }
            index -= 1;
        }
        unreachable;
    }

    const StateUpdateInfo = struct {
        end_pos: ?usize,
        state: AtomReadState,
    };

    // TODO: This is very tied to the implementation details of readAll which doesn't seem great
    pub fn stateFromRemainingAtom(maybe_remaining_atom: ?AtomInfo) StateUpdateInfo {
        if (maybe_remaining_atom) |remaining_atom| {
            if (std.mem.eql(u8, "meta", &remaining_atom.header.name)) {
                return .{ .state = .in_meta, .end_pos = remaining_atom.end_pos };
            } else if (std.mem.eql(u8, "udta", &remaining_atom.header.name)) {
                return .{ .state = .in_udta, .end_pos = remaining_atom.end_pos };
            } else if (std.mem.eql(u8, "moov", &remaining_atom.header.name)) {
                return .{ .state = .in_moov, .end_pos = remaining_atom.end_pos };
            }
        }
        return .{ .state = .start, .end_pos = null };
    }
};

test "AtomTreeIterator single atom" {
    const test_data = "\x00\x00\x00\x08moov";
    var stream_source = std.io.StreamSource{ .const_buffer = std.io.fixedBufferStream(test_data) };
    var atom_it = AtomTreeIterator.init(std.testing.allocator);
    defer atom_it.deinit();

    const reader = stream_source.reader();
    const seekable_stream = stream_source.seekableStream();

    // first atom should be the moov atom
    const first_atom = try atom_it.next(reader, seekable_stream);
    try std.testing.expectEqualStrings("moov", &first_atom.?.header.name);

    // second atom should be null
    const second_atom = try atom_it.next(reader, seekable_stream);
    try std.testing.expect(second_atom == null);
}

test "AtomTreeIterator multiple top-level atoms" {
    const test_data = "\x00\x00\x00\x08moov\x00\x00\x00\x08moov";
    var stream_source = std.io.StreamSource{ .const_buffer = std.io.fixedBufferStream(test_data) };
    var atom_it = AtomTreeIterator.init(std.testing.allocator);
    defer atom_it.deinit();

    const reader = stream_source.reader();
    const seekable_stream = stream_source.seekableStream();

    var tree_num: usize = 0;
    while (tree_num < 2) : (tree_num += 1) {
        // first atom should be the moov atom
        const first_atom = try atom_it.next(reader, seekable_stream);
        try std.testing.expectEqualStrings("moov", &first_atom.?.header.name);

        // second atom should be null
        const second_atom = try atom_it.next(reader, seekable_stream);
        try std.testing.expect(second_atom == null);
    }
}

test "AtomTreeIterator reading a subtree fully but not the outer tree" {
    // zig fmt: off
    const test_data =
        "\x00\x00\x00\x20moov" ++
          "\x00\x00\x00\x10dum1" ++
            "\x00\x00\x00\x08dum2" ++
          "\x00\x00\x00\x08dum3"
    ;
    // zig fmt: on
    var stream_source = std.io.StreamSource{ .const_buffer = std.io.fixedBufferStream(test_data) };
    var atom_it = AtomTreeIterator.init(std.testing.allocator);
    defer atom_it.deinit();

    const reader = stream_source.reader();
    const seekable_stream = stream_source.seekableStream();

    const first_atom = try atom_it.next(reader, seekable_stream);
    try std.testing.expectEqualStrings("moov", &first_atom.?.header.name);

    {
        const remaining_atom = atom_it.peekRemainingAtomAtPos(try seekable_stream.getPos());
        try std.testing.expectEqualStrings("moov", &remaining_atom.?.header.name);
    }

    const second_atom = try atom_it.next(reader, seekable_stream);
    try std.testing.expectEqualStrings("dum1", &second_atom.?.header.name);

    {
        const remaining_atom = atom_it.peekRemainingAtomAtPos(try seekable_stream.getPos());
        try std.testing.expectEqualStrings("dum1", &remaining_atom.?.header.name);
    }

    const third_atom = try atom_it.next(reader, seekable_stream);
    try std.testing.expectEqualStrings("dum2", &third_atom.?.header.name);

    // we've now read the dum1, and dum2 trees fully, but the moov tree
    // still has a dum3 atom that hasn't been read
    {
        const remaining_atom = atom_it.peekRemainingAtomAtPos(try seekable_stream.getPos());
        try std.testing.expectEqualStrings("moov", &remaining_atom.?.header.name);
    }

    const fourth_atom = try atom_it.next(reader, seekable_stream);
    try std.testing.expectEqualStrings("dum3", &fourth_atom.?.header.name);

    // now we've read the full thing, so there's no remaining atoms left
    {
        const remaining_atom = atom_it.peekRemainingAtomAtPos(try seekable_stream.getPos());
        try std.testing.expect(remaining_atom == null);
    }

    const fifth_atom = try atom_it.next(reader, seekable_stream);
    try std.testing.expect(fifth_atom == null);
}

/// This function can be used to read an atom and verify that it is an `ftyp` atom
/// in order to check that we are actually reading a MP4 file. The `ftyp` atom
/// should be the first atom in an mp4 file.
///
/// If the atom read is not an `ftyp` atom, this function returns `error.MissingFileTypeCompatibilityAtom`.
///
/// This `ftyp` atom is technically optional according to
/// https://developer.apple.com/library/archive/documentation/QuickTime/QTFF/QTFFChap1/qtff1.html#//apple_ref/doc/uid/TP40000939-CH203-CJBCBIFF
/// but 'strongly recommendeded.'
///
/// This verification can be done in order to short-circuit out of non-MP4 files quickly, instead
/// of skipping around the file randomly given happens-to-be-valid-enough data.
pub fn readFtyp(reader: anytype, seekable_stream: anytype) !void {
    var atom_header = try AtomHeader.read(reader, seekable_stream);
    if (!std.mem.eql(u8, "ftyp", &atom_header.name)) {
        return error.MissingFileTypeCompatibilityAtom;
    }
    // We don't actually care too much about the contents of the `ftyp` atom, so just skip them
    // TODO: Should we care about the contents?
    try seekByExtended(seekable_stream, atom_header.sizeExcludingHeader());
}

const AtomReadState = enum {
    start,
    in_moov,
    in_udta,
    in_meta,
    in_ilst,
};

/// Reads one full atom tree and appends any metadata found within it to `all_metadata`.
pub fn readFullAtomIntoArrayList(allocator: Allocator, _reader: anytype, _seekable_stream: anytype, all_metadata: *std.ArrayList(Metadata)) !void {
    // For our purposes of extracting the audio metadata we assume that the metadata
    // we care about will be found in the following structure:
    //
    // moov
    //   udta
    //     meta
    //       ilst
    //         aART
    //         \xA9alb
    //         \xA9ART
    //         ...
    //
    // The data that interests us are the atoms under the "ilst" atom.
    //
    // If we're reading a `moov` atom, then we drill down to the metadata
    // we care about, while skipping anything we don't care about.

    var state: AtomReadState = .start;
    var end_of_ilst: usize = 0;

    const start_pos = try _seekable_stream.getPos();
    var constrained_stream = constrainedStream(start_pos, _reader, _seekable_stream);
    var constrained_reader = constrained_stream.reader();
    var constrained_seekable_stream = constrained_stream.seekableStream();

    var atom_it = AtomTreeIterator.init(allocator);
    defer atom_it.deinit();

    var metadata: *Metadata = undefined;

    while (true) {
        const maybe_atom = atom_it.next(constrained_reader, constrained_seekable_stream) catch |err| switch (err) {
            // We can recover from certain errors
            error.AtomSizeTooLarge,
            error.AtomSizeTooSmall,
            error.EndOfConstrainedStream,
            => {
                // Although if we're trying to read a root node, then there's no way to recover.
                if (atom_it.atom_stack.items.len == 0) {
                    return err;
                }
                const end_of_parent = atom_it.atom_stack.items[atom_it.atom_stack.items.len - 1].end_pos;
                try constrained_seekable_stream.seekTo(end_of_parent);

                const maybe_remaining_atom = atom_it.peekRemainingAtomAtPos(end_of_parent);
                const state_update = AtomTreeIterator.stateFromRemainingAtom(maybe_remaining_atom);
                state = state_update.state;
                constrained_stream.constrained_end_pos = state_update.end_pos;
                continue;
            },
            else => |e| return e,
        };
        if (maybe_atom == null) {
            break;
        }
        const atom = maybe_atom.?;
        constrained_stream.constrained_end_pos = atom.end_pos;

        switch (state) {
            .start => if (std.mem.eql(u8, "moov", &atom.header.name)) {
                state = .in_moov;
                continue;
            },
            .in_moov => if (std.mem.eql(u8, "udta", &atom.header.name)) {
                state = .in_udta;
                continue;
            },
            .in_udta => if (std.mem.eql(u8, "meta", &atom.header.name)) {
                const meta_start_pos = (try constrained_seekable_stream.getPos()) - atom.header.headerSize();

                // The full atom header doesn't interest us but it has to be read.
                _ = try FullAtomHeader.read(constrained_reader);

                try all_metadata.append(Metadata.init(allocator));
                metadata = &all_metadata.items[all_metadata.items.len - 1];
                metadata.start_offset = meta_start_pos;
                metadata.end_offset = atom.end_pos;

                state = .in_meta;
                continue;
            },
            .in_meta => if (std.mem.eql(u8, "ilst", &atom.header.name)) {
                // Used when handling the in_ilst state to know if there are more elements in the list.
                end_of_ilst = atom.end_pos;
                state = .in_ilst;
                continue;
            },
            .in_ilst => {
                readMetadataItem(allocator, constrained_reader, constrained_seekable_stream, metadata, atom.header, atom.end_pos) catch |err| switch (err) {
                    // Some errors within the ilst can be recovered from by skipping the invalid atom
                    error.DataAtomSizeTooLarge,
                    error.DataAtomSizeTooSmall,
                    error.InvalidDataAtom,
                    error.AtomSizeTooSmall,
                    error.InvalidUTF16Data,
                    error.InvalidUTF8Data,
                    error.EndOfConstrainedStream,
                    error.AtomSizeTooLarge,
                    => {
                        try constrained_seekable_stream.seekTo(atom.end_pos);
                    },
                    else => |e| {
                        return e;
                    },
                };

                // in order to read past this point, we need to set the constrained end
                // back to the parent's end pos which we know is the ilst
                constrained_stream.constrained_end_pos = end_of_ilst;

                if ((try constrained_seekable_stream.getPos()) >= end_of_ilst) {
                    const maybe_remaining_atom = atom_it.peekRemainingAtomAtPos(try constrained_seekable_stream.getPos());
                    const state_update = AtomTreeIterator.stateFromRemainingAtom(maybe_remaining_atom);
                    state = state_update.state;
                    constrained_stream.constrained_end_pos = state_update.end_pos;
                }
                continue;
            },
        }

        // Skip every atom we don't recognize or are not interested in.
        try seekByExtended(constrained_seekable_stream, atom.header.sizeExcludingHeader());

        const maybe_remaining_atom = atom_it.peekRemainingAtomAtPos(try constrained_seekable_stream.getPos());
        const state_update = AtomTreeIterator.stateFromRemainingAtom(maybe_remaining_atom);
        state = state_update.state;
        constrained_stream.constrained_end_pos = state_update.end_pos;
    }
}

/// An MP4 file contains trees of atoms. An "atom" is the building block of a MP4 container.
///
/// This function reads all continguous atom trees from an MP4 file and returns a slice
/// containing all the metadata found within, if any.
/// If no metadata is found within the tree, but a complete atom tree was read successfully,
/// then this function returns a slice with length 0.
///
/// MP4 is defined in ISO/IEC 14496-14 but MP4 files are essentially identical to QuickTime container files.
/// See https://wiki.multimedia.cx/index.php/QuickTime_container for information.
///
/// This function does just enough to extract the metadata relevant to an audio file
pub fn readAll(allocator: Allocator, reader: anytype, seekable_stream: anytype) ![]Metadata {
    var all_metadata = std.ArrayList(Metadata).init(allocator);
    errdefer {
        for (all_metadata.items) |*item| {
            item.deinit();
        }
        all_metadata.deinit();
    }

    // We assume that the MP4 file respects the following layout which seem to be standard:
    //
    // ftyp
    // [...] (potentially other top-level atoms)
    // [...] (potentially other top-level atoms)
    //
    // For this function, we want to validate the ftyp atom first in order
    // to short-circuit when reading non-MP4 files, since when reading unknown
    // atoms it's possible that the headers can 'seem' valid even when they aren't.
    try readFtyp(reader, seekable_stream);

    var num_atoms_read: usize = 0;
    while (true) : (num_atoms_read += 1) {
        var start_pos = try seekable_stream.getPos();
        readFullAtomIntoArrayList(allocator, reader, seekable_stream, &all_metadata) catch |err| switch (err) {
            // If we hit parse errors, we only want to return the error if we haven't
            // read anything successfully
            error.EndOfConstrainedStream,
            error.EndOfStream,
            error.AtomSizeTooLarge,
            error.AtomSizeTooSmall,
            => {
                // Because of the nature of the mp4 format, we can't really detect when
                // all of the atoms are 'done', and instead will always get some type of error
                // when reading the next atom tree (EndOfStream or some other error).
                // So, if we have already read something successfully, then we treat it as
                // a successful read and return whatever metadata we've read so far.
                // However, we also need to reset the cursor position back to where it was
                // before this particular attempt at reading an atom tree so that
                // the cursor position is not part-way through an invalid tree when potentially
                // trying to read something else after this function finishes.
                try seekable_stream.seekTo(start_pos);
                if (num_atoms_read > 0) return all_metadata.toOwnedSlice() else return err;
            },
            // Any other error we always want to return the error (OutOfMemory, etc)
            else => |e| return e,
        };
    }

    unreachable;
}

/// SeekableStream.seekBy wrapper that allows for u64 sizes
fn seekByExtended(seekable_stream: anytype, amount: u64) !void {
    if (std.math.cast(u32, amount)) |seek_amount| {
        try seekable_stream.seekBy(seek_amount);
    } else {
        var remaining = amount;
        while (remaining > 0) {
            const seek_amt = std.math.min(remaining, std.math.maxInt(u32));
            try seekable_stream.seekBy(@intCast(u32, seek_amt));
            remaining -= seek_amt;
        }
    }
}

test "seekByExtended" {
    const TestStream = struct {
        pos: u64,

        const Self = @This();

        // dummy partial-implementation of a seekable stream
        // that assumes all seekBy calls use positives `amt`s
        pub const SeekableStream = struct {
            ctx: *Self,

            pub fn seekBy(self: @This(), amt: i64) !void {
                self.ctx.pos += @intCast(u32, amt);
            }
        };
    };
    var test_stream = TestStream{ .pos = 0 };
    const test_seekable_stream = TestStream.SeekableStream{ .ctx = &test_stream };

    const large_seek_amt: u64 = 1 << 32;
    try seekByExtended(test_seekable_stream, large_seek_amt);

    try std.testing.expectEqual(large_seek_amt, test_stream.pos);
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

test "end of file when reading header" {
    const res = readData(std.testing.allocator, ftyp_test_data ++ "\x11\x11\x11\x11\x20\x20");
    try std.testing.expectError(error.EndOfStream, res);
}

test "atom size too large on root" {
    const res = readData(std.testing.allocator, ftyp_test_data ++ "\x11\x11\x11\x11moov");
    try std.testing.expectError(error.AtomSizeTooLarge, res);
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

test "extended size smaller than extended header len" {
    // extended size is set as 0x09, which is larger than AtomHeader.len but smaller
    // than the size of the header with the extended size included, so it
    // should be rejected as too small
    const data = "\x00\x00\x00\x01ftyp\x00\x00\x00\x00\x00\x00\x00\x09";
    const res = readData(std.testing.allocator, data);
    try std.testing.expectError(error.AtomSizeTooSmall, res);
}

test "read tree, then skip sibling to end of parent" {
    // This is a tree like so:
    // ftyp
    // moov
    //  udta
    //   chld
    //  sibl
    //
    // What should happen is the ftyp tree is read, then the moov tree,
    // then the udta leaf, then it should read the header of the chld
    // leaf, but skip it since it's not 'meta'. Since the end of `chld` lines
    // up with the end of its parent, the constrained stream end should be
    // set to the end of the 'moov' atom (since we're not done reading it).
    //
    // In terms of memory layout, the tree will look like this:
    // |-ftyp-|
    //        |----------moov---------|
    //            |----udta----|
    //                  |-chld-|
    //                         |-sibl-|
    //
    // (note that the `udta` and `chld` atoms end at the same point)
    // zig fmt: off
    const test_data =
        ftyp_test_data ++
        "\x00\x00\x00\x20moov" ++
          "\x00\x00\x00\x10udta" ++
            "\x00\x00\x00\x08chld" ++
          "\x00\x00\x00\x08sibl"
    ;
    // zig fmt: on
    var stream_source = std.io.StreamSource{ .const_buffer = std.io.fixedBufferStream(test_data) };
    const meta_slice = try readAll(std.testing.allocator, stream_source.reader(), stream_source.seekableStream());

    // there's no metadata to be read, we just want to check that we didn't hit an error
    try std.testing.expect(meta_slice.len == 0);
}

test "skip invalid leafs by skipping the invalid leaf's parent entirely" {
    // In terms of memory layout, the tree will look like this:
    // |-ftyp-|
    //        |----------moov-----------------------|
    //            |------udta-----------|
    //                    |-chl1-|========| (=== is the encoded size which exceeds its parent's)
    //                           |-chl2-|
    //                                  |-udta- ... |
    //                                          ...
    //
    // The idea here is that we need to deal with `chl1` having an incorrectly encoded size.
    // However, because we can't be sure that `chl2` is actually directly after `chl1` in memory, we
    // can't determine where we should start trying to read its header. Instead, we
    // need to skip to the end of its parent (`udta`) and try reading the next atom (another `udta`)
    // as normal.
    //
    // zig fmt: off
    const test_data =
        ftyp_test_data ++
        "\x00\x00\x00\x54moov" ++
          "\x00\x00\x00\x18udta" ++
            "\x00\x00\x10\x00chl1" ++
            "\x00\x00\x00\x08chl2" ++
          "\x00\x00\x00\x34udta" ++
            "\x00\x00\x00\x2Cmeta\x01\x00\x00\x00" ++
              "\x00\x00\x00\x20ilst" ++
                "\x00\x00\x00\x18\xA9nam\x00\x00\x00\x10data\x00\x00\x00\x01\x00\x00\x00\x00"
    ;
    // zig fmt: on

    var metadata = try readData(std.testing.allocator, test_data);
    defer metadata.deinit();

    // the udta with the invalid child should be skipped but the valid udta should be read
    try std.testing.expectEqual(@as(usize, 1), metadata.map.entries.items.len);
}

test "multiple atom trees with metadata in each" {
    // Constructs mp4 data with this structure:
    // ftyp
    // moov
    //  udta
    //   meta
    //    ilst
    // moov
    //  udta
    //   meta
    //    ilst
    //
    // and ensures that we get the metadata from all 'meta' atoms within both 'moov' trees.
    const metadata_data = "\x00\x00\x00\x18\xA9nam\x00\x00\x00\x10data\x00\x00\x00\x01\x00\x00\x00\x00";

    var data = std.ArrayList(u8).init(std.testing.allocator);
    defer data.deinit();

    var data_writer = data.writer();
    try data_writer.writeAll(ftyp_test_data);
    try writeTestMoovData(data_writer, metadata_data);
    try writeTestMoovData(data_writer, metadata_data);

    var stream_source = std.io.StreamSource{ .buffer = std.io.fixedBufferStream(data.items) };
    const meta_slice = try readAll(std.testing.allocator, stream_source.reader(), stream_source.seekableStream());
    defer {
        for (meta_slice) |*meta| {
            meta.deinit();
        }
        std.testing.allocator.free(meta_slice);
    }

    try std.testing.expectEqual(@as(usize, 2), meta_slice.len);
    for (meta_slice) |*meta| {
        try std.testing.expectEqual(@as(usize, 1), meta.map.entries.items.len);
        try std.testing.expectEqualStrings("", meta.map.getFirst("\xA9nam").?);
    }
}

test "one moov tree with multiple metadata atoms" {
    // Constructs mp4 data with this structure:
    // ftyp
    // moov
    //  udta
    //   meta
    //    ilst
    //   meta
    //    ilst
    //
    // and ensures that we get the metadata from both 'meta' atoms.
    const metadata_data = "\x00\x00\x00\x18\xA9nam\x00\x00\x00\x10data\x00\x00\x00\x01\x00\x00\x00\x00";

    var data = std.ArrayList(u8).init(std.testing.allocator);
    defer data.deinit();

    var writer = data.writer();
    try writer.writeAll(ftyp_test_data);

    const moov_len = AtomHeader.len;
    const udta_len = AtomHeader.len;
    const meta_len = AtomHeader.len + FullAtomHeader.len;
    const ilst_len = AtomHeader.len;

    const meta_atom_len = meta_len + ilst_len + @intCast(u32, metadata_data.len);
    var atom_len: u32 = moov_len + udta_len + meta_atom_len * 2;
    try writer.writeIntBig(u32, atom_len);
    try writer.writeAll("moov");
    atom_len -= moov_len;
    try writer.writeIntBig(u32, atom_len);
    try writer.writeAll("udta");
    atom_len = meta_atom_len;
    try writer.writeIntBig(u32, atom_len);
    try writer.writeAll("meta");
    try writer.writeByte(1);
    try writer.writeIntBig(u24, 0);
    atom_len -= meta_len;
    try writer.writeIntBig(u32, atom_len);
    try writer.writeAll("ilst");
    try writer.writeAll(metadata_data);

    // second meta within the udta
    atom_len = meta_atom_len;
    try writer.writeIntBig(u32, atom_len);
    try writer.writeAll("meta");
    try writer.writeByte(1);
    try writer.writeIntBig(u24, 0);
    atom_len -= meta_len;
    try writer.writeIntBig(u32, atom_len);
    try writer.writeAll("ilst");
    try writer.writeAll(metadata_data);

    var stream_source = std.io.StreamSource{ .buffer = std.io.fixedBufferStream(data.items) };
    const meta_slice = try readAll(std.testing.allocator, stream_source.reader(), stream_source.seekableStream());
    defer {
        for (meta_slice) |*meta| {
            meta.deinit();
        }
        std.testing.allocator.free(meta_slice);
    }

    try std.testing.expectEqual(@as(usize, 2), meta_slice.len);
    for (meta_slice) |*meta| {
        try std.testing.expectEqual(@as(usize, 1), meta.map.entries.items.len);
        try std.testing.expectEqualStrings("", meta.map.getFirst("\xA9nam").?);
    }
}

const ftyp_test_data = "\x00\x00\x00\x08ftyp";

test "readFtyp" {
    var stream_source = std.io.StreamSource{ .const_buffer = std.io.fixedBufferStream(ftyp_test_data) };
    return try readFtyp(stream_source.reader(), stream_source.seekableStream());
}

fn writeTestData(allocator: Allocator, metadata_payload: []const u8) ![]u8 {
    var data = std.ArrayList(u8).init(allocator);
    errdefer data.deinit();

    var writer = data.writer();
    try writer.writeAll(ftyp_test_data);

    try writeTestMoovData(writer, metadata_payload);

    return data.toOwnedSlice();
}

fn writeTestMoovData(writer: anytype, metadata_payload: []const u8) !void {
    const moov_len = AtomHeader.len;
    const udta_len = AtomHeader.len;
    const meta_len = AtomHeader.len + FullAtomHeader.len;
    const ilst_len = AtomHeader.len;

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
}

fn readData(allocator: Allocator, data: []const u8) !Metadata {
    var stream_source = std.io.StreamSource{ .const_buffer = std.io.fixedBufferStream(data) };
    const meta_slice = try readAll(allocator, stream_source.reader(), stream_source.seekableStream());
    std.debug.assert(meta_slice.len == 1);
    const meta = (meta_slice)[0];
    allocator.free(meta_slice);
    return meta;
}
