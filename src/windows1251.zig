const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const invalid_character = 0x98;

/// Caller must free returned memory.
pub fn windows1251ToUtf8Alloc(allocator: Allocator, windows1251_text: []const u8) ![]u8 {
    var buffer = try std.ArrayList(u8).initCapacity(allocator, windows1251_text.len);
    errdefer buffer.deinit();
    for (windows1251_text) |c| {
        try windows1251ToUtf8Append(&buffer, c);
    }
    return buffer.toOwnedSlice();
}

/// Does implicit UTF-8 -> Windows-1251 codepoint conversion before converting Windows-1251 -> UTF-8.
/// UTF-8 text must be made up solely of extended ASCII codepoints (0x00...0xFF).
/// Caller must free returned memory.
pub fn windows1251AsUtf8ToUtf8Alloc(allocator: Allocator, windows1251_text_as_utf8: []const u8) ![]u8 {
    var buffer = try std.ArrayList(u8).initCapacity(allocator, windows1251_text_as_utf8.len);
    errdefer buffer.deinit();
    var utf8_it = std.unicode.Utf8Iterator{ .bytes = windows1251_text_as_utf8, .i = 0 };
    while (utf8_it.nextCodepoint()) |input_codepoint| {
        // If this cast fails then the UTF-8 text has codepoints outside the extended ASCII range
        const c = @intCast(u8, input_codepoint);
        try windows1251ToUtf8Append(&buffer, c);
    }
    return buffer.toOwnedSlice();
}

fn windows1251ToUtf8Append(buffer: *std.ArrayList(u8), c: u8) !void {
    switch (c) {
        0...127 => try buffer.append(c),
        invalid_character => return error.InvalidWindows1251Character,
        else => {
            // ensure we always have enough space for any codepoint
            try buffer.ensureUnusedCapacity(4);
            const codepoint = windows1251ToUtf8Codepoint(c);
            const codepoint_buffer = buffer.unusedCapacitySlice();
            const codepoint_size = std.unicode.utf8Encode(codepoint, codepoint_buffer) catch unreachable;
            buffer.items.len += codepoint_size;
        },
    }
}

/// buf must be four times as big as windows1251_text to ensure that it
/// can contain the converted string
pub fn windows1251ToUtf8(windows1251_text: []const u8, buf: []u8) ![]u8 {
    assert(buf.len >= windows1251_text.len * 4);
    var i: usize = 0;
    for (windows1251_text) |c| switch (c) {
        0...127 => {
            buf[i] = c;
            i += 1;
        },
        invalid_character => return error.InvalidWindows1251Character,
        else => {
            const codepoint = windows1251ToUtf8Codepoint(c);
            const codepoint_size = std.unicode.utf8Encode(codepoint, buf[i..]) catch unreachable;
            i += codepoint_size;
        },
    };
    return buf[0..i];
}

pub const Windows1251DetectionThreshold = struct {
    /// Number of Cyrillic characters in a row before
    /// the text is assumed to be Windows1251.
    streak: usize,
    /// If there are zero non-Cyrillic characters, then
    /// there must be at least this many Cyrillic characters
    /// for the text to be assumed Windows1251.
    min_cyrillic_letters: usize,
};

pub fn Detector(comptime threshold: Windows1251DetectionThreshold) type {
    return struct {
        cyrillic_streak: usize = 0,
        cyrillic_letters: usize = 0,
        found_streak: bool = false,
        ascii_letters: usize = 0,

        const Self = @This();

        pub fn update(self: *Self, c: u8) !void {
            switch (c) {
                // The invalid character being present disqualifies
                // the text entirely
                invalid_character => return error.InvalidWindows1251Character,
                'a'...'z', 'A'...'Z' => {
                    self.cyrillic_streak = 0;
                    self.ascii_letters += 1;
                },
                // zig fmt: off
                // these are the cyrillic characters only
                0x80, 0x81, 0x83, 0x8A, 0x8C...0x90, 0x9A,
                0x9C...0x9F, 0xA1...0xA3, 0xA5, 0xA8, 0xAA,
                0xAF, 0xB2...0xB4, 0xB8, 0xBA, 0xBC...0xFF,
                // zig fmt: on
                => {
                    self.cyrillic_streak += 1;
                    self.cyrillic_letters += 1;
                    if (self.cyrillic_streak >= threshold.streak) {
                        // We can't return early here
                        // since we still need to validate that
                        // the invalid character isn't present
                        // anywhere in the text
                        self.found_streak = true;
                    }
                },
                // control characters, punctuation, numbers, symbols, etc
                // are irrelevant
                else => {},
            }
        }

        pub fn reachesDetectionThreshold(self: Self) bool {
            const all_cyrillic = self.ascii_letters == 0 and self.cyrillic_letters >= threshold.min_cyrillic_letters;
            return self.found_streak or all_cyrillic;
        }
    };
}

pub const DefaultDetector = Detector(.{ .streak = 4, .min_cyrillic_letters = 2 });

pub fn couldBeWindows1251(text: []const u8) bool {
    var detector = DefaultDetector{};
    for (text) |c| {
        detector.update(c) catch return false;
    }
    return detector.reachesDetectionThreshold();
}

/// UTF-8 text must be made up solely of extended ASCII codepoints (0x00...0xFF).
pub fn couldUtf8BeWindows1251(utf8_text: []const u8) bool {
    var detector = DefaultDetector{};

    var utf8_it = std.unicode.Utf8Iterator{ .bytes = utf8_text, .i = 0 };
    while (utf8_it.nextCodepoint()) |codepoint| {
        // If this cast fails then the UTF-8 text has codepoints outside the extended ASCII range
        const c = @intCast(u8, codepoint);
        detector.update(c) catch return false;
    }
    return detector.reachesDetectionThreshold();
}

test "windows1251 to utf8" {
    var buf: [512]u8 = undefined;
    const utf8 = try windows1251ToUtf8("a\xE0b\xE6c\xEFd", &buf);

    try std.testing.expectEqualSlices(u8, "aаbжcпd", utf8);
}

test "windows1251 to utf8 alloc" {
    const utf8 = try windows1251ToUtf8Alloc(std.testing.allocator, "a\xE0b\xE6c\xEFd");
    defer std.testing.allocator.free(utf8);

    try std.testing.expectEqualSlices(u8, "aаbжcпd", utf8);
}

test "windows1251 as utf8 to utf8 alloc" {
    // The UTF-8 codepoints are the equivalent of "a\xE0b\xE6c\xEFd"
    const utf8 = try windows1251AsUtf8ToUtf8Alloc(std.testing.allocator, "aàbæcïd");
    defer std.testing.allocator.free(utf8);

    try std.testing.expectEqualSlices(u8, "aаbжcпd", utf8);
}

test "could be windows1251" {
    try std.testing.expect(!couldBeWindows1251("abcd"));
    try std.testing.expect(!couldBeWindows1251(""));
    try std.testing.expect(!couldBeWindows1251("abc\xC8\xC8"));
    try std.testing.expect(!couldBeWindows1251("\xC8\xC8\xC8\xC8\x98"));
    try std.testing.expect(!couldBeWindows1251("a\xE0b\xE6c\xEFd"));
    try std.testing.expect(couldBeWindows1251("\xC8\xC8"));
    try std.testing.expect(couldBeWindows1251("abc\xC8\xC8\xE6\xEF"));
}

test "could utf8 be windows1251" {
    try std.testing.expect(!couldUtf8BeWindows1251("Ü"));
}

// TODO: Is an array lookup better here?
/// 0x00...0x7F and 0x98 are not valid inputs to this function.
/// Mapping comes from:
/// https://www.unicode.org/Public/MAPPINGS/VENDORS/MICSFT/WINDOWS/CP1251.TXT
/// Note that it's the same as
/// https://www.unicode.org/Public/MAPPINGS/VENDORS/MICSFT/WindowsBestFit/bestfit1251.txt
/// except for 0x98 which we treat as invalid
fn windows1251ToUtf8Codepoint(c: u8) u21 {
    return switch (c) {
        0x00...0x7F => unreachable,
        0x80 => 0x0402, // CYRILLIC CAPITAL LETTER DJE
        0x81 => 0x0403, // CYRILLIC CAPITAL LETTER GJE
        0x82 => 0x201A, // SINGLE LOW-9 QUOTATION MARK
        0x83 => 0x0453, // CYRILLIC SMALL LETTER GJE
        0x84 => 0x201E, // DOUBLE LOW-9 QUOTATION MARK
        0x85 => 0x2026, // HORIZONTAL ELLIPSIS
        0x86 => 0x2020, // DAGGER
        0x87 => 0x2021, // DOUBLE DAGGER
        0x88 => 0x20AC, // EURO SIGN
        0x89 => 0x2030, // PER MILLE SIGN
        0x8A => 0x0409, // CYRILLIC CAPITAL LETTER LJE
        0x8B => 0x2039, // SINGLE LEFT-POINTING ANGLE QUOTATION MARK
        0x8C => 0x040A, // CYRILLIC CAPITAL LETTER NJE
        0x8D => 0x040C, // CYRILLIC CAPITAL LETTER KJE
        0x8E => 0x040B, // CYRILLIC CAPITAL LETTER TSHE
        0x8F => 0x040F, // CYRILLIC CAPITAL LETTER DZHE
        0x90 => 0x0452, // CYRILLIC SMALL LETTER DJE
        0x91 => 0x2018, // LEFT SINGLE QUOTATION MARK
        0x92 => 0x2019, // RIGHT SINGLE QUOTATION MARK
        0x93 => 0x201C, // LEFT DOUBLE QUOTATION MARK
        0x94 => 0x201D, // RIGHT DOUBLE QUOTATION MARK
        0x95 => 0x2022, // BULLET
        0x96 => 0x2013, // EN DASH
        0x97 => 0x2014, // EM DASH
        0x98 => unreachable, // UNDEFINED
        0x99 => 0x2122, // TRADE MARK SIGN
        0x9A => 0x0459, // CYRILLIC SMALL LETTER LJE
        0x9B => 0x203A, // SINGLE RIGHT-POINTING ANGLE QUOTATION MARK
        0x9C => 0x045A, // CYRILLIC SMALL LETTER NJE
        0x9D => 0x045C, // CYRILLIC SMALL LETTER KJE
        0x9E => 0x045B, // CYRILLIC SMALL LETTER TSHE
        0x9F => 0x045F, // CYRILLIC SMALL LETTER DZHE
        0xA0 => 0x00A0, // NO-BREAK SPACE
        0xA1 => 0x040E, // CYRILLIC CAPITAL LETTER SHORT U
        0xA2 => 0x045E, // CYRILLIC SMALL LETTER SHORT U
        0xA3 => 0x0408, // CYRILLIC CAPITAL LETTER JE
        0xA4 => 0x00A4, // CURRENCY SIGN
        0xA5 => 0x0490, // CYRILLIC CAPITAL LETTER GHE WITH UPTURN
        0xA6 => 0x00A6, // BROKEN BAR
        0xA7 => 0x00A7, // SECTION SIGN
        0xA8 => 0x0401, // CYRILLIC CAPITAL LETTER IO
        0xA9 => 0x00A9, // COPYRIGHT SIGN
        0xAA => 0x0404, // CYRILLIC CAPITAL LETTER UKRAINIAN IE
        0xAB => 0x00AB, // LEFT-POINTING DOUBLE ANGLE QUOTATION MARK
        0xAC => 0x00AC, // NOT SIGN
        0xAD => 0x00AD, // SOFT HYPHEN
        0xAE => 0x00AE, // REGISTERED SIGN
        0xAF => 0x0407, // CYRILLIC CAPITAL LETTER YI
        0xB0 => 0x00B0, // DEGREE SIGN
        0xB1 => 0x00B1, // PLUS-MINUS SIGN
        0xB2 => 0x0406, // CYRILLIC CAPITAL LETTER BYELORUSSIAN-UKRAINIAN I
        0xB3 => 0x0456, // CYRILLIC SMALL LETTER BYELORUSSIAN-UKRAINIAN I
        0xB4 => 0x0491, // CYRILLIC SMALL LETTER GHE WITH UPTURN
        0xB5 => 0x00B5, // MICRO SIGN
        0xB6 => 0x00B6, // PILCROW SIGN
        0xB7 => 0x00B7, // MIDDLE DOT
        0xB8 => 0x0451, // CYRILLIC SMALL LETTER IO
        0xB9 => 0x2116, // NUMERO SIGN
        0xBA => 0x0454, // CYRILLIC SMALL LETTER UKRAINIAN IE
        0xBB => 0x00BB, // RIGHT-POINTING DOUBLE ANGLE QUOTATION MARK
        0xBC => 0x0458, // CYRILLIC SMALL LETTER JE
        0xBD => 0x0405, // CYRILLIC CAPITAL LETTER DZE
        0xBE => 0x0455, // CYRILLIC SMALL LETTER DZE
        0xBF => 0x0457, // CYRILLIC SMALL LETTER YI
        0xC0 => 0x0410, // CYRILLIC CAPITAL LETTER A
        0xC1 => 0x0411, // CYRILLIC CAPITAL LETTER BE
        0xC2 => 0x0412, // CYRILLIC CAPITAL LETTER VE
        0xC3 => 0x0413, // CYRILLIC CAPITAL LETTER GHE
        0xC4 => 0x0414, // CYRILLIC CAPITAL LETTER DE
        0xC5 => 0x0415, // CYRILLIC CAPITAL LETTER IE
        0xC6 => 0x0416, // CYRILLIC CAPITAL LETTER ZHE
        0xC7 => 0x0417, // CYRILLIC CAPITAL LETTER ZE
        0xC8 => 0x0418, // CYRILLIC CAPITAL LETTER I
        0xC9 => 0x0419, // CYRILLIC CAPITAL LETTER SHORT I
        0xCA => 0x041A, // CYRILLIC CAPITAL LETTER KA
        0xCB => 0x041B, // CYRILLIC CAPITAL LETTER EL
        0xCC => 0x041C, // CYRILLIC CAPITAL LETTER EM
        0xCD => 0x041D, // CYRILLIC CAPITAL LETTER EN
        0xCE => 0x041E, // CYRILLIC CAPITAL LETTER O
        0xCF => 0x041F, // CYRILLIC CAPITAL LETTER PE
        0xD0 => 0x0420, // CYRILLIC CAPITAL LETTER ER
        0xD1 => 0x0421, // CYRILLIC CAPITAL LETTER ES
        0xD2 => 0x0422, // CYRILLIC CAPITAL LETTER TE
        0xD3 => 0x0423, // CYRILLIC CAPITAL LETTER U
        0xD4 => 0x0424, // CYRILLIC CAPITAL LETTER EF
        0xD5 => 0x0425, // CYRILLIC CAPITAL LETTER HA
        0xD6 => 0x0426, // CYRILLIC CAPITAL LETTER TSE
        0xD7 => 0x0427, // CYRILLIC CAPITAL LETTER CHE
        0xD8 => 0x0428, // CYRILLIC CAPITAL LETTER SHA
        0xD9 => 0x0429, // CYRILLIC CAPITAL LETTER SHCHA
        0xDA => 0x042A, // CYRILLIC CAPITAL LETTER HARD SIGN
        0xDB => 0x042B, // CYRILLIC CAPITAL LETTER YERU
        0xDC => 0x042C, // CYRILLIC CAPITAL LETTER SOFT SIGN
        0xDD => 0x042D, // CYRILLIC CAPITAL LETTER E
        0xDE => 0x042E, // CYRILLIC CAPITAL LETTER YU
        0xDF => 0x042F, // CYRILLIC CAPITAL LETTER YA
        0xE0 => 0x0430, // CYRILLIC SMALL LETTER A
        0xE1 => 0x0431, // CYRILLIC SMALL LETTER BE
        0xE2 => 0x0432, // CYRILLIC SMALL LETTER VE
        0xE3 => 0x0433, // CYRILLIC SMALL LETTER GHE
        0xE4 => 0x0434, // CYRILLIC SMALL LETTER DE
        0xE5 => 0x0435, // CYRILLIC SMALL LETTER IE
        0xE6 => 0x0436, // CYRILLIC SMALL LETTER ZHE
        0xE7 => 0x0437, // CYRILLIC SMALL LETTER ZE
        0xE8 => 0x0438, // CYRILLIC SMALL LETTER I
        0xE9 => 0x0439, // CYRILLIC SMALL LETTER SHORT I
        0xEA => 0x043A, // CYRILLIC SMALL LETTER KA
        0xEB => 0x043B, // CYRILLIC SMALL LETTER EL
        0xEC => 0x043C, // CYRILLIC SMALL LETTER EM
        0xED => 0x043D, // CYRILLIC SMALL LETTER EN
        0xEE => 0x043E, // CYRILLIC SMALL LETTER O
        0xEF => 0x043F, // CYRILLIC SMALL LETTER PE
        0xF0 => 0x0440, // CYRILLIC SMALL LETTER ER
        0xF1 => 0x0441, // CYRILLIC SMALL LETTER ES
        0xF2 => 0x0442, // CYRILLIC SMALL LETTER TE
        0xF3 => 0x0443, // CYRILLIC SMALL LETTER U
        0xF4 => 0x0444, // CYRILLIC SMALL LETTER EF
        0xF5 => 0x0445, // CYRILLIC SMALL LETTER HA
        0xF6 => 0x0446, // CYRILLIC SMALL LETTER TSE
        0xF7 => 0x0447, // CYRILLIC SMALL LETTER CHE
        0xF8 => 0x0448, // CYRILLIC SMALL LETTER SHA
        0xF9 => 0x0449, // CYRILLIC SMALL LETTER SHCHA
        0xFA => 0x044A, // CYRILLIC SMALL LETTER HARD SIGN
        0xFB => 0x044B, // CYRILLIC SMALL LETTER YERU
        0xFC => 0x044C, // CYRILLIC SMALL LETTER SOFT SIGN
        0xFD => 0x044D, // CYRILLIC SMALL LETTER E
        0xFE => 0x044E, // CYRILLIC SMALL LETTER YU
        0xFF => 0x044F, // CYRILLIC SMALL LETTER YA
    };
}
