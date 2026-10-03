const std = @import("std");

const UpdateChannel = enum { stable, dev };

const WasmSurface = enum {
    none,
    core,
    term,
};

const PgsoArtifact = enum {
    fx,
};

const NapiSurface = enum {
    none,
    core,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const pgso_artifact = b.option(
        PgsoArtifact,
        "pgso-artifact",
        "Emit ReleaseSafe LLVM bitcode for one PGO/PGSO artifact",
    );
    const wasm_surface = b.option(
        WasmSurface,
        "wasm-surface",
        "Build a WASI WebAssembly surface for JavaScript hosts (core or term)",
    ) orelse .none;
    const napi_surface = b.option(
        NapiSurface,
        "napi-surface",
        "Build a Node-API addon surface (core)",
    ) orelse .none;

    const git_commit = readGitCommit(b);
    const app_version = readAppVersion(b);
    const update_channel = b.option(UpdateChannel, "update-channel", "Build update channel (stable or dev)") orelse .stable;

    const build_options = b.addOptions();
    build_options.addOption([]const u8, "git_commit", git_commit);
    build_options.addOption([]const u8, "app_version", app_version);
    build_options.addOption([]const u8, "update_channel", @tagName(update_channel));
    build_options.addOption(WasmSurface, "wasm_surface", .none);

    const exe = b.addExecutable(.{
        .name = "fx",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .stack_check = false,
            .stack_protector = false,
            .omit_frame_pointer = false,
            .unwind_tables = .sync,
            .error_tracing = false,
            .strip = optimize != .Debug,
        }),
    });
    exe.root_module.addImport("build_options", build_options.createModule());

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run fx");
    run_step.dependOn(&run_cmd.step);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);
    run_exe_tests.step.dependOn(b.getInstallStep());
    run_exe_tests.setEnvironmentVariable(
        "FX_TEST_PRODUCT_EXE",
        b.getInstallPath(.bin, "fx"),
    );
    if (b.option([]const u8, "test-filter", "Only run tests whose name contains this text")) |filter| {
        const arena = b.allocator.create(std.heap.ArenaAllocator) catch @panic("OOM");
        arena.* = std.heap.ArenaAllocator.init(b.allocator);
        const owned = arena.allocator().dupe([]const u8, &.{filter}) catch @panic("OOM");
        @field(exe_tests, "filters") = owned;
    }

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);

    if (wasm_surface != .none) {
        addWasmArtifact(b, wasm_surface, git_commit, app_version, update_channel);
    }
    if (napi_surface != .none) {
        addNapiArtifact(b, napi_surface, target, git_commit, app_version, update_channel);
    }

    const pgso_ir_step = b.step(
        "pgso-ir",
        "Emit selected ReleaseSafe LLVM bitcode for PGO/PGSO qualification",
    );
    if (pgso_artifact) |artifact| {
        const selected: *std.Build.Step.Compile = switch (artifact) {
            .fx => exe,
        };
        const output_name = switch (artifact) {
            .fx => "pgso/fx.bc",
        };
        const install_ir = b.addInstallFile(
            selected.getEmittedLlvmBc(),
            output_name,
        );
        pgso_ir_step.dependOn(&install_ir.step);
    } else {
        const missing_artifact = b.addFail(
            "pgso-ir requires -Dpgso-artifact",
        );
        pgso_ir_step.dependOn(&missing_artifact.step);
    }
}

fn addWasmArtifact(
    b: *std.Build,
    surface: WasmSurface,
    git_commit: []const u8,
    app_version: []const u8,
    update_channel: UpdateChannel,
) void {
    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .wasi,
    });
    const name = switch (surface) {
        .core => "fx-core",
        .term => "fx-term",
        .none => unreachable,
    };
    const description = switch (surface) {
        .core => "Build the headless fx WebAssembly artifact",
        .term => "Build the terminal fx WebAssembly artifact",
        .none => unreachable,
    };

    const wasm_options = b.addOptions();
    wasm_options.addOption([]const u8, "git_commit", git_commit);
    wasm_options.addOption([]const u8, "app_version", app_version);
    wasm_options.addOption([]const u8, "update_channel", @tagName(update_channel));
    wasm_options.addOption(WasmSurface, "wasm_surface", surface);

    const wasm_root = switch (surface) {
        .core => "src/wasm_core_main.zig",
        .term => "src/wasm_term_main.zig",
        .none => unreachable,
    };
    const wasm_exe = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(wasm_root),
            .target = wasm_target,
            .optimize = .ReleaseSmall,
            .single_threaded = true,
            .link_libc = true,
            .stack_check = false,
            .stack_protector = false,
            .omit_frame_pointer = true,
            .unwind_tables = .none,
            .error_tracing = false,
            .strip = true,
        }),
    });
    if (surface == .core) wasm_exe.stack_size = 1024 * 1024;
    wasm_exe.root_module.addImport("build_options", wasm_options.createModule());

    const install_wasm = b.addInstallArtifact(wasm_exe, .{});
    const wasm_step = b.step(name ++ "-wasm", description);
    wasm_step.dependOn(&install_wasm.step);
    b.getInstallStep().dependOn(&install_wasm.step);
}

fn addNapiArtifact(
    b: *std.Build,
    surface: NapiSurface,
    target: std.Build.ResolvedTarget,
    git_commit: []const u8,
    app_version: []const u8,
    update_channel: UpdateChannel,
) void {
    const napi_options = b.addOptions();
    napi_options.addOption([]const u8, "git_commit", git_commit);
    napi_options.addOption([]const u8, "app_version", app_version);
    napi_options.addOption([]const u8, "update_channel", @tagName(update_channel));
    napi_options.addOption(NapiSurface, "napi_surface", surface);

    const root = switch (surface) {
        .core => "src/napi_core_main.zig",
        .none => unreachable,
    };
    const lib = b.addLibrary(.{
        .name = "libfx",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = b.path(root),
            .target = target,
            .optimize = .ReleaseSafe,
            .link_libc = true,
            .strip = true,
        }),
    });
    lib.root_module.addImport("build_options", napi_options.createModule());
    const node_include = b.option(
        []const u8,
        "node-include-dir",
        "Directory containing node_api.h for the N-API addon",
    ) orelse discoverNodeIncludeDir(b);
    lib.root_module.addSystemIncludePath(.{ .cwd_relative = node_include });
    lib.linker_allow_shlib_undefined = true;

    const install = b.addInstallArtifact(lib, .{ .dest_sub_path = "libfx.node" });
    const step = b.step("libfx-napi", "Build the libfx Node-API core addon");
    step.dependOn(&install.step);
    b.getInstallStep().dependOn(&install.step);
}

fn discoverNodeIncludeDir(b: *std.Build) []const u8 {
    var code: u8 = 0;
    const out = b.runAllowFail(
        &.{ "node", "-p", "require('node:path').join(require('node:path').dirname(process.execPath), '..', 'include', 'node')" },
        &code,
        .ignore,
    ) catch std.process.fatal("Node.js is required to locate node_api.h; pass -Dnode-include-dir=<path>", .{});
    if (code != 0) std.process.fatal("could not locate node_api.h; pass -Dnode-include-dir=<path>", .{});
    const trimmed = std.mem.trim(u8, out, " \t\r\n");
    return b.allocator.dupe(u8, trimmed) catch std.process.fatal("could not allocate Node include path", .{});
}

fn readGitCommit(b: *std.Build) []const u8 {
    var code: u8 = 0;
    const out = b.runAllowFail(
        &.{ "git", "rev-parse", "--short=12", "HEAD" },
        &code,
        .ignore,
    ) catch return "unknown";
    if (code != 0) return "unknown";
    const trimmed = std.mem.trim(u8, out, " \t\r\n");
    return b.allocator.dupe(u8, trimmed) catch "unknown";
}

fn readAppVersion(b: *std.Build) []const u8 {
    const bytes = std.Io.Dir.cwd().readFileAlloc(b.graph.io, "src/main.zig", b.allocator, .limited(1024 * 1024)) catch
        @panic("could not read src/main.zig to resolve app version");
    defer b.allocator.free(bytes);

    const prefix = "pub const version = \"";
    const start = (std.mem.find(u8, bytes, prefix) orelse
        @panic("could not find pub const version in src/main.zig")) + prefix.len;
    const end_rel = std.mem.findScalar(u8, bytes[start..], '"') orelse
        @panic("could not parse pub const version in src/main.zig");
    return b.allocator.dupe(u8, bytes[start .. start + end_rel]) catch
        @panic("could not allocate app version");
}
