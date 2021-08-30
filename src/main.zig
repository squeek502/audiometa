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

        if (metadata.all_id3v2) |id3v2_metadata_list| {
            for (id3v2_metadata_list) |*id3v2_metadata, i| {
                std.debug.print("\nID3v2 Tag #{} (v2.{d})\n===================\n", .{ i + 1, id3v2_metadata.header.major_version });
                id3v2_metadata.metadata.map.dump();
            }
        }
        if (metadata.flac) |*flac_metadata| {
            std.debug.print("\nFLAC Metadata\n=============\n", .{});
            flac_metadata.map.dump();
        }
        if (metadata.id3v1) |*id3v1_metadata| {
            std.debug.print("\nID3v1 Tag\n=========\n", .{});
            id3v1_metadata.map.dump();
        }
    }
}
