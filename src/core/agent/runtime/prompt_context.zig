const std = @import("std");
const model_capabilities = @import("../../config/model_capabilities.zig");
const token_estimate = @import("../../shared/token_estimate.zig");
const types = @import("../../shared/types.zig");
const session_runtime = @import("../../session/session.zig");
const stream_provider = @import("../stream_provider.zig");
const model_provider = @import("../../config/model_provider.zig");

const Allocator = std.mem.Allocator;
const ChatMessage = types.ChatMessage;
const HistoryTurn = types.HistoryTurn;

const compaction_high_water_numerator: usize = 4;
const compaction_ratio_denominator: usize = 5;
const compaction_target_denominator: usize = 10;
const compaction_recent_denominator: usize = 20;
const compaction_soft_ceiling_denominator: usize = 4;
const compaction_source_reduction_denominator: usize = 8;

pub const CompactionTrigger = enum {
    automatic,
    manual,
};

pub const CompactionDecision = enum {
    no_op,
    compact,
};

pub const CompactionPlanInput = struct {
    trigger: CompactionTrigger,
    capabilities: model_capabilities.Capabilities,
    request_tokens: usize,
    source_tokens: usize,
    protected_tokens: usize = 0,
    newest_exchange_tokens: usize = 0,
};

pub const CompactionPlan = struct {
    decision: CompactionDecision,
    usable_input_tokens: ?usize,
    high_water_tokens: ?usize,
    session_target_tokens: ?usize,
    accepted_handoff_tokens: ?usize,
};

pub fn planCompaction(input: CompactionPlanInput) CompactionPlan {
    const usable = usableInputTokens(input.capabilities);
    const high_water = if (usable) |tokens|
        tokens * compaction_high_water_numerator / compaction_ratio_denominator
    else
        null;
    const session_target = if (usable) |tokens|
        tokens / compaction_target_denominator
    else
        null;
    const should_compact = input.source_tokens > 0 and switch (input.trigger) {
        .manual => true,
        .automatic => if (high_water) |tokens| input.request_tokens >= tokens else false,
    };
    if (!should_compact) return .{
        .decision = .no_op,
        .usable_input_tokens = usable,
        .high_water_tokens = high_water,
        .session_target_tokens = session_target,
        .accepted_handoff_tokens = null,
    };

    const source_target = @max(
        @as(usize, 1),
        (input.source_tokens +| (compaction_source_reduction_denominator - 1)) /
            compaction_source_reduction_denominator,
    );
    const total_target = if (session_target) |target|
        @max(@as(usize, 1), target)
    else
        source_target;
    const soft_ceiling = if (usable) |tokens| tokens / compaction_soft_ceiling_denominator else total_target *| 2;
    const oversized_exchange = if (usable) |tokens|
        input.newest_exchange_tokens > tokens / compaction_recent_denominator and input.protected_tokens > soft_ceiling
    else
        false;
    const request_ceiling = if (oversized_exchange) usable.? else soft_ceiling;
    if (input.protected_tokens >= request_ceiling) return .{
        .decision = .no_op,
        .usable_input_tokens = usable,
        .high_water_tokens = high_water,
        .session_target_tokens = session_target,
        .accepted_handoff_tokens = null,
    };
    const accepted = @min(total_target, request_ceiling - input.protected_tokens);
    return .{
        .decision = .compact,
        .usable_input_tokens = usable,
        .high_water_tokens = high_water,
        .session_target_tokens = session_target,
        .accepted_handoff_tokens = accepted,
    };
}

pub fn recentContextTarget(capabilities: model_capabilities.Capabilities, source_tokens: usize) usize {
    return (usableInputTokens(capabilities) orelse source_tokens) / compaction_recent_denominator;
}

pub const RetainedContext = struct {
    cut: types.ContextHistoryCut,
    newest_exchange_tokens: usize,
    estimated_tokens: usize,
};

/// Selects complete execution steps. Payloads are measured, never shortened.
pub fn selectRecentContext(history: []const HistoryTurn, target: usize, input_capacity: ?usize, options: struct {
    provider: ?model_provider.ProviderSelection = null,
    reject_oversized_tool_step: bool = false,
}) RetainedContext {
    var raw_count = session_runtime.rawHistoryTurnCount(history);
    var selected = types.ContextHistoryCut{ .turns = raw_count };
    var total: usize = 0;
    var newest: usize = 0;
    var selected_any = false;
    var index = history.len;
    history_scan: while (index > 0) {
        index -= 1;
        const turn = history[index];
        if (turn == .compacted_summary) continue;
        raw_count -= 1;
        const user = switch (turn) {
            .assistant => |entry| entry.user.text,
            .interrupted => |entry| entry.user.text,
            .compacted_summary => unreachable,
        };
        const reply = switch (turn) {
            .assistant => |entry| entry.assistant,
            .interrupted => |entry| entry.assistant orelse "",
            .compacted_summary => unreachable,
        };
        const execution = switch (turn) {
            .assistant => |entry| entry.execution,
            .interrupted => |entry| entry.execution,
            .compacted_summary => unreachable,
        };
        const replay = switch (turn) {
            .assistant => |entry| entry.provider_replay,
            .interrupted => null,
            .compacted_summary => unreachable,
        };
        var base = textTokens(user) +| textTokens(reply) +| replay_tokens(replay, options.provider) +| 8;
        var steering_index = execution.steering.len;
        var step_index = execution.tool_steps.len;
        if (step_index == 0) {
            for (execution.steering) |entry| {
                base +|= textTokens(entry.text);
                if (entry.assistant_prefix) |prefix| base +|= textTokens(prefix);
            }
            if (input_capacity) |capacity| {
                if (!selected_any and base >= capacity) break :history_scan;
            }
            if (selected_any and (raw_count == 0 or total +| base > target)) break;
            total +|= base;
            selected = .{ .turns = raw_count };
            if (!selected_any) newest = total;
            selected_any = true;
            continue;
        }
        while (step_index > 0) {
            step_index -= 1;
            var cost = base +| executionStepTokens(execution.tool_steps[step_index], options.provider);
            var next_steering = steering_index;
            while (next_steering > 0 and execution.steering[next_steering - 1].after_tool_step_count >= step_index) {
                next_steering -= 1;
                cost +|= textTokens(execution.steering[next_steering].text);
                if (execution.steering[next_steering].assistant_prefix) |prefix| cost +|= textTokens(prefix);
            }
            if (!selected_any and options.reject_oversized_tool_step and cost > target) break :history_scan;
            if (input_capacity) |capacity| {
                if (!selected_any and cost >= capacity) break :history_scan;
            }
            if (selected_any and ((raw_count == 0 and step_index == 0) or total +| cost > target)) return .{
                .cut = selected,
                .newest_exchange_tokens = newest,
                .estimated_tokens = total,
            };
            total +|= cost;
            selected = .{ .turns = raw_count, .tool_steps = step_index, .steering = next_steering };
            if (!selected_any) newest = total;
            selected_any = true;
            steering_index = next_steering;
            base = 0;
        }
    }
    return .{ .cut = selected, .newest_exchange_tokens = newest, .estimated_tokens = total };
}

fn textTokens(text: []const u8) usize {
    var estimator = token_estimate.StreamingEstimator{};
    estimator.consume(text);
    return @intCast(@min(estimator.estimate(), std.math.maxInt(usize)));
}

fn replay_tokens(replay: ?types.ProviderReplay, provider: ?model_provider.ProviderSelection) usize {
    const value = replay orelse return 0;
    if (provider) |selection| if (!value.matches(selection)) return 0;
    return textTokens(value.parts_json);
}

fn executionStepTokens(step: types.ToolExecutionStep, provider: ?model_provider.ProviderSelection) usize {
    var total: usize = 8 +| replay_tokens(step.provider_replay, provider);
    if (step.assistant) |text| total +|= textTokens(text);
    for (step.tool_calls) |call| {
        total +|= textTokens(call.id) +| textTokens(call.name) +| textTokens(call.arguments_json) +| 8;
    }
    for (step.tool_results) |result| {
        total +|= textTokens(result.tool_call_id) +| textTokens(result.tool_name) +| textTokens(result.output) +| 8;
    }
    return total;
}

pub const CompactionHandoffError = error{
    EmptyCompactionHandoff,
    InvalidCompactionHandoff,
    CompactionHandoffTooLarge,
};

pub fn validateCompactionHandoff(
    text: []const u8,
    accepted_tokens: usize,
) CompactionHandoffError!void {
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidCompactionHandoff;
    if (std.mem.trim(u8, text, " \t\r\n").len == 0) {
        return error.EmptyCompactionHandoff;
    }
    var estimator = token_estimate.StreamingEstimator{};
    estimator.consume(text);
    if (estimator.estimate() > accepted_tokens) {
        return error.CompactionHandoffTooLarge;
    }
}

pub const RequestCost = struct {
    serialized_bytes: usize,
    /// Uncalibrated serialization estimate; non-image usage may replace it.
    text_tokens: usize,
    /// Null means no image parts. Otherwise visual cost needs applicable usage.
    image_identity: ?[32]u8 = null,
    estimated_input_tokens: usize,
};

pub const RequestTokenCalibration = struct {
    request: RequestCost,
    exact_input_tokens: usize,

    pub fn applies(self: RequestTokenCalibration, cost: RequestCost) bool {
        return self.request.serialized_bytes != 0 and self.exact_input_tokens != 0 and
            std.meta.eql(cost.image_identity, self.request.image_identity);
    }
};

const ImagePartData = struct {
    type: []const u8 = "",
    data: ?[]const u8 = null,
};

const ImagePart = struct {
    type: []const u8 = "",
    mediaType: ?[]const u8 = null,
    detail: ?[]const u8 = null,
    data: ?ImagePartData = null,
    image_url: ?[]const u8 = null,
};

const MessageContent = struct {
    parts: []const ImagePart = &.{},

    pub fn jsonParse(alloc: Allocator, source: anytype, options: std.json.ParseOptions) !MessageContent {
        if (try source.peekNextTokenType() == .array_begin) {
            return .{ .parts = try std.json.innerParse([]const ImagePart, alloc, source, options) };
        }
        try source.skipValue();
        return .{};
    }
};

const CostMessage = struct {
    role: []const u8 = "",
    type: []const u8 = "",
    content: MessageContent = .{},
    output: MessageContent = .{},
};

const CostRequest = struct {
    prompt: ?[]const CostMessage = null,
    input: ?[]const CostMessage = null,
};

pub const MeasurementError = error{ OutOfMemory, InvalidRequestMeasurement };

/// Borrows the prepared body and request; releases parsing scratch before returning.
/// Image payloads are transport bytes, not text. Their initial token cost is unknown.
pub fn measureProviderRequest(alloc: Allocator, body: []const u8, request: stream_provider.RequestData) MeasurementError!RequestCost {
    const has_images = image_input: {
        if (request.verified_images) |images| if (images.len != 0) break :image_input true;
        for (request.messages) |message| {
            if (message.images.len != 0) break :image_input true;
            // Retained tool images serialize as follow-up user-message file
            // parts, so they never appear in message.images. Count them as
            // image input or their base64 payloads are priced as text.
            if (message.tool_result_memory) |memory| if (memory.tool_images.len != 0) break :image_input true;
        }
        break :image_input false;
    };
    if (!has_images) {
        const tokens = textTokens(body);
        return .{ .serialized_bytes = body.len, .text_tokens = tokens, .estimated_input_tokens = tokens };
    }

    // Typed parsing borrows unescaped payload strings. Value parsing copies them.
    const parsed = std.json.parseFromSlice(CostRequest, alloc, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_if_needed,
    }) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidRequestMeasurement,
    };
    defer parsed.deinit();
    if (parsed.value.prompt != null and parsed.value.input != null) return error.InvalidRequestMeasurement;
    const messages = parsed.value.prompt orelse parsed.value.input orelse {
        // Unrecognized envelope (e.g. chat-completions "messages" bodies):
        // degrade to the conservative text estimate rather than fail the
        // request over a shape this measurer does not know.
        const tokens = textTokens(body);
        return .{ .serialized_bytes = body.len, .text_tokens = tokens, .estimated_input_tokens = tokens };
    };
    var estimator = token_estimate.StreamingEstimator{};
    var identity = std.crypto.hash.sha2.Sha256.init(.{});
    var cursor: usize = 0;
    var found_image = false;
    for (messages) |message| {
        // Retained tool images never land in user-message content on
        // input-style bodies: the responses protocol writes them as
        // input_image parts inside function_call_output items, which carry no
        // role. Scan both carriers.
        const parts = if (std.mem.eql(u8, message.role, "user"))
            message.content.parts
        else if (parsed.value.input != null and std.mem.eql(u8, message.type, "function_call_output"))
            message.output.parts
        else
            continue;
        for (parts) |part| {
            const payload = if (parsed.value.input != null and std.mem.eql(u8, part.type, "input_image"))
                part.image_url orelse return error.InvalidRequestMeasurement
            else if (parsed.value.prompt != null and std.mem.eql(u8, part.type, "file") and
                std.mem.startsWith(u8, part.mediaType orelse "", "image/"))
            payload: {
                const data = part.data orelse return error.InvalidRequestMeasurement;
                if (!std.mem.eql(u8, data.type, "data")) return error.InvalidRequestMeasurement;
                break :payload data.data orelse return error.InvalidRequestMeasurement;
            } else continue;
            const address = @intFromPtr(payload.ptr);
            if (address < @intFromPtr(body.ptr)) return error.InvalidRequestMeasurement;
            const offset = address - @intFromPtr(body.ptr);
            if (offset < cursor or offset > body.len or payload.len > body.len - offset) return error.InvalidRequestMeasurement;
            estimator.consume(body[cursor..offset]);
            cursor = offset + payload.len;
            for ([_][]const u8{ part.type, part.mediaType orelse "", part.detail orelse "", payload }) |value| {
                identity.update(std.mem.asBytes(&value.len));
                identity.update(value);
            }
            found_image = true;
        }
    }
    estimator.consume(body[cursor..]);
    const tokens: usize = @intCast(@min(estimator.estimate(), std.math.maxInt(usize)));
    return .{
        .serialized_bytes = body.len,
        .text_tokens = tokens,
        .image_identity = if (found_image) identity.finalResult() else null,
        .estimated_input_tokens = tokens,
    };
}

pub fn calibrateProviderRequest(
    cost: RequestCost,
    calibration: RequestTokenCalibration,
) RequestCost {
    if (!calibration.applies(cost)) return cost;
    const calibrated_tokens = if (cost.image_identity != null)
        if (cost.text_tokens >= calibration.request.text_tokens)
            calibration.exact_input_tokens +| (cost.text_tokens - calibration.request.text_tokens)
        else
            calibration.exact_input_tokens -| (calibration.request.text_tokens - cost.text_tokens)
    else
        multiplyDivideCeilSaturating(cost.serialized_bytes, calibration.exact_input_tokens, calibration.request.serialized_bytes);
    var result = cost;
    result.estimated_input_tokens = if (cost.image_identity != null)
        @max(cost.text_tokens, calibrated_tokens)
    else
        @max(1, calibrated_tokens);
    return result;
}

fn multiplyDivideCeilSaturating(
    value: usize,
    numerator: usize,
    denominator: usize,
) usize {
    std.debug.assert(denominator != 0);
    const whole = std.math.mul(
        usize,
        value / denominator,
        numerator,
    ) catch return std.math.maxInt(usize);
    const remainder_product = std.math.mul(
        usize,
        value % denominator,
        numerator,
    ) catch return std.math.maxInt(usize);
    const partial = remainder_product / denominator +
        @intFromBool(remainder_product % denominator != 0);
    return std.math.add(usize, whole, partial) catch std.math.maxInt(usize);
}

pub fn estimateCompactionSourceTokens(messages: []const ChatMessage) usize {
    var estimator = token_estimate.StreamingEstimator{};
    for (messages) |message| {
        estimator.consume(@tagName(message.role));
        if (message.content) |content| estimator.consume(content);
        if (message.tool_call_id) |id| estimator.consume(id);
        if (message.tool_name) |name| estimator.consume(name);
        for (message.tool_calls) |call| {
            estimator.consume(call.id);
            estimator.consume(call.name);
            estimator.consume(call.arguments_json);
        }
    }
    return @intCast(@min(estimator.estimate(), std.math.maxInt(usize)));
}

pub fn usableInputTokens(
    capabilities: model_capabilities.Capabilities,
) ?usize {
    const context_window = capabilities.context_window orelse return null;
    const context_tokens: usize = @intCast(context_window);
    // Reserve exactly what the request asks for; that limit is always below the window.
    const output_tokens: usize = model_capabilities.requestOutputTokens(capabilities) orelse return context_tokens;
    return context_tokens - output_tokens;
}

pub const ProviderPrompt = struct {
    instructions: std.ArrayList(ChatMessage),
    messages: std.ArrayList(ChatMessage),

    pub fn deinit(self: *ProviderPrompt, alloc: Allocator) void {
        self.instructions.deinit(alloc);
        self.messages.deinit(alloc);
        self.* = undefined;
    }
};

pub fn buildProviderPrompt(
    alloc: Allocator,
    stable_prefix: []const ChatMessage,
    ephemeral_overlay: []const ChatMessage,
    durable_history: []const ChatMessage,
    current_user_message: ChatMessage,
    within_turn_suffix: []const ChatMessage,
) !ProviderPrompt {
    var instructions: std.ArrayList(ChatMessage) = .empty;
    errdefer instructions.deinit(alloc);
    var messages: std.ArrayList(ChatMessage) = .empty;
    errdefer messages.deinit(alloc);

    try instructions.appendSlice(alloc, stable_prefix);
    try instructions.appendSlice(alloc, ephemeral_overlay);
    try messages.appendSlice(alloc, durable_history);
    try messages.append(alloc, current_user_message);
    try messages.appendSlice(alloc, within_turn_suffix);
    return .{
        .instructions = instructions,
        .messages = messages,
    };
}

fn measurement_test_request(with_images: bool) stream_provider.RequestData {
    return .{
        .model = "fixture/model",
        .messages = if (with_images) &.{.{
            .role = .user,
            .images = &.{.{ .path = @constCast("fixture.png"), .media_type = @constCast("image/png") }},
        }} else &.{},
        .tool_choice = .none,
        .provider_options = .{},
    };
}
