const std = @import("std");
const credentials = @import("../auth/credentials.zig");
const activity_status = @import("../output/activity_status.zig");
const app_session_runtime = @import("app_session_runtime.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const diff_mod = @import("../output/diff.zig");
const file_mutation_contract = @import("../tooling/file_mutation_contract.zig");
const command_output_content = @import("../tooling/command_output_content.zig");
const io_mod = @import("../shared/io.zig");
const permission_request = @import("../permissions/permission_request.zig");
const text_utils = @import("../shared/text_utils.zig");
const shared_theme = @import("../shared/theme.zig");
const types = @import("../shared/types.zig");
const worker_runtime = @import("../agent/worker_runtime.zig");
const assistant_presentation = @import("../agent/assistant_presentation.zig");
const assistant_pacer = @import("../../ui/assistant/pacer.zig");
const ui_render = @import("../../ui/render.zig");
const activity_runtime = @import("../output/activity_runtime.zig");
const worker_status = @import("../output/worker_status.zig");
const core_input_runtime = @import("../input/runtime.zig");
const render_input = @import("../../ui/footer/render_input.zig");
const interaction_state = @import("../../ui/footer/interaction_state.zig");
const render_request = @import("../../ui/render_request.zig");
const transcript_runtime = @import("../../ui/transcript/runtime.zig");

const WorkerEvent = worker_runtime.WorkerEvent;
const InputRuntime = core_input_runtime.Runtime;

const CancelledEventAdmission = enum {
    admit,
    drop,
    defer_until_closure,
};

const reset_style = ui_render.reset_style;

fn discardTable(_: *anyopaque, table: assistant_presentation.TablePayload) !void {
    var owned = table;
    owned.deinit(std.heap.c_allocator);
}

fn discardCodeBlock(_: *anyopaque, block: assistant_presentation.CodeBlockPayload) !void {
    var owned = block;
    owned.deinit(std.heap.c_allocator);
}

fn discardThematicRule(_: *anyopaque) !void {}
fn discardContextCompaction(_: *anyopaque, _: worker_runtime.ContextCompaction) !void {}
fn unavailableFreshPrompt(_: *anyopaque, _: worker_runtime.FreshPromptPreparation) !worker_runtime.FreshPromptHistory {
    return error.SessionPersistenceUnavailable;
}
fn discardCredentialRefresh(_: *anyopaque, _: credentials.Credential) !void {}

/// A retained delivery owns its own payload; a settled delivery acknowledges history.
pub const HistoryDelivery = union(enum) {
    retained,
    settled: assistant_pacer.FinishResult,
};

pub const WorkerEventHandlers = struct {
    ctx: *anyopaque,
    tool_lifecycle: activity_runtime.LifecyclePresenter,
    write_user_prompt: *const fn (*anyopaque, types.UserTurn) anyerror!void,
    write_user_prompt_with_skill_bindings: ?*const fn (*anyopaque, types.UserTurn, []const worker_runtime.SkillBinding, []const worker_runtime.SkillDisplaySpan) anyerror!void = null,
    append_text: *const fn (*anyopaque, []const u8) anyerror!void,
    append_table: *const fn (*anyopaque, assistant_presentation.TablePayload) anyerror!void = discardTable,
    append_code_block: *const fn (*anyopaque, assistant_presentation.CodeBlockPayload) anyerror!void = discardCodeBlock,
    append_thematic_rule: *const fn (*anyopaque) anyerror!void = discardThematicRule,
    drain_assistant_text: *const fn (*anyopaque) anyerror!AssistantTextDrainResult,
    open_model_picker: *const fn (*anyopaque) anyerror!void,
    semantic_notice: *const fn (*anyopaque, types.SemanticNotice) anyerror!void,
    credential_refreshed: *const fn (*anyopaque, credentials.Credential) anyerror!void = discardCredentialRefresh,
    command_output: *const fn (*anyopaque, ?types.ToolLifecycleId, command_output_content.Stream, []const u8) anyerror!void,
    command_output_complete: *const fn (*anyopaque, ?types.ToolLifecycleId) anyerror!void,
    diff_block: *const fn (*anyopaque, diff_mod.DiffEntryPayload) anyerror!void,
    context_compaction: worker_runtime.ContextCompactionHandler = discardContextCompaction,
    prepare_fresh_prompt: worker_runtime.FreshPromptHandler = unavailableFreshPrompt,
    append_history_turn: *const fn (*anyopaque, types.FinishedPrompt) anyerror!HistoryDelivery,
    session_grant: *const fn (*anyopaque, types.PermissionGrant) anyerror!void,
    error_text: *const fn (*anyopaque, types.SemanticNotice) anyerror!void,
};

pub const AssistantTextDrainResult = enum {
    drained,
    blocked,
};

/// Writes one full-detail record for an admitted route recovery transition.
/// The footer status is transient; this preserves retry and failure history
/// in the full-screen surface's detail section.
fn recordRouteRecoveryNotice(app: anytype, status: types.RouteRecoveryStatus) !void {
    var body: std.Io.Writer.Allocating = .init(std.heap.c_allocator);
    defer body.deinit();
    try writeRouteRecoveryBody(&body.writer, status);
    try app.shell.appendFullDetailRecord(app.alloc, .{
        .topic = "recovery",
        .tone = routeRecoveryNoticeTone(status),
        .body = body.written(),
        .visibility = .full_only,
    });
}

fn routeRecoveryNoticeTone(status: types.RouteRecoveryStatus) types.NoticeTone {
    return switch (status.tone()) {
        .warning => .warning,
        .success => .success,
        .danger => .@"error",
    };
}

/// Pure formatter for the recovery record body: footer label, then the
/// structured facts the label cannot carry.
fn writeRouteRecoveryBody(
    writer: *std.Io.Writer,
    status: types.RouteRecoveryStatus,
) !void {
    var label_buf: [types.RouteRecoveryStatus.label_max_bytes]u8 = undefined;
    try writer.writeAll(status.label(&label_buf));
    try writer.print("\nkind: {s}", .{@tagName(status.kind)});
    if (status.cause) |cause| try writer.print(" · cause: {s}", .{@tagName(cause)});
    if (status.attempt_limit > 0) {
        try writer.print(" · attempt: {d}/{d}", .{ status.reportedAttempt(), status.attempt_limit });
    }
    if (status.delay_seconds > 0) {
        try writer.print(" · retry delay: {d}s", .{status.delay_seconds});
    }
    if (status.diagnostic) |diagnostic| {
        try writer.print(" · diagnostic: {s}", .{diagnostic.view()});
    }
}

const DetachedWorkerEventBatch = struct {
    alloc: std.mem.Allocator,
    events: std.ArrayList(WorkerEvent),
    next_unvisited: usize = 0,

    fn init(
        alloc: std.mem.Allocator,
        events: std.ArrayList(WorkerEvent),
    ) DetachedWorkerEventBatch {
        return .{
            .alloc = alloc,
            .events = events,
        };
    }

    fn claim(self: *DetachedWorkerEventBatch) ?WorkerEvent {
        if (self.next_unvisited >= self.events.items.len) return null;
        const event = self.events.items[self.next_unvisited];
        self.next_unvisited += 1;
        return event;
    }

    fn claimedAndRemaining(self: *const DetachedWorkerEventBatch) []const WorkerEvent {
        std.debug.assert(self.next_unvisited > 0);
        return self.events.items[self.next_unvisited - 1 ..];
    }

    fn markClaimedAndRemainingTransferred(self: *DetachedWorkerEventBatch) void {
        self.next_unvisited = self.events.items.len;
    }

    fn deinit(self: *DetachedWorkerEventBatch) void {
        while (self.next_unvisited < self.events.items.len) : (self.next_unvisited += 1) {
            debug_trace.logf("worker", "undelivered worker event discarded kind={s}", .{@tagName(self.events.items[self.next_unvisited])});
            worker_runtime.freeWorkerEvent(self.alloc, self.events.items[self.next_unvisited]);
        }
        self.events.deinit(self.alloc);
        self.* = undefined;
    }
};

fn batchContainsTerminalClosure(
    events: []const WorkerEvent,
    id: types.ToolLifecycleId,
) bool {
    for (events) |event| {
        const lifecycle = switch (event) {
            .tool_lifecycle => |value| value,
            else => continue,
        };
        switch (lifecycle) {
            .terminal => |terminal| {
                if (terminal.id.turn_id == id.turn_id and
                    std.mem.eql(u8, terminal.id.call_id, id.call_id)) return true;
            },
            .turn_finished => |finished| {
                if (finished.turn_id == id.turn_id) return true;
            },
            .provisional, .authoritative_started, .progress => {},
        }
    }
    return false;
}

fn batchSegmentIsInterrupted(events: []const WorkerEvent, cancelled_turn_id: ?u64) bool {
    var turn_id: ?u64 = null;
    scan: for (events, 0..) |event, index| {
        if (index > 0) switch (event) {
            .begin_prompt, .begin_prompt_with_skill_bindings, .begin_presented_prompt => break :scan,
            else => {},
        };
        switch (event) {
            .begin_presented_prompt => |id| turn_id = id,
            .turn_phase_update => |phase| turn_id = phase.turn_id,
            .tool_lifecycle => |lifecycle| {
                turn_id = switch (lifecycle) {
                    .turn_finished => |finished| return finished.outcome == .interrupted,
                    .provisional => |value| value.id.turn_id,
                    .authoritative_started => |value| value.id.turn_id,
                    .progress => |value| value.id.turn_id,
                    .terminal => |value| value.id.turn_id,
                };
            },
            else => {},
        }
    }
    const cancelled = cancelled_turn_id orelse return false;
    return turn_id == null or turn_id.? == cancelled;
}

pub fn Runtime(comptime App: type) type {
    return struct {
        fn cancelledToolStartAdmission(
            presenter: activity_runtime.LifecyclePresenter,
            id: types.ToolLifecycleId,
            batch_events: []const WorkerEvent,
        ) CancelledEventAdmission {
            if (batchContainsTerminalClosure(batch_events, id)) return .admit;
            if (id.turn_id <= presenter.snapshot().finalized_turn_watermark) return .drop;
            return .defer_until_closure;
        }

        fn cancelledEventAdmission(
            presenter: activity_runtime.LifecyclePresenter,
            event: WorkerEvent,
            batch_events: []const WorkerEvent,
        ) CancelledEventAdmission {
            return switch (event) {
                .assistant_presentation,
                .open_model_picker,
                .semantic_notice,
                .full_detail_record,
                .command_output,
                .turn_token_update,
                .turn_phase_update,
                .diff_block,
                .restore_failed_prompt,
                => .drop,
                .route_recovery_status => |status| if (status.action == .paused)
                    .admit
                else
                    .drop,
                .command_output_complete => |lifecycle_id| if (cancelledCommandCompletionMatches(presenter, lifecycle_id))
                    .admit
                else
                    .drop,
                .tool_lifecycle => |lifecycle| switch (lifecycle) {
                    .provisional => |started| cancelledToolStartAdmission(presenter, started.id, batch_events),
                    .authoritative_started => |started| cancelledToolStartAdmission(presenter, started.id, batch_events),
                    .progress => .drop,
                    .terminal => |terminal| if (presenter.record(terminal.id) == null)
                        .drop
                    else
                        .admit,
                    .turn_finished => .admit,
                },
                .begin_prompt,
                .begin_prompt_with_skill_bindings,
                .begin_presented_prompt,
                .append_user_feedback,
                .notification,
                .question_requested,
                .clear_route_recovery_status,
                .provider_resolved,
                .api_status_text,
                .context_compaction,
                .prepare_fresh_prompt,
                .credential_refreshed,
                .finish_prompt,
                .session_grant,
                .error_text,
                => .admit,
            };
        }

        fn cancelledCommandCompletionMatches(
            presenter: activity_runtime.LifecyclePresenter,
            lifecycle_id: ?types.ToolLifecycleId,
        ) bool {
            const id = lifecycle_id orelse return false;
            const record = presenter.record(id) orelse return false;
            return record.phase == .terminal and record.activity_kind == .command;
        }

        /// After the worker joins, persist finished turns without presenting output
        /// or admitting work. The pacer owns the finish preceding queued events.
        pub fn settleFinishedPromptsForShutdown(app: *App) !void {
            try settleDeferredFinish(app);

            var batch = DetachedWorkerEventBatch.init(
                std.heap.c_allocator,
                app.worker.takeEvents(),
            );
            defer batch.deinit();
            while (batch.claim()) |event| {
                defer worker_runtime.freeWorkerEvent(batch.alloc, event);
                switch (event) {
                    .finish_prompt => |finished| try persistFinishedPrompt(app, finished),
                    else => debug_trace.logf("worker", "shutdown worker event dropped kind={s}", .{@tagName(event)}),
                }
            }
        }

        fn persistFinishedPrompt(app: *App, finished: types.FinishedPrompt) !void {
            errdefer |err| app_session_runtime.Runtime(App).recordFailedHistoryDelivery(app, err);
            if (comptime @hasField(App, "session")) {
                try app_session_runtime.Runtime(App).appendFinishedPrompt(app, finished);
            } else {
                try app.appendFinishedPrompt(finished);
            }
        }

        fn settleDeferredFinish(app: *App) !void {
            if (comptime !@hasField(@TypeOf(app.pacer), "deferred_turn")) return;
            if (app.pacer.deferred_turn) |finished| {
                app.pacer.deferred_turn = null;
                app.pacer.deferred_started_ns = null;
                defer types.freeFinishedPrompt(app.alloc, finished);
                try persistFinishedPrompt(app, finished);
            }
        }

        fn preserveFinishedAfterDrainFailure(app: *App, batch: *DetachedWorkerEventBatch, may_persist: bool) void {
            var can_persist = may_persist;
            if (can_persist) settleDeferredFinish(app) catch {
                can_persist = false;
            };
            while (batch.claim()) |event| {
                defer worker_runtime.freeWorkerEvent(batch.alloc, event);
                switch (event) {
                    .finish_prompt => |finished| {
                        if (can_persist) {
                            persistFinishedPrompt(app, finished) catch {
                                can_persist = false;
                            };
                        } else {
                            debug_trace.logf("worker", "finished turn not persisted after earlier save failure", .{});
                        }
                    },
                    else => debug_trace.logf("worker", "presentation failure discarded worker event kind={s}", .{@tagName(event)}),
                }
            }
        }

        pub fn authorizeInteractiveAdmission(app: *App) !bool {
            if (comptime @hasDecl(@TypeOf(app.worker), "interactiveAdmissionSnapshot")) {
                switch (app.worker.interactiveAdmissionSnapshot()) {
                    .open => return true,
                    .stopped => return false,
                    .finalization_failed => {
                        if (comptime @hasField(App, "should_exit")) {
                            app.should_exit = true;
                        }
                        return error.TurnFinalizationDeliveryFailed;
                    },
                }
            }
            return true;
        }

        pub fn syncQueuedPromptModel(app: *App, model: []const u8) !void {
            try app.worker.syncQueuedPromptModel(std.heap.c_allocator, model);
        }

        pub fn syncQueuedPromptPermissionSnapshot(app: *App, snapshot: worker_runtime.PermissionSnapshot) void {
            app.worker.syncQueuedPromptPermissionSnapshot(snapshot);
        }

        pub fn syncQueuedPromptPermissionState(
            app: *App,
            snapshot: worker_runtime.PermissionSnapshot,
        ) !void {
            try app.worker.syncQueuedPromptPermissionState(
                std.heap.c_allocator,
                app.permission_engine.grants.items,
                snapshot,
            );
        }

        pub fn propagateHistoryTurn(app: *App, turn: types.HistoryTurn, max_history_turns: usize) !void {
            if (comptime @hasDecl(App, "propagateHistoryTurn")) {
                try app.propagateHistoryTurn(turn);
                return;
            }
            try app.worker.propagateHistoryTurn(std.heap.c_allocator, turn, max_history_turns);
        }

        pub fn commitContextCompaction(
            app: *App,
            summary: types.CompactedSummaryHistoryTurn,
            active_prefix: ?types.AssistantHistoryTurn,
            retained_from: ?types.ContextHistoryCut,
            max_history_turns: usize,
        ) !void {
            if (comptime @hasDecl(@TypeOf(app.worker), "commitContextCompaction")) {
                try app.worker.commitContextCompaction(
                    std.heap.c_allocator,
                    summary,
                    active_prefix,
                    retained_from,
                    max_history_turns,
                );
                return;
            }
            return error.ContextCompactionPersistenceUnavailable;
        }

        pub fn propagateGrant(app: *App, tool_name: []const u8, target_path: []const u8) !void {
            if (comptime @hasDecl(App, "propagateGrant")) {
                try app.propagateGrant(tool_name, target_path);
                return;
            }
            try app.worker.propagateGrant(std.heap.c_allocator, tool_name, target_path);
        }

        pub fn pushEvent(app: *App, event: WorkerEvent) !void {
            if (comptime @hasDecl(App, "pushWorkerEvent")) {
                const owned = try worker_runtime.dupeWorkerEvent(std.heap.c_allocator, event);
                errdefer worker_runtime.freeWorkerEvent(std.heap.c_allocator, owned);
                try app.pushWorkerEvent(owned);
                return;
            }
            try app.worker.pushEvent(std.heap.c_allocator, event);
        }

        pub fn pushOwnedEvent(app: *App, event: WorkerEvent) !void {
            if (comptime @hasDecl(App, "pushWorkerEvent")) {
                try app.pushWorkerEvent(event);
                return;
            }
            try app.worker.pushOwnedEvent(std.heap.c_allocator, event);
        }

        pub fn pushText(app: *App, text: []const u8) !void {
            if (comptime @hasDecl(App, "pushText")) {
                try app.pushText(text);
            } else {
                try pushEvent(app, .{ .assistant_presentation = .{
                    .text = @constCast(text),
                } });
            }
            debug_trace.eventf(
                "worker",
                "assistant_chunk_received",
                .{},
                "chunk_bytes={d}",
                .{text.len},
            );
        }

        pub fn pushTable(app: *App, table: assistant_presentation.TablePayload) !void {
            try pushEvent(app, .{ .assistant_presentation = .{ .table = table } });
        }

        pub fn pushCodeBlock(app: *App, block: assistant_presentation.CodeBlockPayload) !void {
            try pushEvent(app, .{ .assistant_presentation = .{ .code_block = block } });
        }

        pub fn pushThematicRule(app: *App) !void {
            try pushEvent(app, .{ .assistant_presentation = .thematic_rule });
        }

        pub fn pushCommandOutput(
            app: *App,
            lifecycle_id: ?types.ToolLifecycleId,
            stream: command_output_content.Stream,
            chunk: []const u8,
        ) !void {
            if (chunk.len == 0) return;
            if (comptime @hasDecl(App, "pushCommandOutputWithLifecycle")) {
                try app.pushCommandOutputWithLifecycle(lifecycle_id, stream, chunk);
                return;
            }
            if (comptime @hasDecl(App, "pushCommandOutput")) {
                try app.pushCommandOutput(stream, chunk);
                return;
            }
            try pushEvent(app, .{ .command_output = .{
                .lifecycle_id = lifecycle_id,
                .stream = stream,
                .text = @constCast(chunk),
            } });
        }

        pub fn pushCommandOutputComplete(app: *App, lifecycle_id: ?types.ToolLifecycleId) !void {
            try pushEvent(app, .{ .command_output_complete = lifecycle_id });
        }

        pub fn pushToolLifecycle(
            app: *App,
            event: types.ToolLifecycleEvent,
        ) !void {
            try pushEvent(app, .{ .tool_lifecycle = event });
        }

        pub fn pushWebSearchProgress(app: *App, call_id: []const u8, progress: types.WebSearchProgress) !void {
            const turn_id = app.worker.activeTurnId();
            if (turn_id == 0 or call_id.len == 0) {
                debug_trace.logf(
                    "ui_activity",
                    "web search progress missing active lifecycle identity",
                    .{},
                );
                return;
            }
            const label = try formatWebSearchProgress(std.heap.c_allocator, progress);
            defer std.heap.c_allocator.free(label);
            try pushToolLifecycle(app, .{ .progress = .{
                .id = .{ .turn_id = turn_id, .call_id = call_id },
                .text = label,
            } });
        }

        pub fn pushWebFetchProgress(app: *App, call_id: []const u8, progress: types.WebFetchProgress) !void {
            const turn_id = app.worker.activeTurnId();
            if (turn_id == 0 or call_id.len == 0) {
                debug_trace.logf(
                    "ui_activity",
                    "web fetch progress missing active lifecycle identity",
                    .{},
                );
                return;
            }
            const label = try formatWebFetchProgress(std.heap.c_allocator, progress);
            defer std.heap.c_allocator.free(label);
            try pushToolLifecycle(app, .{ .progress = .{
                .id = .{ .turn_id = turn_id, .call_id = call_id },
                .text = label,
            } });
        }

        pub fn pushSemanticNotice(app: *App, notice: types.SemanticNotice) !void {
            try pushEvent(app, .{ .semantic_notice = notice });
        }

        pub fn pushDiffBlock(app: *App, payload: diff_mod.DiffEntryPayload) !void {
            try pushOwnedEvent(app, .{ .diff_block = payload });
        }

        /// Activate an admitted continuation without presenting another user turn.
        pub fn beginRecoveryPresentation(app: *App) void {
            app.stream = .{
                .active = true,
                .turn_started_ms = io_mod.milliTimestamp(),
            };
            _ = app.shell.worker_status_state().clear();
            app.shell.render_requests.request(.footer);
        }

        pub fn syncState(
            app: *App,
            presenter: activity_runtime.LifecyclePresenter,
        ) void {
            const snapshot = app.worker.snapshotState(app.alloc) catch return;
            defer snapshot.deinit(app.alloc);

            const was_approval_active = app.approval_prompt.isActive();
            const worker_pending_request = if (snapshot.pending_permission_request) |*request|
                request.view()
            else
                null;
            var owned_child_pending = if (worker_pending_request == null)
                if (app_session_runtime.Runtime(App).subagentHost(app)) |host|
                    host.pendingApprovalRequest(app.alloc) catch null
                else
                    null
            else
                null;
            defer if (owned_child_pending) |*pending| pending.deinit(app.alloc);
            const child_pending_request: ?permission_request.PermissionRequest =
                if (owned_child_pending) |*pending| pending.request.view() else null;
            const pending_request = worker_pending_request orelse child_pending_request;
            const management_active = if (comptime @hasField(
                @TypeOf(app.approval_prompt),
                "rule_management",
            ))
                app.approval_prompt.rule_management != null
            else
                false;
            const approval_changed = if (management_active and pending_request == null)
                false
            else
                app.approval_prompt.syncRequest(app.alloc, pending_request) catch false;
            const review_changed = if (comptime @hasDecl(@TypeOf(app.approval_prompt), "syncReview")) blk: {
                const review = if (comptime @hasField(@TypeOf(snapshot), "pending_permission_review"))
                    if (snapshot.pending_permission_review) |pending|
                        if (pending_request) |request|
                            if (pending.request_id == request.id) pending.review else null
                        else
                            null
                    else
                        null
                else
                    null;
                break :blk app.approval_prompt.syncReview(review);
            } else false;
            if (comptime @hasField(App, "approval_screen")) {
                const file_review_changed = review_changed and
                    (pending_request == null or pending_request.?.file != null);
                if (approval_changed or file_review_changed) {
                    app.approval_screen.clear();
                }
            }
            if (approval_changed or review_changed) {
                app.shell.render_requests.request(.modal);
            }
            if (!was_approval_active and app.approval_prompt.isActive()) {
                if (comptime @hasDecl(App, "dispatchAttentionRequired")) {
                    app.dispatchAttentionRequired(snapshot.active_turn_id, .permission);
                }
            }

            if (app.question_prompt.isActive()) {
                if (app.worker.snapshotPendingQuestionBatch(app.alloc) catch return) |question_snapshot| {
                    question_snapshot.deinit(app.alloc);
                } else {
                    app.question_prompt.discard(app.alloc, "worker_cleared");
                    app.shell.render_requests.request(.modal);
                }
            }

            const modal_active = app.approval_prompt.isActive() or app.question_prompt.isActive();
            const worker_events_pending = if (comptime @hasField(@TypeOf(snapshot), "pending_event_count"))
                snapshot.pending_event_count > 0
            else
                false;
            const cancellation_stops_turn = snapshot.cancel_requested and
                !snapshot.cancel_continues_turn;
            const visible_worker_active = app.stream.active and
                !cancellation_stops_turn and
                (snapshot.processing or
                    worker_events_pending or
                    snapshot.queued_count > 0);
            const awaiting_tool_terminal = snapshot.cancel_requested and
                activeToolStatusCount(presenter) > 0;
            if (!modal_active and
                !visible_worker_active and
                !awaiting_tool_terminal and
                app.stream.active)
            {
                // The worker can become idle before its final UI events reach
                // this thread. Keep any open command block until the queued
                // turn boundary finalizes it instead of discarding output.
                app.stream = .{};
                app.shell.render_requests.request(.footer);
            } else if (modal_active and !app.stream.active) {
                app.stream.active = true;
                app.stream.turn_started_ms = io_mod.milliTimestamp();
                app.shell.render_requests.request(.footer);
            }
            // Waiting on an approval or question is not thinking: freeze the
            // elapsed clock for the duration of the wait.
            activity_status.syncWaitingClock(&app.stream, modal_active, io_mod.milliTimestamp());
        }

        fn activeToolStatusCount(
            presenter: activity_runtime.LifecyclePresenter,
        ) usize {
            return presenter.snapshot().active_tool_count;
        }

        pub fn tick(
            app: *App,
            event_handlers: WorkerEventHandlers,
        ) !void {
            if (!try authorizeInteractiveAdmission(app)) return;
            try drainEvents(app, event_handlers);
            syncState(app, event_handlers.tool_lifecycle);

            const now_ms = io_mod.milliTimestamp();
            if (app.shell.worker_status_state().expire_transient(now_ms)) {
                app.shell.render_requests.request(.footer);
            }
            _ = advanceVisibleAnimation(
                app,
                event_handlers.tool_lifecycle,
                now_ms,
                std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake),
            );
        }

        fn advanceVisibleAnimation(
            app: *App,
            presenter: activity_runtime.LifecyclePresenter,
            now_ms: i64,
            now_awake: std.Io.Clock.Timestamp,
        ) bool {
            const compaction: @import("../output/compaction_activity.zig").Snapshot = if (comptime @hasDecl(@TypeOf(app.worker), "compactionActivitySnapshot")) app.worker.compactionActivitySnapshot() else .{};
            app.shell.render_requests.observeCompactionRevision(compaction.revision);
            if (comptime @hasDecl(@TypeOf(app.worker), "expireCompactionActivity")) {
                if (compaction.operation) |op| {
                    if (app.worker.expireCompactionActivity(op.id, compaction.revision, now_ms)) app.shell.render_requests.request(.footer);
                }
            }
            const compaction_active = if (compaction.operation) |op| op.active() and op.visible(now_ms) else false;
            const status_changed = app.shell.worker_status_state().refresh_route_recovery(now_awake);
            if (status_changed) app.shell.render_requests.request(.footer);
            if (!compaction_active and !app.stream.active and !app.pacer.hasCompletedAssistantPresentationTail()) {
                return status_changed;
            }
            if (app.approval_prompt.isActive() or
                app.question_prompt.isActive() or
                !app.shell.shimmer_active)
            {
                return status_changed;
            }

            var label_buf: [256]u8 = undefined;
            _ = activityShimmerLabel(app, presenter, compaction, now_ms, &label_buf) orelse return status_changed;
            const previous_deadline = app.shell.render_requests.animation_next_deadline_ms;
            if (!app.shell.render_requests.requestAnimationDue(now_ms)) return status_changed;
            debug_trace.logf(
                "frame_schedule",
                "animation_due previous_ms={d} now_ms={d} interval_ms={d}",
                .{ previous_deadline, now_ms, render_request.animation_interval_ms },
            );
            return true;
        }

        fn activityShimmerLabel(
            app: *App,
            presenter: activity_runtime.LifecyclePresenter,
            compaction: @import("../output/compaction_activity.zig").Snapshot,
            now_ms: i64,
            buf: []u8,
        ) ?[]const u8 {
            switch (app.shell.activityProjection()) {
                .turn_thinking => |thinking| if (thinking.tone != .thinking) return null,
                .none, .tool_slot => {},
            }
            switch (activity_status.compactionProjection(buf, compaction, app.stream, now_ms)) {
                .turn_thinking => |thinking| return if (thinking.tone == .thinking) thinking.label else null,
                .none, .tool_slot => {},
            }
            // Existence guard only: pass no clock so the label skips the counter.
            if (!app.stream.active and app.pacer.hasCompletedAssistantPresentationTail()) {
                return activity_status.buildTurnLabel(buf, .{ .active = true }, 0);
            }
            if (activity_status.buildTurnLabel(buf, app.stream, 0)) |label| return label;
            if (app.stream.last_activity_kind == .ask) return ui_render.ask_activity_label;
            switch (presenter.snapshot().activity) {
                .tool_slot => |slot| return slot.fallback_label,
                .none, .turn_thinking => {},
            }
            return activity_status.buildProgressLabel(buf, app.stream);
        }

        fn drainEvents(app: *App, handlers: WorkerEventHandlers) !void {
            errdefer if (comptime @hasDecl(@TypeOf(app.worker), "failPendingHistoryPublication")) {
                app.worker.failPendingHistoryPublication(error.HistoryPublicationDeliveryFailed);
            };
            const taken = app.worker.takeEventBatch();
            var batch = DetachedWorkerEventBatch.init(
                std.heap.c_allocator,
                taken.events,
            );
            app.shell.render_requests.beginFrameAdmissionBlock();
            defer app.shell.render_requests.endFrameAdmissionBlock();

            var lifecycle_cleanup_attempted = false;
            errdefer if (!lifecycle_cleanup_attempted) {
                handlers.tool_lifecycle.finish_batch(app.alloc) catch |err| {
                    debug_trace.logf(
                        "ui_activity",
                        "lifecycle cleanup after drain failure err={s}",
                        .{@errorName(err)},
                    );
                };
            };
            defer batch.deinit();

            var can_persist_finished = true;
            errdefer preserveFinishedAfterDrainFailure(app, &batch, can_persist_finished);

            var interrupted_segment = batchSegmentIsInterrupted(batch.events.items, taken.cancelled_turn_id);
            var first_event = true;

            events: while (batch.claim()) |event| {
                if (!first_event) switch (event) {
                    .begin_prompt, .begin_prompt_with_skill_bindings, .begin_presented_prompt => {
                        interrupted_segment = batchSegmentIsInterrupted(batch.claimedAndRemaining(), taken.cancelled_turn_id);
                    },
                    else => {},
                };
                first_event = false;
                var drain_owns_current = true;
                defer if (drain_owns_current) {
                    worker_runtime.freeWorkerEvent(batch.alloc, event);
                };
                if (interrupted_segment) {
                    switch (cancelledEventAdmission(
                        handlers.tool_lifecycle,
                        event,
                        batch.claimedAndRemaining(),
                    )) {
                        .admit => {},
                        .drop => {
                            debug_trace.logf(
                                "worker",
                                "cancelled worker event dropped kind={s}",
                                .{@tagName(event)},
                            );
                            continue;
                        },
                        .defer_until_closure => {
                            try retainClaimedEventAndSuffix(
                                app,
                                &batch,
                                "cancelled_tool_closure_pending",
                            );
                            drain_owns_current = false;
                            break :events;
                        },
                    }
                }

                switch (event) {
                    .begin_prompt => |prompt| {
                        if (!try requireAssistantTextDrain(handlers)) {
                            try retainClaimedEventAndSuffix(app, &batch, "assistant_text_drain_blocked");
                            drain_owns_current = false;
                            break :events;
                        }
                        resetStream(app, true);
                        app.stream.active = true;
                        app.stream.turn_started_ms = io_mod.milliTimestamp();
                        app.shell.render_requests.request(.footer);
                        try handlers.write_user_prompt(handlers.ctx, prompt);
                    },
                    .begin_prompt_with_skill_bindings => |begin| {
                        if (!try requireAssistantTextDrain(handlers)) {
                            try retainClaimedEventAndSuffix(app, &batch, "assistant_text_drain_blocked");
                            drain_owns_current = false;
                            break :events;
                        }
                        resetStream(app, true);
                        app.stream.active = true;
                        app.stream.turn_started_ms = io_mod.milliTimestamp();
                        app.shell.render_requests.request(.footer);
                        if (handlers.write_user_prompt_with_skill_bindings) |write_bound_prompt| {
                            try write_bound_prompt(handlers.ctx, begin.prompt, begin.skill_bindings, begin.skill_display_spans);
                        } else {
                            try handlers.write_user_prompt(handlers.ctx, begin.prompt);
                        }
                    },
                    .begin_presented_prompt => |turn_id| {
                        if (!try requireAssistantTextDrain(handlers)) {
                            try retainClaimedEventAndSuffix(app, &batch, "assistant_text_drain_blocked");
                            drain_owns_current = false;
                            break :events;
                        }
                        resetStream(app, true);
                        app.stream.active = true;
                        app.stream.turn_started_ms = io_mod.milliTimestamp();
                        app.shell.render_requests.request(.footer);
                        if (comptime @hasDecl(App, "acceptPresentedPrompt")) {
                            try App.acceptPresentedPrompt(app, turn_id);
                        } else {
                            return error.PresentedPromptUnsupported;
                        }
                    },
                    .append_user_feedback => |text| {
                        if (!try requireAssistantTextDrain(handlers)) {
                            try retainClaimedEventAndSuffix(app, &batch, "assistant_text_drain_blocked");
                            drain_owns_current = false;
                            break :events;
                        }
                        try handlers.write_user_prompt(handlers.ctx, .{ .text = text });
                        if (app.stream.active and app.stream.phase != .thinking) {
                            app.stream.phase = .thinking;
                            app.shell.render_requests.request(.footer);
                        }
                    },
                    .assistant_presentation => |presentation| {
                        if (presentation.requiresTextDrain() and !try requireAssistantTextDrain(handlers)) {
                            try retainClaimedEventAndSuffix(app, &batch, "assistant_text_drain_blocked");
                            drain_owns_current = false;
                            break :events;
                        }
                        switch (presentation) {
                            .text => |text| {
                                try handlers.append_text(handlers.ctx, text);
                                debug_trace.eventf(
                                    "worker",
                                    "assistant_chunk_applied",
                                    .{},
                                    "chunk_bytes={d}",
                                    .{text.len},
                                );
                            },
                            .table => |table| {
                                drain_owns_current = false;
                                try handlers.append_table(handlers.ctx, table);
                            },
                            .code_block => |block| {
                                drain_owns_current = false;
                                try handlers.append_code_block(handlers.ctx, block);
                            },
                            .thematic_rule => {
                                drain_owns_current = false;
                                try handlers.append_thematic_rule(handlers.ctx);
                            },
                        }
                    },
                    .notification => |notification| {
                        if (comptime @hasDecl(App, "queueNotification")) {
                            app.queueNotification(notification);
                        }
                    },
                    .question_requested => {
                        if (!try requireAssistantTextDrain(handlers)) {
                            try retainClaimedEventAndSuffix(app, &batch, "assistant_text_drain_blocked");
                            drain_owns_current = false;
                            break :events;
                        }
                        const pending_question = app.worker.snapshotPendingQuestionBatch(app.alloc) catch |err| {
                            try retainClaimedEventAndSuffix(app, &batch, "assistant_text_drain_blocked");
                            drain_owns_current = false;
                            return err;
                        };
                        if (pending_question) |question_snapshot| {
                            defer question_snapshot.deinit(app.alloc);
                            const was_active = app.question_prompt.isActive();
                            app.question_prompt.syncFrom(app.alloc, question_snapshot.entries) catch |err| {
                                try retainClaimedEventAndSuffix(app, &batch, "assistant_text_drain_blocked");
                                drain_owns_current = false;
                                return err;
                            };
                            if (!was_active and app.question_prompt.isActive()) {
                                app.shell.render_requests.request(.modal);
                                if (comptime @hasDecl(App, "dispatchAttentionRequired")) {
                                    app.dispatchAttentionRequired(
                                        app.worker.activeTurnId(),
                                        switch (question_snapshot.source) {
                                            .agent_question => .question,
                                            .route_recovery => .route_recovery,
                                        },
                                    );
                                }
                            }
                        }
                    },
                    .open_model_picker => {
                        if (!try requireAssistantTextDrain(handlers)) {
                            try retainClaimedEventAndSuffix(app, &batch, "assistant_text_drain_blocked");
                            drain_owns_current = false;
                            break :events;
                        }
                        try handlers.open_model_picker(handlers.ctx);
                        app.shell.render_requests.request(.modal);
                    },
                    .semantic_notice => |notice| {
                        if (!try requireAssistantTextDrain(handlers)) {
                            try retainClaimedEventAndSuffix(app, &batch, "assistant_text_drain_blocked");
                            drain_owns_current = false;
                            break :events;
                        }
                        try handlers.semantic_notice(handlers.ctx, notice);
                    },
                    .full_detail_record => |notice| {
                        try app.shell.appendFullDetailRecord(app.alloc, notice);
                    },
                    .route_recovery_status => |status| {
                        if (!try requireAssistantTextDrain(handlers)) {
                            try retainClaimedEventAndSuffix(app, &batch, "assistant_text_drain_blocked");
                            drain_owns_current = false;
                            break :events;
                        }
                        app.shell.worker_status_state().set_route_recovery(status, io_mod.milliTimestamp());
                        app.shell.render_requests.request(.footer);
                        try recordRouteRecoveryNotice(app, status);
                    },
                    .clear_route_recovery_status => {
                        if (app.shell.worker_status_state().clear_route_recovery()) {
                            app.shell.render_requests.request(.footer);
                        }
                    },
                    // The serving provider already appears on the full-screen
                    // network record; nothing interactive consumes the event
                    // today. The batch drain frees the payload.
                    .provider_resolved => {},
                    .api_status_text => |text| {
                        resetStream(app, false);
                        app.shell.worker_status_state().set_api(text, .danger);
                        app.shell.render_requests.request(.footer);
                    },
                    .credential_refreshed => |credential| {
                        try handlers.credential_refreshed(handlers.ctx, credential);
                    },
                    .command_output => |chunk| {
                        try handlers.command_output(handlers.ctx, chunk.lifecycle_id, chunk.stream, chunk.text);
                    },
                    .command_output_complete => |lifecycle_id| {
                        try handlers.command_output_complete(handlers.ctx, lifecycle_id);
                    },
                    .turn_token_update => |update| {
                        applyTurnTokenProgress(app, update);
                    },
                    .turn_phase_update => |update| {
                        applyTurnPhase(app, update);
                    },
                    .diff_block => |payload| {
                        drain_owns_current = false;
                        try handlers.diff_block(handlers.ctx, payload);
                    },
                    .context_compaction => |value| {
                        if (comptime @hasDecl(@TypeOf(app.worker), "resolveContextCompaction")) {
                            app.worker.resolveContextCompaction(
                                std.heap.c_allocator,
                                value,
                                handlers.ctx,
                                handlers.context_compaction,
                            );
                        } else {
                            try handlers.context_compaction(handlers.ctx, value);
                        }
                    },
                    .prepare_fresh_prompt => |value| {
                        const current = app_session_runtime.Runtime(App).normalizeFreshPromptPreparation(app, value);
                        app.worker.resolveFreshPrompt(std.heap.c_allocator, current, handlers.ctx, handlers.prepare_fresh_prompt);
                    },
                    .tool_lifecycle => |lifecycle| {
                        switch (lifecycle) {
                            .provisional, .authoritative_started => {
                                if (!try requireAssistantTextDrain(handlers)) {
                                    try retainClaimedEventAndSuffix(app, &batch, "assistant_text_drain_blocked");
                                    drain_owns_current = false;
                                    break :events;
                                }
                            },
                            .progress, .terminal, .turn_finished => {},
                        }
                        try applyToolLifecycle(app, handlers.tool_lifecycle, lifecycle);
                    },
                    .finish_prompt => |finished| {
                        var accepted = false;
                        errdefer if (!accepted) {
                            settleDeferredFinish(app) catch {
                                can_persist_finished = false;
                            };
                            if (can_persist_finished) persistFinishedPrompt(app, finished) catch {
                                can_persist_finished = false;
                            };
                        };
                        try flushPendingCommandOutputAtTurnBoundary(app, handlers);
                        resetStream(app, false);
                        app.shell.render_requests.request(.footer);
                        const delivery = try handlers.append_history_turn(handlers.ctx, finished);
                        accepted = true;
                        switch (delivery) {
                            .retained => {},
                            .settled => |result| switch (result) {
                                .committed => {},
                                .presentation_failed => |err| return err,
                            },
                        }
                    },
                    .session_grant => |grant| {
                        try handlers.session_grant(handlers.ctx, grant);
                    },
                    .error_text => |notice| {
                        if (!try requireAssistantTextDrain(handlers)) {
                            try retainClaimedEventAndSuffix(app, &batch, "assistant_text_drain_blocked");
                            drain_owns_current = false;
                            break :events;
                        }
                        resetStream(app, false);
                        app.shell.render_requests.request(.footer);
                        try handlers.error_text(handlers.ctx, notice);
                    },
                    .restore_failed_prompt => |prompt| {
                        // Never clobber a draft the user typed while the doomed
                        // turn was still retrying; only an empty composer gets
                        // the failed prompt back.
                        if (app.input_runtime.edit_state.input.items.len == 0) {
                            try app.input_runtime.textReplacementState().replace(app.alloc, prompt);
                            app.shell.render_requests.request(.footer);
                        } else {
                            debug_trace.logf(
                                "worker",
                                "event=restore_failed_prompt_skipped reason=composer_occupied",
                                .{},
                            );
                        }
                    },
                }
            }

            lifecycle_cleanup_attempted = true;
            try handlers.tool_lifecycle.finish_batch(app.alloc);
        }

        fn flushPendingCommandOutputAtTurnBoundary(
            app: *App,
            handlers: WorkerEventHandlers,
        ) !void {
            const Shell = @TypeOf(app.shell);
            if (comptime !@hasDecl(Shell, "openCommandOutputLifecycleId")) return;
            const lifecycle_id = app.shell.openCommandOutputLifecycleId() orelse return;
            debug_trace.logf(
                "command_output",
                "finalizing open command output at turn boundary",
                .{},
            );
            try handlers.command_output_complete(handlers.ctx, lifecycle_id);
        }

        fn requireAssistantTextDrain(handlers: WorkerEventHandlers) !bool {
            return switch (try handlers.drain_assistant_text(handlers.ctx)) {
                .drained => true,
                .blocked => false,
            };
        }

        fn retainClaimedEventAndSuffix(
            app: *App,
            batch: *DetachedWorkerEventBatch,
            reason: []const u8,
        ) !void {
            const retained = batch.claimedAndRemaining();
            try app.worker.prependOwnedEvents(batch.alloc, retained);
            batch.markClaimedAndRemainingTransferred();
            debug_trace.logf(
                "worker",
                "retained detached worker events reason={s} count={d}",
                .{ reason, retained.len },
            );
        }

        fn applyToolLifecycle(
            app: *App,
            presenter: activity_runtime.LifecyclePresenter,
            lifecycle: types.ToolLifecycleEvent,
        ) !void {
            const tool_work_active = switch (lifecycle) {
                .provisional, .authoritative_started, .progress => true,
                .terminal, .turn_finished => false,
            };
            const transition = try presenter.apply(
                app.alloc,
                lifecycle,
            );
            if (transition.applied_activity_kind) |kind| {
                applyToolActivity(&app.stream, kind);
            }
            if (comptime @hasField(App, "session_persistence")) {
                switch (lifecycle) {
                    .terminal => {
                        if (transition.terminal_record) |record| {
                            app_session_runtime.Runtime(App).recordToolTerminal(
                                app,
                                lifecycle,
                                record.captured_command,
                            );
                        }
                    },
                    .provisional, .authoritative_started, .progress, .turn_finished => {},
                }
            }

            const focused_activity_kind = transition.snapshot.focused_activity_kind;
            if (tool_work_active) app.stream.phase = .running;
            app.stream.last_activity_kind = focused_activity_kind;
            if (transition.focus_changed()) {
                app.shell.render_requests.requestAnimationReset();
            }
            app.shell.render_requests.request(.footer);
        }

        fn resetStream(app: *App, clear_route_recovery: bool) void {
            app.stream = .{};
            if (clear_route_recovery and app.shell.worker_status_state().clear()) {
                app.shell.render_requests.request(.footer);
            }
            app.shell.resetCommandOutputDisplay(app.alloc, "worker inactive");
        }

        fn applyToolActivity(stream: *types.StreamState, kind: types.ToolActivityKind) void {
            stream.chunks += 1;
            stream.last_activity_kind = kind;
            switch (kind) {
                .read => stream.read_count += 1,
                .list => stream.list_count += 1,
                .write => stream.write_count += 1,
                .edit => stream.edit_count += 1,
                .open => stream.open_count += 1,
                .command => stream.command_count += 1,
                .subagent => stream.subagent_count += 1,
                .ask => {},
            }
        }

        fn applyTurnTokenProgress(app: *App, update: types.TurnTokenProgress) void {
            if (!app.stream.active) return;

            const changed = !std.meta.eql(app.stream.token_progress, update);
            app.stream.token_progress = update;

            // An armed animation tick already repaints the label within 50ms.
            const animation_armed = app.shell.render_requests.animation_visible and
                app.shell.render_requests.animation_next_deadline_ms != 0;
            if (changed and !animation_armed) app.shell.render_requests.request(.footer);
        }

        fn applyTurnPhase(app: *App, update: types.TurnPhaseUpdate) void {
            if (!app.stream.active or update.turn_id != app.worker.activeTurnId()) return;
            if (update.step_id < app.stream.phase_step_id) return;

            const changed = app.stream.phase != update.phase;
            app.stream.phase = update.phase;
            app.stream.phase_step_id = update.step_id;
            if (changed) app.shell.render_requests.request(.footer);
        }
    };
}

fn formatWebSearchProgress(alloc: std.mem.Allocator, progress: types.WebSearchProgress) ![]u8 {
    var query_buf: [160]u8 = undefined;
    return switch (progress) {
        .query_started => |query| std.fmt.allocPrint(
            alloc,
            "● Searching\x1b[0m {s}{s}\x1b[0m",
            .{ shared_theme.current().tool_stdout_style, text_utils.clippedLabel(&query_buf, query, 120) },
        ),
        .results_received => |entry| std.fmt.allocPrint(
            alloc,
            "● Found {d} result{s}\x1b[0m {s}{s}\x1b[0m",
            .{ entry.result_count, if (entry.result_count == 1) "" else "s", shared_theme.current().tool_stdout_style, text_utils.clippedLabel(&query_buf, entry.query, 120) },
        ),
    };
}

fn formatWebFetchProgress(alloc: std.mem.Allocator, progress: types.WebFetchProgress) ![]u8 {
    var url_buf: [types.WebFetchCompletion.max_url_len]u8 = undefined;
    return switch (progress) {
        .fetching => |url| std.fmt.allocPrint(
            alloc,
            "● Fetching\x1b[0m {s}{s}\x1b[0m",
            .{ shared_theme.current().tool_stdout_style, text_utils.clippedLabel(&url_buf, url, 120) },
        ),
        .converting => |url| std.fmt.allocPrint(
            alloc,
            "● Converting\x1b[0m {s}{s}\x1b[0m",
            .{ shared_theme.current().tool_stdout_style, text_utils.clippedLabel(&url_buf, url, 120) },
        ),
    };
}

const FakeSnapshot = struct {
    processing: bool = false,
    active_turn_id: u64 = 0,
    queued_count: usize = 0,
    pending_event_count: usize = 0,
    cancel_requested: bool = false,
    cancel_continues_turn: bool = false,
    pending_permission_request: ?permission_request.OwnedPermissionRequest = null,
    pending_permission_review: ?worker_runtime.PendingPermissionReview = null,

    fn deinit(self: FakeSnapshot, alloc: std.mem.Allocator) void {
        if (self.pending_permission_request) |request| {
            var owned = request;
            owned.deinit(alloc);
        }
    }
};

const FakeQuestionSnapshot = struct {
    entries: []const u8 = "",
    source: worker_runtime.QuestionPromptSource = .agent_question,

    fn deinit(self: FakeQuestionSnapshot, alloc: std.mem.Allocator) void {
        _ = self;
        _ = alloc;
    }
};

const FakeWorker = struct {
    compaction: @import("../output/compaction_activity.zig").State = .{},
    compaction_reads: usize = 0,

    worker_cancel_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    events: std.ArrayList(WorkerEvent) = .empty,
    queued_count: usize = 0,
    processing: bool = false,
    cancel_continues_turn: bool = false,
    pending_permission_request: ?permission_request.PermissionRequest = null,
    pending_permission_review: ?*const diff_mod.FileReview = null,
    pending_question: bool = false,
    pending_question_source: worker_runtime.QuestionPromptSource = .agent_question,
    active_turn_id: u64 = 1,
    propagated_history_turns: usize = 0,
    propagated_grants: usize = 0,
    reset_cancel_after_take_events: bool = false,
    admission_snapshot: worker_runtime.InteractiveAdmissionSnapshot = .open,

    fn compactionActivitySnapshot(self: *FakeWorker) @import("../output/compaction_activity.zig").Snapshot {
        self.compaction_reads += 1;
        return self.compaction.snapshot;
    }

    fn expireCompactionActivity(self: *FakeWorker, id: @import("../output/compaction_activity.zig").OperationId, revision: u64, now_ms: i64) bool {
        return self.compaction.expire(id, revision, now_ms);
    }

    fn resolveFreshPrompt(_: *FakeWorker, alloc: std.mem.Allocator, value: worker_runtime.FreshPromptPreparation, ctx: *anyopaque, handler: worker_runtime.FreshPromptHandler) void {
        var result = handler(ctx, value) catch return;
        result.deinit(alloc);
    }

    fn deinit(self: *FakeWorker) void {
        for (self.events.items) |event| worker_runtime.freeWorkerEvent(std.heap.c_allocator, event);
        self.events.deinit(std.heap.c_allocator);
    }

    fn pushEvent(self: *FakeWorker, alloc: std.mem.Allocator, event: WorkerEvent) !void {
        const owned = try worker_runtime.dupeWorkerEvent(alloc, event);
        errdefer worker_runtime.freeWorkerEvent(alloc, owned);
        try self.pushOwnedEvent(alloc, owned);
    }

    fn pushOwnedEvent(self: *FakeWorker, alloc: std.mem.Allocator, event: WorkerEvent) !void {
        try self.events.append(alloc, event);
    }

    fn prependOwnedEvents(
        self: *FakeWorker,
        alloc: std.mem.Allocator,
        events: []const WorkerEvent,
    ) !void {
        try self.events.insertSlice(alloc, 0, events);
    }

    fn takeEvents(self: *FakeWorker) std.ArrayList(WorkerEvent) {
        const events = self.events;
        self.events = .empty;
        if (self.reset_cancel_after_take_events) {
            self.reset_cancel_after_take_events = false;
            self.worker_cancel_requested.store(false, .seq_cst);
        }
        return events;
    }

    fn takeEventBatch(self: *FakeWorker) worker_runtime.WorkerEventBatch {
        const cancel_requested = self.worker_cancel_requested.load(.seq_cst);
        return .{
            .events = self.takeEvents(),
            .cancelled_turn_id = if (cancel_requested and self.active_turn_id != 0) self.active_turn_id else null,
        };
    }

    fn snapshotState(self: *FakeWorker, alloc: std.mem.Allocator) !FakeSnapshot {
        return .{
            .processing = self.processing,
            .active_turn_id = self.active_turn_id,
            .queued_count = self.queued_count,
            .pending_event_count = self.events.items.len,
            .cancel_requested = self.worker_cancel_requested.load(.seq_cst),
            .cancel_continues_turn = self.cancel_continues_turn,
            .pending_permission_request = if (self.pending_permission_request) |request|
                try permission_request.OwnedPermissionRequest.dupe(alloc, request)
            else
                null,
            .pending_permission_review = if (self.pending_permission_request) |request|
                if (self.pending_permission_review) |review|
                    .{
                        .request_id = request.id,
                        .review = review,
                    }
                else
                    null
            else
                null,
        };
    }

    fn interactiveAdmissionSnapshot(self: *FakeWorker) worker_runtime.InteractiveAdmissionSnapshot {
        return self.admission_snapshot;
    }

    fn snapshotPendingQuestionBatch(self: *FakeWorker, alloc: std.mem.Allocator) !?FakeQuestionSnapshot {
        _ = alloc;
        return if (self.pending_question) FakeQuestionSnapshot{
            .source = self.pending_question_source,
        } else null;
    }

    fn syncQueuedPromptModel(self: *FakeWorker, alloc: std.mem.Allocator, model: []const u8) !void {
        _ = self;
        _ = alloc;
        _ = model;
    }

    fn syncQueuedPromptPermissionSnapshot(self: *FakeWorker, snapshot: worker_runtime.PermissionSnapshot) void {
        _ = self;
        _ = snapshot;
    }

    fn syncQueuedPromptPermissionState(self: *FakeWorker, alloc: std.mem.Allocator, grants: []const types.PermissionGrant, snapshot: worker_runtime.PermissionSnapshot) !void {
        _ = self;
        _ = alloc;
        _ = grants;
        _ = snapshot;
    }

    fn activeTurnId(self: *FakeWorker) u64 {
        return self.active_turn_id;
    }

    fn propagateHistoryTurn(self: *FakeWorker, alloc: std.mem.Allocator, turn: types.HistoryTurn, max_history_turns: usize) !void {
        _ = alloc;
        _ = turn;
        _ = max_history_turns;
        self.propagated_history_turns += 1;
    }

    fn propagateGrant(self: *FakeWorker, alloc: std.mem.Allocator, tool_name: []const u8, target_path: []const u8) !void {
        _ = alloc;
        _ = tool_name;
        _ = target_path;
        self.propagated_grants += 1;
    }
};

const FakeApprovalPrompt = struct {
    sync_count: usize = 0,
    force_active: bool = false,
    request: ?permission_request.OwnedPermissionRequest = null,
    review: ?*const diff_mod.FileReview = null,
    review_request_id: u64 = 0,

    fn deinit(self: *FakeApprovalPrompt, alloc: std.mem.Allocator) void {
        if (self.request) |*request| request.deinit(alloc);
        self.request = null;
    }

    fn syncRequest(
        self: *FakeApprovalPrompt,
        alloc: std.mem.Allocator,
        request: ?permission_request.PermissionRequest,
    ) permission_request.RequestCloneError!bool {
        self.sync_count += 1;
        if (request) |value| {
            const owned = try permission_request.OwnedPermissionRequest.dupe(alloc, value);
            if (self.request) |*current| current.deinit(alloc);
            self.request = owned;
            return true;
        }
        const changed = self.request != null;
        if (self.request) |*current| current.deinit(alloc);
        self.request = null;
        self.review = null;
        self.review_request_id = 0;
        return changed;
    }

    fn syncReview(self: *FakeApprovalPrompt, review: ?*const diff_mod.FileReview) bool {
        const request = self.request orelse {
            const changed = self.review != null;
            self.review = null;
            self.review_request_id = 0;
            return changed;
        };
        if (self.review == review and self.review_request_id == request.id) return false;
        self.review = review;
        self.review_request_id = if (review == null) 0 else request.id;
        return true;
    }

    fn isActive(self: FakeApprovalPrompt) bool {
        return self.force_active or self.request != null;
    }
};

const FakeQuestionPrompt = struct {
    active: bool = false,
    activate_on_sync: bool = true,
    sync_count: usize = 0,
    clear_count: usize = 0,

    fn syncFrom(self: *FakeQuestionPrompt, alloc: std.mem.Allocator, entries: anytype) !void {
        _ = alloc;
        _ = entries;
        self.sync_count += 1;
        self.active = self.activate_on_sync;
    }

    fn discard(
        self: *FakeQuestionPrompt,
        alloc: std.mem.Allocator,
        reason: []const u8,
    ) void {
        _ = alloc;
        _ = reason;
        self.clear_count += 1;
        self.active = false;
    }

    fn isActive(self: FakeQuestionPrompt) bool {
        return self.active;
    }
};

const FakeCommandOutputDisplay = struct {
    touched: bool = false,
};

const FakeShell = struct {
    command_output_display: FakeCommandOutputDisplay = .{},
    shimmer_active: bool = false,
    native_history_active: bool = false,
    render_requests: render_request.RenderRequestState = .{},
    lifecycle: transcript_runtime.TranscriptRuntime = .{
        .layout = .{
            .rows = 24,
            .cols = 80,
            .content_bottom = 20,
            .divider_top_row = 21,
            .input_row = 22,
            .divider_bottom_row = 23,
            .hint_row = 24,
        },
    },
    raw_entries: std.ArrayList([]u8) = .empty,
    updated_entries: usize = 0,
    last_class: transcript_runtime.RawEntryClass = .unknown_raw,
    trim_calls: usize = 0,
    fail_next_update: bool = false,

    fn deinit(self: *FakeShell, alloc: std.mem.Allocator) void {
        self.lifecycle.deinit(alloc);
        for (self.raw_entries.items) |entry| alloc.free(entry);
        self.raw_entries.deinit(alloc);
    }

    fn nativeHistoryActive(self: *const FakeShell) bool {
        return self.native_history_active;
    }

    fn trimTrailingBlankLines(self: *FakeShell) void {
        self.trim_calls += 1;
    }

    fn appendRawTranscriptEntry(self: *FakeShell, alloc: std.mem.Allocator, line: []const u8) !u32 {
        try self.raw_entries.append(alloc, try alloc.dupe(u8, line));
        return @intCast(self.raw_entries.items.len);
    }

    fn appendFullDetailRecord(self: *FakeShell, alloc: std.mem.Allocator, notice: types.SemanticNotice) !void {
        return self.lifecycle.appendFullDetailRecord(alloc, notice);
    }

    fn appendRawTranscriptEntryClassified(self: *FakeShell, alloc: std.mem.Allocator, line: []const u8, class: transcript_runtime.RawEntryClass) !u32 {
        self.last_class = class;
        return self.appendRawTranscriptEntry(alloc, line);
    }

    fn updateRawBytesEntry(self: *FakeShell, alloc: std.mem.Allocator, entry_id: u32, line: []const u8) !bool {
        const index = entry_id - 1;
        alloc.free(self.raw_entries.items[index]);
        self.raw_entries.items[index] = try alloc.dupe(u8, line);
        self.updated_entries += 1;
        return true;
    }

    fn setRawEntryClass(self: *FakeShell, entry_id: u32, class: transcript_runtime.RawEntryClass) bool {
        _ = entry_id;
        self.last_class = class;
        return true;
    }

    pub fn applyToolLifecycle(
        self: *FakeShell,
        alloc: std.mem.Allocator,
        event: types.ToolLifecycleEvent,
    ) !?types.ToolActivityKind {
        if (self.fail_next_update) {
            switch (event) {
                .progress, .terminal, .turn_finished => {
                    self.fail_next_update = false;
                    return error.InjectedTranscriptUpdateFailure;
                },
                .provisional, .authoritative_started => {},
            }
        }
        return self.lifecycle.applyToolLifecycle(alloc, event);
    }

    pub fn finishLifecycleBatch(
        self: *FakeShell,
        alloc: std.mem.Allocator,
    ) !void {
        return self.lifecycle.finishLifecycleBatch(alloc);
    }

    pub fn activityProjection(
        self: *const FakeShell,
    ) activity_runtime.ActivityProjection {
        return self.lifecycle.activityProjection();
    }

    pub fn worker_status_state(self: *FakeShell) *worker_status.State {
        return self.lifecycle.worker_status_state();
    }

    pub fn focusedToolEntryId(self: *const FakeShell) ?u32 {
        return self.lifecycle.focusedToolEntryId();
    }

    pub fn focusedToolActivityKind(
        self: *const FakeShell,
    ) ?types.ToolActivityKind {
        return self.lifecycle.focusedToolActivityKind();
    }

    pub fn activeToolActivityCount(self: *const FakeShell) usize {
        return self.lifecycle.activeToolActivityCount();
    }

    fn toolActivityRecord(
        self: *const FakeShell,
        id: types.ToolLifecycleId,
    ) ?activity_runtime.ToolPresentationRecord {
        return self.lifecycle.toolActivityRecord(id);
    }

    fn toolActivityRecordCount(self: *const FakeShell) usize {
        return self.lifecycle.toolActivityRecordCount();
    }

    fn toolStatusEntryLabel(self: *const FakeShell, entry_id: u32) ?[]const u8 {
        return self.lifecycle.toolStatusEntryLabel(entry_id);
    }

    fn finalizedToolTurnWatermark(self: *const FakeShell) u64 {
        return self.lifecycle.finalizedToolTurnWatermark();
    }

    fn lifecyclePinCount(self: *const FakeShell) usize {
        return self.lifecycle.lifecyclePinCount();
    }

    fn replaceableEntryId(self: *FakeShell) ?u32 {
        _ = self;
        return null;
    }

    fn resetCommandOutputDisplay(self: *FakeShell, alloc: std.mem.Allocator, reason: []const u8) void {
        _ = alloc;
        _ = reason;
        self.command_output_display = .{};
    }

    fn openCommandOutputLifecycleId(self: *const FakeShell) ?types.ToolLifecycleId {
        return self.lifecycle.openCommandOutputLifecycleId();
    }
};

const FakePacer = struct {
    flushed: usize = 0,
    completed_assistant_presentation_tail: bool = false,

    fn flushPendingText(self: *FakePacer, callbacks: anytype) !void {
        _ = callbacks;
        self.flushed += 1;
    }

    fn hasCompletedAssistantPresentationTail(self: *const FakePacer) bool {
        return self.completed_assistant_presentation_tail;
    }
};

const FakeSubagents = struct {
    view_active: bool = false,
    child_busy: bool = false,
    child_shell: FakeShell = .{},
    child_render_requests: render_request.RenderRequestState = .{},

    fn isViewActive(self: FakeSubagents) bool {
        return self.view_active;
    }

    fn childConversationRuntime(self: *FakeSubagents) ?*FakeShell {
        if (!self.view_active) return null;
        return &self.child_shell;
    }

    fn activeRenderRequests(self: *FakeSubagents) *render_request.RenderRequestState {
        return &self.child_render_requests;
    }

    fn deinit(self: *FakeSubagents, alloc: std.mem.Allocator) void {
        self.child_shell.deinit(alloc);
    }
};

const FakeApp = struct {
    alloc: std.mem.Allocator,
    session_persistence: app_session_runtime.Persistence = .{},
    worker: FakeWorker = .{},
    approval_prompt: FakeApprovalPrompt = .{},
    approval_screen: interaction_state.ApprovalScreenState = .{},
    question_prompt: FakeQuestionPrompt = .{},
    input_runtime: InputRuntime = .{},
    stream: types.StreamState = .{},
    shell: FakeShell = .{},
    pacer: FakePacer = .{},
    subagents: FakeSubagents = .{},
    should_exit: bool = false,
    frame_commits: usize = 0,
    transcript: std.ArrayList(u8) = .empty,
    replaceable_count: usize = 0,
    replaceable_silent_count: usize = 0,
    replace_count: usize = 0,
    replace_silent_count: usize = 0,
    last_class: transcript_runtime.RawEntryClass = .unknown_raw,
    attention_count: usize = 0,
    last_attention_turn_id: u64 = 0,
    last_attention_kind: ?@import("../hooks/hooks.zig").AttentionKind = null,
    persisted_finishes: std.ArrayList(types.FinishedPrompt) = .empty,
    finish_persistence_error: ?anyerror = null,

    fn init(alloc: std.mem.Allocator) FakeApp {
        return .{ .alloc = alloc };
    }

    fn deinit(self: *FakeApp) void {
        for (self.persisted_finishes.items) |finished| types.freeFinishedPrompt(self.alloc, finished);
        self.persisted_finishes.deinit(self.alloc);
        self.session_persistence.deinit(self.alloc);
        self.worker.deinit();
        self.approval_prompt.deinit(self.alloc);
        self.input_runtime.deinit(self.alloc);
        self.shell.deinit(self.alloc);
        self.subagents.deinit(self.alloc);
        self.transcript.deinit(self.alloc);
    }

    fn pacerCallbacks(self: *FakeApp) void {
        _ = self;
    }

    pub fn appendFinishedPrompt(self: *FakeApp, finished: types.FinishedPrompt) !void {
        if (self.finish_persistence_error) |err| return err;
        const owned = try types.dupeFinishedPrompt(self.alloc, finished);
        errdefer types.freeFinishedPrompt(self.alloc, owned);
        try self.persisted_finishes.append(self.alloc, owned);
        if (finished.snapshot_file_ownership) |ownership| ownership.transfer();
    }

    fn writeTranscript(self: *FakeApp, text: []const u8, record: bool) !void {
        _ = record;
        try self.transcript.appendSlice(self.alloc, text);
    }

    fn writeDomainNotice(self: *FakeApp, notice: types.SemanticNotice, _: bool) !void {
        try self.transcript.appendSlice(self.alloc, notice.topic);
        try self.transcript.appendSlice(self.alloc, ":");
        try self.transcript.appendSlice(self.alloc, notice.body);
    }

    fn writeTranscriptClassified(self: *FakeApp, text: []const u8, record: bool, class: transcript_runtime.RawEntryClass) !void {
        self.last_class = class;
        try self.writeTranscript(text, record);
    }

    fn appendReplaceableTranscriptLine(self: *FakeApp, text: []const u8) !u32 {
        self.replaceable_count += 1;
        try self.transcript.appendSlice(self.alloc, text);
        return @intCast(self.replaceable_count);
    }

    fn appendReplaceableTranscriptLineClassified(self: *FakeApp, text: []const u8, class: transcript_runtime.RawEntryClass) !u32 {
        self.last_class = class;
        return self.appendReplaceableTranscriptLine(text);
    }

    fn appendReplaceableTranscriptLineSilent(self: *FakeApp, text: []const u8) !u32 {
        self.replaceable_silent_count += 1;
        try self.transcript.appendSlice(self.alloc, text);
        return @intCast(self.replaceable_silent_count);
    }

    fn appendReplaceableTranscriptLineSilentClassified(self: *FakeApp, text: []const u8, class: transcript_runtime.RawEntryClass) !u32 {
        self.last_class = class;
        return self.appendReplaceableTranscriptLineSilent(text);
    }

    fn replaceTrailingTranscriptLine(self: *FakeApp, text: []const u8) !bool {
        self.replace_count += 1;
        try self.transcript.appendSlice(self.alloc, text);
        return false;
    }

    fn replaceTrailingTranscriptLineSilent(self: *FakeApp, text: []const u8) !bool {
        self.replace_silent_count += 1;
        try self.transcript.appendSlice(self.alloc, text);
        return false;
    }

    fn dispatchAttentionRequired(
        self: *FakeApp,
        turn_id: u64,
        kind: @import("../hooks/hooks.zig").AttentionKind,
    ) void {
        self.attention_count += 1;
        self.last_attention_turn_id = turn_id;
        self.last_attention_kind = kind;
    }
};

const NoopBridge = struct {
    fn user(_: *anyopaque, _: types.UserTurn) !void {}
    fn text(_: *anyopaque, _: []const u8) !void {}
    fn drain(_: *anyopaque) !AssistantTextDrainResult {
        return .drained;
    }
    fn openModelPicker(_: *anyopaque) !void {}
    fn notice(_: *anyopaque, _: types.SemanticNotice) !void {}
    fn output(_: *anyopaque, _: ?types.ToolLifecycleId, _: command_output_content.Stream, _: []const u8) !void {}
    fn outputComplete(_: *anyopaque, _: ?types.ToolLifecycleId) !void {}
    fn diff(_: *anyopaque, payload: @import("../output/diff.zig").DiffEntryPayload) !void {
        @import("../output/diff.zig").freeDiffEntryPayload(std.heap.c_allocator, payload);
    }
    fn history(_: *anyopaque, _: types.FinishedPrompt) !HistoryDelivery {
        return .{ .settled = .committed };
    }
    fn grant(_: *anyopaque, _: types.PermissionGrant) !void {}
    fn err(_: *anyopaque, _: types.SemanticNotice) !void {}

    fn lifecycleSnapshot(raw: *anyopaque) activity_runtime.LifecycleSnapshot {
        const app: *FakeApp = @ptrCast(@alignCast(raw));
        return .{
            .finalized_turn_watermark = app.shell.finalizedToolTurnWatermark(),
            .active_tool_count = app.shell.activeToolActivityCount(),
            .focused_entry_id = app.shell.focusedToolEntryId(),
            .focused_activity_kind = app.shell.focusedToolActivityKind(),
            .activity = app.shell.activityProjection(),
        };
    }

    fn lifecycleRecord(
        raw: *anyopaque,
        id: types.ToolLifecycleId,
    ) ?activity_runtime.ToolPresentationRecord {
        const app: *FakeApp = @ptrCast(@alignCast(raw));
        return app.shell.toolActivityRecord(id);
    }

    fn applyLifecycle(
        raw: *anyopaque,
        alloc: std.mem.Allocator,
        event: types.ToolLifecycleEvent,
    ) !activity_runtime.LifecycleTransition {
        const app: *FakeApp = @ptrCast(@alignCast(raw));
        const previous_focused_entry_id = app.shell.focusedToolEntryId();
        const applied_activity_kind = try app.shell.applyToolLifecycle(alloc, event);
        return .{
            .previous_focused_entry_id = previous_focused_entry_id,
            .snapshot = lifecycleSnapshot(raw),
            .applied_activity_kind = applied_activity_kind,
            .terminal_record = switch (event) {
                .terminal => |terminal| app.shell.toolActivityRecord(terminal.id),
                .provisional, .authoritative_started, .progress, .turn_finished => null,
            },
        };
    }

    fn finishLifecycleBatch(raw: *anyopaque, alloc: std.mem.Allocator) !void {
        const app: *FakeApp = @ptrCast(@alignCast(raw));
        try app.shell.finishLifecycleBatch(alloc);
    }

    fn lifecyclePresenter(app: *FakeApp) activity_runtime.LifecyclePresenter {
        return .{
            .ctx = @ptrCast(app),
            .snapshot_fn = lifecycleSnapshot,
            .record_fn = lifecycleRecord,
            .apply_fn = applyLifecycle,
            .finish_batch_fn = finishLifecycleBatch,
        };
    }

    fn handlers(app: *FakeApp) WorkerEventHandlers {
        return .{
            .ctx = undefined,
            .tool_lifecycle = lifecyclePresenter(app),
            .write_user_prompt = user,
            .append_text = text,
            .drain_assistant_text = drain,
            .open_model_picker = openModelPicker,
            .semantic_notice = notice,
            .command_output = output,
            .command_output_complete = outputComplete,
            .diff_block = diff,
            .append_history_turn = history,
            .session_grant = grant,
            .error_text = err,
        };
    }
};

const PacedTranscriptBridge = struct {
    app: *FakeApp,
    pacer: assistant_pacer.AssistantPacer = .{},
    metrics: types.Metrics = .{},
    drain_count: usize = 0,
    user_prompt_count: usize = 0,
    pacer_pending_when_user_prompt_written: bool = false,
    assistant_present_when_user_prompt_written: bool = false,
    notice_count: usize = 0,
    history_count: usize = 0,
    finish_count: usize = 0,
    order: [8]u8 = undefined,
    order_len: usize = 0,

    fn init(app: *FakeApp) PacedTranscriptBridge {
        return .{ .app = app };
    }

    fn deinit(self: *PacedTranscriptBridge) void {
        self.pacer.deinit(self.app.alloc);
    }

    fn callbacks(self: *PacedTranscriptBridge) assistant_pacer.TickCallbacks {
        return .{
            .emit_ctx = @ptrCast(self),
            .emit_fn = emit,
            .finish_ctx = @ptrCast(self),
            .finish_fn = finish,
        };
    }

    fn handlers(self: *PacedTranscriptBridge) WorkerEventHandlers {
        var bridge = NoopBridge.handlers(self.app);
        bridge.ctx = @ptrCast(self);
        bridge.write_user_prompt = writeUserPrompt;
        bridge.append_text = appendText;
        bridge.drain_assistant_text = drainAssistantText;
        bridge.semantic_notice = semanticNotice;
        bridge.append_history_turn = appendHistoryTurn;
        return bridge;
    }

    fn tickPacer(self: *PacedTranscriptBridge, now_ns: i128) !void {
        try self.pacer.tick(self.app.alloc, now_ns, self.callbacks());
    }

    fn record(self: *PacedTranscriptBridge, value: u8) void {
        if (self.order_len < self.order.len) {
            self.order[self.order_len] = value;
            self.order_len += 1;
        }
    }

    fn orderSlice(self: *const PacedTranscriptBridge) []const u8 {
        return self.order[0..self.order_len];
    }

    fn appendText(raw: *anyopaque, text: []const u8) !void {
        const self: *PacedTranscriptBridge = @ptrCast(@alignCast(raw));
        try self.pacer.enqueue(self.app.alloc, text);
    }

    fn writeUserPrompt(raw: *anyopaque, _: types.UserTurn) !void {
        const self: *PacedTranscriptBridge = @ptrCast(@alignCast(raw));
        self.user_prompt_count += 1;
        self.record('U');
        self.pacer_pending_when_user_prompt_written = self.pacer.hasPending();
        self.assistant_present_when_user_prompt_written =
            self.app.shell.lifecycle.entries.items.len > 0 and
            self.app.shell.lifecycle.entries.items[self.app.shell.lifecycle.entries.items.len - 1] == .assistant_turn;
    }

    fn drainAssistantText(raw: *anyopaque) !AssistantTextDrainResult {
        const self: *PacedTranscriptBridge = @ptrCast(@alignCast(raw));
        self.drain_count += 1;
        try self.pacer.flushPresentationAtBoundary(
            self.app.alloc,
            0,
            self.callbacks(),
        );
        return .drained;
    }

    fn semanticNotice(raw: *anyopaque, _: types.SemanticNotice) !void {
        const self: *PacedTranscriptBridge = @ptrCast(@alignCast(raw));
        self.notice_count += 1;
    }

    fn appendHistoryTurn(raw: *anyopaque, finished: types.FinishedPrompt) !HistoryDelivery {
        const self: *PacedTranscriptBridge = @ptrCast(@alignCast(raw));
        self.history_count += 1;
        if (try self.pacer.deferFinish(self.app.alloc, finished)) return .retained;
        self.finish_count += 1;
        return .{ .settled = .committed };
    }

    fn emit(raw: *anyopaque, text: []const u8) !void {
        const self: *PacedTranscriptBridge = @ptrCast(@alignCast(raw));
        _ = try self.app.shell.lifecycle.streamAssistantChunk(
            self.app.alloc,
            &self.metrics,
            text,
        );
    }

    fn finish(raw: *anyopaque, _: types.FinishedPrompt) !assistant_pacer.FinishResult {
        const self: *PacedTranscriptBridge = @ptrCast(@alignCast(raw));
        self.finish_count += 1;
        self.record('F');
        return .committed;
    }
};

fn tickNoop(app: *FakeApp) !void {
    try Runtime(FakeApp).tick(app, NoopBridge.handlers(app));
}

fn test_awake_timestamp(milliseconds: i64) std.Io.Clock.Timestamp {
    return .{
        .clock = .awake,
        .raw = .fromNanoseconds(@as(i96, milliseconds) * std.time.ns_per_ms),
    };
}

fn queueLifecycle(app: *FakeApp, event: types.ToolLifecycleEvent) !void {
    try app.worker.pushEvent(std.heap.c_allocator, .{ .tool_lifecycle = event });
}

fn queueToolStart(
    app: *FakeApp,
    turn_id: u64,
    call_id: []const u8,
    tool_name: []const u8,
) !void {
    try queueLifecycle(app, .{ .authoritative_started = .{
        .id = .{ .turn_id = turn_id, .call_id = call_id },
        .reconciles_provisional_call_id = null,
        .tool_name = tool_name,
        .activity_kind = if (std.mem.eql(u8, tool_name, "read_file"))
            .read
        else if (std.mem.eql(u8, tool_name, "write_file"))
            .write
        else
            .command,
    } });
}

fn queueToolTerminal(
    app: *FakeApp,
    turn_id: u64,
    call_id: []const u8,
    kind: types.ToolOutcomeKind,
    summary: []const u8,
) !void {
    try queueLifecycle(app, .{ .terminal = .{
        .id = .{ .turn_id = turn_id, .call_id = call_id },
        .outcome = .{ .kind = kind, .summary = summary },
    } });
}

fn queueTurnFinished(
    app: *FakeApp,
    turn_id: u64,
    outcome: types.TurnPresentationOutcome,
) !void {
    try queueLifecycle(app, .{ .turn_finished = .{
        .turn_id = turn_id,
        .outcome = outcome,
    } });
}
