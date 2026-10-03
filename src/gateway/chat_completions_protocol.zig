const std = @import("std");
const stream_provider = @import("../core/agent/stream_provider.zig");
const types = @import("../core/shared/types.zig");
const model_tool_schema = @import("../core/tooling/model_tool_schema.zig");
const tool_result_errors = @import("../core/tooling/tool_result_errors.zig");
const image_attachments = @import("../core/images/image_attachments.zig");
const tool_call_ids = @import("tool_call_ids.zig");
const sse = @import("sse.zig");
const configured_provider = @import("../core/config/configured_provider.zig");
const model_provider = @import("../core/config/model_provider.zig");
const io_mod = @import("../core/shared/io.zig");

const Allocator = std.mem.Allocator;

pub const ToolChoiceMode = configured_provider.ToolChoiceMode;

/// OpenRouter upstream routing preferences. A null value keeps the request body
/// free of any provider-routing field, which is what a generic OpenAI-compatible
/// endpoint requires.
pub const UpstreamRouting = struct {
    /// Upstream provider slugs in preference order.
    order: []const []const u8 = &.{},
    /// When false, upstream routing is a hard restriction rather than a hint.
    allow_fallback: bool = true,
};

pub const Options = struct {
    tool_choice_mode: ToolChoiceMode = .omit,
    /// Borrowed only during serialization; includes the configured authority binding.
    provider: ?*const model_provider.ProviderId = null,
    upstream_routing: ?UpstreamRouting = null,
};

pub const Error = error{
    OutOfMemory,
    InvalidProviderPrompt,
    InvalidModel,
    UnsupportedProviderOption,
    UnsupportedVision,
    UnsupportedResponseFormat,
    UnsupportedReplay,
    InvalidProviderState,
    ReplayTooLarge,
    UnsupportedToolProvenance,
    InvalidOutputLimit,
    InvalidToolSelection,
    InvalidToolSchema,
    InvalidToolCallId,
    InvalidToolName,
    InvalidToolArguments,
    InvalidToolHistory,
    ImageUnavailable,
    RequiredToolMissing,
    UnexpectedToolCall,
    InvalidChunk,
    ConflictingIdentity,
    InvalidFinishReason,
    InconsistentFinishReason,
    IncompleteStream,
    StreamClosed,
    ProviderError,
    OutputTruncated,
    ContentFiltered,
    Refused,
    EventTooLarge,
    StreamTooLarge,
    TooManyEvents,
    TooManyTools,
    IdentityTooLarge,
    ArgumentsTooLarge,
    ContentTooLarge,
    JsonTooDeep,
    Cancelled,
    ReadFailed,
};

const max_selected_tools = 256;
const max_name_bytes = 128;
const max_history_arguments_bytes = 1024 * 1024;
const max_json_depth = 64;

const Function = struct {
    name: []const u8,
    description: []const u8,
    schema: union(enum) {
        builtin: model_tool_schema.ObjectSchema,
        dynamic: std.json.Value,
    },
};

fn contains_name(names: []const []const u8, name: []const u8) bool {
    for (names) |candidate| if (std.mem.eql(u8, candidate, name)) return true;
    return false;
}

fn validate_name(name: []const u8) Error!void {
    if (name.len == 0 or name.len > max_name_bytes) return error.InvalidToolName;
    // fx advertises dotted built-in tool names. Keep those
    // literal identities; do not invent aliases that core cannot resolve.
    for (name) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '_' and byte != '-' and byte != '.') return error.InvalidToolName;
}

fn append_function(alloc: Allocator, functions: *std.ArrayList(Function), function: Function) Error!void {
    try validate_name(function.name);
    if (functions.items.len == max_selected_tools) return error.TooManyTools;
    for (functions.items) |prior| if (std.mem.eql(u8, prior.name, function.name)) return error.InvalidToolSelection;
    try functions.append(alloc, function);
}

// Provider-native advertisements are not Chat Completions function tools.
// Omit only registered provider-executed tools; missing ordinary schemas fail.
fn select_functions(alloc: Allocator, tools: stream_provider.ToolSelection, choice: types.ToolChoice) Error!std.ArrayList(Function) {
    var functions: std.ArrayList(Function) = .empty;
    errdefer functions.deinit(alloc);
    if (choice == .none) return functions;
    if (tools.advertised_names.len > max_selected_tools or tools.advertised_functions.len > max_selected_tools or tools.additional_functions.len > max_selected_tools or tools.selected_dynamic.len > max_selected_tools) return error.TooManyTools;
    for (tools.advertised_names) |name| {
        const function = tools.advertisedFunction(name) orelse {
            const registered = tools.registry.lookup(name) orelse return error.InvalidToolSelection;
            if (registered.provider_executed) continue;
            return error.InvalidToolSelection;
        };
        // A repeated definition must not be selected by accidental first match.
        var matches: usize = 0;
        for (tools.advertised_functions) |candidate| if (std.mem.eql(u8, candidate.name, name)) {
            matches += 1;
        };
        if (matches != 1) return error.InvalidToolSelection;
        try append_function(alloc, &functions, .{ .name = name, .description = function.description, .schema = .{ .builtin = function.input_schema } });
    }
    for (tools.additional_functions) |function| {
        if (contains_name(tools.advertised_names, function.name)) continue;
        try append_function(alloc, &functions, .{ .name = function.name, .description = function.description, .schema = .{ .builtin = function.input_schema } });
    }
    var schema_budget: SchemaBudget = .{};
    for (tools.selected_dynamic) |function| {
        if (contains_name(tools.advertised_names, function.name)) continue;
        if (function.input_schema != .object) return error.InvalidToolSchema;
        try validate_dynamic_schema(function.input_schema, 0, &schema_budget);
        try append_function(alloc, &functions, .{ .name = function.name, .description = function.description, .schema = .{ .dynamic = function.input_schema } });
    }
    if (choice == .required and functions.items.len == 0) return error.RequiredToolMissing;
    return functions;
}

const SchemaBudget = struct {
    nodes: usize = 16 * 1024,
    string_bytes: usize = 1024 * 1024,

    fn consume_string(self: *SchemaBudget, text: []const u8) Error!void {
        if (text.len > self.string_bytes or !std.unicode.utf8ValidateSlice(text)) return error.InvalidToolSchema;
        self.string_bytes -= text.len;
    }
};

fn validate_dynamic_schema(value: std.json.Value, depth: usize, budget: *SchemaBudget) Error!void {
    if (depth > max_json_depth) return error.JsonTooDeep;
    if (budget.nodes == 0) return error.InvalidToolSchema;
    budget.nodes -= 1;
    switch (value) {
        .object => |fields| {
            var iterator = fields.iterator();
            while (iterator.next()) |entry| {
                try budget.consume_string(entry.key_ptr.*);
                try validate_dynamic_schema(entry.value_ptr.*, depth + 1, budget);
            }
        },
        .array => |items| for (items.items) |item| try validate_dynamic_schema(item, depth + 1, budget),
        .string => |text| try budget.consume_string(text),
        .number_string => return error.InvalidToolSchema,
        .float => |number| if (!std.math.isFinite(number)) return error.InvalidToolSchema,
        .integer, .bool, .null => {},
    }
}

fn validate_request(request: stream_provider.RequestData, options: Options) Error!void {
    try request.validatePrompt();
    configured_provider.validate_model_id(request.model) catch return error.InvalidModel;
    const provider_options = request.provider_options;
    // Reasoning effort is a native OpenRouter request field, emitted below.
    // `fast` and `prompt_caching` carried meaning only on the retired gateway:
    // OpenRouter caches prompts implicitly and exposes no speed flag, so both
    // are accepted and carry no wire representation.
    if (provider_options.provider_order.len != 0 and options.upstream_routing == null) {
        return error.UnsupportedProviderOption;
    }
    if (request.response_format != null) return error.UnsupportedResponseFormat;
    // Inline image content on user and tool-result messages serializes natively
    // below. A fallback vision route projects its messages to text before they
    // reach this protocol and advertises the regular `vision` tool, so any
    // vision mode is a caller-side hint and not a wire constraint here.
    // Verified snapshots only flow through the vision executor's structured
    // request, which this protocol rejects above via response_format.
    if (request.verified_images != null and request.verified_images.?.len != 0) return error.UnsupportedVision;
    if (request.max_output_tokens == 0) return error.InvalidOutputLimit;
    for (request.messages) |message| {
        if (message.images.len != 0 and message.role != .user) return error.InvalidProviderPrompt;
        if (message.provider_replay != null and message.role != .assistant) return error.InvalidProviderState;
        if (message.role != .assistant and message.tool_calls.len != 0) return error.InvalidToolHistory;
        if (message.role != .tool and message.tool_call_id != null) return error.InvalidToolHistory;
        if (message.role != .assistant and message.content == null) return error.InvalidProviderPrompt;
        if (message.role == .assistant and message.content == null and message.tool_calls.len == 0 and message.provider_replay == null) return error.InvalidProviderPrompt;
    }
}

fn check_json_depth(text: []const u8) Error!void {
    var depth: usize = 0;
    var quoted = false;
    var escaped = false;
    for (text) |byte| {
        if (quoted) {
            if (escaped) {
                escaped = false;
            } else if (byte == '\\') {
                escaped = true;
            } else if (byte == '"') quoted = false;
        } else switch (byte) {
            '"' => quoted = true,
            '{', '[' => {
                if (depth == max_json_depth) return error.JsonTooDeep;
                depth += 1;
            },
            '}', ']' => if (depth > 0) {
                depth -= 1;
            },
            else => {},
        }
    }
}

/// Caller owns the bounded diagnostic. Normalize JSON before masking so later
/// diagnostic decoding cannot restore an escaped credential.
pub fn redact_error_detail(alloc: Allocator, raw: []const u8, credential: []const u8) Allocator.Error![]u8 {
    if (raw.len > 64 * 1024 or credential.len > 16 * 1024) return alloc.dupe(u8, "Provider error details exceeded the local limit");
    check_json_depth(raw) catch return alloc.dupe(u8, "Provider error details exceeded the nesting limit");
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    const json_shaped = trimmed.len != 0 and (trimmed[0] == '{' or trimmed[0] == '[' or trimmed[0] == '"');
    var parsed: ?std.json.Parsed(std.json.Value) = std.json.parseFromSlice(std.json.Value, alloc, raw, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => if (json_shaped) return alloc.dupe(u8, "Provider error details could not be decoded") else null,
    };
    defer if (parsed) |*value| value.deinit();
    const detail = if (parsed) |value| try std.json.Stringify.valueAlloc(alloc, value.value, .{}) else try alloc.dupe(u8, raw);
    if (detail.len > 64 * 1024) {
        defer alloc.free(detail);
        return alloc.dupe(u8, "Provider error details exceeded the local limit");
    }
    errdefer alloc.free(detail);
    const encoded = try std.json.Stringify.valueAlloc(alloc, credential, .{});
    defer alloc.free(encoded);
    mask_error_bytes(detail, encoded[1 .. encoded.len - 1]);
    mask_error_bytes(detail, credential);
    return detail;
}

fn mask_error_bytes(detail: []u8, value: []const u8) void {
    if (value.len == 0) return;
    var remaining = detail;
    while (std.mem.find(u8, remaining, value)) |index| {
        @memset(remaining[index..][0..value.len], '*');
        remaining = remaining[index + value.len ..];
    }
}

fn validate_arguments(alloc: Allocator, text: []const u8) Error!void {
    try check_json_depth(text);
    if (try types.ToolArgumentIntegrity.classifyFunctionInput(alloc, text) != .valid) return error.InvalidToolArguments;
}

fn validate_history(alloc: Allocator, messages: []const types.ChatMessage) Error!void {
    var pending: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer pending.deinit(alloc);
    for (messages) |message| {
        if (message.role == .tool) {
            const id = message.tool_call_id orelse return error.InvalidToolCallId;
            const name = pending.get(id) orelse return error.InvalidToolHistory;
            if (message.tool_name) |tool_name| if (!std.mem.eql(u8, tool_name, name)) return error.InvalidToolHistory;
            _ = pending.remove(id);
            continue;
        }
        if (pending.count() != 0) return error.InvalidToolHistory;
        if (message.tool_calls.len > max_selected_tools) return error.TooManyTools;
        for (message.tool_calls) |call| {
            if (call.provenance != .fx_local or call.provider_result != null) return error.UnsupportedToolProvenance;
            if (call.id.len == 0 or call.final_identity != .valid) return error.InvalidToolCallId;
            try validate_name(call.name);
            if (call.argument_integrity != .valid) return error.InvalidToolArguments;
            if (call.arguments_json.len > max_history_arguments_bytes) return error.ArgumentsTooLarge;
            try validate_arguments(alloc, call.arguments_json);
            const entry = try pending.getOrPut(alloc, call.id);
            if (entry.found_existing) return error.InvalidToolHistory;
            entry.value_ptr.* = call.name;
        }
    }
    if (pending.count() != 0) return error.InvalidToolHistory;
}

const reasoning_fields = [_][]const u8{ "reasoning", "reasoning_content" };
const association_field = "_tool_call_ids";

// The private association list never reaches the wire. Signed/encrypted metadata
// is indivisible: filtering an associated call must drop the entire sequence.
fn parse_replay(alloc: Allocator, raw: []const u8) Error!std.json.Parsed(std.json.Value) {
    if (raw.len > types.ProviderReplay.max_bytes) return error.ReplayTooLarge;
    try check_json_depth(raw);
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, raw, .{ .duplicate_field_behavior = .@"error", .parse_numbers = false }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidProviderState,
    };
    errdefer parsed.deinit();
    if (parsed.value != .object) return error.InvalidProviderState;
    const fields = parsed.value.object;
    var metadata_seen = false;
    var iterator = fields.iterator();
    while (iterator.next()) |entry| {
        const key = entry.key_ptr.*;
        const value = entry.value_ptr.*;
        if (contains_name(&reasoning_fields, key)) {
            if (value != .string and value != .null) return error.InvalidProviderState;
            metadata_seen = true;
        } else if (std.mem.eql(u8, key, "reasoning_details")) {
            if (value != .null) {
                if (value != .array) return error.InvalidProviderState;
                for (value.array.items) |item| if (item != .object) return error.InvalidProviderState;
            }
            metadata_seen = true;
        } else if (std.mem.eql(u8, key, association_field)) {
            if (value != .array or value.array.items.len > max_selected_tools) return error.InvalidProviderState;
            for (value.array.items, 0..) |id, index| {
                if (id != .string or id.string.len == 0 or id.string.len > 256) return error.InvalidProviderState;
                for (value.array.items[0..index]) |prior| if (std.mem.eql(u8, id.string, prior.string)) return error.InvalidProviderState;
            }
        } else return error.InvalidProviderState;
    }
    if (!metadata_seen or !fields.contains(association_field)) return error.InvalidProviderState;
    return parsed;
}

fn replay_calls_match(fields: std.json.ObjectMap, calls: []const types.ToolCall) bool {
    const ids = fields.get(association_field).?.array.items;
    if (ids.len != calls.len) return false;
    for (ids, calls) |id, call| if (!std.mem.eql(u8, id.string, call.id)) return false;
    return true;
}

/// Borrows the whole validated sequence or drops it; never edits opaque blocks.
pub fn project_replay(alloc: Allocator, replay: ?types.ProviderReplay, calls: []const types.ToolCall, _: bool, reasoning: bool) Error!?types.ProviderReplay {
    const value = replay orelse return null;
    if (!reasoning) return null;
    var parsed = try parse_replay(alloc, value.parts_json);
    defer parsed.deinit();
    return if (replay_calls_match(parsed.value.object, calls)) value else null;
}

fn write_replay(writer: *std.Io.Writer, alloc: Allocator, message: types.ChatMessage) (Error || std.Io.Writer.Error)!void {
    const replay = message.provider_replay orelse return;
    var parsed = try parse_replay(alloc, replay.parts_json);
    defer parsed.deinit();
    if (!replay_calls_match(parsed.value.object, message.tool_calls)) return error.InvalidProviderState;
    var fields = parsed.value.object.iterator();
    while (fields.next()) |entry| {
        if (std.mem.eql(u8, entry.key_ptr.*, association_field)) continue;
        try writer.writeByte(',');
        try std.json.Stringify.value(entry.key_ptr.*, .{}, writer);
        try writer.writeByte(':');
        try std.json.Stringify.value(entry.value_ptr.*, .{}, writer);
    }
}

/// Pure Chat Completions serialization. Caller owns the returned bytes. Model
/// IDs are opaque: no catalog lookup, prefix inference, or provider defaults.
/// max_output_tokens deliberately maps to max_tokens, not max_completion_tokens.
/// Deadline enforcement and prepared-body reuse belong to the transport owner.
pub fn build_request(alloc: Allocator, input: stream_provider.RequestData, options: Options) Error![]u8 {
    try validate_request(input, options);
    var projected: ?[]types.ChatMessage = null;
    if (options.provider) |provider| {
        projected = try types.projectProviderReplay(alloc, input.messages, .{ .provider = provider.*, .model = input.model });
    } else {
        for (input.messages) |message| if (message.provider_replay != null) return error.UnsupportedReplay;
    }
    defer if (projected) |messages| alloc.free(messages);
    var request = input;
    request.messages = projected orelse input.messages;
    try validate_history(alloc, request.messages);
    var functions = try select_functions(alloc, request.tools, request.tool_choice);
    defer functions.deinit(alloc);
    var projection = tool_call_ids.Projection.init(alloc, request.messages) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidToolCallId,
    };
    defer projection.deinit(alloc);
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    write_request(&out.writer, alloc, request, options, functions.items, &projection) catch |err| switch (err) {
        error.WriteFailed, error.OutOfMemory => return error.OutOfMemory,
        error.InvalidProviderState, error.ReplayTooLarge, error.JsonTooDeep, error.ImageUnavailable, error.InvalidProviderPrompt => |failure| return failure,
        else => return error.InvalidToolSchema,
    };
    return out.toOwnedSlice();
}

fn toolResultDenied(message: types.ChatMessage) bool {
    const failed = if (message.tool_result_status) |status|
        status == .failure
    else
        false;
    return failed and tool_result_errors.toolPermissionDenialReason(message.content orelse "") != null;
}

/// Writes one OpenAI-style image_url part. `base64_data` is already encoded.
fn write_image_url_part_encoded(writer: *std.Io.Writer, media_type: []const u8, base64_data: []const u8) !void {
    try writer.writeAll("{\"type\":\"image_url\",\"image_url\":{\"url\":\"data:");
    try writer.writeAll(media_type);
    try writer.writeAll(";base64,");
    try writer.writeAll(base64_data);
    try writer.writeAll("\"}}");
}

/// Writes one OpenAI-style image_url part from raw bytes, encoding in chunks.
fn write_image_url_part_raw(writer: *std.Io.Writer, media_type: []const u8, bytes: []const u8) !void {
    try writer.writeAll("{\"type\":\"image_url\",\"image_url\":{\"url\":\"data:");
    try writer.writeAll(media_type);
    try writer.writeAll(";base64,");
    var offset: usize = 0;
    while (offset < bytes.len) {
        const end = @min(offset + 3 * 1024, bytes.len);
        try std.base64.standard.Encoder.encodeWriter(writer, bytes[offset..end]);
        offset = end;
    }
    try writer.writeAll("\"}}");
}

/// User messages carry image attachments as content parts instead of a plain
/// string so vision-capable chat-completions models receive the pixels.
fn write_user_content_parts(
    writer: *std.Io.Writer,
    alloc: Allocator,
    message: types.ChatMessage,
) !void {
    try writer.writeByte('[');
    var wrote_part = false;
    if (message.content) |content| {
        if (content.len > 0) {
            try writer.writeAll("{\"type\":\"text\",\"text\":");
            try std.json.Stringify.value(content, .{}, writer);
            try writer.writeByte('}');
            wrote_part = true;
        }
    }
    for (message.images) |image| {
        if (wrote_part) try writer.writeByte(',');
        var snapshot = image_attachments.loadVerifiedSnapshot(alloc, image, .{}) catch return error.ImageUnavailable;
        defer snapshot.deinit(alloc);
        try write_image_url_part_raw(writer, snapshot.media_type, snapshot.bytes);
        wrote_part = true;
    }
    try writer.writeByte(']');
}

/// Emits retained tool-result images as one user message after a contiguous
/// run of tool messages; chat-completions tool messages cannot carry image
/// parts, and strict providers require tool messages to stay adjacent to the
/// assistant tool-call message they answer.
fn write_tool_image_follow_up(writer: *std.Io.Writer, alloc: Allocator, tool_names: []const []const u8, images: []const types.ToolImage) !void {
    const label = if (tool_names.len == 1)
        try std.fmt.allocPrint(alloc, "The tool \"{s}\" returned {d} image(s).", .{ tool_names[0], images.len })
    else
        try std.fmt.allocPrint(alloc, "Tool results returned {d} image(s).", .{images.len});
    defer alloc.free(label);
    try writer.writeAll("{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":");
    try std.json.Stringify.value(label, .{}, writer);
    try writer.writeByte('}');
    for (images) |image| {
        try writer.writeByte(',');
        try write_image_url_part_encoded(writer, image.mime_type, image.data);
    }
    try writer.writeAll("]}");
}

fn flush_tool_image_follow_up(
    writer: *std.Io.Writer,
    alloc: Allocator,
    count: *usize,
    pending_names: *std.ArrayList([]const u8),
    pending_images: *std.ArrayList(types.ToolImage),
) !void {
    if (pending_images.items.len == 0) return;
    if (count.* != 0) try writer.writeByte(',');
    count.* += 1;
    try write_tool_image_follow_up(writer, alloc, pending_names.items, pending_images.items);
    pending_names.clearRetainingCapacity();
    pending_images.clearRetainingCapacity();
}

fn write_request(writer: *std.Io.Writer, alloc: Allocator, request: stream_provider.RequestData, options: Options, functions: []const Function, projection: *const tool_call_ids.Projection) !void {
    try writer.writeAll("{\"model\":");
    try std.json.Stringify.value(request.model, .{}, writer);
    try writer.writeAll(",\"stream\":true,\"stream_options\":{\"include_usage\":true},\"messages\":[");
    var count: usize = 0;
    // Images from tool results buffer across each contiguous tool-message run
    // and flush as one user message when the run ends, so tool messages stay
    // adjacent to the assistant tool-call message they answer.
    var pending_names: std.ArrayList([]const u8) = .empty;
    defer pending_names.deinit(alloc);
    var pending_images: std.ArrayList(types.ToolImage) = .empty;
    defer pending_images.deinit(alloc);
    const lanes = [_][]const types.ChatMessage{ request.instructions, request.messages };
    for (lanes) |lane| {
        for (lane) |message| {
            // Source validation rejects empty assistants; only stripped replay can leave one here.
            if (message.role == .assistant and message.content == null and message.tool_calls.len == 0 and message.provider_replay == null) continue;
            if (message.role != .tool) try flush_tool_image_follow_up(writer, alloc, &count, &pending_names, &pending_images);
            if (count != 0) try writer.writeByte(',');
            count += 1;
            try writer.writeAll("{\"role\":");
            try std.json.Stringify.value(@tagName(message.role), .{}, writer);
            try writer.writeAll(",\"content\":");
            if (message.role == .user and message.images.len != 0) {
                try write_user_content_parts(writer, alloc, message);
            } else {
                try std.json.Stringify.value(message.content, .{}, writer);
            }
            try write_replay(writer, alloc, message);
            if (message.role == .tool) {
                try writer.writeAll(",\"tool_call_id\":");
                try std.json.Stringify.value(projection.resolve(message.tool_call_id.?), .{}, writer);
            }
            if (message.tool_calls.len != 0) {
                try writer.writeAll(",\"tool_calls\":[");
                for (message.tool_calls, 0..) |call, index| {
                    if (index != 0) try writer.writeByte(',');
                    try writer.writeAll("{\"id\":");
                    try std.json.Stringify.value(projection.resolve(call.id), .{}, writer);
                    try writer.writeAll(",\"type\":\"function\",\"function\":{\"name\":");
                    try std.json.Stringify.value(call.name, .{}, writer);
                    try writer.writeAll(",\"arguments\":");
                    try std.json.Stringify.value(call.arguments_json, .{}, writer);
                    try writer.writeAll("}}");
                }
                try writer.writeByte(']');
            }
            try writer.writeByte('}');
            if (message.role == .tool) {
                const tool_images = if (message.tool_result_memory) |memory| memory.tool_images else &.{};
                if (tool_images.len != 0 and !toolResultDenied(message)) {
                    try pending_names.append(alloc, message.tool_name orelse "unknown");
                    try pending_images.appendSlice(alloc, tool_images);
                }
            }
        }
        // Lane boundary: flush before the next lane starts.
        try flush_tool_image_follow_up(writer, alloc, &count, &pending_names, &pending_images);
    }
    try writer.writeByte(']');
    if (functions.len != 0) {
        try writer.writeAll(",\"tools\":[");
        for (functions, 0..) |function, index| {
            if (index != 0) try writer.writeByte(',');
            try writer.writeAll("{\"type\":\"function\",\"function\":{\"name\":");
            try std.json.Stringify.value(function.name, .{}, writer);
            try writer.writeAll(",\"description\":");
            try model_tool_schema.writeCappedDescriptionJsonString(alloc, writer, function.description);
            try writer.writeAll(",\"parameters\":");
            switch (function.schema) {
                .builtin => |schema| try model_tool_schema.writeObjectSchema(alloc, writer, schema),
                .dynamic => |schema| try std.json.Stringify.value(schema, .{}, writer),
            }
            try writer.writeAll("}}");
        }
        try writer.writeByte(']');
    }
    if (functions.len != 0) {
        if (options.tool_choice_mode == .send) {
            try writer.writeAll(",\"tool_choice\":");
            try std.json.Stringify.value(@tagName(request.tool_choice), .{}, writer);
        }
        if (request.provider_options.parallel_tool_calls) |parallel| {
            try writer.writeAll(",\"parallel_tool_calls\":");
            try std.json.Stringify.value(parallel, .{}, writer);
        }
    }
    if (request.max_output_tokens) |limit| try writer.print(",\"max_tokens\":{d}", .{limit});
    if (request.provider_options.reasoning) |reasoning| {
        try writer.writeAll(",\"reasoning\":{\"effort\":");
        try std.json.Stringify.value(reasoningWireValue(reasoning.label()), .{}, writer);
        try writer.writeByte('}');
    }
    // Upstream preferences are only sent when the user actually set an order.
    // Emitting an empty order with fallback disabled would pin every request to
    // OpenRouter's default routing instead of its normal failover.
    if (options.upstream_routing) |routing| {
        if (routing.order.len != 0) try write_upstream_routing(writer, routing);
    }
    try writer.writeByte('}');
}

/// OpenRouter normalizes reasoning efforts to its own tiers and rejects `max`,
/// which some catalogs still advertise. Map it to the highest accepted tier.
fn reasoningWireValue(label: []const u8) []const u8 {
    if (std.mem.eql(u8, label, "max")) return "high";
    return label;
}

/// OpenRouter takes upstream provider preferences in a `provider` object rather
/// than a top-level field. A strict order disables fallback so a request that
/// cannot reach the listed upstreams fails instead of rerouting.
fn write_upstream_routing(writer: anytype, routing: UpstreamRouting) !void {
    try writer.writeAll(",\"provider\":{\"order\":[");
    for (routing.order, 0..) |slug, index| {
        if (index != 0) try writer.writeByte(',');
        try std.json.Stringify.value(slug, .{}, writer);
    }
    // The trailing `}}` is an escaped literal brace closing the provider object;
    // the caller writes the request object's own closing brace.
    try writer.print("],\"allow_fallbacks\":{}}}", .{routing.allow_fallback});
}

pub const Limits = struct {
    event_bytes: usize = 1024 * 1024,
    total_wire_bytes: usize = 32 * 1024 * 1024,
    events: usize = 100_000,
    tool_calls: usize = 128,
    identity_bytes: usize = 256,
    arguments_bytes: usize = 1024 * 1024,
    content_bytes: usize = 8 * 1024 * 1024,
    reasoning_bytes: usize = types.ProviderReplay.max_bytes,
};

const ReasoningPart = struct {
    presence: enum { absent, null_value, value } = .absent,
    bytes: std.ArrayList(u8) = .empty,
};

const Deltas = struct {
    content: ?[]const u8 = null,
    reasoning: [2]?[]const u8 = @splat(null),
};

const Tool = struct {
    id: ?[]u8 = null,
    name: std.ArrayList(u8) = .empty,
    arguments: std.ArrayList(u8) = .empty,

    fn deinit(self: *Tool, alloc: Allocator) void {
        if (self.id) |id| alloc.free(id);
        self.name.deinit(alloc);
        self.arguments.deinit(alloc);
    }
};

/// Single-owner, request-local state machine. No I/O, callbacks, tool execution,
/// or hidden cancellation reads. Owns all retained input (including selected
/// names) until deinit. Any accept/finish failure poisons the reducer; deinit
/// remains mandatory. A successful finish transfers independent owned results.
pub const Reducer = struct {
    alloc: Allocator,
    limits: Limits,
    choice: types.ToolChoice,
    names: std.ArrayList([]u8) = .empty,
    tools: std.ArrayList(Tool) = .empty,
    content: std.ArrayList(u8) = .empty,
    generation_id: ?[]u8 = null,
    response_model: ?[]u8 = null,
    usage: types.Usage = .{},
    usage_total: ?u64 = null,
    usage_final_fields: packed struct(u3) {
        input: bool = false,
        output: bool = false,
        total: bool = false,
    } = .{},
    reasoning: [2]ReasoningPart = @splat(.{}),
    reasoning_details: ReasoningPart = .{},
    reasoning_bytes: usize = 0,
    refusal_seen: bool = false,
    finish_reason: ?types.ProviderFinishReason = null,
    phase: enum { receiving, finished, done, closed } = .receiving,
    event_count: usize = 0,
    json_bytes: usize = 0,

    pub fn init(alloc: Allocator, request: stream_provider.RequestData, limits: Limits) Error!Reducer {
        try validate_request(request, .{});
        var functions = try select_functions(alloc, request.tools, request.tool_choice);
        defer functions.deinit(alloc);
        var self = Reducer{ .alloc = alloc, .limits = limits, .choice = request.tool_choice };
        errdefer self.deinit();
        for (functions.items) |function| {
            const name = try alloc.dupe(u8, function.name);
            errdefer alloc.free(name);
            try self.names.append(alloc, name);
        }
        return self;
    }

    pub fn deinit(self: *Reducer) void {
        for (self.names.items) |name| self.alloc.free(name);
        self.names.deinit(self.alloc);
        for (self.tools.items) |*tool| tool.deinit(self.alloc);
        self.tools.deinit(self.alloc);
        self.content.deinit(self.alloc);
        for (&self.reasoning) |*part| part.bytes.deinit(self.alloc);
        self.reasoning_details.bytes.deinit(self.alloc);
        if (self.generation_id) |id| self.alloc.free(id);
        if (self.response_model) |model| self.alloc.free(model);
        self.* = undefined;
    }

    /// Accepts one already-framed data event. Presentation slices borrow reducer
    /// storage, not parsed JSON, until the next mutation or deinit. JSON-only
    /// callers must also bound framing wire; consume_stream includes comments.
    pub fn accept(self: *Reducer, data: []const u8, cancelled: bool) Error!Deltas {
        errdefer self.phase = .closed;
        if (cancelled) return error.Cancelled;
        if (self.phase == .closed or self.phase == .done) return error.StreamClosed;
        if (data.len > self.limits.event_bytes) return error.EventTooLarge;
        if (data.len > self.limits.total_wire_bytes - self.json_bytes) return error.StreamTooLarge;
        self.json_bytes += data.len;
        if (self.event_count == self.limits.events) return error.TooManyEvents;
        self.event_count += 1;
        if (std.mem.eql(u8, data, "[DONE]")) {
            if (self.phase != .finished) return error.IncompleteStream;
            self.phase = .done;
            return .{};
        }
        try check_json_depth(data);
        var parsed = std.json.parseFromSlice(std.json.Value, self.alloc, data, .{ .duplicate_field_behavior = .@"error", .parse_numbers = false }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidChunk,
        };
        defer parsed.deinit();
        const root = try object(parsed.value);
        if (non_null(root, "error") != null) return error.ProviderError;
        try self.accept_identity(&self.generation_id, non_null(root, "id"), self.limits.identity_bytes);
        try self.accept_identity(&self.response_model, non_null(root, "model"), configured_provider.max_model_bytes);
        const choices_value = root.get("choices") orelse return error.InvalidChunk;
        if (choices_value != .array) return error.InvalidChunk;
        const choices = choices_value.array.items;
        if (choices.len > 1) return error.InvalidChunk;
        if (choices.len == 0) {
            if (self.phase != .finished) return error.InvalidChunk;
            try self.accept_usage(non_null(root, "usage") orelse return error.InvalidChunk, true);
            return .{};
        }
        const choice = try object(choices[0]);
        if (try index_value(choice.get("index") orelse return error.InvalidChunk) != 0) return error.InvalidChunk;
        const delta = try object(choice.get("delta") orelse return error.InvalidChunk);
        if (self.phase == .finished) {
            const reason = try string(non_null(choice, "finish_reason") orelse return error.InconsistentFinishReason);
            if (!std.mem.eql(u8, reason, @tagName(self.finish_reason.?))) return error.InconsistentFinishReason;
            var fields = delta.iterator();
            while (fields.next()) |field| {
                if (std.mem.eql(u8, field.key_ptr.*, "role")) {
                    if (field.value_ptr.* != .string or !std.mem.eql(u8, field.value_ptr.string, "assistant")) return error.InconsistentFinishReason;
                } else if (std.mem.eql(u8, field.key_ptr.*, "content")) {
                    if (field.value_ptr.* != .null and (field.value_ptr.* != .string or field.value_ptr.string.len != 0)) return error.InconsistentFinishReason;
                } else return error.InconsistentFinishReason;
            }
            try self.accept_usage(non_null(root, "usage") orelse return error.InconsistentFinishReason, true);
            return .{};
        }
        if (non_null(delta, "role")) |role| if (!std.mem.eql(u8, try string(role), "assistant")) return error.InvalidChunk;
        // These fields carry semantics outside this codec's text/function subset.
        for ([_][]const u8{ "function_call", "audio" }) |key| if (non_null(delta, key) != null) return error.InvalidChunk;
        const reasoning_delta = try self.accept_reasoning(delta);
        const content_start = self.content.items.len;
        if (non_null(delta, "content")) |value| try append_bounded(self.alloc, &self.content, try string(value), self.limits.content_bytes, error.ContentTooLarge);
        if (non_null(delta, "refusal")) |value| {
            const refusal = try string(value);
            self.refusal_seen = self.refusal_seen or refusal.len != 0;
        }
        if (non_null(delta, "tool_calls")) |value| try self.accept_tools(value);
        if (non_null(root, "usage")) |usage| try self.accept_usage(usage, non_null(choice, "finish_reason") != null);
        if (non_null(choice, "finish_reason")) |value| {
            const reason = try string(value);
            self.finish_reason = if (std.mem.eql(u8, reason, "stop")) .stop else if (std.mem.eql(u8, reason, "tool_calls")) .tool_calls else if (std.mem.eql(u8, reason, "length")) .length else if (std.mem.eql(u8, reason, "content_filter")) .content_filter else return error.InvalidFinishReason;
            self.phase = .finished;
        }
        return .{
            .content = if (self.content.items.len > content_start) self.content.items[content_start..] else null,
            .reasoning = reasoning_delta,
        };
    }

    fn accept_reasoning(self: *Reducer, fields: std.json.ObjectMap) Error![2]?[]const u8 {
        var deltas: [2]?[]const u8 = @splat(null);
        for (reasoning_fields, &self.reasoning, 0..) |key, *part, index| {
            const value = fields.get(key) orelse continue;
            if (value == .null) {
                if (part.presence == .absent) part.presence = .null_value;
                continue;
            }
            const text = try string(value);
            const encoded = try std.json.Stringify.valueAlloc(self.alloc, value, .{});
            defer self.alloc.free(encoded);
            try self.count_reasoning(encoded.len);
            const start = part.bytes.items.len;
            try part.bytes.appendSlice(self.alloc, text);
            part.presence = .value;
            if (text.len != 0) deltas[index] = part.bytes.items[start..];
        }
        if (fields.get("reasoning_details")) |value| {
            const part = &self.reasoning_details;
            if (value == .null) {
                if (part.presence == .absent) part.presence = .null_value;
            } else {
                if (value != .array) return error.InvalidChunk;
                part.presence = .value;
                for (value.array.items) |item| {
                    if (item != .object) return error.InvalidChunk;
                    const encoded = try std.json.Stringify.valueAlloc(self.alloc, item, .{});
                    defer self.alloc.free(encoded);
                    try self.count_reasoning(encoded.len + 1);
                    if (part.bytes.items.len != 0) try part.bytes.append(self.alloc, ',');
                    try part.bytes.appendSlice(self.alloc, encoded);
                }
            }
        }
        return deltas;
    }

    fn count_reasoning(self: *Reducer, bytes: usize) Error!void {
        const limit = @min(self.limits.reasoning_bytes, types.ProviderReplay.max_bytes);
        if (bytes > limit - self.reasoning_bytes) return error.ReplayTooLarge;
        self.reasoning_bytes += bytes;
    }

    /// Caller owns the bounded replay envelope; accumulators remain reducer-owned.
    fn reasoning_state(self: *const Reducer) (Error || std.Io.Writer.Error)!?[]u8 {
        if (self.reasoning[0].presence == .absent and self.reasoning[1].presence == .absent and self.reasoning_details.presence == .absent) return null;
        var out: std.Io.Writer.Allocating = .init(self.alloc);
        defer out.deinit();
        try out.writer.writeByte('{');
        for (reasoning_fields, self.reasoning) |key, part| {
            if (part.presence == .absent) continue;
            try std.json.Stringify.value(key, .{}, &out.writer);
            try out.writer.writeByte(':');
            try std.json.Stringify.value(if (part.presence == .value) part.bytes.items else @as(?[]const u8, null), .{}, &out.writer);
            try out.writer.writeByte(',');
        }
        const details = self.reasoning_details;
        if (details.presence != .absent) {
            try out.writer.writeAll("\"reasoning_details\":");
            if (details.presence == .null_value) {
                try out.writer.writeAll("null");
            } else {
                try out.writer.writeByte('[');
                try out.writer.writeAll(details.bytes.items);
                try out.writer.writeByte(']');
            }
            try out.writer.writeByte(',');
        }
        try out.writer.writeAll("\"" ++ association_field ++ "\":[");
        for (self.tools.items, 0..) |tool, index| {
            if (index != 0) try out.writer.writeByte(',');
            try std.json.Stringify.value(tool.id.?, .{}, &out.writer);
        }
        try out.writer.writeAll("]}");
        if (out.written().len > @min(self.limits.reasoning_bytes, types.ProviderReplay.max_bytes)) return error.ReplayTooLarge;
        return try out.toOwnedSlice();
    }

    fn accept_identity(self: *Reducer, destination: *?[]u8, value: ?std.json.Value, max_bytes: usize) Error!void {
        const text = try string(value orelse return);
        if (text.len == 0) return error.InvalidChunk;
        if (text.len > max_bytes) return error.IdentityTooLarge;
        if (destination.*) |prior| {
            if (!std.mem.eql(u8, prior, text)) return error.ConflictingIdentity;
        } else destination.* = try self.alloc.dupe(u8, text);
    }

    fn accept_tools(self: *Reducer, value: std.json.Value) Error!void {
        if (value != .array) return error.InvalidChunk;
        if (value.array.items.len > self.limits.tool_calls) return error.TooManyTools;
        if (value.array.items.len != 0 and self.choice == .none) return error.UnexpectedToolCall;
        for (value.array.items, 0..) |item, delta_index| {
            const delta = try object(item);
            const index = try index_value(delta.get("index") orelse return error.InvalidChunk);
            if (index >= self.limits.tool_calls) return error.TooManyTools;
            for (value.array.items[0..delta_index]) |prior| {
                if (try index_value((try object(prior)).get("index") orelse return error.InvalidChunk) == index) return error.ConflictingIdentity;
            }
            while (self.tools.items.len <= index) try self.tools.append(self.alloc, .{});
            const tool = &self.tools.items[index];
            if (non_null(delta, "type")) |kind| if (!std.mem.eql(u8, try string(kind), "function")) return error.InvalidChunk;
            try self.accept_identity(&tool.id, non_null(delta, "id"), self.limits.identity_bytes);
            if (tool.id) |id| for (self.tools.items, 0..) |other, other_index| {
                if (other_index != index and other.id != null and std.mem.eql(u8, id, other.id.?)) return error.ConflictingIdentity;
            };
            if (non_null(delta, "function")) |function_value| {
                const function = try object(function_value);
                if (non_null(function, "name")) |name_value| {
                    const fragment = try string(name_value);
                    try append_bounded(self.alloc, &tool.name, fragment, @min(max_name_bytes, self.limits.identity_bytes), error.IdentityTooLarge);
                    var prefix = false;
                    for (self.names.items) |name| prefix = prefix or std.mem.startsWith(u8, name, tool.name.items);
                    if (!prefix) return error.InvalidToolName;
                }
                if (non_null(function, "arguments")) |arguments| try append_bounded(self.alloc, &tool.arguments, try string(arguments), self.limits.arguments_bytes, error.ArgumentsTooLarge);
            }
        }
    }

    fn known_name(self: *const Reducer, name: []const u8) bool {
        for (self.names.items) |candidate| if (std.mem.eql(u8, candidate, name)) return true;
        return false;
    }

    fn accept_usage(self: *Reducer, value: std.json.Value, final: bool) Error!void {
        const fields = try object(value);
        // OpenAI-compatible endpoints report optional nested breakdowns. A
        // missing block leaves that field unknown rather than zero.
        const prompt_details = try optional_object(fields, "prompt_tokens_details");
        const completion_details = try optional_object(fields, "completion_tokens_details");
        const incoming = types.Usage{
            .input_tokens = try token_count(fields, "prompt_tokens"),
            .output_tokens = try token_count(fields, "completion_tokens"),
            .cache_read_tokens = if (prompt_details) |details| try token_count(details, "cached_tokens") else null,
            .cache_write_tokens = if (prompt_details) |details| try token_count(details, "cache_creation_input_tokens") else null,
            .reasoning_tokens = if (completion_details) |details| try token_count(details, "reasoning_tokens") else null,
        };
        const incoming_total = try token_count(fields, "total_tokens");
        const usage = types.Usage{
            .input_tokens = incoming.input_tokens orelse self.usage.input_tokens,
            .output_tokens = incoming.output_tokens orelse self.usage.output_tokens,
            .cache_read_tokens = incoming.cache_read_tokens orelse self.usage.cache_read_tokens,
            .cache_write_tokens = incoming.cache_write_tokens orelse self.usage.cache_write_tokens,
            .reasoning_tokens = incoming.reasoning_tokens orelse self.usage.reasoning_tokens,
        };
        const total = incoming_total orelse self.usage_total;
        var final_fields = self.usage_final_fields;
        if (final) {
            final_fields.input = final_fields.input or incoming.input_tokens != null;
            final_fields.output = final_fields.output or incoming.output_tokens != null;
            final_fields.total = final_fields.total or incoming_total != null;
        }
        // Carried progress values are lower bounds, not current or final assertions.
        if (total) |tokens| {
            const sum = std.math.add(u64, usage.input_tokens orelse 0, usage.output_tokens orelse 0) catch return error.InvalidChunk;
            const exact = (incoming.input_tokens != null and incoming.output_tokens != null) or (final_fields.input and final_fields.output);
            if (incoming_total != null or final_fields.total) {
                if (tokens < sum or (exact and tokens != sum)) return error.InvalidChunk;
            } else if (exact and sum < tokens) return error.InvalidChunk;
        }
        for (
            [_]?u64{ self.usage.input_tokens, self.usage.output_tokens, self.usage_total },
            [_]?u64{ usage.input_tokens, usage.output_tokens, total },
            [_]bool{ self.usage_final_fields.input, self.usage_final_fields.output, self.usage_final_fields.total },
        ) |previous, current, was_final| {
            if (previous) |prior| {
                if (current.? < prior or (was_final and current.? != prior)) return error.ConflictingIdentity;
            }
        }
        self.usage = usage;
        self.usage_total = total;
        self.usage_final_fields = final_fields;
    }

    /// Requires finish_reason followed by [DONE]. Length/filter/refusal are
    /// explicit errors, never executable partial calls or successful tool turns.
    /// Results use stream_provider.Result.deinit with this reducer's allocator.
    /// Observed tokens are not exact billing; no deferred lookup is invented.
    pub fn finish(self: *Reducer, cancelled: bool) Error!stream_provider.Result {
        errdefer self.phase = .closed;
        if (cancelled) return error.Cancelled;
        if (self.phase == .closed) return error.StreamClosed;
        if (self.phase != .done) return error.IncompleteStream;
        const reason = self.finish_reason.?;
        switch (reason) {
            .length => return error.OutputTruncated,
            .content_filter => return error.ContentFiltered,
            .stop, .tool_calls => {},
            else => return error.InvalidFinishReason,
        }
        if (self.refusal_seen) return error.Refused;
        if ((reason == .tool_calls) != (self.tools.items.len != 0)) return error.InconsistentFinishReason;
        if (self.choice == .required and self.tools.items.len == 0) return error.RequiredToolMissing;
        for (self.tools.items) |tool| {
            if (tool.id == null) return error.InvalidToolCallId;
            if (!self.known_name(tool.name.items)) return error.InvalidToolName;
            try validate_arguments(self.alloc, tool.arguments.items);
        }
        const provider_state = self.reasoning_state() catch |err| switch (err) {
            error.WriteFailed => return error.OutOfMemory,
            else => |failure| return failure,
        };
        errdefer if (provider_state) |state| self.alloc.free(state);
        var calls: std.ArrayList(types.ToolCall) = .empty;
        errdefer {
            for (calls.items) |call| {
                self.alloc.free(call.id);
                self.alloc.free(call.name);
                self.alloc.free(call.arguments_json);
            }
            calls.deinit(self.alloc);
        }
        for (self.tools.items) |*tool| {
            // finish() is terminal: ownership moves to the result and the
            // emptied accumulators cost nothing at reducer deinit.
            const id = tool.id.?;
            tool.id = null;
            errdefer self.alloc.free(id);
            const name = try tool.name.toOwnedSlice(self.alloc);
            errdefer self.alloc.free(name);
            const arguments = try tool.arguments.toOwnedSlice(self.alloc);
            errdefer self.alloc.free(arguments);
            try calls.append(self.alloc, .{ .id = id, .name = name, .arguments_json = arguments });
        }
        const content = if (self.content.items.len != 0) try self.content.toOwnedSlice(self.alloc) else null;
        errdefer if (content) |text| self.alloc.free(text);
        const generation_id = self.generation_id;
        self.generation_id = null;
        errdefer if (generation_id) |id| self.alloc.free(id);
        const owned_calls = try calls.toOwnedSlice(self.alloc);
        self.phase = .closed;
        return .{ .completed = .{
            .completion = .{ .content = content, .tool_calls = owned_calls, .generation_id = generation_id, .finish_reason = reason, .usage = self.usage, .provider_state_json = provider_state },
            .ownership = .owned,
            .usage = .{ .unavailable = .possibly_billed },
        } };
    }
};

fn object(value: std.json.Value) Error!std.json.ObjectMap {
    return if (value == .object) value.object else error.InvalidChunk;
}

fn string(value: std.json.Value) Error![]const u8 {
    return if (value == .string) value.string else error.InvalidChunk;
}

fn non_null(fields: std.json.ObjectMap, key: []const u8) ?std.json.Value {
    const value = fields.get(key) orelse return null;
    return if (value == .null) null else value;
}

fn optional_object(fields: std.json.ObjectMap, key: []const u8) Error!?std.json.ObjectMap {
    const value = non_null(fields, key) orelse return null;
    return if (value == .object) value.object else error.InvalidChunk;
}

fn integer(value: std.json.Value) Error!i64 {
    // Keep opaque metadata numbers lossless, but retain integer-only counters
    // and indexes with the same range as the ordinary JSON integer parser.
    return switch (value) {
        .integer => value.integer,
        .number_string => std.fmt.parseInt(i64, value.number_string, 10) catch error.InvalidChunk,
        else => error.InvalidChunk,
    };
}

fn index_value(value: std.json.Value) Error!usize {
    return std.math.cast(usize, try integer(value)) orelse error.InvalidChunk;
}

fn token_count(fields: std.json.ObjectMap, key: []const u8) Error!?u64 {
    const value = non_null(fields, key) orelse return null;
    return std.math.cast(u64, try integer(value)) orelse error.InvalidChunk;
}

fn append_bounded(alloc: Allocator, destination: *std.ArrayList(u8), text: []const u8, limit: usize, failure: Error) Error!void {
    if (text.len > limit - destination.items.len) return failure;
    try destination.appendSlice(alloc, text);
}

/// Thin stream consumer, not a network transport. The source owns blocking-I/O
/// cancellation. EventSink receives synchronous presentation-only text. Stops
/// exactly at framed [DONE], without waiting for EOF or consuming another event.
/// event_bytes also bounds all wire between dispatched data events (including
/// ignored fields/comments); total_wire_bytes bounds the entire consumed stream.
pub fn consume_stream(alloc: Allocator, source: *std.Io.Reader, request: stream_provider.RequestData, limits: Limits, events: ?stream_provider.EventSink, cancel_flag: *const std.atomic.Value(bool)) Error!stream_provider.Result {
    if (cancel_flag.load(.seq_cst)) return error.Cancelled;
    var reducer = try Reducer.init(alloc, request, limits);
    defer reducer.deinit();
    var framing = sse.Reader{ .max_event_bytes = limits.event_bytes };
    defer framing.deinit(alloc);
    while (true) {
        const remaining = limits.total_wire_bytes - framing.total_bytes;
        const event_limited = limits.event_bytes < remaining;
        framing.max_total_bytes = framing.total_bytes + @min(limits.event_bytes, remaining);
        const data = framing.next(alloc, source, cancel_flag) catch |err| switch (err) {
            error.StreamTooLarge => return if (event_limited) error.EventTooLarge else error.StreamTooLarge,
            else => return err,
        };
        const chunk = data orelse return error.IncompleteStream;
        const deltas = try reducer.accept(chunk, cancel_flag.load(.seq_cst));
        if (events) |sink| {
            for (deltas.reasoning) |delta| if (delta) |text| {
                if (cancel_flag.load(.seq_cst)) return error.Cancelled;
                sink.emit(.{ .reasoning_delta = text });
            };
            if (deltas.content) |text| {
                if (cancel_flag.load(.seq_cst)) return error.Cancelled;
                sink.emit(.{ .content_delta = text });
            }
        }
        if (reducer.phase == .done) return reducer.finish(cancel_flag.load(.seq_cst));
    }
}

const test_functions = [_]model_tool_schema.FunctionSchema{
    .{ .name = "read_file", .description = "Read a file.", .input_schema = .{
        .properties = &.{.{ .name = "path", .json_type = .string }},
        .required = &.{"path"},
        .additional_properties = false,
    } },
    .{ .name = "shell", .description = "Run a command.", .input_schema = .{
        .properties = &.{.{ .name = "request", .json_type = .object, .shape = &.{ .object = &.{
            .properties = &.{.{ .name = "command", .json_type = .string }},
            .required = &.{"command"},
        } } }},
    } },
};

fn test_request() stream_provider.RequestData {
    return .{
        .model = "opaque/local-model:8b",
        .instructions = &.{ .{ .role = .system, .content = "first" }, .{ .role = .system, .content = "second" } },
        .messages = &.{.{ .role = .user, .content = "hi" }},
        .tool_choice = .auto,
        .provider_options = .{},
    };
}

fn test_tool_request() stream_provider.RequestData {
    var request = test_request();
    request.tools = .{ .advertised_names = &.{ "read_file", "shell" }, .advertised_functions = &test_functions };
    return request;
}

const test_stop = "{\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}";
const test_tools_finish = "{\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"tool_calls\"}]}";
const test_text = "{\"id\":\"chat-1\",\"model\":\"resolved-model\",\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":\"hello\"},\"finish_reason\":null}]}";
const test_call = "{\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call-1\",\"type\":\"function\",\"function\":{\"name\":\"read_file\",\"arguments\":\"{\\\"path\\\":\\\"x\\\"}\"}}]}}]}";

fn test_accept(reducer: *Reducer, data: []const u8) Error!void {
    _ = try reducer.accept(data, false);
}

fn test_finish(reducer: *Reducer, terminal: []const u8) Error!stream_provider.Result {
    try test_accept(reducer, terminal);
    try test_accept(reducer, "[DONE]");
    return reducer.finish(false);
}

const test_reasoning = "{\"choices\":[{\"index\":0,\"delta\":{\"reasoning\":\"inspect\",\"reasoning_content\":\"carefully\",\"reasoning_details\":[{\"type\":\"reasoning.text\",\"text\":\"first\",\"index\":0,\"signature\":\"signed\"}]}}]}";
const test_reasoning_continuation = "{\"choices\":[{\"index\":0,\"delta\":{\"reasoning_details\":[{\"type\":\"reasoning.text\",\"text\":\"second\",\"index\":0},{\"type\":\"reasoning.encrypted\",\"data\":\"opaque\",\"extra\":{\"signature\":\"nested\",\"number\":0.12345678901234567890,\"large\":18446744073709551616}}]}}]}";

fn test_provider() model_provider.ProviderId {
    var provider = model_provider.parse("local").?;
    provider.configured.binding = @splat(1);
    return provider;
}

fn test_usage_snapshot(reducer: *Reducer, usage: []const u8) Error!void {
    const choices = if (reducer.phase == .finished) "[]" else "[{\"index\":0,\"delta\":{}}]";
    const chunk = try std.fmt.allocPrint(reducer.alloc, "{{\"choices\":{s},\"usage\":{s}}}", .{ choices, usage });
    defer reducer.alloc.free(chunk);
    try test_accept(reducer, chunk);
}

fn test_allocation_paths(alloc: Allocator) !void {
    var request = test_tool_request();
    request.tool_choice = .required;
    const call: types.ToolCall = .{ .id = "functions/read:0", .name = "read_file", .arguments_json = "{\"path\":\"x\"}" };
    request.messages = &.{ .{ .role = .assistant, .tool_calls = &.{call} }, .{ .role = .tool, .tool_call_id = call.id, .content = "result" } };
    const body = try build_request(alloc, request, .{ .tool_choice_mode = .send });
    defer alloc.free(body);
    var source = std.Io.Reader.fixed("data: " ++ test_text ++ "\n\ndata: " ++ test_call ++ "\n\ndata: " ++ test_tools_finish ++ "\n\ndata: [DONE]\n\n");
    const cancelled = std.atomic.Value(bool).init(false);
    var result = try consume_stream(alloc, &source, request, .{}, null, &cancelled);
    defer result.deinit(alloc);
}
