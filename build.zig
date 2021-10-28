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

    var test_against_taglib = b.addTest("test/test_against_taglib.zig");
    test_against_taglib.setBuildMode(mode);
    test_against_taglib.setTarget(target);
    test_against_taglib.setFilter(test_filter);
    test_against_taglib.addPackagePath("audiometa", "src/audiometa.zig");
    const test_against_taglib_step = b.step("test_against_taglib", "Test tag parsing against taglib");
    test_against_taglib_step.dependOn(&test_against_taglib.step);

    var test_against_ffprobe = b.addTest("test/test_against_ffprobe.zig");
    test_against_ffprobe.setBuildMode(mode);
    test_against_ffprobe.setTarget(target);
    test_against_ffprobe.setFilter(test_filter);
    test_against_ffprobe.addPackagePath("audiometa", "src/audiometa.zig");
    const test_against_ffprobe_step = b.step("test_against_ffprobe", "Test tag parsing against ffprobe");
    test_against_ffprobe_step.dependOn(&test_against_ffprobe.step);

    // Tools

    const extract_tag_exe = b.addExecutable("extract_tag", "tools/extract_tag.zig");
    extract_tag_exe.addPackagePath("audiometa", "src/audiometa.zig");
    extract_tag_exe.setTarget(target);
    extract_tag_exe.setBuildMode(mode);
    extract_tag_exe.install();

    const extract_tag_run = extract_tag_exe.run();
    extract_tag_run.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        extract_tag_run.addArgs(args);
    }
    const extract_tag_run_step = b.step("run_extract_tag", "Run the extract tag tool");
    extract_tag_run_step.dependOn(&extract_tag_run.step);

    // Fuzz

    _ = addFuzzer(b, "fuzz", &.{}) catch unreachable;

    var fuzz_oom = addFuzzer(b, "fuzz-oom", &.{}) catch unreachable;
    // setup build options
    {
        const debug_options = b.addOptions();
        debug_options.addOption(bool, "is_zig_debug_version", true);
        fuzz_oom.debug_exe.addOptions("build_options", debug_options);
        const afl_options = b.addOptions();
        afl_options.addOption(bool, "is_zig_debug_version", false);
        fuzz_oom.lib.addOptions("build_options", afl_options);
    }
}

fn addFuzzer(b: *std.build.Builder, comptime name: []const u8, afl_clang_args: []const []const u8) !FuzzerSteps {
    // The library
    const fuzz_lib = b.addStaticLibrary(name ++ "-lib", "test/" ++ name ++ ".zig");
    fuzz_lib.addPackagePath("audiometa", "src/audiometa.zig");
    fuzz_lib.setBuildMode(.Debug);
    fuzz_lib.want_lto = true;
    fuzz_lib.bundle_compiler_rt = true;

    // Setup the output name
    const fuzz_executable_name = name;
    const fuzz_exe_path = try std.fs.path.join(b.allocator, &.{ b.cache_root, fuzz_executable_name });

    // We want `afl-clang-lto -o path/to/output path/to/library`
    const fuzz_compile = b.addSystemCommand(&.{ "afl-clang-lto", "-o", fuzz_exe_path });
    // Add the path to the library file to afl-clang-lto's args
    fuzz_compile.addArtifactArg(fuzz_lib);
    // Custom args
    fuzz_compile.addArgs(afl_clang_args);

    // Install the cached output to the install 'bin' path
    const fuzz_install = b.addInstallBinFile(.{ .path = fuzz_exe_path }, fuzz_executable_name);

    // Add a top-level step that compiles and installs the fuzz executable
    const fuzz_compile_run = b.step(name, "Build executable for fuzz testing '" ++ name ++ "' using afl-clang-lto");
    fuzz_compile_run.dependOn(&fuzz_compile.step);
    fuzz_compile_run.dependOn(&fuzz_install.step);

    // Compile a companion exe for debugging crashes
    const fuzz_debug_exe = b.addExecutable(name ++ "-debug", "test/" ++ name ++ ".zig");
    fuzz_debug_exe.addPackagePath("audiometa", "src/audiometa.zig");
    fuzz_debug_exe.setBuildMode(.Debug);

    // Only install fuzz-debug when the fuzz step is run
    const install_fuzz_debug_exe = b.addInstallArtifact(fuzz_debug_exe);
    fuzz_compile_run.dependOn(&install_fuzz_debug_exe.step);

    return FuzzerSteps{
        .lib = fuzz_lib,
        .debug_exe = fuzz_debug_exe,
    };
}

const FuzzerSteps = struct {
    lib: *std.build.LibExeObjStep,
    debug_exe: *std.build.LibExeObjStep,

    pub fn libExes(self: *const FuzzerSteps) [2]*std.build.LibExeObjStep {
        return [_]*std.build.LibExeObjStep{ self.lib, self.debug_exe };
    }
};
