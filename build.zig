const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const os_tag = target.result.os.tag;

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    mod.addIncludePath(b.path("src"));
    mod.addCSourceFile(.{ .file = b.path("src/orb_math.c"), .flags = &.{} });

    if (os_tag == .windows) {
        mod.addCSourceFile(.{ .file = b.path("src/shim_win.c"), .flags = &.{} });
        for ([_][]const u8{ "user32", "gdi32", "shell32", "winmm", "advapi32", "ole32" }) |lib| {
            mod.linkSystemLibrary(lib, .{});
        }
    } else {
        for ([_][]const u8{ "src/shim.m", "src/orb.m", "src/orbview.m" }) |file| {
            mod.addCSourceFile(.{ .file = b.path(file), .flags = &.{"-fobjc-arc"} });
        }
        for ([_][]const u8{ "Cocoa", "Speech", "AVFoundation", "Carbon", "ApplicationServices", "QuartzCore" }) |fw| {
            mod.linkFramework(fw, .{});
        }
    }

    const exe = b.addExecutable(.{ .name = "free-voice-transcribe", .root_module = mod });
    if (os_tag == .windows) {
        exe.subsystem = .Windows;
        const install_script = b.addInstallFileWithDir(
            b.path("scripts/copilot_bridge.ps1"),
            .bin,
            "copilot_bridge.ps1",
        );
        b.getInstallStep().dependOn(&install_script.step);
    }
    b.installArtifact(exe);

    // `zig build app` produces a signed .app bundle on macOS (needed for mic/speech permission prompts).
    const bundle = b.addSystemCommand(&.{"scripts/bundle.sh"});
    bundle.step.dependOn(b.getInstallStep());
    b.step("app", "Build FreeVoiceTranscribe.app (macOS)").dependOn(&bundle.step);
}
