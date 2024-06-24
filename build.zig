const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardOptimizeOption(.{});

    const audiometa = b.addModule("audiometa", .{
        .root_source_file = b.path("src/audiometa.zig"),
    });

    const exe = b.addExecutable(.{
        .name = "audiometa",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = mode,
    });
    exe.root_module.addImport("audiometa", audiometa);
    b.installArtifact(exe);

    // Tests

    const test_filter = b.option([]const u8, "test-filter", "Skip tests that do not match filter");

    const tests = b.addTest(.{
        .root_source_file = b.path("src/audiometa.zig"),
        .target = target,
        .optimize = mode,
        .filter = test_filter,
    });
    const run_tests = b.addRunArtifact(tests);

    const test_lib_step = b.step("test-lib", "Run all library tests (without parse tests)");
    test_lib_step.dependOn(&run_tests.step);

    const parse_tests = b.addTest(.{
        .root_source_file = b.path("test/parse_tests.zig"),
        .target = target,
        .optimize = mode,
        .filter = test_filter,
    });
    parse_tests.root_module.addImport("audiometa", audiometa);
    const run_parse_tests = b.addRunArtifact(parse_tests);

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(&run_parse_tests.step);

    const test_against_taglib = b.addTest(.{
        .root_source_file = b.path("test/test_against_taglib.zig"),
        .target = target,
        .optimize = mode,
        .filter = test_filter,
    });
    test_against_taglib.root_module.addImport("audiometa", audiometa);
    const run_test_against_taglib = b.addRunArtifact(test_against_taglib);
    const test_against_taglib_step = b.step("test_against_taglib", "Test tag parsing against taglib");
    test_against_taglib_step.dependOn(&run_test_against_taglib.step);

    const test_against_ffprobe = b.addTest(.{
        .root_source_file = b.path("test/test_against_ffprobe.zig"),
        .target = target,
        .optimize = mode,
        .filter = test_filter,
    });
    test_against_ffprobe.root_module.addImport("audiometa", audiometa);
    const run_test_against_ffprobe = b.addRunArtifact(test_against_ffprobe);
    const test_against_ffprobe_step = b.step("test_against_ffprobe", "Test tag parsing against ffprobe");
    test_against_ffprobe_step.dependOn(&run_test_against_ffprobe.step);

    // Tools

    const extract_tag_exe = b.addExecutable(.{
        .name = "extract_tag",
        .root_source_file = b.path("tools/extract_tag.zig"),
        .target = target,
        .optimize = mode,
    });
    extract_tag_exe.root_module.addImport("audiometa", audiometa);
    b.installArtifact(extract_tag_exe);

    const synchsafe_exe = b.addExecutable(.{
        .name = "synchsafe",
        .root_source_file = b.path("tools/synchsafe.zig"),
        .target = target,
        .optimize = mode,
    });
    synchsafe_exe.root_module.addImport("audiometa", audiometa);
    b.installArtifact(synchsafe_exe);

    // Fuzz

    _ = addFuzzer(b, "fuzz", &.{}, audiometa, target) catch unreachable;
    _ = addFuzzer(b, "fuzz-collation", &.{}, audiometa, target) catch unreachable;

    var fuzz_oom = addFuzzer(b, "fuzz-oom", &.{}, audiometa, target) catch unreachable;
    // setup build options
    {
        const debug_options = b.addOptions();
        debug_options.addOption(bool, "is_zig_debug_version", true);
        fuzz_oom.debug_exe.root_module.addOptions("build_options", debug_options);
        const afl_options = b.addOptions();
        afl_options.addOption(bool, "is_zig_debug_version", false);
        fuzz_oom.lib.root_module.addOptions("build_options", afl_options);
    }
}

fn addFuzzer(
    b: *std.Build,
    comptime name: []const u8,
    afl_clang_args: []const []const u8,
    audiometa: *std.Build.Module,
    target: std.Build.ResolvedTarget,
) !FuzzerSteps {
    // The library
    const fuzz_lib = b.addStaticLibrary(.{
        .name = name ++ "-lib",
        .root_source_file = b.path("test/" ++ name ++ ".zig"),
        .target = target,
        .optimize = .Debug,
    });
    fuzz_lib.root_module.addImport("audiometa", audiometa);
    fuzz_lib.want_lto = true;
    fuzz_lib.bundle_compiler_rt = true;
    fuzz_lib.root_module.pic = true;

    // Setup the output name
    const fuzz_executable_name = name;

    // We want `afl-clang-lto -o path/to/output path/to/library`
    const fuzz_compile = b.addSystemCommand(&.{ "afl-clang-lto", "-o" });
    const fuzz_exe_path = fuzz_compile.addOutputFileArg(name);
    // Add the path to the library file to afl-clang-lto's args
    fuzz_compile.addArtifactArg(fuzz_lib);
    // Custom args
    fuzz_compile.addArgs(afl_clang_args);

    // Install the cached output to the install 'bin' path
    const fuzz_install = b.addInstallBinFile(fuzz_exe_path, fuzz_executable_name);
    fuzz_install.step.dependOn(&fuzz_compile.step);

    // Add a top-level step that compiles and installs the fuzz executable
    const fuzz_compile_run = b.step(name, "Build executable for fuzz testing '" ++ name ++ "' using afl-clang-lto");
    fuzz_compile_run.dependOn(&fuzz_compile.step);
    fuzz_compile_run.dependOn(&fuzz_install.step);

    // Compile a companion exe for debugging crashes
    const fuzz_debug_exe = b.addExecutable(.{
        .name = name ++ "-debug",
        .root_source_file = b.path("test/" ++ name ++ ".zig"),
        .target = target,
        .optimize = .Debug,
    });
    fuzz_debug_exe.root_module.addImport("audiometa", audiometa);

    // Only install fuzz-debug when the fuzz step is run
    const install_fuzz_debug_exe = b.addInstallArtifact(fuzz_debug_exe, .{});
    fuzz_compile_run.dependOn(&install_fuzz_debug_exe.step);

    return FuzzerSteps{
        .lib = fuzz_lib,
        .debug_exe = fuzz_debug_exe,
    };
}

const FuzzerSteps = struct {
    lib: *std.Build.Step.Compile,
    debug_exe: *std.Build.Step.Compile,

    pub fn libExes(self: *const FuzzerSteps) [2]*std.Build.Step.Compile {
        return [_]*std.Build.Step.Compile{ self.lib, self.debug_exe };
    }
};
