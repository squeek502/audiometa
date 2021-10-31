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

    // default to 4kb minimum just in case we get very small files that need to allocate
    // fairly large sizes for things like ArrayList(ID3v2Metadata)
    const max_allocation_size = std.math.max(4096, data.len * 10);
    var max_size_allocator = &(MaxSizeAllocator.init(allocator, max_allocation_size).allocator);

    var metadata = try audiometa.metadata.readAll(max_size_allocator, &stream_source);
    defer metadata.deinit();
}

/// Allocator that checks that individual allocations never go over
/// a certain size, and panics if they do
const MaxSizeAllocator = struct {
    allocator: Allocator,
    parent_allocator: *Allocator,
    max_alloc_size: usize,

    const Self = @This();

    pub fn init(parent_allocator: *Allocator, max_alloc_size: usize) Self {
        return .{
            .allocator = Allocator{
                .allocFn = alloc,
                .resizeFn = resize,
            },
            .parent_allocator = parent_allocator,
            .max_alloc_size = max_alloc_size,
        };
    }

    fn alloc(allocator: *Allocator, len: usize, ptr_align: u29, len_align: u29, ra: usize) error{OutOfMemory}![]u8 {
        const self = @fieldParentPtr(Self, "allocator", allocator);
        if (len > self.max_alloc_size) {
            std.debug.print("trying to allocate size: {}\n", .{len});
            @panic("allocation exceeds max alloc size");
        }
        return self.parent_allocator.allocFn(self.parent_allocator, len, ptr_align, len_align, ra);
    }

    fn resize(allocator: *Allocator, buf: []u8, buf_align: u29, new_len: usize, len_align: u29, ra: usize) error{OutOfMemory}!usize {
        const self = @fieldParentPtr(Self, "allocator", allocator);
        if (new_len > self.max_alloc_size) {
            std.debug.print("trying to resize to size: {}\n", .{new_len});
            @panic("allocation exceeds max alloc size");
        }
        return self.parent_allocator.resizeFn(self.parent_allocator, buf, buf_align, new_len, len_align, ra);
    }
};
