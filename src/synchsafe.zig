const std = @import("std");
const assert = std.debug.assert;

pub fn EncodedType(comptime T: type) type {
    comptime assert(@typeInfo(T) == .Int);
    comptime assert(@typeInfo(T).Int.signedness == .unsigned);
    const num_bits = @typeInfo(T).Int.bits;
    const num_bytes_ceil = try std.math.divCeil(comptime_int, num_bits, 8);
    const num_zero_bits_available = (num_bytes_ceil * 8) - num_bits;
    const num_zero_bits_needed = num_bytes_ceil;
    var num_bytes_needed = num_bytes_ceil;
    if (num_zero_bits_needed > num_zero_bits_available) {
        num_bytes_needed += 1;
    }
    return std.meta.Int(.unsigned, num_bytes_needed * 8);
}

pub fn DecodedType(comptime T: type) type {
    comptime assert(@typeInfo(T) == .Int);
    comptime assert(@typeInfo(T).Int.signedness == .unsigned);
    const num_bits = @typeInfo(T).Int.bits;
    comptime assert(num_bits % 8 == 0);
    const num_bytes = num_bits / 8;
    // every byte has 1 unavailable bit
    const num_available_bits = num_bits - num_bytes;
    return std.meta.Int(.unsigned, num_available_bits);
}

pub fn decode(comptime T: type, x: T) DecodedType(T) {
    var out: T = 0;
    var mask: T = 0x7F << (@typeInfo(T).Int.bits - 8);

    while (mask != 0) {
        out >>= 1;
        out |= x & mask;
        mask >>= 8;
    }

    return @truncate(out);
}

pub fn encode(comptime T: type, x: T) EncodedType(T) {
    const OutType = EncodedType(T);
    var in: OutType = x;
    var out: OutType = undefined;

    // compute masks at compile time so that we can handle any
    // sized integer without any runtime cost
    const byte_count = @typeInfo(OutType).Int.bits / 8;
    const byte_masks = comptime blk: {
        var masks_array: [byte_count]OutType = undefined;
        masks_array[0] = 0x7F;
        const ByteCountType = std.math.Log2Int(OutType);
        var byte_index: ByteCountType = 1;
        while (byte_index < byte_count) : (byte_index += 1) {
            const prev_mask = masks_array[byte_index - 1];
            masks_array[byte_index] = ((prev_mask + 1) << 8) - 1;
        }
        break :blk &masks_array;
    };
    inline for (byte_masks) |mask| {
        out = in & ~mask;
        out <<= 1;
        out |= in & mask;
        in = out;
    }
    return out;
}

/// Returns true if the given slice has no non-synchsafe
/// bytes within it.
pub fn isSliceSynchsafe(bytes: []const u8) bool {
    for (bytes) |byte| {
        // if any byte has its most significant bit set,
        // then it's not synchsafe
        if (byte & (1 << 7) != 0) {
            return false;
        }
    }
    return true;
}

/// Returns true if the given integer has no non-synchsafe
/// bytes within it.
pub fn areIntBytesSynchsafe(comptime T: type, x: T) bool {
    comptime assert(@typeInfo(T) == .Int);
    comptime assert(@typeInfo(T).Int.signedness == .unsigned);
    const num_bits = @typeInfo(T).Int.bits;
    if (num_bits < 8) return true;

    const mask: T = comptime mask: {
        const num_bytes = num_bits / 8;
        var mask: T = 1 << 7;
        var i: usize = 1;
        while (i < num_bytes) : (i += 1) {
            mask <<= 8;
            mask |= 1 << 7;
        }
        break :mask mask;
    };

    return x & mask == 0;
}

/// Returns true if the integer is small enough that synchsafety
/// is irrelevant. That is, the encoded and decoded forms of the
/// integer are guaranteed to be equal.
///
/// Note: Any number for which this function returns false
/// has the opposite guarantee--the encoded and decoded values
/// will always differ.
pub fn isBelowSynchsafeThreshold(comptime T: type, x: T) bool {
    comptime assert(@typeInfo(T) == .Int);
    comptime assert(@typeInfo(T).Int.signedness == .unsigned);
    return std.math.maxInt(T) < 128 or x < 128;
}

fn testEncodeAndDecode(comptime T: type, encoded: T, decoded: DecodedType(T)) !void {
    try std.testing.expectEqual(encoded, encode(DecodedType(T), decoded));
    try std.testing.expectEqual(decoded, decode(T, encoded));
}

test "decode and encode" {
    try testEncodeAndDecode(u24, 0x037F7F, 0xFFFF);
    try testEncodeAndDecode(u16, 0x17F, 0xFF);
}

test "encoded and decoded types" {
    try std.testing.expectEqual(u28, DecodedType(u32));
    try std.testing.expectEqual(u14, DecodedType(u16));

    try std.testing.expectEqual(u16, EncodedType(u8));
    try std.testing.expectEqual(u8, EncodedType(u7));
    try std.testing.expectEqual(u32, EncodedType(u28));
    try std.testing.expectEqual(u16, EncodedType(u14));
    try std.testing.expectEqual(u24, EncodedType(u15));
}

test "is synchsafe" {
    try std.testing.expect(isSliceSynchsafe(&[_]u8{ 0, 0, 0, 127 }));
    try std.testing.expect(!isSliceSynchsafe(&[_]u8{ 0, 0, 0, 255 }));

    try std.testing.expect(areIntBytesSynchsafe(u2, 0));
    try std.testing.expect(areIntBytesSynchsafe(u8, 127));
    try std.testing.expect(!areIntBytesSynchsafe(u8, 128));
    try std.testing.expect(!areIntBytesSynchsafe(u8, 255));
    try std.testing.expect(areIntBytesSynchsafe(u9, 256));

    try std.testing.expect(isBelowSynchsafeThreshold(u2, 0));
    try std.testing.expect(isBelowSynchsafeThreshold(u8, 127));
    try std.testing.expect(!isBelowSynchsafeThreshold(u8, 128));
}
