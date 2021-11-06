const std = @import("std");

const package_sqlite = std.build.Pkg{
    .name = "sqlite",
    .path = .{ .path = "third_party/zig-sqlite/sqlite.zig" },
};
const package_args = std.build.Pkg{
    .name = "args",
    .path = .{ .path = "third_party/zig-args/args.zig" },
};
const package_prometheus = std.build.Pkg{
    .name = "prometheus",
    .path = .{ .path = "third_party/zig-prometheus/src/main.zig" },
};
const package_apple_pie = std.build.Pkg{
    .name = "apple_pie",
    .path = .{ .path = "third_party/apple_pie/src/apple_pie.zig" },
};

const packages = &[_]std.build.Pkg{
    package_sqlite,
    package_args,
    package_prometheus,
    package_apple_pie,
};

pub fn build(b: *std.build.Builder) void {
    const test_data = b.option([]const u8, "test_data", "Test with this data file");

    var target = b.standardTargetOptions(.{});
    target.setGnuLibCVersion(2, 28, 0);
    const mode = b.standardReleaseOptions();

    const sqlite = b.addStaticLibrary("sqlite", null);
    sqlite.addCSourceFile("third_party/zig-sqlite/c/sqlite3.c", &[_][]const u8{
        "-std=c99",
        "-Wall",
        "-Wextra",
        "-fsanitize=undefined",
    });
    sqlite.linkLibC();

    //

    const exe = b.addExecutable("hdas", "src/main.zig");
    exe.setTarget(target);
    exe.setBuildMode(mode);
    exe.addIncludeDir("third_party/zig-sqlite/c");

    inline for (packages) |pkg| {
        exe.addPackage(pkg);
    }

    exe.linkLibC();
    exe.linkLibrary(sqlite);

    exe.install();

    //

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    var exe_tests = b.addTest("src/test.zig");
    exe_tests.setBuildMode(mode);

    const test_step = b.step("test", "Run unit tests");

    const tests_options = b.addOptions();
    tests_options.addOption(?[]const u8, "test_data", test_data);

    exe_tests.addOptions("build_options", tests_options);
    test_step.dependOn(&exe_tests.step);
}
