const std = @import("std");

const UpdateChannel = enum { stable, dev };

const PgsoArtifact = enum {
    fx,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const pgso_artifact = b.option(
        PgsoArtifact,
        "pgso-artifact",
        "Emit ReleaseSafe LLVM bitcode for one PGO/PGSO artifact",
    );

    const git_commit = readGitCommit(b);
    const app_version = readAppVersion(b);
    const update_channel = b.option(UpdateChannel, "update-channel", "Build update channel (stable or dev)") orelse .stable;

    const build_options = b.addOptions();
    build_options.addOption([]const u8, "git_commit", git_commit);
    build_options.addOption([]const u8, "app_version", app_version);
    build_options.addOption([]const u8, "update_channel", @tagName(update_channel));

    const exe = b.addExecutable(.{
        .name = "fx",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .stack_check = false,
            .stack_protector = false,
            .omit_frame_pointer = true,
            .unwind_tables = .none,
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

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);

    const mcp_test_exports = b.createModule(.{
        .root_source_file = b.path("src/mcp_test_exports.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    mcp_test_exports.addImport("build_options", build_options.createModule());
    const mcp_dispatcher_e2e = b.addExecutable(.{
        .name = "mcp-stdio-dispatcher-driver",
        .root_module = b.createModule(.{
            .root_source_file = b.path(
                "tests/e2e/fixtures/mcp-stdio-dispatcher-driver.zig",
            ),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    mcp_dispatcher_e2e.root_module.addImport(
        "mcp_test_exports",
        mcp_test_exports,
    );
    const run_mcp_dispatcher_e2e = b.addRunArtifact(mcp_dispatcher_e2e);
    if (b.args) |args| run_mcp_dispatcher_e2e.addArgs(args);
    const mcp_dispatcher_e2e_step = b.step(
        "run-mcp-stdio-dispatcher-e2e",
        "Run the MCP stdio dispatcher E2E driver",
    );
    mcp_dispatcher_e2e_step.dependOn(&run_mcp_dispatcher_e2e.step);

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
