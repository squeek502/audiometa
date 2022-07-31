const std = @import("std");

pub const flac = @import("flac.zig");
pub const id3v1 = @import("id3v1.zig");
pub const id3v2 = @import("id3v2.zig");
pub const id3v2_data = @import("id3v2_data.zig");
pub const ape = @import("ape.zig");
pub const mp4 = @import("mp4.zig");
pub const latin1 = @import("latin1.zig");
pub const windows1251 = @import("windows1251.zig");
pub const metadata = @import("metadata.zig");
pub const synchsafe = @import("synchsafe.zig");
pub const unsynch = @import("unsynch.zig");
pub const buffered_stream_source = @import("buffered_stream_source.zig");
pub const constrained_stream = @import("constrained_stream.zig");
pub const util = @import("util.zig");
pub const collate = @import("collate.zig");
pub const ziglyph = @import("ziglyph");

test {
    std.testing.refAllDecls(@This());
}
