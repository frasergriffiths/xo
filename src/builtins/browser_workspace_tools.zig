const std = @import("std");
const builtin_tools = @import("tools.zig");
const browser_shell = @import("../tools/shell/browser_shell.zig");
const tool_set = @import("../core/tooling/tool_set.zig");
const tool_dispatch = @import("../core/tooling/tool_dispatch.zig");

const shell_description =
    "Run one completion-only command inside the browser workspace with action=run. This clean root-fixed shell is the workspace interface. Native host paths, git, Node, npm, Python, managed running handles, TTY input, and operating-system access are unavailable.";

const shell = buildShellSpec();

fn buildShellSpec() tool_dispatch.Tool {
    var spec = builtin_tools.shell;
    spec.description = shell_description;
    spec.model_schema = .{
        .name = "shell",
        .description = shell_description,
        .input_schema = .{
            .properties = &.{
                .{ .name = "action", .json_type = .string, .shape = &.{ .enum_values = &.{"run"} } },
                .{
                    .name = "command",
                    .json_type = .string,
                    .bounds = &.{ .max_length = 64 * 1024 },
                    .description = "Foreground command to run in the browser workspace.",
                },
            },
            .required = &.{ "action", "command" },
            .additional_properties = false,
        },
    };
    spec.decode = browser_shell.decode;
    spec.validate = null;
    spec.call = browser_shell.call;
    spec.reads_only_fn = browser_shell.readsOnly;
    spec.irreversible_fn = browser_shell.isIrreversible;
    spec.executor_kind = .run_command;
    spec.captured_command_action = null;
    spec.captured_command_fn = null;
    spec.process_local_fn = null;
    spec.permission_target_kind = .command_cwd;
    spec.captured_command_host = .workspace_clean;
    return spec;
}

const all = [_]tool_dispatch.Tool{shell};
pub const registry = tool_dispatch.Registry{ .tools = all[0..] };
const advertisement_order = [_][]const u8{"shell"};
const advertisement_set = tool_set.ToolSet{
    .registry = registry,
    .order = advertisement_order[0..],
    .read_only_tool_names = &.{},
};

pub fn selectToolSet(comptime native_tools: bool, workspace_available: bool) tool_set.ToolSet {
    if (comptime native_tools) return builtin_tools.advertisement_set;
    return if (workspace_available) advertisement_set else tool_set.empty;
}

fn expectDecodeFailure(arguments_json: []const u8) !void {
    const decoded = try registry.tools[0].decode(.{
        .allocator = std.testing.allocator,
    }, arguments_json);
    switch (decoded) {
        .input => |input| {
            input.deinit(std.testing.allocator);
            return error.TestExpectedDecodeFailure;
        },
        .failure => |body| std.testing.allocator.free(body),
    }
}
