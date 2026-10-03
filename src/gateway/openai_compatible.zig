const std = @import("std");
const definitions = @import("../core/config/configured_provider.zig");
const chat_completions = @import("chat_completions.zig");
const provider_set = @import("../core/gateway/provider_set.zig");
const provider_catalog = @import("../core/auth/provider_catalog.zig");
const model_provider = @import("../core/config/model_provider.zig");
const api_key_validator_contract = @import("../core/auth/api_key_validator.zig");
const gateway_client = @import("client.zig");
const secret = @import("../core/auth/secret.zig");
const debug_trace = @import("../core/shared/debug_trace.zig");

/// The environment variable a user may set instead of saving a key through
/// `/provider`.
pub const default_api_key_env = "FX_OPENAI_COMPATIBLE_API_KEY";
/// Endpoint used when the profile has not named its own base URL.
pub const default_base_url = "https://api.openai.com/v1";
/// Model used when the profile has not saved one. Any model the endpoint
/// serves can be selected; this is only a starting point.
pub const default_model = "gpt-4o-mini";

/// The env-variable name the endpoint definition advertises for its credential
/// slot. The transport sends the resolved credential value, so this only names
/// the slot; it does not have to exist in the environment.
pub const api_key_env = default_api_key_env;

/// Wires the OpenAI-compatible route against one endpoint definition. Every
/// callback borrows `target`, so the definition must outlive the returned
/// bundle and the provider set that carries it.
pub fn bundle(target: *const definitions.Definition) provider_set.Bundle {
    // Use the full chat-completions bundle so the route also advertises a model
    // catalog provider; without one the provider switch reports the catalog as
    // unavailable even though the endpoint is reachable.
    var wired = chat_completions.bundle(target);
    wired.capabilities = .{ .fx_search = false, .vision_fallback = true };
    wired.presentation = provider_catalog.find(.openai_compatible);
    wired.auth_strategy = .api_key;
    wired.title_model = null;
    wired.api_key_validator = .{
        .context = @ptrCast(@constCast(target)),
        .validate_fn = validateApiKeyFor,
    };
    return wired;
}

/// The probe reads the endpoint's own model catalog, so it has to accept a
/// catalog of the same size the catalog fetch does. A small bound here reported
/// every healthy large endpoint as unverifiable and refused working keys.
const max_key_probe_bytes: usize = gateway_client.gateway_models_response_max_bytes;

/// Probes the configured endpoint's `/models` list with the candidate key. A
/// network or service problem reports `unavailable`, which never talks the user
/// out of a working key.
fn validateApiKeyFor(raw: ?*anyopaque, alloc: std.mem.Allocator, api_key: []const u8) api_key_validator_contract.Result {
    const target: *const definitions.Definition = @ptrCast(@alignCast(raw.?));
    if (api_key.len == 0 or api_key.len > 1024) return .refused;
    for (api_key) |byte| {
        if (byte <= 0x20 or byte >= 0x7f) return .refused;
    }
    const probe_url = std.mem.concat(alloc, u8, &.{ target.base_url, "/models" }) catch return .unavailable;
    defer alloc.free(probe_url);
    const authorization = std.fmt.allocPrint(alloc, "Bearer {s}", .{api_key}) catch return .unavailable;
    defer secret.zeroAndFree(alloc, authorization);
    const headers: std.http.Client.Request.Headers = .{
        .authorization = .{ .override = authorization },
        .user_agent = .{ .override = gateway_client.user_agent },
        .accept_encoding = .omit,
    };
    const result = gateway_client.fetchBoundedHttp(alloc, .GET, probe_url, null, headers, &.{}, max_key_probe_bytes) catch |err| {
        debug_trace.logf("openai-compatible", "key probe failed url={s} err={s}", .{ probe_url, @errorName(err) });
        return .unavailable;
    };
    defer secret.zeroAndFree(alloc, result.body);
    return switch (result.status) {
        .ok => .accepted,
        .unauthorized, .forbidden, .payment_required => .refused,
        else => .unavailable,
    };
}

/// Identity used by the model catalog for this route.
pub const provider_id: model_provider.ProviderId = .openai_compatible;
