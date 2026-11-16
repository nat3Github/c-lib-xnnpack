const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    _ = addModule(b, target, optimize);
}

pub fn addModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    const mod = b.addModule("cpuinfo", .{
        .root_source_file = null,
        .target = target,
        .optimize = optimize,
    });
    mod.addIncludePath(b.path("include"));
    mod.addIncludePath(b.path("src"));

    const t = target.result;
    const common_flags = &[_][]const u8{ "-std=gnu11", "-DCPUINFO_LOG_LEVEL=2" };
    const linux_flags = &[_][]const u8{ "-std=gnu11", "-DCPUINFO_LOG_LEVEL=2", "-D_GNU_SOURCE=1" };
    const common_srcs = &[_][]const u8{
        "src/api.c", "src/cache.c", "src/init.c", "src/log.c",
    };
    for (common_srcs) |s| mod.addCSourceFile(.{ .file = b.path(s), .flags = common_flags });

    switch (t.os.tag) {
        .macos => switch (t.cpu.arch) {
            .aarch64 => {
                const arm_srcs = &[_][]const u8{
                    "src/arm/uarch.c", "src/arm/cache.c", "src/arm/mach/init.c", "src/mach/topology.c",
                };
                for (arm_srcs) |s| mod.addCSourceFile(.{ .file = b.path(s), .flags = common_flags });
            },
            .x86_64 => {
                const x86_srcs = &[_][]const u8{
                    "src/x86/init.c",             "src/x86/info.c",
                    "src/x86/vendor.c",           "src/x86/uarch.c",
                    "src/x86/name.c",             "src/x86/topology.c",
                    "src/x86/isa.c",              "src/x86/cache/init.c",
                    "src/x86/cache/descriptor.c", "src/x86/cache/deterministic.c",
                    "src/x86/mach/init.c",        "src/mach/topology.c",
                };
                for (x86_srcs) |s| mod.addCSourceFile(.{ .file = b.path(s), .flags = common_flags });
            },
            else => std.debug.panic("cpuinfo: unsupported macOS arch {s}", .{@tagName(t.cpu.arch)}),
        },
        .linux => {
            switch (t.cpu.arch) {
                .aarch64 => {
                    const arm_srcs = &[_][]const u8{
                        "src/arm/uarch.c",             "src/arm/cache.c",
                        "src/arm/linux/init.c",        "src/arm/linux/cpuinfo.c",
                        "src/arm/linux/clusters.c",    "src/arm/linux/chipset.c",
                        "src/arm/linux/midr.c",        "src/arm/linux/hwcap.c",
                        "src/arm/linux/aarch64-isa.c",
                    };
                    for (arm_srcs) |s| mod.addCSourceFile(.{ .file = b.path(s), .flags = linux_flags });
                },
                .x86_64 => {
                    const x86_srcs = &[_][]const u8{
                        "src/x86/init.c",             "src/x86/info.c",
                        "src/x86/vendor.c",           "src/x86/uarch.c",
                        "src/x86/name.c",             "src/x86/topology.c",
                        "src/x86/isa.c",              "src/x86/cache/init.c",
                        "src/x86/cache/descriptor.c", "src/x86/cache/deterministic.c",
                        "src/x86/linux/init.c",       "src/x86/linux/cpuinfo.c",
                    };
                    for (x86_srcs) |s| mod.addCSourceFile(.{ .file = b.path(s), .flags = linux_flags });
                },
                else => std.debug.panic("cpuinfo: unsupported Linux arch {s}", .{@tagName(t.cpu.arch)}),
            }
            const linux_srcs = &[_][]const u8{
                "src/linux/smallfile.c", "src/linux/multiline.c",
                "src/linux/cpulist.c",   "src/linux/processors.c",
            };
            for (linux_srcs) |s| mod.addCSourceFile(.{ .file = b.path(s), .flags = linux_flags });
            // Bionic: arm/linux/init.c reads system properties for chipset
            // detection, and log.c logs via liblog instead of stderr.
            if (t.abi.isAndroid()) {
                if (t.cpu.arch == .aarch64) mod.addCSourceFile(.{ .file = b.path("src/arm/android/properties.c"), .flags = linux_flags });
                mod.linkSystemLibrary("log", .{});
            }
        },
        .windows => switch (t.cpu.arch) {
            .x86_64 => {
                const x86_srcs = &[_][]const u8{
                    "src/x86/init.c",             "src/x86/info.c",
                    "src/x86/vendor.c",           "src/x86/uarch.c",
                    "src/x86/name.c",             "src/x86/topology.c",
                    "src/x86/isa.c",              "src/x86/cache/init.c",
                    "src/x86/cache/descriptor.c", "src/x86/cache/deterministic.c",
                    "src/x86/windows/init.c",
                };
                const windows_flags = &[_][]const u8{ "-std=gnu11", "-DCPUINFO_LOG_LEVEL=2", "-D_WIN32_WINNT=0x0601", "-D_CRT_SECURE_NO_WARNINGS" };
                for (x86_srcs) |s| mod.addCSourceFile(.{ .file = b.path(s), .flags = windows_flags });
            },
            // ARM64 Windows uses a different upstream source list (no
            // arm/cache.c, a windows-specific logical-sys-info init instead
            // of arm/linux/*) and isn't a target this repo verifies (no
            // realistic ARM64 Windows execution environment) — only wire
            // x86_64, same scope decision as tools/test-windows.sh.
            else => std.debug.panic("cpuinfo: only x86_64 wired up for Windows (got arch={s})", .{@tagName(t.cpu.arch)}),
        },
        else => std.debug.panic("cpuinfo: only macOS/Linux/Windows wired up (got os={s})", .{@tagName(t.os.tag)}),
    }

    return mod;
}
