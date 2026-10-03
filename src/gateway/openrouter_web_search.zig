const std = @import("std");
const client_mod = @import("client.zig");
const codec = @import("chat_completions_protocol.zig");
const io_mod = @import("../core/shared/io.zig");
const openrouter = @import("openrouter.zig");
const secret = @import("../core/auth/secret.zig");
const types = @import("../core/shared/types.zig");
const web_search_contract = @import("../core/tooling/web_search_contract.zig");
const web_search_policy = @import("../core/tooling/web_search_policy.zig");
const web_search_provider = @import("../core/tooling/web_search_provider.zig");

const Allocator = std.mem.Allocator;

/// OpenRouter exposes one web backend through its `web` request plugin. The
/// domain filters are passed straight through, so a caller that asks for a
/// strict allow or block list gets provider-enforced filtering rather than a
/// locally narrowed result set.
pub const backend = web_search_contract.SearchBackendId{ .value = "openrouter_web" };

const max_response_bytes: usize = 1024 * 1024;
const max_domain_entries: usize = 32;
const max_domain_bytes: usize = 253;
/// The request body is fixed-shape, so a writer failure can only be the bound.
const BuildError = Allocator.Error || error{WriteFailed};
const open_timeout_ms: i64 = 15_000;

/// The worker model is the same model the agent runs, so a search answer shares
/// the agent's reasoning quality and billing surface.
pub const provider = web_search_provider.Provider{
    .policy = .{
        .preferred_backends = &.{backend},
        .backend_policies = &.{.{
            .id = backend,
            .features = .{
                // OpenRouter bills one request per call and does not expose a
                // separate multi-search budget, so max_uses is a local best
                // effort rather than a provider guarantee.
                .max_uses = .best_effort,
                .allowed_domains = .pass_through,
                .blocked_domains = .pass_through,
                .ordered_sources = true,
                .usage = true,
                .terminal_incomplete = true,
                .timeout = true,
                .cancellation = true,
                .result_bounds = .post_filter,
            },
        }},
    },
    .preferred_backends_fn = preferredBackends,
    .execute_fn = execute,
};

fn preferredBackends(_: ?*anyopaque) !?[]const web_search_contract.SearchBackendId {
    return provider.policy.preferred_backends;
}

const http_headers = [_]std.http.Header{
    .{ .name = "accept", .value = "application/json" },
    .{ .name = openrouter.definition.headers[0].name, .value = openrouter.definition.headers[0].value },
    .{ .name = openrouter.definition.headers[1].name, .value = openrouter.definition.headers[1].value },
};

fn execute(
    _: ?*anyopaque,
    alloc: Allocator,
    inputs: web_search_provider.Inputs,
    request: web_search_contract.ProviderRequest,
    on_progress: ?web_search_contract.ProgressFn,
    progress_ctx: ?*anyopaque,
) anyerror!web_search_contract.ProviderResponse {
    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
    if (inputs.credential_source != .openrouter_api_key and inputs.credential_source != .stored_key) {
        return error.Unauthorized;
    }
    if (inputs.api_key.len == 0 or inputs.api_key.len > 16 * 1024) return error.Unauthorized;
    if (request.query.len == 0) return error.InvalidRequest;

    if (on_progress) |callback| {
        if (progress_ctx) |ctx| callback(ctx, .{ .query_update = request.query });
    }

    const body = try buildBody(alloc, inputs, request);
    defer alloc.free(body);

    var client: std.http.Client = .{ .allocator = alloc, .io = io_mod.getIo() };
    defer client.deinit();
    const authorization = try std.fmt.allocPrint(alloc, "Bearer {s}", .{inputs.api_key});
    defer secret.zeroAndFree(alloc, authorization);
    var uri = try std.Uri.parse(openrouter.chat_url);
    uri.scheme = "https";
    var operation = client_mod.PostOperation{
        .client = &client,
        .uri = uri,
        .authorization = authorization,
        .extra_headers = &http_headers,
    };
    var opened = try client_mod.openBoundedPost(alloc, request.cancel_flag, deadline(request.timeout_ms), &operation);
    defer opened.deinit(alloc);
    const http = &opened.request.?;
    http.transfer_encoding = .{ .content_length = body.len };
    var send_buffer: [4096]u8 = undefined;
    var outgoing = try http.sendBodyUnflushed(&send_buffer);
    try outgoing.writer.writeAll(body);
    try outgoing.end();
    if (http.connection) |connection| try connection.flush();

    var response = try http.receiveHead(&.{});
    var transfer: [64 * 1024]u8 = undefined;
    const reader = response.reader(&transfer);
    if (response.head.status != .ok) {
        const detail = reader.allocRemaining(alloc, .limited(max_response_bytes)) catch |err| switch (err) {
            error.StreamTooLong => try alloc.dupe(u8, "OpenRouter search error response exceeded the local limit"),
            else => return err,
        };
        defer alloc.free(detail);
        // Mask before the diagnostic can reach a log or the transcript, then
        // classify the status so the caller can distinguish auth from load.
        const redacted = try codec.redact_error_detail(alloc, detail, inputs.api_key);
        defer alloc.free(redacted);
        return switch (response.head.status) {
            .unauthorized, .forbidden => error.Unauthorized,
            .too_many_requests => error.RateLimited,
            else => error.ProviderFailed,
        };
    }
    const payload = try reader.allocRemaining(alloc, .limited(max_response_bytes));
    defer secret.zeroAndFree(alloc, payload);
    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;

    return parseResponse(alloc, payload, request, on_progress, progress_ctx);
}

fn deadline(timeout_ms: u32) std.Io.Clock.Timestamp {
    const budget: i64 = @intCast(@min(timeout_ms, @as(u32, std.math.maxInt(i32))));
    return std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
        .clock = .awake,
        .raw = .fromMilliseconds(@max(@min(budget, open_timeout_ms + 15_000), 1_000)),
    });
}

fn buildBody(
    alloc: Allocator,
    inputs: web_search_provider.Inputs,
    request: web_search_contract.ProviderRequest,
) BuildError![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const writer = &out.writer;
    try writer.writeAll("{\"model\":");
    try std.json.Stringify.value(inputs.worker_model, .{}, writer);
    try writer.writeAll(",\"stream\":false,\"max_tokens\":");
    try writer.print("{d}", .{request.max_output_tokens});
    try writer.writeAll(",\"messages\":[{\"role\":\"user\",\"content\":");
    try std.json.Stringify.value(request.query, .{}, writer);
    try writer.writeAll("}],\"plugins\":[{\"id\":\"web\",\"max_results\":");
    try writer.print("{d}", .{request.max_results});
    if (request.allowed_domains) |domains| try writeDomains(writer, "allowed_domains", domains);
    if (request.blocked_domains) |domains| try writeDomains(writer, "blocked_domains", domains);
    try writer.writeAll("}]}");
    return out.toOwnedSlice();
}

fn writeDomains(writer: anytype, key: []const u8, domains: []const []const u8) BuildError!void {
    if (domains.len == 0 or domains.len > max_domain_entries) return;
    try writer.print(",\"{s}\":[", .{key});
    var written: usize = 0;
    for (domains) |domain| {
        if (domain.len == 0 or domain.len > max_domain_bytes) continue;
        if (written != 0) try writer.writeByte(',');
        try std.json.Stringify.value(domain, .{}, writer);
        written += 1;
    }
    try writer.writeByte(']');
}

fn parseResponse(
    alloc: Allocator,
    payload: []const u8,
    request: web_search_contract.ProviderRequest,
    on_progress: ?web_search_contract.ProgressFn,
    progress_ctx: ?*anyopaque,
) !web_search_contract.ProviderResponse {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, payload, .{}) catch
        return error.MalformedResponse;
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return error.MalformedResponse;

    var response = web_search_contract.ProviderResponse{};
    errdefer response.deinit(alloc);
    var items: std.ArrayList(web_search_contract.ResultItem) = .empty;
    errdefer freeItems(alloc, &items);
    var sources: std.ArrayList(web_search_contract.Source) = .empty;
    defer {
        for (sources.items) |source| source.deinit(alloc);
        sources.deinit(alloc);
    }

    // OpenRouter returns a single assistant message. The answer text is the
    // commentary block and the cited pages are the search block.
    if (textOf(root)) |text| {
        if (text.len > 0) {
            try items.append(alloc, .{ .commentary = try alloc.dupe(u8, text) });
        }
    }
    try collectCitations(alloc, root, request.max_results, &sources);
    const result_count = sources.items.len;
    if (result_count > 0) {
        const content = try sources.toOwnedSlice(alloc);
        sources = .empty;
        try items.append(alloc, .{ .search = .{ .tool_use_id = "openrouter-web", .content = content } });
    }
    if (on_progress) |callback| {
        if (progress_ctx) |ctx| callback(ctx, .{ .results_received = .{
            .query = request.query,
            .result_count = result_count,
        } });
    }

    const finish_reason = finishReason(root);
    if (finish_reason) |reason| {
        if (std.mem.eql(u8, reason, "length") or std.mem.eql(u8, reason, "content_filter")) {
            try items.append(alloc, .{ .terminal_incomplete = .{
                .stop_reason = try alloc.dupe(u8, reason),
                .message = try alloc.dupe(u8, "OpenRouter stopped the search answer before it finished."),
            } });
        }
        response.stop_reason = try alloc.dupe(u8, reason);
    }
    response.usage = try readUsage(alloc, root);
    response.content = try items.toOwnedSlice(alloc);
    return response;
}

fn freeItems(alloc: Allocator, items: *std.ArrayList(web_search_contract.ResultItem)) void {
    for (items.items) |item| item.deinit(alloc);
    items.deinit(alloc);
}

fn textOf(root: std.json.Value) ?[]const u8 {
    const choices = root.object.get("choices") orelse return null;
    if (choices != .array or choices.array.items.len == 0) return null;
    const message = choices.array.items[0].object.get("message") orelse return null;
    if (message != .object) return null;
    const content = message.object.get("content") orelse return null;
    if (content != .string) return null;
    return content.string;
}

fn finishReason(root: std.json.Value) ?[]const u8 {
    const choices = root.object.get("choices") orelse return null;
    if (choices != .array or choices.array.items.len == 0) return null;
    const reason = choices.array.items[0].object.get("finish_reason") orelse return null;
    if (reason != .string) return null;
    return reason.string;
}

fn collectCitations(
    alloc: Allocator,
    root: std.json.Value,
    max_results: u8,
    out: *std.ArrayList(web_search_contract.Source),
) !void {
    const choices = root.object.get("choices") orelse return;
    if (choices != .array or choices.array.items.len == 0) return;
    const message = choices.array.items[0].object.get("message") orelse return;
    if (message != .object) return;
    const annotations = message.object.get("annotations") orelse return;
    if (annotations != .array or annotations.array.items.len > 256) return;
    for (annotations.array.items) |annotation| {
        if (out.items.len >= max_results) return;
        if (annotation != .object) continue;
        const kind = annotation.object.get("type") orelse continue;
        if (kind != .string or !std.mem.eql(u8, kind.string, "url_citation")) continue;
        const citation = annotation.object.get("url_citation") orelse continue;
        if (citation != .object) continue;
        const url_value = citation.object.get("url") orelse continue;
        if (url_value != .string or url_value.string.len == 0) continue;
        const title_value = citation.object.get("title");
        const title = if (title_value) |value|
            if (value == .string and value.string.len > 0) value.string else url_value.string
        else
            url_value.string;
        try out.append(alloc, .{
            .title = try alloc.dupe(u8, title),
            .url = try alloc.dupe(u8, url_value.string),
        });
    }
}

fn readUsage(alloc: Allocator, root: std.json.Value) !?types.ToolUsage {
    _ = alloc;
    const usage_value = root.object.get("usage") orelse return null;
    if (usage_value != .object) return null;
    var usage = types.ToolUsage{};
    if (numberOf(usage_value.object, "prompt_tokens")) |value| usage.input_tokens = value;
    if (numberOf(usage_value.object, "completion_tokens")) |value| usage.output_tokens = value;
    // The plugin ran for this request, so a call always bills one search even
    // when the endpoint reports no separate counter.
    usage.web_search_requests = if (numberOf(usage_value.object, "web_search_requests")) |value|
        std.math.cast(u32, value) orelse 1
    else
        1;
    return usage;
}

fn numberOf(object: std.json.ObjectMap, key: []const u8) ?u64 {
    const value = object.get(key) orelse return null;
    if (value != .integer or value.integer < 0) return null;
    return std.math.cast(u64, value.integer);
}

const _ = web_search_policy;
