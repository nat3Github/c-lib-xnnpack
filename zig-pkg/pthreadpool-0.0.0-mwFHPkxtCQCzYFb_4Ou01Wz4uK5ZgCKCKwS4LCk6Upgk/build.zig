const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    _ = addModule(b, target, optimize);
}

pub fn addModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    const mod = b.addModule("pthreadpool", .{
        .root_source_file = null,
        .target = target,
        .optimize = optimize,
    });
    mod.addIncludePath(b.path("include"));
    // FXdiv: header-only pthreadpool dependency, not worth its own package.
    mod.addIncludePath(b.dependency("fxdiv", .{}).path("include"));

    // Upstream defaults PTHREADPOOL_USE_PTHREADS to 0 on Windows (native
    // Win32-threads + C11 `<threads.h>` path instead) — but zig's bundled
    // mingw doesn't ship `<threads.h>`. mingw's `<pthread.h>` (via
    // winpthreads) works fine, so force the pthreads path on Windows too
    // rather than porting the native-Win32-threads variant.
    const flags: []const []const u8 = if (target.result.os.tag == .windows)
        &[_][]const u8{ "-std=gnu11", "-DPTHREADPOOL_USE_PTHREADS=1" }
    else
        &[_][]const u8{"-std=gnu11"};
    const srcs = &[_][]const u8{ "src/portable-api.c", "src/memory.c", "src/pthreads.c" };
    for (srcs) |s| mod.addCSourceFile(.{ .file = b.path(s), .flags = flags });

    return mod;
}
