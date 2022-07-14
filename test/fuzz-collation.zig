const std = @import("std");
const audiometa = @import("audiometa");

pub const log_level: std.log.Level = .warn;

pub export fn main() void {
    zigMain() catch unreachable;
}

pub fn zigMain() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .stack_trace_frames = 8 }){};
    defer std.debug.assert(gpa.deinit() == false);
    const allocator = gpa.allocator();

    const stdin = std.io.getStdIn();
    const data = try stdin.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(data);
    var stream_source = std.io.StreamSource{ .buffer = std.io.fixedBufferStream(data) };

    var metadata = try audiometa.metadata.readAll(allocator, &stream_source);
    defer metadata.deinit();

    var collator = try audiometa.collate.Collator.init(allocator, &metadata, .{});
    defer collator.deinit();

    _ = try collator.artist();
    _ = try collator.artists();
    _ = try collator.album();
    _ = try collator.albums();
    _ = try collator.title();
    _ = try collator.titles();
    _ = try collator.trackNumber();
    _ = try collator.trackNumbers();
}
