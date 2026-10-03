const std = @import("std");
const credentials = @import("../core/auth/credentials.zig");
const model_catalog = @import("../core/gateway/model_catalog.zig");
const gateway_provider = @import("../core/gateway/gateway_provider.zig");
const gateway_client = @import("client.zig");
const model_policy = @import("groq_model_policy.zig");
const io_mod = @import("../core/shared/io.zig");
const secret = @import("../core/auth/secret.zig");

const Allocator = std.mem.Allocator;

/// Groq lists its full active catalog in one OpenAI-style response. The bound
/// keeps a single response from exhausting the picker.
const max_catalog_models: usize = 512;
const max_model_id_bytes: usize = 256;
const max_catalog_bytes: usize = 8 * 1024 * 1024;
const fetch_timeout_ms: i64 = 30_000;

pub const default_models_endpoint = "https://api.groq.com/openai/v1/models";
const e2e_models_endpoint_env = "FX_E2E_GROQ_MODELS_URL";

pub const model_catalog_provider = model_catalog.Provider{
    .fetch_fn = fetchCatalogForProvider,
    .provider_id = .groq,
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

/// Groq's catalog is keyed by account, so a credential is required. A
/// host-managed request carries no local bytes; a public-only request carries
/// none either.
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
            error.GatewayResponseTooLarge => return error.GroqModelCatalogTooLarge,
            else => return err,
        };
        return .{
            .status = result.status,
            .body = result.body,
        };
    }
};

/// Parses a Groq `/models` payload into owned catalog entries. Groq returns an
/// OpenAI-style `{ "object": "list", "data": [ ... ] }` where each entry has
/// `id`, `created`, `active`, and `context_window`. Entries with `active: false`
/// are retired and skipped. Groq publishes no `supported_parameters` array, so
/// every active model is kept and the fallback policy describes capabilities.
pub fn parseCatalog(
    alloc: Allocator,
    json_text: []const u8,
) !std.ArrayList(model_catalog.ModelCatalogEntry) {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, json_text, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidGroqModelCatalog;
    const data = parsed.value.object.get("data") orelse return error.InvalidGroqModelCatalog;
    if (data != .array or data.array.items.len > max_catalog_models) {
        return error.InvalidGroqModelCatalog;
    }

    var catalog: std.ArrayList(model_catalog.ModelCatalogEntry) = .empty;
    errdefer model_catalog.freeModelCatalog(alloc, &catalog);
    for (data.array.items) |value| {
        if (value != .object) return error.InvalidGroqModelCatalog;
        const object = value.object;
        const id = object.get("id") orelse return error.InvalidGroqModelCatalog;
        if (id != .string) return error.InvalidGroqModelCatalog;
        try validateModelId(id.string);
        if (!activeModel(object)) continue;
        // Speech, text-to-speech, and guard models cannot drive an agent turn,
        // so they never reach the model picker.
        if (model_policy.isNonChatModel(id.string)) continue;

        const owned_id = try alloc.dupe(u8, id.string);
        errdefer alloc.free(owned_id);
        const model_type = try alloc.dupe(u8, "language");
        errdefer alloc.free(model_type);
        const context_window = try positiveU32(object, "context_window");
        const owned_by = object.get("owned_by");
        const owned_by_name = if (owned_by != null and owned_by.? == .string) owned_by.?.string else "";

        try catalog.append(alloc, .{
            .id = owned_id,
            .model_type = model_type,
            .released = try optionalTimestamp(object, "created"),
            .has_tool_use = true,
            .has_reasoning = false,
            .supports_fast_mode = false,
            .has_vision = containsIgnoreCase(owned_by_name, "vision"),
            .has_file_input = false,
            .has_implicit_caching = false,
            .context_window = context_window,
            .max_tokens = 0,
        });
    }
    return catalog;
}

fn activeModel(object: std.json.ObjectMap) bool {
    const value = object.get("active") orelse return true;
    if (value == .bool) return value.bool;
    return true;
}

fn validateModelId(id: []const u8) !void {
    if (id.len == 0 or id.len > max_model_id_bytes) return error.InvalidGroqModelCatalog;
    if (std.mem.findScalar(u8, id, '?') != null or std.mem.findScalar(u8, id, '#') != null) {
        return error.InvalidGroqModelCatalog;
    }
    for (id) |byte| {
        if (byte <= 0x20 or byte == 0x7f) return error.InvalidGroqModelCatalog;
    }
}

fn positiveU32(object: std.json.ObjectMap, key: []const u8) !u32 {
    const value = object.get(key) orelse return 0;
    if (value == .null) return 0;
    if (value != .integer or value.integer < 0) return error.InvalidGroqModelCatalog;
    return std.math.cast(u32, value.integer) orelse error.InvalidGroqModelCatalog;
}

fn optionalTimestamp(object: std.json.ObjectMap, key: []const u8) !i64 {
    const value = object.get(key) orelse return 0;
    if (value == .null) return 0;
    if (value != .integer) return error.InvalidGroqModelCatalog;
    return value.integer;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    const last_start = haystack.len - needle.len;
    var index: usize = 0;
    while (index <= last_start) : (index += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[index .. index + needle.len], needle)) return true;
    }
    return false;
}
