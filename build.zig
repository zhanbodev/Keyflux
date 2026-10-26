const std = @import("std");
const builtin = @import("builtin");

comptime {
    if (!std.mem.eql(u8, builtin.zig_version_string, "0.17.0")) @compileError("Keyflux requires Zig 0.17.0 (see .zigversion)");
}

pub fn build(b: *std.Build) void {
    const default_target: std.Target.Query = switch (builtin.os.tag) {
        .macos => .{ .os_tag = .macos, .os_version_min = .{ .semver = .{ .major = 13, .minor = 0, .patch = 0 } } },
        .windows => .{ .os_tag = .windows, .abi = .gnu, .os_version_min = .{ .windows = .win10 } },
        else => .{},
    };
    const target = b.standardTargetOptions(.{ .default_target = default_target });
    const optimize = b.standardOptimizeOption(.{});
    const mod = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize, .link_libc = true });
    mod.addCSourceFile(.{ .file = b.path("native/platform.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra" } });
    mod.addCSourceFile(.{ .file = b.path("native/kick75.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra" } });
    mod.addIncludePath(b.path("vendor/hidapi/hidapi"));
    mod.addIncludePath(b.path("vendor/hidapi/mac"));
    switch (target.result.os.tag) {
        .macos => {
            const sdk = b.option([]const u8, "macos-sdk", "Apple macOS SDK root") orelse if (builtin.os.tag == .macos) std.mem.trim(u8, b.run(&.{ "xcrun", "--sdk", "macosx", "--show-sdk-path" }), " \r\n") else @panic("Cross-compiling macOS requires -Dmacos-sdk=/path/to/SDK");
            mod.addSystemIncludePath(.{ .cwd_relative = b.fmt("{s}/usr/include", .{sdk}) });
            mod.addSystemFrameworkPath(.{ .cwd_relative = b.fmt("{s}/System/Library/Frameworks", .{sdk}) });
            mod.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/usr/lib", .{sdk}) });
            mod.addCSourceFile(.{ .file = b.path("vendor/hidapi/mac/hid.c"), .flags = &.{"-std=c11"} });
            mod.linkFramework("IOKit", .{});
            mod.linkFramework("CoreFoundation", .{});
        },
        .windows => {
            mod.addCSourceFile(.{ .file = b.path("vendor/hidapi/windows/hid.c"), .flags = &.{"-std=c11"} });
            mod.linkSystemLibrary("ws2_32", .{});
            mod.linkSystemLibrary("advapi32", .{});
            mod.linkSystemLibrary("bcrypt", .{});
            mod.linkSystemLibrary("psapi", .{});
        },
        else => @panic("Keyflux runtime supports macOS and Windows; use zig test src/tests.zig for portable core tests"),
    }
    const exe = b.addExecutable(.{ .name = "keyflux", .root_module = mod });
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    b.step("run", "Run Keyflux").dependOn(&run.step);
    const tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("src/tests.zig"), .target = target, .optimize = optimize }) });
    b.step("test", "Run portable core and contract tests").dependOn(&b.addRunArtifact(tests).step);
}
