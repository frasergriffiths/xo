const std = @import("std");
const agent_runtime = @import("../agent/agent_runtime.zig");
const agent_stream_provider = @import("../agent/stream_provider.zig");
const runtime_context_compaction = @import("../agent/runtime/context_compaction.zig");
const compaction_activity = @import("../output/compaction_activity.zig");
const runtime_prompt_context = @import("../agent/runtime/prompt_context.zig");
const command_admission = @import("../permissions/command_admission.zig");
const permission_auto_classifier = @import("../permissions/auto_classifier.zig");
const shared_theme = @import("../shared/theme.zig");
const code_highlight = @import("../agent/presentation/code_highlight.zig");
const code_highlight_languages = @import("../agent/presentation/code_highlight_languages.zig");
const app_callbacks = @import("app_callbacks.zig");
const runtime_profile = @import("../hosts/runtime_profile.zig");
const host = @import("../hosts/host.zig");
const app_permission_runtime = @import("app_permission_runtime.zig");
const app_session_runtime = @import("app_session_runtime.zig");
const provider_runtime = @import("provider_runtime.zig");
const app_worker_runtime = @import("app_worker_runtime.zig");
const auth_runtime = @import("../auth/auth_runtime.zig");
const credentials = @import("../auth/credentials.zig");
const change_tracker = @import("../workspace/change_tracker.zig");
const file_mutation_contract = @import("../tooling/file_mutation_contract.zig");
const hooks = @import("../hooks/hooks.zig");
const io_mod = @import("../shared/io.zig");

const permission_gate = @import("../permissions/permission_gate.zig");
const permissions = @import("../permissions/permissions.zig");
const prompt_policy_contract = @import("../config/prompt_policy.zig");
const model_provider = @import("../config/model_provider.zig");
const session_runtime = @import("../session/session.zig");
const session_child_store = @import("../session/session_child_store.zig");
const skill_runtime = @import("../skills/skill_runtime.zig");
const subagent_agent_adapter = @import("../subagent/agent_adapter.zig");
const subagent_domain = @import("../subagent/domain.zig");
const subagent_execution = @import("../subagent/execution.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const text_utils = @import("../shared/text_utils.zig");
const tool_args = @import("../tooling/tool_args.zig");
const tool_admission = @import("../tooling/tool_admission.zig");
const tool_projection_mod = @import("../tooling/tool_projection.zig");
const model_tool_schema = @import("../tooling/model_tool_schema.zig");
const tool_dispatch = @import("../tooling/tool_dispatch.zig");

const context_contract = @import("../workspace/context_contract.zig");
const model_catalog = @import("../gateway/model_catalog.zig");
const provider_set = @import("../gateway/provider_set.zig");
const test_openrouter = if (@import("builtin").is_test)
    @import("../../gateway/openrouter_test_fixtures.zig")
else
    struct {};
const test_builtin_tools = if (@import("builtin").is_test)
    @import("../../builtins/tools.zig")
else
    struct {};
const tool_presentation = @import("../tooling/tool_presentation.zig");
const tool_runtime = @import("../tooling/tool_runtime.zig");
const skill_invocation = @import("../skills/skill_invocation.zig");
const web_fetch_runtime = @import("../tooling/web_fetch_runtime.zig");
const web_search_runtime = @import("../tooling/web_search_runtime.zig");
const types = @import("../shared/types.zig");
const worker_runtime = @import("../agent/worker_runtime.zig");
const workspace_access = @import("../workspace/workspace_access.zig");

const Allocator = std.mem.Allocator;
const ChatMessage = types.ChatMessage;
const PermissionGrant = types.PermissionGrant;
const PermissionMode = types.PermissionMode;
const ToolCall = types.ToolCall;
const ToolPermissionDecision = types.ToolPermissionDecision;

pub fn Runtime(comptime App: type) type {
    return struct {
        const ToolAuthorityView = struct {
            mode: PermissionMode,
            grants: []const PermissionGrant,
            rules: types.PermissionRuleSet,
        };

        fn appAccessScope(app: *const App) ?workspace_access.AccessScope {
            if (comptime @hasDecl(App, "workspaceAccessScope")) {
                return app.workspaceAccessScope();
            }
            return null;
        }

        fn modelVisibleProjectContext(app: *App) []const u8 {
            if (comptime @hasField(App, "context_enabled")) {
                if (!app.context_enabled) return "";
            }
            if (app.worker.active_context_snapshot) |snapshot| return snapshot.modelVisibleBytes();
            return app.context_snapshot.modelVisibleBytes();
        }

        fn childToolContext(root_context: tool_runtime.Context) tool_runtime.Context {
            var child_context = root_context;
            child_context.tracker = null;
            return child_context;
        }

        pub fn toolContext(
            app: *App,
            ignored_list_entries: []const []const u8,
            max_list_entries: usize,
            max_read_file_bytes: usize,
            max_read_file_lines: usize,
            max_read_file_line_len: usize,
            max_command_output_bytes: usize,
            gateway_retry_count: usize,
            gateway_chat_url: []const u8,
        ) tool_runtime.Context {
            return toolContextWithAuthority(
                app,
                ignored_list_entries,
                max_list_entries,
                max_read_file_bytes,
                max_read_file_lines,
                max_read_file_line_len,
                max_command_output_bytes,
                gateway_retry_count,
                gateway_chat_url,
                null,
            );
        }

        pub fn toolContextForSubagent(
            app: *App,
            ignored_list_entries: []const []const u8,
            max_list_entries: usize,
            max_read_file_bytes: usize,
            max_read_file_lines: usize,
            max_read_file_line_len: usize,
            max_command_output_bytes: usize,
            gateway_retry_count: usize,
            gateway_chat_url: []const u8,
            admission: subagent_domain.AdmissionSnapshot,
        ) tool_runtime.Context {
            return toolContextWithAuthority(
                app,
                ignored_list_entries,
                max_list_entries,
                max_read_file_bytes,
                max_read_file_lines,
                max_read_file_line_len,
                max_command_output_bytes,
                gateway_retry_count,
                gateway_chat_url,
                .{
                    .mode = admission.permission_mode,
                    .grants = admission.grants,
                    .rules = admission.rules,
                },
            );
        }

        fn toolContextWithAuthority(
            app: *App,
            ignored_list_entries: []const []const u8,
            max_list_entries: usize,
            max_read_file_bytes: usize,
            max_read_file_lines: usize,
            max_read_file_line_len: usize,
            max_command_output_bytes: usize,
            gateway_retry_count: usize,
            gateway_chat_url: []const u8,
            authority: ?ToolAuthorityView,
        ) tool_runtime.Context {
            const workspace_root = app.workspace_root;
            const agent_settings = app.worker.effectiveAgentTurnSettings();
            const permission_snapshot = if (authority) |snapshot|
                worker_runtime.PermissionSnapshot{
                    .mode = snapshot.mode,
                }
            else
                app_permission_runtime.Runtime(App).livePermissionSnapshot(app);
            const permission_grants = if (authority) |snapshot|
                snapshot.grants
            else
                app.permission_engine.grants.items;
            const permission_rules = if (authority) |snapshot|
                snapshot.rules
            else
                app.permission_engine.rules;
            const child_capability =
                if (comptime @hasField(App, "session_persistence"))
                    app_session_runtime.Runtime(App).childCapability(app)
                else
                    null;
            const selected_provider = provider_runtime.provider(app);
            const provider_capabilities = if (comptime @hasDecl(App, "providerSet"))
                app.providerSet().select(selected_provider).capabilities
            else if (selected_provider == .openrouter)
                provider_set.Bundle.Capabilities{ .fx_search = true, .vision_fallback = true }
            else
                provider_set.Bundle.Capabilities{};
            var ctx: tool_runtime.Context = .{
                .workspace_root = workspace_root,
                .access_scope = appAccessScope(app),
                .ignored_list_entries = ignored_list_entries,
                .max_list_entries = max_list_entries,
                .max_read_file_bytes = max_read_file_bytes,
                .max_read_file_lines = max_read_file_lines,
                .max_read_file_line_len = max_read_file_line_len,
                .max_command_output_bytes = max_command_output_bytes,
                .max_tool_result_bytes = agent_settings.max_tool_result_bytes,
                .api_key = app.auth.apiKey() orelse "",
                .agent_stream_provider = if (comptime @hasDecl(App, "agentStreamProvider"))
                    app.agentStreamProvider()
                else
                    agent_stream_provider.unavailable_provider,
                .credential_source = app.auth.credentialSource(),
                .account_id = app.auth.accountId(),
                .provider = selected_provider,
                .provider_capabilities = provider_capabilities,
                .secret_store = if (comptime @hasDecl(@TypeOf(app.auth), "secretStore"))
                    app.auth.secretStore()
                else
                    host.unavailable_secret_store,
                .model = provider_runtime.model(app),
                .reviewer_model = if (comptime @hasField(App, "review_model")) app.review_model else "",
                .gateway_retry_count = gateway_retry_count,
                .gateway_chat_url = gateway_chat_url,
                .gateway_models_path = if (comptime @hasField(App, "web_search_models_path")) app.web_search_models_path else "/v1/models",
                .agent_step_limit = app.agent_step_limit,
                .fast_mode = agent_settings.fast_mode,
                .effort = agent_settings.effort,
                .provider_order = if (selected_provider == .openrouter) agent_settings.provider_order else &.{},
                .provider_strict = selected_provider == .openrouter and agent_settings.provider_strict,
                .first_call_tool_choice = agent_settings.first_call_tool_choice,
                .tool_registry = if (comptime @hasDecl(App, "toolRegistry")) app.toolRegistry() else .{},
                .subagent_host = if (comptime @hasField(App, "session_persistence"))
                    app_session_runtime.Runtime(App).subagentHost(app)
                else
                    null,
                .subagent_caller_id = if (comptime @hasField(App, "session_persistence"))
                    app_session_runtime.Runtime(App).activeSessionId(app)
                else
                    null,
                .permission_mode = permission_snapshot.mode,
                .permission_grants = permission_grants,
                .permission_rules = permission_rules,
                .worker = &app.worker,
                .permission_prompter = tool_admission.workerPrompter(&app.worker),
                .cancel_flag = &app.worker.worker_cancel_requested,
                .session_child_capability = child_capability,
                .terminal_client = if (comptime @hasField(App, "terminal_client"))
                    &app.terminal_client
                else
                    null,
                .managed_executions = if (comptime @hasField(App, "managed_executions"))
                    &app.managed_executions
                else
                    null,
                .ephemeral_command_replay = if (comptime @hasField(App, "managed_executions"))
                    app.managed_executions.replayStore()
                else
                    null,
                .session = &app.session,
                .session_allocator = app.alloc,
                .skills_dir = app.skills.dir,
                .context_limits = if (comptime @hasField(App, "context_limits")) app.context_limits else .{},
                .context_enabled = if (comptime @hasField(App, "context_enabled")) app.context_enabled else true,
                .context_registry = app.contextRegistry(),
                .output_chunk_ctx = @ptrCast(app),
                .on_output_chunk = app_callbacks.Bindings(App).onCommandOutputChunk,
                .host_sandbox_default = .none,
                .permission_reviewer_provider = if (comptime @hasDecl(App, "permissionReviewerProvider")) app.permissionReviewerProvider() else null,
                .tracker = &app.change_tracker,

                .tool_progress_ctx = @ptrCast(app),
                .on_tool_progress = app_callbacks.Bindings(App).onToolProgress,
                .subagent_status_renderer = app_callbacks.Bindings(App).subagentStatusRenderer(app),
                .lifecycle_view = app.lifecycle_view,
                .lifecycle_scope = lifecycleContext(app).scope,
            };
            if (comptime @hasField(App, "web_fetch_runtime")) {
                ctx.web_fetch_runtime = &app.web_fetch_runtime;
                ctx.web_fetch_artifact_store = app.session.webFetchArtifactStore();
                ctx.web_fetch_artifact_error = app.session.webFetchArtifactError();
                ctx.web_fetch_progress_ctx = @ptrCast(app);
                ctx.on_web_fetch_progress = app_callbacks.Bindings(App).onWebFetchProgress;
            }
            if (comptime @hasField(App, "web_search_runtime")) {
                if (provider_capabilities.fx_search) {
                    app.web_search_runtime.configure(.{
                        .api_key = app.auth.apiKey() orelse "",
                        .credential_source = app.auth.credentialSource(),
                        .worker_model = provider_runtime.model(app),
                        .gateway_retry_count = gateway_retry_count,
                        .gateway_chat_url = gateway_chat_url,
                        .usage = &app.session.usage,
                        .usage_allocator = app.alloc,
                    });
                    ctx.web_search_backend = app.web_search_runtime.dispatchBackend();
                }
                ctx.web_search_runtime_ready = false;
                ctx.web_search_progress_ctx = @ptrCast(app);
                ctx.on_web_search_progress = app_callbacks.Bindings(App).onWebSearchProgress;
            }

            ctx.model_capability_resolver = app_callbacks.Bindings(App).modelCapabilityResolver(app);
            ctx.model_override_resolver = app_callbacks.Bindings(App).modelOverrideResolver(app);
            return ctx;
        }

        const DeadlineWatch = struct {
            app: *App,
            deadline_ms: i64,
            lifecycle_cancel_flag: ?*const std.atomic.Value(bool),
            done: std.atomic.Value(bool) = .init(false),
            timed_out: std.atomic.Value(bool) = .init(false),

            fn run(self: *DeadlineWatch) void {
                while (!self.done.load(.acquire)) {
                    const cancelled = self.app.worker.worker_cancel_requested.load(.acquire);
                    const lifecycle_cancelled = if (self.lifecycle_cancel_flag) |flag|
                        flag.load(.acquire)
                    else
                        false;
                    const timed_out = currentAwakeMillis() >= self.deadline_ms;
                    if (cancelled or lifecycle_cancelled or timed_out) {
                        if (timed_out and !cancelled and !lifecycle_cancelled) {
                            self.timed_out.store(true, .release);
                        }
                        if (self.app.worker.cancelPendingQuestionBatch()) return;
                    }
                    io_mod.sleep(20 * std.time.ns_per_ms);
                }
            }
        };

        fn currentAwakeMillis() i64 {
            const now = std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake);
            const milliseconds = @divFloor(now.raw.nanoseconds, std.time.ns_per_ms);
            return std.math.cast(i64, milliseconds) orelse if (milliseconds < 0)
                std.math.minInt(i64)
            else
                std.math.maxInt(i64);
        }

        pub fn resolveToolActionDisplayTarget(
            app: *App,
            arena: Allocator,
            call: ToolCall,
            ignored_list_entries: []const []const u8,
            max_list_entries: usize,
            max_read_file_bytes: usize,
            max_read_file_lines: usize,
            max_read_file_line_len: usize,
            max_command_output_bytes: usize,
            gateway_retry_count: usize,
            gateway_chat_url: []const u8,
        ) !?[]const u8 {
            const ctx = toolContext(app, ignored_list_entries, max_list_entries, max_read_file_bytes, max_read_file_lines, max_read_file_line_len, max_command_output_bytes, gateway_retry_count, gateway_chat_url);
            return tool_presentation.resolveTerminalDisplayTarget(
                arena,
                ctx.tool_registry,
                ctx.workspace_root,
                ctx.terminal_client,
                ctx.managed_executions,
                call,
            );
        }

        pub fn releaseAgentTerminalLease(
            app: *App,
            session_id: []const u8,
            ignored_list_entries: []const []const u8,
            max_list_entries: usize,
            max_read_file_bytes: usize,
            max_read_file_lines: usize,
            max_read_file_line_len: usize,
            max_command_output_bytes: usize,
            gateway_retry_count: usize,
            gateway_chat_url: []const u8,
        ) !void {
            return tool_runtime.release_agent_terminal_lease(
                toolContext(
                    app,
                    ignored_list_entries,
                    max_list_entries,
                    max_read_file_bytes,
                    max_read_file_lines,
                    max_read_file_line_len,
                    max_command_output_bytes,
                    gateway_retry_count,
                    gateway_chat_url,
                ),
                session_id,
            );
        }

        pub fn describeToolAction(
            app: *App,
            arena: Allocator,
            call: ToolCall,
            display_target: ?[]const u8,
            advertised_dynamic_tool_names: []const []const u8,
            ignored_list_entries: []const []const u8,
            max_list_entries: usize,
            max_read_file_bytes: usize,
            max_read_file_lines: usize,
            max_read_file_line_len: usize,
            max_command_output_bytes: usize,
            gateway_retry_count: usize,
            gateway_chat_url: []const u8,
        ) ![]const u8 {
            const ctx = tool_runtime.withAdvertisedDynamicToolNames(toolContext(app, ignored_list_entries, max_list_entries, max_read_file_bytes, max_read_file_lines, max_read_file_line_len, max_command_output_bytes, gateway_retry_count, gateway_chat_url), advertised_dynamic_tool_names);
            return formatToolAction(ctx, arena, call, display_target, .active, null);
        }

        pub fn describeToolActionCompleted(
            app: *App,
            arena: Allocator,
            call: ToolCall,
            display_target: ?[]const u8,
            advertised_dynamic_tool_names: []const []const u8,
            ignored_list_entries: []const []const u8,
            max_list_entries: usize,
            max_read_file_bytes: usize,
            max_read_file_lines: usize,
            max_read_file_line_len: usize,
            max_command_output_bytes: usize,
            gateway_retry_count: usize,
            gateway_chat_url: []const u8,
        ) ![]const u8 {
            const ctx = tool_runtime.withAdvertisedDynamicToolNames(toolContext(app, ignored_list_entries, max_list_entries, max_read_file_bytes, max_read_file_lines, max_read_file_line_len, max_command_output_bytes, gateway_retry_count, gateway_chat_url), advertised_dynamic_tool_names);
            return formatToolAction(ctx, arena, call, display_target, .completed, null);
        }

        pub fn describeToolActionDenied(
            app: *App,
            arena: Allocator,
            call: ToolCall,
            display_target: ?[]const u8,
            label: []const u8,
            advertised_dynamic_tool_names: []const []const u8,
            ignored_list_entries: []const []const u8,
            max_list_entries: usize,
            max_read_file_bytes: usize,
            max_read_file_lines: usize,
            max_read_file_line_len: usize,
            max_command_output_bytes: usize,
            gateway_retry_count: usize,
            gateway_chat_url: []const u8,
        ) ![]const u8 {
            const ctx = tool_runtime.withAdvertisedDynamicToolNames(toolContext(app, ignored_list_entries, max_list_entries, max_read_file_bytes, max_read_file_lines, max_read_file_line_len, max_command_output_bytes, gateway_retry_count, gateway_chat_url), advertised_dynamic_tool_names);
            return formatToolAction(ctx, arena, call, display_target, .denied, label);
        }

        pub fn requestToolPermissionSync(
            app: *App,
            arena: Allocator,
            call: ToolCall,
            review_turn: permission_auto_classifier.ReviewTurnContext,
            permission_mode: PermissionMode,
            local_grants: []const PermissionGrant,
            live_authority: ?agent_runtime.LiveToolAuthority,
            revalidation: ?agent_runtime.LivePermissionRevalidation,
            advertised_dynamic_tool_names: []const []const u8,
            ignored_list_entries: []const []const u8,
            max_list_entries: usize,
            max_read_file_bytes: usize,
            max_read_file_lines: usize,
            max_read_file_line_len: usize,
            max_command_output_bytes: usize,
            gateway_retry_count: usize,
            gateway_chat_url: []const u8,
        ) !command_admission.PermissionOutcome {
            var ctx = tool_runtime.withAdvertisedDynamicToolNames(toolContext(app, ignored_list_entries, max_list_entries, max_read_file_bytes, max_read_file_lines, max_read_file_line_len, max_command_output_bytes, gateway_retry_count, gateway_chat_url), advertised_dynamic_tool_names);
            applyCredentialLease(app, &ctx, review_turn.credential, gateway_retry_count, gateway_chat_url);
            ctx.permission_review_turn = review_turn;
            const admission = ctx.admissionInputWithLiveAuthority(live_authority);
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

        pub fn requestPreparedFileMutationPermissionSync(
            app: *App,
            arena: Allocator,
            call: ToolCall,
            prepared: *tool_admission.PreparedFileMutationCall,
            review_turn: permission_auto_classifier.ReviewTurnContext,
            permission_mode: PermissionMode,
            local_grants: []const PermissionGrant,
            live_authority: ?agent_runtime.LiveToolAuthority,
            advertised_dynamic_tool_names: []const []const u8,
            ignored_list_entries: []const []const u8,
            max_list_entries: usize,
            max_read_file_bytes: usize,
            max_read_file_lines: usize,
            max_read_file_line_len: usize,
            max_command_output_bytes: usize,
            gateway_retry_count: usize,
            gateway_chat_url: []const u8,
        ) !command_admission.PermissionOutcome {
            var ctx = tool_runtime.withAdvertisedDynamicToolNames(
                toolContext(
                    app,
                    ignored_list_entries,
                    max_list_entries,
                    max_read_file_bytes,
                    max_read_file_lines,
                    max_read_file_line_len,
                    max_command_output_bytes,
                    gateway_retry_count,
                    gateway_chat_url,
                ),
                advertised_dynamic_tool_names,
            );
            applyCredentialLease(app, &ctx, review_turn.credential, gateway_retry_count, gateway_chat_url);
            ctx.permission_review_turn = review_turn;
            const admission = ctx.admissionInputWithLiveAuthority(live_authority);
            return tool_admission.requestPreparedFileMutationPermissionOutcome(
                admission,
                arena,
                call,
                prepared,
                permission_mode,
                local_grants,
            );
        }

        pub fn validateToolCall(
            app: *App,
            arena: Allocator,
            call: ToolCall,
            ignored_list_entries: []const []const u8,
            max_list_entries: usize,
            max_read_file_bytes: usize,
            max_read_file_lines: usize,
            max_read_file_line_len: usize,
            max_command_output_bytes: usize,
            gateway_retry_count: usize,
            gateway_chat_url: []const u8,
        ) !agent_runtime.ToolCallValidationResult {
            return tool_runtime.validateToolCall(toolContext(app, ignored_list_entries, max_list_entries, max_read_file_bytes, max_read_file_lines, max_read_file_line_len, max_command_output_bytes, gateway_retry_count, gateway_chat_url), arena, call);
        }

        pub fn checkToolAvailability(
            app: *App,
            arena: Allocator,
            call: ToolCall,
            ignored_list_entries: []const []const u8,
            max_list_entries: usize,
            max_read_file_bytes: usize,
            max_read_file_lines: usize,
            max_read_file_line_len: usize,
            max_command_output_bytes: usize,
            gateway_retry_count: usize,
            gateway_chat_url: []const u8,
        ) !?[]const u8 {
            return tool_runtime.checkToolAvailability(toolContext(app, ignored_list_entries, max_list_entries, max_read_file_bytes, max_read_file_lines, max_read_file_line_len, max_command_output_bytes, gateway_retry_count, gateway_chat_url), arena, call);
        }

        pub fn permissionTargetForCall(
            app: *App,
            arena: Allocator,
            call: ToolCall,
            advertised_dynamic_tool_names: []const []const u8,
            ignored_list_entries: []const []const u8,
            max_list_entries: usize,
            max_read_file_bytes: usize,
            max_read_file_lines: usize,
            max_read_file_line_len: usize,
            max_command_output_bytes: usize,
            gateway_retry_count: usize,
            gateway_chat_url: []const u8,
        ) ![]const u8 {
            const ctx = tool_runtime.withAdvertisedDynamicToolNames(toolContext(app, ignored_list_entries, max_list_entries, max_read_file_bytes, max_read_file_lines, max_read_file_line_len, max_command_output_bytes, gateway_retry_count, gateway_chat_url), advertised_dynamic_tool_names);
            return tool_admission.permissionTargetForCall(ctx.admissionInput(), arena, call);
        }

        pub fn executeToolCall(
            app: *App,
            request: agent_runtime.ToolExecutionRequest,
            ignored_list_entries: []const []const u8,
            max_list_entries: usize,
            max_read_file_bytes: usize,
            max_read_file_lines: usize,
            max_read_file_line_len: usize,
            max_command_output_bytes: usize,
            gateway_retry_count: usize,
            gateway_chat_url: []const u8,
        ) !agent_runtime.ToolExecutionResult {
            var ctx = toolContext(app, ignored_list_entries, max_list_entries, max_read_file_bytes, max_read_file_lines, max_read_file_line_len, max_command_output_bytes, gateway_retry_count, gateway_chat_url);
            applyCredentialLease(app, &ctx, request.credential, gateway_retry_count, gateway_chat_url);
            ctx.root_user_intent_context = request.root_user_intent_context;
            ctx.root_user_messages = request.root_user_messages;
            ctx.root_user_evidence_complete = request.root_user_evidence_complete;
            ctx.session_grants = request.session_grants;
            ctx.advertised_dynamic_tool_names = request.advertised_dynamic_tool_names;
            ctx.max_tool_result_bytes = request.max_tool_result_bytes;
            return tool_runtime.executeToolCallAuthorized(ctx, request);
        }

        fn applyCredentialLease(
            app: *App,
            ctx: *tool_runtime.Context,
            credential: types.CredentialLease,
            gateway_retry_count: usize,
            gateway_chat_url: []const u8,
        ) void {
            const credential_secret = credential.secret() orelse return;
            const credential_source = credential.credentialSource();
            ctx.api_key = credential_secret;
            ctx.credential_source = credential_source;
            ctx.account_id = credential.accountId();
            ctx.gateway_team = credential.tenant();
            if (comptime @hasField(App, "web_search_runtime") and @hasField(App, "session")) {
                if (ctx.provider_capabilities.fx_search) {
                    app.web_search_runtime.configure(.{
                        .api_key = credential_secret,
                        .credential_source = credential_source,
                        .worker_model = provider_runtime.model(app),
                        .gateway_retry_count = gateway_retry_count,
                        .gateway_chat_url = gateway_chat_url,
                        .usage = &app.session.usage,
                        .usage_allocator = app.alloc,
                    });
                    ctx.web_search_backend = app.web_search_runtime.dispatchBackend();
                }
            }
        }

        pub fn appendStaticContextMessage(
            app: *App,
            arena: Allocator,
            project_context: ?[]const u8,
            messages: *std.ArrayList(ChatMessage),
            ignored_list_entries: []const []const u8,
            max_list_entries: usize,
            max_read_file_bytes: usize,
            max_read_file_lines: usize,
            max_read_file_line_len: usize,
            max_command_output_bytes: usize,
            gateway_retry_count: usize,
            gateway_chat_url: []const u8,
        ) !void {
            _ = ignored_list_entries;
            _ = max_list_entries;
            _ = max_read_file_bytes;
            _ = max_read_file_lines;
            _ = max_read_file_line_len;
            _ = max_command_output_bytes;
            _ = gateway_retry_count;
            _ = gateway_chat_url;
            try app.contextRegistry().appendDefaultStatic(.{
                .project_context = project_context orelse modelVisibleProjectContext(app),
            }, arena, messages);
        }

        pub fn appendTransientRuntimeContextMessage(
            app: *App,
            arena: Allocator,
            messages: *std.ArrayList(ChatMessage),
            ignored_list_entries: []const []const u8,
            max_list_entries: usize,
            max_read_file_bytes: usize,
            max_read_file_lines: usize,
            max_read_file_line_len: usize,
            max_command_output_bytes: usize,
            gateway_retry_count: usize,
            gateway_chat_url: []const u8,
        ) !void {
            _ = ignored_list_entries;
            _ = max_list_entries;
            _ = max_read_file_bytes;
            _ = max_read_file_lines;
            _ = max_read_file_line_len;
            _ = max_command_output_bytes;
            _ = gateway_retry_count;
            _ = gateway_chat_url;
            const permission_snapshot = app_permission_runtime.Runtime(App).livePermissionSnapshot(app);
            const workspace_root = app.workspace_root;
            try app.contextRegistry().appendDefaultTransient(.{
                .workspace_root = workspace_root,
                .host_workspace = null,
                .access_scope = appAccessScope(app),
                .interactive = true,
                .permission_mode = permission_snapshot.mode,
                .stale_shell_handles = app.session.has_stale_shell_handles,
            }, arena, messages);
        }

        pub fn refreshProjectContext(app: *App, targets: []const context_contract.ApplicableTarget) context_contract.ProviderError!void {
            app.context_snapshot.deinit(app.alloc);
            if (!app.context_enabled) return;

            app.context_snapshot = app.contextRegistry().gatherDefaultSnapshot(app.alloc, .{
                .workspace_root = app.workspace_root,
                .access_scope = appAccessScope(app),
                .targets = targets,
                .context_limits = if (comptime @hasField(App, "context_limits")) app.context_limits else .{},
            }) catch |err| {
                debug_trace.logf("context", "gather failed err={s}", .{@errorName(err)});
                return err;
            };
            if (comptime @hasDecl(App, "writeDomainNotice")) {
                for (app.context_snapshot.notices) |notice| {
                    const should_emit = if (comptime @hasDecl(@TypeOf(app.session), "claimContextNotice"))
                        try app.session.claimContextNotice(app.alloc, notice)
                    else
                        true;
                    if (should_emit) {
                        const body = try types.renderContextNoticeBody(app.alloc, notice);
                        defer app.alloc.free(body);
                        app.writeDomainNotice(.{
                            .topic = "context",
                            .tone = .warning,
                            .body = body,
                            .visibility = .full_only,
                        }, true) catch return error.WriteFailed;
                    }
                }
            }
        }

        pub fn fetchModelIds(
            app: *App,
            provider: model_catalog.Provider,
            catalog_endpoint: []const u8,
        ) !std.ArrayList([]u8) {
            const result = model_catalog.fetchWithPublicFallback(provider, app.alloc, .{
                .access = app.auth.modelCatalogAccess(),
                .endpoint = catalog_endpoint,
            });
            var catalog = switch (result) {
                .loaded => |loaded| loaded.catalog,
                .failed => |failed| return failed.failure.asError(),
            };
            defer model_catalog.freeModelCatalog(app.alloc, &catalog);
            return model_catalog.projectModelIds(app.alloc, catalog.items);
        }

        pub fn processQueuedPrompt(
            app: *App,
            queued_job: worker_runtime.QueuedPrompt,
            gateway_retry_count: usize,
            gateway_chat_url: []const u8,
            failure_provenance: ?*?compaction_activity.ErrorProvenance,
        ) !void {
            if (failure_provenance) |out| out.* = null;
            var job = queued_job;
            var fresh_history: ?worker_runtime.FreshPromptHistory = null;
            defer if (fresh_history) |*snapshot| snapshot.deinit(std.heap.c_allocator);
            var snapshot_ownership = worker_runtime.ActivePromptSnapshotOwnership.init(job.images);
            app.worker.beginActivePromptSnapshots(&snapshot_ownership);
            if (job.recovery_checkpoint != null) {
                app.worker.preservePromptSnapshots(job.turn_id, job.images);
            }
            defer app.worker.endActivePromptSnapshots(&snapshot_ownership);
            {
                app.session_persistence.write_mutex.lockUncancelable(io_mod.getIo());
                defer app.session_persistence.write_mutex.unlock(io_mod.getIo());
                if (app.session_persistence.writable) |*loaded| try loaded.requireWritable();
            }
            if (job.recovery_checkpoint == null) {
                if (try app_session_runtime.Runtime(App).snapshotFreshPromptBoundary(app, std.heap.c_allocator)) |value| {
                    var checkpoint = value;
                    defer checkpoint.deinit(std.heap.c_allocator);
                    fresh_history = try app_callbacks.Bindings(App).prepareFreshPrompt(app, .{
                        .user = .{ .text = job.prompt, .images = job.images },
                        .prior_turn = checkpoint.interruptedTurn(),
                    });
                    job.history = fresh_history.?.history;
                    job.authorized_image_catalog = fresh_history.?.authorized_image_catalog;
                    job.root_user_intent_context = fresh_history.?.root_user_intent_context;
                    job.unversioned_history_count = fresh_history.?.unversioned_history_count;
                }
            }
            app.worker.active_context_snapshot = &job.context_snapshot;
            defer app.worker.active_context_snapshot = null;
            defer if (comptime !@import("builtin").single_threaded) {
                if (app.session_persistence.subagent_host) |child_host| child_host.cancelYielded();
            };
            app.worker.active_prompt_is_root_authority = if (app.session_persistence.writable) |writable|
                writable.external_prompt_origin == .persistent_child and
                    job.recovery_checkpoint == null
            else
                false;
            defer app.worker.active_prompt_is_root_authority = false;
            app.worker.setActiveAgentTurnSettings(job.agent_settings);
            defer app.worker.clearActiveAgentTurnSettings();
            var preflight_context_notices: std.Io.Writer.Allocating = .init(std.heap.c_allocator);
            defer preflight_context_notices.deinit();
            for (job.context_snapshot.notices) |notice| {
                try appendClaimedContextNotice(app, &preflight_context_notices.writer, notice);
            }

            var skill_catalog = app.skills.acquireCatalog();
            defer skill_catalog.deinit();
            const explicit_bindings = try std.heap.c_allocator.alloc(skill_invocation.ExplicitBinding, job.skill_bindings.len);
            defer std.heap.c_allocator.free(explicit_bindings);
            for (job.skill_bindings, 0..) |binding, index| {
                explicit_bindings[index] = .{ .name = binding.name, .path = binding.path };
            }
            if (preflight_context_notices.written().len > 0) {
                try app_worker_runtime.Runtime(App).pushSemanticNotice(app, .{
                    .topic = "context",
                    .tone = .warning,
                    .body = preflight_context_notices.written(),
                    .visibility = .full_only,
                });
            }

            var tool_projection = try app.snapshotModelToolProjection(
                std.heap.c_allocator,
                job.permission_mode,
            );
            defer tool_projection.deinit(std.heap.c_allocator);
            const session_child_capability =
                if (comptime @hasField(App, "session_persistence"))
                    app_session_runtime.Runtime(App).childCapability(app)
                else
                    null;

            var deps = app_callbacks.Bindings(App).agentRuntimeDeps(app);
            if (comptime @hasDecl(App, "providerSet")) deps.agent_stream_provider = app.providerSet().select(job.provider).agent_stream_or_unavailable();
            deps.compaction_failure = failure_provenance;
            const semantic_presentation = app_callbacks.Bindings(App).semanticPresentationSink(app);
            const config = buildQueuedPromptConfig(
                app,
                job,
                .{ .skills = skill_catalog.items, .diagnostics = skill_catalog.diagnostics },
                explicit_bindings,
                gateway_retry_count,
                gateway_chat_url,
                &tool_projection,
                session_child_capability,
            );
            const process_result = agent_runtime.processAgentPrompt(&app.session.agent, &deps, semantic_presentation, lifecycleContext(app), config, job);
            try process_result;
        }

        pub fn processContextCompaction(
            app: *App,
            job: worker_runtime.ContextCompactionTask,
            gateway_retry_count: usize,
            failure_provenance: ?*?compaction_activity.ErrorProvenance,
        ) anyerror!void {
            if (failure_provenance) |out| out.* = null;
            const operation_id = job.operation_id orelse app.worker.beginCompactionActivity(.manual, job.turn_id);
            app.worker.runCompactionActivity(operation_id, .preparation);
            // Covers early cancellation before the transaction; acknowledged settlement wins.
            defer if (app.worker.isCancelRequested()) {
                app.worker.settleCompactionActivity(operation_id, .{ .outcome = .cancelled });
            };
            errdefer |err| {
                app.worker.settleCompactionActivity(operation_id, compaction_activity.failure(err, .preparation, app.worker.isCancelRequested()));
                if (failure_provenance) |out| out.* = .{ .operation_id = operation_id, .turn_id = job.turn_id, .err = err };
            }
            var arena_state = std.heap.ArenaAllocator.init(std.heap.c_allocator);
            defer arena_state.deinit();
            const arena = arena_state.allocator();

            const result_storage: runtime_context_compaction.ResultStorage =
                if (app_session_runtime.Runtime(App).childCapability(app)) |capability|
                    .{ .managed = capability }
                else
                    .unavailable;
            var messages: std.ArrayList(ChatMessage) = .empty;
            defer messages.deinit(arena);
            const uncertain_history_count = @min(
                job.unversioned_history_count,
                job.history.len,
            );
            _ = try session_runtime.appendCompactionHistoryChatMessages(
                arena,
                &messages,
                job.history,
                uncertain_history_count,
            );
            const source_tokens = runtime_prompt_context.estimateCompactionSourceTokens(
                messages.items,
            );
            var deps = app_callbacks.Bindings(App).agentRuntimeDeps(app);
            if (comptime @hasDecl(App, "providerSet")) deps.agent_stream_provider = app.providerSet().select(job.provider).agent_stream_or_unavailable();
            const capabilities = deps.available_model_capabilities(deps.ctx, job.model);
            const permission_mode = app_permission_runtime.Runtime(App).livePermissionSnapshot(app).mode;
            var tool_projection = try app.snapshotModelToolProjection(arena, permission_mode);
            defer tool_projection.deinit(arena);
            var skill_catalog = app.skills.acquireCatalog();
            defer skill_catalog.deinit();
            const config = buildQueuedPromptConfig(app, .{
                .prompt = @constCast(""),
                .images = &.{},
                .model = job.model,
                .provider = job.provider,
                .api_key = job.api_key,
                .permission_mode = permission_mode,
                .history = &.{},
                .grants = &.{},
                .agent_settings = app.worker.effectiveAgentTurnSettings(),
            }, .{ .skills = skill_catalog.items, .diagnostics = skill_catalog.diagnostics }, &.{}, gateway_retry_count, "", &tool_projection, null);
            const base_continuation = try agent_runtime.prepareManualCompactionContinuation(
                arena,
                &deps,
                config,
                job.model,
                capabilities,
            );
            var retention_target = runtime_prompt_context.recentContextTarget(capabilities, source_tokens);
            while (true) {
                if (app.worker.worker_cancel_requested.load(.seq_cst)) return;
                var continuation = base_continuation;
                const window = try agent_runtime.prepareRetainedCompactionWindow(arena, job.history, null, capabilities, source_tokens, deps.agent_stream_provider, .{ .provider = job.provider, .model = job.model }, .{ .target = retention_target });
                const continuation_messages = try arena.alloc(ChatMessage, continuation.request.messages.len + window.retained_messages.len);
                @memcpy(continuation_messages[0..continuation.request.messages.len], continuation.request.messages);
                @memcpy(continuation_messages[continuation.request.messages.len..], window.retained_messages);
                continuation.request.messages = continuation_messages;
                const refine = window.refine_budget(arena, deps.agent_stream_provider, continuation, capabilities, source_tokens, &retention_target) catch |err| {
                    if (err == error.Cancelled and app.worker.worker_cancel_requested.load(.seq_cst)) return;
                    return @as(anyerror!void, err);
                };
                if (refine) continue;
                var compaction_count: usize = 0;
                for (job.history) |turn| switch (turn) {
                    .compacted_summary => |summary| {
                        compaction_count = @max(
                            compaction_count,
                            summary.compaction_count,
                        );
                    },
                    else => {},
                };
                const transaction = agent_runtime.compactContextTransaction(arena, &deps, .{
                    .trigger = .manual,
                    .operation_id = operation_id,
                    .activity_origin = .manual,
                    .provider = job.provider,
                    .working_capabilities = capabilities,
                    .request_tokens = source_tokens,
                    .source_tokens = runtime_prompt_context.estimateCompactionSourceTokens(window.source),
                    .continuation = continuation,
                    .retained_from = window.cut,
                    .newest_exchange_tokens = window.newest_exchange_tokens,
                    .source_messages = window.source,
                    .uncertain_source_message_count = if (uncertain_history_count > 0) window.source.len else 0,
                    .result_storage = result_storage,
                    .api_key = job.api_key,
                    .credential_source = job.credential_source,
                    .account_id = job.account_id,
                    .session_id = app_session_runtime.Runtime(App).activeSessionId(app),
                    .retry_count = gateway_retry_count,
                    .cancel_flag = &app.worker.worker_cancel_requested,
                    .trace_ctx = .{ .turn_id = job.turn_id },
                    .removed_turn_count = window.cut.turns,
                    .compaction_count = compaction_count + 1,
                }) catch |err| {
                    if (err == error.Cancelled and
                        app.worker.worker_cancel_requested.load(.seq_cst))
                    {
                        return;
                    }
                    return @as(anyerror!void, err);
                };
                _ = transaction;
                return;
            }
        }

        fn lifecycleContext(app: *App) agent_runtime.LifecycleContext {
            return .{
                .view = app.lifecycle_view,
                .scope = .{
                    .kind = .interactive,
                    .workspace_root = app.workspace_root,
                    .session_id = if (comptime @hasField(App, "session_persistence"))
                        app_session_runtime.Runtime(App).activeSessionId(app)
                    else
                        null,
                },
                .outcome_allocator = app.alloc,
            };
        }

        pub fn runSubagentChild(
            raw: ?*anyopaque,
            turn: *subagent_execution.TurnContext,
            message: subagent_domain.QueuedMessage,
            admission: subagent_domain.AdmissionSnapshot,
            cancel: *std.atomic.Value(bool),
        ) subagent_execution.ServiceError!subagent_execution.RunOutcome {
            const app: *App = @ptrCast(@alignCast(raw.?));
            const alloc = std.heap.c_allocator;
            var child_projection = app.snapshotSubagentModelToolProjection(
                alloc,
                admission.permission_mode,
                admission.rules,
            ) catch
                return error.OutOfMemory;
            defer child_projection.deinit(alloc);
            var skill_catalog = app.skills.acquireCatalog();
            defer skill_catalog.deinit();
            const prompt_policy = app.promptPolicy();
            var tool_context = childToolContext(app.subagentToolContextForAdmission(admission));
            tool_context.managed_executions = turn.managedExecutionRuntime();
            tool_context.ephemeral_command_replay = turn.managedExecutionRuntime().replayStore();
            const providers = if (comptime @hasDecl(App, "providerSet"))
                app.providerSet()
            else
                provider_set.Set{
                    .openrouter = .{
                        .capabilities = tool_context.provider_capabilities,
                        .agent_stream = tool_context.agent_stream_provider,
                    },
                };
            return subagent_agent_adapter.run(.{
                .host = app_session_runtime.Runtime(App).subagentHost(app) orelse
                    return error.ProviderFailed,
                .tool_context = tool_context,
                .provider_set = providers,
                .system_prompt = prompt_policy.system_prompt,
                .model_prompt_overlay = prompt_policy.modelPromptOverlay(admission.model),
                .skill_catalog = .{ .skills = skill_catalog.items, .diagnostics = skill_catalog.diagnostics },
                .advertised_tool_names = child_projection.advertised_names,
                .advertised_functions = child_projection.advertised_functions,
                .custom_tool_guidance = child_projection.custom_guidance,
                .context_registry = app.contextRegistry(),
                .context_enabled = if (comptime @hasField(App, "context_enabled")) app.context_enabled else true,
                .project_context = modelVisibleProjectContext(app),
                .lifecycle_view = app.lifecycle_view,
            }, turn, message, admission, cancel);
        }

        fn appendClaimedContextNotice(app: *App, writer: *std.Io.Writer, notice: []const u8) !void {
            const should_emit = if (comptime @hasDecl(@TypeOf(app.session), "claimContextNotice"))
                try app.session.claimContextNotice(std.heap.c_allocator, notice)
            else
                true;
            if (!should_emit) return;
            if (writer.buffered().len > 0 and !std.mem.endsWith(u8, writer.buffered(), "\n")) {
                try writer.writeByte('\n');
            }
            const body = try types.renderContextNoticeBody(std.heap.c_allocator, notice);
            defer std.heap.c_allocator.free(body);
            try writer.writeAll(body);
        }

        fn buildQueuedPromptConfig(
            app: *App,
            job: worker_runtime.QueuedPrompt,
            catalog: skill_invocation.Catalog,
            bindings: []const skill_invocation.ExplicitBinding,
            gateway_retry_count: usize,
            gateway_chat_url: []const u8,
            tool_projection: *const tool_projection_mod.EffectiveToolProjection,
            session_child_capability: ?*session_child_store.SessionChildCapability,
        ) agent_runtime.Config {
            const prompt_policy = app.promptPolicy();
            return .{
                .system_prompt = prompt_policy.system_prompt,
                .model_prompt_overlay = prompt_policy.modelPromptOverlay(job.model),
                .skill_catalog = catalog,
                .skill_bindings = bindings,
                .gateway_retry_count = gateway_retry_count,
                .recovery_pause_flag = if (comptime @hasField(@TypeOf(app.worker), "worker_recovery_pause_requested"))
                    &app.worker.worker_recovery_pause_requested
                else
                    null,
                .gateway_chat_url = gateway_chat_url,
                .advertised_tool_names = tool_projection.advertised_names,
                .advertised_functions = tool_projection.advertised_functions,
                .provider_capabilities = if (comptime @hasDecl(App, "providerSet"))
                    app.providerSet().select(job.provider).capabilities
                else if (job.provider == .openrouter)
                    .{ .fx_search = true, .vision_fallback = true }
                else
                    .{},
                .custom_tool_guidance = tool_projection.custom_guidance,
                .agent_step_limit = app.agent_step_limit,
                .max_tool_result_bytes = job.agent_settings.max_tool_result_bytes,
                .cancel_flag = &app.worker.worker_cancel_requested,
                .review_enabled = false,
                .fast_mode = job.agent_settings.fast_mode,
                .effort = job.agent_settings.effort,
                .provider_order = if (job.provider == .openrouter) job.agent_settings.provider_order else &.{},
                .provider_strict = job.provider == .openrouter and job.agent_settings.provider_strict,
                .first_call_tool_choice = job.agent_settings.first_call_tool_choice,
                .workspace_root = app.workspace_root,
                .access_scope = appAccessScope(app),
                .origin = if (app.session_persistence.writable) |writable|
                    if (writable.external_prompt_origin == .persistent_child) .subagent else .root
                else
                    .root,
                .root_user_messages = if (app.session_persistence.writable) |writable|
                    writable.external_root_user_messages
                else
                    &.{},
                .root_user_evidence_complete = if (app.session_persistence.writable) |writable|
                    writable.external_root_user_evidence_complete
                else
                    false,
                .current_prompt_is_root_authority = app.worker.active_prompt_is_root_authority,
                .session_child_capability = session_child_capability,
                .context_limits = if (comptime @hasField(App, "context_limits")) app.context_limits else .{},
            };
        }
    };
}

const ToolActionState = enum { active, completed, denied };

fn formatToolAction(
    ctx: tool_runtime.Context,
    arena: Allocator,
    call: ToolCall,
    display_target: ?[]const u8,
    state: ToolActionState,
    denied_label: ?[]const u8,
) ![]const u8 {
    if (std.mem.eql(u8, call.name, "web_search") or tool_presentation.isProviderSearchAlias(call.name)) {
        return formatWebSearchAction(arena, call, state, denied_label);
    }
    const spec = ctx.tool_registry.lookup(call.name) orelse {
        return formatMissingSpecToolAction(arena, state, denied_label, call.name);
    };
    if (try tool_presentation.formatRunCommandActivity(arena, ctx.tool_registry, ctx.workspace_root, call)) |activity| {
        defer arena.free(activity.detail);
        const label = if (activity.compatibility_tool) |compatibility_tool|
            specLabel(compatibility_tool, state, denied_label)
        else switch (state) {
            .active => "Running",
            .completed => "Ran",
            .denied => denied_label.?,
        };
        return formatCommandActionValue(
            arena,
            label,
            activity.detail,
        );
    }
    if (std.mem.eql(u8, call.name, "write_file") or
        std.mem.eql(u8, call.name, "edit_file"))
    {
        return formatToolActionValue(
            arena,
            specLabel(spec, state, denied_label),
            display_target orelse spec.label_arg_default,
        );
    }
    if (try tool_presentation.subagentAction(arena, call, switch (state) {
        .active => .active,
        .completed => .completed,
        .denied => .{ .stopped = denied_label.? },
    })) |action| {
        defer action.deinit(arena);
        return formatToolActionValue(arena, action.label, action.detail);
    }
    const args = tool_args.parseToolArgsObject(arena, call.arguments_json) catch {
        return formatInvalidArgsToolAction(arena, state, denied_label);
    };

    const presentation = tool_dispatch.presentationForArgs(spec.*, args);
    const value = display_target orelse
        tool_presentation.resolvedSkillName(call, presentation) orelse
        tool_dispatch.presentationLabelValue(presentation, args) orelse
        presentation.label_arg_default;
    return formatToolActionValue(arena, presentationLabel(presentation, state, denied_label), value);
}

fn formatWebSearchAction(arena: Allocator, call: ToolCall, state: ToolActionState, denied_label: ?[]const u8) ![]const u8 {
    const args = tool_args.parseToolArgsObject(arena, call.arguments_json) catch {
        return formatInvalidArgsToolAction(arena, state, denied_label);
    };
    const label = switch (state) {
        .active => "Searching",
        .completed => "Searched",
        .denied => denied_label.?,
    };
    return formatToolActionValue(arena, label, try tool_presentation.formatWebSearchActionDetail(arena, args));
}

fn formatMissingSpecToolAction(arena: Allocator, state: ToolActionState, denied_label: ?[]const u8, name: []const u8) ![]const u8 {
    return switch (state) {
        .active => formatToolActionValue(arena, "Working", name),
        .completed => formatToolActionValue(arena, "Completed", name),
        .denied => formatToolActionValue(arena, denied_label.?, name),
    };
}

fn formatInvalidArgsToolAction(arena: Allocator, state: ToolActionState, denied_label: ?[]const u8) ![]const u8 {
    return switch (state) {
        .active => std.fmt.allocPrint(arena, "● Working…\x1b[0m", .{}),
        .completed => formatToolActionValue(arena, "Completed", "tool call"),
        .denied => formatToolActionValue(arena, denied_label.?, "tool call"),
    };
}

fn formatToolActionValue(arena: Allocator, label: []const u8, value: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "● {s}\x1b[0m {s}{s}\x1b[0m", .{ label, shared_theme.current().tool_stdout_style, value });
}

/// Command rows keep the muted tool-text base and add shell syntax colors for
/// quoted strings, numbers, comments, and keywords.
fn formatCommandActionValue(arena: Allocator, label: []const u8, command: []const u8) ![]const u8 {
    const theme = shared_theme.current();
    const profile = code_highlight_languages.resolve("sh") orelse
        return formatToolActionValue(arena, label, command);
    const highlighted = try code_highlight.highlight(
        arena,
        command,
        profile,
        if (theme.light) .light else .dark,
        theme.tool_stdout_style,
    );
    return std.fmt.allocPrint(arena, "● {s}\x1b[0m {s}\x1b[0m", .{ label, highlighted });
}

fn specLabel(spec: *const tool_dispatch.Tool, state: ToolActionState, denied_label: ?[]const u8) []const u8 {
    return switch (state) {
        .active => spec.action_label,
        .completed => spec.completed_action_label,
        .denied => denied_label.?,
    };
}

fn presentationLabel(presentation: tool_dispatch.CallPresentation, state: ToolActionState, denied_label: ?[]const u8) []const u8 {
    return switch (state) {
        .active => presentation.action_label,
        .completed => presentation.completed_action_label,
        .denied => denied_label.?,
    };
}

const test_ignored_list_entries = [_][]const u8{ ".git", "zig-out" };
const test_gateway_chat_url = "https://gateway.test/chat";
const test_tools = [_]tool_dispatch.Tool{
    test_builtin_tools.web_search,
    test_builtin_tools.shell,
    test_builtin_tools.grep_files,
    test_builtin_tools.skill,
    test_builtin_tools.install_skill,
    test_builtin_tools.subagent,
};
const test_tool_registry = tool_dispatch.Registry{ .tools = test_tools[0..] };
const custom_label_tool = tool_dispatch.Tool{
    .name = "custom_registered_tool",
    .description = "Custom registered test tool.",
    .model_schema = .{
        .name = "custom_registered_tool",
        .description = "Custom registered test tool.",
    },
    .action_label = "Custom running",
    .completed_action_label = "Custom ran",
    .label_arg_kind = .name,
    .label_arg_default = "custom fallback",
    .decode = test_builtin_tools.read_file.decode,
    .call = test_builtin_tools.read_file.call,
    .reads_only_fn = test_builtin_tools.read_file.reads_only_fn,
    .irreversible_fn = test_builtin_tools.read_file.irreversible_fn,
};
const custom_registry_tools = [_]tool_dispatch.Tool{custom_label_tool};
const custom_tool_registry = tool_dispatch.Registry{ .tools = custom_registry_tools[0..] };

fn gatherTestProjectContext(_: Allocator, _: context_contract.InitialContextInput) context_contract.ProviderError!context_contract.ProviderContext {
    return .{};
}

fn appendTestStaticContext(input: context_contract.StaticContextInput, alloc: Allocator, messages: *std.ArrayList(ChatMessage)) context_contract.ProviderError!void {
    const content = try std.fmt.allocPrint(alloc, "provider static:{s}", .{input.project_context});
    try messages.append(alloc, .{ .role = .system, .content = content });
}

fn appendTestTransientContext(input: context_contract.TransientContextInput, alloc: Allocator, messages: *std.ArrayList(ChatMessage)) context_contract.ProviderError!void {
    const content = try std.fmt.allocPrint(
        alloc,
        "provider transient:{s}:{s}",
        .{ input.workspace_root, @tagName(input.permission_mode) },
    );
    try messages.append(alloc, .{ .role = .system, .content = content });
}

const test_context_provider = context_contract.Provider{
    .id = "test.default_context",
    .gather_project_context_fn = gatherTestProjectContext,
    .select_applicable_project_context_fn = context_contract.selectNoApplicableProjectContext,
    .append_static_fn = appendTestStaticContext,
    .append_transient_fn = appendTestTransientContext,
};
const test_context_registry = context_contract.Registry{ .default_provider = test_context_provider };
const test_prompt_policy = prompt_policy_contract.Policy{
    .system_prompt = "test system prompt",
    .model_prompt_overlay_fn = struct {
        fn overlay(model: []const u8) ?[]const u8 {
            return if (std.mem.eql(u8, model, "test-model")) "test model overlay" else null;
        }
    }.overlay,
};

var refresh_gather_calls: usize = 0;
var refresh_targets_match: bool = false;
var refresh_gather_error: context_contract.ProviderError = error.WriteFailed;

fn gatherFreshProjectContext(alloc: Allocator, input: context_contract.InitialContextInput) context_contract.ProviderError!context_contract.ProviderContext {
    refresh_gather_calls += 1;
    refresh_targets_match = input.targets.len == 1 and
        input.targets[0].kind == .file and
        std.mem.eql(u8, input.targets[0].path, "/tmp/workspace/images/example.png");
    const content = try std.fmt.allocPrint(alloc, "fresh:{s}", .{input.workspace_root});
    errdefer alloc.free(content);
    const notices = try alloc.alloc([]u8, 1);
    errdefer alloc.free(notices);
    notices[0] = try alloc.dupe(u8, "fresh context notice");
    return .{ .content = content, .notices = notices };
}

fn gatherFailingProjectContext(_: Allocator, _: context_contract.InitialContextInput) context_contract.ProviderError!context_contract.ProviderContext {
    refresh_gather_calls += 1;
    return refresh_gather_error;
}

fn appendNoopStaticContext(_: context_contract.StaticContextInput, _: Allocator, _: *std.ArrayList(ChatMessage)) context_contract.ProviderError!void {}

fn appendNoopTransientContext(_: context_contract.TransientContextInput, _: Allocator, _: *std.ArrayList(ChatMessage)) context_contract.ProviderError!void {}

const fresh_context_registry = context_contract.Registry{ .default_provider = .{
    .id = "test.fresh_context",
    .gather_project_context_fn = gatherFreshProjectContext,
    .select_applicable_project_context_fn = context_contract.selectNoApplicableProjectContext,
    .append_static_fn = appendNoopStaticContext,
    .append_transient_fn = appendNoopTransientContext,
} };
const failing_context_registry = context_contract.Registry{ .default_provider = .{
    .id = "test.failing_context",
    .gather_project_context_fn = gatherFailingProjectContext,
    .select_applicable_project_context_fn = context_contract.selectNoApplicableProjectContext,
    .append_static_fn = appendNoopStaticContext,
    .append_transient_fn = appendNoopTransientContext,
} };

const RefreshContextApp = struct {
    alloc: Allocator,
    workspace_root: []const u8 = "/tmp/workspace",
    context_enabled: bool,
    context_snapshot: context_contract.GatheredContextSnapshot,
    context_registry: context_contract.Registry,
    context_notices: std.ArrayList(u8) = .empty,
    context_notice_tone: ?types.NoticeTone = null,
    context_notice_visibility: ?types.NoticeVisibility = null,
    session: session_runtime.SessionRuntime = .{ .max_history_turns = 8 },

    fn contextRegistry(self: *const RefreshContextApp) context_contract.Registry {
        return self.context_registry;
    }

    fn deinit(self: *RefreshContextApp) void {
        self.context_snapshot.deinit(self.alloc);
        self.context_notices.deinit(self.alloc);
        self.session.deinit(self.alloc);
    }

    fn writeDomainNotice(self: *RefreshContextApp, notice: types.SemanticNotice, _: bool) !void {
        self.context_notice_tone = notice.tone;
        self.context_notice_visibility = notice.visibility;
        try self.context_notices.appendSlice(self.alloc, notice.body);
    }
};

fn makeTestContextSnapshot(alloc: Allocator, provider_id: []const u8, content: []const u8) !context_contract.GatheredContextSnapshot {
    const owned_provider_id = try alloc.dupe(u8, provider_id);
    errdefer alloc.free(owned_provider_id);
    return .{ .contribution = .{
        .provider_id = owned_provider_id,
        .content = try alloc.dupe(u8, content),
    } };
}

fn testToolContext(app: *FakeApp) tool_runtime.Context {
    return Runtime(FakeApp).toolContext(app, &test_ignored_list_entries, 100, 1024, 40, 120, 2048, 2, test_gateway_chat_url);
}

const ProjectionBarrier = struct {
    entered: std.atomic.Value(bool) = .init(false),
    release: std.atomic.Value(bool) = .init(false),

    fn wait(self: *ProjectionBarrier) void {
        self.entered.store(true, .release);
        while (!self.release.load(.acquire)) io_mod.sleep(std.time.ns_per_ms);
    }
};

const FakeApp = struct {
    alloc: Allocator,
    agent_stream_provider: agent_stream_provider.Provider = agent_stream_provider.unavailable_provider,
    workspace_root: []const u8 = "/tmp/workspace",
    auth: auth_runtime.Runtime = .{},
    selected_model: std.ArrayList(u8) = .empty,
    selected_provider: model_provider.ProviderId = .openrouter,
    permission_engine: permissions.PermissionEngine = .{},
    agent_step_limit: usize = 8,
    fast_mode: bool = true,
    effort: types.ReasoningEffort = types.ReasoningEffort.literal("high"),
    worker: worker_runtime.WorkerRuntime = .{},
    session: session_runtime.SessionRuntime = .{ .max_history_turns = 4 },
    session_persistence: app_session_runtime.Persistence = .{},
    skills_dir: []const u8 = "/tmp/skills",
    context_snapshot: context_contract.GatheredContextSnapshot,
    permission_state: app_permission_runtime.State = .{},
    change_tracker: change_tracker.ChangeTracker = .{},
    skills: skill_runtime.Runtime = .{},
    total_input_tokens: u64 = 0,
    total_output_tokens: u64 = 0,
    total_web_search_requests: u64 = 0,
    append_context_count: usize = 0,
    snapshot_tools_count: usize = 0,
    snapshot_permission_mode: ?PermissionMode = null,
    snapshot_permission_rule_pattern: ?[]const u8 = null,
    snapshot_barrier: ?*ProjectionBarrier = null,
    snapshot_tools_error: ?anyerror = null,
    snapshot_custom_guidance: []const u8 = "",

    diff_blocks: usize = 0,
    web_fetch_runtime: web_fetch_runtime.Runtime = web_fetch_runtime.Runtime.init(.{}),
    web_search_runtime: web_search_runtime.Runtime = web_search_runtime.Runtime.init(.{
        .provider = test_openrouter.default_web_search_provider,
    }),
    web_search_models_path: []const u8 = "/models",
    lifecycle_runtime: hooks.Runtime,
    lifecycle_view: hooks.RuntimeView,
    tool_registry: tool_dispatch.Registry = test_tool_registry,
    context_registry: context_contract.Registry = test_context_registry,

    fn init(alloc: Allocator) !FakeApp {
        var lifecycle_runtime = hooks.Runtime.init(alloc);
        const lifecycle_view = lifecycle_runtime.freeze();
        var app = FakeApp{
            .alloc = alloc,
            .lifecycle_runtime = lifecycle_runtime,
            .lifecycle_view = lifecycle_view,
            .context_snapshot = try makeTestContextSnapshot(alloc, "test.default_context", "project context"),
        };
        errdefer app.context_snapshot.deinit(alloc);
        var credential = credentials.Credential{
            .token = try alloc.dupe(u8, "api-key"),
            .source = .openrouter_api_key,
        };
        defer credential.deinit(alloc);
        _ = app.auth.adoptCredential(alloc, &credential);
        errdefer app.auth.deinit(alloc);
        try app.selected_model.appendSlice(alloc, "test-model");
        return app;
    }

    fn toolRegistry(self: *const FakeApp) tool_dispatch.Registry {
        return self.tool_registry;
    }

    fn contextRegistry(self: *const FakeApp) context_contract.Registry {
        return self.context_registry;
    }

    fn promptPolicy(_: *const FakeApp) prompt_policy_contract.Policy {
        return test_prompt_policy;
    }

    pub fn agentStreamProvider(self: *const FakeApp) agent_stream_provider.Provider {
        return self.agent_stream_provider;
    }

    fn deinit(self: *FakeApp) void {
        self.auth.deinit(self.alloc);
        self.selected_model.deinit(self.alloc);
        self.permission_engine.deinit(self.alloc);
        self.context_snapshot.deinit(self.alloc);
        self.worker.deinit(std.heap.c_allocator);
        self.web_fetch_runtime.deinit(self.alloc);
        self.web_search_runtime.deinit();
        self.session.deinit(self.alloc);
        self.change_tracker.deinit(self.alloc);
        self.lifecycle_runtime.deinit();
    }

    fn subagentToolContextForAdmission(
        self: *FakeApp,
        admission: subagent_domain.AdmissionSnapshot,
    ) tool_runtime.Context {
        return Runtime(FakeApp).toolContextForSubagent(
            self,
            &test_ignored_list_entries,
            100,
            1024,
            40,
            120,
            2048,
            2,
            test_gateway_chat_url,
            admission,
        );
    }

    fn snapshotModelToolProjection(
        self: *FakeApp,
        alloc: Allocator,
        permission_mode: PermissionMode,
    ) !tool_projection_mod.EffectiveToolProjection {
        self.snapshot_tools_count += 1;
        self.snapshot_permission_mode = permission_mode;
        if (self.snapshot_barrier) |barrier| barrier.wait();
        self.snapshot_permission_rule_pattern = if (self.permission_engine.rules.rules.len > 0)
            self.permission_engine.rules.rules[0].pattern
        else
            null;
        if (self.snapshot_tools_error) |err| return err;
        const advertised_names = try alloc.alloc([]const u8, 0);
        errdefer alloc.free(advertised_names);
        const advertised_functions = try alloc.alloc(model_tool_schema.FunctionSchema, 0);
        errdefer alloc.free(advertised_functions);
        return .{
            .advertised_names = advertised_names,
            .advertised_functions = advertised_functions,
            .custom_guidance = try alloc.dupe(u8, self.snapshot_custom_guidance),
        };
    }

    fn snapshotSubagentModelToolProjection(
        self: *FakeApp,
        alloc: Allocator,
        permission_mode: PermissionMode,
        permission_rules: types.PermissionRuleSet,
    ) !tool_projection_mod.EffectiveToolProjection {
        self.snapshot_tools_count += 1;
        self.snapshot_permission_mode = permission_mode;
        if (self.snapshot_barrier) |barrier| barrier.wait();
        self.snapshot_permission_rule_pattern = if (permission_rules.rules.len > 0)
            permission_rules.rules[0].pattern
        else
            null;
        if (self.snapshot_tools_error) |err| return err;
        const advertised_names = try alloc.alloc([]const u8, 0);
        errdefer alloc.free(advertised_names);
        const advertised_functions = try alloc.alloc(model_tool_schema.FunctionSchema, 0);
        errdefer alloc.free(advertised_functions);
        return .{
            .advertised_names = advertised_names,
            .advertised_functions = advertised_functions,
            .custom_guidance = try alloc.dupe(u8, self.snapshot_custom_guidance),
        };
    }

    pub fn appendRuntimeContextMessage(self: *FakeApp, arena: Allocator, messages: *std.ArrayList(ChatMessage)) !void {
        self.append_context_count += 1;
        try Runtime(FakeApp).appendTransientRuntimeContextMessage(self, arena, messages, &test_ignored_list_entries, 100, 1024, 40, 120, 2048, 2, test_gateway_chat_url);
    }

    pub fn requestToolPermissionSync(self: *FakeApp, arena: Allocator, call: ToolCall, permission_mode: PermissionMode, local_grants: []const PermissionGrant) !command_admission.PermissionOutcome {
        return Runtime(FakeApp).requestToolPermissionSync(self, arena, call, "", permission_mode, local_grants, null, null, &.{}, null, &test_ignored_list_entries, 100, 1024, 40, 120, 2048, 2, test_gateway_chat_url);
    }

    pub fn requestToolPermissionSyncWithAdvertised(self: *FakeApp, arena: Allocator, call: ToolCall, review_turn: permission_auto_classifier.ReviewTurnContext, permission_mode: PermissionMode, local_grants: []const PermissionGrant, live_authority: ?agent_runtime.LiveToolAuthority, revalidation: ?agent_runtime.LivePermissionRevalidation, advertised_dynamic_tool_names: []const []const u8) !command_admission.PermissionOutcome {
        return Runtime(FakeApp).requestToolPermissionSync(self, arena, call, review_turn, permission_mode, local_grants, live_authority, revalidation, advertised_dynamic_tool_names, &test_ignored_list_entries, 100, 1024, 40, 120, 2048, 2, test_gateway_chat_url);
    }

    pub fn requestPreparedFileMutationPermissionSyncWithAdvertised(self: *FakeApp, arena: Allocator, call: ToolCall, prepared: *tool_admission.PreparedFileMutationCall, review_turn: permission_auto_classifier.ReviewTurnContext, permission_mode: PermissionMode, local_grants: []const PermissionGrant, live_authority: ?agent_runtime.LiveToolAuthority, advertised_dynamic_tool_names: []const []const u8) !command_admission.PermissionOutcome {
        return Runtime(FakeApp).requestPreparedFileMutationPermissionSync(self, arena, call, prepared, review_turn, permission_mode, local_grants, live_authority, advertised_dynamic_tool_names, &test_ignored_list_entries, 100, 1024, 40, 120, 2048, 2, test_gateway_chat_url);
    }

    pub fn validateToolCall(self: *FakeApp, arena: Allocator, call: ToolCall) !agent_runtime.ToolCallValidationResult {
        return Runtime(FakeApp).validateToolCall(self, arena, call, &test_ignored_list_entries, 100, 1024, 40, 120, 2048, 2, test_gateway_chat_url);
    }

    pub fn checkToolAvailability(self: *FakeApp, arena: Allocator, call: ToolCall) !?[]const u8 {
        return Runtime(FakeApp).checkToolAvailability(self, arena, call, &test_ignored_list_entries, 100, 1024, 40, 120, 2048, 2, test_gateway_chat_url);
    }

    pub fn describeToolAction(self: *FakeApp, arena: Allocator, call: ToolCall) ![]const u8 {
        return Runtime(FakeApp).describeToolAction(self, arena, call, null, &.{}, &test_ignored_list_entries, 100, 1024, 40, 120, 2048, 2, test_gateway_chat_url);
    }

    pub fn describeToolActionWithAdvertised(self: *FakeApp, arena: Allocator, call: ToolCall, display_target: ?[]const u8, advertised_dynamic_tool_names: []const []const u8) ![]const u8 {
        return Runtime(FakeApp).describeToolAction(self, arena, call, display_target, advertised_dynamic_tool_names, &test_ignored_list_entries, 100, 1024, 40, 120, 2048, 2, test_gateway_chat_url);
    }

    pub fn describeToolActionCompleted(self: *FakeApp, arena: Allocator, call: ToolCall) ![]const u8 {
        return Runtime(FakeApp).describeToolActionCompleted(self, arena, call, null, &.{}, &test_ignored_list_entries, 100, 1024, 40, 120, 2048, 2, test_gateway_chat_url);
    }

    pub fn describeToolActionCompletedWithAdvertised(self: *FakeApp, arena: Allocator, call: ToolCall, display_target: ?[]const u8, advertised_dynamic_tool_names: []const []const u8) ![]const u8 {
        return Runtime(FakeApp).describeToolActionCompleted(self, arena, call, display_target, advertised_dynamic_tool_names, &test_ignored_list_entries, 100, 1024, 40, 120, 2048, 2, test_gateway_chat_url);
    }

    pub fn describeToolActionDenied(self: *FakeApp, arena: Allocator, call: ToolCall, label: []const u8) ![]const u8 {
        return Runtime(FakeApp).describeToolActionDenied(self, arena, call, null, label, &.{}, &test_ignored_list_entries, 100, 1024, 40, 120, 2048, 2, test_gateway_chat_url);
    }

    pub fn describeToolActionDeniedWithAdvertised(self: *FakeApp, arena: Allocator, call: ToolCall, display_target: ?[]const u8, label: []const u8, advertised_dynamic_tool_names: []const []const u8) ![]const u8 {
        return Runtime(FakeApp).describeToolActionDenied(self, arena, call, display_target, label, advertised_dynamic_tool_names, &test_ignored_list_entries, 100, 1024, 40, 120, 2048, 2, test_gateway_chat_url);
    }

    pub fn permissionTargetForCall(self: *FakeApp, arena: Allocator, call: ToolCall) ![]const u8 {
        return Runtime(FakeApp).permissionTargetForCall(self, arena, call, &.{}, &test_ignored_list_entries, 100, 1024, 40, 120, 2048, 2, test_gateway_chat_url);
    }

    pub fn permissionTargetForCallWithAdvertised(self: *FakeApp, arena: Allocator, call: ToolCall, advertised_dynamic_tool_names: []const []const u8) ![]const u8 {
        return Runtime(FakeApp).permissionTargetForCall(self, arena, call, advertised_dynamic_tool_names, &test_ignored_list_entries, 100, 1024, 40, 120, 2048, 2, test_gateway_chat_url);
    }

    pub fn executeToolCall(self: *FakeApp, request: agent_runtime.ToolExecutionRequest) !agent_runtime.ToolExecutionResult {
        return Runtime(FakeApp).executeToolCall(self, request, &test_ignored_list_entries, 100, 1024, 40, 120, 2048, 2, test_gateway_chat_url);
    }

    pub fn executeToolCallWithAdvertised(self: *FakeApp, request: agent_runtime.ToolExecutionRequest) !agent_runtime.ToolExecutionResult {
        return self.executeToolCall(request);
    }

    pub fn registerAndEmitDiffBlock(self: *FakeApp, payload: agent_runtime.DiffEntryPayload) !void {
        _ = payload;
        self.diff_blocks += 1;
    }

    pub fn formatToolExecutionErrorForAgent(self: *FakeApp, arena: Allocator, tool_name: []const u8, err: anyerror) ![]const u8 {
        _ = self;
        return std.fmt.allocPrint(arena, "Tool {s} failed: {s}", .{ tool_name, @errorName(err) });
    }
};

fn testAgentStreamProvider(stream_fn: agent_stream_provider.StreamFn) agent_stream_provider.Provider {
    var provider = test_openrouter.agent_stream;
    provider.stream_fn = stream_fn;
    return provider;
}

const TestCatalogProvider = struct {
    saw_expected_input: bool = false,

    fn appendEntry(
        alloc: Allocator,
        catalog: *std.ArrayList(model_catalog.ModelCatalogEntry),
        id_text: []const u8,
    ) !void {
        const id = try alloc.dupe(u8, id_text);
        errdefer alloc.free(id);
        const model_type = try alloc.dupe(u8, "language");
        errdefer alloc.free(model_type);
        try catalog.append(alloc, .{ .id = id, .model_type = model_type });
    }

    fn fetch(
        raw_context: ?*anyopaque,
        alloc: Allocator,
        input: model_catalog.FetchInput,
    ) Allocator.Error!model_catalog.ProviderResult {
        const self: *TestCatalogProvider = @ptrCast(@alignCast(raw_context.?));
        self.saw_expected_input =
            std.mem.eql(u8, input.access.authorizationCredential() orelse "", "api-key") and
            input.access.teamContext() == null and
            input.access.credentialSource() == .openrouter_api_key and
            std.mem.eql(u8, input.endpoint, "/catalog") and
            input.cancel_flag == null and
            input.view == .full;

        var catalog: std.ArrayList(model_catalog.ModelCatalogEntry) = .empty;
        errdefer model_catalog.freeModelCatalog(alloc, &catalog);
        try appendEntry(alloc, &catalog, "provider/first");
        try appendEntry(alloc, &catalog, "provider/second");
        return .{ .catalog = catalog };
    }
};

fn makeQueuedPrompt(alloc: Allocator) !worker_runtime.QueuedPrompt {
    return .{
        .prompt = try alloc.dupe(u8, "draft an issue"),
        .images = &.{},
        .model = try alloc.dupe(u8, "test-model"),
        .api_key = try alloc.dupe(u8, "api-key"),
        .permission_mode = .yolo,
        .history = try alloc.alloc(types.HistoryTurn, 0),
        .grants = try alloc.alloc(types.PermissionGrant, 0),
    };
}
