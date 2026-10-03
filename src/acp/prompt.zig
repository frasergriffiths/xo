const std = @import("std");
const skill_contract = @import("../core/skills/skill_contract.zig");
const std_builtin = @import("builtin");
const command_admission = @import("../core/permissions/command_admission.zig");
const auth_runtime = @import("../core/auth/auth_runtime.zig");
const credentials = @import("../core/auth/credentials.zig");
const model_provider = @import("../core/config/model_provider.zig");
const host = @import("../core/hosts/host.zig");
const session_title_generation = @import("../core/session/session_title_generation.zig");
const io_mod = @import("../core/shared/io.zig");
const image_attachments = @import("../core/images/image_attachments.zig");
const jsonrpc = @import("jsonrpc.zig");
const acp_types = @import("types.zig");
const server = @import("server.zig");
const sessions = @import("sessions.zig");
const agent_runtime = @import("../core/agent/agent_runtime.zig");
const agent_execution_memory = @import("../core/agent/execution_memory.zig");
const diff_mod = @import("../core/output/diff.zig");
const file_mutation = @import("../core/tooling/file_mutation.zig");
const file_mutation_contract = @import("../core/tooling/file_mutation_contract.zig");

const permission_auto_classifier = @import("../core/permissions/auto_classifier.zig");
const auto_classifier_context = @import("../core/permissions/auto_classifier_context.zig");
const permission_gate = @import("../core/permissions/permission_gate.zig");
const permission_request = @import("../core/permissions/permission_request.zig");
const session_codec = @import("../core/session/session_codec.zig");
const session_log = @import("../core/session/session_log.zig");
const session_store = @import("../core/session/session_store.zig");
const session_runtime = @import("../core/session/session.zig");
const session_usage = @import("../core/session/session_usage.zig");
const subagent_agent_adapter = @import("../core/subagent/agent_adapter.zig");
const subagent_domain = @import("../core/subagent/domain.zig");
const subagent_execution = @import("../core/subagent/execution.zig");
const subagent_model_contract = @import("../core/subagent/model_contract.zig");
const gateway_model_catalog = @import("../core/gateway/model_catalog.zig");
const usage_recovery = @import("../core/session/usage_recovery.zig");
const skill_runtime = @import("../core/skills/skill_runtime.zig");
const skill_invocation = @import("../core/skills/skill_invocation.zig");
const context_contract = @import("../core/workspace/context_contract.zig");
const config_runtime = @import("../core/config/config_runtime.zig");
const model_capabilities = @import("../core/config/model_capabilities.zig");
const provider_set = @import("../core/gateway/provider_set.zig");
const mode_registry = @import("../core/modes/mode_registry.zig");
const debug_trace = @import("../core/shared/debug_trace.zig");
const display_width = @import("../core/shared/display_width.zig");
const text_utils = @import("../core/shared/text_utils.zig");
const tool_projection_mod = @import("../core/tooling/tool_projection.zig");
const model_tool_schema = @import("../core/tooling/model_tool_schema.zig");
const tool_admission = @import("../core/tooling/tool_admission.zig");
const tool_dispatch = @import("../core/tooling/tool_dispatch.zig");
const tool_specs = @import("../core/tooling/tool_specs.zig");
const tool_set_contract = @import("../core/tooling/tool_set.zig");

const tool_presentation = @import("../core/tooling/tool_presentation.zig");
const tool_call_presentation = @import("tool_call_presentation.zig");
const tool_result_errors = @import("../core/tooling/tool_result_errors.zig");
const tool_runtime = @import("../core/tooling/tool_runtime.zig");
const command_output_content = @import("../core/tooling/command_output_content.zig");
const builtin_tools = @import("../builtins/tools.zig");
const test_openrouter = if (std_builtin.is_test)
    @import("../gateway/openrouter_test_fixtures.zig")
else
    struct {};
const types = @import("../core/shared/types.zig");
const worker_runtime = @import("../core/agent/worker_runtime.zig");

const Allocator = std.mem.Allocator;
const ErrorCode = jsonrpc.ErrorCode;

pub const no_active_session_rpc_error = jsonrpc.RpcError{
    .code = ErrorCode.invalid_params,
    .message = "No active session",
};
const ToolCall = types.ToolCall;
const ChatMessage = types.ChatMessage;
const HistoryTurn = types.HistoryTurn;
const PermissionGrant = types.PermissionGrant;
const PermissionMode = types.PermissionMode;
const ToolPermissionDecision = types.ToolPermissionDecision;
const ToolExecutionResult = agent_runtime.ToolExecutionResult;

pub const TerminalOutcome = union(enum) {
    stop_reason: acp_types.StopReason,
    rpc_error: jsonrpc.RpcError,
};

fn promptInputFailure(err: anyerror) anyerror!TerminalOutcome {
    return switch (err) {
        error.OutOfMemory => err,
        error.UnsupportedPromptImage => .{ .rpc_error = .{
            .code = ErrorCode.invalid_params,
            .message = "Image prompt blocks are not supported in this runtime",
        } },
        error.InvalidPromptImage,
        error.InvalidImageId,
        error.ImageIdOverflow,
        error.UnsupportedImageType,
        error.ImageSnapshotMediaTypeMismatch,
        => .{ .rpc_error = .{
            .code = ErrorCode.invalid_params,
            .message = "Invalid image prompt block",
        } },
        error.ImageTooLarge => .{ .rpc_error = .{
            .code = ErrorCode.invalid_params,
            .message = "Image prompt exceeds size limit",
        } },
        else => err,
    };
}

fn promptExecutionFailure(err: anyerror) anyerror!TerminalOutcome {
    return switch (err) {
        error.ModelImageCapabilityUnavailable,
        error.SubscriptionNativeImageUnavailable,
        => .{ .rpc_error = .{
            .code = ErrorCode.invalid_params,
            .message = "Image prompts are unavailable for the selected model",
        } },
        else => err,
    };
}

const ProviderTerminalPublication = enum {
    not_applicable,
    pending,
    published,
};

const AgentMessageKind = enum {
    assistant,
    operational,
};

const AcpContext = struct {
    alloc: Allocator,
    state: *server.ServerState,
    session_id: []const u8,
    /// Tool-call IDs already announced with a pending update. Keys are owned
    /// copies of provider call ids so the ID stays stable from permission
    /// review through execution.
    published_tool_calls: std.StringHashMapUnmanaged(ProviderTerminalPublication) = .empty,
    message_id: acp_types.MessageIdBuffer = undefined,
    message_kind: ?AgentMessageKind = null,
    stop_reason: acp_types.StopReason = .end_turn,
    auto_classifier: permission_auto_classifier.Classifier =
        permission_auto_classifier.Classifier.disabled(),
    /// Mode and permission policy captured at prompt dispatch so mid-turn
    /// session/set_mode changes never mutate a running turn.
    captured_mode: ?[]const u8 = null,
    captured_permission_mode: ?PermissionMode = null,
    current_prompt_input: ?*ParsedPromptInput = null,

    fn deinitPublishedToolCalls(self: *AcpContext) void {
        var keys = self.published_tool_calls.keyIterator();
        while (keys.next()) |key| self.alloc.free(key.*);
        self.published_tool_calls.deinit(self.alloc);
    }

    fn sendUpdate(self: *AcpContext, update_json: []const u8) !void {
        var out: std.Io.Writer.Allocating = .init(self.alloc);
        defer out.deinit();
        try acp_types.writeSessionUpdate(&out.writer, self.session_id, update_json);
        try self.state.writer.writeNotification(self.alloc, "session/update", out.writer.buffered());
    }

    fn assistantMessageId(self: *AcpContext) []const u8 {
        return self.messageId(.assistant);
    }

    fn operationalMessageId(self: *AcpContext) []const u8 {
        return self.messageId(.operational);
    }

    fn messageId(self: *AcpContext, kind: AgentMessageKind) []const u8 {
        if (self.message_kind != kind) {
            _ = acp_types.generateMessageId(&self.message_id);
            self.message_kind = kind;
        }
        return &self.message_id;
    }

    fn sendAgentText(self: *AcpContext, message_id: []const u8, text: []const u8) !void {
        const plain = try stripAnsiAlloc(self.alloc, text);
        defer if (plain.ptr != text.ptr) self.alloc.free(plain);
        var out: std.Io.Writer.Allocating = .init(self.alloc);
        defer out.deinit();
        try acp_types.writeAgentMessageChunk(&out.writer, message_id, plain);
        try self.sendUpdate(out.writer.buffered());
    }

    fn sendModelRecoveryStatus(
        self: *AcpContext,
        status: types.RouteRecoveryStatus,
    ) !void {
        var out: std.Io.Writer.Allocating = .init(self.alloc);
        defer out.deinit();
        try acp_types.writeModelRecoveryInfoUpdate(
            &out.writer,
            status,
            self.state.active_session.?.writable != null,
        );
        try self.sendUpdate(out.writer.buffered());
    }

    fn clearModelRecoveryStatus(self: *AcpContext) !void {
        var out: std.Io.Writer.Allocating = .init(self.alloc);
        defer out.deinit();
        try acp_types.writeModelRecoveryInfoUpdate(&out.writer, null, false);
        try self.sendUpdate(out.writer.buffered());
    }

    fn sendToolCallPending(self: *AcpContext, arena: Allocator, call: ToolCall) ![]const u8 {
        if (self.published_tool_calls.getKey(call.id)) |published| return published;
        const registry = self.toolRegistry();
        const title = describeToolTitle(registry, arena, call) catch "Tool call";
        const name = acpToolName(call.name);
        const kind = mapToolKind(name);
        const masked_arguments = try agent_execution_memory.redactToolArgumentsJson(
            arena,
            call.name,
            call.arguments_json,
        );
        defer arena.free(masked_arguments);
        var parsed_arguments: ?std.json.Parsed(std.json.Value) = std.json.parseFromSlice(
            std.json.Value,
            arena,
            masked_arguments,
            .{},
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => null,
        };
        defer if (parsed_arguments) |*parsed| parsed.deinit();
        const raw_input = if (parsed_arguments) |*parsed| parsed.value else null;

        try self.published_tool_calls.ensureUnusedCapacity(self.alloc, 1);
        const owned_id = try self.alloc.dupe(u8, call.id);
        errdefer self.alloc.free(owned_id);
        var out: std.Io.Writer.Allocating = .init(self.alloc);
        defer out.deinit();
        try acp_types.writeToolCall(&out.writer, owned_id, name, title, kind, .pending, raw_input);
        try self.sendUpdate(out.writer.buffered());
        self.published_tool_calls.putAssumeCapacity(
            owned_id,
            if (tool_presentation.isProviderSearchAlias(call.name)) .pending else .not_applicable,
        );
        return owned_id;
    }

    fn sendProviderTerminal(
        self: *AcpContext,
        tool_call_id: []const u8,
        outcome: types.ToolOutcome,
        result: ?[]const u8,
    ) !void {
        const publication = self.published_tool_calls.getPtr(tool_call_id) orelse return;
        if (publication.* != .pending) return;
        const status = providerTerminalStatus(outcome.kind) orelse return;

        const detail: ?[]const u8 = result;
        switch (status) {
            .completed => try self.sendToolCallCompletedWithCommandResult(tool_call_id, detail orelse "Web search completed", null),
            .failed => try self.sendToolCallErrorWithCommandResult(tool_call_id, detail orelse "Web search failed", null),
            .pending, .in_progress => unreachable,
        }
        const updated = self.published_tool_calls.getPtr(tool_call_id) orelse
            return error.ToolCallPublicationStateLost;
        updated.* = .published;
    }

    fn sendToolCallProgressText(self: *AcpContext, tool_call_id: []const u8, text: ?[]const u8) !void {
        const plain = if (text) |value| try stripAnsiAlloc(self.alloc, value) else null;
        defer if (plain) |value| if (text) |original| {
            if (value.ptr != original.ptr) self.alloc.free(value);
        };
        var out: std.Io.Writer.Allocating = .init(self.alloc);
        defer out.deinit();
        try acp_types.writeToolCallUpdate(&out.writer, tool_call_id, .in_progress, plain);
        try self.sendUpdate(out.writer.buffered());
    }

    fn sendWebSearchProgress(self: *AcpContext, tool_call_id: []const u8, progress: types.WebSearchProgress) !void {
        var out: std.Io.Writer.Allocating = .init(self.alloc);
        defer out.deinit();
        try writeWebSearchProgressUpdate(self.alloc, &out.writer, tool_call_id, progress);
        try self.sendUpdate(out.writer.buffered());
    }

    fn sendWebFetchProgress(self: *AcpContext, tool_call_id: []const u8, progress: types.WebFetchProgress) !void {
        var out: std.Io.Writer.Allocating = .init(self.alloc);
        defer out.deinit();
        try writeWebFetchProgressUpdate(self.alloc, &out.writer, tool_call_id, progress);
        try self.sendUpdate(out.writer.buffered());
    }

    fn sendToolCallCompletedWithCommandResult(self: *AcpContext, tool_call_id: []const u8, result_text: ?[]const u8, command_result_json: ?[]const u8) !void {
        var out: std.Io.Writer.Allocating = .init(self.alloc);
        defer out.deinit();
        try acp_types.writeToolCallUpdateWithCommandResult(&out.writer, tool_call_id, .completed, result_text, command_result_json);
        try self.sendUpdate(out.writer.buffered());
    }

    fn sendToolCallError(self: *AcpContext, tool_call_id: []const u8, err_text: []const u8) !void {
        try self.sendToolCallErrorWithCommandResult(tool_call_id, err_text, null);
    }

    fn sendToolCallErrorWithCommandResult(self: *AcpContext, tool_call_id: []const u8, err_text: []const u8, command_result_json: ?[]const u8) !void {
        var out: std.Io.Writer.Allocating = .init(self.alloc);
        defer out.deinit();
        try acp_types.writeToolCallUpdateWithCommandResult(&out.writer, tool_call_id, .failed, err_text, command_result_json);
        try self.sendUpdate(out.writer.buffered());
    }

    fn toolContext(self: *AcpContext) tool_runtime.Context {
        const session = if (self.state.active_session) |*active| active else unreachable;
        const provider_capabilities = self.state.cfg.provider_set.select(session.provider).capabilities;
        if (provider_capabilities.fx_search) {
            self.state.web_search_runtime.configure(.{
                .api_key = session.api_key,
                .credential_source = session.credential_source,
                .worker_model = session.model,
                .gateway_retry_count = self.state.cfg.gateway_retry_count,
                .gateway_chat_url = self.state.cfg.gateway_chat_url,
                .usage = &session.session_rt.usage,
                .usage_allocator = self.state.alloc,
            });
        }
        const tc: tool_runtime.Context = .{
            .workspace_root = self.state.workspace_root,
            .access_scope = self.state.workspace_access.scope(self.state.workspace_root),
            .ignored_list_entries = self.state.cfg.ignored_list_entries,
            .max_list_entries = self.state.cfg.max_list_entries,
            .max_read_file_bytes = self.state.cfg.max_read_file_bytes,
            .max_read_file_lines = self.state.cfg.max_read_file_lines,
            .max_read_file_line_len = self.state.cfg.max_read_file_line_len,
            .max_command_output_bytes = self.state.cfg.max_command_output_bytes,
            .max_tool_result_bytes = session.max_tool_result_bytes,
            .api_key = session.api_key,
            .agent_stream_provider = server.streamProviderFor(self.state, session.provider),
            .credential_source = session.credential_source,
            .account_id = session.account_id,
            .provider = session.provider,
            .provider_capabilities = provider_capabilities,
            .secret_store = self.state.cfg.secret_store,
            .model = session.model,
            .gateway_retry_count = self.state.cfg.gateway_retry_count,
            .gateway_chat_url = self.state.cfg.gateway_chat_url,
            .gateway_models_path = self.state.cfg.gateway_models_path,
            .agent_step_limit = session.agent_step_limit,
            .fast_mode = session.fast_mode,
            .effort = session.effort,
            .first_call_tool_choice = session.first_call_tool_choice,
            .permission_mode = self.captured_permission_mode orelse session.permission_mode,
            .permission_grants = session.session_grants,
            .permission_rules = session.permission_rules,
            .tool_registry = self.toolRegistry(),
            .permission_reviewer_provider = self.state.cfg.provider_set.select(session.provider).permission_reviewer,
            .auto_classifier = self.auto_classifier,
            .subagent_host = self.state.subagent_host,
            .subagent_caller_id = session.session_id,
            .worker = &self.state.worker,
            .permission_prompter = if (self.state.initialized) .{
                .context = @ptrCast(self),
                .request_fn = requestAcpPermission,
                .retain_grant_fn = retainAcpGrant,
            } else null,
            .cancel_flag = &session.cancel_flag,
            .session = &session.session_rt,
            .session_allocator = self.alloc,
            .skills_dir = self.state.skills.dir,
            .context_limits = self.state.context_limits,
            .context_enabled = self.state.context_enabled,
            .context_registry = self.state.cfg.context_registry,
            .output_chunk_ctx = @ptrCast(self),
            .on_output_chunk = onCommandOutputChunk,

            .session_child_capability = if (session.writable) |*writable|
                writable.childCapability() catch null
            else
                null,
            .terminal_client = &self.state.terminal_client,
            .managed_executions = &self.state.managed_executions,
            .ephemeral_command_replay = self.state.managed_executions.replayStore(),
            .web_fetch_runtime = &self.state.web_fetch_runtime,
            .web_fetch_artifact_store = session.session_rt.webFetchArtifactStore(),
            .web_fetch_artifact_error = session.session_rt.webFetchArtifactError(),
            .web_search_runtime_ready = false,
            .web_search_backend = if (provider_capabilities.fx_search) self.state.web_search_runtime.dispatchBackend() else null,
            .model_capability_resolver = .{
                .ctx = @ptrCast(self),
                .resolve_fn = resolveModelCapabilities,
            },
            .model_override_resolver = .{
                .context = @ptrCast(self),
                .resolve_fn = resolveModelOverride,
            },
            .interactive = false,
            .lifecycle_view = self.state.lifecycle_view,
            .lifecycle_scope = .{
                .kind = .acp,
                .workspace_root = session.workspace_root,
                .session_id = session.session_id,
            },
        };
        return tc;
    }

    fn modelVisibleProjectContext(self: *const AcpContext) []const u8 {
        if (!self.state.context_enabled) return "";
        return self.state.context_snapshot.modelVisibleBytes();
    }

    fn toolRegistry(self: *const AcpContext) tool_dispatch.Registry {
        return activeToolSet(self.state).registry;
    }
};

fn activeToolSet(state: *const server.ServerState) tool_set_contract.ToolSet {
    return tool_call_presentation.activeToolSet(state);
}

const Osc8Link = struct { uri: []const u8, end: usize };

fn parseOsc8Link(text: []const u8, index: usize) ?Osc8Link {
    if (!std.mem.startsWith(u8, text[index..], "\x1b]8;")) return null;
    const end = display_width.ansiSequenceEnd(text, index);
    var body_end = end;
    if (body_end > index and text[body_end - 1] == 0x07) {
        body_end -= 1;
    } else if (body_end >= index + 2 and text[body_end - 2] == 0x1b and text[body_end - 1] == '\\') {
        body_end -= 2;
    }
    const body_start = index + "\x1b]8;".len;
    if (body_end < body_start) return null;
    const body = text[body_start..body_end];
    const separator = std.mem.findScalar(u8, body, ';') orelse return null;
    return .{ .uri = body[separator + 1 ..], .end = end };
}

/// Removes ANSI escape sequences so ACP clients receive Markdown-compatible
/// text. OSC-8 hyperlinks become Markdown links so their targets survive the
/// conversion. Returns the original slice when no escape byte is present;
/// callers free the result only when it differs from the input.
fn stripAnsiAlloc(alloc: Allocator, text: []const u8) ![]const u8 {
    if (std.mem.findScalar(u8, text, 0x1b) == null) return text;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var open_link_uri: ?[]const u8 = null;
    var index: usize = 0;
    while (index < text.len) {
        if (text[index] == 0x1b) {
            if (parseOsc8Link(text, index)) |link| {
                if (link.uri.len > 0) {
                    if (open_link_uri == null) {
                        try out.append(alloc, '[');
                        open_link_uri = link.uri;
                    }
                } else if (open_link_uri) |uri| {
                    try appendMarkdownLinkClose(alloc, &out, uri);
                    open_link_uri = null;
                }
                index = link.end;
            } else {
                index = display_width.ansiSequenceEnd(text, index);
            }
        } else {
            try out.append(alloc, text[index]);
            index += 1;
        }
    }
    // A link left open by a chunk boundary still closes with its target so
    // the emitted Markdown stays balanced.
    if (open_link_uri) |uri| try appendMarkdownLinkClose(alloc, &out, uri);
    return try out.toOwnedSlice(alloc);
}

fn appendMarkdownLinkClose(alloc: Allocator, out: *std.ArrayList(u8), uri: []const u8) !void {
    try out.appendSlice(alloc, "](");
    try out.appendSlice(alloc, uri);
    try out.append(alloc, ')');
}

/// Runs a prompt turn under the mode and permission policy captured at
/// dispatch. Mid-turn session/set_mode changes only affect later prompts.
pub fn handlePrompt(
    state: *server.ServerState,
    alloc: Allocator,
    msg: *jsonrpc.Message,
    captured_mode: []const u8,
    captured_permission_mode: PermissionMode,
) !TerminalOutcome {
    const session = if (state.active_session) |*active| active else return .{
        .rpc_error = no_active_session_rpc_error,
    };
    {
        session.session_write_mutex.lockUncancelable(io_mod.getIo());
        defer session.session_write_mutex.unlock(io_mod.getIo());
        if (session.writable) |*loaded| try loaded.requireWritable();
    }
    if (!try server.selectCredentialForProvider(state, session.provider)) {
        return .{ .rpc_error = .{
            .code = ErrorCode.invalid_request,
            .message = if (session.provider == .openrouter)
                credentials.missing_credential_message
            else
                credentials.missing_credential_message,
        } };
    }

    const params = msg.params_raw orelse return .{
        .rpc_error = .{
            .code = ErrorCode.invalid_params,
            .message = "Missing params",
        },
    };

    var prior_image_catalog = try session.session_rt.snapshotImageCatalog(alloc, &.{});
    defer types.freeImageAttachmentSlice(alloc, prior_image_catalog);
    if (session.writable) |writable| {
        if (writable.state.recovery_checkpoint) |checkpoint| {
            const merged = try session_runtime.merge_image_catalog_history_turn(alloc, prior_image_catalog, checkpoint.interruptedTurn());
            types.freeImageAttachmentSlice(alloc, prior_image_catalog);
            prior_image_catalog = merged;
        }
    }
    const next_image_id = (try image_attachments.calculate_next_image_id(prior_image_catalog)).next_id;
    var prompt_input = parsePromptInputWithFirstImageId(alloc, params, next_image_id) catch |err|
        return promptInputFailure(err);
    defer prompt_input.deinit(alloc);
    if (prompt_input.pending_images.len > 0) {
        {
            var temporary_snapshot_dir: ?[]u8 = null;
            defer if (temporary_snapshot_dir) |path| alloc.free(path);
            const snapshot_dir = try session_store.imageSnapshotStorageDir(
                alloc,
                if (session.store) |store| store.sessions_dir else null,
                if (session.store != null) session.session_id else null,
                &temporary_snapshot_dir,
            );
            defer alloc.free(snapshot_dir);
            prompt_input.captureImages(alloc, snapshot_dir) catch |err|
                return promptInputFailure(err);
        }
    }
    const prompt_text = prompt_input.text;

    if (prompt_input.continue_recovery and prompt_text.len != 0) {
        return .{
            .rpc_error = .{
                .code = ErrorCode.invalid_params,
                .message = "Recovery continuation cannot include a new prompt",
            },
        };
    }
    if (!prompt_input.continue_recovery and prompt_text.len == 0) {
        return .{
            .rpc_error = .{
                .code = ErrorCode.invalid_params,
                .message = "Empty prompt",
            },
        };
    }

    try refreshProjectContext(
        state,
        alloc,
        prompt_input.targets,
        prompt_input.omissions,
        prompt_input.omission_summary,
    );

    session.pending_prompt_id = msg.id;
    defer session.pending_prompt_id = null;

    var ctx = AcpContext{
        .alloc = alloc,
        .state = state,
        .session_id = session.session_id,
        .captured_mode = captured_mode,
        .captured_permission_mode = captured_permission_mode,
        .current_prompt_input = &prompt_input,
    };
    defer ctx.deinitPublishedToolCalls();

    var recovery_checkpoint: ?session_codec.RecoveryCheckpoint = null;
    defer if (recovery_checkpoint) |*checkpoint| checkpoint.deinit(alloc);
    if (prompt_input.continue_recovery) {
        const writable = if (session.writable) |*value| value else return .{
            .rpc_error = .{
                .code = ErrorCode.invalid_params,
                .message = "This session does not support durable recovery",
            },
        };
        const checkpoint = writable.state.recovery_checkpoint orelse return .{
            .rpc_error = .{
                .code = ErrorCode.invalid_params,
                .message = "No paused model response to continue",
            },
        };
        recovery_checkpoint = try checkpoint.dupe(alloc);
    } else if (session.writable) |*writable| {
        if (writable.conversation_writer.turn_open) {
            const checkpoint = writable.state.recovery_checkpoint orelse
                return error.InvalidRecoveryCheckpoint;
            try persistAcpHistoryTurn(alloc, session, checkpoint.interruptedTurn(), null);
        }
    }

    var tool_projection = try state.cfg.mode_registry.buildModelToolProjection(alloc, activeToolSet(state), captured_mode, .{
        .permission_mode = captured_permission_mode,
        .permission_rules = session.permission_rules,
        .subagent_available = state.subagent_host != null,
    });
    defer tool_projection.deinit(alloc);

    const owned_prompt = try alloc.dupe(
        u8,
        if (recovery_checkpoint) |checkpoint| checkpoint.user.text else prompt_text,
    );
    defer alloc.free(owned_prompt);

    var skill_catalog = state.skills.acquireCatalog();
    defer skill_catalog.deinit();
    for (state.context_snapshot.notices) |notice| try pushContextNotice(@ptrCast(&ctx), notice);

    session.session_rt.setConversationLanguageFromUserMessage(owned_prompt);
    const context_history = try session.session_rt.snapshotHistory(alloc);
    defer types.freeHistoryTurnSlice(alloc, context_history);
    var context_snapshot = try state.context_snapshot.dupe(alloc);
    defer context_snapshot.deinit(alloc);
    const root_user_intent_context = try auto_classifier_context.buildCanonicalRootUserContext(
        alloc,
        owned_prompt,
        session.session_rt.agent.history.items,
    );
    defer alloc.free(root_user_intent_context);

    const current_images = if (recovery_checkpoint) |checkpoint| checkpoint.user.images else prompt_input.images;
    const authorized_image_catalog = if (recovery_checkpoint != null)
        prior_image_catalog
    else
        try session.session_rt.snapshotImageCatalog(alloc, current_images);
    defer if (recovery_checkpoint == null) types.freeImageAttachmentSlice(alloc, authorized_image_catalog);

    const job: worker_runtime.QueuedPrompt = .{
        .turn_id = if (recovery_checkpoint) |checkpoint| checkpoint.turn_id else 0,
        .prompt = @constCast(owned_prompt),
        .images = @constCast(current_images),
        .authorized_image_catalog = authorized_image_catalog,
        .model = session.model,
        .api_key = @constCast(session.api_key),
        .credential_source = session.credential_source,
        .account_id = if (session.account_id) |account_id| @constCast(account_id) else null,
        .provider = session.provider,
        .permission_mode = captured_permission_mode,
        .history = context_history,
        .unversioned_history_count = session.session_rt.unversionedHistoryEnd(),
        .root_user_intent_context = root_user_intent_context,
        .grants = session.session_grants,
        .context_snapshot = context_snapshot,
        .recovery_checkpoint = recovery_checkpoint,
        .recovery_source_already_presented = recovery_checkpoint != null,
    };

    session.session_rt.usage.configureCheckpointSink(
        if (session.writable != null)
            .{
                .context = @ptrCast(&ctx),
                .allocator = alloc,
                .persist = persistUsageCheckpoint,
            }
        else
            null,
    );
    if (comptime @import("builtin").os.tag != .wasi) {
        if (state.cfg.provider_set.select(session.provider).deferred_usage != null) {
            if (session.credential_source == .host_managed) {
                session.session_rt.usage.replaceHostManagedReconciliationAuthority(
                    alloc,
                    session.provider,
                );
            } else if (session.credential_source) |source| {
                session.session_rt.usage.replaceProviderReconciliationCredential(
                    alloc,
                    session.provider,
                    source,
                    session.account_id,
                    session.api_key,
                );
            }
        }
    }
    defer session.session_rt.usage.configureCheckpointSink(null);
    const deps = agentRuntimeDeps(&ctx);
    const current_prompt_is_root_authority = if (session.writable) |writable|
        writable.external_prompt_origin == .persistent_child and
            recovery_checkpoint == null
    else
        false;
    var agent_config = buildAgentConfig(state, session, .{
        .skill_catalog = .{ .skills = skill_catalog.items, .diagnostics = skill_catalog.diagnostics },
        .advertised_tool_names = tool_projection.advertised_names,
        .advertised_functions = tool_projection.advertised_functions,
        .custom_tool_guidance = tool_projection.custom_guidance,
    }, current_prompt_is_root_authority);
    agent_config.session_child_capability = if (session.writable) |*writable|
        writable.childCapability() catch null
    else
        null;
    maybeStartAcpTitleTask(state, session, owned_prompt, recovery_checkpoint != null);
    defer if (session.title_task != null) completeAcpTitleTask(state, session, alloc);
    agent_runtime.processAgentPrompt(&session.session_rt.agent, &deps, null, .{
        .view = state.lifecycle_view,
        .scope = .{
            .kind = .acp,
            .workspace_root = session.workspace_root,
            .session_id = session.session_id,
        },
        .outcome_allocator = alloc,
    }, agent_config, job) catch |err| {
        if (err == error.NonInteractivePermissionRequired) {
            ctx.stop_reason = .refused;
        } else {
            return promptExecutionFailure(err);
        }
    };
    prompt_input.retainImageSnapshots();
    completeAcpTitleTask(state, session, alloc);
    try sessions.sendActiveSessionInfoUpdate(state, alloc);
    try sessions.sendActiveSessionUsageUpdate(state, alloc);

    if (session.cancel_flag.load(.seq_cst)) {
        ctx.stop_reason = .cancelled;
    }

    return .{ .stop_reason = ctx.stop_reason };
}

/// Starts background title generation for a fresh persisted ACP session. The
/// task runs concurrently with the first prompt turn and is applied by
/// `completeAcpTitleTask` before the session info update goes out. The locally
/// derived title remains when generation is skipped or unavailable.
fn maybeStartAcpTitleTask(
    state: *server.ServerState,
    session: *server.ActiveSessionState,
    prompt_text: []const u8,
    recovery: bool,
) void {
    // Unit tests share the real provider bundles; never spawn network side
    // calls from a test process. Wiring is covered by e2e mock servers.
    if (comptime @import("builtin").is_test) return;
    if (!state.session_titles or recovery) return;
    if (session.title_task != null) return;
    if (session.session_rt.agent.history.items.len != 0) return;
    const writable = if (session.writable) |*value| value else return;
    const bundle = state.cfg.provider_set.select(session.provider);
    const title_model = bundle.title_model orelse return;
    const agent_stream = bundle.agent_stream orelse return;
    const excerpt = session_title_generation.promptExcerpt(prompt_text) orelse return;
    if (session.credential_source != .host_managed and session.api_key.len == 0) return;
    const task = session_title_generation.Task.create(.{
        .session_id = writable.active_id,
        .model = title_model,
        .prompt_excerpt = excerpt,
        .api_key = if (session.api_key.len > 0) session.api_key else null,
        .account_id = session.account_id,
        .credential_source = session.credential_source,
        .stream_provider = agent_stream,
    }) catch return;
    task.spawn() catch |err| {
        debug_trace.logf("session", "event=title_generation result=unavailable reason=spawn err={s}", .{@errorName(err)});
        task.destroy();
        return;
    };
    session.title_task = task;
}

/// Joins the bounded title task and installs the generated title unless the
/// session already carries a user-set title. No-op without a pending task.
fn completeAcpTitleTask(state: *server.ServerState, session: *server.ActiveSessionState, alloc: Allocator) void {
    _ = state;
    const task = session.title_task orelse return;
    session.title_task = null;
    defer task.destroy();
    task.join();
    const title = task.takeTitle() orelse return;
    defer std.heap.c_allocator.free(title);
    session.session_write_mutex.lockUncancelable(io_mod.getIo());
    defer session.session_write_mutex.unlock(io_mod.getIo());
    const writable = if (session.writable) |*value| value else return;
    if (!std.mem.eql(u8, writable.active_id, task.session_id)) {
        debug_trace.logf("session", "event=title_generation_apply result=dropped reason=session_changed session={s}", .{task.session_id});
        return;
    }
    const installed = session_title_generation.installGeneratedTitle(alloc, writable, session.session_rt.agent.history.items, title) catch |err| {
        debug_trace.logf("session", "event=title_generation_apply result=failed session={s} err={s}", .{ task.session_id, @errorName(err) });
        return;
    };
    if (installed) {
        debug_trace.logf("session", "event=title_generation_apply result=installed session={s}", .{task.session_id});
    }
}

pub fn runSubagentChild(
    raw: ?*anyopaque,
    turn: *subagent_execution.TurnContext,
    message: subagent_domain.QueuedMessage,
    admission: subagent_domain.AdmissionSnapshot,
    cancel: *std.atomic.Value(bool),
) subagent_execution.ServiceError!subagent_execution.RunOutcome {
    const state: *server.ServerState = @ptrCast(@alignCast(raw.?));
    const subagent_host = state.subagent_host orelse return error.ProviderFailed;
    const alloc = state.alloc;
    state.subagent_authority_mutex.lockUncancelable(io_mod.getIo());
    const active = if (state.active_session) |*session| session else {
        state.subagent_authority_mutex.unlock(io_mod.getIo());
        return error.ProviderFailed;
    };
    const session_id = active.session_id;
    const captured_mode = active.mode;
    state.subagent_authority_mutex.unlock(io_mod.getIo());
    var ctx = AcpContext{
        .alloc = alloc,
        .state = state,
        .session_id = session_id,
        .captured_mode = captured_mode,
        .captured_permission_mode = admission.permission_mode,
    };
    defer ctx.deinitPublishedToolCalls();
    var child_projection = state.cfg.mode_registry.buildModelToolProjection(
        alloc,
        builtin_tools.advertisement_set,
        captured_mode,
        .{
            .permission_mode = admission.permission_mode,
            .permission_rules = admission.rules,
            .subagent_available = true,
        },
    ) catch return error.OutOfMemory;
    defer child_projection.deinit(alloc);
    var skill_catalog = state.skills.acquireCatalog();
    defer skill_catalog.deinit();
    return subagent_agent_adapter.run(.{
        .host = subagent_host,
        .tool_context = ctx.toolContext(),
        .provider_set = state.cfg.provider_set,
        .system_prompt = state.cfg.prompt_policy.system_prompt,
        .model_prompt_overlay = state.cfg.prompt_policy.modelPromptOverlay(admission.model),
        .skill_catalog = .{ .skills = skill_catalog.items, .diagnostics = skill_catalog.diagnostics },
        .advertised_tool_names = child_projection.advertised_names,
        .advertised_functions = child_projection.advertised_functions,
        .custom_tool_guidance = child_projection.custom_guidance,
        .context_registry = state.cfg.context_registry,
        .context_enabled = state.context_enabled,
        .project_context = state.context_snapshot.modelVisibleBytes(),
        .lifecycle_view = state.lifecycle_view,
    }, turn, message, admission, cancel);
}

fn refreshProjectContext(
    state: *server.ServerState,
    alloc: Allocator,
    targets: []const context_contract.ApplicableTarget,
    omissions: []const context_contract.ContextOmissionInput,
    omission_summary: ?context_contract.ContextOmissionSummary,
) context_contract.ProviderError!void {
    state.context_snapshot.deinit(alloc);
    if (!state.context_enabled) return;

    state.context_snapshot = state.cfg.context_registry.gatherDefaultSnapshot(alloc, .{
        .workspace_root = state.workspace_root,
        .access_scope = state.workspace_access.scope(state.workspace_root),
        .targets = targets,
        .omissions = omissions,
        .omission_summary = omission_summary,
        .context_limits = state.context_limits,
    }) catch |err| {
        debug_trace.logf("context", "acp gather failed err={s}", .{@errorName(err)});
        return err;
    };
}

const AgentConfigSections = struct {
    skill_catalog: skill_invocation.Catalog = .{ .skills = &.{} },
    advertised_tool_names: []const []const u8 = &.{},
    advertised_functions: []const model_tool_schema.FunctionSchema = &.{},
    custom_tool_guidance: []const u8,
};

fn buildAgentConfig(
    state: *server.ServerState,
    session: *server.ActiveSessionState,
    sections: AgentConfigSections,
    current_prompt_is_external: bool,
) agent_runtime.Config {
    return .{
        .system_prompt = state.cfg.prompt_policy.system_prompt,
        .model_prompt_overlay = state.cfg.prompt_policy.modelPromptOverlay(session.model),
        .skill_catalog = sections.skill_catalog,
        .gateway_retry_count = state.cfg.gateway_retry_count,
        .gateway_chat_url = state.cfg.gateway_chat_url,
        .advertised_tool_names = sections.advertised_tool_names,
        .advertised_functions = sections.advertised_functions,
        .provider_capabilities = state.cfg.provider_set.select(session.provider).capabilities,
        .custom_tool_guidance = sections.custom_tool_guidance,
        .agent_step_limit = session.agent_step_limit,
        .max_tool_result_bytes = session.max_tool_result_bytes,
        .cancel_flag = &session.cancel_flag,
        .fast_mode = session.fast_mode,
        .effort = session.effort,
        .first_call_tool_choice = session.first_call_tool_choice,
        .workspace_root = state.workspace_root,
        .access_scope = state.workspace_access.scope(state.workspace_root),
        .origin = if (session.writable) |writable|
            if (writable.external_prompt_origin == .persistent_child) .subagent else .root
        else
            .root,
        .root_user_messages = if (session.writable) |writable|
            writable.external_root_user_messages
        else
            &.{},
        .root_user_evidence_complete = if (session.writable) |writable|
            writable.external_root_user_evidence_complete
        else
            false,
        .current_prompt_is_root_authority = if (session.writable) |writable|
            writable.external_prompt_origin == .persistent_child and
                current_prompt_is_external
        else
            false,
        .enforce_response_language = true,
        .context_limits = state.context_limits,
    };
}

const PendingPromptImage = struct {
    id: usize,
    bytes: []u8,
    media_type: []u8,

    fn deinit(self: *PendingPromptImage, alloc: Allocator) void {
        alloc.free(self.bytes);
        alloc.free(self.media_type);
        self.* = undefined;
    }
};

const ParsedPromptInput = struct {
    text: []u8,
    continue_recovery: bool = false,
    targets: []context_contract.ApplicableTarget = &.{},
    omissions: []context_contract.ContextOmissionInput = &.{},
    omission_summary: ?context_contract.ContextOmissionSummary = null,
    pending_images: []PendingPromptImage = &.{},
    images: []types.ImageAttachment = &.{},
    retain_image_snapshots: bool = false,

    fn captureImages(self: *ParsedPromptInput, alloc: Allocator, snapshot_dir: []const u8) !void {
        if (self.pending_images.len == 0) return;
        const images = try alloc.alloc(types.ImageAttachment, self.pending_images.len);
        var captured: usize = 0;
        errdefer {
            for (images[0..captured]) |attachment| {
                image_attachments.discardImageAttachment(alloc, attachment);
            }
            alloc.free(images);
        }
        for (self.pending_images, 0..) |pending, index| {
            images[index] = try image_attachments.captureInlineImageBytes(
                alloc,
                pending.id,
                pending.media_type,
                pending.bytes,
                snapshot_dir,
            );
            captured += 1;
        }
        self.images = images;
    }

    fn retainImageSnapshots(self: *ParsedPromptInput) void {
        self.retain_image_snapshots = true;
    }

    fn deinit(self: *ParsedPromptInput, alloc: Allocator) void {
        alloc.free(self.text);
        for (self.targets) |target| alloc.free(@constCast(target.path));
        if (self.targets.len > 0) alloc.free(self.targets);
        for (self.omissions) |omission| alloc.free(@constCast(omission.source));
        if (self.omissions.len > 0) alloc.free(self.omissions);
        for (self.pending_images) |*pending| pending.deinit(alloc);
        if (self.pending_images.len > 0) alloc.free(self.pending_images);
        if (self.images.len > 0) {
            if (self.retain_image_snapshots) {
                types.freeImageAttachmentSlice(alloc, self.images);
            } else {
                image_attachments.discardImageAttachmentSlice(alloc, self.images);
            }
        }
        self.* = undefined;
    }
};

fn parsePromptInput(alloc: Allocator, params_json: []const u8) !ParsedPromptInput {
    return parsePromptInputWithFirstImageId(alloc, params_json, 1);
}

fn parsePromptInputWithFirstImageId(
    alloc: Allocator,
    params_json: []const u8,
    first_image_id: usize,
) !ParsedPromptInput {
    if (first_image_id == 0) return error.InvalidImageId;
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, params_json, .{}) catch
        return .{ .text = try alloc.dupe(u8, "") };
    defer parsed.deinit();

    if (parsed.value != .object) return .{ .text = try alloc.dupe(u8, "") };

    const continue_recovery = blk: {
        const meta = parsed.value.object.get("_meta") orelse break :blk false;
        if (meta != .object) break :blk false;
        const fx = meta.object.get("fx") orelse break :blk false;
        if (fx != .object) break :blk false;
        const value = fx.object.get("continueRecovery") orelse break :blk false;
        break :blk value == .bool and value.bool;
    };

    const prompt_arr = parsed.value.object.get("prompt") orelse
        return .{ .text = try alloc.dupe(u8, ""), .continue_recovery = continue_recovery };
    if (prompt_arr != .array) return .{ .text = try alloc.dupe(u8, ""), .continue_recovery = continue_recovery };

    var text_buf: std.ArrayList(u8) = .empty;
    defer text_buf.deinit(alloc);
    var targets: std.ArrayList(context_contract.ApplicableTarget) = .empty;
    defer {
        for (targets.items) |target| alloc.free(@constCast(target.path));
        targets.deinit(alloc);
    }
    var omissions: std.ArrayList(context_contract.ContextOmissionInput) = .empty;
    var pending_images: std.ArrayList(PendingPromptImage) = .empty;
    defer {
        for (pending_images.items) |*pending| pending.deinit(alloc);
        pending_images.deinit(alloc);
    }
    var omission_summary: context_contract.ContextOmissionSummaryBuilder = .{};
    defer {
        for (omissions.items) |omission| alloc.free(@constCast(omission.source));
        omissions.deinit(alloc);
    }

    for (prompt_arr.array.items) |block| {
        if (block != .object) continue;
        const block_type = block.object.get("type") orelse continue;
        if (block_type != .string) continue;

        if (std.mem.eql(u8, block_type.string, "text")) {
            if (block.object.get("text")) |text_val| {
                if (text_val == .string) {
                    if (text_buf.items.len > 0) try text_buf.append(alloc, '\n');
                    try text_buf.appendSlice(alloc, text_val.string);
                }
            }
        } else if (std.mem.eql(u8, block_type.string, "image")) {
            const data_value = block.object.get("data") orelse return error.InvalidPromptImage;
            const media_type_value = block.object.get("mimeType") orelse return error.InvalidPromptImage;
            if (data_value != .string or media_type_value != .string or media_type_value.string.len == 0) {
                return error.InvalidPromptImage;
            }
            const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(data_value.string) catch
                return error.InvalidPromptImage;
            if (decoded_len == 0) return error.InvalidPromptImage;
            if (decoded_len > image_attachments.max_image_bytes) {
                return error.ImageTooLarge;
            }
            const decoded = try alloc.alloc(u8, decoded_len);
            errdefer alloc.free(decoded);
            std.base64.standard.Decoder.decode(decoded, data_value.string) catch
                return error.InvalidPromptImage;
            const canonical_len = std.base64.standard.Encoder.calcSize(decoded.len);
            if (canonical_len != data_value.string.len) return error.InvalidPromptImage;
            const canonical = try alloc.alloc(u8, canonical_len);
            defer alloc.free(canonical);
            const encoded = std.base64.standard.Encoder.encode(canonical, decoded);
            if (!std.mem.eql(u8, encoded, data_value.string)) return error.InvalidPromptImage;

            const image_id = std.math.add(usize, first_image_id, pending_images.items.len) catch
                return error.ImageIdOverflow;
            if (text_buf.items.len > 0) try text_buf.append(alloc, '\n');
            var placeholder: std.Io.Writer.Allocating = .init(alloc);
            defer placeholder.deinit();
            try image_attachments.writeImagePlaceholder(&placeholder.writer, image_id);
            try text_buf.appendSlice(alloc, placeholder.writer.buffered());

            const media_type = try alloc.dupe(u8, media_type_value.string);
            errdefer alloc.free(media_type);
            try pending_images.append(alloc, .{
                .id = image_id,
                .bytes = decoded,
                .media_type = media_type,
            });
        } else if (std.mem.eql(u8, block_type.string, "resource")) {
            if (block.object.get("resource")) |resource| {
                if (resource == .object) {
                    const uri = if (resource.object.get("uri")) |uri_value|
                        if (uri_value == .string) uri_value.string else ""
                    else
                        "";
                    if (uri.len > 0) {
                        if (try localFileTargetPath(alloc, uri)) |path| {
                            errdefer alloc.free(path);
                            try targets.append(alloc, .{ .path = path, .kind = .file });
                        } else {
                            var duplicate = false;
                            for (omissions.items) |omission| {
                                if (omission.reason == .unsafe_target and std.mem.eql(u8, omission.source, uri)) {
                                    duplicate = true;
                                    break;
                                }
                            }
                            if (!duplicate) {
                                if (omissions.items.len < context_contract.Limits.project_omission_records) {
                                    const source = try alloc.dupe(u8, uri);
                                    errdefer alloc.free(source);
                                    try omissions.append(alloc, .{
                                        .source = source,
                                        .reason = .unsafe_target,
                                    });
                                } else {
                                    omission_summary.add(uri, .unsafe_target);
                                }
                            }
                        }
                    }
                    if (resource.object.get("text")) |text_val| {
                        if (text_val == .string) {
                            if (text_buf.items.len > 0) try text_buf.append(alloc, '\n');
                            if (uri.len > 0) {
                                try text_buf.appendSlice(alloc, "File: ");
                                try text_buf.appendSlice(alloc, uri);
                                try text_buf.append(alloc, '\n');
                            }
                            try text_buf.appendSlice(alloc, text_val.string);
                        }
                    }
                }
            }
        }
    }

    var result = ParsedPromptInput{
        .text = try alloc.dupe(u8, text_buf.items),
        .continue_recovery = continue_recovery,
    };
    errdefer result.deinit(alloc);
    result.targets = try targets.toOwnedSlice(alloc);
    result.omissions = try omissions.toOwnedSlice(alloc);
    result.pending_images = try pending_images.toOwnedSlice(alloc);
    result.omission_summary = omission_summary.finish();
    return result;
}

fn localFileTargetPath(alloc: Allocator, uri_text: []const u8) Allocator.Error!?[]u8 {
    const uri = std.Uri.parse(uri_text) catch return null;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "file") or
        uri.user != null or
        uri.password != null or
        uri.host != null or
        uri.port != null or
        uri.query != null or
        uri.fragment != null)
    {
        return null;
    }

    const encoded_path = switch (uri.path) {
        .raw, .percent_encoded => |path| path,
    };
    const decoded_storage = try alloc.dupe(u8, encoded_path);
    defer alloc.free(decoded_storage);

    var read_index: usize = 0;
    var write_index: usize = 0;
    while (read_index < decoded_storage.len) {
        const byte = if (decoded_storage[read_index] == '%') blk: {
            if (decoded_storage.len - read_index < 3) return null;
            const value = std.fmt.parseInt(
                u8,
                decoded_storage[read_index + 1 .. read_index + 3],
                16,
            ) catch return null;
            read_index += 3;
            break :blk value;
        } else blk: {
            const value = decoded_storage[read_index];
            read_index += 1;
            break :blk value;
        };
        if (byte == 0) return null;
        decoded_storage[write_index] = byte;
        write_index += 1;
    }
    const decoded_path = decoded_storage[0..write_index];
    if (!std.fs.path.isAbsolute(decoded_path)) return null;

    var components = std.mem.splitScalar(u8, decoded_path, '/');
    while (components.next()) |component| {
        if (std.mem.eql(u8, component, "..")) return null;
    }

    return io_mod.realpathAlloc(alloc, decoded_path) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => null,
    };
}

fn agentRuntimeDeps(ctx: *AcpContext) agent_runtime.AgentRuntimeDeps {
    const session = if (ctx.state.active_session) |*active| active else unreachable;
    return .{
        .ctx = @ptrCast(ctx),
        .agent_stream_provider = server.streamProviderFor(ctx.state, ctx.state.active_session.?.provider),
        .flush_assistant_stream_per_content_chunk = false,
        .render_assistant_text = false,
        .tool_registry = ctx.toolRegistry(),
        .context_registry = ctx.state.cfg.context_registry,
        .context_enabled = ctx.state.context_enabled,
        .finalize_turn = finalizeTurn,
        .release_agent_terminal_lease = releaseAgentTerminalLease,
        .append_runtime_context = appendRuntimeContext,
        .append_static_context = appendStaticContext,
        .validate_tool_call = validateToolCall,

        .prepare_skill_call = prepareSkillCall,
        .check_tool_availability = checkToolAvailability,
        .request_tool_permission = requestToolPermissionOutcomeWithRequest,
        .request_prepared_file_mutation_permission = requestPreparedFileMutationPermissionOutcomeForRuntime,
        .resolve_tool_action_display_target = resolveToolActionDisplayTarget,
        .describe_tool_action = describeToolAction,
        .describe_tool_action_completed = describeToolActionCompleted,
        .describe_tool_action_denied = describeToolActionDenied,
        .permission_target_for_call = permissionTargetForCall,
        .execute_tool_call = executeToolCall,
        .publish_committed_file_handoff = publishCommittedFileHandoff,
        .publish_deferred_tool_completion = publishDeferredToolCompletion,
        .propagate_history_turn = propagateHistoryTurn,
        .commit_context_compaction = .{ .commit = commitContextCompaction },
        .recovery_checkpoint = if (session.writable != null)
            .{
                .set = setRecoveryCheckpoint,
                .clear = clearRecoveryCheckpoint,
            }
        else
            null,
        .propagate_grant = retainAcpGrant,
        .push_event = pushEvent,
        .push_text = pushText,
        .push_reasoning_delta = pushReasoningDelta,
        .push_route_recovery_status = pushRouteRecoveryStatus,
        .push_tool_lifecycle = pushToolLifecycle,
        .push_diff_block = pushDiffBlock,
        .push_system_notice = pushSystemNotice,
        .push_context_notice = pushContextNotice,
        .push_command_output_complete = pushCommandOutputComplete,
        .push_http_error = pushHttpError,
        .refresh_gateway_credential = refreshGatewayCredential,
        .available_model_capabilities = availableModelCapabilities,
        .resolve_model_capabilities = resolveModelCapabilities,
        .model_catalog_unavailable = modelCatalogUnavailable,
        .format_tool_execution_error = formatToolExecutionError,
        .record_tool_call_rejected = recordToolCallRejected,
        .record_tool_call_failed = recordToolCallFailed,
        .usage = &session.session_rt.usage,
        .usage_allocator = ctx.state.alloc,
    };
}

fn releaseAgentTerminalLease(raw_ctx: *anyopaque, session_id: []const u8) !void {
    const ctx: *AcpContext = @ptrCast(@alignCast(raw_ctx));
    return tool_runtime.release_agent_terminal_lease(ctx.toolContext(), session_id);
}

fn refreshGatewayCredential(
    raw: *anyopaque,
    alloc: Allocator,
    source: types.CredentialSource,
    mode: auth_runtime.CredentialRefreshMode,
) !?[]u8 {
    const ctx: *AcpContext = @ptrCast(@alignCast(raw));
    return server.refreshModelCredential(
        @ptrCast(ctx.state),
        alloc,
        source,
        mode,
        null,
    );
}

fn persistUsageCheckpoint(
    raw_ctx: *anyopaque,
    snapshot: session_usage.Snapshot,
) !void {
    const ctx: *AcpContext = @ptrCast(@alignCast(raw_ctx));
    const active = if (ctx.state.active_session) |*session|
        session
    else
        return error.SessionPersistenceUnavailable;
    if (!std.mem.eql(u8, active.session_id, ctx.session_id)) {
        return error.SessionPersistenceUnavailable;
    }
    active.session_write_mutex.lockUncancelable(io_mod.getIo());
    defer active.session_write_mutex.unlock(io_mod.getIo());
    const writable = if (active.writable) |*value|
        value
    else
        return error.SessionPersistenceUnavailable;
    const store = if (active.store) |*value|
        value
    else
        return error.SessionPersistenceUnavailable;
    const recovery_checkpoint = try store.prepareUsageRecoveryCheckpoint(
        ctx.alloc,
        writable,
        snapshot,
    );
    _ = try writable.appendEvent(
        ctx.alloc,
        .{ .usage_checkpointed = .{ .usage = snapshot } },
        recovery_checkpoint.timestamp_ms,
    );
    try store.finishUsageRecoveryCheckpoint(
        writable.active_id,
        recovery_checkpoint,
    );
}

fn modelCatalogUnavailable(raw_ctx: *anyopaque) bool {
    const ctx: *AcpContext = @ptrCast(@alignCast(raw_ctx));
    return ctx.state.capability_resolver.state == .failed;
}

fn resolveModelCapabilities(
    raw_ctx: *anyopaque,
    _: Allocator,
    model: []const u8,
) model_capabilities.ResolveError!model_capabilities.Capabilities {
    const ctx: *AcpContext = @ptrCast(@alignCast(raw_ctx));
    const session = if (ctx.state.active_session) |*active| active else return .{};
    const bundle = ctx.state.cfg.provider_set.select(session.provider);
    return ctx.state.capability_resolver.resolve(
        ctx.state.alloc,
        bundle.model_catalog orelse return bundle.fallbackModelCapabilities(model),
        .{
            .access = credentials.catalogAccessForCredentialAndAccount(
                session.credential_source,
                session.api_key,
                null,
                session.account_id,
            ),
            .endpoint = ctx.state.cfg.gateway_models_path,
            .cancel_flag = &session.cancel_flag,
        },
        model,
        bundle.fallbackModelCapabilities(model),
    );
}

/// Subagent model overrides resolve against the same catalog the capability
/// path uses. The resolve loads the catalog on first use; only cancellation
/// or an unavailable catalog falls back to raw passthrough.
fn resolveModelOverride(
    raw_ctx: ?*anyopaque,
    alloc: Allocator,
    raw_model: []const u8,
) Allocator.Error!subagent_model_contract.ModelCatalogMatch {
    const ctx: *AcpContext = @ptrCast(@alignCast(raw_ctx.?));
    const session = if (ctx.state.active_session) |*active| active else return .no_catalog;
    const bundle = ctx.state.cfg.provider_set.select(session.provider);
    const catalog_provider = bundle.model_catalog orelse return .no_catalog;
    _ = ctx.state.capability_resolver.resolve(
        ctx.state.alloc,
        catalog_provider,
        .{
            .access = credentials.catalogAccessForCredentialAndAccount(
                session.credential_source,
                session.api_key,
                null,
                session.account_id,
            ),
            .endpoint = ctx.state.cfg.gateway_models_path,
            .cancel_flag = &session.cancel_flag,
        },
        raw_model,
        bundle.fallbackModelCapabilities(raw_model),
    ) catch return .no_catalog;
    const entries = ctx.state.capability_resolver.catalogEntries() orelse return .no_catalog;
    var ids = try gateway_model_catalog.projectModelIds(alloc, entries);
    defer {
        for (ids.items) |id| alloc.free(id);
        ids.deinit(alloc);
    }
    return subagent_model_contract.matchCatalogModel(alloc, ids.items, raw_model);
}

fn availableModelCapabilities(
    raw_ctx: *anyopaque,
    model: []const u8,
) model_capabilities.Capabilities {
    const ctx: *AcpContext = @ptrCast(@alignCast(raw_ctx));
    const session = if (ctx.state.active_session) |*active| active else return .{};
    return ctx.state.capability_resolver.available(
        model,
        ctx.state.cfg.provider_set.select(session.provider).fallbackModelCapabilities(model),
    );
}

fn finalizeTurn(raw_ctx: *anyopaque, turn_id: u64, outcome: types.TurnPresentationOutcome, disposition: ?types.ProviderCompletionDisposition) !void {
    std.debug.assert(turn_id != 0);
    const ctx: *AcpContext = @ptrCast(@alignCast(raw_ctx));
    if (disposition == .length_limited) {
        ctx.stop_reason = .max_output_tokens;
    } else if (outcome == .failed or outcome == .paused) {
        ctx.stop_reason = .refused;
    }
}

fn appendRuntimeContext(raw_ctx: *anyopaque, arena: Allocator, messages: *std.ArrayList(ChatMessage)) !void {
    const ctx: *AcpContext = @ptrCast(@alignCast(raw_ctx));
    const session = if (ctx.state.active_session) |*active| active else unreachable;
    try ctx.state.cfg.context_registry.appendDefaultTransient(.{
        .workspace_root = ctx.state.workspace_root,
        .access_scope = ctx.state.workspace_access.scope(ctx.state.workspace_root),
        .interactive = false,
        .permission_mode = ctx.captured_permission_mode orelse session.permission_mode,
    }, arena, messages);
}

fn appendStaticContext(raw_ctx: *anyopaque, arena: Allocator, project_context: ?[]const u8, messages: *std.ArrayList(ChatMessage)) !void {
    const ctx: *AcpContext = @ptrCast(@alignCast(raw_ctx));
    try ctx.state.cfg.context_registry.appendDefaultStatic(.{
        .project_context = project_context orelse ctx.modelVisibleProjectContext(),
    }, arena, messages);
}

fn validateToolCall(raw_ctx: *anyopaque, arena: Allocator, call: ToolCall) !agent_runtime.ToolCallValidationResult {
    const ctx: *AcpContext = @ptrCast(@alignCast(raw_ctx));
    if (ctx.state.active_session) |session| {
        const mode = ctx.captured_mode orelse session.mode;
        if (try ctx.state.cfg.mode_registry.toolPolicyDeniedJson(arena, activeToolSet(ctx.state), mode, call.name)) |reason| {
            return .{ .failure = reason };
        }
    }
    return tool_runtime.validateToolCall(ctx.toolContext(), arena, call);
}

fn checkToolAvailability(raw_ctx: *anyopaque, arena: Allocator, call: ToolCall) !?[]const u8 {
    const ctx: *AcpContext = @ptrCast(@alignCast(raw_ctx));
    return tool_runtime.checkToolAvailability(ctx.toolContext(), arena, call);
}

fn prepareSkillCall(raw_ctx: *anyopaque, arena: Allocator, call: ToolCall, locations: ?*const skill_contract.Locations) !skill_contract.CallPreparation {
    const ctx: *AcpContext = @ptrCast(@alignCast(raw_ctx));
    return tool_runtime.prepareSkillCall(ctx.toolContext(), arena, call, locations);
}

fn requestPreparedFileMutationPermissionOutcomeForRuntime(raw_ctx: *anyopaque, arena: Allocator, call: ToolCall, prepared: *tool_admission.PreparedFileMutationCall, review_turn: permission_auto_classifier.ReviewTurnContext, permission_mode: PermissionMode, local_grants: []const PermissionGrant, live_authority: ?agent_runtime.LiveToolAuthority, advertised_dynamic_tool_names: []const []const u8) !command_admission.PermissionOutcome {
    const ctx: *AcpContext = @ptrCast(@alignCast(raw_ctx));
    var tool_ctx = tool_runtime.withAdvertisedDynamicToolNames(ctx.toolContext(), advertised_dynamic_tool_names);
    tool_ctx.permission_review_turn = review_turn;
    const admission = tool_ctx.admissionInputWithLiveAuthority(live_authority);
    return tool_admission.requestPreparedFileMutationPermissionOutcome(
        admission,
        arena,
        call,
        prepared,
        permission_mode,
        local_grants,
    );
}

fn requestToolPermissionOutcome(raw_ctx: *anyopaque, arena: Allocator, call: ToolCall, permission_mode: PermissionMode, local_grants: []const PermissionGrant, advertised_dynamic_tool_names: []const []const u8) !command_admission.PermissionOutcome {
    const ctx: *AcpContext = @ptrCast(@alignCast(raw_ctx));
    const tool_ctx = tool_runtime.withAdvertisedDynamicToolNames(ctx.toolContext(), advertised_dynamic_tool_names);
    return tool_admission.requestPermissionOutcome(
        tool_ctx.admissionInput(),
        arena,
        call,
        permission_mode,
        local_grants,
    );
}

fn requestToolPermissionOutcomeWithRequest(raw_ctx: *anyopaque, arena: Allocator, call: ToolCall, review_turn: permission_auto_classifier.ReviewTurnContext, permission_mode: PermissionMode, local_grants: []const PermissionGrant, live_authority: ?agent_runtime.LiveToolAuthority, revalidation: ?agent_runtime.LivePermissionRevalidation, advertised_dynamic_tool_names: []const []const u8) !command_admission.PermissionOutcome {
    const ctx: *AcpContext = @ptrCast(@alignCast(raw_ctx));
    var tool_ctx = tool_runtime.withAdvertisedDynamicToolNames(ctx.toolContext(), advertised_dynamic_tool_names);
    tool_ctx.permission_review_turn = review_turn;
    const admission = tool_ctx.admissionInputWithLiveAuthority(live_authority);
    return if (revalidation) |request| switch (request) {
        .action => |action| tool_admission.revalidateLiveActionPermissionOutcome(
            admission,
            arena,
            call,
            permission_mode,
            local_grants,
            action.authority,
            action.human_approval,
        ),
    } else tool_admission.requestPermissionOutcome(
        admission,
        arena,
        call,
        permission_mode,
        local_grants,
    );
}

const TestReviewTurn = struct {
    tool_calls: [1]ToolCall,
    root_messages: [1][]const u8,

    fn init(root_text: []const u8, call: ToolCall) TestReviewTurn {
        return .{
            .tool_calls = .{call},
            .root_messages = .{root_text},
        };
    }

    fn context(self: *const TestReviewTurn) permission_auto_classifier.ReviewTurnContext {
        return .{
            .model = "openai/gpt-5",
            .pending_assistant = .{ .role = .assistant, .tool_calls = &self.tool_calls },
            .target_call_id = self.tool_calls[0].id,
            .origin = .root,
            .trusted_root_context = self.root_messages[0],
        };
    }
};

fn requestAcpPermission(
    raw_ctx: *anyopaque,
    alloc: Allocator,
    request: permission_request.PermissionRequest,
    call: ToolCall,
    _: ?*const diff_mod.FileReview,
    _: ?[]const PermissionGrant,
) anyerror!permission_request.OwnedPermissionResponse {
    var validated_arguments: std.Io.Writer.Allocating = .init(alloc);
    defer validated_arguments.deinit();
    try writeValidatedToolArguments(alloc, &validated_arguments.writer, call.arguments_json);

    const ctx: *AcpContext = @ptrCast(@alignCast(raw_ctx));
    const request_id = server.beginPermissionRequest(ctx.state) orelse return error.PermissionRequestAlreadyPending;
    errdefer {
        server.cancelPermissionRequest(ctx.state, request_id);
        _ = server.awaitPermissionDecision(ctx.state, request_id);
    }

    var pending_arena = std.heap.ArenaAllocator.init(alloc);
    defer pending_arena.deinit();
    const tool_call_id = try ctx.sendToolCallPending(pending_arena.allocator(), call);

    var params: std.Io.Writer.Allocating = .init(alloc);
    defer params.deinit();
    try params.writer.writeAll("{\"sessionId\":");
    try jsonrpc.writeJsonStr(ctx.session_id, &params.writer);
    try params.writer.writeAll(",\"toolCall\":{\"toolCallId\":");
    try jsonrpc.writeJsonStr(tool_call_id, &params.writer);
    try params.writer.writeAll(",\"name\":");
    try jsonrpc.writeJsonStr(acpToolName(call.name), &params.writer);
    try params.writer.writeAll(",\"title\":");
    try jsonrpc.writeJsonStr(request.label, &params.writer);
    try params.writer.writeAll(",\"kind\":");
    try jsonrpc.writeJsonStr(mapToolKind(call.name).jsonString(), &params.writer);
    try params.writer.writeAll(",\"status\":\"pending\",\"rawInput\":");
    try params.writer.writeAll(validated_arguments.written());
    try params.writer.writeAll("},\"options\":[");
    try writePermissionOption(&params.writer, "allow_once", "Allow once", "allow_once");
    try params.writer.writeByte(',');
    try writePermissionOption(&params.writer, "allow_always", "Allow for this session", "allow_always");
    try params.writer.writeByte(',');
    try writePermissionOption(&params.writer, "reject_once", "Reject", "reject_once");
    try params.writer.writeAll("]}");

    try ctx.state.writer.writeRequest(
        alloc,
        .{ .integer = @intCast(request_id) },
        "session/request_permission",
        params.writer.buffered(),
    );
    const decision = server.awaitPermissionDecision(ctx.state, request_id);
    return permission_request.OwnedPermissionResponse.init(alloc, decision, null);
}

fn writeValidatedToolArguments(alloc: Allocator, writer: *std.Io.Writer, arguments_json: []const u8) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, arguments_json, .{}) catch
        return error.InvalidToolArgumentsJson;
    defer parsed.deinit();
    try std.json.Stringify.value(parsed.value, .{}, writer);
}

fn writePermissionOption(
    writer: *std.Io.Writer,
    option_id: []const u8,
    name: []const u8,
    kind: []const u8,
) !void {
    try writer.writeAll("{\"optionId\":");
    try jsonrpc.writeJsonStr(option_id, writer);
    try writer.writeAll(",\"name\":");
    try jsonrpc.writeJsonStr(name, writer);
    try writer.writeAll(",\"kind\":");
    try jsonrpc.writeJsonStr(kind, writer);
    try writer.writeByte('}');
}

fn describeToolAction(raw_ctx: *anyopaque, arena: Allocator, call: ToolCall, display_target: ?[]const u8, _: []const []const u8) ![]const u8 {
    const ctx: *AcpContext = @ptrCast(@alignCast(raw_ctx));
    return tool_presentation.formatPlainAction(arena, .{
        .tool_registry = ctx.toolRegistry(),
        .call = call,
        .display_target = display_target,
    });
}

fn resolveToolActionDisplayTarget(raw_ctx: *anyopaque, arena: Allocator, call: ToolCall) !?[]const u8 {
    const ctx: *AcpContext = @ptrCast(@alignCast(raw_ctx));
    return tool_presentation.resolveTerminalDisplayTarget(
        arena,
        ctx.toolRegistry(),
        ctx.state.workspace_root,
        &ctx.state.terminal_client,
        &ctx.state.managed_executions,
        call,
    );
}

fn describeToolActionCompleted(raw_ctx: *anyopaque, arena: Allocator, call: ToolCall, display_target: ?[]const u8, _: []const []const u8) ![]const u8 {
    const ctx: *AcpContext = @ptrCast(@alignCast(raw_ctx));
    if (try tool_presentation.formatSubagentPlainAction(arena, call, .completed)) |line| return line;
    return tool_presentation.formatPlainAction(arena, .{
        .tool_registry = ctx.toolRegistry(),
        .call = call,
        .display_target = display_target,
    });
}

fn describeToolActionDenied(raw_ctx: *anyopaque, arena: Allocator, call: ToolCall, display_target: ?[]const u8, label: []const u8, _: []const []const u8) ![]const u8 {
    const ctx: *AcpContext = @ptrCast(@alignCast(raw_ctx));
    if (try tool_presentation.formatSubagentPlainAction(arena, call, .{ .stopped = label })) |line| return line;
    const action = try tool_presentation.formatPlainAction(arena, .{
        .tool_registry = ctx.toolRegistry(),
        .call = call,
        .display_target = display_target,
    });
    return std.fmt.allocPrint(arena, "{s}: {s}", .{ label, action });
}

fn permissionTargetForCall(raw_ctx: *anyopaque, arena: Allocator, call: ToolCall, advertised_dynamic_tool_names: []const []const u8) ![]const u8 {
    const ctx: *AcpContext = @ptrCast(@alignCast(raw_ctx));
    const tool_ctx = tool_runtime.withAdvertisedDynamicToolNames(
        ctx.toolContext(),
        advertised_dynamic_tool_names,
    );
    return tool_admission.permissionTargetForCall(tool_ctx.admissionInput(), arena, call);
}

fn executeToolCall(
    raw_ctx: *anyopaque,
    request: agent_runtime.ToolExecutionRequest,
) !ToolExecutionResult {
    const ctx: *AcpContext = @ptrCast(@alignCast(raw_ctx));

    const acp_id = ctx.sendToolCallPending(request.call_allocator, request.call) catch "call_unknown";
    ctx.sendToolCallProgressText(acp_id, null) catch {};

    var tool_ctx = ctx.toolContext();
    tool_ctx.root_user_intent_context = request.root_user_intent_context;
    tool_ctx.root_user_messages = request.root_user_messages;
    tool_ctx.root_user_evidence_complete = request.root_user_evidence_complete;
    var progress_ctx = AcpWebSearchProgressContext{ .ctx = ctx, .tool_call_id = acp_id };
    var fetch_progress_ctx = AcpWebFetchProgressContext{ .ctx = ctx, .tool_call_id = acp_id };
    tool_ctx.web_search_progress_ctx = @ptrCast(&progress_ctx);
    tool_ctx.on_web_search_progress = onWebSearchProgress;
    tool_ctx.web_fetch_progress_ctx = @ptrCast(&fetch_progress_ctx);
    tool_ctx.on_web_fetch_progress = onWebFetchProgress;
    tool_ctx.session_grants = request.session_grants;
    tool_ctx.advertised_dynamic_tool_names = request.advertised_dynamic_tool_names;
    tool_ctx.max_tool_result_bytes = request.max_tool_result_bytes;
    const result = tool_runtime.executeToolCallAuthorized(tool_ctx, request) catch |err| {
        const err_text = try formatToolExecutionError(
            raw_ctx,
            request.result_allocator,
            request.call.name,
            err,
        );
        sendAuthorizedToolCallError(ctx, request, acp_id, err, err_text);
        return err;
    };

    return completeAuthorizedToolCallTransport(ctx, request, acp_id, result);
}

fn sendAuthorizedToolCallError(
    ctx: *AcpContext,
    _: agent_runtime.ToolExecutionRequest,
    acp_id: []const u8,
    _: anyerror,
    err_text: []const u8,
) void {
    ctx.sendToolCallError(acp_id, err_text) catch {};
}

fn completeAuthorizedToolCallTransport(
    ctx: *AcpContext,
    request: agent_runtime.ToolExecutionRequest,
    acp_id: []const u8,
    result: ToolExecutionResult,
) ToolExecutionResult {
    return completeToolCallTransport(ctx, request.call, acp_id, result);
}

fn completeToolCallTransport(
    ctx: *AcpContext,
    call: ToolCall,
    acp_id: []const u8,
    result: ToolExecutionResult,
) ToolExecutionResult {
    const output_text = toolUpdateContentText(result);
    if (result.status == .failure) {
        ctx.sendToolCallErrorWithCommandResult(
            acp_id,
            output_text,
            result.command_result_json,
        ) catch {};
        return result;
    }
    if (file_mutation_contract.isToolName(call.name) and
        result.committed_file_handoff != null)
    {
        var deferred = result;
        deferred.deferred_tool_completion = .{
            .transport_id = acp_id,
            .content_text = output_text,
            .command_result_json = result.command_result_json,
        };
        return deferred;
    }
    ctx.sendToolCallCompletedWithCommandResult(
        acp_id,
        output_text,
        result.command_result_json,
    ) catch {};
    return result;
}

fn publishCommittedFileHandoff(
    _: *anyopaque,
    _: file_mutation.CommittedFileHandoff,
) agent_runtime.SecondaryPublicationReport {
    return .{ .diff = .skipped, .tracker = .skipped };
}

fn publishDeferredToolCompletion(
    raw_ctx: *anyopaque,
    completion: agent_runtime.DeferredToolCompletion,
) agent_runtime.TransportPublicationOutcome {
    const ctx: *AcpContext = @ptrCast(@alignCast(raw_ctx));
    ctx.sendToolCallCompletedWithCommandResult(
        completion.transport_id,
        completion.content_text,
        completion.command_result_json,
    ) catch |err| {
        debug_trace.logf(
            "acp",
            "deferred ACP completion publication failed call_id={s} err={s}",
            .{ completion.transport_id, @errorName(err) },
        );
        return .failed;
    };
    return .published;
}

const AcpWebSearchProgressContext = struct {
    ctx: *AcpContext,
    tool_call_id: []const u8,
};

const AcpWebFetchProgressContext = struct {
    ctx: *AcpContext,
    tool_call_id: []const u8,
};

fn onWebSearchProgress(raw_ctx: *anyopaque, _: []const u8, progress: types.WebSearchProgress) void {
    const progress_ctx: *AcpWebSearchProgressContext = @ptrCast(@alignCast(raw_ctx));
    progress_ctx.ctx.sendWebSearchProgress(progress_ctx.tool_call_id, progress) catch {};
}

fn onWebFetchProgress(raw_ctx: *anyopaque, _: []const u8, progress: types.WebFetchProgress) void {
    const progress_ctx: *AcpWebFetchProgressContext = @ptrCast(@alignCast(raw_ctx));
    progress_ctx.ctx.sendWebFetchProgress(progress_ctx.tool_call_id, progress) catch {};
}

fn writeWebSearchProgressUpdate(alloc: Allocator, writer: *std.Io.Writer, tool_call_id: []const u8, progress: types.WebSearchProgress) !void {
    const text = try tool_presentation.formatWebSearchProgressPlain(alloc, progress);
    defer alloc.free(text);
    try acp_types.writeToolCallUpdate(writer, tool_call_id, .in_progress, text);
}

fn writeWebFetchProgressUpdate(alloc: Allocator, writer: *std.Io.Writer, tool_call_id: []const u8, progress: types.WebFetchProgress) !void {
    const text = try tool_presentation.formatWebFetchProgressPlain(alloc, progress);
    defer alloc.free(text);
    try acp_types.writeToolCallUpdate(writer, tool_call_id, .in_progress, text);
}

fn recordToolCallRejected(
    raw_ctx: *anyopaque,
    arena: Allocator,
    call: ToolCall,
    model_output: []const u8,
    command_result_json: ?[]const u8,
) !void {
    const ctx: *AcpContext = @ptrCast(@alignCast(raw_ctx));
    const acp_id = ctx.sendToolCallPending(arena, call) catch "call_unknown";
    ctx.sendToolCallErrorWithCommandResult(
        acp_id,
        toolUpdateContentText(.{
            .status = .failure,
            .model_output = model_output,
        }),
        command_result_json,
    ) catch {};
}

fn recordToolCallFailed(
    raw_ctx: *anyopaque,
    arena: Allocator,
    call: ToolCall,
    model_output: []const u8,
    command_result_json: ?[]const u8,
) !void {
    const ctx: *AcpContext = @ptrCast(@alignCast(raw_ctx));
    const acp_id = ctx.sendToolCallPending(arena, call) catch "call_unknown";
    ctx.sendToolCallErrorWithCommandResult(
        acp_id,
        toolUpdateContentText(.{
            .status = .failure,
            .model_output = model_output,
        }),
        command_result_json,
    ) catch {};
}

fn toolUpdateContentText(result: ToolExecutionResult) []const u8 {
    return tool_call_presentation.toolUpdateContentText(result.status == .failure, result.model_output);
}

fn propagateHistoryTurn(raw_ctx: *anyopaque, turn: HistoryTurn) !void {
    const ctx: *AcpContext = @ptrCast(@alignCast(raw_ctx));
    if (ctx.state.active_session) |*session| {
        try persistAcpHistoryTurn(
            ctx.alloc,
            session,
            turn,
            ctx.current_prompt_input,
        );
    }
}

fn persistAcpHistoryTurn(
    alloc: Allocator,
    session: *server.ActiveSessionState,
    turn: HistoryTurn,
    current_prompt_input: ?*ParsedPromptInput,
) !void {
    session.session_write_mutex.lockUncancelable(io_mod.getIo());
    defer session.session_write_mutex.unlock(io_mod.getIo());
    var prepared = try session.session_rt.prepareHistoryEntry(alloc, turn);
    var prepared_owned = true;
    defer if (prepared_owned) types.freeHistoryTurn(alloc, prepared);
    const writable = if (session.writable) |*value| value else {
        session.session_rt.commitPreparedHistoryEntry(alloc, prepared);
        prepared_owned = false;
        if (current_prompt_input) |prompt_input| prompt_input.retainImageSnapshots();
        return;
    };
    try writable.prepareHistoryTurnForCommit(alloc, &prepared);
    _ = writable.appendEvent(
        alloc,
        .{ .history_turn_committed = .{
            .conversation_language = session.session_rt.languageSnapshot(),
            .total_input_tokens = writable.state.total_input_tokens,
            .total_output_tokens = writable.state.total_output_tokens,
            .turn = prepared,
        } },
        io_mod.milliTimestamp(),
    ) catch |err| {
        if (err == error.SessionPersistenceUncertain) {
            if (current_prompt_input) |input| input.retainImageSnapshots();
        }
        return err;
    };
    session.session_rt.commitPreparedHistoryEntry(alloc, prepared);
    prepared_owned = false;
    if (current_prompt_input) |prompt_input| prompt_input.retainImageSnapshots();
}

fn commitContextCompaction(
    raw_ctx: *anyopaque,
    summary: types.CompactedSummaryHistoryTurn,
    active_prefix: ?types.AssistantHistoryTurn,
    retained_from: ?types.ContextHistoryCut,
) !void {
    const ctx: *AcpContext = @ptrCast(@alignCast(raw_ctx));
    const session = if (ctx.state.active_session) |*value| value else return error.SessionPersistenceUnavailable;
    session.session_write_mutex.lockUncancelable(io_mod.getIo());
    defer session.session_write_mutex.unlock(io_mod.getIo());
    const prepared = try session_runtime.prepareCompactedHistory(ctx.alloc, session.session_rt.agent.history.items, summary, retained_from orelse .{ .turns = session_runtime.rawHistoryTurnCount(session.session_rt.agent.history.items) });
    var prepared_owned = true;
    defer if (prepared_owned) types.freeHistoryTurnSlice(ctx.alloc, prepared);
    if (session.writable) |*writable| {
        _ = writable.commitContextCompaction(ctx.alloc, summary, active_prefix, retained_from, io_mod.milliTimestamp()) catch |err| {
            if (err == error.SessionPersistenceUncertain and active_prefix != null) {
                if (ctx.current_prompt_input) |input| input.retainImageSnapshots();
            }
            return err;
        };
        if (active_prefix != null) {
            if (ctx.current_prompt_input) |input| input.retainImageSnapshots();
        }
    }
    session.session_rt.commitCompactedHistory(ctx.alloc, prepared);
    prepared_owned = false;
}

fn setRecoveryCheckpoint(
    raw_ctx: *anyopaque,
    checkpoint: session_codec.RecoveryCheckpoint,
) !void {
    const ctx: *AcpContext = @ptrCast(@alignCast(raw_ctx));
    errdefer |err| if (err == error.SessionPersistenceUncertain) {
        if (ctx.current_prompt_input) |input| input.retainImageSnapshots();
    };
    const session = if (ctx.state.active_session) |*value| value else return error.SessionPersistenceUnavailable;
    session.session_write_mutex.lockUncancelable(io_mod.getIo());
    defer session.session_write_mutex.unlock(io_mod.getIo());
    const writable = if (session.writable) |*value| value else return error.SessionPersistenceUnavailable;
    const now_ms = io_mod.milliTimestamp();
    _ = try writable.appendEvent(
        ctx.alloc,
        .{ .recovery_checkpoint_set = .{ .checkpoint = checkpoint } },
        now_ms,
    );
    // The durable checkpoint references the prompt's captured image bytes, so
    // the prompt's deinit must not delete them. A failed turn never reaches
    // the success-path retain, making this the only retain on that path.
    if (ctx.current_prompt_input) |input| input.retainImageSnapshots();
}

fn clearRecoveryCheckpoint(raw_ctx: *anyopaque) !void {
    const ctx: *AcpContext = @ptrCast(@alignCast(raw_ctx));
    const session = if (ctx.state.active_session) |*value| value else return error.SessionPersistenceUnavailable;
    session.session_write_mutex.lockUncancelable(io_mod.getIo());
    defer session.session_write_mutex.unlock(io_mod.getIo());
    const writable = if (session.writable) |*value| value else return error.SessionPersistenceUnavailable;
    if (writable.state.recovery_checkpoint == null) return;
    _ = try writable.appendEvent(
        ctx.alloc,
        .{ .recovery_checkpoint_cleared = .{} },
        io_mod.milliTimestamp(),
    );
}

/// Stores grants on the active ACP session without persisting them.
fn retainAcpGrant(raw_ctx: *anyopaque, tool_name: []const u8, target_path: []const u8) !void {
    const ctx: *AcpContext = @ptrCast(@alignCast(raw_ctx));
    ctx.state.subagent_authority_mutex.lockUncancelable(io_mod.getIo());
    defer ctx.state.subagent_authority_mutex.unlock(io_mod.getIo());
    const session = if (ctx.state.active_session) |*active| active else return;
    try session.retainGrant(ctx.alloc, tool_name, target_path);
}

fn pushEvent(raw_ctx: *anyopaque, event: worker_runtime.WorkerEvent) !void {
    const ctx: *AcpContext = @ptrCast(@alignCast(raw_ctx));
    switch (event) {
        .clear_route_recovery_status => try ctx.clearModelRecoveryStatus(),
        else => {},
    }
    worker_runtime.freeWorkerEvent(std.heap.c_allocator, event);
}

fn pushRouteRecoveryStatus(
    raw_ctx: *anyopaque,
    status: types.RouteRecoveryStatus,
) !void {
    const ctx: *AcpContext = @ptrCast(@alignCast(raw_ctx));
    try ctx.sendModelRecoveryStatus(status);
}

fn pushText(raw_ctx: *anyopaque, emission: agent_runtime.TextEmission) !void {
    const ctx: *AcpContext = @ptrCast(@alignCast(raw_ctx));
    const text, const message_id = switch (emission) {
        .assistant_started => {
            ctx.message_kind = null;
            return;
        },
        .assistant_source => |text| .{ text, ctx.assistantMessageId() },
        .assistant_rendered => return,
        .assistant_restarted => |text| .{ text, ctx.operationalMessageId() },
        .operational => |text| .{ text, ctx.operationalMessageId() },
    };
    if (text.len == 0) return;
    ctx.sendAgentText(message_id, text) catch {};
}

fn pushReasoningDelta(raw_ctx: *anyopaque, delta: []const u8) !void {
    const ctx: *AcpContext = @ptrCast(@alignCast(raw_ctx));
    var update: std.Io.Writer.Allocating = .init(ctx.alloc);
    defer update.deinit();
    try acp_types.writeAgentThoughtChunk(&update.writer, delta);
    try ctx.sendUpdate(update.written());
}

fn pushToolLifecycle(raw_ctx: *anyopaque, event: types.ToolLifecycleEvent) !void {
    const ctx: *AcpContext = @ptrCast(@alignCast(raw_ctx));
    switch (event) {
        .provisional => |provisional| {
            const tool_name = provisional.tool_name orelse return;
            if (!tool_presentation.isProviderSearchAlias(tool_name)) return;
            var arena_state = std.heap.ArenaAllocator.init(ctx.alloc);
            defer arena_state.deinit();
            _ = try ctx.sendToolCallPending(arena_state.allocator(), .{
                .id = provisional.id.call_id,
                .name = tool_name,
                .arguments_json = "{}",
                .provenance = .provider_executed,
            });
        },
        .authoritative_started => |started| {
            var arena_state = std.heap.ArenaAllocator.init(ctx.alloc);
            defer arena_state.deinit();
            _ = try ctx.sendToolCallPending(arena_state.allocator(), .{
                .id = started.id.call_id,
                .name = started.tool_name,
                .arguments_json = started.arguments_json orelse "{}",
            });
        },
        .terminal => |terminal| try ctx.sendProviderTerminal(terminal.id.call_id, terminal.outcome, terminal.result),
        .progress, .turn_finished => {},
    }
}

fn pushSystemNotice(raw_ctx: *anyopaque, text: []const u8) !void {
    const ctx: *AcpContext = @ptrCast(@alignCast(raw_ctx));
    ctx.sendAgentText(ctx.operationalMessageId(), text) catch {};
}

fn pushContextNotice(raw_ctx: *anyopaque, text: []const u8) !void {
    const ctx: *AcpContext = @ptrCast(@alignCast(raw_ctx));
    const session = if (ctx.state.active_session) |*active| active else return;
    if (!try session.session_rt.claimContextNotice(ctx.alloc, text)) return;
    try pushSystemNotice(raw_ctx, text);
}

fn pushDiffBlock(raw_ctx: *anyopaque, payload: agent_runtime.DiffEntryPayload) !void {
    defer diff_mod.freeDiffEntryPayload(std.heap.c_allocator, payload);
    try pushText(raw_ctx, .{ .operational = payload.preview });
}

fn pushCommandOutputComplete(_: *anyopaque, _: ?types.ToolLifecycleId) !void {}

fn pushHttpError(raw_ctx: *anyopaque, status: std.http.Status, detail: []const u8, credential_source: ?types.CredentialSource) !void {
    const ctx: *AcpContext = @ptrCast(@alignCast(raw_ctx));
    var buf: [1024]u8 = undefined;
    const auth_failure = auth_runtime.FailureSnapshot.fromHttp(status, credential_source);
    const owned_message = if (auth_failure) |failure|
        try failure.renderText(ctx.alloc)
    else
        null;
    defer if (owned_message) |message| ctx.alloc.free(message);
    const msg = owned_message orelse if (detail.len > 0)
        std.fmt.bufPrint(&buf, "HTTP {d}: {s}", .{ @intFromEnum(status), detail }) catch "HTTP error"
    else
        std.fmt.bufPrint(&buf, "HTTP {d}", .{@intFromEnum(status)}) catch "HTTP error";
    ctx.sendAgentText(ctx.operationalMessageId(), msg) catch {};
}

fn formatToolExecutionError(_: *anyopaque, arena: Allocator, tool_name: []const u8, err: anyerror) ![]const u8 {
    return tool_result_errors.formatToolExecutionErrorJson(arena, tool_name, err);
}

fn onCommandOutputChunk(raw_ctx: *anyopaque, lifecycle_id: ?types.ToolLifecycleId, _: command_output_content.Stream, chunk: []const u8) !void {
    const ctx: *AcpContext = @ptrCast(@alignCast(raw_ctx));
    const id = lifecycle_id orelse return;
    try ctx.sendToolCallProgressText(id.call_id, chunk);
}

fn acpAwakeMillis() i64 {
    const now = std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake);
    const milliseconds = @divFloor(now.raw.nanoseconds, std.time.ns_per_ms);
    return std.math.cast(i64, milliseconds) orelse if (milliseconds < 0)
        std.math.minInt(i64)
    else
        std.math.maxInt(i64);
}

pub const mapToolKind = tool_call_presentation.mapToolKind;

const acpToolName = tool_call_presentation.acpToolName;

const describeToolTitle = tool_call_presentation.describeToolTitle;

fn providerTerminalStatus(outcome: types.ToolOutcomeKind) ?acp_types.ToolCallStatus {
    return switch (outcome) {
        .completed => .completed,
        .denied, .cancelled, .failed => .failed,
        .deferred => null,
    };
}

fn testResolveChatUrl(_: ?*anyopaque, fallback: []const u8) []const u8 {
    return if (fallback.len == 0) test_openrouter.chat_url_provider.resolve_fn() else fallback;
}

const AcpContextRegistryFixture = struct {
    var gather_calls: usize = 0;
    var gather_error: ?context_contract.ProviderError = null;
    var static_context: ?[]const u8 = null;
    var transient_calls: usize = 0;
    var transient_permission_mode: ?PermissionMode = null;

    fn reset() void {
        gather_calls = 0;
        gather_error = null;
        static_context = null;
        transient_calls = 0;
        transient_permission_mode = null;
    }

    fn gather(alloc: Allocator, _: context_contract.InitialContextInput) context_contract.ProviderError!context_contract.ProviderContext {
        gather_calls += 1;
        if (gather_error) |err| return err;
        return .{ .content = try std.fmt.allocPrint(alloc, "ACP registry context {d}", .{gather_calls}) };
    }

    fn appendStatic(input: context_contract.StaticContextInput, alloc: Allocator, messages: *std.ArrayList(ChatMessage)) context_contract.ProviderError!void {
        static_context = input.project_context;
        try messages.append(alloc, .{ .role = .system, .content = input.project_context });
    }

    fn appendTransient(input: context_contract.TransientContextInput, alloc: Allocator, messages: *std.ArrayList(ChatMessage)) context_contract.ProviderError!void {
        transient_calls += 1;
        transient_permission_mode = input.permission_mode;
        try messages.append(alloc, .{ .role = .system, .content = "ACP registry transient" });
    }
};

const test_acp_context_registry = context_contract.Registry{ .default_provider = .{
    .id = "test.acp_context",
    .gather_project_context_fn = AcpContextRegistryFixture.gather,
    .select_applicable_project_context_fn = context_contract.selectNoApplicableProjectContext,
    .append_static_fn = AcpContextRegistryFixture.appendStatic,
    .append_transient_fn = AcpContextRegistryFixture.appendTransient,
} };

const test_acp_modes = [_]mode_registry.ModeSpec{
    .{ .id = "normal", .name = "Normal" },
    .{
        .id = "plan",
        .name = "Plan",
        .permission_mode = .yolo,
        .tool_policy = .read_only,
        .tool_policy_denial_message = "Plan mode only allows read-only workspace inspection tools.",
    },
};

const test_acp_mode_registry = mode_registry.Registry{
    .default_mode_id = "normal",
    .modes = test_acp_modes[0..],
};

fn testModelPromptOverlay(model: []const u8) ?[]const u8 {
    return if (std.mem.eql(u8, model, "test-model")) "ACP test model overlay" else null;
}

fn testServerConfig() server.Config {
    return .{
        .default_model = "test-model",
        .default_agent_step_limit = 4,
        .gateway_retry_count = 0,
        .gateway_chat_url = "http://127.0.0.1",
        .gateway_models_path = "/models",
        .gateway_provider = .{ .chat_url = .{ .context = @constCast(&test_openrouter), .resolve_fn = testResolveChatUrl } },
        .provider_set = provider_set.openrouter_only(test_openrouter.provider_bundle),
        .secret_store = host.unavailable_secret_store,
        .prompt_policy = .{
            .system_prompt = "test",
            .model_prompt_overlay_fn = testModelPromptOverlay,
        },
        .ignored_list_entries = &.{},
        .max_list_entries = 32,
        .max_read_file_bytes = 1024 * 1024,
        .max_read_file_lines = 1000,
        .max_read_file_line_len = 4096,
        .max_command_output_bytes = 1024 * 1024,
        .max_tool_result_bytes = 1024 * 1024,
        .max_history_turns = 8,
        .context_registry = test_acp_context_registry,
        .mode_registry = test_acp_mode_registry,
    };
}

fn initTestAcpState(alloc: Allocator, workspace_root: []const u8, mode: PermissionMode) !server.ServerState {
    const owned_workspace = try alloc.dupe(u8, workspace_root);
    errdefer alloc.free(owned_workspace);
    const session_id = try alloc.dupe(u8, "session_1");
    errdefer alloc.free(session_id);
    const model = try alloc.dupe(u8, "test-model");
    errdefer alloc.free(model);
    const api_key = try alloc.dupe(u8, "test-api-key");
    errdefer alloc.free(api_key);

    const cfg = testServerConfig();
    return .{
        .alloc = alloc,
        .cfg = cfg,
        .writer = jsonrpc.Writer.init(),
        .workspace_root = owned_workspace,
        .api_key = api_key,
        .credential_source = .openrouter_api_key,
        .web_search_runtime = @import("../core/tooling/web_search_runtime.zig").Runtime.init(.{
            .provider = cfg.provider_set.openrouter.fx_search.?,
        }),
        .active_session = .{
            .session_id = session_id,
            .model = model,
            .mode = "normal",
            .workspace_root = owned_workspace,
            .api_key = api_key,
            .credential_source = .openrouter_api_key,
            .agent_step_limit = 4,
            .max_tool_result_bytes = 1024 * 1024,
            .fast_mode = false,
            .effort = .auto,
            .first_call_tool_choice = .auto,
            .permission_mode = mode,
            .permission_rules = .{},
            .session_rt = .{ .max_history_turns = 8 },
            .cancel_flag = std.atomic.Value(bool).init(false),
            .pending_prompt_id = null,
        },
    };
}

fn testPermissionRuleSet(alloc: Allocator, permission: []const u8, pattern: []const u8, action: types.PermissionAction) !types.PermissionRuleSet {
    var rules = types.PermissionRuleSet{
        .rules = try alloc.alloc(types.PermissionRule, 1),
    };
    errdefer alloc.free(rules.rules);

    const owned_permission = try alloc.dupe(u8, permission);
    errdefer alloc.free(owned_permission);

    const owned_pattern = try alloc.dupe(u8, pattern);
    rules.rules[0] = .{
        .permission = owned_permission,
        .pattern = owned_pattern,
        .action = action,
    };
    return rules;
}

fn createSymlinkOrSkip(dir: std.Io.Dir, target_path: []const u8, link_path: []const u8) !void {
    if (comptime @import("builtin").os.tag == .windows) return error.SkipZigTest;
    dir.symLink(std.testing.io, target_path, link_path, .{ .is_directory = false }) catch |err| {
        if (err == error.AccessDenied or std.mem.eql(u8, @errorName(err), "Permission" ++ "Denied")) {
            return error.SkipZigTest;
        }
        return err;
    };
}
