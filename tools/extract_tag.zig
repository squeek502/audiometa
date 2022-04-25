const std = @import("std");
const audiometa = @import("audiometa");
const assert = std.debug.assert;

pub fn main() anyerror!void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer assert(gpa.deinit() == false);
    const allocator = gpa.allocator();

    var args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 3) {
        std.debug.print("usage: {s} <tagged_file> <output_file> [tag_number]\n", .{args[0]});
        return;
    }

    const in_path = args[1];
    const out_path = args[2];
    var index_selection: ?usize = blk: {
        if (args.len < 4) break :blk null;
        const index_str = args[3];
        break :blk (std.fmt.parseInt(usize, index_str, 10) catch null);
    };

    var file = try std.fs.cwd().openFile(in_path, .{});
    defer file.close();

    var stream_source = std.io.StreamSource{ .file = file };
    var all_metadata = try audiometa.metadata.readAll(allocator, &stream_source);
    defer all_metadata.deinit();

    var buf: std.ArrayList(u8) = std.ArrayList(u8).init(allocator);
    defer buf.deinit();

    for (all_metadata.tags) |tag, i| {
        if (index_selection != null and index_selection.? != i + 1) {
            continue;
        }
        const metadata: *const audiometa.metadata.Metadata = switch (tag) {
            .id3v2 => &tag.id3v2.metadata,
            .ape => &tag.ape.metadata,
            .id3v1, .vorbis, .flac, .mp4 => |*val| val,
        };
        if (tag == .flac) {
            // FLAC start/end offsets only include the block itself, so we need to provide the headers
            var buf_writer = buf.writer();
            try buf_writer.writeAll(audiometa.flac.flac_stream_marker);
            const is_last_metadata_block = @as(u8, 1 << 7);
            try buf_writer.writeByte(audiometa.flac.block_type_vorbis_comment | is_last_metadata_block);
            try buf_writer.writeIntBig(u24, @intCast(u24, metadata.end_offset - metadata.start_offset));
            try sliceFileIntoBuf(&buf, file, metadata.start_offset, metadata.end_offset);
        } else if (tag == .mp4) {
            // MP4 start/end offsets only include the 'meta' atom, so we need to provide the ftyp and moov atoms
            const meta_data_len = metadata.end_offset - metadata.start_offset;
            try writeMp4Atoms(buf.writer(), @intCast(u32, meta_data_len));
            try sliceFileIntoBuf(&buf, file, metadata.start_offset, metadata.end_offset);
        } else {
            try sliceFileIntoBuf(&buf, file, metadata.start_offset, metadata.end_offset);
        }
    }

    std.debug.print("buflen: {d}\n", .{buf.items.len});
    var out_file = try std.fs.cwd().createFile(out_path, .{});
    defer out_file.close();

    try out_file.writeAll(buf.items);
}

fn sliceFileIntoBuf(buf: *std.ArrayList(u8), file: std.fs.File, start_offset: usize, end_offset: usize) !void {
    var contents_len = end_offset - start_offset;
    try buf.ensureUnusedCapacity(contents_len);
    var buf_slice = buf.unusedCapacitySlice()[0..contents_len];
    const bytes_read = try file.pread(buf_slice, start_offset);
    assert(bytes_read == contents_len);
    buf.items.len += bytes_read;
}

fn writeMp4Atoms(writer: anytype, meta_atom_len: u32) !void {
    const moov_len = audiometa.mp4.AtomHeader.len;
    const udta_len = audiometa.mp4.AtomHeader.len;

    const minimal_ftyp_data = "\x00\x00\x00\x08ftyp";
    try writer.writeAll(minimal_ftyp_data);

    var atom_len: u32 = moov_len + udta_len + meta_atom_len;
    try writer.writeIntBig(u32, atom_len);
    try writer.writeAll("moov");
    atom_len -= moov_len;
    try writer.writeIntBig(u32, atom_len);
    try writer.writeAll("udta");
}
