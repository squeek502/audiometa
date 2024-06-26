const std = @import("std");

// From https://www.unicode.org/Public/UCD/latest/ucd/CaseFolding.txt
const case_folding_txt = @embedFile("CaseFolding.txt");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    const unbuf_stdout = std.io.getStdOut().writer();
    var buf_stdout = std.io.bufferedWriter(unbuf_stdout);
    const writer = buf_stdout.writer();

    var codepoint_mapping = std.AutoArrayHashMap(u21, [3]u21).init(allocator);
    defer codepoint_mapping.deinit();

    var line_it = std.mem.tokenizeAny(u8, case_folding_txt, "\r\n");
    while (line_it.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;

        var field_it = std.mem.splitScalar(u8, line, ';');
        const codepoint_str = field_it.first();
        const codepoint = try std.fmt.parseUnsigned(u21, codepoint_str, 16);

        const status = std.mem.trim(u8, field_it.next() orelse continue, " ");
        // Only interested in 'common' and 'full'
        if (status[0] != 'C' and status[0] != 'F') continue;

        const mapping = std.mem.trim(u8, field_it.next() orelse continue, " ");
        var mapping_it = std.mem.splitScalar(u8, mapping, ' ');
        var mapping_buf = [_]u21{0} ** 3;
        var mapping_i: u8 = 0;
        while (mapping_it.next()) |mapping_c| {
            mapping_buf[mapping_i] = try std.fmt.parseInt(u21, mapping_c, 16);
            mapping_i += 1;
        }

        try codepoint_mapping.putNoClobber(codepoint, mapping_buf);
    }

    var offset_to_index = std.AutoHashMap(i32, u8).init(allocator);
    defer offset_to_index.deinit();
    var unique_offsets = std.AutoArrayHashMap(i32, u32).init(allocator);
    defer unique_offsets.deinit();

    // First pass
    {
        var it = codepoint_mapping.iterator();
        while (it.next()) |entry| {
            const codepoint = entry.key_ptr.*;
            const mappings = std.mem.sliceTo(entry.value_ptr, 0);
            if (mappings.len == 1) {
                const offset: i32 = @as(i32, mappings[0]) - @as(i32, codepoint);
                const result = try unique_offsets.getOrPut(offset);
                if (!result.found_existing) result.value_ptr.* = 0;
                result.value_ptr.* += 1;
            }
        }

        // A codepoint mapping to itself (offset=0) is the most common case
        try unique_offsets.put(0, 0x10FFFF);
        const C = struct {
            vals: []u32,

            pub fn lessThan(ctx: @This(), a_index: usize, b_index: usize) bool {
                return ctx.vals[a_index] > ctx.vals[b_index];
            }
        };
        unique_offsets.sort(C{ .vals = unique_offsets.values() });

        var offset_it = unique_offsets.iterator();
        var offset_index: u7 = 0;
        while (offset_it.next()) |entry| {
            try offset_to_index.put(entry.key_ptr.*, offset_index);
            offset_index += 1;
        }
    }

    var mappings_to_index = std.AutoArrayHashMap([3]u21, u8).init(allocator);
    defer mappings_to_index.deinit();
    var codepoint_to_index = std.AutoHashMap(u21, u8).init(allocator);
    defer codepoint_to_index.deinit();

    // Second pass
    {
        var count_multiple_codepoints: u8 = 0;

        var it = codepoint_mapping.iterator();
        while (it.next()) |entry| {
            const codepoint = entry.key_ptr.*;
            const mappings = std.mem.sliceTo(entry.value_ptr, 0);
            if (mappings.len > 1) {
                const result = try mappings_to_index.getOrPut(entry.value_ptr.*);
                if (!result.found_existing) {
                    result.value_ptr.* = 0x80 | count_multiple_codepoints;
                    count_multiple_codepoints += 1;
                }
                const index = result.value_ptr.*;
                try codepoint_to_index.put(codepoint, index);
            } else {
                const offset: i32 = @as(i32, mappings[0]) - @as(i32, codepoint);
                const index = offset_to_index.get(offset).?;
                try codepoint_to_index.put(codepoint, index);
            }
        }
    }

    // Build the stage1/stage2/stage3 arrays and output them
    {
        const Block = [256]u8;
        var stage2_blocks = std.AutoArrayHashMap(Block, void).init(allocator);
        defer stage2_blocks.deinit();

        const empty_block: Block = [_]u8{0} ** 256;
        try stage2_blocks.put(empty_block, {});
        const stage1_len = (0x10FFFF / 256) + 1;
        var stage1: [stage1_len]u8 = undefined;

        var codepoint: u21 = 0;
        var block: Block = undefined;
        while (codepoint <= 0x10FFFF) {
            const data_index = codepoint_to_index.get(codepoint) orelse 0;
            block[codepoint % 256] = data_index;

            codepoint += 1;
            if (codepoint % 256 == 0) {
                const result = try stage2_blocks.getOrPut(block);
                const index = result.index;
                stage1[(codepoint >> 8) - 1] = @intCast(index);
            }
        }

        const last_meaningful_block = std.mem.lastIndexOfNone(u8, &stage1, "\x00").?;
        const meaningful_stage1 = stage1[0 .. last_meaningful_block + 1];
        const codepoint_cutoff = (last_meaningful_block + 1) << 8;
        const multiple_codepoint_start: usize = unique_offsets.count();

        var index: usize = 0;
        const stage3_elems = unique_offsets.count() + mappings_to_index.count() * 3;
        var stage3 = try allocator.alloc(i24, stage3_elems);
        defer allocator.free(stage3);
        for (unique_offsets.keys()) |key| {
            stage3[index] = @intCast(key);
            index += 1;
        }
        for (mappings_to_index.keys()) |key| {
            stage3[index] = @intCast(key[0]);
            stage3[index + 1] = @intCast(key[1]);
            stage3[index + 2] = @intCast(key[2]);
            index += 3;
        }

        const stage2_elems = stage2_blocks.count() * 256;
        var stage2 = try allocator.alloc(u8, stage2_elems);
        defer allocator.free(stage2);
        for (stage2_blocks.keys(), 0..) |key, i| {
            @memcpy(stage2[i * 256 ..][0..256], &key);
        }

        try writer.print("const cutoff = 0x{X};\n", .{codepoint_cutoff});
        try writeArray(writer, u8, "stage1", meaningful_stage1);
        try writeArray(writer, u8, "stage2", stage2);
        try writer.print("const multiple_start = {};\n", .{multiple_codepoint_start});
        try writeArray(writer, i24, "stage3", stage3);
    }

    try buf_stdout.flush();
}

fn writeArray(writer: anytype, comptime T: type, name: []const u8, data: []const T) !void {
    try writer.print("const {s} = [{}]{s}{{", .{ name, data.len, @typeName(T) });

    for (data, 0..) |v, i| {
        if (i % 32 == 0) try writer.writeAll("\n    ");
        try writer.print("{},", .{v});
        if (i != data.len - 1) try writer.writeByte(' ');
    }

    try writer.writeAll("\n};\n");
}
