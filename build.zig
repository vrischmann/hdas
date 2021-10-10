const std = @import("std");
const deps = @import("deps.zig");

pub fn build(b: *std.build.Builder) void {
    const test_data = b.option([]const u8, "test_data", "Test with this data file");

    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();

    const exe = b.addExecutable("health-data-api", "src/main.zig");
    exe.setTarget(target);
    exe.setBuildMode(mode);
    deps.addAllTo(exe);
    exe.install();

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
