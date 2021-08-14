const std = @import("std");

pub const flac = @import("flac.zig");
pub const id3v1 = @import("id3v1.zig");
pub const id3v2 = @import("id3v2.zig");
pub const latin1 = @import("latin1.zig");
pub const metadata = @import("metadata.zig");
pub const synchsafe = @import("synchsafe.zig");
pub const util = @import("util.zig");

test "" {
    std.testing.refAllDecls(@This());
}
