const std = @import("std");
const api_key_validator_contract = @import("../core/auth/api_key_validator.zig");
const chat_completions = @import("chat_completions.zig");
const endpoint = @import("groq_endpoint.zig");
const gateway_client = @import("client.zig");
const debug_trace = @import("../core/shared/debug_trace.zig");
const io_mod = @import("../core/shared/io.zig");
const secret = @import("../core/auth/secret.zig");
const codec = @import("chat_completions_protocol.zig");
const definitions = @import("../core/config/configured_provider.zig");
const model_capabilities = @import("../core/config/model_capabilities.zig");
const model_provider = @import("../core/config/model_provider.zig");
const model_policy = @import("groq_model_policy.zig");
const models = @import("groq_models.zig");
const provider_catalog = @import("../core/auth/provider_catalog.zig");
const provider_set = @import("../core/gateway/provider_set.zig");
const streams = @import("../core/agent/stream_provider.zig");

/// Groq is the second built-in provider beside OpenRouter. It speaks the same
/// OpenAI chat completions protocol, so the shared chat-completions transport
/// carries the wire format and the only Groq-specific surface is the live model
/// catalog plus the endpoint's own address and key slot.
///
/// The endpoint and key slot below are defaults, not fixed values: the key is
/// only ever read from the environment or saved through `/provider`, and no
/// credential is compiled in. Unlike OpenRouter, Groq is not user-retargetable
/// in the first cut, so `is_builtin_override` stays false.
pub const base_url = endpoint.default_base_url;
pub const api_key_env = endpoint.default_api_key_env;

/// Used when no model has been selected yet. Chosen for tool use and a long
/// context window; the settings parser reads the same value from the endpoint
/// leaf so the two cannot drift apart.
pub const default_model = endpoint.default_model;
/// The security review side call runs on the same strong model as the agent.
pub const reviewer_model = default_model;
/// Titles are a short text-only call, so the cheapest capable model is enough.
pub const title_model = "llama-3.1-8b-instant";

/// Static storage. Every callback below borrows this definition for the life of
/// the process, so the transport context never dangles.
pub const definition: definitions.Definition = .{
    .id = endpoint.default_base_url_id,
    .protocol = .@"openai-chat-completions",
    .base_url = base_url,
    .auth = .{ .bearer = api_key_env },
    .credential_sources = &.{ .groq_api_key, .groq_stored_key },
    .tool_choice_mode = .send,
    // Groq publishes no OpenRouter-style upstream routing object, so the shared
    // transport refuses `provider_order` and `provider_strict` rather than
    // silently dropping them.
    .upstream_routing = false,
    .headers = &.{},
    .is_builtin_override = false,
    .reviewer_model = reviewer_model,
};

/// Wires the full Groq route against one endpoint definition. Every callback
/// borrows `target` for as long as the returned bundle is reachable, so the
/// definition must outlive the provider set that carries the bundle.
pub fn bundle(target: *const definitions.Definition) provider_set.Bundle {
    var wired = chat_completions.transport_bundle(target);
    wired.capabilities = .{ .fx_search = false, .vision_fallback = true };
    wired.presentation = provider_catalog.find(.groq);
    wired.auth_strategy = .api_key;
    wired.title_model = title_model;
    wired.fallback_model_capabilities_fn = model_policy.capabilitiesForModel;
    wired.model_catalog = .{
        .fetch_fn = models.model_catalog_provider.fetch_fn,
        .provider_id = .groq,
        .refresh_interval_ms = models.model_catalog_provider.refresh_interval_ms,
    };
    wired.cli_model_catalog = models.cli_model_catalog_provider;
    wired.api_key_validator = .{
        .context = @ptrCast(@constCast(target)),
        .validate_fn = validateApiKeyFor,
    };
    return wired;
}

pub const provider_bundle: provider_set.Bundle = bundle(&definition);

/// Model used when the profile has no saved selection. Kept next to the
/// endpoint definition so the two cannot drift apart.
pub fn defaultModel() []const u8 {
    return default_model;
}

/// Streaming endpoint, derived from the same base URL the transport uses so the
/// two cannot drift apart.
pub const chat_url = base_url ++ "/chat/completions";
pub const models_path = base_url ++ "/models";
/// Bounded retry budget for one agent turn against the Groq endpoint.
pub const retry_count: u8 = 3;

/// Confirms a candidate key against the compiled default endpoint. Prefer
/// `bundle.?.api_key_validator`, which probes whichever address is configured.
pub const api_key_validator = api_key_validator_contract.Provider{
    .context = @ptrCast(@constCast(&definition)),
    .validate_fn = validateApiKeyFor,
};

const key_probe_timeout_ms: i64 = 15_000;
const max_key_probe_bytes: usize = 8 * 1024;

/// Groq publishes no `/key` endpoint, so the probe reads the models list, which
/// requires the same bearer credential as a chat request. `unavailable` means
/// the probe could not be completed, which is not a refusal: a network or
/// service problem must never talk the user out of a working key.
fn validateApiKeyFor(raw: ?*anyopaque, alloc: std.mem.Allocator, api_key: []const u8) api_key_validator_contract.Result {
    const target: *const definitions.Definition = @ptrCast(@alignCast(raw.?));
    if (api_key.len == 0 or api_key.len > 1024) return .refused;
    for (api_key) |byte| {
        if (byte <= 0x20 or byte >= 0x7f) return .refused;
    }
    const probe_url = endpoint.join(alloc, target.base_url, endpoint.key_probe_path) catch return .unavailable;
    defer alloc.free(probe_url);
    const authorization = std.fmt.allocPrint(alloc, "Bearer {s}", .{api_key}) catch return .unavailable;
    defer secret.zeroAndFree(alloc, authorization);
    const headers: std.http.Client.Request.Headers = .{
        .authorization = .{ .override = authorization },
        .user_agent = .{ .override = gateway_client.user_agent },
        .accept_encoding = .omit,
    };
    const result = gateway_client.fetchBoundedHttp(alloc, .GET, probe_url, null, headers, &.{}, max_key_probe_bytes) catch |err| {
        debug_trace.logf("groq", "key probe failed url={s} err={s}", .{ probe_url, @errorName(err) });
        return .unavailable;
    };
    defer secret.zeroAndFree(alloc, result.body);
    debug_trace.logf("groq", "key probe url={s} status={d}", .{ probe_url, @intFromEnum(result.status) });
    return switch (result.status) {
        .ok => .accepted,
        .unauthorized, .forbidden, .payment_required => .refused,
        else => .unavailable,
    };
}

/// Capability heuristics used when the live catalog has not been fetched or does
/// not describe the model.
pub fn fallbackModelCapabilities(model: []const u8) model_capabilities.Capabilities {
    return model_policy.capabilitiesForModel(model);
}

fn identity() model_provider.ProviderId {
    return .groq;
}
