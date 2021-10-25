const std = @import("std");
const audiometa = @import("audiometa");
const Allocator = std.mem.Allocator;

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

    // use a hash of the data as the initial failing index, this will
    // likely be way too large initially but we'll half it each time we
    // don't hit an OutOfMemory until it fails
    var failing_index = std.hash.CityHash32.hash(data) / 10000;
    while (true) {
        std.debug.print("trying with failing index {}\n", .{failing_index});
        var failing_allocator = std.testing.FailingAllocator.init(allocator, failing_index);

        var metadata = audiometa.metadata.readAll(&failing_allocator.allocator, &stream_source) catch |err| switch (err) {
            error.OutOfMemory => break,
            else => return err,
        };
        defer metadata.deinit();
        if (failing_index == 0 and failing_allocator.allocations > 0) {
            @panic("OutOfMemory got swallowed somewhere");
        } else if (failing_index == 0) {
            break;
        }
        // if we didn't get OutOfMemory, try again with half of the failing index
        failing_index /= 2;
    }
    std.debug.print("success\n", .{});
}
