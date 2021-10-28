const std = @import("std");
const audiometa = @import("audiometa");
const Allocator = std.mem.Allocator;
const build_options = @import("build_options");

pub const log_level: std.log.Level = .warn;

pub export fn main() void {
    zigMain() catch unreachable;
}

pub fn zigMain() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == false);
    const gpa_allocator = &gpa.allocator;

    const stdin = std.io.getStdIn();
    const data = try stdin.readToEndAlloc(gpa_allocator, std.math.maxInt(usize));
    defer gpa_allocator.free(data);
    // use a hash of the data as the initial failing index, this will
    // almost certainly be way too large initially but we'll fix that after
    // the first iteration
    var failing_index: usize = std.hash.CityHash32.hash(data);
    var should_have_failed = false;
    while (true) : (should_have_failed = true) {
        var failing_allocator = std.testing.FailingAllocator.init(gpa_allocator, failing_index);

        // need to reset the stream_source each time to ensure that we're reading
        // from the start each iteration
        var stream_source = std.io.StreamSource{ .buffer = std.io.fixedBufferStream(data) };

        // when debugging, it helps a lot to get the context of where the failing alloc
        // actually occured, so further wrap the failing allocator to get a stack
        // trace at the point of the OutOfMemory return.
        var allocator: *Allocator = allocator: {
            // However, this will fail in the AFL-compiled version because it
            // panics when trying to print a stack trace, so only do this when
            // we are compiling the debug version of this code with the Zig compiler
            if (build_options.is_zig_debug_version) {
                var stack_trace_allocator = StackTraceOnErrorAllocator.init(&failing_allocator.allocator);
                break :allocator &stack_trace_allocator.allocator;
            } else {
                break :allocator &failing_allocator.allocator;
            }
        };

        var metadata = audiometa.metadata.readAll(allocator, &stream_source) catch |err| switch (err) {
            error.OutOfMemory => break,
            else => return err,
        };
        defer metadata.deinit();

        // if there were no allocations at all, then just break
        if (failing_allocator.index == 0) {
            break;
        }
        if (should_have_failed) {
            @panic("OutOfMemory got swallowed somewhere");
        }

        // now that we've run this input once without hitting the fail index,
        // we can treat the current index of the FailingAllocator as an upper bound
        // for the amount of allocations, and use modulo to get a random-ish but
        // predictable index that we know will fail on the second run
        failing_index = failing_index % failing_allocator.index;
    }
}

/// Wrapping allocator that prints a stack trace on error in alloc
const StackTraceOnErrorAllocator = struct {
    allocator: Allocator,
    parent_allocator: *Allocator,

    const Self = @This();

    pub fn init(parent_allocator: *Allocator) Self {
        return .{
            .allocator = Allocator{
                .allocFn = alloc,
                .resizeFn = resize,
            },
            .parent_allocator = parent_allocator,
        };
    }

    fn alloc(allocator: *Allocator, len: usize, ptr_align: u29, len_align: u29, ra: usize) error{OutOfMemory}![]u8 {
        const self = @fieldParentPtr(Self, "allocator", allocator);
        return self.parent_allocator.allocFn(self.parent_allocator, len, ptr_align, len_align, ra) catch |err| {
            std.debug.print(
                "alloc: {s} - len: {}, ptr_align: {}, len_align: {}\n",
                .{ @errorName(err), len, ptr_align, len_align },
            );
            const return_address = if (ra != 0) ra else @returnAddress();
            std.debug.dumpCurrentStackTrace(return_address);
            std.debug.print("^^^ allocation failure stack trace\n", .{});
            return err;
        };
    }

    fn resize(allocator: *Allocator, buf: []u8, buf_align: u29, new_len: usize, len_align: u29, ra: usize) error{OutOfMemory}!usize {
        const self = @fieldParentPtr(Self, "allocator", allocator);
        // Do not catch errors here since this can return errors that are not 'real'
        // See the doc comment of Allocotor.reallocBytes for more details.
        // Also, the FailingAllocator does not induce failure in its resize implementation,
        // which is what we're really interested in here.
        return self.parent_allocator.resizeFn(self.parent_allocator, buf, buf_align, new_len, len_align, ra);
    }
};
