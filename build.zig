const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const mode = b.standardReleaseOptions();

    const exe = b.addExecutable("audiometa", "src/main.zig");
    exe.setTarget(target);
    exe.setBuildMode(mode);
    exe.addPackagePath("audiometa", "src/audiometa.zig");
    exe.install();

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // Tests

    const test_filter = b.option([]const u8, "test-filter", "Skip tests that do not match filter");

    var tests = b.addTest("src/audiometa.zig");
    tests.setBuildMode(mode);
    tests.setTarget(target);
    tests.setFilter(test_filter);

    var parse_tests = b.addTest("test/parse_tests.zig");
    parse_tests.setBuildMode(mode);
    parse_tests.setTarget(target);
    parse_tests.setFilter(test_filter);
    parse_tests.addPackagePath("audiometa", "src/audiometa.zig");

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&tests.step);
    test_step.dependOn(&parse_tests.step);

    // Tools

    const extract_tag_exe = b.addExecutable("extract_tag", "tools/extract_tag.zig");
    extract_tag_exe.addPackagePath("audiometa", "src/audiometa.zig");
    extract_tag_exe.setTarget(target);
    extract_tag_exe.setBuildMode(mode);
    extract_tag_exe.install();
}
