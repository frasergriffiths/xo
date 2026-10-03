const std = @import("std");
const builtin = @import("builtin");
const builtin_context = @import("../../../../builtins/context.zig");
const builtin_tools = @import("../../../../builtins/tools.zig");
const types = @import("../../../shared/types.zig");
const worker_runtime = @import("../../worker_runtime.zig");
const session_runtime = @import("../../../session/session.zig");
const session_codec = @import("../../../session/session_codec.zig");
const session_child_store = @import("../../../session/session_child_store.zig");
const result_store = @import("../../../session/result_store.zig");
const debug_trace = @import("../../../shared/debug_trace.zig");
const image_attachments = @import("../../../images/image_attachments.zig");
const io_mod = @import("../../../shared/io.zig");
const diff = @import("../../../output/diff.zig");
const file_mutation = @import("../../../tooling/file_mutation.zig");
const command_result_mapping = @import("../../../tooling/command_result_mapping.zig");
const tool_dispatch = @import("../../../tooling/tool_dispatch.zig");
const model_tool_schema = @import("../../../tooling/model_tool_schema.zig");
const tool_specs = @import("../../../tooling/tool_specs.zig");
const tool_result_errors = @import("../../../tooling/tool_result_errors.zig");
const context_contract = @import("../../../workspace/context_contract.zig");
const lifecycle_hooks = @import("../../../hooks/hooks.zig");
const runtime_parallel_execution = @import("../parallel_execution.zig");
const runtime_config = @import("../config.zig");
const runtime_lifecycle = @import("../lifecycle.zig");
const runtime_deps = @import("../deps.zig");
const runtime_orchestrator = @import("../orchestrator.zig");
const runtime_tool_admission = @import("../tool_admission.zig");
const runtime_tool_batch = @import("../tool_batch.zig");
const runtime_tool_contracts = @import("../tool_contracts.zig");
const runtime_tool_presentation = @import("../tool_presentation.zig");
const runtime_telemetry = @import("../telemetry.zig");
const command_admission = @import("../../../permissions/command_admission.zig");
const permission_auto_classifier = @import("../../../permissions/auto_classifier.zig");
const auto_classifier_context = @import("../../../permissions/auto_classifier_context.zig");

const test_support = @import("support.zig");

const ChatMessage = types.ChatMessage;
const PermissionGrant = types.PermissionGrant;
const ToolCall = types.ToolCall;

const FakeCompletion = test_support.FakeCompletion;
const FakeGateway = test_support.FakeGateway;
const FakeAgentRuntimeDeps = test_support.FakeAgentRuntimeDeps;
const PreToolUseTestHandler = test_support.PreToolUseTestHandler;
const PromptFixture = test_support.PromptFixture;

const runFakePrompt = test_support.runFakePrompt;
const runFakePromptWithLifecycle = test_support.runFakePromptWithLifecycle;
const registerPreToolUseTestHandler = test_support.registerPreToolUseTestHandler;
const testLifecycleContext = test_support.testLifecycleContext;
const prepareToolCallForLifecycle = runtime_lifecycle.prepareToolCallForLifecycle;
const expectBodyContains = test_support.expectBodyContains;
const expectBodyNotContains = test_support.expectBodyNotContains;
const expectBodyContainsInOrder = test_support.expectBodyContainsInOrder;
const countText = test_support.countText;
const countNeedle = test_support.countNeedle;
const readTraceFile = test_support.readTraceFile;
const logIndex = test_support.logIndex;
const textContains = test_support.textContains;
const toolCall = test_support.toolCall;

const vision_agent_test_tools = test_support.vision_agent_test_tools;
const VisionAgentToolRuntime = test_support.VisionAgentToolRuntime;

const PostEffectTerminalFailure = struct {
    effect_count: usize = 0,

    fn execute(
        raw: *anyopaque,
        _: runtime_tool_contracts.ToolExecutionRequest,
    ) !runtime_tool_contracts.ToolExecutionResult {
        const self: *PostEffectTerminalFailure = @ptrCast(@alignCast(raw));
        self.effect_count += 1;
        return error.OutOfMemory;
    }
};

const terminal_advertised_names = [_][]const u8{"shell"};
const terminal_advertised_functions = [_]model_tool_schema.FunctionSchema{builtin_tools.shell.model_schema};

fn makeOwnedVisionCatalog(
    alloc: std.mem.Allocator,
    dir: std.Io.Dir,
    image_id: usize,
) ![]types.ImageAttachment {
    try dir.writeFile(io_mod.getIo(), .{ .sub_path = "vision.png", .data = "\x89PNG\r\n\x1a\nimage bytes" });
    const catalog = try alloc.alloc(types.ImageAttachment, 1);
    errdefer alloc.free(catalog);
    const path = try io_mod.dirRealpathAlloc(alloc, dir, "vision.png");
    var path_owned = true;
    errdefer if (path_owned) alloc.free(path);
    const media_type = try alloc.dupe(u8, "image/png");
    var media_type_owned = true;
    errdefer if (media_type_owned) alloc.free(media_type);
    catalog[0] = .{ .id = image_id, .path = path, .media_type = media_type };
    path_owned = false;
    media_type_owned = false;
    errdefer types.freeImageAttachment(alloc, catalog[0]);
    const root = try io_mod.dirRealpathAlloc(alloc, dir, ".");
    defer alloc.free(root);
    const snapshot_dir = try std.fs.path.join(alloc, &.{ root, "snapshots" });
    defer alloc.free(snapshot_dir);
    try image_attachments.captureImageSnapshot(alloc, &catalog[0], snapshot_dir);
    return catalog;
}

const BlockingPromptRun = struct {
    gateway: *FakeGateway,
    hooks: *FakeAgentRuntimeDeps,
    config: runtime_config.Config,
    job: worker_runtime.QueuedPrompt,
    finished: *std.atomic.Value(bool),
    failure: ?anyerror = null,

    fn run(self: *@This()) void {
        runFakePrompt(self.gateway, self.hooks, self.config, self.job) catch |err| {
            self.failure = err;
        };
        self.finished.store(true, .seq_cst);
    }
};

fn waitForPermissionBarrier(
    waiting: *const std.atomic.Value(bool),
    finished: *const std.atomic.Value(bool),
) bool {
    while (!waiting.load(.seq_cst) and !finished.load(.seq_cst)) {
        std.Thread.yield() catch std.atomic.spinLoopHint();
    }
    return waiting.load(.seq_cst);
}

fn executedToolCount(hooks: *FakeAgentRuntimeDeps) usize {
    hooks.execute_mutex.lockUncancelable(io_mod.getIo());
    defer hooks.execute_mutex.unlock(io_mod.getIo());
    return hooks.executed_names.items.len;
}

fn expectGrantListsEqual(
    expected: []const PermissionGrant,
    actual: []const PermissionGrant,
) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |expected_grant, actual_grant| {
        try std.testing.expectEqualStrings(
            expected_grant.tool_name,
            actual_grant.tool_name,
        );
        try std.testing.expectEqualStrings(
            expected_grant.target_path,
            actual_grant.target_path,
        );
    }
}

fn logContains(hooks: *const FakeAgentRuntimeDeps, needle: []const u8) bool {
    for (hooks.log.items) |entry| {
        if (std.mem.find(u8, entry, needle) != null) return true;
    }
    return false;
}

const FailingApplicableContext = struct {
    const Failure = enum {
        out_of_memory,
        no_space_left,
        write_failed,
    };

    var failure: Failure = .out_of_memory;
    var expected_target: []const u8 = "";
    var select_calls: usize = 0;
    var saw_expected_input = false;

    fn reset(next_failure: Failure, target: []const u8) void {
        failure = next_failure;
        expected_target = target;
        select_calls = 0;
        saw_expected_input = false;
    }

    fn gather(
        _: std.mem.Allocator,
        _: context_contract.InitialContextInput,
    ) context_contract.ProviderError!context_contract.ProviderContext {
        return .{};
    }

    fn select(
        _: std.mem.Allocator,
        input: context_contract.LaterContextInput,
    ) context_contract.ProviderError!context_contract.ProviderContext {
        select_calls += 1;
        saw_expected_input = input.targets.len == 1 and
            input.targets[0].kind == .file and
            std.mem.eql(u8, input.targets[0].path, expected_target) and
            input.delivered_sources.len == 0 and
            input.evaluated_endpoints.len == 0;
        return switch (failure) {
            .out_of_memory => error.OutOfMemory,
            .no_space_left => error.NoSpaceLeft,
            .write_failed => error.WriteFailed,
        };
    }

    fn appendStatic(
        _: context_contract.StaticContextInput,
        _: std.mem.Allocator,
        _: *std.ArrayList(ChatMessage),
    ) context_contract.ProviderError!void {}

    fn appendTransient(
        _: context_contract.TransientContextInput,
        _: std.mem.Allocator,
        _: *std.ArrayList(ChatMessage),
    ) context_contract.ProviderError!void {}

    const registry = context_contract.Registry{ .default_provider = .{
        .id = "test.failing_applicable_context",
        .gather_project_context_fn = gather,
        .select_applicable_project_context_fn = select,
        .append_static_fn = appendStatic,
        .append_transient_fn = appendTransient,
    } };
};

const ApplicableContextDelta = struct {
    const content = "SCOPED_CONTEXT_DELTA";
    const source = "/test/scoped/AGENTS.md";
    const endpoint = "/test/scoped";

    var expected_target: []const u8 = "";
    var cancel_flag: ?*std.atomic.Value(bool) = null;
    var select_calls: usize = 0;
    var saw_expected_input = false;

    fn reset(target: []const u8, maybe_cancel_flag: ?*std.atomic.Value(bool)) void {
        expected_target = target;
        cancel_flag = maybe_cancel_flag;
        select_calls = 0;
        saw_expected_input = false;
    }

    fn gather(
        _: std.mem.Allocator,
        _: context_contract.InitialContextInput,
    ) context_contract.ProviderError!context_contract.ProviderContext {
        if (cancel_flag) |flag| flag.store(true, .seq_cst);
        return .{};
    }

    fn select(
        alloc: std.mem.Allocator,
        input: context_contract.LaterContextInput,
    ) context_contract.ProviderError!context_contract.ProviderContext {
        select_calls += 1;
        saw_expected_input = input.targets.len == 1 and
            input.targets[0].kind == .file and
            std.mem.eql(u8, input.targets[0].path, expected_target) and
            input.delivered_sources.len == 0 and
            input.evaluated_endpoints.len == 0;
        if (cancel_flag) |flag| flag.store(true, .seq_cst);

        var selected: context_contract.ProviderContext = .{};
        errdefer selected.deinit(alloc);
        selected.content = try alloc.dupe(u8, content);
        selected.delivered_sources = try dupeStrings(alloc, &.{source});
        selected.evaluated_endpoints = try dupeStrings(alloc, &.{endpoint});
        return selected;
    }

    fn appendStatic(
        _: context_contract.StaticContextInput,
        _: std.mem.Allocator,
        _: *std.ArrayList(ChatMessage),
    ) context_contract.ProviderError!void {}

    fn appendTransient(
        _: context_contract.TransientContextInput,
        _: std.mem.Allocator,
        _: *std.ArrayList(ChatMessage),
    ) context_contract.ProviderError!void {}

    fn dupeStrings(
        alloc: std.mem.Allocator,
        strings: []const []const u8,
    ) std.mem.Allocator.Error![][]u8 {
        if (strings.len == 0) return &.{};
        const owned = try alloc.alloc([]u8, strings.len);
        var initialized: usize = 0;
        errdefer {
            for (owned[0..initialized]) |string| alloc.free(string);
            alloc.free(owned);
        }
        for (strings, 0..) |string, index| {
            owned[index] = try alloc.dupe(u8, string);
            initialized += 1;
        }
        return owned;
    }

    const registry = context_contract.Registry{ .default_provider = .{
        .id = "test.applicable_context_delta",
        .gather_project_context_fn = gather,
        .select_applicable_project_context_fn = select,
        .append_static_fn = appendStatic,
        .append_transient_fn = appendTransient,
    } };
};

const EmptyApplicableContext = struct {
    var select_calls: usize = 0;
    var last_target_count: usize = 0;

    fn reset() void {
        select_calls = 0;
        last_target_count = 0;
    }

    fn gather(
        _: std.mem.Allocator,
        _: context_contract.InitialContextInput,
    ) context_contract.ProviderError!context_contract.ProviderContext {
        return .{};
    }

    fn select(
        _: std.mem.Allocator,
        input: context_contract.LaterContextInput,
    ) context_contract.ProviderError!context_contract.ProviderContext {
        select_calls += 1;
        last_target_count = input.targets.len;
        return .{};
    }

    fn appendStatic(
        _: context_contract.StaticContextInput,
        _: std.mem.Allocator,
        _: *std.ArrayList(ChatMessage),
    ) context_contract.ProviderError!void {}

    fn appendTransient(
        _: context_contract.TransientContextInput,
        _: std.mem.Allocator,
        _: *std.ArrayList(ChatMessage),
    ) context_contract.ProviderError!void {}

    const registry = context_contract.Registry{ .default_provider = .{
        .id = "test.empty_applicable_context",
        .gather_project_context_fn = gather,
        .select_applicable_project_context_fn = select,
        .append_static_fn = appendStatic,
        .append_transient_fn = appendTransient,
    } };
};

const FreshnessApplicableContext = struct {
    const content = "NEW_SCOPED_CONTEXT";
    const source = "/test/new/AGENTS.md";
    const endpoint = "/test/new";

    var old_target: []const u8 = "";
    var new_target: []const u8 = "";
    var select_calls: usize = 0;
    var first_saw_old_target = false;
    var first_saw_new_target = false;
    var reissue_saw_new_target = false;
    var execution_reissue_saw_new_target = false;

    fn reset(old: []const u8, new: []const u8) void {
        old_target = old;
        new_target = new;
        select_calls = 0;
        first_saw_old_target = false;
        first_saw_new_target = false;
        reissue_saw_new_target = false;
        execution_reissue_saw_new_target = false;
    }

    fn gather(
        _: std.mem.Allocator,
        _: context_contract.InitialContextInput,
    ) context_contract.ProviderError!context_contract.ProviderContext {
        return .{};
    }

    fn select(
        alloc: std.mem.Allocator,
        input: context_contract.LaterContextInput,
    ) context_contract.ProviderError!context_contract.ProviderContext {
        select_calls += 1;
        for (input.targets) |target| {
            if (select_calls == 1 and std.mem.eql(u8, target.path, old_target)) {
                first_saw_old_target = true;
            }
            if (select_calls == 1 and std.mem.eql(u8, target.path, new_target)) {
                first_saw_new_target = true;
            }
            if (select_calls == 2 and std.mem.eql(u8, target.path, new_target)) {
                reissue_saw_new_target = true;
            }
            if (select_calls == 3 and std.mem.eql(u8, target.path, new_target)) {
                execution_reissue_saw_new_target = true;
            }
        }
        if (select_calls == 2 and reissue_saw_new_target) {
            var selected: context_contract.ProviderContext = .{};
            errdefer selected.deinit(alloc);
            selected.content = try alloc.dupe(u8, content);
            selected.delivered_sources = try ApplicableContextDelta.dupeStrings(alloc, &.{source});
            selected.evaluated_endpoints = try ApplicableContextDelta.dupeStrings(alloc, &.{endpoint});
            return selected;
        }
        return .{};
    }

    fn appendStatic(
        _: context_contract.StaticContextInput,
        _: std.mem.Allocator,
        _: *std.ArrayList(ChatMessage),
    ) context_contract.ProviderError!void {}

    fn appendTransient(
        _: context_contract.TransientContextInput,
        _: std.mem.Allocator,
        _: *std.ArrayList(ChatMessage),
    ) context_contract.ProviderError!void {}

    const registry = context_contract.Registry{ .default_provider = .{
        .id = "test.freshness_applicable_context",
        .gather_project_context_fn = gather,
        .select_applicable_project_context_fn = select,
        .append_static_fn = appendStatic,
        .append_transient_fn = appendTransient,
    } };
};

fn expectPermissionDeniedToolResult(gateway: *const FakeGateway, index: usize, tool_name: []const u8, reason: types.ToolPermissionDenialReason) !void {
    const alloc = std.testing.allocator;
    try std.testing.expect(index < gateway.request_bodies.items.len);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, gateway.request_bodies.items[index], .{});
    defer parsed.deinit();

    const messages = test_support.promptMessages(parsed.value) orelse return error.TestExpectedPromptMessageMissing;
    for (messages) |entry| {
        if (entry != .object) continue;
        const role = entry.object.get("role") orelse continue;
        if (role != .string or !std.mem.eql(u8, role.string, "tool")) continue;
        const content = entry.object.get("content") orelse continue;
        if (content != .string) continue;
        if (!tool_result_errors.isToolPermissionDeniedOutput(content.string)) continue;

        var payload = try std.json.parseFromSlice(std.json.Value, alloc, content.string, .{});
        defer payload.deinit();
        const error_obj = payload.value.object.get("error").?.object;
        try std.testing.expectEqualStrings("tool_permission_denied", error_obj.get("type").?.string);
        try std.testing.expectEqualStrings(tool_name, error_obj.get("tool_name").?.string);
        if (expectedPermissionDeniedMessage(reason)) |message| {
            try std.testing.expectEqualStrings(message, error_obj.get("message").?.string);
        }
        try std.testing.expectEqualStrings(@tagName(reason), error_obj.get("reason").?.string);
        try std.testing.expect(error_obj.get("denied").?.bool);
        try std.testing.expect(error_obj.get("suggestion") != null);
        return;
    }

    return error.TestExpectedToolResultMissing;
}

fn expectedPermissionDeniedMessage(reason: types.ToolPermissionDenialReason) ?[]const u8 {
    return switch (reason) {
        .user_denied => "Permission denied by user",
        .auto_denied => "Blocked by automatic safety policy",
        .review_caution => "Action held after safety review",
        .review_evidence_incomplete => "Safety review evidence incomplete; action held",
        .review_unavailable => "Safety reviewer unavailable; action held",
        .policy_denied, .permission_required => null,
    };
}

fn expectMalformedArgumentToolPair(
    gateway: *const FakeGateway,
    index: usize,
    tool_call_id: []const u8,
    tool_name: []const u8,
) !void {
    const alloc = std.testing.allocator;
    try std.testing.expect(index < gateway.request_bodies.items.len);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, gateway.request_bodies.items[index], .{});
    defer parsed.deinit();

    var call_count: usize = 0;
    var result_count: usize = 0;
    const messages = test_support.promptMessages(parsed.value) orelse return error.TestExpectedPromptMessageMissing;
    for (messages) |entry| {
        if (entry != .object) continue;
        const role = entry.object.get("role") orelse continue;
        if (role != .string) continue;

        if (std.mem.eql(u8, role.string, "assistant")) {
            const tool_calls = entry.object.get("tool_calls") orelse continue;
            if (tool_calls != .array) continue;
            for (tool_calls.array.items) |call| {
                if (call != .object) continue;
                const call_id = call.object.get("id") orelse continue;
                const function = call.object.get("function") orelse continue;
                if (function != .object) continue;
                const call_name = function.object.get("name") orelse continue;
                if (call_id != .string or call_name != .string) continue;
                if (!std.mem.eql(u8, call_id.string, tool_call_id) or
                    !std.mem.eql(u8, call_name.string, tool_name))
                {
                    continue;
                }
                const arguments = function.object.get("arguments") orelse return error.TestExpectedToolCallInputMissing;
                if (arguments != .string) return error.TestExpectedToolCallInputMissing;
                var input = try std.json.parseFromSlice(std.json.Value, alloc, arguments.string, .{});
                defer input.deinit();
                try std.testing.expect(input.value == .object);
                try std.testing.expectEqual(@as(usize, 0), input.value.object.count());
                call_count += 1;
            }
            continue;
        }

        if (std.mem.eql(u8, role.string, "tool")) {
            const call_id = entry.object.get("tool_call_id") orelse continue;
            if (call_id != .string or !std.mem.eql(u8, call_id.string, tool_call_id)) continue;
            const content = entry.object.get("content") orelse continue;
            if (content != .string) continue;
            if (!tool_result_errors.isToolExecutionFailedOutput(content.string)) continue;

            var failure = try std.json.parseFromSlice(std.json.Value, alloc, content.string, .{});
            defer failure.deinit();
            const error_obj = failure.value.object.get("error").?.object;
            try std.testing.expectEqualStrings("tool_execution_failed", error_obj.get("type").?.string);
            try std.testing.expectEqualStrings(tool_name, error_obj.get("tool_name").?.string);
            try std.testing.expect(std.mem.find(u8, error_obj.get("suggestion").?.string, "tool schema") != null);
            result_count += 1;
        }
    }

    try std.testing.expectEqual(@as(usize, 1), call_count);
    try std.testing.expectEqual(@as(usize, 1), result_count);
}

fn logIndexContaining(hooks: *const FakeAgentRuntimeDeps, needle: []const u8) ?usize {
    for (hooks.log.items, 0..) |entry, i| {
        if (std.mem.find(u8, entry, needle) != null) return i;
    }
    return null;
}

fn checkSkillPreparationCancellation(count: usize) !void {
    const alloc = std.testing.allocator;
    const contracts = @import("../../../skills/skill_contract.zig");
    const Trigger = struct {
        fn prepare(raw: *anyopaque, _: std.mem.Allocator, _: ToolCall, _: ?*const contracts.Locations) anyerror!contracts.CallPreparation {
            const hooks: *FakeAgentRuntimeDeps = @ptrCast(@alignCast(raw));
            hooks.cancel_on_execute.?.store(true, .seq_cst);
            return error.Cancelled;
        }
    };
    const calls = [_]ToolCall{
        .{ .id = "first_skill", .name = "skill", .arguments_json = "{\"name\":\"workflow\"}" },
        .{ .id = "second_skill", .name = "skill", .arguments_json = "{\"name\":\"workflow\"}" },
    };
    var fixture = PromptFixture{};
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    defer hooks.deinit();
    hooks.tool_registry = .{ .tools = &.{ builtin_tools.skill, builtin_tools.read_file } };
    hooks.cancel_on_execute = &fixture.cancel_flag;
    hooks.cancel_on_execute_name = "not-an-executed-tool";
    hooks.exec_plans = &.{.{ .result = .{ .model_output = "prior completed output" } }};
    var gateway = FakeGateway.init(alloc, &.{
        .{ .tool_calls = &.{.{ .id = "prior", .name = "read_file", .arguments_json = "{\"path\":\"README.md\"}" }} },
        .{ .tool_calls = calls[0..count] },
    });
    defer gateway.deinit();
    var deps = hooks.deps();
    deps.prepare_skill_call = Trigger.prepare;
    deps.agent_stream_provider = gateway.provider();
    var job = fixture.job();
    job.permission_mode = .yolo;
    var agent: @import("../agent.zig").Agent = .{};
    defer agent.deinit(alloc);
    try runtime_orchestrator.processAgentPrompt(&agent, &deps, null, testLifecycleContext(lifecycle_hooks.RuntimeView.empty(), alloc, fixture.workspace_root), fixture.config(), job);
    try std.testing.expectEqual(types.TurnPresentationOutcome.interrupted, hooks.finalized_outcome.?);
    try std.testing.expectEqual(@as(usize, 1), hooks.finalization_count);
    try std.testing.expectEqual(@as(usize, 1), hooks.executed_names.items.len);
    try std.testing.expectEqual(@as(usize, 1), hooks.history_turns.items.len);
    const interrupted = hooks.history_turns.items[0].interrupted;
    try std.testing.expectEqual(@as(usize, 1), interrupted.execution.tool_steps.len);
    try std.testing.expectEqualStrings("prior", interrupted.execution.tool_steps[0].tool_calls[0].id);
    try std.testing.expectEqualStrings("prior completed output", interrupted.execution.tool_steps[0].tool_results[0].output);
    for (calls[0..count]) |call| try expectSingleTerminalOutcome(hooks.lifecycle_events.items, call.id, .cancelled);
}

fn expectRejectedPrompt(completion: FakeCompletion, expected_error: anyerror) !void {
    if (comptime !builtin.is_test) return;
    const alloc = std.testing.allocator;
    const completions = [_]FakeCompletion{completion};
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    defer hooks.deinit();
    var fixture = PromptFixture{};

    try std.testing.expectError(
        expected_error,
        runFakePrompt(&gateway, &hooks, fixture.config(), fixture.job()),
    );
    try std.testing.expectEqual(@as(usize, 0), hooks.history_turns.items.len);
    try std.testing.expectEqual(@as(usize, 0), hooks.permission_names.items.len);
    try std.testing.expectEqual(@as(usize, 0), hooks.executed_names.items.len);
    try std.testing.expectEqual(@as(usize, 0), hooks.lifecycle_events.items.len);
    try std.testing.expectEqual(@as(usize, 0), hooks.system_notices.items.len);
    try std.testing.expectEqual(@as(usize, 0), hooks.texts.items.len);
    try std.testing.expectEqual(@as(usize, 0), hooks.finish_event_count);
    try std.testing.expectEqual(@as(usize, 1), hooks.finalization_count);
    try std.testing.expectEqual(types.TurnPresentationOutcome.failed, hooks.finalized_outcome.?);
    try std.testing.expect(logContains(&hooks, "event:turn_finished"));
}

fn lifecycleCallId(event: types.ToolLifecycleEvent) ?[]const u8 {
    return switch (event) {
        .provisional => |value| value.id.call_id,
        .authoritative_started => |value| value.id.call_id,
        .progress => |value| value.id.call_id,
        .terminal => |value| value.id.call_id,
        .turn_finished => null,
    };
}

fn expectLifecycleCallIds(
    events: []const types.ToolLifecycleEvent,
    expected: []const []const u8,
) !void {
    try std.testing.expectEqual(expected.len, events.len);
    for (events, expected) |event, call_id| {
        try std.testing.expectEqualStrings(call_id, lifecycleCallId(event).?);
    }
}

fn expectSingleTerminalOutcome(
    events: []const types.ToolLifecycleEvent,
    call_id: []const u8,
    expected_kind: types.ToolOutcomeKind,
) !void {
    var matches: usize = 0;
    for (events) |event| {
        if (event != .terminal) continue;
        const terminal = event.terminal;
        if (!std.mem.eql(u8, terminal.id.call_id, call_id)) continue;
        matches += 1;
        try std.testing.expectEqual(expected_kind, terminal.outcome.kind);
    }
    try std.testing.expectEqual(@as(usize, 1), matches);
}

fn failContextGateCommit() std.mem.Allocator.Error!void {
    return error.OutOfMemory;
}

fn expectLogOrder(
    hooks: *const FakeAgentRuntimeDeps,
    earlier: []const u8,
    later_prefix: []const u8,
) !void {
    var earlier_index: ?usize = null;
    var later_index: ?usize = null;
    for (hooks.log.items, 0..) |entry, index| {
        if (earlier_index == null and std.mem.eql(u8, entry, earlier)) earlier_index = index;
        if (later_index == null and std.mem.startsWith(u8, entry, later_prefix)) later_index = index;
    }
    if (earlier_index == null) return error.MissingEarlierLogEvent;
    if (later_index == null) return error.MissingLaterLogEvent;
    if (earlier_index.? >= later_index.?) return error.LogEventOutOfOrder;
}
