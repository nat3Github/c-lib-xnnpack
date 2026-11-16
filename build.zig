const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    var arena_state = std.heap.ArenaAllocator.init(b.allocator);
    defer arena_state.deinit();
    _ = addModule(b, arena_state.allocator(), target, optimize);
}

/// Every `XNN_ENABLE_*`/`XNNPACK_ENABLE_*` macro CMake unconditionally
/// defines; XNNPACK's headers have no `#ifndef` fallback for these.
fn xnnEnableFlags(arena: std.mem.Allocator, arch: std.Target.Cpu.Arch) []const []const u8 {
    var flags: std.ArrayList([]const u8) = .empty;
    const append = struct {
        fn f(list: *std.ArrayList([]const u8), a: std.mem.Allocator, s: []const u8) void {
            list.append(a, s) catch @panic("OOM");
        }
    }.f;

    append(&flags, arena, "-DXNN_ENABLE_CPUINFO=1");
    append(&flags, arena, "-DXNN_ENABLE_KLEIDIAI=0");

    const is_x86_64 = arch == .x86_64;
    const is_aarch64 = arch == .aarch64;

    for ([_][]const u8{
        "ARM_FP16_VECTOR", "ARM_FP16_SCALAR", "ARM_BF16", "ARM_DOTPROD", "ARM_I8MM", "ARM_SME", "ARM_SME2",
    }) |name| {
        append(&flags, arena, std.fmt.allocPrint(arena, "-DXNN_ENABLE_{s}={d}", .{ name, @intFromBool(is_aarch64) }) catch @panic("OOM"));
    }
    append(&flags, arena, "-DXNN_ENABLE_RISCV_VECTOR=0");
    append(&flags, arena, "-DXNN_ENABLE_RISCV_FP16_VECTOR=0");
    for ([_][]const u8{
        "SSE",            "SSE2",       "SSSE3",     "SSE41",       "AVX",        "F16C",
        "FMA3",           "AVX2",       "AVXVNNI",   "AVXVNNIINT8", "AVX256SKX",  "AVX256VNNI",
        "AVX256VNNIGFNI", "AVX512F",    "AVX512SKX", "AVX512VBMI",  "AVX512VNNI", "AVX512VNNIGFNI",
        "AVX512AMX",      "AVX512FP16",
    }) |name| {
        append(&flags, arena, std.fmt.allocPrint(arena, "-DXNN_ENABLE_{s}={d}", .{ name, @intFromBool(is_x86_64) }) catch @panic("OOM"));
    }
    append(&flags, arena, "-DXNN_ENABLE_AVX512BF16=0");
    append(&flags, arena, "-DXNN_ENABLE_VSX=0");
    append(&flags, arena, std.fmt.allocPrint(arena, "-DXNN_ENABLE_ASSEMBLY={d}", .{@intFromBool(is_x86_64 or is_aarch64)}) catch @panic("OOM"));
    append(&flags, arena, "-DXNN_ENABLE_SPARSE=0");
    append(&flags, arena, "-DXNN_ENABLE_HVX=0");
    append(&flags, arena, "-DXNN_ENABLE_RNDNU16=1");
    append(&flags, arena, "-DXNN_ENABLE_WASMRELAXEDSIMDFP16=0");
    append(&flags, arena, "-DXNN_ENABLE_WASM_REVECTORIZE=0");
    // Level 5 (Debug) writes raw, unbuffered `write()` calls straight to
    // stdout (xnnpack-fork/src/log.c) — every other level (Info/Warning/
    // Error/Fatal) goes to stderr. `zig build test` runs test binaries with
    // `--listen=-`, a structured message protocol also carried over stdout;
    // interleaved raw Debug writes silently corrupt that framing and hang
    // the build (parent and child both left waiting on bytes that'll never
    // arrive in the expected shape) without printing any test failure.
    // Level 4 (Info) still logs hardware-config/microkernel-selection notes,
    // just via stderr instead.
    append(&flags, arena, "-DXNN_LOG_LEVEL=4");
    append(&flags, arena, "-Drestrict=__restrict__");

    return flags.toOwnedSlice(arena) catch @panic("OOM");
}

const IsaTier = struct {
    name: []const u8,
    bzl_var: []const u8,
    cflags: []const []const u8 = &.{},
};

/// `-Xclang -target-feature -Xclang +<feature>` is needed instead of plain
/// `-m<feature>`/`-march=...`: `zig build`'s C-source compile path
/// re-appends its own baseline target args after per-file flags, clobbering
/// them, and `-march=...` gets misparsed as a `-mcpu` lookup by `zig cc`.
fn targetFeatureFlags(comptime features: []const []const u8) []const []const u8 {
    comptime var flags: []const []const u8 = &.{};
    inline for (features) |feature| {
        const signed = if (feature[0] == '-') feature else "+" ++ feature;
        flags = flags ++ &[_][]const u8{ "-Xclang", "-target-feature", "-Xclang", signed };
    }
    return flags;
}

const x86_64_tiers = [_]IsaTier{
    .{ .name = "sse", .bzl_var = "SSE", .cflags = targetFeatureFlags(&.{"sse"}) },
    .{ .name = "sse2", .bzl_var = "SSE2", .cflags = targetFeatureFlags(&.{"sse2"}) },
    .{ .name = "sse2fma", .bzl_var = "SSE2FMA", .cflags = targetFeatureFlags(&.{"sse2"}) },
    .{ .name = "ssse3", .bzl_var = "SSSE3", .cflags = targetFeatureFlags(&.{"ssse3"}) },
    .{ .name = "sse41", .bzl_var = "SSE41", .cflags = targetFeatureFlags(&.{"sse4.1"}) },
    .{ .name = "avx", .bzl_var = "AVX", .cflags = targetFeatureFlags(&.{"avx"}) },
    .{ .name = "f16c", .bzl_var = "F16C", .cflags = targetFeatureFlags(&.{"f16c"}) },
    .{ .name = "fma3", .bzl_var = "FMA3", .cflags = targetFeatureFlags(&.{ "f16c", "fma" }) },
    .{ .name = "avx2", .bzl_var = "AVX2", .cflags = targetFeatureFlags(&.{ "f16c", "fma", "avx2" }) },
    .{ .name = "avxvnni", .bzl_var = "AVXVNNI", .cflags = targetFeatureFlags(&.{ "f16c", "fma", "avx2", "avxvnni", "gfni" }) },
    .{ .name = "avxvnniint8", .bzl_var = "AVXVNNIINT8", .cflags = targetFeatureFlags(&.{ "f16c", "fma", "avx2", "avxvnniint8", "gfni" }) },
    .{ .name = "avx256skx", .bzl_var = "AVX256SKX", .cflags = targetFeatureFlags(&.{ "f16c", "fma", "avx512f", "avx512cd", "avx512bw", "avx512dq", "avx512vl" }) },
    .{ .name = "avx256vnni", .bzl_var = "AVX256VNNI", .cflags = targetFeatureFlags(&.{ "f16c", "fma", "avx512f", "avx512cd", "avx512bw", "avx512dq", "avx512vl", "avx512vnni" }) },
    .{ .name = "avx256vnnigfni", .bzl_var = "AVX256VNNIGFNI", .cflags = targetFeatureFlags(&.{ "f16c", "fma", "avx512f", "avx512cd", "avx512bw", "avx512dq", "avx512vl", "avx512vnni", "gfni" }) },
    .{ .name = "avx512f", .bzl_var = "AVX512F", .cflags = targetFeatureFlags(&.{ "avx512f", "evex512" }) },
    .{ .name = "avx512skx", .bzl_var = "AVX512SKX", .cflags = targetFeatureFlags(&.{ "f16c", "fma", "avx512f", "avx512cd", "avx512bw", "avx512dq", "avx512vl", "evex512" }) },
    .{ .name = "avx512vbmi", .bzl_var = "AVX512VBMI", .cflags = targetFeatureFlags(&.{ "f16c", "fma", "avx512f", "avx512cd", "avx512bw", "avx512dq", "avx512vl", "avx512vbmi", "evex512" }) },
    .{ .name = "avx512vnni", .bzl_var = "AVX512VNNI", .cflags = targetFeatureFlags(&.{ "f16c", "fma", "avx512f", "avx512cd", "avx512bw", "avx512dq", "avx512vl", "avx512vnni", "evex512" }) },
    .{ .name = "avx512vnnigfni", .bzl_var = "AVX512VNNIGFNI", .cflags = targetFeatureFlags(&.{ "f16c", "fma", "avx512f", "avx512cd", "avx512bw", "avx512dq", "avx512vl", "avx512vnni", "gfni", "evex512" }) },
    .{ .name = "avx512fp16", .bzl_var = "AVX512FP16", .cflags = targetFeatureFlags(&.{ "f16c", "fma", "avx512f", "avx512cd", "avx512bw", "avx512dq", "avx512vl", "avx512vnni", "gfni", "avx512fp16", "evex512" }) },
    .{ .name = "avx512amx", .bzl_var = "AVX512AMX", .cflags = targetFeatureFlags(&.{ "f16c", "fma", "avx512f", "avx512cd", "avx512bw", "avx512dq", "avx512vl", "avx512vnni", "gfni", "amx-tile", "amx-int8", "evex512" }) },
    .{ .name = "amd64", .bzl_var = "AMD64_ASM" },
};

const aarch64_tiers = [_]IsaTier{
    .{ .name = "neon", .bzl_var = "NEON" },
    .{ .name = "neon_aarch64", .bzl_var = "NEON_AARCH64" },
    .{ .name = "neonfma", .bzl_var = "NEONFMA" },
    .{ .name = "neonfma_aarch64", .bzl_var = "NEONFMA_AARCH64" },
    .{ .name = "neonv8", .bzl_var = "NEONV8" },
    .{ .name = "neonfp16", .bzl_var = "NEONFP16", .cflags = targetFeatureFlags(&.{"fullfp16"}) },
    .{ .name = "fp16arith", .bzl_var = "FP16ARITH", .cflags = targetFeatureFlags(&.{"fullfp16"}) },
    .{ .name = "neonfp16arith", .bzl_var = "NEONFP16ARITH", .cflags = targetFeatureFlags(&.{"fullfp16"}) },
    .{ .name = "neonfp16arith_aarch64", .bzl_var = "NEONFP16ARITH_AARCH64", .cflags = targetFeatureFlags(&.{"fullfp16"}) },
    .{ .name = "neondotfp16arith", .bzl_var = "NEONDOTFP16ARITH", .cflags = targetFeatureFlags(&.{ "dotprod", "fullfp16" }) },
    .{ .name = "neonbf16", .bzl_var = "NEONBF16", .cflags = targetFeatureFlags(&.{"bf16"}) },
    .{ .name = "neondot", .bzl_var = "NEONDOT", .cflags = targetFeatureFlags(&.{"dotprod"}) },
    .{ .name = "neondot_aarch64", .bzl_var = "NEONDOT_AARCH64", .cflags = targetFeatureFlags(&.{"dotprod"}) },
    .{ .name = "neoni8mm", .bzl_var = "NEONI8MM", .cflags = targetFeatureFlags(&.{ "i8mm", "fullfp16" }) },
    .{ .name = "neoni8mmbf16", .bzl_var = "NEONI8MMBF16", .cflags = targetFeatureFlags(&.{ "i8mm", "fullfp16", "bf16" }) },
    .{ .name = "neonsme", .bzl_var = "NEONSME", .cflags = targetFeatureFlags(&.{ "sve", "sve2" }) },
    .{ .name = "neonsme2", .bzl_var = "NEONSME2", .cflags = targetFeatureFlags(&.{ "sve", "sve2" }) },
};

/// Hand-written `.S` tier. `-Xclang` doesn't reach the separate `cc1as`
/// invocation, and since zig 0.17 `-Wa,-march=...` is overridden by zig's own
/// target features, so these files get their own module whose target adds
/// fullfp16 + dotprod.
const aarch64_asm_tier: IsaTier = .{ .name = "aarch64", .bzl_var = "AARCH64_ASM" };

/// Reads `gen/<tier.name>_microkernels.bzl`'s checked-in, auto-generated
/// `PROD_<tier.bzl_var>_MICROKERNEL_SRCS` list.
fn readTierSrcs(b: *std.Build, arena: std.mem.Allocator, tier: IsaTier) []const []const u8 {
    const io = b.graph.io;
    const bzl_path = std.fmt.allocPrint(arena, "gen/{s}_microkernels.bzl", .{tier.name}) catch @panic("OOM");
    const bzl_file = b.root.join(arena, bzl_path) catch @panic("OOM");
    const content = bzl_file.root_dir.handle.readFileAlloc(io, bzl_file.sub_path, arena, .unlimited) catch |err| {
        std.debug.panic("failed to read {s}: {s}", .{ bzl_path, @errorName(err) });
    };

    const marker = std.fmt.allocPrint(arena, "PROD_{s}_MICROKERNEL_SRCS = [", .{tier.bzl_var}) catch @panic("OOM");
    const start = (std.mem.indexOf(u8, content, marker) orelse
        std.debug.panic("{s}: couldn't find `{s}`", .{ bzl_path, marker })) + marker.len;
    const end = start + (std.mem.indexOfScalar(u8, content[start..], ']') orelse
        std.debug.panic("{s}: unterminated `{s}` array", .{ bzl_path, marker }));
    const body = content[start..end];

    var srcs: std.ArrayList([]const u8) = .empty;
    var pos: usize = 0;
    while (std.mem.indexOfScalarPos(u8, body, pos, '"')) |q1| {
        const q2 = std.mem.indexOfScalarPos(u8, body, q1 + 1, '"') orelse break;
        srcs.append(arena, body[q1 + 1 .. q2]) catch @panic("OOM");
        pos = q2 + 1;
    }
    return srcs.toOwnedSlice(arena) catch @panic("OOM");
}

const config_srcs = &[_][]const u8{
    "src/configs/argmaxpool-config.c",         "src/configs/avgpool-config.c",
    "src/configs/binary-elementwise-config.c", "src/configs/cmul-config.c",
    "src/configs/conv-hwc2chw-config.c",       "src/configs/dwconv-config.c",
    "src/configs/dwconv2d-chw-config.c",       "src/configs/gemm-config.c",
    "src/configs/ibilinear-chw-config.c",      "src/configs/ibilinear-config.c",
    "src/configs/lut32norm-config.c",          "src/configs/maxpool-config.c",
    "src/configs/pack-lh-config.c",            "src/configs/raddstoreexpminusmax-config.c",
    "src/configs/reduce-config.c",             "src/configs/spmm-config.c",
    "src/configs/transpose-config.c",          "src/configs/unary-elementwise-config.c",
    "src/configs/unpool-config.c",             "src/configs/vmulcaddc-config.c",
    "src/configs/xx-fill-config.c",            "src/configs/xx-pad-config.c",
    "src/configs/x8-lut-config.c",
};

const logging_srcs = &[_][]const u8{
    "src/enums/allocation-type.c",  "src/enums/datatype-strings.c",
    "src/enums/microkernel-type.c", "src/enums/node-type.c",
    "src/enums/operator-type.c",
};

const runtime_support_srcs = &[_][]const u8{
    "src/sanitizers.c",                  "src/indirection.c",
    "src/microparams-init.c",            "src/normalization.c",
    "src/cache.c",                       "src/datatype.c",
    "src/operator-delete.c",             "src/operators/fingerprint_id.c",
    "src/operators/fingerprint_cache.c", "src/xnnpack/fingerprint_check.c",
    "src/memory.c",                      "src/microkernel-utils.c",
    "src/mutex.c",                       "src/operator-utils.c",
};

const operator_srcs = &[_][]const u8{
    "src/operator-run.c",
    "src/operators/argmax-pooling-nhwc.c",
    "src/operators/average-pooling-nhwc.c",
    "src/operators/batch-matrix-multiply-nc.c",
    "src/operators/binary-elementwise-nd.c",
    "src/operators/constant-pad-nd.c",
    "src/operators/convolution-nchw.c",
    "src/operators/convolution-nhwc.c",
    "src/operators/deconvolution-nhwc.c",
    "src/operators/dynamic-fully-connected-nc.c",
    "src/operators/fully-connected-nc.c",
    "src/operators/max-pooling-nhwc.c",
    "src/operators/pack-lh.c",
    "src/operators/reduce-nd.c",
    "src/operators/resize-bilinear-nchw.c",
    "src/operators/resize-bilinear-nhwc.c",
    "src/operators/rope-nthc.c",
    "src/operators/slice-nd.c",
    "src/operators/softmax-nc.c",
    "src/operators/transpose-nd.c",
    "src/operators/unary-elementwise-nc.c",
    "src/operators/unpooling-nhwc.c",
};

const subgraph_srcs = &[_][]const u8{
    "src/memory-planner.c",                  "src/runtime.c",                            "src/subgraph.c",
    "src/subgraph/argmax-pooling-2d.c",      "src/subgraph/average-pooling-2d.c",        "src/subgraph/batch-matrix-multiply.c",
    "src/subgraph/binary.c",                 "src/subgraph/concatenate.c",               "src/subgraph/convolution-2d.c",
    "src/subgraph/copy.c",                   "src/subgraph/deconvolution-2d.c",          "src/subgraph/deprecated.c",
    "src/subgraph/depth-to-space-2d.c",      "src/subgraph/depthwise-convolution-2d.c",  "src/subgraph/even-split.c",
    "src/subgraph/fully-connected-sparse.c", "src/subgraph/fully-connected.c",           "src/subgraph/max-pooling-2d.c",
    "src/subgraph/pack-lh.c",                "src/subgraph/reshape-helpers.c",           "src/subgraph/rope.c",
    "src/subgraph/softmax.c",                "src/subgraph/space-to-depth-2d.c",         "src/subgraph/static-constant-pad.c",
    "src/subgraph/static-reduce.c",          "src/subgraph/static-resize-bilinear-2d.c", "src/subgraph/static-slice.c",
    "src/subgraph/static-transpose.c",       "src/subgraph/subgraph-utils.c",            "src/subgraph/unary.c",
    "src/subgraph/unpooling-2d.c",           "src/subgraph/validation.c",                "src/tensor.c",
};

/// Only C++ XNNPACK needs at the operator/subgraph layer (reference
/// pack/unary/binary fallbacks for shapes/dtypes no fast microkernel covers).
const cxx_srcs = &[_][]const u8{
    "src/pack-lh.cc",                       "src/reference/packing.cc",
    "src/subgraph/rewrites/cvt_to_fp32.cc", "src/reference/unary-elementwise.cc",
    "src/reference/binary-elementwise.cc",
};

fn addTierSources(b: *std.Build, arena: std.mem.Allocator, mod: *std.Build.Module, tier: IsaTier, enable_flags: []const []const u8) void {
    const srcs = readTierSrcs(b, arena, tier);
    if (srcs.len == 0) return;
    const flags = std.mem.concat(arena, []const u8, &.{ enable_flags, tier.cflags }) catch @panic("OOM");
    for (srcs) |s| mod.addCSourceFile(.{ .file = b.path(s), .flags = flags });
}

pub fn addModule(
    b: *std.Build,
    arena: std.mem.Allocator,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    const cpuinfo_dep = b.dependency("cpuinfo", .{ .target = target, .optimize = optimize });
    const pthreadpool_dep = b.dependency("pthreadpool", .{ .target = target, .optimize = optimize });

    const mod = b.addModule("xnnpack", .{
        .root_source_file = null,
        .target = target,
        .optimize = optimize,
        .link_libcpp = true,
    });
    mod.addImport("cpuinfo", cpuinfo_dep.module("cpuinfo"));
    mod.addImport("pthreadpool", pthreadpool_dep.module("pthreadpool"));
    // addImport only wires up Zig-level `@import`, it doesn't propagate a
    // dependency's C include paths — cpuinfo.h/pthreadpool.h still need to be
    // added explicitly here.
    mod.addIncludePath(cpuinfo_dep.path("include"));
    mod.addIncludePath(pthreadpool_dep.path("include"));

    // XNNPACK's sources #include "include/xnnpack.h" / "src/xnnpack/common.h"
    // relative to this repo root, so the root itself (not just include/) must
    // be on the path. FP16/FXdiv are header-only deps, not worth their own
    // package — just add their include dirs directly.
    mod.addIncludePath(b.path("."));
    mod.addIncludePath(b.dependency("fp16", .{}).path("include"));
    mod.addIncludePath(b.dependency("fxdiv", .{}).path("include"));

    const t = target.result;
    const enable_flags = xnnEnableFlags(arena, t.cpu.arch);

    const base_srcs = &[_][]const u8{
        "src/init.c",                       "src/allocator.c",                    "src/log.c",                        "src/params.c",
        "src/configs/hardware-config.c",    "src/xnnpack/init-once.c",            "src/tables/exp2-k-over-64.c",      "src/tables/exp2-k-over-2048.c",
        "src/tables/exp2minus-k-over-4.c",  "src/tables/exp2minus-k-over-8.c",    "src/tables/exp2minus-k-over-16.c", "src/tables/exp2minus-k-over-32.c",
        "src/tables/exp2minus-k-over-64.c", "src/tables/exp2minus-k-over-2048.c", "src/tables/vlog.c",
        // NON_PROD scalar reference kernel the PoC calls directly.
                       "src/f32-vbinary/gen/f32-vadd-scalar-u4.c",
    };
    for (base_srcs) |s| mod.addCSourceFile(.{ .file = b.path(s), .flags = enable_flags });
    for (config_srcs) |s| mod.addCSourceFile(.{ .file = b.path(s), .flags = enable_flags });
    for (logging_srcs) |s| mod.addCSourceFile(.{ .file = b.path(s), .flags = enable_flags });
    for (runtime_support_srcs) |s| mod.addCSourceFile(.{ .file = b.path(s), .flags = enable_flags });
    for (operator_srcs) |s| mod.addCSourceFile(.{ .file = b.path(s), .flags = enable_flags });
    for (subgraph_srcs) |s| mod.addCSourceFile(.{ .file = b.path(s), .flags = enable_flags });

    // CMakeLists.txt sets CMAKE_CXX_STANDARD 17 for the whole project.
    const xnnpack_cxx_flags = std.mem.concat(arena, []const u8, &.{ &[_][]const u8{"-std=c++17"}, enable_flags }) catch @panic("OOM");
    for (cxx_srcs) |s| mod.addCSourceFile(.{ .file = b.path(s), .flags = xnnpack_cxx_flags });

    addTierSources(b, arena, mod, .{ .name = "scalar", .bzl_var = "SCALAR" }, enable_flags);

    const tiers: []const IsaTier = switch (t.cpu.arch) {
        .x86_64 => &x86_64_tiers,
        .aarch64 => &aarch64_tiers,
        else => std.debug.panic("xnnpack: ISA tiers only cover x86_64/aarch64 (got arch={s})", .{@tagName(t.cpu.arch)}),
    };
    for (tiers) |tier| addTierSources(b, arena, mod, tier, enable_flags);

    if (t.cpu.arch == .aarch64) {
        var asm_query = target.query;
        asm_query.cpu_features_add.addFeatureSet(std.Target.aarch64.featureSet(&.{ .fullfp16, .dotprod }));
        const asm_mod = b.createModule(.{
            .target = b.resolveTargetQuery(asm_query),
            .optimize = optimize,
        });
        asm_mod.addIncludePath(b.path("."));
        addTierSources(b, arena, asm_mod, aarch64_asm_tier, enable_flags);
        mod.addImport("xnnpack_asm", asm_mod);
    }

    return mod;
}
