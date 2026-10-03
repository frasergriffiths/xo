const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("../shared/io.zig");
const app_lifecycle = @import("../app/app_lifecycle.zig");
const auth_runtime = @import("../auth/auth_runtime.zig");
const one_shot = @import("one_shot.zig");
const cli_replay = @import("cli_replay.zig");
const command_specs = @import("../slash_commands/command_specs.zig");
const collections = @import("../shared/collections.zig");
const config_runtime = @import("../config/config_runtime.zig");
const credentials = @import("../auth/credentials.zig");
const model_provider = @import("../config/model_provider.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const doctor_runtime = @import("doctor_runtime.zig");
const gateway_provider = @import("../gateway/gateway_provider.zig");
const model_catalog = @import("../gateway/model_catalog.zig");
const provider_set = @import("../gateway/provider_set.zig");
const execution_process_provider = @import("../execution/process_provider.zig");
const github_publish = @import("../github/github_publish.zig");
const github_workflows = @import("../github/github_workflows.zig");
const host = @import("../hosts/host.zig");
const provider_catalog = @import("../auth/provider_catalog.zig");
const secret = @import("../auth/secret.zig");
const output_contracts = @import("../output/output_contracts.zig");
const prompt_policy = @import("../config/prompt_policy.zig");
const session_store = @import("../session/session_store.zig");
const subagent_resume_admission = @import("../subagent/resume_admission.zig");
const usage_report = @import("../session/usage_report.zig");
const skill_contract = @import("../skills/skill_contract.zig");
const types = @import("../shared/types.zig");
const update_target = @import("../upgrade/update_target.zig");
const test_openrouter = if (builtin.is_test)
    @import("../../gateway/openrouter_test_fixtures.zig")
else
    struct {};
const context_contract = @import("../workspace/context_contract.zig");
const mode_registry = @import("../modes/mode_registry.zig");
const text_utils = @import("../shared/text_utils.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const tool_set_contract = @import("../tooling/tool_set.zig");
const workspace_access = @import("../workspace/workspace_access.zig");
const workspace_commands = @import("../workspace/workspace_commands.zig");
const usage_cli_runtime = @import("usage_cli_runtime.zig");

const Allocator = std.mem.Allocator;
const CommandCatalog = command_specs.TopLevelRegistry;
const TopLevelKind = command_specs.TopLevelKind;

pub const Command = union(enum) {
    interactive,
    help,
    pr: []const [:0]const u8,
    issue: []const [:0]const u8,
    setup: []const [:0]const u8,
    status: []const [:0]const u8,
    models: []const [:0]const u8,
    provider: []const [:0]const u8,
    doctor: []const [:0]const u8,
    session: []const [:0]const u8,
    sessions: []const [:0]const u8,
    resume_session: ResumeInvocation,
    usage: []const [:0]const u8,
    upgrade: []const [:0]const u8,
    replay: []const [:0]const u8,
    workspace: []const [:0]const u8,
    unknown: []const u8,
};

const ResumeInvocation = struct {
    args: []const [:0]const u8,
    top_level_alias: bool = false,
};

const resume_id_alias_prefix = "--resume-";
pub const upgrade_relaunch_arg = "--upgrade-relaunch";

pub const UpgradeRelaunch = struct {
    previous_revision: ?[]u8 = null,

    pub fn deinit(self: *UpgradeRelaunch, alloc: Allocator) void {
        if (self.previous_revision) |revision| alloc.free(revision);
        self.* = undefined;
    }
};

// The one resume alias that asks which session to open. Every other spelling
// names its target, so it resumes without a prompt.
const resume_picker_alias = "-r";

pub const ResumeTarget = union(enum) {
    remembered,
    pick,
    last,
    id: []u8,

    pub fn deinit(self: *ResumeTarget, alloc: Allocator) void {
        switch (self.*) {
            .remembered, .pick, .last => {},
            .id => |value| alloc.free(value),
        }
        self.* = undefined;
    }
};

pub const LaunchModifiers = struct {
    context_limit_overrides: []config_runtime.context_limits.Override = &.{},
    additional_directories: [][]u8 = &.{},
    saved_directories_suppressed: bool = false,
    provider_override: ?model_provider.ProviderId = null,
    model_override: ?[]u8 = null,
    effort_override: ?types.ReasoningEffort = null,
    fast_override: ?bool = null,
    provider_order_override: ?[][]const u8 = null,
    provider_strict_override: ?bool = null,

    pub fn deinit(self: *LaunchModifiers, alloc: Allocator) void {
        if (self.context_limit_overrides.len > 0) alloc.free(self.context_limit_overrides);
        for (self.additional_directories) |path| alloc.free(path);
        if (self.additional_directories.len > 0) alloc.free(self.additional_directories);
        if (self.model_override) |model| alloc.free(model);
        if (self.provider_order_override) |order| freeProviderOrderOverride(alloc, order);
        self.* = .{};
    }

    pub fn hasWorkspaceModifiers(self: LaunchModifiers) bool {
        return self.additional_directories.len > 0 or self.saved_directories_suppressed;
    }

    pub fn hasModelOverrides(self: LaunchModifiers) bool {
        return self.provider_override != null or self.model_override != null or
            self.effort_override != null or self.fast_override != null or
            self.provider_order_override != null or self.provider_strict_override != null;
    }
};

fn freeProviderOrderOverride(alloc: Allocator, order: []const []const u8) void {
    for (order) |slug| alloc.free(@constCast(slug));
    if (order.len > 0) alloc.free(order);
}

/// Parses one `--provider-order` value, replacing any earlier occurrence.
/// The returned slice is owned by `alloc`.
fn parseProviderOrderFlag(alloc: Allocator, raw: []const u8, previous: ?[][]const u8) ![][]const u8 {
    const parsed: [][]const u8 = switch (config_runtime.parseProviderOrderList(alloc, raw)) {
        .ok => |maybe| maybe orelse return error.InvalidProviderOrderValue,
        .invalid => return error.InvalidProviderOrderValue,
    };
    if (previous) |old| freeProviderOrderOverride(alloc, old);
    return parsed;
}

pub const InteractiveLaunch = struct {
    requested_resume: ?ResumeTarget = null,
    upgrade_relaunch: ?UpgradeRelaunch = null,
    modifiers: LaunchModifiers = .{},

    pub fn deinit(self: *InteractiveLaunch, alloc: Allocator) void {
        if (self.requested_resume) |*target| target.deinit(alloc);
        if (self.upgrade_relaunch) |*relaunch| relaunch.deinit(alloc);
        self.modifiers.deinit(alloc);
        self.* = undefined;
    }
};

pub const RunResult = union(enum) {
    interactive: InteractiveLaunch,
    handled_success,
    handled_failure,
    handled_exit: u8,
};

const version_usage = "usage: fx --version\n";

pub const Config = struct {
    version: []const u8 = "",
    revision: []const u8 = "",
    build_channel: update_target.Channel = .stable,
    auth_mode: credentials.AuthMode = .local,
    command_catalog: CommandCatalog,
    default_model: []const u8,
    default_agent_step_limit: usize,
    models_path: []const u8,
    gateway_retry_count: usize,
    gateway_chat_url: []const u8,
    gateway_provider: gateway_provider.Provider,
    provider_set: provider_set.Set,
    process_provider: execution_process_provider.Provider = execution_process_provider.unavailable_provider,
    url_opener: host.UrlOpener,
    secret_store: host.SecretStore,
    prompt_policy: prompt_policy.Policy,
    skill_root_policy: skill_contract.RootPolicy,
    ignored_list_entries: []const []const u8,
    max_list_entries: usize,
    max_read_file_bytes: usize,
    max_read_file_lines: usize,
    max_read_file_line_len: usize,
    max_command_output_bytes: usize,
    max_tool_result_bytes: usize,
    max_history_turns: usize,
    context_registry: context_contract.Registry,
    mode_registry: mode_registry.Registry,
    tool_set: tool_set_contract.ToolSet,
};

const LocalSurfaceOptions = struct {
    format: output_contracts.OutputFormat = .text,
};

fn selectCatalogModel(
    entries: []const model_catalog.ModelCatalogEntry,
    saved: ?[]const u8,
) ?[]const u8 {
    if (saved) |candidate| {
        for (entries) |entry| {
            if (std.mem.eql(u8, entry.id, candidate)) return entry.id;
        }
    }
    return if (entries.len > 0) entries[0].id else null;
}

const UpgradeOptions = struct {
    format: output_contracts.OutputFormat = .text,
    channel: ?update_target.Channel = null,
};

const SessionListOptions = struct {
    format: output_contracts.OutputFormat = .text,
    scope: session_store.SessionListScope = .current_workspace,
    limit: usize = session_store.session_list_default_limit,
    continuation: ?session_store.ResumableSessionContinuation = null,
};

const UsageOptions = struct {
    format: output_contracts.OutputFormat = .text,
    scope: usage_report.Scope = .days_30,
};

const WorkspaceOptions = struct {
    format: output_contracts.OutputFormat = .text,
    action: ?workspace_commands.Action = null,
};

const SessionDetailTarget = union(enum) {
    last,
    id: []u8,

    fn deinit(self: *SessionDetailTarget, alloc: Allocator) void {
        switch (self.*) {
            .last => {},
            .id => |value| alloc.free(value),
        }
        self.* = undefined;
    }
};

const SessionDetailOptions = struct {
    format: output_contracts.OutputFormat = .text,
    target: ?SessionDetailTarget = null,

    fn deinit(self: *SessionDetailOptions, alloc: Allocator) void {
        if (self.target) |*target| target.deinit(alloc);
        self.* = undefined;
    }
};

const SessionMigrationOptions = struct {
    format: output_contracts.OutputFormat = .text,
    session_id: []u8,
    allow_large: bool = false,

    fn deinit(self: *SessionMigrationOptions, alloc: Allocator) void {
        alloc.free(self.session_id);
        self.* = undefined;
    }
};

const SessionRecoveryOptions = struct {
    format: output_contracts.OutputFormat = .text,
    session_id: []u8,

    fn deinit(self: *SessionRecoveryOptions, alloc: Allocator) void {
        alloc.free(self.session_id);
        self.* = undefined;
    }
};

const WorkflowOptions = struct {
    auto_permission: bool,
    create: bool,
    context: []u8,

    fn deinit(self: WorkflowOptions, alloc: Allocator) void {
        alloc.free(self.context);
    }
};

const WriteFn = *const fn (?*anyopaque, []const u8) anyerror!void;
const LoadStartupStateFn = *const fn (Allocator, host.SecretStore, []const u8, usize) anyerror!app_lifecycle.StartupState;
const LoadStartupStateWithoutCredentialsFn = *const fn (Allocator, []const u8, usize) anyerror!app_lifecycle.StartupState;
const LoadStartupStatusFn = *const fn (Allocator, host.SecretStore, []const u8, usize) anyerror!app_lifecycle.StartupStatus;
const LoadStartupStateWithAuthModeFn = *const fn (Allocator, host.SecretStore, []const u8, usize, credentials.AuthMode) anyerror!app_lifecycle.StartupState;
const LoadCatalogStartupStateWithAuthModeFn = *const fn (Allocator, host.SecretStore, []const u8, usize, credentials.AuthMode, ?model_provider.ProviderId, ?[]const u8) anyerror!app_lifecycle.StartupState;
const LoadStartupStatusWithAuthModeFn = *const fn (Allocator, host.SecretStore, []const u8, usize, credentials.AuthMode) anyerror!app_lifecycle.StartupStatus;
const GetenvFn = *const fn (?*anyopaque, []const u8) ?[]const u8;
const EnvironMapFn = *const fn (?*anyopaque) ?*const std.process.Environ.Map;
const ReadMaskedKeyFn = *const fn (?*anyopaque, Allocator, WriteFn, ?*anyopaque) anyerror![]u8;
const SetupTerminalAvailableFn = *const fn (?*anyopaque) bool;
const RunDeps = struct {
    stdout_ctx: ?*anyopaque = null,
    stderr_ctx: ?*anyopaque = null,
    env_ctx: ?*anyopaque = null,
    setup_ctx: ?*anyopaque = null,
    write_stdout: WriteFn = writeRealStdout,
    write_stderr: WriteFn = writeRealStderr,
    load_startup_state: LoadStartupStateFn = app_lifecycle.loadStartupState,
    load_startup_state_without_credentials: LoadStartupStateWithoutCredentialsFn = app_lifecycle.loadStartupStateWithoutCredentials,
    load_startup_status: LoadStartupStatusFn = app_lifecycle.loadStartupStatus,
    load_startup_state_with_auth_mode: LoadStartupStateWithAuthModeFn = app_lifecycle.loadStartupStateWithAuthMode,
    load_catalog_startup_state_with_auth_mode: LoadCatalogStartupStateWithAuthModeFn = app_lifecycle.loadCatalogStartupStateWithAuthMode,
    load_startup_status_with_auth_mode: LoadStartupStatusWithAuthModeFn = app_lifecycle.loadStartupStatusWithAuthMode,
    getenv: GetenvFn = getenvDefault,
    environ_map: EnvironMapFn = environMapDefault,
    read_masked_key: ReadMaskedKeyFn = readMaskedKeyDefault,
    setup_terminal_available: SetupTerminalAvailableFn = setupTerminalAvailableDefault,
};

const GlobalLaunchArgs = struct {
    remaining: []const [:0]const u8,
    modifiers: LaunchModifiers = .{},

    fn deinit(self: *GlobalLaunchArgs, alloc: Allocator) void {
        self.modifiers.deinit(alloc);
        self.* = undefined;
    }

    fn takeModifiers(self: *GlobalLaunchArgs) LaunchModifiers {
        const result = self.modifiers;
        self.modifiers = .{};
        return result;
    }
};

fn parseGlobalLaunchArgs(
    alloc: Allocator,
    args: []const [:0]const u8,
) !GlobalLaunchArgs {
    var overrides: std.ArrayList(config_runtime.context_limits.Override) = .empty;
    errdefer overrides.deinit(alloc);
    var directories: std.ArrayList([]u8) = .empty;
    errdefer {
        for (directories.items) |path| alloc.free(path);
        directories.deinit(alloc);
    }
    var suppress_saved = false;
    var provider_override: ?model_provider.ProviderId = null;
    var model_override: ?[]u8 = null;
    errdefer if (model_override) |model| alloc.free(model);
    var effort_override: ?types.ReasoningEffort = null;
    var fast_override: ?bool = null;
    var provider_order_override: ?[][]const u8 = null;
    errdefer if (provider_order_override) |order| freeProviderOrderOverride(alloc, order);
    var provider_strict_override: ?bool = null;

    var index: usize = 0;
    while (index < args.len) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--context-limit")) {
            index += 1;
            if (index >= args.len) return error.MissingContextLimitValue;
            try overrides.append(alloc, try config_runtime.context_limits.parseOverride(args[index]));
        } else if (std.mem.startsWith(u8, arg, "--context-limit=")) {
            try overrides.append(alloc, try config_runtime.context_limits.parseOverride(arg["--context-limit=".len..]));
        } else if (std.mem.eql(u8, arg, "--add-dir")) {
            index += 1;
            if (index >= args.len or args[index].len == 0) return error.MissingAddDirectoryValue;
            try directories.append(alloc, try alloc.dupe(u8, args[index]));
        } else if (std.mem.startsWith(u8, arg, "--add-dir=")) {
            const value = arg["--add-dir=".len..];
            if (value.len == 0) return error.MissingAddDirectoryValue;
            try directories.append(alloc, try alloc.dupe(u8, value));
        } else if (std.mem.eql(u8, arg, "--no-additional-dirs")) {
            if (suppress_saved) return error.DuplicateAdditionalDirectorySuppression;
            suppress_saved = true;
        } else if (std.mem.eql(u8, arg, "--provider")) {
            index += 1;
            if (index >= args.len) return error.MissingProviderValue;
            provider_override = model_provider.parse(args[index]) orelse
                return error.InvalidProviderValue;
        } else if (std.mem.startsWith(u8, arg, "--provider=")) {
            provider_override = model_provider.parse(arg["--provider=".len..]) orelse
                return error.InvalidProviderValue;
        } else if (std.mem.eql(u8, arg, "--model")) {
            index += 1;
            if (index >= args.len) return error.MissingModelValue;
            const model = std.mem.trim(u8, args[index], " \t\r\n");
            if (model.len == 0) return error.MissingModelValue;
            const owned_model = try alloc.dupe(u8, model);
            if (model_override) |old| alloc.free(old);
            model_override = owned_model;
        } else if (std.mem.startsWith(u8, arg, "--model=")) {
            const model = std.mem.trim(u8, arg["--model=".len..], " \t\r\n");
            if (model.len == 0) return error.MissingModelValue;
            const owned_model = try alloc.dupe(u8, model);
            if (model_override) |old| alloc.free(old);
            model_override = owned_model;
        } else if (std.mem.eql(u8, arg, "--effort")) {
            index += 1;
            if (index >= args.len) return error.MissingEffortValue;
            effort_override = types.ReasoningEffort.parse(args[index]) orelse
                return error.InvalidEffortValue;
        } else if (std.mem.startsWith(u8, arg, "--effort=")) {
            effort_override = types.ReasoningEffort.parse(arg["--effort=".len..]) orelse
                return error.InvalidEffortValue;
        } else if (std.mem.eql(u8, arg, "--fast") or std.mem.eql(u8, arg, "--no-fast")) {
            const enabled = std.mem.eql(u8, arg, "--fast");
            if (fast_override != null and fast_override.? != enabled)
                return error.ConflictingFastFlags;
            fast_override = enabled;
        } else if (std.mem.eql(u8, arg, "--provider-order")) {
            index += 1;
            if (index >= args.len) return error.MissingProviderOrderValue;
            provider_order_override = try parseProviderOrderFlag(alloc, args[index], provider_order_override);
        } else if (std.mem.startsWith(u8, arg, "--provider-order=")) {
            provider_order_override = try parseProviderOrderFlag(alloc, arg["--provider-order=".len..], provider_order_override);
        } else if (std.mem.eql(u8, arg, "--provider-strict") or std.mem.eql(u8, arg, "--no-provider-strict")) {
            const strict = std.mem.eql(u8, arg, "--provider-strict");
            if (provider_strict_override != null and provider_strict_override.? != strict)
                return error.ConflictingProviderStrictFlags;
            provider_strict_override = strict;
        } else {
            break;
        }
        index += 1;
    }

    const override_slice = try overrides.toOwnedSlice(alloc);
    errdefer if (override_slice.len > 0) alloc.free(override_slice);
    const directory_slice = try directories.toOwnedSlice(alloc);
    return .{
        .remaining = args[index..],
        .modifiers = .{
            .context_limit_overrides = override_slice,
            .additional_directories = directory_slice,
            .saved_directories_suppressed = suppress_saved,
            .provider_override = provider_override,
            .model_override = model_override,
            .effort_override = effort_override,
            .fast_override = fast_override,
            .provider_order_override = provider_order_override,
            .provider_strict_override = provider_strict_override,
        },
    };
}

/// Returns the command that follows the supported global launch modifiers.
/// Startup uses this same surface to select the full runtime configuration
/// before the allocating parser runs.
pub fn commandAfterGlobalLaunchArgs(args: []const [:0]const u8) ?[]const u8 {
    const remaining = argsAfterGlobalLaunchArgs(args);
    return if (remaining.len > 0) remaining[0] else null;
}

pub fn argsAfterGlobalLaunchArgs(args: []const [:0]const u8) []const [:0]const u8 {
    var index: usize = 0;
    while (index < args.len) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--context-limit") or
            std.mem.eql(u8, arg, "--add-dir") or
            std.mem.eql(u8, arg, "--provider") or
            std.mem.eql(u8, arg, "--provider-order") or
            std.mem.eql(u8, arg, "--model") or
            std.mem.eql(u8, arg, "--effort"))
        {
            index += 1;
            if (index >= args.len) return &.{};
        } else if (!std.mem.startsWith(u8, arg, "--context-limit=") and
            !std.mem.startsWith(u8, arg, "--add-dir=") and
            !std.mem.startsWith(u8, arg, "--provider=") and
            !std.mem.startsWith(u8, arg, "--provider-order=") and
            !std.mem.startsWith(u8, arg, "--model=") and
            !std.mem.startsWith(u8, arg, "--effort=") and
            !std.mem.eql(u8, arg, "--no-additional-dirs") and
            !std.mem.eql(u8, arg, "--fast") and
            !std.mem.eql(u8, arg, "--no-fast") and
            !std.mem.eql(u8, arg, "--provider-strict") and
            !std.mem.eql(u8, arg, "--no-provider-strict"))
        {
            return args[index..];
        }
        index += 1;
    }
    return &.{};
}

pub fn parse(command_catalog: CommandCatalog, args: []const [:0]const u8) Command {
    @setRuntimeSafety(false);
    if (args.len == 0) return .interactive;

    const command = args[0];
    if (command.len == 0) return .{ .unknown = command };
    switch (command[0]) {
        '-', 'h' => {
            if (command_specs.matchesTopLevel(command_catalog, command, .help)) return .help;
            if (command_specs.matchesTopLevel(command_catalog, command, .@"resume") or
                std.mem.startsWith(u8, command, resume_id_alias_prefix))
            {
                return .{ .resume_session = .{
                    .args = args,
                    .top_level_alias = true,
                } };
            }
        },
        'a' => {},
        'd' => {
            if (command_specs.matchesTopLevel(command_catalog, command, .doctor)) return .{ .doctor = args[1..] };
        },
        'i' => {
            if (command_specs.matchesTopLevel(command_catalog, command, .issue)) return .{ .issue = args[1..] };
        },
        'l' => {},
        'm' => {
            if (command_specs.matchesTopLevel(command_catalog, command, .models)) return .{ .models = args[1..] };
        },
        'p' => {
            if (command_specs.matchesTopLevel(command_catalog, command, .pr)) return .{ .pr = args[1..] };
            if (command_specs.matchesTopLevel(command_catalog, command, .provider)) return .{ .provider = args[1..] };
        },
        'r' => {
            if (command_specs.matchesTopLevel(command_catalog, command, .@"resume")) return .{ .resume_session = .{ .args = args[1..] } };
            if (command_specs.matchesTopLevel(command_catalog, command, .replay)) return .{ .replay = args[1..] };
        },
        's' => {
            if (command_specs.matchesTopLevel(command_catalog, command, .setup)) return .{ .setup = args[1..] };
            if (command_specs.matchesTopLevel(command_catalog, command, .status)) return .{ .status = args[1..] };
            if (command_specs.matchesTopLevel(command_catalog, command, .sessions)) return .{ .sessions = args[1..] };
            if (command_specs.matchesTopLevel(command_catalog, command, .session)) {
                if (args.len > 1 and std.mem.eql(u8, args[1], "resume")) {
                    return .{ .resume_session = .{ .args = args[2..] } };
                }
                return .{ .session = args[1..] };
            }
        },
        'u' => {
            if (command_specs.matchesTopLevel(command_catalog, command, .usage)) return .{ .usage = args[1..] };
            if (command_specs.matchesTopLevel(command_catalog, command, .upgrade)) return .{ .upgrade = args[1..] };
        },
        'w' => {
            if (command_specs.matchesTopLevel(command_catalog, command, .workspace)) return .{ .workspace = args[1..] };
        },
        else => {},
    }
    return .{ .unknown = command };
}

pub const NonInteractiveLaunch = struct {
    global_args: GlobalLaunchArgs,
    effective_args: []const [:0]const u8,
    command: Command,

    pub fn deinit(self: *NonInteractiveLaunch, alloc: Allocator) void {
        self.global_args.deinit(alloc);
        self.* = undefined;
    }
};

pub const InteractiveLaunchParseResult = union(enum) {
    interactive: InteractiveLaunch,
    noninteractive: NonInteractiveLaunch,
};

/// Parses the shared interactive launch language without dispatching commands.
/// Returned launch values own their allocations and must be deinitialized.
pub fn parseInteractiveLaunch(
    alloc: Allocator,
    args: []const [:0]const u8,
    command_catalog: CommandCatalog,
) !InteractiveLaunchParseResult {
    var global_args = try parseGlobalLaunchArgs(alloc, args);
    errdefer global_args.deinit(alloc);
    const effective_args = global_args.remaining;

    if (effective_args.len == 0) {
        return .{ .interactive = .{ .modifiers = global_args.takeModifiers() } };
    }

    const command = parse(command_catalog, effective_args);
    if (topLevelHelpRequest(command_catalog, effective_args) != null) {
        return .{ .noninteractive = .{
            .global_args = global_args,
            .effective_args = effective_args,
            .command = command,
        } };
    }
    switch (command) {
        .interactive => return .{ .interactive = .{
            .modifiers = global_args.takeModifiers(),
        } },
        .resume_session => |invocation| {
            const resume_args = invocation.args;
            const has_upgrade_relaunch = !invocation.top_level_alias and
                resume_args.len >= 2 and
                std.mem.eql(u8, resume_args[1], upgrade_relaunch_arg);
            if (has_upgrade_relaunch and resume_args.len > 3) return error.InvalidResumeArgs;
            var upgrade_relaunch: ?UpgradeRelaunch = null;
            errdefer if (upgrade_relaunch) |*relaunch| relaunch.deinit(alloc);
            if (has_upgrade_relaunch) {
                const previous_revision = if (resume_args.len == 3) revision: {
                    if (!update_target.isValidRevision(resume_args[2])) return error.InvalidResumeArgs;
                    break :revision try alloc.dupe(u8, resume_args[2]);
                } else null;
                upgrade_relaunch = .{ .previous_revision = previous_revision };
            }
            const target_args = if (has_upgrade_relaunch) resume_args[0..1] else resume_args;
            const target = try parseResumeArgs(
                alloc,
                command_catalog,
                target_args,
                invocation.top_level_alias,
            );
            const relaunch = upgrade_relaunch;
            upgrade_relaunch = null;
            return .{ .interactive = .{
                .requested_resume = target,
                .upgrade_relaunch = relaunch,
                .modifiers = global_args.takeModifiers(),
            } };
        },
        else => return .{ .noninteractive = .{
            .global_args = global_args,
            .effective_args = effective_args,
            .command = command,
        } },
    }
}

/// Detects `fx <subcommand> --help` / `-h` and returns the subcommand kind so the
/// caller can render command-specific help. Top-level `fx --help`/`fx help` are
/// handled separately and intentionally excluded here.
fn topLevelHelpRequest(command_catalog: CommandCatalog, args: []const [:0]const u8) ?TopLevelKind {
    if (args.len < 2) return null;
    const kind = command_specs.topLevelKindFromToken(command_catalog, args[0]) orelse return null;
    if (kind == .help) return null;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) return kind;
    }
    return null;
}

pub fn runIfRequested(alloc: Allocator, args: []const [:0]const u8, cfg: Config) !RunResult {
    return runIfRequestedWithDeps(alloc, args, cfg, .{});
}

fn runNoConfigIfRequestedWithDeps(
    alloc: Allocator,
    args: []const [:0]const u8,
    version: []const u8,
    command_catalog: CommandCatalog,
    deps: RunDeps,
) !bool {
    if (args.len != 1 or !command_specs.matchesTopLevel(command_catalog, args[0], .help)) {
        return false;
    }
    try writeTopLevelHelp(alloc, command_catalog, deps, version, .stdout);
    return true;
}

const CliTeamValidationContext = struct {
    alloc: Allocator,
    cfg: *const Config,
};

/// Confirms a candidate key reaches the provider's own model catalog. Used to
/// refuse a bad key before it is saved.
fn validateCliCatalogCredential(
    raw: ?*anyopaque,
    candidate: credentials.Credential,
) std.mem.Allocator.Error!bool {
    const context: *CliTeamValidationContext = @ptrCast(@alignCast(raw.?));
    const access = credentials.catalogAccessAt(candidate, io_mod.milliTimestamp());
    if (access.authorizationCredential() == null) return false;
    const provider = context.cfg.provider_set.openrouter.model_catalog orelse return false;
    const fetched = try provider.fetch(context.alloc, .{
        .access = access,
        .endpoint = context.cfg.models_path,
        .view = .picker,
    });
    return switch (fetched) {
        .failure => false,
        .catalog => |catalog_value| result: {
            var catalog = catalog_value;
            defer model_catalog.freeModelCatalog(context.alloc, &catalog);
            break :result catalog.items.len > 0;
        },
    };
}

fn writeProviderActivationError(
    alloc: Allocator,
    deps: RunDeps,
    detail: []const u8,
) !void {
    const message = try std.fmt.allocPrint(
        alloc,
        "fx provider: {s}\n",
        .{detail},
    );
    defer alloc.free(message);
    try writeStderr(deps, message);
}

fn writeHostManagedAuthResult(deps: RunDeps) !void {
    try writeStdout(deps, credentials.host_managed_auth_message);
    try writeStdout(deps, "\n");
}

fn activateProviderSelection(
    alloc: Allocator,
    cfg: Config,
    deps: RunDeps,
    target: model_provider.ProviderId,
    exact_source: ?credentials.Source,
) !bool {
    return activateProviderSelectionFallible(alloc, cfg, deps, target, exact_source) catch |err| {
        switch (err) {
            error.CredentialStorageUnavailable,
            error.CredentialTemporarilyUnavailable,
            error.CredentialRefreshPersistenceUncertain,
            error.CredentialAuthorityChanged,
            => {},
            else => return err,
        }
        const detail = try auth_runtime.preparationFailureText(alloc, target, err);
        defer alloc.free(detail);
        try writeProviderActivationError(alloc, deps, detail);
        return false;
    };
}

fn activateProviderSelectionFallible(
    alloc: Allocator,
    cfg: Config,
    deps: RunDeps,
    target: model_provider.ProviderId,
    exact_source: ?credentials.Source,
) !bool {
    const workspace_root = try io_mod.realpathAlloc(alloc, ".");
    defer alloc.free(workspace_root);
    var settings = config_runtime.loadMergedSettings(alloc, workspace_root) catch |err| {
        try writeProviderActivationError(alloc, deps, "could not load settings");
        debug_trace.logf("config", "provider selection settings load failed err={s}", .{@errorName(err)});
        return false;
    };
    defer settings.deinit(alloc);

    if (target == .configured) {
        const bound = try target.bind(settings.providers orelse .{});
        const selected_model = settings.models.get(bound) orelse return error.ConfiguredModelNotSelected;
        var attempt = config_runtime.attemptUserPreferences(alloc, .{
            .provider = bound,
            .model_preference = .{ .provider = bound, .model = selected_model },
        });
        defer attempt.deinit(alloc);
        switch (attempt) {
            .failure => {
                try writeProviderActivationError(alloc, deps, "failed to save provider selection");
                return false;
            },
            .outcome => {},
        }
        const message = try std.fmt.allocPrint(alloc, "Provider set to {s}.\n", .{bound.label()});
        defer alloc.free(message);
        try writeStdout(deps, message);
        return true;
    }
    const preferred_source = exact_source orelse settings.credential_source;
    var prepared_credential = if (cfg.auth_mode == .host_managed)
        null
    else
        try auth_runtime.prepareCredential(
            alloc,
            cfg.secret_store,
            target,
            preferred_source,
        );
    defer if (prepared_credential) |*credential| credential.deinit(alloc);

    const already_selected = (settings.provider orelse @as(model_provider.ProviderId, .openrouter)).eql(target);
    // A selected provider without a persisted model still needs one chosen
    // below; FX_MODEL only covers a single run, so it does not count here.
    const has_persisted_model = if (config_runtime.selectProviderModel(cfg.default_model, &settings, target, null)) |_| true else |_| false;
    if (already_selected and has_persisted_model and
        (cfg.auth_mode == .host_managed or prepared_credential != null))
    {
        try writeStdout(deps, switch (target) {
            .openrouter => "OpenRouter is already selected.\n",
            .groq => "Groq is already selected.\n",
            .openai_compatible => "OpenAI-compatible is already selected.\n",
            .configured => "Configured provider is already selected.\n",
        });
        return true;
    }

    const credential = if (cfg.auth_mode == .host_managed)
        null
    else if (prepared_credential) |*value|
        value
    else {
        try writeProviderActivationError(
            alloc,
            deps,
            switch (target) {
                .openrouter => "configure an OpenRouter API key first",
                .groq => "configure a Groq API key first",
                .openai_compatible => "configure an OpenAI-compatible API key first",
                .configured => "configure the provider auth environment variable first",
            },
        );
        return false;
    };
    const catalog_provider = cfg.provider_set.select(target).model_catalog orelse {
        try writeProviderActivationError(alloc, deps, switch (target) {
            .openrouter => "OpenRouter model catalog is unavailable",
            .groq => "Groq model catalog is unavailable",
            .openai_compatible => "OpenAI-compatible model catalog is unavailable",
            .configured => "Configured model catalog is unavailable",
        });
        return false;
    };
    const fetch_result = model_catalog.fetchWithPublicFallback(catalog_provider, alloc, .{
        .access = if (cfg.auth_mode == .host_managed)
            .host_managed
        else
            credentials.catalogAccessAt(
                credential.?.*,
                io_mod.milliTimestamp(),
            ).withExplicitAuthority(),
        .endpoint = cfg.models_path,
        .view = .picker,
    });
    var loaded = switch (fetch_result) {
        .loaded => |loaded| blk: {
            if (loaded.provenance.access.level != .authenticated or
                loaded.provenance.anonymous_fallback_used)
            {
                var rejected = loaded.catalog;
                model_catalog.freeModelCatalog(alloc, &rejected);
                try writeProviderActivationError(
                    alloc,
                    deps,
                    "target credential did not produce an authenticated model catalog",
                );
                return false;
            }
            break :blk loaded;
        },
        .failed => |failure| {
            debug_trace.logf("catalog", "provider selection catalog failed provider={s} category={s}", .{ @tagName(target), @tagName(failure.failure.category) });
            const detail = try std.fmt.allocPrint(
                alloc,
                "could not load the target model catalog ({s})",
                .{@tagName(failure.failure.category)},
            );
            defer alloc.free(detail);
            try writeProviderActivationError(alloc, deps, detail);
            return false;
        },
    };
    defer model_catalog.freeModelCatalog(alloc, &loaded.catalog);
    const saved_model = settings.models.get(target);
    const selected_model = selectCatalogModel(loaded.catalog.items, saved_model) orelse {
        try writeProviderActivationError(alloc, deps, "target model catalog is empty");
        return false;
    };
    var attempt = config_runtime.attemptUserPreferences(alloc, .{
        .provider = target,
        .model_preference = .{ .provider = target, .model = selected_model },
        .credential_source = exact_source,
    });
    defer attempt.deinit(alloc);
    switch (attempt) {
        .failure => |failure| {
            debug_trace.logf("config", "provider selection persistence failed err={s}", .{@errorName(failure.err)});
            try writeProviderActivationError(alloc, deps, "failed to save provider selection");
            return false;
        },
        .outcome => {},
    }
    try writeStdout(deps, switch (target) {
        .openrouter => "Provider set to OpenRouter.\n",
        .groq => "Provider set to Groq.\n",
        .openai_compatible => "Provider set to OpenAI-compatible.\n",
        .configured => "Provider set to configured connection.\n",
    });
    return true;
}

fn runIfRequestedWithDeps(alloc: Allocator, args: []const [:0]const u8, cfg: Config, deps: RunDeps) !RunResult {
    const parsed_launch = parseInteractiveLaunch(alloc, args, cfg.command_catalog) catch |err| {
        if (err == error.InvalidResumeArgs) {
            try writeTopLevelUsage(cfg.command_catalog, deps, .@"resume");
            return .handled_failure;
        }
        var writer: std.Io.Writer.Allocating = .init(alloc);
        defer writer.deinit();
        if (globalLaunchErrorMessage(err)) |message| {
            try writer.writer.print("fx: {s}\n", .{message});
        } else {
            try writer.writer.print("fx: invalid global launch option: {s}\n", .{@errorName(err)});
        }
        try writer.writer.writeAll("usage: fx [--context-limit NAME=BYTES|off] [--add-dir PATH]... [--no-additional-dirs] [--provider <name>] [--model <id>] [--effort <level>] [--fast|--no-fast] [--provider-order <a,b,...>] [--provider-strict|--no-provider-strict] <command>\n");
        try writeStderr(deps, writer.written());
        return .handled_failure;
    };
    switch (parsed_launch) {
        .interactive => |launch| {
            return .{ .interactive = launch };
        },
        .noninteractive => |value| {
            var noninteractive = value;
            defer noninteractive.deinit(alloc);
            return runNonInteractiveWithDeps(alloc, &noninteractive, cfg, deps);
        },
    }
}

fn runNonInteractiveWithDeps(
    alloc: Allocator,
    parsed_launch: *NonInteractiveLaunch,
    cfg: Config,
    deps: RunDeps,
) !RunResult {
    const global_args = &parsed_launch.global_args;
    const effective_args = parsed_launch.effective_args;
    const parsed_command = parsed_launch.command;

    if (global_args.modifiers.hasWorkspaceModifiers() and
        !commandSupportsWorkspaceModifiers(parsed_command))
    {
        try writeWorkspaceModifierUsage(deps);
        return .handled_failure;
    }

    if (global_args.modifiers.hasModelOverrides()) {
        try writeModelModifierUsage(deps);
        return .handled_failure;
    }

    if (isVersionFlag(effective_args[0])) {
        if (effective_args.len != 1) {
            try writeStderr(deps, version_usage);
            return .handled_failure;
        }
        try writeStdout(deps, cfg.version);
        try writeStdout(deps, "\n");
        return .handled_success;
    }

    if (topLevelHelpRequest(cfg.command_catalog, effective_args)) |kind| {
        const text = try command_specs.renderTopLevelCommandHelp(alloc, cfg.command_catalog, kind);
        defer alloc.free(text);
        try writeStdout(deps, text);
        return .handled_success;
    }

    switch (parsed_command) {
        .interactive, .resume_session => unreachable,
        .help => {
            try writeTopLevelHelp(alloc, cfg.command_catalog, deps, cfg.version, .stdout);
            return .handled_success;
        },
        .pr => |rest| return runGithubWorkflow(alloc, rest, cfg, global_args.modifiers, deps, .pull_request),
        .issue => |rest| return runGithubWorkflow(alloc, rest, cfg, global_args.modifiers, deps, .issue),
        .provider => |rest| {
            if (rest.len != 1) {
                try writeStderr(deps, "usage: fx provider <name>\n");
                return .handled_failure;
            }
            const target = model_provider.parse(rest[0]) orelse {
                try writeStderr(deps, "fx provider: expected openrouter or a configured name\n");
                return .handled_failure;
            };
            return if (try activateProviderSelection(alloc, cfg, deps, target, null))
                .handled_success
            else
                .handled_failure;
        },
        .setup => |rest| {
            if (rest.len != 0) {
                try writeTopLevelUsage(cfg.command_catalog, deps, .setup);
                return .handled_failure;
            }
            if (cfg.auth_mode == .host_managed) {
                try writeHostManagedAuthResult(deps);
                return .handled_success;
            }
            return if (try runPasteSetup(alloc, cfg.secret_store, deps)) .handled_success else .handled_failure;
        },
        .status => |rest| {
            const opts = parseLocalSurfaceArgs(rest) catch |err| {
                try writeUsageOrJsonError(alloc, cfg.command_catalog, deps, .status, "status", err, rest);
                return .handled_failure;
            };
            var startup = if (cfg.auth_mode == .host_managed)
                try deps.load_startup_status_with_auth_mode(
                    alloc,
                    cfg.secret_store,
                    cfg.default_model,
                    cfg.default_agent_step_limit,
                    cfg.auth_mode,
                )
            else
                try deps.load_startup_status(
                    alloc,
                    cfg.secret_store,
                    cfg.default_model,
                    cfg.default_agent_step_limit,
                );
            defer startup.deinit(alloc);
            try writeConfigDiagnostics(alloc, deps, startup.config_diagnostics);

            var snapshot = statusSnapshotFromStartupWithBuild(startup, .{
                .channel = cfg.build_channel,
                .version = cfg.version,
                .revision = cfg.revision,
            });
            snapshot.provider_endpoint = startup.provider_endpoint;
            if (opts.format == .json) {
                try writeStatusJsonLine(alloc, deps, snapshot);
                return .handled_success;
            }

            const text = try snapshot.render(alloc, opts.format);
            defer alloc.free(text);
            try writeFormattedOutput(deps, text, opts.format);
            return .handled_success;
        },
        .models => |rest| {
            const opts = parseLocalSurfaceArgs(rest) catch |err| {
                try writeUsageOrJsonError(alloc, cfg.command_catalog, deps, .models, "models", err, rest);
                return .handled_failure;
            };

            var startup = if (cfg.auth_mode == .host_managed)
                try deps.load_catalog_startup_state_with_auth_mode(
                    alloc,
                    cfg.secret_store,
                    cfg.default_model,
                    cfg.default_agent_step_limit,
                    cfg.auth_mode,
                    null,
                    null,
                )
            else
                try deps.load_startup_state(
                    alloc,
                    cfg.secret_store,
                    cfg.default_model,
                    cfg.default_agent_step_limit,
                );
            defer startup.deinit(alloc);
            try writeConfigDiagnostics(alloc, deps, startup.config_diagnostics);

            const catalog_access = startup.modelCatalogAccess();
            var available_providers = cfg.provider_set;
            available_providers.definitions = startup.configured_providers.definitions;
            const catalog_provider = available_providers.select(startup.provider).cli_model_catalog orelse {
                try writeStderr(deps, switch (startup.provider) {
                    .openrouter => "fx models: OpenRouter model catalog is unavailable\n",
                    .groq => "fx models: Groq model catalog is unavailable\n",
                    .openai_compatible => "fx models: OpenAI-compatible model catalog is unavailable\n",
                    .configured => "fx models: Configured model catalog is unavailable\n",
                });
                return .handled_failure;
            };
            const loaded = switch (catalog_provider.fetch(alloc, .{
                .access = catalog_access,
                .endpoint = cfg.models_path,
            })) {
                .loaded => |loaded| loaded,
                .failure => |failure| {
                    const error_name = @errorName(failure.failure.asError());
                    const message = try std.fmt.allocPrint(
                        alloc,
                        "could not list models: {s}",
                        .{catalogFailureDetail(failure.failure)},
                    );
                    defer alloc.free(message);
                    if (opts.format == .json) {
                        try writeJsonCommandFailureCode(
                            alloc,
                            deps,
                            "models",
                            error_name,
                            message,
                        );
                    } else {
                        try writeStderr(deps, "fx models: ");
                        try writeStderr(deps, message);
                        try writeStderr(deps, "\n");
                    }
                    return .handled_failure;
                },
            };
            var ids = loaded.ids;
            defer collections.freeStringList(alloc, &ids);

            const text = try (output_contracts.ModelListSnapshot{
                .ids = ids.items,
                .provider = startup.provider,
                .private_models_hidden = loaded.provenance.access.private_models_may_be_hidden,
                .public_only_reason = loaded.provenance.access.public_only_reason,
            }).render(alloc, opts.format);
            defer alloc.free(text);
            try writeFormattedOutput(deps, text, opts.format);
            return .handled_success;
        },
        .doctor => |rest| {
            const opts = parseLocalSurfaceArgs(rest) catch |err| {
                try writeUsageOrJsonError(alloc, cfg.command_catalog, deps, .doctor, "doctor", err, rest);
                return .handled_failure;
            };

            const workspace_root = try io_mod.realpathAlloc(alloc, ".");
            defer alloc.free(workspace_root);
            var snapshot = try doctor_runtime.collect(
                alloc,
                cfg.secret_store,
                cfg.default_model,
                cfg.default_agent_step_limit,
            );
            defer snapshot.deinit(alloc);

            var output_snapshot = doctorSnapshotFromRuntime(snapshot);
            if (opts.format == .json) {
                try writeDoctorJsonLine(alloc, deps, output_snapshot);
                return .handled_success;
            }

            const text = try output_snapshot.render(alloc, opts.format);
            defer alloc.free(text);
            try writeFormattedOutput(deps, text, opts.format);
            return .handled_success;
        },
        .session => |rest| {
            if (rest.len > 0 and std.mem.eql(u8, rest[0], "recover")) {
                var recovery = parseSessionRecoveryArgs(
                    alloc,
                    rest[1..],
                ) catch |err| {
                    try writeUsageOrJsonError(
                        alloc,
                        cfg.command_catalog,
                        deps,
                        .session,
                        "session",
                        err,
                        rest[1..],
                    );
                    return .handled_failure;
                };
                defer recovery.deinit(alloc);

                const workspace_root = try io_mod.realpathAlloc(alloc, ".");
                defer alloc.free(workspace_root);
                var store = session_store.Store.init(
                    alloc,
                    workspace_root,
                ) catch |err| {
                    try writeLookupFailure(
                        alloc,
                        deps,
                        "session",
                        err,
                        recovery.format,
                    );
                    return .handled_failure;
                };
                defer store.deinit(alloc);
                var result = store.recoverSessionCopy(
                    alloc,
                    recovery.session_id,
                    .{},
                ) catch |err| {
                    try writeLookupFailure(
                        alloc,
                        deps,
                        "session",
                        err,
                        recovery.format,
                    );
                    return .handled_failure;
                };
                defer result.deinit(alloc);

                const text = try (output_contracts.SessionRecoverySnapshot{
                    .result = result,
                }).render(alloc, recovery.format);
                defer alloc.free(text);
                try writeFormattedOutput(deps, text, recovery.format);
                return if (result.status == .recovered)
                    .handled_success
                else
                    .handled_failure;
            }

            if (rest.len > 0 and std.mem.eql(u8, rest[0], "migrate")) {
                var migration = parseSessionMigrationArgs(alloc, rest[1..]) catch |err| {
                    try writeUsageOrJsonError(alloc, cfg.command_catalog, deps, .session, "session", err, rest[1..]);
                    return .handled_failure;
                };
                defer migration.deinit(alloc);

                const workspace_root = try io_mod.realpathAlloc(alloc, ".");
                defer alloc.free(workspace_root);

                var store = session_store.Store.init(alloc, workspace_root) catch |err| {
                    try writeLookupFailure(alloc, deps, "session", err, migration.format);
                    return .handled_failure;
                };
                defer store.deinit(alloc);
                var result = store.migrateLegacyStorageOnly(
                    alloc,
                    migration.session_id,
                    .{ .allow_large = migration.allow_large },
                ) catch |err| {
                    try writeLookupFailure(alloc, deps, "session", err, migration.format);
                    return .handled_failure;
                };
                defer result.deinit(alloc);

                const text = try (output_contracts.SessionMigrationSnapshot{
                    .result = result,
                }).render(alloc, migration.format);
                defer alloc.free(text);
                try writeFormattedOutput(deps, text, migration.format);
                return .handled_success;
            }

            var opts = parseSessionDetailArgs(alloc, rest) catch |err| {
                try writeUsageOrJsonError(alloc, cfg.command_catalog, deps, .session, "session", err, rest);
                return .handled_failure;
            };
            defer opts.deinit(alloc);

            const target = opts.target orelse {
                try writeUsageOrJsonError(alloc, cfg.command_catalog, deps, .session, "session", error.InvalidSessionDetailArgs, rest);
                return .handled_failure;
            };

            const workspace_root = try io_mod.realpathAlloc(alloc, ".");
            defer alloc.free(workspace_root);

            var store = session_store.Store.initReadOnly(alloc, workspace_root) catch |err| {
                try writeLookupFailure(alloc, deps, "session", err, opts.format);
                return .handled_failure;
            };
            defer store.deinit(alloc);

            switch (target) {
                .last => {
                    var summary = subagent_resume_admission.latestVisibleWorkspaceSummary(
                        store,
                        alloc,
                    ) catch |err| {
                        try writeLookupFailure(alloc, deps, "session", err, opts.format);
                        return .handled_failure;
                    };
                    defer summary.deinit(alloc);

                    const text = try (output_contracts.SessionSummarySnapshot{
                        .summary = summary,
                    }).render(alloc, opts.format);
                    defer alloc.free(text);
                    try writeFormattedOutput(deps, text, opts.format);
                    return .handled_success;
                },
                .id => |id| {
                    var detail = subagent_resume_admission.loadVisibleReadOnlyDetail(
                        store,
                        alloc,
                        id,
                        .{},
                    ) catch |err| {
                        try writeSessionDetailFailure(
                            alloc,
                            deps,
                            id,
                            err,
                            opts.format,
                        );
                        return .handled_failure;
                    };
                    defer detail.deinit(alloc);

                    const text = try (output_contracts.SessionDetailSnapshot{
                        .detail = detail,
                    }).render(alloc, opts.format);
                    defer alloc.free(text);
                    try writeFormattedOutput(deps, text, opts.format);
                    return .handled_success;
                },
            }
        },
        .sessions => |rest| {
            const opts = parseSessionListArgs(rest) catch |err| {
                try writeUsageOrJsonError(alloc, cfg.command_catalog, deps, .sessions, "sessions", err, rest);
                return .handled_failure;
            };

            const workspace_root = try io_mod.realpathAlloc(alloc, ".");
            defer alloc.free(workspace_root);

            var store = session_store.Store.initReadOnly(alloc, workspace_root) catch |err| {
                try writeLookupFailure(alloc, deps, "sessions", err, opts.format);
                return .handled_failure;
            };
            defer store.deinit(alloc);

            var page = subagent_resume_admission.listVisiblePage(
                store,
                alloc,
                opts.scope,
                opts.continuation,
                opts.limit,
            ) catch |err| return err;
            defer page.deinit(alloc);
            const next_cursor = if (page.has_more and page.summaries.items.len > 0)
                try formatSessionListCursor(
                    alloc,
                    page.summaries.items[page.summaries.items.len - 1],
                )
            else
                null;
            defer if (next_cursor) |cursor| alloc.free(cursor);

            const text = try (output_contracts.SessionListSnapshot{
                .sessions = page.summaries.items,
                .has_more = page.has_more,
                .next_cursor = next_cursor,
                .skipped_invalid = page.skipped_invalid,
                .all_workspaces = opts.scope == .all_workspaces,
            }).render(alloc, opts.format);
            defer alloc.free(text);
            try writeFormattedOutput(deps, text, opts.format);
            return .handled_success;
        },
        .workspace => |rest| {
            const opts = parseWorkspaceArgs(rest) catch |err| {
                try writeWorkspaceCommandError(alloc, cfg.command_catalog, deps, rest, err);
                return .handled_failure;
            };
            var startup = deps.load_startup_state_without_credentials(
                alloc,
                cfg.default_model,
                cfg.default_agent_step_limit,
            ) catch |err| {
                try writeWorkspaceCommandError(alloc, cfg.command_catalog, deps, rest, err);
                return .handled_failure;
            };
            defer startup.deinit(alloc);
            try writeConfigDiagnostics(alloc, deps, startup.config_diagnostics);

            if (opts.action == null) {
                const snapshot = output_contracts.WorkspaceSnapshot.fromAccess(
                    startup.workspace_root,
                    &startup.workspace_access,
                );
                const text = try snapshot.render(alloc, opts.format);
                defer alloc.free(text);
                try writeFormattedOutput(deps, text, opts.format);
                return .handled_success;
            }

            var failure_phase: workspace_commands.FailurePhase = .stage;
            var result = workspace_commands.execute(
                alloc,
                startup.workspace_root,
                &startup.workspace_access,
                opts.action.?,
                &failure_phase,
            ) catch |err| {
                try writeWorkspaceCommandError(alloc, cfg.command_catalog, deps, rest, err);
                return .handled_failure;
            };
            defer result.deinit(alloc);

            switch (result) {
                .updated => |updated| {
                    var snapshot = output_contracts.WorkspaceSnapshot.fromAccess(startup.workspace_root, &updated.access);
                    snapshot.mutation = updated.mutation;
                    const text = try snapshot.render(alloc, opts.format);
                    defer alloc.free(text);
                    try writeFormattedOutput(deps, text, opts.format);
                    return .handled_success;
                },
                .indeterminate => |reconciliation| {
                    try writeWorkspaceIndeterminateError(alloc, deps, rest, reconciliation);
                    return .handled_failure;
                },
            }
        },
        .usage => |rest| {
            const opts = parseUsageArgs(rest) catch |err| {
                try writeUsageOrJsonError(alloc, cfg.command_catalog, deps, .usage, "usage", err, rest);
                return .handled_failure;
            };
            const home = deps.getenv(deps.env_ctx, "HOME") orelse {
                try writeUsageCommandFailure(
                    alloc,
                    deps,
                    error.HomeNotSet,
                    opts.format,
                );
                return .handled_failure;
            };
            var report = usage_cli_runtime.collect(
                alloc,
                home,
                opts.scope,
                @max(io_mod.milliTimestamp(), 0),
            ) catch |err| {
                try writeUsageCommandFailure(alloc, deps, err, opts.format);
                return .handled_failure;
            };
            defer report.deinit(alloc);
            const text = try (output_contracts.UsageSnapshot{
                .report = &report,
            }).render(alloc, opts.format);
            defer alloc.free(text);
            try writeFormattedOutput(deps, text, opts.format);
            return .handled_success;
        },
        .upgrade => |rest| {
            const upgrade_runtime = @import("../upgrade/upgrade_runtime.zig");
            const opts = parseUpgradeArgs(rest) catch |err| {
                try writeUsageOrJsonError(alloc, cfg.command_catalog, deps, .upgrade, "upgrade", err, rest);
                return .handled_failure;
            };

            var startup = deps.load_startup_state_without_credentials(
                alloc,
                cfg.default_model,
                cfg.default_agent_step_limit,
            ) catch |err| {
                if (opts.format == .json) {
                    try writeJsonCommandFailure(alloc, deps, "upgrade", err, "failed to load update settings");
                } else {
                    try writeStderr(deps, "fx upgrade: failed to load update settings\n");
                }
                return .handled_failure;
            };
            defer startup.deinit(alloc);
            try writeConfigDiagnostics(alloc, deps, startup.config_diagnostics);

            const channel = opts.channel orelse startup.update_channel;
            if (opts.channel) |selected| {
                var outcome = config_runtime.setUserPreferences(alloc, .{ .update_channel = selected }) catch |err| {
                    if (opts.format == .json) {
                        try writeJsonCommandFailure(alloc, deps, "upgrade", err, "failed to save update channel");
                    } else {
                        try writeStderr(deps, "fx upgrade: failed to save update channel\n");
                    }
                    return .handled_failure;
                };
                defer outcome.deinit(alloc);
            }

            var result = upgrade_runtime.run(alloc, .{
                .channel = cfg.build_channel,
                .version = cfg.version,
                .revision = cfg.revision,
            }, channel, switch (opts.format) {
                .text => .text,
                .json => .json,
            });
            defer result.deinit(alloc);
            const text = result.snapshot.render(alloc, switch (opts.format) {
                .text => .text,
                .json => .json,
            }) catch {
                try writeStderr(deps, "fx upgrade: render failed\n");
                return .handled_failure;
            };
            defer alloc.free(text);
            try writeStdout(deps, text);
            if (opts.format == .json) try writeStdout(deps, "\n");
            return if (result.snapshot.status == .failed) .handled_failure else .handled_success;
        },
        .replay => |rest| {
            const exit_code = try cli_replay.run(alloc, rest);
            return if (exit_code == 0) .handled_success else .handled_failure;
        },
        .unknown => |command| {
            try writeStderr(deps, "fx: unknown subcommand: ");
            try writeStderr(deps, command);
            try writeStderr(deps, "\n\n");
            try writeTopLevelHelp(alloc, cfg.command_catalog, deps, cfg.version, .stderr);
            return error.UnknownCliCommand;
        },
    }
}

const TopLevelHelpDestination = enum { stdout, stderr };

fn writeTopLevelHelp(
    alloc: Allocator,
    command_catalog: CommandCatalog,
    deps: RunDeps,
    version: []const u8,
    destination: TopLevelHelpDestination,
) !void {
    const text = try command_specs.renderTopLevelHelp(
        alloc,
        command_catalog,
        command_specs.top_level_help_default_width,
        version,
    );
    defer alloc.free(text);
    switch (destination) {
        .stdout => try writeStdout(deps, text),
        .stderr => try writeStderr(deps, text),
    }
}

fn runGithubWorkflow(
    alloc: Allocator,
    args: []const [:0]const u8,
    cfg: Config,
    launch_modifiers: LaunchModifiers,
    deps: RunDeps,
    workflow: github_workflows.Workflow,
) !RunResult {
    const opts = try parseWorkflowArgs(alloc, args);
    defer opts.deinit(alloc);

    const prompt = switch (workflow) {
        .pull_request => github_workflows.buildPrompt(alloc, workflow, workflowLanguagePlaceholder(), opts.context) catch |err| switch (err) {
            error.NotGitRepository => {
                try writeStderr(deps, "fx pr: requires running inside a git repository\n");
                return .handled_failure;
            },
            else => return err,
        },
        .issue => try github_workflows.buildPrompt(alloc, workflow, workflowLanguagePlaceholder(), opts.context),
    };
    defer alloc.free(prompt);

    const workflow_cfg = workflowConfigWithLaunchModifiers(cfg, launch_modifiers);
    if (!opts.create) {
        const exit_code = try one_shot.runPrompt(alloc, prompt, opts.auto_permission, workflow_cfg, cfg.context_registry, cfg.tool_set);
        return if (exit_code == 0) .handled_success else .handled_failure;
    }

    const run_result = try one_shot.runPromptCapture(alloc, prompt, opts.auto_permission, workflow_cfg, cfg.context_registry, cfg.tool_set);
    defer run_result.deinit(alloc);
    if (run_result.exit_code != 0) return .handled_failure;

    const draft = draftFromRun(alloc, run_result) catch {
        try writeStderr(deps, switch (workflow) {
            .pull_request => "fx pr: failed to parse drafted PR title/body\n",
            .issue => "fx issue: failed to parse drafted issue title/body\n",
        });
        return .handled_failure;
    };
    defer draft.deinit(alloc);

    const published = try github_publish.publish(alloc, switch (workflow) {
        .pull_request => .pull_request,
        .issue => .issue,
    }, draft);
    defer published.deinit(alloc);
    if (!published.ok) {
        try writeStderr(deps, switch (workflow) {
            .pull_request => "fx pr: ",
            .issue => "fx issue: ",
        });
        try writeStderr(deps, published.text);
        try writeStderr(deps, "\n");
        return .handled_failure;
    }
    try writeStdout(deps, published.text);
    try writeStdout(deps, "\n");
    return .handled_success;
}

/// Parses the draft from the completed final response only, so text the model
/// wrote before a tool call never becomes the title or body.
fn draftFromRun(alloc: Allocator, run_result: one_shot.PromptRunResult) !github_publish.Draft {
    return github_publish.parseDraft(alloc, run_result.final_source);
}

fn writeStdout(deps: RunDeps, text: []const u8) !void {
    try deps.write_stdout(deps.stdout_ctx, text);
}

fn writeStderr(deps: RunDeps, text: []const u8) !void {
    try deps.write_stderr(deps.stderr_ctx, text);
}

fn runPasteSetup(
    alloc: Allocator,
    secret_store: host.SecretStore,
    deps: RunDeps,
) !bool {
    if (secret_store.isDisabled()) {
        try writeStderr(deps, "fx setup: stored API keys are disabled by FX_DISABLE_KEYCHAIN\n");
        return false;
    }
    if (!deps.setup_terminal_available(deps.setup_ctx)) {
        try writeStderr(deps, "fx setup: an interactive terminal is required to paste an API key\n");
        return false;
    }

    try writeStderr(deps, "Paste OpenRouter API key (input hidden): ");
    const stored_interactively = secret_store.storeInteractive() catch {
        try writeStderr(deps, "\nfx setup: API key was not saved\n");
        return false;
    };
    if (!stored_interactively) {
        const key = deps.read_masked_key(
            deps.setup_ctx,
            alloc,
            deps.write_stderr,
            deps.stderr_ctx,
        ) catch {
            try writeStderr(deps, "\nfx setup: API key was not saved\n");
            return false;
        };
        defer secret.zeroAndFree(alloc, key);
        try writeStderr(deps, "\n");
        secret_store.store(alloc, key) catch {
            try writeStderr(deps, "fx setup: API key was not saved\n");
            return false;
        };
    }

    const message = try std.fmt.allocPrint(
        alloc,
        "Saved API key to {s}.\n",
        .{secret_store.backend_label},
    );
    defer alloc.free(message);
    try writeStdout(deps, message);
    return true;
}

fn setupTerminalAvailableDefault(_: ?*anyopaque) bool {
    return std.c.isatty(std.posix.STDIN_FILENO) != 0 and
        std.c.isatty(std.posix.STDERR_FILENO) != 0;
}

fn readMaskedKeyDefault(
    _: ?*anyopaque,
    alloc: Allocator,
    write_mask: WriteFn,
    write_ctx: ?*anyopaque,
) ![]u8 {
    var raw = try MaskedKeyRawMode.enable();
    defer raw.disable();

    var input: std.ArrayList(u8) = .empty;
    errdefer {
        if (input.capacity > 0) secret.zeroAndFree(alloc, input.allocatedSlice());
    }

    while (input.items.len < 8 * 1024) {
        var byte: [1]u8 = undefined;
        if (try std.posix.read(std.posix.STDIN_FILENO, &byte) == 0) return error.SetupCancelled;
        switch (byte[0]) {
            '\r', '\n' => {
                if (input.items.len == 0) continue;
                // toOwnedSlice shrinks through realloc, which may move the buffer
                // and free the original without zeroing it. Copy out and wipe the
                // source so no unzeroed key is left behind in freed memory.
                const owned = try alloc.dupe(u8, input.items);
                secret.zeroAndFree(alloc, input.allocatedSlice());
                input = .empty;
                return owned;
            },
            3, 4, 0x1b => return error.SetupCancelled,
            8, 127 => if (input.items.len > 0) {
                _ = input.pop();
                try write_mask(write_ctx, "\x08 \x08");
            },
            0x20...0x7e => {
                try input.append(alloc, byte[0]);
                try write_mask(write_ctx, "•");
            },
            else => {},
        }
    }
    return error.SetupKeyTooLong;
}

const MaskedKeyRawMode = struct {
    original: std.posix.termios = undefined,
    active: bool = false,

    fn enable() !MaskedKeyRawMode {
        if (std.c.isatty(std.posix.STDIN_FILENO) == 0 or
            std.c.isatty(std.posix.STDERR_FILENO) == 0)
        {
            return error.NotATerminal;
        }

        var self: MaskedKeyRawMode = .{};
        self.original = try std.posix.tcgetattr(std.posix.STDIN_FILENO);
        var raw = self.original;
        raw.iflag.BRKINT = false;
        raw.iflag.ICRNL = false;
        raw.iflag.INPCK = false;
        raw.iflag.ISTRIP = false;
        raw.iflag.IXON = false;
        raw.iflag.IXOFF = false;
        raw.cflag.CSIZE = .CS8;
        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        raw.lflag.IEXTEN = false;
        raw.lflag.ISIG = false;
        const vmin_idx = switch (builtin.os.tag) {
            .linux => 6,
            else => 16,
        };
        const vtime_idx = switch (builtin.os.tag) {
            .linux => 5,
            else => 17,
        };
        if (vmin_idx < raw.cc.len and vtime_idx < raw.cc.len) {
            raw.cc[vmin_idx] = 1;
            raw.cc[vtime_idx] = 0;
        }
        try std.posix.tcsetattr(std.posix.STDIN_FILENO, .FLUSH, raw);
        self.active = true;
        return self;
    }

    fn disable(self: *MaskedKeyRawMode) void {
        if (!self.active) return;
        std.posix.tcsetattr(std.posix.STDIN_FILENO, .FLUSH, self.original) catch {};
        self.active = false;
    }
};

fn writeConfigDiagnostics(
    alloc: Allocator,
    deps: RunDeps,
    diagnostics: []const config_runtime.ConfigDiagnostic,
) !void {
    for (diagnostics) |diagnostic| {
        if (!diagnostic.reportAtStartup()) continue;
        var notice_writer: std.Io.Writer.Allocating = .init(alloc);
        defer notice_writer.deinit();
        try notice_writer.writer.print(
            "fx: config {s}: {s}",
            .{ @tagName(diagnostic.layer), @tagName(diagnostic.cause) },
        );
        try config_runtime.writeDiagnosticMetadata(&notice_writer.writer, diagnostic);
        try notice_writer.writer.writeByte('\n');
        const notice = try notice_writer.toOwnedSlice();
        defer alloc.free(notice);
        try writeStderr(deps, notice);
    }
}

fn writeFormattedOutput(deps: RunDeps, text: []const u8, format: output_contracts.OutputFormat) !void {
    switch (format) {
        .text => try writeStdout(deps, text),
        .json => try writeJsonLine(deps, text),
    }
}

fn writeJsonLine(deps: RunDeps, text: []const u8) !void {
    @setRuntimeSafety(false);
    var buf: [4096]u8 = undefined;
    if (text.len < buf.len) {
        @memcpy(buf[0..text.len], text);
        buf[text.len] = '\n';
        return writeStdout(deps, buf[0 .. text.len + 1]);
    }

    try writeStdout(deps, text);
    try writeStdout(deps, "\n");
}

const JsonLinePayload = union(enum) {
    status: output_contracts.StatusSnapshot,
    doctor: output_contracts.DoctorSnapshot,
};

fn writeRenderedJsonLine(alloc: Allocator, deps: RunDeps, fixed_buffer: []u8, payload: JsonLinePayload) !void {
    var writer: std.Io.Writer = .fixed(fixed_buffer);
    renderJsonLinePayload(&writer, payload) catch |err| switch (err) {
        error.WriteFailed => {
            var out: std.Io.Writer.Allocating = .init(alloc);
            defer out.deinit();
            try renderJsonLinePayload(&out.writer, payload);
            return writeJsonLine(deps, out.writer.buffered());
        },
    };
    try writeJsonLine(deps, writer.buffered());
}

fn renderJsonLinePayload(writer: *std.Io.Writer, payload: JsonLinePayload) std.Io.Writer.Error!void {
    switch (payload) {
        .status => |snapshot| try snapshot.writeJson(writer),
        .doctor => |snapshot| try snapshot.writeJson(writer),
    }
}

fn writeStatusJsonLine(alloc: Allocator, deps: RunDeps, snapshot: output_contracts.StatusSnapshot) !void {
    var buf: [1024]u8 = undefined;
    try writeRenderedJsonLine(alloc, deps, buf[0..], .{ .status = snapshot });
}

fn statusSnapshotFromStartup(startup: app_lifecycle.StartupStatus) output_contracts.StatusSnapshot {
    return statusSnapshotFromStartupWithBuild(startup, .{
        .channel = .stable,
        .version = "",
        .revision = "",
    });
}

fn statusSnapshotFromStartupWithBuild(
    startup: app_lifecycle.StartupStatus,
    build: update_target.CurrentBuild,
) output_contracts.StatusSnapshot {
    return .{
        .model = startup.selected_model,
        .model_origin = startup.model_origin.label(),
        .provider = startup.provider,
        .auth = startup.auth,
        .auth_help = startup.auth.missingHelp(.cli),
        .permission_mode = permissionModeForSnapshot(startup.permission_mode),
        .workspace_root = startup.workspace_root,
        .history_turns = 0,
        .session_permission_grants = 0,
        .agent_step_limit = startup.agent_step_limit,
        .update_channel = startup.update_channel.label(),
        .build_channel = build.channel.label(),
        .build_revision = build.revision,
    };
}

fn writeDoctorJsonLine(alloc: Allocator, deps: RunDeps, snapshot: output_contracts.DoctorSnapshot) !void {
    var buf: [4096]u8 = undefined;
    try writeRenderedJsonLine(alloc, deps, buf[0..], .{ .doctor = snapshot });
}

fn doctorSnapshotFromRuntime(snapshot: doctor_runtime.Snapshot) output_contracts.DoctorSnapshot {
    return .{
        .workspace_root = snapshot.workspace_root,
        .model = snapshot.model,
        .provider = snapshot.provider,
        .auth = snapshot.auth,
        .permission_mode = permissionModeForSnapshot(snapshot.permission_mode),
        .agent_step_limit = snapshot.agent_step_limit,
        .checks = snapshot.checks,
    };
}

fn writeRealStdout(_: ?*anyopaque, text: []const u8) !void {
    if (comptime builtin.os.tag != .windows) {
        return writeFdAll(std.posix.STDOUT_FILENO, text);
    }
    try std.Io.File.stdout().writeStreamingAll(io_mod.getIo(), text);
}

fn writeRealStderr(_: ?*anyopaque, text: []const u8) !void {
    if (comptime builtin.os.tag != .windows) {
        return writeFdAll(std.posix.STDERR_FILENO, text);
    }
    try std.Io.File.stderr().writeStreamingAll(io_mod.getIo(), text);
}

fn writeFdAll(fd: std.posix.fd_t, text: []const u8) !void {
    @setRuntimeSafety(false);
    var remaining = text;
    while (remaining.len > 0) {
        const written = std.c.write(fd, remaining.ptr, remaining.len);
        if (written <= 0) return error.WriteFailed;
        remaining = remaining[@intCast(written)..];
    }
}

fn getenvDefault(_: ?*anyopaque, key: []const u8) ?[]const u8 {
    return io_mod.getenv(key);
}

fn environMapDefault(_: ?*anyopaque) ?*const std.process.Environ.Map {
    return io_mod.environMap();
}

fn writeTopLevelUsage(command_catalog: CommandCatalog, deps: RunDeps, kind: TopLevelKind) !void {
    try writeStderr(deps, "usage: fx ");
    try writeStderr(deps, command_specs.topLevelUsage(command_catalog, kind));
    try writeStderr(deps, "\n");
}

fn writeUsageOrJsonError(
    alloc: Allocator,
    command_catalog: CommandCatalog,
    deps: RunDeps,
    usage_kind: TopLevelKind,
    output_kind: []const u8,
    err: anyerror,
    args: anytype,
) !void {
    if (argsContainJson(args)) {
        try writeCommandFailure(alloc, deps, output_kind, err, .json);
    } else {
        try writeTopLevelUsage(command_catalog, deps, usage_kind);
    }
}

fn writeUsageCommandFailure(
    alloc: Allocator,
    deps: RunDeps,
    err: anyerror,
    format: output_contracts.OutputFormat,
) !void {
    const message = usageFailureMessage(err);
    if (format == .json) {
        return writeJsonCommandFailure(
            alloc,
            deps,
            "usage",
            err,
            message,
        );
    }
    try writeStderr(deps, "fx usage: ");
    try writeStderr(deps, message);
    try writeStderr(deps, "\n");
}

fn usageFailureMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.HomeNotSet => "HOME is not set",
        error.DurablePathUnsafe,
        error.PrivateStatePermissionsUnsupported,
        => "local usage storage is unsafe",
        else => "local usage data is unavailable",
    };
}

fn writeWorkspaceCommandError(
    alloc: Allocator,
    command_catalog: CommandCatalog,
    deps: RunDeps,
    args: []const [:0]const u8,
    err: anyerror,
) !void {
    if (!argsContainJson(args)) {
        if (output_contracts.workspaceErrorMessage(err)) |message| {
            try writeStderr(deps, "fx workspace: ");
            try writeStderr(deps, message);
            try writeStderr(deps, "\n");
            return;
        }
        try writeTopLevelUsage(command_catalog, deps, .workspace);
        return;
    }

    const message = output_contracts.workspaceErrorMessage(err) orelse "invalid arguments";
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll("{\"kind\":\"workspace\",\"error\":");
    try std.json.Stringify.value(message, .{}, &out.writer);
    try out.writer.writeAll(",\"code\":");
    try std.json.Stringify.value(@errorName(err), .{}, &out.writer);
    try out.writer.writeByte('}');
    try writeJsonLine(deps, out.writer.buffered());
}

fn writeWorkspaceIndeterminateError(
    alloc: Allocator,
    deps: RunDeps,
    args: []const [:0]const u8,
    reconciliation: workspace_commands.Reconciliation,
) !void {
    const message = switch (reconciliation) {
        .intended => "settings durability is uncertain; reloaded settings match the requested update",
        .previous => "settings durability is uncertain; reloaded settings match the previous state, so the update was not applied",
        .unconfirmed => "settings durability is uncertain; reloaded settings match neither the requested nor previous state",
    };
    if (!argsContainJson(args)) {
        try writeStderr(deps, "fx workspace: ");
        try writeStderr(deps, message);
        try writeStderr(deps, "\n");
        return;
    }

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll("{\"kind\":\"workspace\",\"error\":");
    try std.json.Stringify.value(message, .{}, &out.writer);
    try out.writer.writeAll(",\"code\":\"SettingsCommitIndeterminate\"}");
    try writeJsonLine(deps, out.writer.buffered());
}

fn argsContainJson(args: anytype) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--json")) return true;
    }
    return false;
}

fn workflowLanguagePlaceholder() types.ConversationLanguage {
    return types.ConversationLanguage.default();
}

fn permissionModeForSnapshot(mode: anytype) types.PermissionMode {
    _ = mode;
    return .yolo;
}

fn permissionModeLabel(mode: anytype) []const u8 {
    _ = mode;
    return "yolo";
}

fn permissionRulesForSnapshot(alloc: Allocator, active_rules: anytype) !types.PermissionRuleSet {
    if (active_rules.rules.len == 0) return .{};
    const rules = try alloc.alloc(types.PermissionRule, active_rules.rules.len);
    for (active_rules.rules, 0..) |rule, i| {
        rules[i] = .{
            .permission = rule.permission,
            .pattern = rule.pattern,
            .action = switch (rule.action) {
                .allow => .allow,
                .ask => .ask,
                .deny => .deny,
            },
        };
    }
    return .{ .rules = rules };
}

fn catalogFailureDetail(failure: model_catalog.Failure) []const u8 {
    return switch (failure.category) {
        .authentication => "AuthenticationRejected",
        .cancellation => "the request was cancelled",
        .malformed_response => "MalformedResponse",
        .resource_exhausted => "OutOfMemory",
        .rate_limited, .gateway_unavailable, .transport, .http_status, .runtime => "Unavailable",
    };
}

fn writeCommandFailure(
    alloc: Allocator,
    deps: RunDeps,
    kind: []const u8,
    err: anyerror,
    format: output_contracts.OutputFormat,
) !void {
    if (format != .json) return err;
    const message = commandFailureMessage(err) orelse return err;
    return writeJsonCommandFailure(alloc, deps, kind, err, message);
}

fn writeJsonCommandFailure(
    alloc: Allocator,
    deps: RunDeps,
    kind: []const u8,
    err: anyerror,
    message: []const u8,
) !void {
    return writeJsonCommandFailureCode(
        alloc,
        deps,
        kind,
        @errorName(err),
        message,
    );
}

fn writeJsonCommandFailureCode(
    alloc: Allocator,
    deps: RunDeps,
    kind: []const u8,
    code: []const u8,
    message: []const u8,
) !void {
    const json = try (output_contracts.CommandFailureSnapshot{
        .kind = kind,
        .message = message,
        .code = code,
    }).renderJson(alloc);
    defer alloc.free(json);
    try writeJsonLine(deps, json);
}

fn writeLookupFailure(
    alloc: Allocator,
    deps: RunDeps,
    kind: []const u8,
    err: anyerror,
    format: output_contracts.OutputFormat,
) !void {
    if (format == .json) {
        return writeCommandFailure(alloc, deps, kind, err, format);
    }

    switch (err) {
        error.NoSavedSessions => {
            try writeStderr(deps, "fx session: no saved sessions for this workspace\n");
        },
        error.NoReadableSessions => {
            try writeStderr(deps, "fx session: saved sessions are unreadable; run `fx doctor` for recovery guidance\n");
        },
        error.SessionNotFound => {
            try writeStderr(deps, "fx session: record not found\n");
        },
        error.InvalidSessionFormat,
        error.InvalidPermissionState,
        error.PermissionStateTooLarge,
        error.InvalidRecoveryCheckpoint,
        error.InvalidUsageSidecar,
        => {
            try writeStderr(
                deps,
                "fx session: record is corrupt; run `fx doctor` for recovery guidance\n",
            );
        },
        error.UnsupportedSessionSchema => {
            try writeStderr(
                deps,
                "fx session: record uses an unsupported session version\n",
            );
        },
        error.InvalidSessionId => {
            try writeStderr(deps, "fx session: invalid session id\n");
        },
        error.LegacySessionTooLarge => {
            try writeStderr(
                deps,
                "fx session: legacy session is too large for automatic loading; run `fx session migrate <id> --allow-large`\n",
            );
        },
        error.LegacySessionReadResourceExhausted => {
            try writeStderr(
                deps,
                "fx session: legacy session could not be loaded with available resources\n",
            );
        },
        error.LegacySessionMigrationResourceExhausted => {
            try writeStderr(
                deps,
                "fx session: migration did not complete because resources were exhausted; the original session remains authoritative\n",
            );
        },
        error.LegacySessionMigrationFailed, error.LegacySessionChanged => {
            try writeStderr(
                deps,
                "fx session: migration did not complete; the original session remains authoritative\n",
            );
        },
        error.LegacySessionMigrationIndeterminate => {
            try writeStderr(
                deps,
                "fx session: migration outcome is indeterminate and will be resolved by the next exact writable load\n",
            );
        },
        error.SessionRecoveryNotNeeded => {
            try writeStderr(
                deps,
                "fx session: recovery was refused because the session has a valid commit boundary; resume it normally\n",
            );
        },
        error.SessionRecoveryRequiresCurrentSchema => {
            try writeStderr(
                deps,
                "fx session: recovery supports conversation logs and schema-v3 event logs; migrate snapshot sessions first\n",
            );
        },
        error.SessionRecoveryUnsupportedSchema => {
            try writeStderr(
                deps,
                "fx session: recovery is unavailable for this unsupported session version\n",
            );
        },
        error.SessionRecoveryBoundaryInvalid => {
            try writeStderr(
                deps,
                "fx session: no exact trustworthy recovery boundary was found; the source was left unchanged\n",
            );
        },
        error.SessionRecoveryIndeterminate => {
            try writeStderr(
                deps,
                "fx session: the recovery copy could not be confirmed; the source was left unchanged\n",
            );
        },
        error.SessionAuthorityBoundaryUnavailable,
        error.SessionCommitBoundaryUnavailable,
        => {
            try writeStderr(
                deps,
                "fx session: session authority is temporarily unavailable while an incomplete commit is resolved\n",
            );
        },
        error.SessionAuthorityIntentCleanupPending => {
            try writeStderr(
                deps,
                "fx session: session authority is confirmed but transition cleanup is still pending\n",
            );
        },
        error.SessionBusy, error.SessionLockUnsupported => {
            try writeStderr(
                deps,
                "fx session: session is busy or the filesystem cannot provide the required lock\n",
            );
        },
        error.SessionPathUnsafe,
        error.DurablePathUnsafe,
        error.PrivateStatePermissionsUnsupported,
        => {
            try writeStderr(
                deps,
                "fx session: durable session storage is unsafe or does not support required private permissions\n",
            );
        },
        error.DurableLayoutFailed, error.SessionStoreUnavailable => {
            try writeStderr(deps, "fx session: durable session store is unavailable\n");
        },
        error.HomeNotSet => {
            try writeStderr(deps, "fx ");
            try writeStderr(deps, kind);
            try writeStderr(deps, ": HOME is not set\n");
        },
        else => return err,
    }
}

fn writeSessionDetailFailure(
    alloc: Allocator,
    deps: RunDeps,
    session_id: []const u8,
    err: anyerror,
    format: output_contracts.OutputFormat,
) !void {
    const message = switch (err) {
        error.InvalidSessionFormat => try std.fmt.allocPrint(
            alloc,
            "session {s} is corrupt; run `fx session recover {s}`",
            .{ session_id, session_id },
        ),
        error.UnsupportedSessionSchema => try std.fmt.allocPrint(
            alloc,
            "session {s} uses an unsupported session version",
            .{session_id},
        ),
        else => return writeLookupFailure(
            alloc,
            deps,
            "session",
            err,
            format,
        ),
    };
    defer alloc.free(message);
    if (format == .json) {
        return writeJsonCommandFailure(
            alloc,
            deps,
            "session",
            err,
            message,
        );
    }
    try writeStderr(deps, "fx session: ");
    try writeStderr(deps, message);
    try writeStderr(deps, "\n");
}

fn commandFailureMessage(err: anyerror) ?[]const u8 {
    if (lookupFailureMessage(err)) |message| return message;
    return switch (err) {
        error.InvalidLocalSurfaceArgs,
        error.InvalidUsageArgs,
        error.InvalidSessionDetailArgs,
        error.InvalidSessionMigrationArgs,
        error.InvalidSessionRecoveryArgs,
        error.InvalidResumeArgs,
        => "invalid arguments",
        else => null,
    };
}

fn lookupFailureMessage(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.NoSavedSessions => "no saved sessions for this workspace",
        error.NoReadableSessions => "saved sessions are unreadable; run `fx doctor` for recovery guidance",
        error.SessionNotFound => "record not found",
        error.InvalidSessionFormat,
        error.InvalidPermissionState,
        error.PermissionStateTooLarge,
        error.InvalidRecoveryCheckpoint,
        error.InvalidUsageSidecar,
        => "record is corrupt; run `fx doctor` for recovery guidance",
        error.UnsupportedSessionSchema => "record uses an unsupported session version",
        error.InvalidSessionId => "invalid session id",
        error.LegacySessionTooLarge => "legacy session is too large for automatic loading; run `fx session migrate <id> --allow-large`",
        error.LegacySessionReadResourceExhausted => "legacy session could not be loaded with available resources",
        error.LegacySessionMigrationResourceExhausted => "migration did not complete because resources were exhausted; the original session remains authoritative",
        error.LegacySessionMigrationFailed, error.LegacySessionChanged => "migration did not complete; the original session remains authoritative",
        error.LegacySessionMigrationIndeterminate => "migration outcome is indeterminate and will be resolved by the next exact writable load",
        error.SessionRecoveryNotNeeded => "recovery was refused because the session has a valid commit boundary; resume it normally",
        error.SessionRecoveryRequiresCurrentSchema => "recovery supports conversation logs and schema-v3 event logs; migrate snapshot sessions first",
        error.SessionRecoveryUnsupportedSchema => "recovery is unavailable for this unsupported session version",
        error.SessionRecoveryBoundaryInvalid => "no exact trustworthy recovery boundary was found; the source was left unchanged",
        error.SessionRecoveryIndeterminate => "the recovery copy could not be confirmed; the source was left unchanged",
        error.SessionAuthorityBoundaryUnavailable,
        error.SessionCommitBoundaryUnavailable,
        => "session authority is temporarily unavailable while an incomplete commit is resolved",
        error.SessionAuthorityIntentCleanupPending => "session authority is confirmed but transition cleanup is still pending",
        error.SessionBusy, error.SessionLockUnsupported => "session is busy or the filesystem cannot provide the required lock",
        error.SessionPathUnsafe,
        error.DurablePathUnsafe,
        error.PrivateStatePermissionsUnsupported,
        => "durable session storage is unsafe or does not support required private permissions",
        error.DurableLayoutFailed, error.SessionStoreUnavailable => "durable session store is unavailable",
        error.HomeNotSet => "HOME is not set",
        else => null,
    };
}

fn workflowConfig(cfg: Config) @import("one_shot.zig").Config {
    return .{
        .auth_mode = cfg.auth_mode,
        .default_model = cfg.default_model,
        .default_agent_step_limit = cfg.default_agent_step_limit,
        .gateway_retry_count = cfg.gateway_retry_count,
        .gateway_chat_url = cfg.gateway_provider.chat_url.resolve(cfg.gateway_chat_url),
        .gateway_models_path = cfg.models_path,
        .gateway_provider = cfg.gateway_provider,
        .provider_set = cfg.provider_set,
        .process_provider = cfg.process_provider,
        .secret_store = cfg.secret_store,
        .prompt_policy = cfg.prompt_policy,
        .skill_root_policy = cfg.skill_root_policy,
        .ignored_list_entries = cfg.ignored_list_entries,
        .max_list_entries = cfg.max_list_entries,
        .max_read_file_bytes = cfg.max_read_file_bytes,
        .max_read_file_lines = cfg.max_read_file_lines,
        .max_read_file_line_len = cfg.max_read_file_line_len,
        .max_command_output_bytes = cfg.max_command_output_bytes,
        .max_tool_result_bytes = cfg.max_tool_result_bytes,
        .max_history_turns = cfg.max_history_turns,
        .mode_registry = cfg.mode_registry,
    };
}

fn workflowConfigWithLaunchModifiers(
    cfg: Config,
    modifiers: LaunchModifiers,
) @import("one_shot.zig").Config {
    var result = workflowConfig(cfg);
    result.context_limit_overrides = modifiers.context_limit_overrides;
    result.additional_directories = modifiers.additional_directories;
    result.saved_directories_suppressed = modifiers.saved_directories_suppressed;
    return result;
}

fn commandSupportsWorkspaceModifiers(command: Command) bool {
    return switch (command) {
        .interactive, .pr, .issue, .resume_session => true,
        else => false,
    };
}

fn writeWorkspaceModifierUsage(deps: RunDeps) !void {
    try writeStderr(
        deps,
        "fx: --add-dir and --no-additional-dirs are only supported for interactive, resume, ask, PR, and issue launches\n",
    );
}

fn writeModelModifierUsage(deps: RunDeps) !void {
    try writeStderr(
        deps,
        "fx: --provider, --model, --effort, --fast, --provider-order, and --provider-strict apply to interactive sessions\n",
    );
}

fn globalLaunchErrorMessage(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.MissingAddDirectoryValue => "--add-dir requires a directory path",
        error.DuplicateAdditionalDirectorySuppression => "--no-additional-dirs may only be specified once",
        error.MissingModelValue => "--model requires a model id",
        error.MissingEffortValue => "--effort requires a value",
        error.InvalidEffortValue => "--effort value is not a valid reasoning effort",
        error.ConflictingFastFlags => "--fast and --no-fast cannot be used together",
        error.MissingProviderValue => "--provider requires a provider name",
        error.InvalidProviderValue => "--provider accepts openrouter or a configured provider name",
        error.MissingProviderOrderValue => "--provider-order requires a comma-separated provider list",
        error.InvalidProviderOrderValue => "--provider-order accepts comma-separated provider slugs (letters, digits, '-')",
        error.ConflictingProviderStrictFlags => "--provider-strict and --no-provider-strict cannot be used together",
        else => null,
    };
}

fn parseLocalSurfaceArgs(args: []const [:0]const u8) !LocalSurfaceOptions {
    var options = LocalSurfaceOptions{};
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            options.format = .json;
            continue;
        }
        return error.InvalidLocalSurfaceArgs;
    }
    return options;
}

fn parseUpgradeArgs(args: []const [:0]const u8) !UpgradeOptions {
    var options = UpgradeOptions{};
    var format_seen = false;
    var channel_seen = false;
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--json")) {
            if (format_seen) return error.InvalidUpgradeArgs;
            format_seen = true;
            options.format = .json;
            continue;
        }
        if (std.mem.eql(u8, arg, "--channel")) {
            if (channel_seen or index + 1 >= args.len) return error.InvalidUpgradeArgs;
            channel_seen = true;
            index += 1;
            options.channel = update_target.Channel.parse(args[index]) orelse
                return error.InvalidUpgradeArgs;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--channel=")) {
            if (channel_seen) return error.InvalidUpgradeArgs;
            channel_seen = true;
            options.channel = update_target.Channel.parse(arg["--channel=".len..]) orelse
                return error.InvalidUpgradeArgs;
            continue;
        }
        return error.InvalidUpgradeArgs;
    }
    return options;
}

fn parseSessionListArgs(args: []const [:0]const u8) !SessionListOptions {
    var options = SessionListOptions{};
    var format_seen = false;
    var limit_seen = false;
    var cursor_seen = false;
    var scope_seen = false;
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--json")) {
            if (format_seen) return error.InvalidLocalSurfaceArgs;
            format_seen = true;
            options.format = .json;
            continue;
        }
        if (std.mem.eql(u8, arg, "--all")) {
            if (scope_seen) return error.InvalidLocalSurfaceArgs;
            scope_seen = true;
            options.scope = .all_workspaces;
            continue;
        }
        if (std.mem.eql(u8, arg, "--limit")) {
            if (limit_seen or index + 1 >= args.len) return error.InvalidLocalSurfaceArgs;
            limit_seen = true;
            index += 1;
            options.limit = std.fmt.parseUnsigned(usize, args[index], 10) catch
                return error.InvalidLocalSurfaceArgs;
            if (options.limit == 0 or
                options.limit > session_store.session_list_max_limit)
            {
                return error.InvalidLocalSurfaceArgs;
            }
            continue;
        }
        if (std.mem.eql(u8, arg, "--cursor")) {
            if (cursor_seen or index + 1 >= args.len) return error.InvalidLocalSurfaceArgs;
            cursor_seen = true;
            index += 1;
            options.continuation = try parseSessionListCursor(args[index]);
            continue;
        }
        return error.InvalidLocalSurfaceArgs;
    }
    return options;
}

fn parseUsageArgs(args: []const [:0]const u8) !UsageOptions {
    var options = UsageOptions{};
    var period_seen = false;
    var json_seen = false;
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--json")) {
            if (json_seen) return error.InvalidUsageArgs;
            json_seen = true;
            options.format = .json;
            continue;
        }
        if (std.mem.eql(u8, arg, "--period")) {
            if (period_seen or index + 1 >= args.len) return error.InvalidUsageArgs;
            period_seen = true;
            index += 1;
            options.scope = if (std.mem.eql(u8, args[index], "24h"))
                .hours_24
            else if (std.mem.eql(u8, args[index], "7d"))
                .days_7
            else if (std.mem.eql(u8, args[index], "30d"))
                .days_30
            else
                return error.InvalidUsageArgs;
            continue;
        }
        return error.InvalidUsageArgs;
    }
    return options;
}

fn parseSessionListCursor(raw: []const u8) !session_store.ResumableSessionContinuation {
    if (raw.len == 0 or raw.len > 320) return error.InvalidLocalSurfaceArgs;
    var fields = std.mem.splitScalar(u8, raw, ':');
    if (!std.mem.eql(u8, fields.next() orelse return error.InvalidLocalSurfaceArgs, "v1")) {
        return error.InvalidLocalSurfaceArgs;
    }
    const updated_text = fields.next() orelse return error.InvalidLocalSurfaceArgs;
    const id = fields.next() orelse return error.InvalidLocalSurfaceArgs;
    if (fields.next() != null) return error.InvalidLocalSurfaceArgs;
    session_store.validateSessionId(id) catch return error.InvalidLocalSurfaceArgs;
    const updated_at_ms = std.fmt.parseInt(i64, updated_text, 10) catch
        return error.InvalidLocalSurfaceArgs;
    var canonical: [320]u8 = undefined;
    const encoded = std.fmt.bufPrint(
        &canonical,
        "v1:{d}:{s}",
        .{ updated_at_ms, id },
    ) catch return error.InvalidLocalSurfaceArgs;
    if (!std.mem.eql(u8, encoded, raw)) return error.InvalidLocalSurfaceArgs;
    return .{ .updated_at_ms = updated_at_ms, .id = id };
}

fn formatSessionListCursor(
    alloc: Allocator,
    summary: session_store.SessionSummary,
) ![]u8 {
    return std.fmt.allocPrint(
        alloc,
        "v1:{d}:{s}",
        .{ summary.updated_at_ms, summary.id },
    );
}

fn parseWorkspaceArgs(args: []const [:0]const u8) !WorkspaceOptions {
    var positional: [2][]const u8 = undefined;
    var positional_len: usize = 0;
    var options = WorkspaceOptions{};
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            if (options.format == .json) return error.InvalidWorkspaceArgs;
            options.format = .json;
            continue;
        }
        if (positional_len >= positional.len) return error.InvalidWorkspaceArgs;
        positional[positional_len] = arg;
        positional_len += 1;
    }

    if (positional_len == 0) return options;
    if (std.mem.eql(u8, positional[0], "list")) {
        if (positional_len != 1) return error.InvalidWorkspaceArgs;
        return options;
    }
    if (std.mem.eql(u8, positional[0], "clear")) {
        if (positional_len != 1) return error.InvalidWorkspaceArgs;
        options.action = .clear;
        return options;
    }
    if (std.mem.eql(u8, positional[0], "add")) {
        if (positional_len != 2 or positional[1].len == 0) return error.InvalidWorkspaceArgs;
        options.action = .{ .add = positional[1] };
        return options;
    }
    if (std.mem.eql(u8, positional[0], "remove")) {
        if (positional_len != 2 or positional[1].len == 0) return error.InvalidWorkspaceArgs;
        options.action = .{ .remove = positional[1] };
        return options;
    }
    return error.InvalidWorkspaceArgs;
}

fn parseSessionDetailArgs(
    alloc: Allocator,
    args: []const [:0]const u8,
) !SessionDetailOptions {
    var options = SessionDetailOptions{};
    errdefer options.deinit(alloc);
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--json")) {
            options.format = .json;
            continue;
        }
        if (options.target != null) return error.InvalidSessionDetailArgs;
        const exact_id = std.mem.eql(u8, arg, "--id");
        if (exact_id) {
            i += 1;
            if (i >= args.len) return error.InvalidSessionDetailArgs;
        }
        const trimmed = std.mem.trim(u8, args[i], " \t\r\n");
        if (trimmed.len == 0) return error.InvalidSessionDetailArgs;
        if (!exact_id and std.mem.eql(u8, trimmed, "last")) {
            options.target = .last;
            continue;
        }
        options.target = .{ .id = try alloc.dupe(u8, trimmed) };
    }
    return options;
}

fn parseSessionMigrationArgs(
    alloc: Allocator,
    args: []const [:0]const u8,
) !SessionMigrationOptions {
    var format: output_contracts.OutputFormat = .text;
    var allow_large = false;
    var session_id: ?[]u8 = null;
    errdefer if (session_id) |id| alloc.free(id);
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--json")) {
            format = .json;
            continue;
        }
        if (std.mem.eql(u8, arg, "--allow-large")) {
            allow_large = true;
            continue;
        }
        if (session_id != null) return error.InvalidSessionMigrationArgs;
        const exact_id = std.mem.eql(u8, arg, "--id");
        if (exact_id) {
            i += 1;
            if (i >= args.len) return error.InvalidSessionMigrationArgs;
        }
        const trimmed = std.mem.trim(u8, args[i], " \t\r\n");
        if (trimmed.len == 0) return error.InvalidSessionMigrationArgs;
        session_id = try alloc.dupe(u8, trimmed);
    }
    return .{
        .format = format,
        .session_id = session_id orelse return error.InvalidSessionMigrationArgs,
        .allow_large = allow_large,
    };
}

fn parseSessionRecoveryArgs(
    alloc: Allocator,
    args: []const [:0]const u8,
) !SessionRecoveryOptions {
    var format: output_contracts.OutputFormat = .text;
    var session_id: ?[]u8 = null;
    errdefer if (session_id) |id| alloc.free(id);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--json")) {
            format = .json;
            continue;
        }
        if (session_id != null) return error.InvalidSessionRecoveryArgs;
        const exact_id = std.mem.eql(u8, arg, "--id");
        if (exact_id) {
            i += 1;
            if (i >= args.len) return error.InvalidSessionRecoveryArgs;
        }
        const trimmed = std.mem.trim(u8, args[i], " \t\r\n");
        if (trimmed.len == 0) return error.InvalidSessionRecoveryArgs;
        session_id = try alloc.dupe(u8, trimmed);
    }
    return .{
        .format = format,
        .session_id = session_id orelse return error.InvalidSessionRecoveryArgs,
    };
}

fn parseResumeArgs(
    alloc: Allocator,
    command_catalog: CommandCatalog,
    args: []const [:0]const u8,
    top_level_alias: bool,
) !ResumeTarget {
    if (args.len == 0) return .last;

    if (top_level_alias) {
        if (std.mem.eql(u8, args[0], "--resume")) {
            if (args.len == 1) return .last;
            if (args.len != 2) return error.InvalidResumeArgs;
            const id = std.mem.trim(u8, args[1], " \t\r\n");
            if (id.len == 0) return error.InvalidResumeArgs;
            if (std.mem.eql(u8, id, "last")) return .last;
            return .{ .id = try alloc.dupe(u8, id) };
        }
        if (args.len != 1) return error.InvalidResumeArgs;
        if (std.mem.eql(u8, args[0], resume_picker_alias)) return .pick;
        if (std.mem.eql(u8, args[0], "-c") or std.mem.eql(u8, args[0], "--continue")) return .remembered;
        if (command_specs.matchesTopLevel(command_catalog, args[0], .@"resume")) return .last;
        if (!std.mem.startsWith(u8, args[0], resume_id_alias_prefix)) return error.InvalidResumeArgs;
        const id = args[0][resume_id_alias_prefix.len..];
        if (id.len == 0) return error.InvalidResumeArgs;
        return .{ .id = try alloc.dupe(u8, id) };
    }

    if (std.mem.eql(u8, args[0], "--resume")) {
        if (args.len == 2 and std.mem.eql(u8, args[1], "--last")) return .last;
        return error.InvalidResumeArgs;
    }

    const exact_id = std.mem.eql(u8, args[0], "--id");
    const operand_index: usize = if (exact_id) 1 else 0;
    if (args.len != operand_index + 1) return error.InvalidResumeArgs;

    const trimmed = std.mem.trim(u8, args[operand_index], " \t\r\n");
    if (trimmed.len == 0) return error.InvalidResumeArgs;
    if (!exact_id and std.mem.eql(u8, trimmed, "last")) return .last;
    return .{ .id = try alloc.dupe(u8, trimmed) };
}

fn parseWorkflowArgs(alloc: Allocator, args: []const [:0]const u8) !WorkflowOptions {
    var auto_permission = false;
    var create = false;
    var start_index: usize = 0;
    while (start_index < args.len) : (start_index += 1) {
        if (std.mem.eql(u8, args[start_index], "--auto")) {
            auto_permission = true;
            continue;
        }
        if (std.mem.eql(u8, args[start_index], "--create")) {
            create = true;
            continue;
        }
        break;
    }

    return .{
        .auto_permission = auto_permission,
        .create = create,
        .context = try joinArgs(alloc, args[start_index..]),
    };
}

fn joinArgs(alloc: Allocator, args: []const [:0]const u8) ![]u8 {
    if (args.len == 0) return alloc.dupe(u8, "");

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    for (args, 0..) |arg, i| {
        if (i > 0) try out.writer.writeByte(' ');
        try out.writer.writeAll(arg);
    }
    return try out.toOwnedSlice();
}

fn isVersionFlag(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v");
}

fn testCommandCatalog() CommandCatalog {
    const builtin_commands = @import("../../builtins/commands.zig");
    return builtin_commands.top_level_registry;
}

const CaptureOutput = struct {
    stdout: std.Io.Writer.Allocating,
    stderr: std.Io.Writer.Allocating,
    setup_store_calls: usize = 0,
    setup_read_calls: usize = 0,
    setup_value_matched: bool = false,
    setup_interactive_store: bool = false,
    setup_store_disabled: bool = false,

    fn init(alloc: Allocator) CaptureOutput {
        return .{
            .stdout = .init(alloc),
            .stderr = .init(alloc),
        };
    }

    fn deinit(self: *@This()) void {
        self.stdout.deinit();
        self.stderr.deinit();
    }

    fn deps(self: *@This()) RunDeps {
        return .{
            .stdout_ctx = self,
            .stderr_ctx = self,
            .setup_ctx = self,
            .write_stdout = captureStdout,
            .write_stderr = captureStderr,
            .read_masked_key = captureReadMaskedKey,
            .setup_terminal_available = captureSetupTerminalAvailable,
        };
    }

    fn secretStore(self: *@This()) host.SecretStore {
        return .{
            .context = self,
            .backend_label = "test credential store",
            .is_disabled_fn = captureSecretStoreIsDisabled,
            .load_fn = captureSecretStoreLoad,
            .store_fn = captureSecretStoreWrite,
            .store_interactive_fn = captureSecretStoreInteractiveWrite,
        };
    }
};

fn captureStdout(ctx: ?*anyopaque, text: []const u8) !void {
    const capture: *CaptureOutput = @ptrCast(@alignCast(ctx.?));
    try capture.stdout.writer.writeAll(text);
}

fn captureStderr(ctx: ?*anyopaque, text: []const u8) !void {
    const capture: *CaptureOutput = @ptrCast(@alignCast(ctx.?));
    try capture.stderr.writer.writeAll(text);
}

fn captureSetupTerminalAvailable(_: ?*anyopaque) bool {
    return true;
}

fn captureReadMaskedKey(
    ctx: ?*anyopaque,
    alloc: Allocator,
    _: WriteFn,
    _: ?*anyopaque,
) ![]u8 {
    const capture: *CaptureOutput = @ptrCast(@alignCast(ctx.?));
    capture.setup_read_calls += 1;
    return alloc.dupe(u8, "paste-only-test-key");
}

fn captureSecretStoreIsDisabled(ctx: ?*anyopaque) bool {
    const capture: *CaptureOutput = @ptrCast(@alignCast(ctx.?));
    return capture.setup_store_disabled;
}

fn captureSecretStoreLoad(
    _: ?*anyopaque,
    _: Allocator,
    _: host.SecretSlot,
) host.SecretStoreLoadError!?[]u8 {
    return null;
}

fn captureSecretStoreWrite(
    ctx: ?*anyopaque,
    _: Allocator,
    _: host.SecretSlot,
    value: []const u8,
) host.SecretStoreWriteError!void {
    const capture: *CaptureOutput = @ptrCast(@alignCast(ctx.?));
    capture.setup_store_calls += 1;
    capture.setup_value_matched = std.mem.eql(u8, value, "paste-only-test-key");
}

fn captureSecretStoreInteractiveWrite(
    ctx: ?*anyopaque,
    _: host.SecretSlot,
) host.SecretStoreWriteError!bool {
    const capture: *CaptureOutput = @ptrCast(@alignCast(ctx.?));
    if (!capture.setup_interactive_store) return false;
    capture.setup_store_calls += 1;
    return true;
}

fn gatherNoopContextForTest(_: Allocator, _: context_contract.InitialContextInput) context_contract.ProviderError!context_contract.ProviderContext {
    return .{};
}

fn appendNoopStaticContextForTest(_: context_contract.StaticContextInput, _: Allocator, _: *std.ArrayList(types.ChatMessage)) context_contract.ProviderError!void {}

fn appendNoopTransientContextForTest(_: context_contract.TransientContextInput, _: Allocator, _: *std.ArrayList(types.ChatMessage)) context_contract.ProviderError!void {}

const test_surface_context_registry = context_contract.Registry{ .default_provider = .{
    .id = "test.surface_context",
    .gather_project_context_fn = gatherNoopContextForTest,
    .select_applicable_project_context_fn = context_contract.selectNoApplicableProjectContext,
    .append_static_fn = appendNoopStaticContextForTest,
    .append_transient_fn = appendNoopTransientContextForTest,
} };

var stable_cli_test_environ: ?*std.process.Environ.Map = null;

fn stableCliTestEnviron() !*const std.process.Environ.Map {
    if (stable_cli_test_environ) |map| return map;

    const alloc = std.heap.page_allocator;
    const map = try alloc.create(std.process.Environ.Map);
    map.* = std.process.Environ.Map.init(alloc);
    stable_cli_test_environ = map;
    return map;
}

fn testSurfaceChatUrlResolve(_: ?*anyopaque, fallback: []const u8) []const u8 {
    return fallback;
}

fn testConfig() Config {
    return .{
        .version = "0.0.0",
        .command_catalog = testCommandCatalog(),
        .default_model = "test-model",
        .default_agent_step_limit = 42,
        .models_path = "/v1/models",
        .gateway_retry_count = 1,
        .gateway_chat_url = "https://example.test/chat",
        .gateway_provider = .{ .chat_url = .{ .resolve_fn = testSurfaceChatUrlResolve } },
        .provider_set = provider_set.openrouter_only(test_openrouter.provider_bundle),
        .url_opener = host.unavailable_url_opener,
        .secret_store = host.unavailable_secret_store,
        .prompt_policy = .{ .system_prompt = "system" },
        .skill_root_policy = .{ .managed_root_source = .global_fx },
        .ignored_list_entries = &.{},
        .max_list_entries = 10,
        .max_read_file_bytes = 1024,
        .max_read_file_lines = 100,
        .max_read_file_line_len = 200,
        .max_command_output_bytes = 4096,
        .max_tool_result_bytes = 4096,
        .max_history_turns = 8,
        .context_registry = test_surface_context_registry,
        .mode_registry = .{ .default_mode_id = "surface" },
        .tool_set = .{
            .registry = .{ .tools = &.{} },
            .order = &.{},
            .read_only_tool_names = &.{},
        },
    };
}

fn stubLoadStartupState(
    alloc: Allocator,
    _: host.SecretStore,
    default_model: []const u8,
    default_agent_step_limit: usize,
) !app_lifecycle.StartupState {
    var state = app_lifecycle.StartupState{ .agent_step_limit = default_agent_step_limit };
    errdefer state.deinit(alloc);
    state.workspace_root = try alloc.dupe(u8, "/tmp/fx");
    state.selected_model = try alloc.dupe(u8, default_model);
    state.credential = .{
        .token = try alloc.dupe(u8, "test-key"),
        .source = .openrouter_api_key,
    };
    return state;
}

fn stubLoadStartupStateWithoutCredentials(
    alloc: Allocator,
    _: []const u8,
    default_agent_step_limit: usize,
) !app_lifecycle.StartupState {
    var state = app_lifecycle.StartupState{
        .agent_step_limit = default_agent_step_limit,
    };
    errdefer state.deinit(alloc);
    state.workspace_root = try alloc.dupe(u8, "/tmp/fx");
    return state;
}

fn failingStartupStateWithoutCredentials(
    _: Allocator,
    _: []const u8,
    _: usize,
) !app_lifecycle.StartupState {
    return error.StartupShouldNotRun;
}

fn stubLoadStartupStatus(
    alloc: Allocator,
    _: host.SecretStore,
    default_model: []const u8,
    default_agent_step_limit: usize,
) !app_lifecycle.StartupStatus {
    const workspace_root = try alloc.dupe(u8, "/tmp/fx");
    errdefer alloc.free(workspace_root);
    const selected_model = try alloc.dupe(u8, default_model);
    errdefer alloc.free(selected_model);
    return .{
        .workspace_root = workspace_root,
        .selected_model = selected_model,
        .owned_selected_model = selected_model,
        .permission_mode = config_runtime.default_permission_mode,
        .agent_step_limit = default_agent_step_limit,
    };
}

fn failingStartupState(
    _: Allocator,
    _: host.SecretStore,
    _: []const u8,
    _: usize,
) !app_lifecycle.StartupState {
    return error.StartupShouldNotRun;
}

const ModelFetchProbe = struct {
    const Outcome = enum {
        success,
        failure,
        cancelled,
    };

    called: bool = false,
    outcome: Outcome = .success,

    fn provider(self: *ModelFetchProbe) gateway_provider.CliModelCatalogProvider {
        return .{
            .context = self,
            .fetch_fn = fetch,
        };
    }

    fn failure(
        input: gateway_provider.CliModelCatalogInput,
        category: model_catalog.FailureCategory,
    ) gateway_provider.CliModelCatalogResult {
        return .{ .failure = .{
            .access = .init(input.access),
            .anonymous_fallback_used = false,
            .failure = .{ .category = category },
        } };
    }

    fn fetch(
        raw: ?*anyopaque,
        alloc: Allocator,
        input: gateway_provider.CliModelCatalogInput,
    ) gateway_provider.CliModelCatalogResult {
        const self: *ModelFetchProbe = @ptrCast(@alignCast(raw.?));
        self.called = true;
        if (!std.mem.eql(u8, input.access.authorizationCredential() orelse "", "test-key") or
            !std.mem.eql(u8, input.access.teamContext() orelse "", "team_123") or
            input.access.credentialSource() != .openrouter_api_key or
            !std.mem.eql(u8, input.endpoint, "/v1/models") or
            input.cancel_flag != null)
        {
            return failure(input, .runtime);
        }

        switch (self.outcome) {
            .failure => return failure(input, .runtime),
            .cancelled => return failure(input, .cancellation),
            .success => {},
        }

        var ids: std.ArrayList([]u8) = .empty;
        const id = alloc.dupe(u8, "private/blue-hornbill") catch {
            return failure(input, .resource_exhausted);
        };
        ids.append(alloc, id) catch {
            alloc.free(id);
            return failure(input, .resource_exhausted);
        };
        return .{ .loaded = .{
            .ids = ids,
            .provenance = .{ .access = .init(input.access) },
        } };
    }
};

const ChatUrlProbe = struct {
    called: bool = false,

    fn provider(self: *ChatUrlProbe) gateway_provider.ChatUrlProvider {
        return .{
            .context = self,
            .resolve_fn = resolve,
        };
    }

    fn resolve(raw: ?*anyopaque, fallback: []const u8) []const u8 {
        const self: *ChatUrlProbe = @ptrCast(@alignCast(raw.?));
        self.called = std.mem.eql(u8, fallback, "https://example.test/chat");
        return "http://127.0.0.1:43123/chat";
    }
};
