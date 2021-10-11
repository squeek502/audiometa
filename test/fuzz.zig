const std = @import("std");
const audiometa = @import("audiometa");

pub const log_level: std.log.Level = .warn;

pub export fn main() void {
    zigMain() catch unreachable;
}

pub fn zigMain() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == false);
    const allocator = &gpa.allocator;

    const stdin = std.io.getStdIn();
    const data = try stdin.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(data);
    var stream_source = std.io.StreamSource{ .buffer = std.io.fixedBufferStream(data) };

    var metadata = try audiometa.metadata.readAll(allocator, &stream_source);
    defer metadata.deinit();
}
