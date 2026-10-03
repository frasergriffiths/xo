const std = @import("std");
const skill_contract = @import("../skills/skill_contract.zig");
const builtin = @import("builtin");
const agent_stream_provider = @import("../agent/stream_provider.zig");
const auth_runtime = @import("../auth/auth_runtime.zig");
const host_mod = @import("../hosts/host.zig");
const command_contract = @import("../execution/command_contract.zig");
const command_environment = @import("../execution/command_environment.zig");
const managed_execution = @import("../execution/managed_execution.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const diagnostics = @import("../workspace/diagnostics.zig");
const image_attachments = @import("../images/image_attachments.zig");
const io_mod = @import("../shared/io.zig");
const tool_contracts = @import("../agent/runtime/tool_contracts.zig");
const result_commit = @import("result_commit.zig");
const vision_executor = @import("../agent/runtime/vision_executor.zig");
const change_tracker = @import("../workspace/change_tracker.zig");
const diff_mod = @import("../output/diff.zig");
const file_mutation = @import("file_mutation.zig");
const file_mutation_contract = @import("file_mutation_contract.zig");
const hooks = @import("../hooks/hooks.zig");
const permission_auto_classifier = @import("../permissions/auto_classifier.zig");
const glob_pattern = @import("../workspace/glob_pattern.zig");
const permission_prompter = @import("../permissions/permission_prompter.zig");
const permission_request = @import("../permissions/permission_request.zig");
const command_admission = @import("../permissions/command_admission.zig");
const pathing = @import("../workspace/pathing.zig");
const execution_router = @import("../execution/router.zig");
const skill_runtime = @import("../skills/skill_runtime.zig");
const subagent_model_contract = @import("../subagent/model_contract.zig");
const subagent_tool_host = @import("../subagent/tool_host.zig");
const subagent_tool_provider = @import("../subagent/tool_provider.zig");
const session_runtime = @import("../session/session.zig");
const session_permission_state = @import("../permissions/session_permission_state.zig");
const session_child_store = @import("../session/session_child_store.zig");
const command_replay_store = @import("../session/command_replay_store.zig");
const session_store = @import("../session/session_store.zig");
const text_utils = @import("../shared/text_utils.zig");
const model_capabilities = @import("../config/model_capabilities.zig");

const tool_admission = @import("tool_admission.zig");
const tool_args = @import("tool_args.zig");
const command_result_mapping = @import("command_result_mapping.zig");
const tool_dispatch = @import("tool_dispatch.zig");
const tool_specs = @import("tool_specs.zig");
const tool_result_errors = @import("tool_result_errors.zig");
const tool_result_limits = @import("tool_result_limits.zig");
const file_mutation_execution = @import("file_mutation_execution.zig");

const capability_retrieval = @import("capability_retrieval.zig");

const tool_presentation = @import("tool_presentation.zig");
const shell_impl = @import("../../tools/shell/shell.zig");
const shell_resolver = @import("../terminal/shell_resolver.zig");
const web_fetch_runtime = @import("web_fetch_runtime.zig");
const web_search_contract = @import("web_search_contract.zig");
const web_fetch_artifacts = @import("../session/web_fetch_artifacts.zig");
const types = @import("../shared/types.zig");
const model_provider = @import("../config/model_provider.zig");
const provider_set = @import("../gateway/provider_set.zig");
const credential_authority = @import("../auth/credential_authority.zig");
const worker_runtime = @import("../agent/worker_runtime.zig");
const context_contract = @import("../workspace/context_contract.zig");
const test_builtin_tools = if (builtin.is_test)
    @import("../../builtins/tools.zig")
else
    struct {};
const test_openrouter = if (builtin.is_test)
    @import("../../gateway/openrouter_test_fixtures.zig")
else
    struct {};

const Allocator = std.mem.Allocator;
const ToolCall = types.ToolCall;
const ChatMessage = types.ChatMessage;

const PermissionGrant = types.PermissionGrant;
const PermissionMode = types.PermissionMode;
const ToolPermissionDecision = types.ToolPermissionDecision;
const ToolExecutionResult = tool_contracts.ToolExecutionResult;
const SessionRuntime = session_runtime.SessionRuntime;
const WorkerRuntime = worker_runtime.WorkerRuntime;

const helpers = struct {
    const requiredStringArg = tool_args.requiredStringArg;
    const parseToolArgsObject = tool_args.parseToolArgsObject;
};

const parseToolArgsObject = helpers.parseToolArgsObject;
const context_limits = @import("../config/context_limits.zig");
const workspace_access = @import("../workspace/workspace_access.zig");
const host_capabilities = @import("../hosts/host.zig");
const terminal_client_runtime = @import("../terminal/client.zig");
const terminal_managed_observer = @import("../terminal/managed_observer.zig");

pub const Context = struct {
    workspace_root: []const u8,
    access_scope: ?workspace_access.AccessScope = null,
    ignored_list_entries: []const []const u8,
    max_list_entries: usize,
    max_read_file_bytes: usize,
    max_read_file_lines: usize,
    max_read_file_line_len: usize,
    max_command_output_bytes: usize,
    max_tool_result_bytes: usize = tool_result_limits.default_max_tool_result_bytes,
    api_key: []const u8,
    agent_stream_provider: agent_stream_provider.Provider = agent_stream_provider.unavailable_provider,
    gateway_team: ?[]const u8 = null,
    credential_source: ?types.CredentialSource = null,
    account_id: ?[]const u8 = null,
    provider: model_provider.ProviderId = .openrouter,
    provider_capabilities: provider_set.Bundle.Capabilities = .{
        .fx_search = true,
        .vision_fallback = true,
    },
    secret_store: host_mod.SecretStore = host_mod.unavailable_secret_store,
    model: []const u8,
    /// Resolved review-model override for automatic permission review. Empty
    /// keeps the reviewer provider's compiled default.
    reviewer_model: []const u8 = "",
    permission_review_turn: ?permission_auto_classifier.ReviewTurnContext = null,
    root_user_intent_context: []const u8 = "",
    root_user_messages: []const []const u8 = &.{},
    root_user_evidence_complete: bool = false,
    current_turn_messages: []const ChatMessage = &.{},
    gateway_retry_count: usize,
    gateway_chat_url: []const u8,
    gateway_models_path: []const u8 = "/v1/models",
    agent_step_limit: usize,
    fast_mode: bool = false,
    effort: types.ReasoningEffort = .auto,
    /// Borrowed gateway provider routing inherited by subagent turns. Never
    /// applied to tool-internal provider requests (vision, web search), which
    /// keep gateway-default routing.
    provider_order: []const []const u8 = &.{},
    provider_strict: bool = false,
    first_call_tool_choice: types.ToolChoice = .auto,
    tool_registry: tool_dispatch.Registry = .{},
    host_tool_provider: ?tool_dispatch.HostToolProvider = null,
    subagent_host: ?*subagent_tool_host.Runtime = null,
    subagent_caller_id: ?[]const u8 = null,
    permission_mode: PermissionMode,
    permission_grants: []const PermissionGrant,
    session_grants: []const PermissionGrant = &.{},
    permission_rules: types.PermissionRuleSet,
    permission_state_override: ?*const session_permission_state.State = null,
    worker: *WorkerRuntime,
    /// Sole prompt capability admission consults. When null, admission never
    /// prompts: it resolves by rule, automatic review, or fail-closed denial
    /// (e.g. a noninteractive host sets this explicitly).
    permission_prompter: ?permission_prompter.Prompter = null,
    cancel_flag: ?*std.atomic.Value(bool) = null,
    session: *SessionRuntime,
    session_allocator: Allocator = std.heap.c_allocator,
    skills_dir: []const u8 = "",
    skill_locations: ?*const skill_contract.Locations = null,
    context_limits: context_limits.Values = .{},
    context_registry: context_contract.Registry,
    context_enabled: bool = true,
    output_chunk_lifecycle_id: ?types.ToolLifecycleId = null,
    output_chunk_ctx: *anyopaque,
    on_output_chunk: command_contract.CommandOutputCallback,
    command_artifact_dir: ?[]const u8 = null,
    tool_result_dir: ?[]const u8 = null,
    session_child_capability: ?*session_child_store.SessionChildCapability = null,
    ephemeral_command_replay: ?*command_replay_store.EphemeralStore = null,
    terminal_client: ?*terminal_client_runtime.Runtime = null,
    managed_executions: ?*managed_execution.Runtime = null,
    command_timeout_ms: ?usize = null,
    command_timeout_started_ms: ?i64 = null,
    command_replay_capture: ?*command_replay_store.Capture = null,
    command_replay_unavailable: bool = false,
    tracker: ?*change_tracker.ChangeTracker = null,

    tool_progress_ctx: ?*anyopaque = null,
    on_tool_progress: ?*const fn (*anyopaque, types.ToolLifecycleId, []const u8) void = null,
    subagent_status_renderer: ?types.SubagentStatusRenderer = null,
    advertised_dynamic_tool_names: []const []const u8 = &.{},
    permission_reviewer_provider: ?permission_auto_classifier.Provider = null,
    auto_classifier: permission_auto_classifier.Classifier =
        permission_auto_classifier.Classifier.disabled(),
    web_fetch_runtime: ?*web_fetch_runtime.Runtime = null,
    web_fetch_artifact_store: ?*web_fetch_artifacts.Store = null,
    web_fetch_artifact_error: ?anyerror = null,
    web_search_runtime_ready: bool = false,
    web_search_backend: ?tool_dispatch.WebSearchBackend = null,
    web_search_progress_ctx: ?*anyopaque = null,
    on_web_search_progress: ?tool_dispatch.WebSearchProgressFn = null,
    web_fetch_progress_ctx: ?*anyopaque = null,
    on_web_fetch_progress: ?tool_dispatch.WebFetchProgressFn = null,
    model_capability_resolver: ?model_capabilities.Resolver = null,
    model_override_resolver: ?subagent_tool_host.ModelOverrideResolver = null,
    /// False when running outside an interactive TUI (e.g. headless runs). Tools
    /// that require a live user (like `ask_user_question`) short-circuit
    /// in that case.
    interactive: bool = true,
    lifecycle_view: hooks.RuntimeView = hooks.RuntimeView.empty(),
    lifecycle_scope: hooks.Scope = .{
        .kind = .interactive,
        .workspace_root = "",
    },

    /// Projects only the borrowed capabilities consumed by admission.
    pub fn admissionInput(self: Context) tool_admission.Input {
        var input: tool_admission.Input = .{
            .workspace_root = self.workspace_root,
            .access_scope = self.access_scope,
            .permission_review_turn = self.permission_review_turn,
            .permission_grants = self.permission_grants,
            .permission_rules = self.permission_rules,
            .session_permission_state = self.permission_state_override,
            .session_permission_state_provider = .{
                .context = @ptrCast(self.session),
                .snapshot_fn = snapshotSessionPermissionState,
            },
            .tool_registry = self.tool_registry,
            .worker = self.worker,

            .permission_prompter = self.permission_prompter,
            .advertised_dynamic_tool_names = self.advertised_dynamic_tool_names,

            .context_limits = self.context_limits,
            .auto_classifier = self.admissionAutoClassifier(),
            .terminal_review_context = self.terminalReviewContext(),
        };
        if (self.permission_state_override != null) {
            input.session_permission_state_provider = null;
        }
        return input;
    }

    fn terminalReviewContext(self: Context) ?terminal_managed_observer.Context {
        return .{
            .alloc = self.session_allocator,
            .lifecycle_allocator = self.session_allocator,
            .terminal_client = self.terminal_client orelse return null,
            .managed_runtime = self.managed_executions orelse return null,
            .owner = self.session_child_capability orelse return null,
            .durable_session_id = self.lifecycle_scope.session_id orelse return null,
            .workspace_root = self.workspace_root,
            .transport_role = switch (self.lifecycle_scope.kind) {
                .interactive, .subagent => .interactive,
                .ask => .headless,
            },
            .max_output_bytes = self.max_command_output_bytes,
            .cancel_flag = runtimeCancelFlag(self),
        };
    }

    pub fn admissionInputWithLiveAuthority(
        self: Context,
        authority: ?tool_contracts.LiveToolAuthority,
    ) tool_admission.Input {
        var input = self.admissionInput();
        if (authority) |live| {
            input.permission_grants = live.grants;
            input.permission_rules = live.rules;
            input.session_permission_state = live.permission_state;
            if (live.permission_state != null) {
                input.session_permission_state_provider = null;
            }
            input.advertised_dynamic_tool_names = live.integrations;
        }
        return input;
    }

    fn admissionAutoClassifier(self: Context) permission_auto_classifier.Classifier {
        if (self.auto_classifier.enabled()) return self.auto_classifier;
        const provider = self.permission_reviewer_provider orelse
            return permission_auto_classifier.Classifier.disabled();
        return permission_auto_classifier.Classifier.withProvider(provider, .{
            .credential = self.api_key,
            .credential_source = self.credential_source,
            .account_id = self.account_id,
            .tenant = self.gateway_team,
            .endpoint = self.gateway_chat_url,
            .reviewer_model = self.reviewer_model,
            .cancel_flag = self.cancel_flag,
            .usage = &self.session.usage,
            .usage_allocator = self.session_allocator,
        });
    }
};

fn snapshotSessionPermissionState(
    raw_session: *anyopaque,
    alloc: Allocator,
) !session_permission_state.State {
    const session: *SessionRuntime = @ptrCast(@alignCast(raw_session));
    return session.snapshotPermissionState(alloc);
}

fn registeredToolSpec(ctx: Context, name: []const u8) ?*const tool_specs.ToolSpec {
    return ctx.tool_registry.lookup(name);
}

fn providerDisablesTool(capabilities: provider_set.Bundle.Capabilities, name: []const u8) bool {
    return std.mem.eql(u8, name, "vision") and
        !capabilities.vision_fallback;
}

pub fn validateToolCall(ctx: Context, arena: Allocator, call: ToolCall) !tool_contracts.ToolCallValidationResult {
    if (providerDisablesTool(ctx.provider_capabilities, call.name)) {
        return .{ .failure = try arena.dupe(u8, "Unsupported tool: vision") };
    }
    const spec = registeredToolSpec(ctx, call.name) orelse return .not_registered;
    switch (spec.executor_kind) {
        // File mutation arguments are decoded once by shared permission preflight.
        .write_file, .edit_file => return .{ .valid = .{} },
        else => {},
    }

    var dispatch_ctx = typedDispatchContext(ctx, arena);
    dispatch_ctx.captured_command_host = spec.captured_command_host;
    return switch (try tool_dispatch.validateRegisteredToolCall(dispatch_ctx, ctx.tool_registry, call)) {
        .not_registered => .not_registered,
        .valid => .{ .valid = .{} },
        .failure => |reason| .{ .failure = reason },
    };
}

pub fn checkToolAvailability(ctx: Context, arena: Allocator, call: ToolCall) !?[]const u8 {
    if (providerDisablesTool(ctx.provider_capabilities, call.name)) {
        return try arena.dupe(u8, "Unsupported tool: vision");
    }
    return tool_dispatch.localToolAvailabilityFailureForCall(
        typedDispatchContext(ctx, arena),
        ctx.tool_registry,
        call,
    );
}

pub fn executeToolCallAuthorized(
    ctx: Context,
    request: tool_contracts.ToolExecutionRequest,
) !ToolExecutionResult {
    var replay_continuation_transferred = request.command_replay_capture == null;
    defer if (!replay_continuation_transferred) {
        request.command_replay_capture.?.abort(request.result_allocator);
    };
    var execution_ctx = ctx;
    execution_ctx.skill_locations = request.skill_locations orelse ctx.skill_locations;
    if (request.permission_mode) |permission_mode| {
        execution_ctx.permission_mode = permission_mode;
    }
    if (request.live_authority) |authority| {
        if (!containsName(authority.tools, request.call.name) and
            !containsName(authority.integrations, request.call.name))
        {
            return tool_contracts.failToolExecutionResult(
                error.LiveToolAuthorityUnavailable,
            );
        }
        execution_ctx.permission_mode = authority.permission_mode;
        execution_ctx.permission_grants = authority.grants;
        execution_ctx.session_grants = authority.grants;
        execution_ctx.permission_rules = authority.rules;
        execution_ctx.advertised_dynamic_tool_names = authority.integrations;
    } else {
        execution_ctx.session_grants = request.session_grants;
        execution_ctx.advertised_dynamic_tool_names =
            request.advertised_dynamic_tool_names;
    }
    execution_ctx.max_tool_result_bytes = request.max_tool_result_bytes;
    execution_ctx.current_turn_messages = request.current_turn_messages;
    execution_ctx.output_chunk_lifecycle_id = request.lifecycle_id;
    execution_ctx.command_timeout_started_ms = request.command_timeout_started_ms;
    execution_ctx.command_replay_capture = request.command_replay_capture;
    execution_ctx.command_replay_unavailable = request.command_replay_unavailable;

    const started_at_ms = io_mod.milliTimestamp();
    const uses_file_mutation_contract = if (registeredToolSpec(
        execution_ctx,
        request.call.name,
    )) |spec|
        spec.take_file_mutation_input_fn != null
    else
        false;
    const result = (if (comptime builtin.os.tag == .wasi)
        executeWorkspaceToolCallInner(
            execution_ctx,
            request.result_allocator,
            request.call,
            request.authority,
            request.classification_complete,
        )
    else if (uses_file_mutation_contract)
        file_mutation_execution.execute(.{
            .call_allocator = request.call_allocator,
            .result_allocator = request.result_allocator,
            .call = request.call,
            .authorization = switch (request.authority) {
                .file_mutation => |value| value,
                else => null,
            },
            .maybe_cancel_flag = execution_ctx.cancel_flag,
            .lifecycle_id = request.lifecycle_id,
        })
    else
        executeToolCallInner(
            execution_ctx,
            request.result_allocator,
            request.call,
            request.authority,
            request.classification_complete,
            request.authorized_image_catalog,
        )) catch |err| {
        diagnostics.recordToolCallResult(.{
            .name = request.call.name,
            .arguments_json = request.call.arguments_json,
            .model_output = "",
            .outcome = classifyToolExecutionError(err),
            .started_at_ms = started_at_ms,
            .subagent_id = execution_ctx.lifecycle_scope.subagent_id orelse 0,
        });
        return if (err == error.CancelledBeforeExecution) error.Cancelled else err;
    };
    diagnostics.recordToolCallResult(.{
        .name = request.call.name,
        .arguments_json = request.call.arguments_json,
        .model_output = result.model_output,
        .outcome = classifyReturnedToolCallOutcome(result),
        .started_at_ms = started_at_ms,
        .subagent_id = execution_ctx.lifecycle_scope.subagent_id orelse 0,
    });
    if (request.command_replay_capture) |continued| {
        replay_continuation_transferred = result.command_replay_capture == continued;
    }
    return result;
}

fn classifyToolExecutionError(err: anyerror) diagnostics.ToolCallOutcome {
    return switch (err) {
        error.CancelledBeforeExecution => .rejected,
        error.Cancelled => .tool_failed,
        else => .runtime_failed,
    };
}

fn classifyReturnedToolCallOutcome(
    result: ToolExecutionResult,
) diagnostics.ToolCallOutcome {
    if (result.status == .success) return .succeeded;
    if (result.command_result_json != null) return .command_failed;
    // Only an explicit denial records a rejection. An authorized execution
    // that failed — with or without a declared kind — is a tool failure, so
    // a producer that forgets to declare a kind cannot silently masquerade
    // as a rejection in diagnostics.
    return switch (result.failure_kind) {
        .denied => .rejected,
        .none, .preflight, .apply => .tool_failed,
    };
}

pub fn executeHostToolCallAuthorized(
    ctx: Context,
    request: tool_contracts.ToolExecutionRequest,
) !ToolExecutionResult {
    const spec = ctx.tool_registry.lookup(request.call.name) orelse
        return error.InvalidToolArguments;
    if (spec.executor_kind != .host) return error.InvalidToolArguments;

    var execution_ctx = ctx;
    if (request.permission_mode) |permission_mode| {
        execution_ctx.permission_mode = permission_mode;
    }
    execution_ctx.max_tool_result_bytes = request.max_tool_result_bytes;
    var dispatch_ctx = typedDispatchContextForCall(
        execution_ctx,
        request.result_allocator,
        request.call,
    );
    dispatch_ctx.execution_authority = request.authority;
    const dispatched = try tool_dispatch.dispatchAuthorizedToolCall(
        dispatch_ctx,
        execution_ctx.tool_registry,
        request.call,
    );
    return toolExecutionResultFromDispatch(dispatched, .{});
}

fn containsName(values: []const []const u8, needle: []const u8) bool {
    for (values) |value| {
        if (std.mem.eql(u8, value, needle)) return true;
    }
    return false;
}

pub fn executeToolCall(
    ctx: Context,
    arena: Allocator,
    call: ToolCall,
) !ToolExecutionResult {
    return executeToolCallAuthorized(ctx, .{
        .call_allocator = arena,
        .result_allocator = arena,
        .call = call,
        .authority = .ordinary,
        .current_turn_messages = ctx.current_turn_messages,
        .session_grants = ctx.session_grants,
        .advertised_dynamic_tool_names = ctx.advertised_dynamic_tool_names,
        .max_tool_result_bytes = ctx.max_tool_result_bytes,
    });
}

const ToolDispatchPrelude = union(enum) {
    completed: ToolExecutionResult,
    registered_static,
    registered_dynamic: tool_dispatch.Tool,
};

fn executeToolCallInner(
    ctx: Context,
    arena: Allocator,
    call: ToolCall,
    authority: command_admission.ToolExecutionAuthority,
    classification_complete: bool,
    authorized_image_catalog: []const types.ImageAttachment,
) !ToolExecutionResult {
    return switch (try resolveToolDispatchPrelude(
        ctx,
        arena,
        call,
        classification_complete,
    )) {
        .completed => |result| return result,
        .registered_static => try executeRegisteredTool(
            ctx,
            arena,
            call,
            authority,
            authorized_image_catalog,
            ctx.tool_registry,
        ),
        .registered_dynamic => |dynamic_tool| blk: {
            const tools = [_]tool_dispatch.Tool{dynamic_tool};
            break :blk try executeRegisteredTool(
                ctx,
                arena,
                call,
                authority,
                authorized_image_catalog,
                .{ .tools = tools[0..] },
            );
        },
    };
}

fn executeWorkspaceToolCallInner(
    ctx: Context,
    arena: Allocator,
    call: ToolCall,
    authority: command_admission.ToolExecutionAuthority,
    classification_complete: bool,
) !ToolExecutionResult {
    if (!classification_complete) {
        if (try checkToolAvailability(ctx, arena, call)) |reason| {
            return semanticFailure(reason);
        }
    }
    const spec = registeredToolSpec(ctx, call.name) orelse
        return semanticFailure(try std.fmt.allocPrint(arena, "Unsupported tool: {s}", .{call.name}));
    if (ctx.tool_registry.tools.len != 1 or
        !std.mem.eql(u8, spec.name, "shell") or
        spec.executor_kind != .run_command or
        spec.runtime_provider != .run_command)
    {
        return semanticFailure(try std.fmt.allocPrint(arena, "Unsupported tool: {s}", .{call.name}));
    }

    var command_backend = RunCommandBackendState{ .runtime = ctx };
    var dispatch_metadata: DispatchMetadata = .{};
    var dispatch_ctx = typedDispatchContextForCall(ctx, arena, call);
    dispatch_metadata.attach(&dispatch_ctx);
    dispatch_ctx.execution_authority = authority;
    dispatch_ctx.captured_command_host = spec.captured_command_host;
    dispatch_ctx.run_command_backend = .{
        .ctx = &command_backend,
        .execute_fn = executeRunCommandBackend,
    };
    const dispatched = try tool_dispatch.dispatchAuthorizedToolCall(
        dispatch_ctx,
        ctx.tool_registry,
        call,
    );
    if (command_backend.execution_error) |err| {
        dispatched.deinit(arena);
        return err;
    }
    var execution = command_backend.completion orelse
        toolExecutionResultFromDispatch(dispatched, dispatch_metadata);
    execution.model_output = dispatched.body;
    return execution;
}

fn resolveToolDispatchPrelude(
    ctx: Context,
    arena: Allocator,
    call: ToolCall,
    classification_complete: bool,
) !ToolDispatchPrelude {
    if (!classification_complete) {
        if (try checkToolAvailability(ctx, arena, call)) |reason| {
            return .{ .completed = semanticFailure(reason) };
        }
    }
    if (registeredToolSpec(ctx, call.name) != null) return .registered_static;
    return .{ .completed = semanticFailure(try std.fmt.allocPrint(arena, "Unsupported tool: {s}", .{call.name})) };
}

fn executeRegisteredTool(
    ctx: Context,
    arena: Allocator,
    call: ToolCall,
    authority: command_admission.ToolExecutionAuthority,
    authorized_image_catalog: []const types.ImageAttachment,
    registry: tool_dispatch.Registry,
) !ToolExecutionResult {
    var context_notice_sink = ContextNoticeSinkState{ .allocator = arena };
    var command_backend = RunCommandBackendState{ .runtime = ctx };
    var vision_provider = VisionProviderState{
        .runtime = ctx,
        .authorized_image_catalog = authorized_image_catalog,
    };
    var dispatch_metadata: DispatchMetadata = .{};
    var subagent_provider = SubagentProviderState{
        .runtime = ctx,
        .call = call,
        .completion_sink = &dispatch_metadata.subagent_completion,
    };
    var dispatch_ctx = typedDispatchContextForCall(ctx, arena, call);
    dispatch_metadata.attach(&dispatch_ctx);
    var result_commit_token: ?result_commit.Token = null;
    dispatch_ctx.result_commit_sink = &result_commit_token;
    dispatch_ctx.execution_authority = authority;

    const runtime_provider = if (registry.lookup(call.name)) |tool|
        tool.runtime_provider
    else
        .none;
    if (registry.lookup(call.name)) |tool| {
        dispatch_ctx.captured_command_host = tool.captured_command_host;
    }
    switch (runtime_provider) {
        .none => {},
        .run_command => dispatch_ctx.run_command_backend = .{
            .ctx = &command_backend,
            .execute_fn = executeRunCommandBackend,
        },
        .vision => dispatch_ctx.vision_provider = .{
            .ctx = &vision_provider,
            .execute_fn = executeVisionProvider,
        },
        .subagent => dispatch_ctx.subagent_provider = .{
            .context = &subagent_provider,
            .execute_fn = executeSubagentProvider,
        },
    }
    attachContextNoticeSink(&dispatch_ctx, &context_notice_sink);
    const dispatched = try tool_dispatch.dispatchAuthorizedToolCall(
        dispatch_ctx,
        registry,
        call,
    );
    if (command_backend.execution_error) |err| {
        dispatched.deinit(arena);
        return err;
    }
    if (vision_provider.execution_error) |err| {
        dispatched.deinit(arena);
        return err;
    }

    var execution = if (command_backend.completion) |completion|
        completion
    else if (vision_provider.completion) |completion|
        completion
    else
        toolExecutionResultFromDispatch(dispatched, dispatch_metadata);
    execution.model_output = dispatched.body;

    execution.context_notices = context_notice_sink.notices.items;
    execution.result_commit = result_commit_token;
    if (dispatch_ctx.cancel_flag) |cancel_flag| {
        if (cancel_flag.load(.seq_cst) and
            tool_dispatch.toolActivityKind(registry, call.name) == .command)
        {
            execution.cancelled = true;
        }
    }
    return execution;
}

const RunCommandBackendState = struct {
    runtime: Context,
    completion: ?ToolExecutionResult = null,
    execution_error: ?anyerror = null,
};

fn executeRunCommandBackend(
    maybe_ctx: ?*anyopaque,
    dispatch_ctx: tool_dispatch.DispatchContext,
    request: tool_dispatch.RunCommandRequest,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const raw_ctx = maybe_ctx orelse unreachable;
    const state: *RunCommandBackendState = @ptrCast(@alignCast(raw_ctx));
    const authority = switch (dispatch_ctx.execution_authority orelse {
        state.execution_error = error.InvalidRunCommandExecutionAuthority;
        return .{ .failure = try dispatch_ctx.allocator.dupe(u8, "") };
    }) {
        .run_command => |command_authority| command_authority,
        .ordinary, .file_mutation, .vision_paths => {
            state.execution_error = error.InvalidRunCommandExecutionAuthority;
            return .{ .failure = try dispatch_ctx.allocator.dupe(u8, "") };
        },
    };
    const execution = toolRunCommand(
        state.runtime,
        dispatch_ctx.allocator,
        request,
        authority,
    ) catch |err| {
        state.execution_error = err;
        return .{ .failure = try dispatch_ctx.allocator.dupe(u8, "") };
    };
    state.completion = execution;
    return switch (execution.status) {
        .success => .{ .success = @constCast(execution.model_output) },
        .failure => .{ .failure = @constCast(execution.model_output) },
    };
}

const DispatchMetadata = struct {
    model_content_kind: tool_dispatch.ModelContentKind = .ordinary,
    inner_usage: ?types.ToolUsage = null,
    web_search_completion: ?types.WebSearchCompletion = null,
    web_fetch_completion: ?types.WebFetchCompletion = null,
    subagent_completion: ?types.SubagentStatus = null,
    tool_result_memory: ?types.ToolResultMemory = null,
    command_result_json: ?[]const u8 = null,

    fn attach(self: *DispatchMetadata, ctx: *tool_dispatch.DispatchContext) void {
        ctx.model_content_kind_sink = &self.model_content_kind;
        ctx.inner_usage_sink = &self.inner_usage;
        ctx.web_search_completion_sink = &self.web_search_completion;
        ctx.web_fetch_completion_sink = &self.web_fetch_completion;
        ctx.tool_result_memory_sink = &self.tool_result_memory;
        ctx.command_result_json_sink = &self.command_result_json;
    }
};

fn toolExecutionResultFromDispatch(
    result: tool_dispatch.AuthorizedDispatchResult,
    metadata: DispatchMetadata,
) ToolExecutionResult {
    var memory = metadata.tool_result_memory;
    if (result.images.len > 0) {
        var rich_memory = memory orelse types.ToolResultMemory{};
        rich_memory.tool_images = result.images;
        memory = rich_memory;
    }
    return switch (result.status) {
        .success => .{
            .model_content_kind = metadata.model_content_kind,
            .model_output = result.body,
            .inner_usage = metadata.inner_usage,
            .web_search_completion = metadata.web_search_completion,
            .web_fetch_completion = metadata.web_fetch_completion,
            .subagent_completion = metadata.subagent_completion,
            .tool_result_memory = memory,
            .command_result_json = metadata.command_result_json,
        },
        .failure => .{
            .status = .failure,
            .model_output = result.body,
            .inner_usage = metadata.inner_usage,
            .web_search_completion = metadata.web_search_completion,
            .web_fetch_completion = metadata.web_fetch_completion,
            .subagent_completion = metadata.subagent_completion,
            .tool_result_memory = memory,
            .command_result_json = metadata.command_result_json,
        },
    };
}

const ContextNoticeSinkState = struct {
    allocator: Allocator,
    notices: std.ArrayList([]const u8) = .empty,
};

fn attachContextNoticeSink(dispatch_ctx: *tool_dispatch.DispatchContext, state: *ContextNoticeSinkState) void {
    dispatch_ctx.context_notice_ctx = state;
    dispatch_ctx.on_context_notice = recordContextNoticeForDispatch;
}

fn recordContextNoticeForDispatch(raw_ctx: ?*anyopaque, notice: []const u8) error{OutOfMemory}!void {
    const state_ptr = raw_ctx orelse return;
    const state: *ContextNoticeSinkState = @ptrCast(@alignCast(state_ptr));
    const duplicate = try state.allocator.dupe(u8, notice);
    errdefer state.allocator.free(duplicate);
    try state.notices.append(state.allocator, duplicate);
}
fn typedDispatchContext(ctx: Context, arena: Allocator) tool_dispatch.DispatchContext {
    var capabilities = tool_dispatch.ToolCapabilities.for_host(
        host_capabilities.current(),
    );
    capabilities.web_search_runtime_ready =
        ctx.web_search_runtime_ready and ctx.web_search_backend != null;
    return .{
        .allocator = arena,
        .permission_mode = ctx.permission_mode,
        .workspace_root = ctx.workspace_root,
        .access_scope = ctx.access_scope,
        .change_tracker = ctx.tracker,
        .skills_dir = ctx.skills_dir,
        .skill_locations = ctx.skill_locations,
        .context_limits = ctx.context_limits,
        .ignored_list_entries = ctx.ignored_list_entries,
        .max_list_entries = ctx.max_list_entries,
        .max_read_file_bytes = ctx.max_read_file_bytes,
        .max_read_file_lines = ctx.max_read_file_lines,
        .max_read_file_line_len = ctx.max_read_file_line_len,
        .max_tool_result_bytes = ctx.max_tool_result_bytes,
        .tool_result_dir = ctx.tool_result_dir,
        .session_child_capability = ctx.session_child_capability,
        .ephemeral_command_replay = ctx.ephemeral_command_replay,
        .terminal_client = ctx.terminal_client,
        .managed_executions = ctx.managed_executions,
        .command_artifact_dir = ctx.command_artifact_dir,
        .terminal_owner_session_id = ctx.lifecycle_scope.session_id,
        .terminal_transport_role = switch (ctx.lifecycle_scope.kind) {
            .interactive, .subagent => .interactive,
            .ask => .headless,
        },
        .lifecycle_allocator = ctx.session_allocator,
        .cancel_flag = runtimeCancelFlag(ctx),
        .output_chunk_lifecycle_id = ctx.output_chunk_lifecycle_id,
        .output_chunk_ctx = ctx.output_chunk_ctx,
        .on_output_chunk = ctx.on_output_chunk,
        .command_timeout_ms = ctx.command_timeout_ms,
        .ask_question_ctx = if (ctx.interactive) ctx.worker else null,
        .ask_question_batch = if (ctx.interactive) requestQuestionBatchWithWorker else null,
        .web_fetch_runtime = ctx.web_fetch_runtime,
        .web_fetch_artifact_store = ctx.web_fetch_artifact_store,
        .web_fetch_artifact_error = ctx.web_fetch_artifact_error,
        .tool_capabilities = capabilities,
        .web_search_backend = ctx.web_search_backend,
        .web_search_progress_ctx = ctx.web_search_progress_ctx,
        .on_web_search_progress = ctx.on_web_search_progress,
        .web_fetch_progress_ctx = ctx.web_fetch_progress_ctx,
        .on_web_fetch_progress = ctx.on_web_fetch_progress,
        .host_tool_provider = ctx.host_tool_provider,
    };
}

fn terminal_lease_cleanup_dispatch_context(
    ctx: Context,
    arena: Allocator,
) tool_dispatch.DispatchContext {
    var dispatch = typedDispatchContext(ctx, arena);
    dispatch.cancel_flag = null;
    return dispatch;
}

pub fn release_agent_terminal_lease(ctx: Context, session_id: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(ctx.session_allocator);
    defer arena_state.deinit();
    return shell_impl.releaseAgentWriteLease(
        terminal_lease_cleanup_dispatch_context(ctx, arena_state.allocator()),
        session_id,
    );
}

fn requestQuestionBatchWithWorker(
    raw_ctx: ?*anyopaque,
    response_alloc: Allocator,
    entries: []const types.QuestionBatchEntry,
) Allocator.Error!?[][]u8 {
    const worker: *WorkerRuntime = @ptrCast(@alignCast(raw_ctx.?));
    const worker_alloc = std.heap.c_allocator;
    const worker_answers = try worker.requestQuestionBatchAnswerBlocking(worker_alloc, entries);
    defer freeQuestionAnswers(worker_alloc, worker_answers);

    const answers = worker_answers orelse return null;
    const copied_answers = try dupeQuestionAnswers(response_alloc, answers);
    return copied_answers;
}

fn dupeQuestionAnswers(alloc: Allocator, answers: []const []const u8) Allocator.Error![][]u8 {
    const copy = try alloc.alloc([]u8, answers.len);
    errdefer alloc.free(copy);

    var copied: usize = 0;
    errdefer {
        for (copy[0..copied]) |answer| alloc.free(answer);
    }
    while (copied < answers.len) : (copied += 1) {
        copy[copied] = try alloc.dupe(u8, answers[copied]);
    }
    return copy;
}

fn freeQuestionAnswers(alloc: Allocator, maybe_answers: ?[][]u8) void {
    const answers = maybe_answers orelse return;
    for (answers) |answer| alloc.free(answer);
    alloc.free(answers);
}

fn runtimeCancelFlag(ctx: Context) *std.atomic.Value(bool) {
    return ctx.cancel_flag orelse &ctx.worker.worker_cancel_requested;
}

fn typedDispatchContextForCall(
    ctx: Context,
    arena: Allocator,
    call: ToolCall,
) tool_dispatch.DispatchContext {
    var dispatch = typedDispatchContext(ctx, arena);
    dispatch.tool_call_id = call.id;
    dispatch.tool_call_name = call.name;
    dispatch.resolved_skill = call.resolved_skill;
    return dispatch;
}

pub fn prepareSkillCall(ctx: Context, arena: Allocator, call: ToolCall, locations: ?*const skill_contract.Locations) !skill_contract.CallPreparation {
    const tool = ctx.tool_registry.lookup(call.name) orelse return error.UnsupportedTool;
    const prepare = tool.prepare_skill_call_fn orelse return error.UnsupportedTool;
    var dispatch = typedDispatchContextForCall(ctx, arena, call);
    dispatch.skill_locations = locations;
    return prepare(dispatch, call.arguments_json);
}

const VisionProviderState = struct {
    runtime: Context,
    authorized_image_catalog: []const types.ImageAttachment,
    completion: ?ToolExecutionResult = null,
    execution_error: ?anyerror = null,
};

fn executeVisionProvider(
    maybe_ctx: ?*anyopaque,
    dispatch_ctx: tool_dispatch.DispatchContext,
    input: tool_dispatch.ToolInput,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const raw_ctx = maybe_ctx orelse unreachable;
    const state: *VisionProviderState = @ptrCast(@alignCast(raw_ctx));
    const request = input.as(tool_contracts.vision.VisionRequest);
    const execution = executeVisionRequest(
        state,
        dispatch_ctx.allocator,
        request.*,
        dispatch_ctx.execution_authority orelse {
            state.execution_error = error.InvalidVisionExecutionAuthority;
            return .{ .failure = try dispatch_ctx.allocator.dupe(u8, "") };
        },
    ) catch |err| {
        state.execution_error = err;
        return .{ .failure = try dispatch_ctx.allocator.dupe(u8, "") };
    };
    state.completion = execution;
    return switch (execution.status) {
        .success => .{ .success = @constCast(execution.model_output) },
        .failure => .{ .failure = @constCast(execution.model_output) },
    };
}

fn executeVisionRequest(
    state: *VisionProviderState,
    alloc: Allocator,
    request: tool_contracts.vision.VisionRequest,
    authority: command_admission.ToolExecutionAuthority,
) !ToolExecutionResult {
    const config: vision_executor.Config = .{
        .stream_provider = state.runtime.agent_stream_provider,
        .api_key = state.runtime.api_key,
        .credential_source = state.runtime.credential_source,
        .gateway_team = state.runtime.gateway_team,
        .session_id = state.runtime.lifecycle_scope.session_id,
        .retry_count = state.runtime.gateway_retry_count,
        .cancel_flag = state.runtime.cancel_flag,
        .usage = &state.runtime.session.usage,
        .usage_allocator = state.runtime.session_allocator,
        .trace_ctx = .{},
        .output_limit = state.runtime.context_limits.image_adapter_output_bytes,
    };
    if (request.image_ids() != null) {
        if (authority != .ordinary) return error.InvalidVisionExecutionAuthority;
        return vision_executor.executeRequest(
            alloc,
            request,
            state.authorized_image_catalog,
            config,
        );
    }

    const approved_targets = switch (authority) {
        .vision_paths => |vision_authority| vision_authority.targets,
        .ordinary, .run_command, .file_mutation => return error.InvalidVisionExecutionAuthority,
    };
    const raw_paths = request.paths() orelse return error.InvalidVisionExecutionAuthority;
    if (raw_paths.len != approved_targets.len) return error.InvalidVisionExecutionAuthority;
    return executeVisionPathRequest(state, alloc, request, approved_targets, config);
}

fn executeVisionPathRequest(
    state: *VisionProviderState,
    alloc: Allocator,
    request: tool_contracts.vision.VisionRequest,
    approved_targets: []const command_admission.VisionPathExecutionTarget,
    config: vision_executor.Config,
) !ToolExecutionResult {
    const catalog = try alloc.alloc(types.ImageAttachment, approved_targets.len);
    defer alloc.free(catalog);
    var initialized: usize = 0;

    const snapshot_dir = image_attachments.createTempSnapshotDir(alloc) catch |err|
        return visionPathPreparationFailure(alloc, err);
    defer alloc.free(snapshot_dir);
    defer image_attachments.cleanupSnapshotDir(snapshot_dir);
    defer {
        image_attachments.discardImageSnapshots(alloc, catalog[0..initialized]);
        for (catalog[0..initialized]) |image| types.freeImageAttachment(alloc, image);
    }

    for (approved_targets, 0..) |target, index| {
        const image = image_attachments.captureBoundImageAttachment(
            alloc,
            target.canonical_path,
            target.identity,
            index + 1,
            snapshot_dir,
            .{ .cancel_flag = state.runtime.cancel_flag },
        ) catch |err| return visionPathPreparationFailure(alloc, err);
        catalog[index] = image;
        initialized += 1;
    }

    const image_ids = try alloc.alloc(usize, catalog.len);
    defer alloc.free(image_ids);
    for (image_ids, 0..) |*image_id, index| image_id.* = index + 1;
    const id_request: tool_contracts.vision.VisionRequest = .{
        .source = .{ .image_ids = image_ids },
        .focus = request.focus,
    };
    return vision_executor.executeRequest(alloc, id_request, catalog, config);
}

fn visionPathFailure(alloc: Allocator, err: anyerror) Allocator.Error!ToolExecutionResult {
    const details = [_]tool_result_errors.Detail{
        .{ .name = "error", .value = .{ .string = @errorName(err) } },
    };
    return .{
        .status = .failure,
        .status_detail = @errorName(err),
        .model_output = try tool_result_errors.toolExecutionFailureJson(alloc, .{
            .tool_name = "vision",
            .message = "Vision could not load an approved image path.",
            .details = &details,
            .suggestion = "Use an existing supported image under 20 MiB, or choose another image.",
        }),
    };
}

fn visionPathImagePreparationFailure(alloc: Allocator) Allocator.Error!ToolExecutionResult {
    const details = [_]tool_result_errors.Detail{
        .{ .name = "error", .value = .{ .string = "ImagePreparationFailed" } },
    };
    return .{
        .status = .failure,
        .status_detail = "ImagePreparationFailed",
        .model_output = try tool_result_errors.toolExecutionFailureJson(alloc, .{
            .tool_name = "vision",
            .message = "Vision could not prepare an approved image path.",
            .details = &details,
            .suggestion = image_attachments.image_preparation_failed_notice,
        }),
    };
}

fn visionPathPreparationFailure(
    alloc: Allocator,
    err: anyerror,
) !ToolExecutionResult {
    return switch (err) {
        error.OutOfMemory, error.Cancelled, error.TimedOut => err,
        error.ImagePreparationFailed => visionPathImagePreparationFailure(alloc),
        else => visionPathFailure(alloc, err),
    };
}

fn semanticFailure(output: []const u8) ToolExecutionResult {
    return .{ .status = .failure, .model_output = output };
}

pub fn withAdvertisedDynamicToolNames(ctx: Context, advertised_dynamic_tool_names: []const []const u8) Context {
    var copy = ctx;
    copy.advertised_dynamic_tool_names = advertised_dynamic_tool_names;
    return copy;
}

const EffectiveCommandTimeout = struct {
    timeout_ms: usize,
    started_ms: i64,
};

fn effectiveCommandTimeout(
    request_timeout_ms: u64,
    ambient_timeout_ms: ?usize,
    ambient_started_ms: ?i64,
    now_ms: i64,
) !EffectiveCommandTimeout {
    const requested = std.math.cast(usize, request_timeout_ms) orelse
        return error.InvalidToolArguments;
    const ambient = ambient_timeout_ms orelse return .{
        .timeout_ms = requested,
        .started_ms = now_ms,
    };
    const ambient_started = ambient_started_ms orelse now_ms;
    const elapsed: usize = if (now_ms <= ambient_started)
        0
    else
        std.math.cast(usize, now_ms - ambient_started) orelse std.math.maxInt(usize);
    return .{
        .timeout_ms = @min(requested, ambient -| elapsed),
        .started_ms = now_ms,
    };
}

fn commandReplayPolicy(
    environment: command_environment.Environment,
    has_replay_capability: bool,
    interactive: bool,
    continued: ?command_replay_store.CapturePolicy,
) ?command_replay_store.CapturePolicy {
    if (continued) |policy| return policy;
    return switch (environment) {
        .legacy => if (has_replay_capability or interactive)
            .best_effort
        else
            null,
        .clean, .user => if (has_replay_capability)
            .required
        else if (interactive)
            .best_effort
        else
            null,
    };
}

fn toolRunCommand(
    ctx: Context,
    arena: Allocator,
    request: tool_dispatch.RunCommandRequest,
    authority: command_admission.CommandExecutionAuthority,
) !ToolExecutionResult {
    const command = request.command;
    const cwd = request.resolved_cwd;
    const command_ctx = command_admission.CommandContext{
        .command = command,
        .resolved_cwd = cwd,
        .target_os = builtin.os.tag,
        .environment = request.environment,
    };
    const timeout = try effectiveCommandTimeout(
        request.timeout_ms,
        ctx.command_timeout_ms,
        ctx.command_timeout_started_ms,
        io_mod.milliTimestamp(),
    );
    const replay_policy = commandReplayPolicy(
        request.environment,
        ctx.session_child_capability != null or
            ctx.ephemeral_command_replay != null,
        ctx.interactive,
        if (ctx.command_replay_capture) |capture| capture.policy() else null,
    );

    try execution_router.validateConfigContext(.{
        .max_command_output_bytes = ctx.max_command_output_bytes,
    }, command_ctx);
    var route = try execution_router.prepareAuthorizedRoute(arena, command_ctx, authority);
    defer route.deinit(arena);

    const compatibility_result = try tool_dispatch.dispatchRunCommandCompatibility(
        typedDispatchContext(ctx, arena),
        ctx.tool_registry,
        request,
    );
    if (compatibility_result) |compatibility| {
        if (route != .approved_shell) return error.CommandAdmissionChanged;
        const intercepted_replay = try initCommandReplayCapture(
            arena,
            replay_policy,
            ctx.max_command_output_bytes,
            ctx.max_command_output_bytes,
            ctx.session_child_capability,
            ctx.ephemeral_command_replay,
            ctx.command_replay_capture,
            ctx.command_replay_unavailable,
        );
        const capture = intercepted_replay.capture;
        var transferred = false;
        defer if (!transferred) {
            if (capture) |candidate| candidate.abort(arena);
        };
        var callback = CommandReplayCaptureCallback{
            .alloc = arena,
            .capture = capture,
        };
        const output = switch (compatibility) {
            .success => |body| body,
            .failure => |body| body,
            .rich => {
                compatibility.deinit(arena);
                return error.RichCommandOutputUnsupported;
            },
        };
        if (compatibility == .success and capture != null and output.len > 0) {
            callback.accept(
                ctx.output_chunk_lifecycle_id,
                .stdout,
                output,
            ) catch |err| {
                if (err != error.CommandOutputCaptureFailed) return err;
                return finishCommandToolResult(
                    arena,
                    capture,
                    false,
                    &transferred,
                    null,
                    try command_result_mapping.Command.outputCaptureFailure(arena),
                );
            };
        }
        if (compatibility == .success and ctx.interactive and output.len > 0) {
            try ctx.on_output_chunk(
                ctx.output_chunk_ctx,
                ctx.output_chunk_lifecycle_id,
                .stdout,
                output,
            );
        }
        return finishCommandToolResult(
            arena,
            capture,
            intercepted_replay.unavailable and
                (ctx.command_replay_unavailable or callback.had_accepted_output),
            &transferred,
            null,
            .{
                .status = switch (compatibility) {
                    .success => .success,
                    .failure => .failure,
                    .rich => unreachable,
                },
                .model_output = output,
            },
        );
    }

    const replay_init = try initCommandReplayCapture(
        arena,
        replay_policy,
        ctx.max_command_output_bytes,
        execution_router.foregroundResultComparisonLimit(
            route,
            ctx.max_command_output_bytes,
        ),
        ctx.session_child_capability,
        ctx.ephemeral_command_replay,
        ctx.command_replay_capture,
        ctx.command_replay_unavailable,
    );
    const replay_capture = replay_init.capture;
    var replay_transferred = false;
    defer if (!replay_transferred) {
        if (replay_capture) |capture| capture.abort(arena);
    };
    var replay_callback = CommandReplayCaptureCallback{
        .alloc = arena,
        .capture = replay_capture,
    };

    const routed = execution_router.executePreparedRoute(.{
        .max_command_output_bytes = ctx.max_command_output_bytes,
        .cancel_flag = runtimeCancelFlag(ctx),
        .output_chunk_lifecycle_id = ctx.output_chunk_lifecycle_id,
        .output_chunk_ctx = ctx.output_chunk_ctx,
        .on_output_chunk = ctx.on_output_chunk,
        .accepted_output_chunk_ctx = if (replay_capture != null) @ptrCast(&replay_callback) else null,
        .on_accepted_output_chunk = if (replay_capture != null) CommandReplayCaptureCallback.onChunk else null,
        .callback_projection = if (ctx.interactive) .raw else .model_safe,
        .timeout_ms = timeout.timeout_ms,
        .timeout_started_ms = timeout.started_ms,
        .command_artifact_capability = ctx.session_child_capability,
        .command_artifact_dir = ctx.command_artifact_dir,
    }, arena, route) catch |err| {
        if (err == error.TimeoutExpired) {
            return finishCommandToolResult(
                arena,
                replay_capture,
                replay_init.unavailable and
                    (ctx.command_replay_unavailable or replay_callback.had_accepted_output),
                &replay_transferred,
                null,
                try command_result_mapping.Command.timeoutFailure(
                    arena,
                    command,
                    cwd,
                    timeout.timeout_ms,
                    timeout.started_ms,
                ),
            );
        }
        if (err == error.CommandOutputCaptureFailed) return finishCommandToolResult(
            arena,
            replay_capture,
            false,
            &replay_transferred,
            null,
            try command_result_mapping.Command.outputCaptureFailure(arena),
        );
        if (err == error.Cancelled and runtimeCancelFlag(ctx).load(.seq_cst)) {
            return finishCommandToolResult(
                arena,
                replay_capture,
                replay_init.unavailable and
                    (ctx.command_replay_unavailable or replay_callback.had_accepted_output),
                &replay_transferred,
                null,
                .{
                    .status = .failure,
                    .cancelled = true,
                    .model_output = "command cancelled\n",
                },
            );
        }
        return err;
    };
    const result = routed.result;

    if (try command_result_mapping.Command.cancelledFailure(arena, result)) |cancelled| {
        return finishCommandToolResult(
            arena,
            replay_capture,
            replay_init.unavailable and
                (ctx.command_replay_unavailable or replay_callback.had_accepted_output),
            &replay_transferred,
            result,
            cancelled,
        );
    }

    if (try command_result_mapping.Command.nonZeroFailure(arena, result)) |failure| {
        return finishCommandToolResult(
            arena,
            replay_capture,
            replay_init.unavailable and
                (ctx.command_replay_unavailable or replay_callback.had_accepted_output),
            &replay_transferred,
            result,
            failure,
        );
    }

    return finishCommandToolResult(
        arena,
        replay_capture,
        replay_init.unavailable and
            (ctx.command_replay_unavailable or replay_callback.had_accepted_output),
        &replay_transferred,
        result,
        .{
            .model_output = result.output,
            .command_result_json = if (result.command_result) |command_result| try command_result.toJson(arena) else null,
        },
    );
}

const CommandReplayCaptureCallback = struct {
    alloc: Allocator,
    capture: ?*command_replay_store.Capture,
    had_accepted_output: bool = false,

    fn onChunk(
        raw_ctx: *anyopaque,
        lifecycle_id: ?types.ToolLifecycleId,
        stream: command_contract.CommandOutputStream,
        chunk: []const u8,
    ) !void {
        const self: *@This() = @ptrCast(@alignCast(raw_ctx));
        return self.accept(lifecycle_id, stream, chunk);
    }

    fn accept(
        self: *@This(),
        lifecycle_id: ?types.ToolLifecycleId,
        stream: command_contract.CommandOutputStream,
        chunk: []const u8,
    ) !void {
        _ = lifecycle_id;
        if (chunk.len == 0) return;
        self.had_accepted_output = true;
        if (self.capture) |capture| {
            switch (capture.policy()) {
                .required => try capture.appendAcceptedRequired(
                    self.alloc,
                    stream,
                    chunk,
                ),
                .best_effort => capture.appendAccepted(self.alloc, stream, chunk),
            }
        }
    }
};

const CommandReplayCaptureInit = struct {
    capture: ?*command_replay_store.Capture = null,
    unavailable: bool = false,
};

fn initCommandReplayCapture(
    arena: Allocator,
    replay_policy: ?command_replay_store.CapturePolicy,
    inline_limit: usize,
    comparison_limit: usize,
    capability: ?*session_child_store.SessionChildCapability,
    ephemeral_store: ?*command_replay_store.EphemeralStore,
    continued_capture: ?*command_replay_store.Capture,
    continued_unavailable: bool,
) !CommandReplayCaptureInit {
    const policy = replay_policy orelse return .{};
    if (continued_unavailable) {
        if (policy == .required) return error.CommandOutputCaptureFailed;
        return .{ .unavailable = true };
    }
    if (continued_capture) |capture| {
        capture.setComparisonLimit(comparison_limit);
        return .{ .capture = capture };
    }
    const capture_inline_limit = if (policy == .required) 0 else inline_limit;
    const capture = (if (capability) |saved|
        command_replay_store.Capture.create(arena, capture_inline_limit, saved)
    else if (ephemeral_store) |ephemeral|
        command_replay_store.Capture.createEphemeral(arena, capture_inline_limit, ephemeral)
    else
        command_replay_store.Capture.create(arena, capture_inline_limit, null)) catch |err| {
        if (policy == .required) return err;
        debug_trace.logf(
            "session",
            "command replay capture initialization unavailable err={s}",
            .{@errorName(err)},
        );
        return .{ .unavailable = true };
    };
    capture.setPolicyBeforeCapture(policy);
    capture.setComparisonLimit(comparison_limit);
    return .{ .capture = capture };
}

fn finishCommandToolResult(
    arena: Allocator,
    capture: ?*command_replay_store.Capture,
    replay_unavailable: bool,
    replay_transferred: *bool,
    process_result: ?command_contract.RunCommandResult,
    result: ToolExecutionResult,
) !ToolExecutionResult {
    var owned = result;
    if (capture) |candidate| switch (candidate.policy()) {
        .required => candidate.sealRequired(arena) catch {
            owned = try command_result_mapping.Command.outputCaptureFailure(arena);
        },
        .best_effort => {},
    };
    if (process_result) |command_result| {
        if (commandProcessPresentation(command_result)) |presentation| {
            var memory = owned.tool_result_memory orelse types.ToolResultMemory{};
            memory.command_process_presentation = presentation;
            owned.tool_result_memory = memory;
        }
    }
    if (replay_unavailable) {
        var memory = owned.tool_result_memory orelse types.ToolResultMemory{};
        memory.command_output_replay = .unavailable;
        owned.tool_result_memory = memory;
    }
    owned.command_replay_capture = capture;
    if (capture != null) replay_transferred.* = true;
    return owned;
}

fn commandProcessPresentation(
    result: command_contract.RunCommandResult,
) ?types.CommandProcessPresentation {
    const command_result = result.command_result orelse return null;
    const foreground = command_result;
    if (foreground.timed_out) return .timed_out;
    if (foreground.signal) |signal| return .{ .signal = signal };
    if (foreground.exit_code) |exit_code| {
        if (exit_code != 0) return .{ .exit_code = exit_code };
    }
    return null;
}

const SubagentProviderState = struct {
    runtime: Context,
    call: ToolCall,
    completion_sink: *?types.SubagentStatus,
};

fn requestDerivedSubagentSessionTitle(alloc: Allocator, call: ToolCall) Allocator.Error!?[]u8 {
    const action = try tool_presentation.subagentAction(alloc, call, .identity) orelse return null;
    alloc.free(action.detail);
    return action.label;
}

const SubagentProgressBridge = struct {
    alloc: Allocator,
    call: ToolCall,
    renderer: types.SubagentStatusRenderer,
    progress_ctx: *anyopaque,
    progress_fn: *const fn (*anyopaque, types.ToolLifecycleId, []const u8) void,
    lifecycle_id: types.ToolLifecycleId,

    fn init(alloc: Allocator, ctx: Context, call: ToolCall) ?SubagentProgressBridge {
        return .{
            .alloc = alloc,
            .call = call,
            .renderer = ctx.subagent_status_renderer orelse return null,
            .progress_ctx = ctx.tool_progress_ctx orelse return null,
            .progress_fn = ctx.on_tool_progress orelse return null,
            .lifecycle_id = ctx.output_chunk_lifecycle_id orelse return null,
        };
    }

    fn sink(self: *SubagentProgressBridge) subagent_tool_host.ProgressSink {
        return .{ .context = self, .publish_fn = publish };
    }

    fn publish(raw: *anyopaque, status: types.SubagentStatus) void {
        const self: *SubagentProgressBridge = @ptrCast(@alignCast(raw));
        var rendered_status = status;
        const session_title = requestDerivedSubagentSessionTitle(self.alloc, self.call) catch null;
        defer if (session_title) |title| self.alloc.free(title);
        rendered_status.session_title = session_title;
        var status_buf: [256]u8 = undefined;
        const status_line = self.renderer.render(&status_buf, rendered_status);
        if (status_line.len == 0) return;
        const first_line = (tool_presentation.formatSubagentPlainAction(self.alloc, self.call, .active) catch return) orelse return;
        defer self.alloc.free(first_line);
        const row = std.fmt.allocPrint(self.alloc, "● {s}\n  {s}", .{ first_line, status_line }) catch return;
        defer self.alloc.free(row);
        self.progress_fn(self.progress_ctx, self.lifecycle_id, row);
    }
};

fn subagentProviderFailure(
    alloc: Allocator,
    error_code: []const u8,
) Allocator.Error!subagent_tool_provider.Result {
    const body = subagent_model_contract.encodeResultAlloc(alloc, .{
        .ok = false,
        .error_code = error_code,
    }) catch return error.OutOfMemory;
    return .{ .status = .failure, .body = body };
}

fn executeSubagentProvider(
    raw_context: ?*anyopaque,
    arena: Allocator,
    request: *subagent_model_contract.Request,
    invocation_id: []const u8,
) subagent_tool_provider.ExecuteError!subagent_tool_provider.Result {
    const state: *SubagentProviderState = @ptrCast(@alignCast(raw_context.?));
    const ctx = state.runtime;
    const host = ctx.subagent_host orelse
        return subagentProviderFailure(arena, "host_unavailable");
    const caller_id = ctx.subagent_caller_id orelse
        return subagentProviderFailure(arena, "caller_unavailable");
    const identity_epoch = host.issueOperationIdentity(invocation_id);
    var progress_bridge = SubagentProgressBridge.init(arena, ctx, state.call);
    const output = host.executeManaged(arena, request, .{
        .caller_id = caller_id,
        .invocation_id = invocation_id,
        .parent_permission_mode = ctx.permission_mode,
        .root_user_intent_context = ctx.root_user_intent_context,
        .root_user_messages = ctx.root_user_messages,
        .root_user_evidence_complete = ctx.root_user_evidence_complete,
        .defaults = .{
            .provider = ctx.provider,
            .model = ctx.model,
            .effort = ctx.effort,
            .fast_mode = ctx.fast_mode,
            .conversation_language = ctx.session.languageSnapshot(),
        },
        .max_result_bytes = ctx.max_tool_result_bytes,
        .timestamp_ms = io_mod.milliTimestamp(),
        .identity_epoch = identity_epoch,
        .cancel_flag = runtimeCancelFlag(ctx),
        .steering_worker = if (ctx.interactive) ctx.worker else null,
        .progress = if (progress_bridge) |*bridge| bridge.sink() else null,
        .model_capability_resolver = ctx.model_capability_resolver,
        .model_override_resolver = ctx.model_override_resolver,
    }) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        if (err == error.Cancelled) return error.Cancelled;
        return subagentProviderFailure(arena, "host_failure");
    };
    if (output.final_status) |status_value| {
        var status = status_value;
        status.session_title = requestDerivedSubagentSessionTitle(arena, state.call) catch null;
        state.completion_sink.* = status;
    }
    return .{
        .status = if (output.success) .success else .failure,
        .body = output.body,
    };
}

fn noopOutput(_: *anyopaque, _: ?types.ToolLifecycleId, _: command_contract.CommandOutputStream, _: []const u8) !void {}

const TestCapturedShellInput = struct {
    command: []u8,
    profile: ?command_environment.Profile,
    timeout_ms: u64,

    fn deinit(self: *TestCapturedShellInput, alloc: Allocator) void {
        alloc.free(self.command);
        alloc.destroy(self);
    }
};

fn decodeTestCapturedShell(
    ctx: tool_dispatch.DispatchContext,
    args_json: []const u8,
) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    var parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, args_json, .{}) catch
        return .{ .failure = try ctx.allocator.dupe(u8, "invalid captured shell input") };
    defer parsed.deinit();
    if (parsed.value != .object) {
        return .{ .failure = try ctx.allocator.dupe(u8, "invalid captured shell input") };
    }
    for (parsed.value.object.keys()) |name| {
        if (!std.mem.eql(u8, name, "action") and
            !std.mem.eql(u8, name, "command") and
            !std.mem.eql(u8, name, "profile") and
            !std.mem.eql(u8, name, "timeout_ms"))
        {
            return .{ .failure = try ctx.allocator.dupe(u8, "invalid captured shell input") };
        }
    }
    const action = parsed.value.object.get("action") orelse
        return .{ .failure = try ctx.allocator.dupe(u8, "invalid captured shell input") };
    const command = parsed.value.object.get("command") orelse
        return .{ .failure = try ctx.allocator.dupe(u8, "invalid captured shell input") };
    if (action != .string or !std.mem.eql(u8, action.string, "run") or
        command != .string)
    {
        return .{ .failure = try ctx.allocator.dupe(u8, "invalid captured shell input") };
    }
    const profile: ?command_environment.Profile = if (parsed.value.object.get("profile")) |value| blk: {
        if (value == .null) break :blk null;
        if (value != .string) {
            return .{ .failure = try ctx.allocator.dupe(u8, "invalid captured shell input") };
        }
        break :blk std.meta.stringToEnum(
            command_environment.Profile,
            value.string,
        ) orelse return .{ .failure = try ctx.allocator.dupe(
            u8,
            "invalid captured shell input",
        ) };
    } else null;
    const timeout_ms: u64 = if (parsed.value.object.get("timeout_ms")) |value| blk: {
        if (value != .integer or value.integer <= 0) {
            return .{ .failure = try ctx.allocator.dupe(u8, "invalid captured shell input") };
        }
        break :blk @intCast(value.integer);
    } else 600_000;
    const input = try ctx.allocator.create(TestCapturedShellInput);
    errdefer ctx.allocator.destroy(input);
    input.* = .{
        .command = try ctx.allocator.dupe(u8, command.string),
        .profile = profile,
        .timeout_ms = timeout_ms,
    };
    return .{ .input = .{
        .ptr = input,
        .deinit_fn = struct {
            fn deinit(raw: *anyopaque, alloc: Allocator) void {
                const value: *TestCapturedShellInput = @ptrCast(@alignCast(raw));
                value.deinit(alloc);
            }
        }.deinit,
    } };
}

fn validateTestCapturedShell(
    _: tool_dispatch.DispatchContext,
    _: tool_dispatch.ToolInput,
) tool_dispatch.DispatchError!?[]u8 {
    return null;
}

fn testCapturedShellFalse(_: tool_dispatch.ToolInput) bool {
    return false;
}

fn callTestCapturedShell(
    ctx: tool_dispatch.DispatchContext,
    erased: tool_dispatch.ToolInput,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const input = erased.as(TestCapturedShellInput);
    const backend = ctx.run_command_backend orelse return .{
        .failure = try ctx.allocator.dupe(u8, "captured shell backend unavailable"),
    };
    var shell_buffer: [4096]u8 = undefined;
    const configured = shell_resolver.configuredLoginShellInto(&shell_buffer);
    const environment = shell_resolver.environment(
        ctx.allocator,
        configured,
        input.profile,
    ) catch return .{
        .failure = try ctx.allocator.dupe(u8, "captured shell profile unavailable"),
    };
    defer switch (environment) {
        .clean, .user => |path| ctx.allocator.free(path),
        .legacy, .workspace_clean => {},
    };
    return backend.execute(ctx, .{
        .command = input.command,
        .resolved_cwd = ctx.workspace_root,
        .environment = environment,
        .timeout_ms = input.timeout_ms,
    });
}

const test_captured_shell = blk: {
    var tool = test_builtin_tools.shell;
    tool.executor_kind = .run_command;
    tool.decode = decodeTestCapturedShell;
    tool.validate = validateTestCapturedShell;
    tool.call = callTestCapturedShell;
    tool.captured_command_fn = null;
    tool.process_local_fn = null;
    tool.reads_only_fn = testCapturedShellFalse;
    tool.irreversible_fn = testCapturedShellFalse;
    break :blk tool;
};

const test_tool_registry = tool_dispatch.Registry{ .tools = &.{
    test_builtin_tools.glob_files,
    test_builtin_tools.grep_files,
    test_builtin_tools.read_file,
    test_builtin_tools.write_file,
    test_builtin_tools.edit_file,
    test_builtin_tools.web_fetch,
    test_builtin_tools.web_search,
    test_captured_shell,
    test_builtin_tools.capability_search,
    test_builtin_tools.skill,
    test_builtin_tools.install_skill,
    test_builtin_tools.subagent,
    test_builtin_tools.ask_user_question,
    test_builtin_tools.read_tool_result,
} };

fn matchesTestRunCommandCompatibility(command: []const u8) bool {
    return std.mem.startsWith(u8, command, "fx-compatibility-probe");
}

fn executeTestRunCommandCompatibility(
    ctx: tool_dispatch.DispatchContext,
    _: []const u8,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    return .{ .success = try ctx.allocator.dupe(u8, "registered compatibility\n") };
}

const test_compatible_tool = blk: {
    var tool = test_builtin_tools.install_skill;
    tool.run_command_compatibility = .{
        .matches = matchesTestRunCommandCompatibility,
        .execute = executeTestRunCommandCompatibility,
    };
    break :blk tool;
};

fn executeFailingRunCommandCompatibility(
    ctx: tool_dispatch.DispatchContext,
    _: []const u8,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    return .{ .failure = try tool_result_errors.formatToolExecutionErrorJson(
        ctx.allocator,
        "shell",
        error.SkillInstallFailed,
    ) };
}

const test_failing_compatible_tool = blk: {
    var tool = test_builtin_tools.install_skill;
    tool.run_command_compatibility = .{
        .matches = matchesTestRunCommandCompatibility,
        .execute = executeFailingRunCommandCompatibility,
    };
    break :blk tool;
};

const test_compatibility_registry = tool_dispatch.Registry{ .tools = &.{
    test_captured_shell,
    test_compatible_tool,
} };

const test_failing_compatibility_registry = tool_dispatch.Registry{ .tools = &.{
    test_captured_shell,
    test_failing_compatible_tool,
} };

fn gatherNoopTestContext(_: Allocator, _: context_contract.InitialContextInput) context_contract.ProviderError!context_contract.ProviderContext {
    return .{};
}

fn appendNoopTestStaticContext(_: context_contract.StaticContextInput, _: Allocator, _: *std.ArrayList(ChatMessage)) context_contract.ProviderError!void {}

fn appendNoopTestTransientContext(_: context_contract.TransientContextInput, _: Allocator, _: *std.ArrayList(ChatMessage)) context_contract.ProviderError!void {}

const test_context_registry = context_contract.Registry{ .default_provider = .{
    .id = "test.tool_runtime_context",
    .gather_project_context_fn = gatherNoopTestContext,
    .select_applicable_project_context_fn = context_contract.selectNoApplicableProjectContext,
    .append_static_fn = appendNoopTestStaticContext,
    .append_transient_fn = appendNoopTestTransientContext,
} };

const test_review_calls = [_]ToolCall{
    .{ .id = "test-review", .name = "shell", .arguments_json = "{\"action\":\"run\",\"command\":\"printf test\",\"timeout_ms\":600000}" },
};
const test_review_root_messages = [_][]const u8{"test root request"};

fn testReviewTurn() permission_auto_classifier.ReviewTurnContext {
    return .{
        .model = "openai/gpt-5",
        .pending_assistant = .{ .role = .assistant, .tool_calls = &test_review_calls },
        .target_call_id = "test-review",
        .origin = .root,
        .trusted_root_context = test_review_root_messages[0],
    };
}

const TestRuntime = struct {
    agent_stream_provider: agent_stream_provider.Provider = agent_stream_provider.unavailable_provider,
    tool_registry: tool_dispatch.Registry = test_tool_registry,
    worker: WorkerRuntime = .{},
    session: SessionRuntime = .{ .max_history_turns = 8 },
    subagent_host: ?*subagent_tool_host.Runtime = null,
    subagent_caller_id: ?[]const u8 = null,
    model: []const u8 = "",
    reviewer_model: []const u8 = "",
    session_allocator: Allocator = std.testing.allocator,
    workspace_root: []const u8 = "/tmp",
    ignored_list_entries: []const []const u8 = &.{},
    skills_dir: []const u8 = "",
    tracker: ?*change_tracker.ChangeTracker = null,
    permission_rules: types.PermissionRuleSet = .{},
    permission_grants: []const PermissionGrant = &.{},
    session_grants: []const PermissionGrant = &.{},
    cancel_flag: ?*std.atomic.Value(bool) = null,
    permission_mode: PermissionMode = .yolo,
    max_command_output_bytes: usize = 64 * 1024,
    max_tool_result_bytes: usize = 64 * 1024,
    api_key: []const u8 = "",
    provider: model_provider.ProviderId = .openrouter,
    provider_capabilities: provider_set.Bundle.Capabilities = .{
        .fx_search = true,
        .vision_fallback = true,
    },
    gateway_team: ?[]const u8 = null,
    gateway_retry_count: usize = 0,
    gateway_chat_url: []const u8 = "",
    context_limits: context_limits.Values = .{},
    command_artifact_dir: ?[]const u8 = null,
    session_child_capability: ?*session_child_store.SessionChildCapability = null,
    ephemeral_command_replay: ?*command_replay_store.EphemeralStore = null,
    command_timeout_ms: ?usize = null,
    interactive: bool = true,

    advertised_dynamic_tool_names: []const []const u8 = &.{},
    auto_classifier: permission_auto_classifier.Classifier = .disabled(),
    web_search_runtime_ready: bool = false,
    web_search_backend: ?tool_dispatch.WebSearchBackend = null,
    web_search_progress_ctx: ?*anyopaque = null,
    on_web_search_progress: ?tool_dispatch.WebSearchProgressFn = null,
    web_fetch_runtime: ?*web_fetch_runtime.Runtime = null,
    web_fetch_artifact_store: ?*web_fetch_artifacts.Store = null,
    web_fetch_artifact_error: ?anyerror = null,
    web_fetch_progress_ctx: ?*anyopaque = null,
    on_web_fetch_progress: ?tool_dispatch.WebFetchProgressFn = null,

    fn deinit(self: *TestRuntime, alloc: Allocator) void {
        self.worker.deinit(alloc);
        self.session.deinit(alloc);
    }

    fn context(self: *TestRuntime) Context {
        return .{
            .workspace_root = self.workspace_root,
            .ignored_list_entries = self.ignored_list_entries,
            .max_list_entries = 100,
            .max_read_file_bytes = 64 * 1024,
            .max_read_file_lines = 400,
            .max_read_file_line_len = 2000,
            .max_command_output_bytes = self.max_command_output_bytes,
            .max_tool_result_bytes = self.max_tool_result_bytes,
            .api_key = self.api_key,
            .agent_stream_provider = self.agent_stream_provider,
            .gateway_team = self.gateway_team,
            .provider = self.provider,
            .provider_capabilities = self.provider_capabilities,
            .model = self.model,
            .reviewer_model = self.reviewer_model,
            .gateway_retry_count = self.gateway_retry_count,
            .gateway_chat_url = self.gateway_chat_url,
            .agent_step_limit = 0,
            .permission_mode = self.permission_mode,
            .permission_grants = self.permission_grants,
            .session_grants = self.session_grants,
            .permission_rules = self.permission_rules,
            .tool_registry = self.tool_registry,
            .subagent_host = self.subagent_host,
            .subagent_caller_id = self.subagent_caller_id,
            .worker = &self.worker,
            .permission_prompter = if (self.interactive)
                tool_admission.workerPrompter(&self.worker)
            else
                null,
            .cancel_flag = self.cancel_flag,
            .session = &self.session,
            .session_allocator = self.session_allocator,
            .skills_dir = self.skills_dir,
            .context_registry = test_context_registry,
            .context_limits = self.context_limits,
            .output_chunk_ctx = undefined,
            .on_output_chunk = noopOutput,
            .command_artifact_dir = self.command_artifact_dir,
            .session_child_capability = self.session_child_capability,
            .ephemeral_command_replay = self.ephemeral_command_replay,
            .command_timeout_ms = self.command_timeout_ms,
            .tracker = self.tracker,

            .advertised_dynamic_tool_names = self.advertised_dynamic_tool_names,
            .auto_classifier = self.auto_classifier,
            .permission_review_turn = testReviewTurn(),
            .web_fetch_runtime = self.web_fetch_runtime,
            .web_fetch_artifact_store = self.web_fetch_artifact_store,
            .web_fetch_artifact_error = self.web_fetch_artifact_error,
            .web_search_runtime_ready = self.web_search_runtime_ready,
            .web_search_backend = self.web_search_backend,
            .web_search_progress_ctx = self.web_search_progress_ctx,
            .on_web_search_progress = self.on_web_search_progress,
            .web_fetch_progress_ctx = self.web_fetch_progress_ctx,
            .on_web_fetch_progress = self.on_web_fetch_progress,
            .interactive = self.interactive,
        };
    }
};

const CancelTestCommandOnOutput = struct {
    flag: *std.atomic.Value(bool),
    needle: []const u8,
    seen: bool = false,

    fn onChunk(ctx: *anyopaque, _: ?types.ToolLifecycleId, _: command_contract.CommandOutputStream, chunk: []const u8) !void {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        if (std.mem.find(u8, chunk, self.needle) == null) return;
        self.seen = true;
        self.flag.store(true, .seq_cst);
    }
};

fn runCommandArgsForTest(alloc: Allocator, command: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll("{\"action\":\"run\",\"command\":");
    try std.json.Stringify.value(command, .{}, &out.writer);
    try out.writer.writeAll(",\"timeout_ms\":600000}");
    return out.toOwnedSlice();
}

fn executeTestRunCommand(
    ctx: Context,
    arena: Allocator,
    call: ToolCall,
) !ToolExecutionResult {
    const terminal_call = try terminalExecCallForTest(arena, call);
    const command_ctx = try tool_admission.runCommandContext(ctx.admissionInput(), arena, terminal_call);
    return executeToolCallAuthorized(ctx, .{
        .call_allocator = arena,
        .result_allocator = arena,
        .call = terminal_call,
        .authority = .{ .run_command = .{ .shell_allowed = .{
            .fingerprint = .init(command_ctx),
            .source = .configured_rule,
        } } },
        .session_grants = ctx.session_grants,
        .advertised_dynamic_tool_names = ctx.advertised_dynamic_tool_names,
        .max_tool_result_bytes = ctx.max_tool_result_bytes,
    });
}

fn terminalExecCallForTest(arena: Allocator, call: ToolCall) !ToolCall {
    if (std.mem.eql(u8, call.name, "shell")) return call;
    if (!std.mem.eql(u8, call.name, "run_command")) return call;
    var args = try std.json.parseFromSliceLeaky(
        std.json.Value,
        arena,
        call.arguments_json,
        .{ .allocate = .alloc_always },
    );
    if (args != .object) return error.InvalidToolArguments;
    try args.object.put(arena, "action", .{ .string = "run" });
    try args.object.put(arena, "timeout_ms", .{ .integer = 600_000 });
    var out: std.Io.Writer.Allocating = .init(arena);
    defer out.deinit();
    try std.json.Stringify.value(args, .{}, &out.writer);
    var migrated = call;
    migrated.name = "shell";
    migrated.arguments_json = try out.toOwnedSlice();
    return migrated;
}

fn unexpectedTestPrompt(
    _: *anyopaque,
    _: Allocator,
    _: permission_request.PermissionRequest,
    _: ToolCall,
    _: ?*const diff_mod.FileReview,
    _: ?[]const types.PermissionGrant,
) anyerror!permission_request.OwnedPermissionResponse {
    return error.TestUnexpectedPrompt;
}

const TestAutoReview = struct {
    calls: usize = 0,
    decision: permission_auto_classifier.Decision = .clear,
    risk: permission_auto_classifier.Risk = .low,
    rationale: []const u8 = "test automatic review",
    action_tag: ?std.meta.Tag(permission_auto_classifier.Action) = null,
    exact_command: ?[]const u8 = null,
    exact_arguments_json: ?[]const u8 = null,
    file_display_path: ?[]const u8 = null,
    file_additions: usize = 0,
    file_deletions: usize = 0,
    file_review_rows: usize = 0,
    target_path: ?[]const u8 = null,

    fn review(
        raw_ctx: *anyopaque,
        alloc: Allocator,
        request: permission_auto_classifier.ReviewRequest,
    ) anyerror!permission_auto_classifier.ParseOutcome {
        const self: *@This() = @ptrCast(@alignCast(raw_ctx));
        self.calls += 1;
        self.target_path = if (request.targets.len > 0)
            request.targets[0].path
        else
            null;
        self.action_tag = std.meta.activeTag(request.action);
        switch (request.action) {
            .shell_input => |shell_input| self.exact_arguments_json = shell_input.arguments_json,
            .command => |command| self.exact_command = command.command,
            .file_mutation => |file| {
                self.file_display_path = file.display_path;
                self.file_additions = file.additions;
                self.file_deletions = file.deletions;
                self.file_review_rows = file.review.rowCount();
            },
            .tool => |tool| {
                self.exact_arguments_json = tool.arguments_json;
            },
        }
        return .{ .valid = .{
            .risk = self.risk,
            .decision = self.decision,
            .rationale = try alloc.dupe(u8, self.rationale),
        } };
    }

    fn classifier(self: *@This()) permission_auto_classifier.Classifier {
        return .withOverride(self, review);
    }
};

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.find(u8, haystack, needle) != null);
}

fn expectNotContains(haystack: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.find(u8, haystack, needle) == null);
}

fn expectCommandResultField(json: []const u8, field: []const u8, expected: []const u8) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    const value = parsed.value.object.get(field) orelse return error.TestExpectedEqual;
    try std.testing.expect(value == .string);
    try std.testing.expectEqualStrings(expected, value.string);
}

fn expectCommandResultBool(json: []const u8, field: []const u8, expected: bool) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    const value = parsed.value.object.get(field) orelse return error.TestExpectedEqual;
    try std.testing.expect(value == .bool);
    try std.testing.expectEqual(expected, value.bool);
}

fn expectCommandResultInt(json: []const u8, field: []const u8, expected: anytype) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    const value = parsed.value.object.get(field) orelse return error.TestExpectedEqual;
    try std.testing.expect(value == .integer);
    try std.testing.expectEqual(@as(i64, @intCast(expected)), value.integer);
}

fn expectCommandResultNull(json: []const u8, field: []const u8) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    const value = parsed.value.object.get(field) orelse return error.TestExpectedEqual;
    try std.testing.expect(value == .null);
}

fn expectCommandResultStringPrefix(json: []const u8, field: []const u8, prefix: []const u8) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    const value = parsed.value.object.get(field) orelse return error.TestExpectedEqual;
    try std.testing.expect(value == .string);
    try std.testing.expect(std.mem.startsWith(u8, value.string, prefix));
}

fn expectToolErrorField(json: []const u8, field: []const u8, expected: []const u8) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    const error_obj = parsed.value.object.get("error").?.object;
    const value = error_obj.get(field) orelse return error.TestExpectedEqual;
    try std.testing.expect(value == .string);
    try std.testing.expectEqualStrings(expected, value.string);
}

fn expectToolErrorDetailString(json: []const u8, field: []const u8, expected: []const u8) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    const details = parsed.value.object.get("error").?.object.get("details").?.object;
    const value = details.get(field) orelse return error.TestExpectedEqual;
    try std.testing.expect(value == .string);
    try std.testing.expectEqualStrings(expected, value.string);
}

fn expectToolErrorDetailInt(json: []const u8, field: []const u8, expected: i64) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    const details = parsed.value.object.get("error").?.object.get("details").?.object;
    const value = details.get(field) orelse return error.TestExpectedEqual;
    try std.testing.expect(value == .integer);
    try std.testing.expectEqual(expected, value.integer);
}

fn writeTestFile(dir: std.Io.Dir, path: []const u8, content: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| {
        try dir.createDirPath(io_mod.getIo(), parent);
    }
    var file = try dir.createFile(std.testing.io, path, .{ .truncate = true });
    defer file.close(io_mod.getIo());
    try file.writeStreamingAll(io_mod.getIo(), content);
}

fn writeLargeTestFile(dir: std.Io.Dir, path: []const u8, prefix: []const u8, fill_len: usize) !void {
    if (std.fs.path.dirname(path)) |parent| {
        try dir.createDirPath(io_mod.getIo(), parent);
    }
    var file = try dir.createFile(std.testing.io, path, .{ .truncate = true });
    defer file.close(io_mod.getIo());
    try file.writeStreamingAll(io_mod.getIo(), prefix);

    var chunk: [4096]u8 = undefined;
    @memset(&chunk, 'x');
    var remaining = fill_len;
    while (remaining > 0) {
        const n = @min(remaining, chunk.len);
        try file.writeStreamingAll(io_mod.getIo(), chunk[0..n]);
        remaining -= n;
    }
}

fn readTraceFileForTest(alloc: Allocator, trace_path: []const u8) ![]u8 {
    var file = try std.Io.Dir.openFileAbsolute(std.testing.io, trace_path, .{});
    defer file.close(io_mod.getIo());
    var read_buf: [1024]u8 = undefined;
    var reader = file.reader(std.testing.io, &read_buf);
    return reader.interface.allocRemaining(alloc, std.Io.Limit.limited(64 * 1024));
}

const WebSearchBackendFixture = struct {
    calls: usize = 0,

    fn search(
        raw_ctx: *anyopaque,
        ctx: tool_dispatch.DispatchContext,
        request: web_search_contract.Request,
    ) anyerror!web_search_contract.ExecutionOutput {
        const self: *@This() = @ptrCast(@alignCast(raw_ctx));
        self.calls += 1;
        if (ctx.on_web_search_progress) |on_progress| {
            on_progress(ctx.web_search_progress_ctx.?, ctx.tool_call_id, .{ .query_started = request.query });
            on_progress(ctx.web_search_progress_ctx.?, ctx.tool_call_id, .{ .results_received = .{
                .query = request.query,
                .result_count = 3,
            } });
        }
        return .{
            .output = .{
                .query = request.query,
                .results = &.{},
                .duration_ms = 17,
                .web_search_requests = 2,
            },
            .inner_usage = .{ .input_tokens = 12, .output_tokens = 34, .web_search_requests = 2 },
        };
    }
};

const WebSearchProgressCapture = struct {
    searching_count: usize = 0,
    found_count: usize = 0,
    call_id: []const u8 = "",
    query_buf: [128]u8 = undefined,
    query_len: usize = 0,
    result_count: usize = 0,

    fn onProgress(raw_ctx: *anyopaque, call_id: []const u8, progress: types.WebSearchProgress) void {
        const self: *@This() = @ptrCast(@alignCast(raw_ctx));
        self.call_id = call_id;
        switch (progress) {
            .query_started => |query| {
                self.searching_count += 1;
                self.setQuery(query);
            },
            .results_received => |update| {
                self.found_count += 1;
                self.setQuery(update.query);
                self.result_count = update.result_count;
            },
        }
    }

    fn setQuery(self: *@This(), query: []const u8) void {
        self.query_len = @min(self.query_buf.len, query.len);
        @memcpy(self.query_buf[0..self.query_len], query[0..self.query_len]);
    }

    fn queryView(self: *const @This()) []const u8 {
        return self.query_buf[0..self.query_len];
    }
};

fn expectToolOutput(ctx: Context, tool_name: []const u8, args_json: []const u8, expected: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const result = try executeToolCall(ctx, arena, .{
        .id = "1",
        .name = tool_name,
        .arguments_json = args_json,
    });
    try std.testing.expectEqualStrings(expected, result.model_output);
    if (result.diff_entry) |payload| {
        diff_mod.freeDiffEntryPayload(std.heap.c_allocator, payload);
    }
}

fn absolutePathExists(path: []const u8) bool {
    _ = std.Io.Dir.cwd().statFile(io_mod.getIo(), path, .{}) catch return false;
    return true;
}

fn setTestHome(home: ?[]const u8) !void {
    const map = try std.heap.c_allocator.create(std.process.Environ.Map);
    map.* = std.process.Environ.Map.init(std.heap.c_allocator);
    if (home) |value| try map.put("HOME", value);
    io_mod.setEnvironMap(map);
}

fn registryOwnedWebFetchCall(
    ctx: tool_dispatch.DispatchContext,
    input: tool_dispatch.ToolInput,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    _ = input;
    return .{ .success = try ctx.allocator.dupe(u8, "registry-owned web_fetch") };
}

fn registryOwnedWebSearchCall(
    ctx: tool_dispatch.DispatchContext,
    input: tool_dispatch.ToolInput,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    _ = input;
    return .{ .success = try ctx.allocator.dupe(u8, "registry-owned web_search") };
}

fn registryOwnedTerminalExecCall(
    ctx: tool_dispatch.DispatchContext,
    input: tool_dispatch.ToolInput,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    _ = input;
    return .{ .success = try ctx.allocator.dupe(u8, "registry-owned terminal exec") };
}

fn registryOwnedAskQuestionCall(
    ctx: tool_dispatch.DispatchContext,
    input: tool_dispatch.ToolInput,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    _ = input;
    if (ctx.ask_question_ctx == null or ctx.ask_question_batch == null) {
        return error.InvalidToolArguments;
    }
    return .{ .success = try ctx.allocator.dupe(u8, "registry-owned ask_user_question") };
}

fn registryOwnedSkillCall(
    ctx: tool_dispatch.DispatchContext,
    input: tool_dispatch.ToolInput,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    _ = input;
    return .{ .success = try ctx.allocator.dupe(u8, "registry-owned skill") };
}

fn registryOwnedInstallSkillCall(
    ctx: tool_dispatch.DispatchContext,
    input: tool_dispatch.ToolInput,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    _ = input;
    return .{ .success = try ctx.allocator.dupe(u8, "registry-owned install_skill") };
}

fn registryOwnedCapabilitySearchCall(
    ctx: tool_dispatch.DispatchContext,
    input: tool_dispatch.ToolInput,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    _ = input;
    return .{ .success = try ctx.allocator.dupe(u8, "registry-owned capability_search") };
}

const QuestionBridgeThreadState = struct {
    worker: *WorkerRuntime,
    entries: []const types.QuestionBatchEntry,
    answers: ?[][]u8 = null,
    err: ?Allocator.Error = null,
};

fn runQuestionBridge(state: *QuestionBridgeThreadState) void {
    state.answers = requestQuestionBatchWithWorker(
        state.worker,
        std.testing.allocator,
        state.entries,
    ) catch |err| {
        state.err = err;
        return;
    };
}

fn waitForQuestionBridgeSnapshot(worker: *WorkerRuntime) !worker_runtime.PendingQuestionBatchSnapshot {
    var attempts: usize = 0;
    while (attempts < 100) : (attempts += 1) {
        if (try worker.snapshotPendingQuestionBatch(std.testing.allocator)) |snapshot| return snapshot;
        io_mod.sleep(std.time.ns_per_ms);
    }
    return error.TestExpectedEqual;
}

const PermissionThreadState = struct {
    decision: ?ToolPermissionDecision = null,
    err: ?anyerror = null,
};

const FilePermissionThreadState = struct {
    decision: ?ToolPermissionDecision = null,
    file_authority: bool = false,
    prepared: bool = false,
    additions: usize = 0,
    expected_grant_target: []const u8 = "",
    expected_workspace_offer: bool = false,
    frozen_offer_matches: bool = false,
    err: ?anyerror = null,
};

fn runFilePermissionOutcome(
    state: *FilePermissionThreadState,
    req_ctx: Context,
    call: ToolCall,
    mode: PermissionMode,
) void {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const outcome = tool_admission.requestPermissionOutcome(
        req_ctx.admissionInput(),
        arena_state.allocator(),
        call,
        mode,
        &.{},
    ) catch |err| {
        state.err = err;
        return;
    };
    if (outcome.tool_failure != null) {
        state.err = error.UnexpectedToolFailure;
        return;
    }
    state.decision = outcome.decision;
    const authority = outcome.execution_authority orelse return;
    switch (authority) {
        .file_mutation => |file_authority| {
            state.file_authority = true;
            state.prepared = file_authority.prepared != null;
            if (file_authority.prepared) |prepared| {
                state.additions = prepared.preview.additions;
            }
            if (file_authority.grant_offer) |offer| {
                state.frozen_offer_matches = fileGrantOfferMatchesExpectation(
                    offer,
                    state.expected_grant_target,
                    state.expected_workspace_offer,
                );
            }
        },
        else => state.err = error.UnexpectedExecutionAuthority,
    }
}

fn fileGrantOfferMatchesExpectation(
    offer: file_mutation_contract.FileGrantOffer,
    expected_target: []const u8,
    expected_workspace: bool,
) bool {
    const workspace_permissions = [_][]const u8{ "edit", "read", "glob", "grep" };
    for (offer.grants) |grant| {
        if (!std.mem.eql(u8, grant.target_path, expected_target)) return false;
    }
    if (expected_workspace) {
        if (offer.scope != .workspace_files) return false;
        if (offer.grants.len != workspace_permissions.len) return false;
        for (workspace_permissions) |permission| {
            var found = false;
            for (offer.grants) |grant| {
                found = found or std.mem.eql(
                    u8,
                    grant.tool_name,
                    permission,
                );
            }
            if (!found) return false;
        }
        return true;
    }
    return switch (offer.scope) {
        .workspace_files => false,
        .external_tree => |root| offer.grants.len == 1 and
            std.mem.eql(u8, offer.grants[0].tool_name, "edit") and
            std.mem.eql(
                u8,
                root,
                expected_target[0 .. expected_target.len - "/**".len],
            ),
    };
}

fn testFileMutationArgs(
    alloc: Allocator,
    kind: file_mutation_contract.Kind,
    path: []const u8,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll("{\"path\":");
    try std.json.Stringify.value(path, .{}, &out.writer);
    switch (kind) {
        .write => {
            try out.writer.writeAll(",\"content\":\"after\\n\"}");
        },
        .edit => {
            try out.writer.writeAll(
                ",\"old_string\":\"before\\n\",\"new_string\":\"after\\n\"}",
            );
        },
    }
    return try out.toOwnedSlice();
}

fn testMaxAdmittedLexicalPath(
    alloc: Allocator,
    basename: []const u8,
) ![]u8 {
    if (basename.len > std.Io.Dir.max_path_bytes) {
        return error.NameTooLong;
    }
    const path = try alloc.alloc(u8, std.Io.Dir.max_path_bytes);
    var cursor: usize = 0;
    var remaining = path.len - basename.len;
    if (remaining % 2 != 0) {
        if (remaining < "x/../".len) return error.NameTooLong;
        @memcpy(path[cursor..][0.."x/../".len], "x/../");
        cursor += "x/../".len;
        remaining -= "x/../".len;
    }
    while (remaining > 0) : (remaining -= 2) {
        @memcpy(path[cursor..][0..2], "./");
        cursor += 2;
    }
    @memcpy(path[cursor..][0..basename.len], basename);
    return path;
}

fn runPermissionRequest(state: *PermissionThreadState, req_ctx: Context, call: ToolCall, mode: PermissionMode) void {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const outcome = tool_admission.requestPermissionOutcome(req_ctx.admissionInput(), arena_state.allocator(), call, mode, &.{}) catch |err| {
        state.err = err;
        return;
    };
    state.decision = outcome.decision;
}

fn waitForPermissionPrompt(worker: *WorkerRuntime, expected: []const u8) !u64 {
    var attempts: usize = 0;
    while (attempts < 100) : (attempts += 1) {
        var snapshot = try worker.snapshotState(std.testing.allocator);
        defer snapshot.deinit(std.testing.allocator);
        if (snapshot.pending_permission_request) |request| {
            try expectContains(request.label, expected);
            return request.id;
        }
        io_mod.sleep(1 * std.time.ns_per_ms);
    }
    return error.TestExpectedEqual;
}

const vision_test_registry_tools = [_]tool_dispatch.Tool{test_builtin_tools.vision};

const VisionGatewayResponse = struct {
    status: std.http.Status = .ok,
    content: ?[]const u8 = null,
    usage: types.Usage = .{},
    generation_id: ?[]const u8 = "gen_01ARZ3NDEKTSV4RRFFQ69G5FAV",
};

const VisionGatewayFixture = struct {
    alloc: Allocator,
    responses: []const VisionGatewayResponse,
    allocation_probe: ?*std.testing.FailingAllocator = null,
    allocation_index_at_stream: ?usize = null,
    payloads: std.ArrayList([]u8) = .empty,
    call_count: usize = 0,
    cancel_after_call: ?usize = null,
    last_api_key: []const u8 = "",
    last_team: ?[]const u8 = null,
    last_model: []const u8 = "",
    last_retry_count: usize = 0,

    fn deinit(self: *VisionGatewayFixture) void {
        for (self.payloads.items) |payload| self.alloc.free(payload);
        self.payloads.deinit(self.alloc);
    }

    fn provider(self: *VisionGatewayFixture) agent_stream_provider.Provider {
        var result = test_openrouter.agent_stream;
        result.context = self;
        result.stream_fn = stream;
        return result;
    }

    fn stream(
        context: ?*anyopaque,
        _: Allocator,
        request: agent_stream_provider.ModelRequest,
    ) anyerror!agent_stream_provider.Result {
        const self: *VisionGatewayFixture = @ptrCast(@alignCast(context.?));
        if (self.allocation_probe) |probe| {
            self.allocation_index_at_stream = probe.alloc_index;
        }
        const response_index = self.call_count;
        self.call_count += 1;
        const payload = try test_openrouter.buildRequest(self.alloc, request.data());
        defer self.alloc.free(payload);
        try self.payloads.append(self.alloc, try self.alloc.dupe(u8, payload));
        self.last_api_key = request.credential.secret() orelse "";
        self.last_team = request.credential.tenant();
        self.last_model = request.model;
        self.last_retry_count = request.retry_count;
        if (self.cancel_after_call == self.call_count) request.cancel_flag.store(true, .seq_cst);
        if (response_index >= self.responses.len) return error.UnexpectedVisionGatewayCall;
        const response = self.responses[response_index];
        try request.admission.admit();
        request.delivery.markPossiblySent();
        if (response.status != .ok) return .{ .failed = .{ .kind = .provider_error } };
        const credential_source = request.credential.credentialSource() orelse
            return error.MissingCredentialSource;
        return .{ .completed = .{
            .completion = .{
                .content = response.content,
                .generation_id = response.generation_id,
                .finish_reason = .stop,
                .usage = response.usage,
            },
            .usage = .{ .deferred = .{
                .provider = .openrouter,
                .generation_id = response.generation_id orelse "gen_test",
                .scope = "https://openrouter.ai/api/v1",
                .tenant = request.credential.tenant(),
                .credential_source = credential_source,
                .credential_identity = credential_authority.derive(
                    credential_source,
                    request.credential.accountId(),
                ),
            } },
        } };
    }
};

fn makeVisionCatalog(
    alloc: Allocator,
    dir: std.Io.Dir,
    count: usize,
) ![]types.ImageAttachment {
    const catalog = try alloc.alloc(types.ImageAttachment, count);
    errdefer alloc.free(catalog);
    var initialized: usize = 0;
    errdefer for (catalog[0..initialized]) |image| types.freeImageAttachment(alloc, image);
    const root = try io_mod.dirRealpathAlloc(alloc, dir, ".");
    defer alloc.free(root);
    const snapshot_dir = try std.fs.path.join(alloc, &.{ root, "snapshots" });
    defer alloc.free(snapshot_dir);
    for (catalog, 0..) |*image, index| {
        const name = try std.fmt.allocPrint(alloc, "vision-{d}.png", .{index + 1});
        defer alloc.free(name);
        try dir.writeFile(io_mod.getIo(), .{ .sub_path = name, .data = "\x89PNG\r\n\x1a\nimage bytes" });
        const path = try io_mod.dirRealpathAlloc(alloc, dir, name);
        var path_owned = true;
        errdefer if (path_owned) alloc.free(path);
        const media_type = try alloc.dupe(u8, "image/png");
        var media_type_owned = true;
        errdefer if (media_type_owned) alloc.free(media_type);
        image.* = .{ .id = index + 1, .path = path, .media_type = media_type };
        path_owned = false;
        media_type_owned = false;
        var image_initialized = false;
        errdefer if (!image_initialized) types.freeImageAttachment(alloc, image.*);
        try image_attachments.captureImageSnapshot(alloc, image, snapshot_dir);
        initialized += 1;
        image_initialized = true;
    }
    return catalog;
}

fn visionArgs(alloc: Allocator, image_ids: []const usize, focus: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll("{\"image_ids\":");
    try std.json.Stringify.value(image_ids, .{}, &out.writer);
    try out.writer.writeAll(",\"focus\":");
    try std.json.Stringify.value(focus, .{}, &out.writer);
    try out.writer.writeByte('}');
    return out.toOwnedSlice();
}

fn visionProviderSuccess(alloc: Allocator, image_ids: []const usize) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll("{\"images\":[");
    for (image_ids, 0..) |image_id, index| {
        if (index > 0) try out.writer.writeByte(',');
        try out.writer.print(
            "{{\"image_id\":{d},\"status\":\"ok\",\"summary\":\"evidence {d}\",\"visible_text\":[],\"details\":[]}}",
            .{ image_id, image_id },
        );
    }
    try out.writer.writeAll("]}");
    return out.toOwnedSlice();
}

fn visionProviderSuccessReversed(alloc: Allocator, image_ids: []const usize) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll("{\"images\":[");
    var index = image_ids.len;
    while (index > 0) {
        index -= 1;
        if (index + 1 < image_ids.len) try out.writer.writeByte(',');
        const image_id = image_ids[index];
        try out.writer.print(
            "{{\"image_id\":{d},\"status\":\"ok\",\"summary\":\"evidence {d}\",\"visible_text\":[],\"details\":[]}}",
            .{ image_id, image_id },
        );
    }
    try out.writer.writeAll("]}");
    return out.toOwnedSlice();
}

fn executeVisionForTest(
    rt: *TestRuntime,
    alloc: Allocator,
    args_json: []const u8,
    catalog: []const types.ImageAttachment,
) !ToolExecutionResult {
    return executeToolCallAuthorized(rt.context(), .{
        .call_allocator = alloc,
        .result_allocator = alloc,
        .call = .{ .id = "vision-call", .name = "vision", .arguments_json = args_json },
        .authority = .ordinary,
        .authorized_image_catalog = catalog,
        .session_grants = &.{},
        .advertised_dynamic_tool_names = &.{},
        .max_tool_result_bytes = rt.max_tool_result_bytes,
    });
}

fn executeVisionPathForTest(
    rt: *TestRuntime,
    alloc: Allocator,
    args_json: []const u8,
    canonical_paths: []const []const u8,
) !ToolExecutionResult {
    const targets = try alloc.alloc(
        command_admission.VisionPathExecutionTarget,
        canonical_paths.len,
    );
    var initialized: usize = 0;
    defer {
        for (targets[0..initialized]) |target| {
            alloc.free(@constCast(target.canonical_path));
        }
        alloc.free(targets);
    }
    for (canonical_paths, targets) |path, *target| {
        var file = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{
            .allow_directory = false,
            .follow_symlinks = false,
        });
        defer file.close(io_mod.getIo());
        const stat = try file.stat(io_mod.getIo());
        target.* = .{
            .canonical_path = try alloc.dupe(u8, path),
            .identity = pathing.fileIdentity(
                try pathing.descriptorDevice(file.handle),
                stat,
            ),
        };
        initialized += 1;
    }
    return executeVisionPathTargetsForTest(rt, alloc, args_json, targets);
}

fn executeVisionPathTargetsForTest(
    rt: *TestRuntime,
    alloc: Allocator,
    args_json: []const u8,
    targets: []const command_admission.VisionPathExecutionTarget,
) !ToolExecutionResult {
    return executeToolCallAuthorized(rt.context(), .{
        .call_allocator = alloc,
        .result_allocator = alloc,
        .call = .{ .id = "vision-call", .name = "vision", .arguments_json = args_json },
        .authority = .{ .vision_paths = .{ .targets = targets } },
        .authorized_image_catalog = &.{},
        .session_grants = &.{},
        .advertised_dynamic_tool_names = &.{},
        .max_tool_result_bytes = rt.max_tool_result_bytes,
    });
}

fn visionRequestAllocationCount(args_json: []const u8) !usize {
    var probe = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{ .resize_fail_index = 0 },
    );
    const alloc = probe.allocator();
    const request = try tool_contracts.vision.parse_vision_request(alloc, args_json);
    request.deinit(alloc);
    try std.testing.expectEqual(probe.allocated_bytes, probe.freed_bytes);
    return probe.alloc_index;
}

fn visionProviderParseAllocationCount(provider_json: []const u8) !usize {
    var probe = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{ .resize_fail_index = 0 },
    );
    const alloc = probe.allocator();
    const parsed = try tool_contracts.vision.parse_vision_provider_result(
        alloc,
        provider_json,
        provider_json.len,
    );
    parsed.deinit(alloc);
    try std.testing.expectEqual(probe.allocated_bytes, probe.freed_bytes);
    return probe.alloc_index;
}

fn visionAllocationIndexAtGateway(
    catalog: []const types.ImageAttachment,
    args_json: []const u8,
    provider_json: []const u8,
) !usize {
    const base = std.testing.allocator;
    var probe = std.testing.FailingAllocator.init(
        base,
        .{ .resize_fail_index = 0 },
    );
    const responses = [_]VisionGatewayResponse{.{ .content = provider_json }};
    var fixture = VisionGatewayFixture{
        .alloc = base,
        .responses = &responses,
        .allocation_probe = &probe,
    };
    defer fixture.deinit();
    var rt = TestRuntime{
        .agent_stream_provider = fixture.provider(),
        .tool_registry = .{ .tools = vision_test_registry_tools[0..] },
        .session_allocator = base,
        .context_limits = .{ .image_adapter_output_bytes = .{
            .value = .{ .bytes = 64 * 1024 },
            .source = .command_line,
        } },
    };
    defer rt.deinit(base);
    const alloc = probe.allocator();

    const result = try executeVisionForTest(&rt, alloc, args_json, catalog);
    alloc.free(@constCast(result.model_output));
    try std.testing.expectEqual(tool_contracts.ToolExecutionStatus.success, result.status);
    try std.testing.expectEqual(probe.allocated_bytes, probe.freed_bytes);
    return fixture.allocation_index_at_stream orelse error.TestExpectedEqual;
}

const OneShotFailingAllocator = struct {
    failing: std.testing.FailingAllocator,

    fn init(alloc: Allocator, fail_index: usize) OneShotFailingAllocator {
        return .{ .failing = .init(alloc, .{
            .fail_index = fail_index,
            .resize_fail_index = 0,
        }) };
    }

    fn allocator(self: *OneShotFailingAllocator) Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = allocate,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }

    fn allocate(
        raw: *anyopaque,
        len: usize,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) ?[*]u8 {
        const self: *OneShotFailingAllocator = @ptrCast(@alignCast(raw));
        const result = self.failing.allocator().rawAlloc(
            len,
            alignment,
            return_address,
        );
        if (result == null and self.failing.has_induced_failure) {
            self.failing.fail_index = std.math.maxInt(usize);
        }
        return result;
    }

    fn resize(
        raw: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) bool {
        const self: *OneShotFailingAllocator = @ptrCast(@alignCast(raw));
        return self.failing.allocator().rawResize(
            memory,
            alignment,
            new_len,
            return_address,
        );
    }

    fn remap(
        raw: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) ?[*]u8 {
        const self: *OneShotFailingAllocator = @ptrCast(@alignCast(raw));
        return self.failing.allocator().rawRemap(
            memory,
            alignment,
            new_len,
            return_address,
        );
    }

    fn free(
        raw: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) void {
        const self: *OneShotFailingAllocator = @ptrCast(@alignCast(raw));
        self.failing.allocator().rawFree(memory, alignment, return_address);
    }
};

fn expectVisionOutOfMemoryAt(
    fail_index: usize,
    expected_gateway_calls: usize,
    catalog: []const types.ImageAttachment,
    args_json: []const u8,
    provider_json: []const u8,
) !void {
    const base = std.testing.allocator;
    var failing = OneShotFailingAllocator.init(base, fail_index);
    const responses = [_]VisionGatewayResponse{.{ .content = provider_json }};
    var fixture = VisionGatewayFixture{ .alloc = base, .responses = &responses };
    defer fixture.deinit();
    var rt = TestRuntime{
        .agent_stream_provider = fixture.provider(),
        .tool_registry = .{ .tools = vision_test_registry_tools[0..] },
        .session_allocator = base,
        .context_limits = .{ .image_adapter_output_bytes = .{
            .value = .{ .bytes = 64 * 1024 },
            .source = .command_line,
        } },
    };
    defer rt.deinit(base);
    const alloc = failing.allocator();

    if (executeVisionForTest(&rt, alloc, args_json, catalog)) |result| {
        alloc.free(@constCast(result.model_output));
        if (result.interactive_notice != null or result.system_notice != null) {
            return error.OutOfMemoryProducedVisionNotice;
        }
        return error.OutOfMemoryReturnedVisionResult;
    } else |err| {
        try std.testing.expectEqual(error.OutOfMemory, err);
    }
    try std.testing.expect(failing.failing.has_induced_failure);
    try std.testing.expectEqual(expected_gateway_calls, fixture.call_count);
    try std.testing.expectEqual(
        failing.failing.allocated_bytes,
        failing.failing.freed_bytes,
    );
}
