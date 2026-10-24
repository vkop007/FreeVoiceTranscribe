const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    for ([_][]const u8{ "src/shim.m", "src/orb.m", "src/orbview.m" }) |file| {
        mod.addCSourceFile(.{ .file = b.path(file), .flags = &.{"-fobjc-arc"} });
    }
    mod.addIncludePath(b.path("src"));
    for ([_][]const u8{ "Cocoa", "Speech", "AVFoundation", "Carbon", "ApplicationServices", "QuartzCore" }) |fw| {
        mod.linkFramework(fw, .{});
    }

    const exe = b.addExecutable(.{ .name = "siri-assistant", .root_module = mod });
    b.installArtifact(exe);

    // `zig build app` produces a signed .app bundle (needed for mic/speech permission prompts).
    const bundle = b.addSystemCommand(&.{"scripts/bundle.sh"});
    bundle.step.dependOn(b.getInstallStep());
    b.step("app", "Build SiriAssistant.app").dependOn(&bundle.step);
}
