const std = @import("std");
const audiometa = @import("audiometa");
const assert = std.debug.assert;

pub fn main() anyerror!void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    var args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    for (args[1..]) |arg| {
        var file = try std.fs.cwd().openFile(arg, .{});
        defer file.close();

        var stream_source = std.io.StreamSource{ .file = file };
        var metadata = try audiometa.metadata.readAll(allocator, &stream_source);
        defer metadata.deinit();

        for (metadata.tags, 0..) |tag, i| {
            switch (tag) {
                .id3v1 => |*id3v1_meta| {
                    std.debug.print("\n#{}: ID3v1 Tag\n=============\n", .{i + 1});
                    id3v1_meta.map.dump();
                },
                .flac => |*flac_meta| {
                    std.debug.print("\n#{}: FLAC Metadata\n=================\n", .{i + 1});
                    flac_meta.map.dump();
                },
                .vorbis => |*vorbis_meta| {
                    std.debug.print("\n#{}: Vorbis Tag\n==============\n", .{i + 1});
                    vorbis_meta.map.dump();
                },
                .id3v2 => |*id3v2_meta| {
                    std.debug.print("\n#{}: ID3v2 Tag (v2.{d})\n=======================\n", .{ i + 1, id3v2_meta.header.major_version });
                    id3v2_meta.dump();
                },
                .ape => |*ape_meta| {
                    std.debug.print("\n#{}: APE Tag (v{d})\n=================\n", .{ i + 1, ape_meta.header_or_footer.version });
                    ape_meta.metadata.map.dump();
                },
                .mp4 => |*mp4_meta| {
                    std.debug.print("\n#{}: MP4\n=======================\n", .{i + 1});
                    mp4_meta.map.dump();
                },
            }
        }
    }
}
