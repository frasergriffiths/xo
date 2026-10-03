const std = @import("std");
const build_options = @import("build_options");
const jsonrpc = @import("jsonrpc.zig");
const core_types = @import("../core/shared/types.zig");
const io_mod = @import("../core/shared/io.zig");

const Allocator = std.mem.Allocator;
const writeJsonStr = jsonrpc.writeJsonStr;

pub const MessageIdBuffer = [32]u8;

pub fn generateMessageId(storage: *MessageIdBuffer) []const u8 {
    var random_bytes: [16]u8 = undefined;
    io_mod.getIo().random(&random_bytes);
    storage.* = std.fmt.bytesToHex(random_bytes, .lower);
    return storage;
}

pub const protocol_version: u32 = 1;

pub fn writeModelRecoveryInfoUpdate(
    writer: *std.Io.Writer,
    status: ?core_types.RouteRecoveryStatus,
    durable: bool,
) !void {
    try writer.writeAll("{\"sessionUpdate\":\"session_info_update\",\"_meta\":{\"fx\":{\"modelResponseRecovery\":");
    const recovery = status orelse {
        try writer.writeAll("null}}}");
        return;
    };
    try writer.writeAll("{\"state\":");
    try writeJsonStr(
        if (recovery.isRecovered())
            "recovered"
        else if (recovery.kind == .terminal_provider_error)
            // Match the CLI JSON contract: a genuine lifecycle pause
            // (action == .paused) is resumable; a terminal stop is not.
            if (recovery.action == .paused) "paused" else "failed"
        else
            "active",
        writer,
    );
    try writer.writeAll(",\"kind\":");
    try writeJsonStr(@tagName(recovery.kind), writer);
    if (recovery.cause) |cause| {
        try writer.writeAll(",\"cause\":");
        try writeJsonStr(@tagName(cause), writer);
    }
    if (recovery.action) |action| {
        try writer.writeAll(",\"action\":");
        try writeJsonStr(@tagName(action), writer);
    }
    if (recovery.required_action != .none) {
        try writer.writeAll(",\"requiredAction\":");
        try writeJsonStr(@tagName(recovery.required_action), writer);
    }
    const reported_attempt = recovery.reportedAttempt();
    if (reported_attempt != 0) {
        try writer.print(",\"attempt\":{d}", .{reported_attempt});
    }
    if (recovery.attempt_limit != 0) {
        try writer.print(",\"attemptLimit\":{d}", .{recovery.attempt_limit});
    }
    if (recovery.delay_seconds != 0) {
        try writer.print(",\"delaySeconds\":{d}", .{recovery.delay_seconds});
    }
    try writer.print(",\"durable\":{s},\"message\":", .{if (durable) "true" else "false"});
    var label_buf: [core_types.RouteRecoveryStatus.label_max_bytes]u8 = undefined;
    try writeJsonStr(recovery.label(&label_buf), writer);
    try writer.writeAll("}}}}");
}

pub const StopReason = enum {
    end_turn,
    max_output_tokens,
    max_model_turns,
    refused,
    cancelled,

    pub fn jsonString(self: StopReason) []const u8 {
        return switch (self) {
            .end_turn => "end_turn",
            .max_output_tokens => "max_output_tokens",
            .max_model_turns => "max_model_turns",
            .refused => "refused",
            .cancelled => "cancelled",
        };
    }
};

pub const ToolCallKind = enum {
    read,
    edit,
    delete,
    move,
    search,
    execute,
    think,
    fetch,
    other,

    pub fn jsonString(self: ToolCallKind) []const u8 {
        return switch (self) {
            .read => "read",
            .edit => "edit",
            .delete => "delete",
            .move => "move",
            .search => "search",
            .execute => "execute",
            .think => "think",
            .fetch => "fetch",
            .other => "other",
        };
    }
};

pub const ToolCallStatus = enum {
    pending,
    in_progress,
    completed,
    failed,

    pub fn jsonString(self: ToolCallStatus) []const u8 {
        return switch (self) {
            .pending => "pending",
            .in_progress => "in_progress",
            .completed => "completed",
            .failed => "failed",
        };
    }
};

pub fn writeSessionUpdate(w: *std.Io.Writer, session_id: []const u8, update_json: []const u8) !void {
    try w.writeAll("{\"sessionId\":");
    try writeJsonStr(session_id, w);
    try w.writeAll(",\"update\":");
    try w.writeAll(update_json);
    try w.writeAll("}");
}

pub fn writeAgentMessageChunk(w: *std.Io.Writer, message_id: []const u8, text: []const u8) !void {
    try w.writeAll("{\"sessionUpdate\":\"agent_message_chunk\",\"messageId\":");
    try writeJsonStr(message_id, w);
    try w.writeAll(",\"content\":{\"type\":\"text\",\"text\":");
    try writeJsonStr(text, w);
    try w.writeAll("}}");
}

pub fn writeAgentThoughtChunk(w: *std.Io.Writer, text: []const u8) !void {
    try w.writeAll("{\"sessionUpdate\":\"agent_thought_chunk\",\"content\":{\"type\":\"text\",\"text\":");
    try writeJsonStr(text, w);
    try w.writeAll("}}");
}

pub fn writeUserMessageChunk(w: *std.Io.Writer, message_id: []const u8, text: []const u8) !void {
    try w.writeAll("{\"sessionUpdate\":\"user_message_chunk\",\"messageId\":");
    try writeJsonStr(message_id, w);
    try w.writeAll(",\"content\":{\"type\":\"text\",\"text\":");
    try writeJsonStr(text, w);
    try w.writeAll("}}");
}

pub fn writeUserImageChunk(
    w: *std.Io.Writer,
    message_id: []const u8,
    media_type: []const u8,
    bytes: []const u8,
) !void {
    try w.writeAll("{\"sessionUpdate\":\"user_message_chunk\",\"messageId\":");
    try writeJsonStr(message_id, w);
    try w.writeAll(",\"content\":{\"type\":\"image\",\"data\":\"");
    try std.base64.standard.Encoder.encodeWriter(w, bytes);
    try w.writeAll("\",\"mimeType\":");
    try writeJsonStr(media_type, w);
    try w.writeAll("}}");
}

pub fn writeToolCall(
    w: *std.Io.Writer,
    tool_call_id: []const u8,
    name: []const u8,
    title: []const u8,
    kind: ToolCallKind,
    status: ToolCallStatus,
    raw_input: ?std.json.Value,
) !void {
    try w.writeAll("{\"sessionUpdate\":\"tool_call\",\"toolCallId\":");
    try writeJsonStr(tool_call_id, w);
    try w.writeAll(",\"name\":");
    try writeJsonStr(name, w);
    try w.writeAll(",\"title\":");
    try writeJsonStr(title, w);
    try w.writeAll(",\"kind\":");
    try writeJsonStr(kind.jsonString(), w);
    try w.writeAll(",\"status\":");
    try writeJsonStr(status.jsonString(), w);
    if (raw_input) |value| {
        try w.writeAll(",\"rawInput\":");
        try std.json.Stringify.value(value, .{}, w);
    }
    try w.writeAll("}");
}

pub fn writeToolCallUpdate(w: *std.Io.Writer, tool_call_id: []const u8, status: ToolCallStatus, content_text: ?[]const u8) !void {
    try writeToolCallUpdateWithCommandResult(w, tool_call_id, status, content_text, null);
}

pub fn writeToolCallUpdateWithCommandResult(
    w: *std.Io.Writer,
    tool_call_id: []const u8,
    status: ToolCallStatus,
    content_text: ?[]const u8,
    command_result_json: ?[]const u8,
) !void {
    try w.writeAll("{\"sessionUpdate\":\"tool_call_update\",\"toolCallId\":");
    try writeJsonStr(tool_call_id, w);
    try w.writeAll(",\"status\":");
    try writeJsonStr(status.jsonString(), w);
    if (content_text) |text| {
        try w.writeAll(",\"content\":[{\"type\":\"content\",\"content\":{\"type\":\"text\",\"text\":");
        try writeJsonStr(text, w);
        try w.writeAll("}}]");
    }
    if (command_result_json) |json| {
        try w.writeAll(",\"command_result\":");
        try w.writeAll(json);
    }
    try w.writeAll("}");
}

pub fn writeInitializeResponse(w: *std.Io.Writer) !void {
    try w.writeAll("{\"protocolVersion\":");
    try w.print("{d}", .{protocol_version});
    try w.writeAll(",\"agentCapabilities\":{");
    try w.writeAll("\"loadSession\":true,");
    try w.print("\"promptCapabilities\":{{\"image\":{s},\"audio\":false,\"embeddedContext\":true}},", .{"true"});
    try w.writeAll("\"sessionCapabilities\":{\"list\":{},\"resume\":{},\"close\":{}}");
    try w.writeAll("},\"agentInfo\":{\"name\":\"fx\",\"title\":\"fx\",\"version\":");
    try writeJsonStr(build_options.app_version, w);
    try w.writeAll("},");
    try w.writeAll("\"authMethods\":[]}");
}

pub fn writePromptResponse(w: *std.Io.Writer, reason: StopReason) !void {
    try w.writeAll("{\"stopReason\":");
    try writeJsonStr(reason.jsonString(), w);
    try w.writeAll("}");
}

pub fn writePromptResponseWithUsage(
    w: *std.Io.Writer,
    reason: StopReason,
    usage: core_types.Usage,
) !void {
    try w.writeAll("{\"stopReason\":");
    try writeJsonStr(reason.jsonString(), w);
    try w.writeAll(",\"usage\":{");
    var first = true;
    inline for (.{
        .{ "inputTokens", usage.input_tokens },
        .{ "outputTokens", usage.output_tokens },
        .{ "cacheReadTokens", usage.cache_read_tokens },
        .{ "cacheWriteTokens", usage.cache_write_tokens },
        .{ "reasoningTokens", usage.reasoning_tokens },
    }) |field| {
        if (field[1]) |value| {
            if (!first) try w.writeByte(',');
            first = false;
            try writeJsonStr(field[0], w);
            try w.print(":{d}", .{value});
        }
    }
    try w.writeAll("}}");
}

pub fn writeAvailableCommandsUpdate(w: *std.Io.Writer, commands_json: []const u8) !void {
    try w.writeAll("{\"sessionUpdate\":\"available_commands_update\",\"availableCommands\":");
    try w.writeAll(commands_json);
    try w.writeAll("}");
}

pub fn writeSessionInfoUpdate(w: *std.Io.Writer, title: []const u8, updated_at: []const u8) !void {
    try w.writeAll("{\"sessionUpdate\":\"session_info_update\",\"title\":");
    try writeJsonStr(title, w);
    try w.writeAll(",\"updatedAt\":");
    try writeJsonStr(updated_at, w);
    try w.writeAll("}");
}

pub fn writeUsageUpdate(w: *std.Io.Writer, used: u64, size: u64, complete_cost: ?f64) !void {
    try w.print("{{\"sessionUpdate\":\"usage_update\",\"used\":{d},\"size\":{d}", .{ used, size });
    if (complete_cost) |amount| {
        try w.print(",\"cost\":{{\"amount\":{d},\"currency\":\"USD\"}}", .{amount});
    }
    try w.writeAll("}");
}
