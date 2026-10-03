const std = @import("std");
const credentials = @import("../core/auth/credentials.zig");
const model_catalog = @import("../core/gateway/model_catalog.zig");
const gateway_provider = @import("../core/gateway/gateway_provider.zig");
const gateway_client = @import("client.zig");
const io_mod = @import("../core/shared/io.zig");
const secret = @import("../core/auth/secret.zig");
const types = @import("../core/shared/types.zig");

const Allocator = std.mem.Allocator;

/// OpenRouter lists the full routable catalog in one response. The bound keeps a
/// single response from exhausting the picker, and matches the endpoint's own
/// order so the vendor ranking upstream applies is preserved.
const max_catalog_models: usize = 512;
const max_model_id_bytes: usize = 256;
const max_catalog_bytes: usize = 8 * 1024 * 1024;
const fetch_timeout_ms: i64 = 30_000;
const max_parameter_entries: usize = 64;
const max_input_modalities: usize = 8;

pub const default_models_endpoint = "https://openrouter.ai/api/v1/models";
const e2e_models_endpoint_env = "FX_E2E_OPENROUTER_MODELS_URL";

pub const model_catalog_provider = model_catalog.Provider{
    .fetch_fn = fetchCatalogForProvider,
    .provider_id = .openrouter,
    .refresh_interval_ms = 10 * 60_000,
};

pub const cli_model_catalog_provider = gateway_provider.CliModelCatalogProvider{
    .fetch_fn = fetchCliModelCatalog,
};

pub fn modelsEndpoint() []const u8 {
    return io_mod.getenv(e2e_models_endpoint_env) orelse default_models_endpoint;
}

fn fetchCliModelCatalog(
    _: ?*anyopaque,
    alloc: Allocator,
    input: gateway_provider.CliModelCatalogInput,
) gateway_provider.CliModelCatalogResult {
    return switch (model_catalog.fetchWithPublicFallback(model_catalog_provider, alloc, .{
        .access = input.access,
        .endpoint = input.endpoint,
        .cancel_flag = input.cancel_flag,
        .view = .full,
    })) {
        .loaded => |loaded| blk: {
            var catalog = loaded.catalog;
            defer model_catalog.freeModelCatalog(alloc, &catalog);
            const ids = model_catalog.projectModelIds(alloc, catalog.items) catch return .{ .failure = .{
                .access = loaded.provenance.access,
                .anonymous_fallback_used = false,
                .failure = .{ .category = .resource_exhausted },
            } };
            break :blk .{ .loaded = .{
                .ids = ids,
                .provenance = loaded.provenance,
            } };
        },
        .failed => |failure| .{ .failure = failure },
    };
}

fn fetchCatalogForProvider(
    _: ?*anyopaque,
    alloc: Allocator,
    input: model_catalog.FetchInput,
) Allocator.Error!model_catalog.ProviderResult {
    const credential = catalogRequestCredential(input.access) orelse
        return .{ .failure = .{ .category = .authentication, .http_status = .unauthorized } };
    var fallback_cancel = std.atomic.Value(bool).init(false);
    const cancel_flag = input.cancel_flag orelse &fallback_cancel;
    const deadline = std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
        .clock = .awake,
        .raw = .fromMilliseconds(fetch_timeout_ms),
    });
    const url = modelsEndpoint();
    if (io_mod.getenv(e2e_models_endpoint_env) != null and !gateway_client.isLoopbackHttpUrl(url)) {
        return .{ .failure = .{ .category = .runtime } };
    }

    var operation = FetchOperation{ .alloc = alloc, .url = url, .credential = credential };
    var response = gateway_client.runBoundedHttpOperation(
        FetchResponse,
        alloc,
        cancel_flag,
        deadline,
        &operation,
    ) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .{ .failure = .{
            .category = if (err == error.Cancelled) .cancellation else .transport,
            .retryable = err != error.Cancelled,
        } };
    };
    defer response.deinit(alloc);
    if (response.status != .ok) {
        return .{ .failure = model_catalog.failureForHttpStatus(response.status) };
    }
    return .{ .catalog = parseCatalog(alloc, response.body) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .{ .failure = .{ .category = .malformed_response, .http_status = .ok } };
    } };
}

/// OpenRouter publishes its catalog without authentication, so a credential is
/// optional. A host-managed request carries no local bytes and sends none.
fn catalogRequestCredential(access: credentials.CatalogAccess) ?[]const u8 {
    return switch (access) {
        .host_managed => null,
        .public_only => null,
        .authenticated => |authenticated| authenticated.credential,
    };
}

const FetchResponse = struct {
    status: std.http.Status,
    body: []u8,

    pub fn deinit(self: *FetchResponse, alloc: Allocator) void {
        secret.zeroAndFree(alloc, self.body);
        self.* = undefined;
    }
};

const FetchOperation = struct {
    alloc: Allocator,
    url: []const u8,
    credential: ?[]const u8,

    pub fn run(self: *@This()) !FetchResponse {
        var auth_header: ?[]u8 = null;
        defer if (auth_header) |value| secret.zeroAndFree(self.alloc, value);
        var headers: std.http.Client.Request.Headers = .{
            .user_agent = .{ .override = gateway_client.user_agent },
            .accept_encoding = .omit,
        };
        if (self.credential) |credential| {
            auth_header = try std.fmt.allocPrint(self.alloc, "Bearer {s}", .{credential});
            headers.authorization = .{ .override = auth_header.? };
        }
        const extra_headers = [_]std.http.Header{
            .{ .name = "accept", .value = "application/json" },
        };
        const result = gateway_client.fetchBoundedHttp(self.alloc, .GET, self.url, null, headers, &extra_headers, max_catalog_bytes) catch |err| switch (err) {
            error.GatewayResponseTooLarge => return error.OpenRouterModelCatalogTooLarge,
            else => return err,
        };
        return .{
            .status = result.status,
            .body = result.body,
        };
    }
};

/// Parses an OpenRouter `/models` payload into owned catalog entries so every
/// caller agrees on which models are offered and what capabilities they declare.
pub fn parseCatalog(
    alloc: Allocator,
    json_text: []const u8,
) !std.ArrayList(model_catalog.ModelCatalogEntry) {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, json_text, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidOpenRouterModelCatalog;
    const data = parsed.value.object.get("data") orelse return error.InvalidOpenRouterModelCatalog;
    if (data != .array or data.array.items.len > max_catalog_models) {
        return error.InvalidOpenRouterModelCatalog;
    }

    var catalog: std.ArrayList(model_catalog.ModelCatalogEntry) = .empty;
    errdefer model_catalog.freeModelCatalog(alloc, &catalog);
    for (data.array.items) |value| {
        if (value != .object) return error.InvalidOpenRouterModelCatalog;
        const object = value.object;
        const id = object.get("id") orelse return error.InvalidOpenRouterModelCatalog;
        if (id != .string) return error.InvalidOpenRouterModelCatalog;
        try validateModelId(id.string);
        // A model with no tools cannot drive the agent, so it is not offered.
        if (!stringArrayContains(object, "supported_parameters", "tools")) continue;

        const owned_id = try alloc.dupe(u8, id.string);
        errdefer alloc.free(owned_id);
        const model_type = try alloc.dupe(u8, "language");
        errdefer alloc.free(model_type);
        const vision = inputModalitiesContain(object, "image");
        const file_input = inputModalitiesContain(object, "file");
        const context_window = try positiveU32(object, "context_length");
        const max_tokens = if (object.get("top_provider")) |top|
            if (top == .object) try positiveU32(top.object, "max_completion_tokens") else 0
        else
            0;

        try catalog.append(alloc, .{
            .id = owned_id,
            .model_type = model_type,
            .released = try optionalTimestamp(object, "created"),
            .has_tool_use = true,
            .has_reasoning = stringArrayContains(object, "supported_parameters", "reasoning") or
                stringArrayContains(object, "supported_parameters", "reasoning_effort"),
            .supports_fast_mode = false,
            .has_vision = vision,
            .has_file_input = vision or file_input,
            // OpenRouter reports cached prompt tokens in the standard
            // `prompt_tokens_details` block, so caching is provider-reported.
            .has_implicit_caching = true,
            .context_window = context_window,
            .max_tokens = max_tokens,
        });
    }
    return catalog;
}

fn validateModelId(id: []const u8) !void {
    if (id.len == 0 or id.len > max_model_id_bytes) return error.InvalidOpenRouterModelCatalog;
    if (std.mem.findScalar(u8, id, '?') != null or std.mem.findScalar(u8, id, '#') != null) {
        return error.InvalidOpenRouterModelCatalog;
    }
    for (id) |byte| {
        if (byte <= 0x20 or byte == 0x7f) return error.InvalidOpenRouterModelCatalog;
    }
}

fn stringArrayContains(object: std.json.ObjectMap, key: []const u8, expected: []const u8) bool {
    const value = object.get(key) orelse return false;
    if (value != .array or value.array.items.len > max_parameter_entries) return false;
    for (value.array.items) |entry| {
        if (entry == .string and std.mem.eql(u8, entry.string, expected)) return true;
    }
    return false;
}

fn inputModalitiesContain(object: std.json.ObjectMap, expected: []const u8) bool {
    const architecture = object.get("architecture") orelse return false;
    if (architecture != .object) return false;
    const value = architecture.object.get("input_modalities") orelse return false;
    if (value != .array or value.array.items.len > max_input_modalities) return false;
    for (value.array.items) |entry| {
        if (entry == .string and std.mem.eql(u8, entry.string, expected)) return true;
    }
    return false;
}

fn positiveU32(object: std.json.ObjectMap, key: []const u8) !u32 {
    const value = object.get(key) orelse return 0;
    if (value == .null) return 0;
    if (value != .integer or value.integer < 0) return error.InvalidOpenRouterModelCatalog;
    return std.math.cast(u32, value.integer) orelse error.InvalidOpenRouterModelCatalog;
}

fn optionalTimestamp(object: std.json.ObjectMap, key: []const u8) !i64 {
    const value = object.get(key) orelse return 0;
    if (value == .null) return 0;
    if (value != .integer) return error.InvalidOpenRouterModelCatalog;
    return value.integer;
}
