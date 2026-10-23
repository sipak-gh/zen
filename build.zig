const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    b.installArtifact(b.addExecutable(.{ .name = "ze", .root_module = module }));

    const run = b.addRunArtifact(b.addTest(.{ .root_module = module }));
    b.step("test", "Run the tests").dependOn(&run.step);
}
