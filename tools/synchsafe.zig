const std = @import("std");
const assert = std.debug.assert;
const synchsafe = @import("audiometa").synchsafe;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer assert(gpa.deinit() == false);
    const allocator = &gpa.allocator;

    var args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        std.debug.print("usage: {s} [-d] <number>\n\nEncodes by default, pass -d to decode.\n", .{args[0]});
        return;
    }

    var num_index: usize = 1;
    var encode = true;
    if (std.mem.eql(u8, "-d", args[1])) {
        encode = false;
        num_index += 1;
    }

    const number = try std.fmt.parseInt(u32, args[1], 0);
    const result = result: {
        if (encode) {
            break :result synchsafe.encode(u32, number);
        } else {
            break :result synchsafe.decode(u32, number);
        }
    };

    std.debug.print("0x{x}\n", .{result});
}
