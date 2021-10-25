const std = @import("std");
const audiometa = @import("audiometa");
const assert = std.debug.assert;

pub fn main() anyerror!void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer assert(gpa.deinit() == false);
    const allocator = &gpa.allocator;

    var args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    for (args[1..]) |arg| {
        var file = try std.fs.cwd().openFile(arg, .{});
        defer file.close();

        var stream_source = std.io.StreamSource{ .file = file };
        var metadata = try audiometa.metadata.readAll(allocator, &stream_source);
        defer metadata.deinit();

        var id3v2_count: usize = 0;
        for (metadata.tags) |tag| {
            switch (tag) {
                .id3v1 => |*id3v1_meta| {
                    std.debug.print("\nID3v1 Tag\n=========\n", .{});
                    id3v1_meta.map.dump();
                },
                .flac => |*flac_meta| {
                    std.debug.print("\nFLAC Metadata\n=============\n", .{});
                    flac_meta.map.dump();
                },
                .vorbis => |*vorbis_meta| {
                    std.debug.print("\nVorbis Tag\n==========\n", .{});
                    vorbis_meta.map.dump();
                },
                .id3v2 => |*id3v2_meta| {
                    id3v2_count += 1;
                    std.debug.print("\nID3v2 Tag #{} (v2.{d})\n===================\n", .{ id3v2_count, id3v2_meta.header.major_version });
                    id3v2_meta.metadata.map.dump();
                },
                .ape => |*ape_meta| {
                    std.debug.print("\nAPE Tag (v{d})\n=============\n", .{ape_meta.header_or_footer.version});
                    ape_meta.metadata.map.dump();
                },
            }
        }
    }
}
