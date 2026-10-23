const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const tiny = b.option(bool, "tiny", "Build ze-tiny: smallest size, no safety checks or symbols") orelse false;
    const module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = if (tiny) b.addExecutable(.{ .name = "ze-tiny", .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = .ReleaseSmall,
        .strip = true,
        .single_threaded = true,
        .unwind_tables = .none,
        .error_tracing = false,
    }) }) else b.addExecutable(.{ .name = "ze", .root_module = module });
    b.installArtifact(exe);

    const run = b.addRunArtifact(b.addTest(.{ .root_module = module }));
    b.step("test", "Run the tests").dependOn(&run.step);
}
