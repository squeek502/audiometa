const std = @import("std");
const print = std.debug.print;

pub const Case = enum { lower, upper };

fn isUtf8ControlCode(c: []const u8) bool {
    return c.len == 2 and c[0] == '\xC2' and c[1] >= '\x80' and c[1] <= '\x9F';
}

/// Like std.unicode.Utf8Iterator, but handles invalid UTF-8 without panicing
pub const InvalidUtf8Iterator = struct {
    bytes: []const u8,
    i: usize,

    /// On invalid UTF-8, returns an error
    pub fn nextCodepointSlice(it: *InvalidUtf8Iterator) !?[]const u8 {
        if (it.i >= it.bytes.len) {
            return null;
        }

        const cp_len = try std.unicode.utf8ByteSequenceLength(it.bytes[it.i]);
        it.i += cp_len;
        return it.bytes[it.i - cp_len .. it.i];
    }
};

/// Copied from std/fmt.zig but works so that UTF8 still gets printed as a string
/// Useful for avoiding things like printing the Operating System Command (0x9D) control character
/// which can really break terminal printing
/// Also allows invalid UTF-8 to be printed (the invalid bytes will likely be escaped).
fn FormatUtf8SliceEscape(comptime case: Case) type {
    const charset = "0123456789" ++ if (case == .upper) "ABCDEF" else "abcdef";

    return struct {
        pub fn f(
            bytes: []const u8,
            comptime fmt: []const u8,
            options: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            _ = fmt;
            _ = options;
            var buf: [4]u8 = undefined;

            buf[0] = '\\';
            buf[1] = 'x';

            var it = InvalidUtf8Iterator{ .bytes = bytes, .i = 0 };
            while (it.nextCodepointSlice() catch c: {
                // On invalid UTF-8, treat the first byte as the 'codepoint slice'
                // and then move past that char.
                // This should always write an escaped character within the loop.
                it.i += 1;
                break :c it.bytes[it.i - 1 .. it.i];
            }) |c| {
                if (c.len == 1) {
                    if (std.ascii.isPrint(c[0])) {
                        try writer.writeByte(c[0]);
                    } else {
                        buf[2] = charset[c[0] >> 4];
                        buf[3] = charset[c[0] & 15];
                        try writer.writeAll(&buf);
                    }
                } else {
                    if (!isUtf8ControlCode(c)) {
                        try writer.writeAll(c);
                    } else {
                        buf[2] = charset[c[1] >> 4];
                        buf[3] = charset[c[1] & 15];
                        try writer.writeAll(&buf);
                    }
                }
            }
        }
    };
}

const formatUtf8SliceEscapeLower = FormatUtf8SliceEscape(.lower).f;
const formatUtf8SliceEscapeUpper = FormatUtf8SliceEscape(.upper).f;

/// Return a Formatter for a []const u8 where every C0 and C1 control
/// character is escaped as \xNN, where NN is the character in lowercase
/// hexadecimal notation.
pub fn fmtUtf8SliceEscapeLower(bytes: []const u8) std.fmt.Formatter(formatUtf8SliceEscapeLower) {
    return .{ .data = bytes };
}

/// Return a Formatter for a []const u8 where every C0 and C1 control
/// character is escaped as \xNN, where NN is the character in uppercase
/// hexadecimal notation.
pub fn fmtUtf8SliceEscapeUpper(bytes: []const u8) std.fmt.Formatter(formatUtf8SliceEscapeUpper) {
    return .{ .data = bytes };
}

/// Run the function once and get the total number of allocations,
/// then iterate and run the function while incrementing the failing
/// index each iteration.
///
/// This is a somewhat hacky generic version of the logic in
/// Zig's std/zig/parser_test.zig `testTransform` function.
pub fn checkAllAllocationFailures(backing_allocator: std.mem.Allocator, comptime f: anytype, extra_args: anytype) !void {
    switch (@typeInfo(@typeInfo(@TypeOf(f)).Fn.return_type.?)) {
        .ErrorUnion => |info| {
            if (info.payload != void) {
                @compileError("Return type must be !void");
            }
        },
        else => @compileError("Return type must be !void"),
    }
    const ArgsTuple = std.meta.ArgsTuple(@TypeOf(f));
    var args: ArgsTuple = undefined;
    inline for (@typeInfo(@TypeOf(extra_args)).Struct.fields) |field, i| {
        const arg_i_str = comptime str: {
            var str_buf: [100]u8 = undefined;
            const args_i = i + 1;
            const str_len = std.fmt.formatIntBuf(&str_buf, args_i, 10, .lower, .{});
            break :str str_buf[0..str_len];
        };
        @field(args, arg_i_str) = @field(extra_args, field.name);
    }

    const needed_alloc_count = x: {
        // Try it once with unlimited memory, make sure it works
        var failing_allocator_inst = std.testing.FailingAllocator.init(backing_allocator, std.math.maxInt(usize));
        args.@"0" = failing_allocator_inst.allocator();
        try @call(.{}, f, args);
        break :x failing_allocator_inst.index;
    };

    var fail_index: usize = 0;
    while (fail_index < needed_alloc_count) : (fail_index += 1) {
        var failing_allocator_inst = std.testing.FailingAllocator.init(backing_allocator, fail_index);
        args.@"0" = failing_allocator_inst.allocator();

        if (@call(.{}, f, args)) |_| {
            return error.NondeterministicMemoryUsage;
        } else |err| switch (err) {
            error.OutOfMemory => {
                if (failing_allocator_inst.allocated_bytes != failing_allocator_inst.freed_bytes) {
                    print(
                        "\nfail_index: {d}/{d}\nallocated bytes: {d}\nfreed bytes: {d}\nallocations: {d}\ndeallocations: {d}\n",
                        .{
                            fail_index,
                            needed_alloc_count,
                            failing_allocator_inst.allocated_bytes,
                            failing_allocator_inst.freed_bytes,
                            failing_allocator_inst.allocations,
                            failing_allocator_inst.deallocations,
                        },
                    );
                    return error.MemoryLeakDetected;
                }
            },
            else => return err,
        }
    }
}
