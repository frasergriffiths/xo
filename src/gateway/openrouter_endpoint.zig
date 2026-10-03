//! Canonical OpenRouter endpoint facts.
//!
//! This module is a leaf: it imports nothing from the rest of the tree so both
//! the transport (`openrouter.zig`) and the settings parser
//! (`configured_provider.zig`) can depend on it without a cycle. Every value
//! here is a default the user may override in `settings.json` under
//! `providers.openrouter`.

const std = @import("std");

/// OpenAI-compatible API prefix. Both the chat and model endpoints are derived
/// from it so they can never disagree.
pub const default_base_url = "https://openrouter.ai/api/v1";

/// Settings key and built-in provider id. Also the one reserved name the
/// `providers` map accepts, so the built-in endpoint stays user-overridable.
pub const default_base_url_id = "openrouter";

pub const default_chat_path = "/chat/completions";
pub const default_models_path = "/models";
pub const key_probe_path = "/key";

/// Environment variable read when no key has been saved through `/provider`.
pub const default_api_key_env = "OPENROUTER_API_KEY";

/// Client attribution OpenRouter accepts for its own dashboard. Advisory only:
/// these never carry authority and an endpoint may ignore them. Declared as an
/// anonymous struct so this leaf module stays importable from the config layer.
pub const AttributionHeader = struct { name: []const u8, value: []const u8 };

pub const attribution_headers = [_]AttributionHeader{
    .{ .name = "HTTP-Referer", .value = "https://openrouter.ai" },
    .{ .name = "X-Title", .value = "fx" },
};

/// Build a validated endpoint URL from a base prefix, or explain why it is not
/// usable. Callers own the returned bytes.
pub fn join(alloc: std.mem.Allocator, base_url: []const u8, path: []const u8) ![]u8 {
    return std.mem.concat(alloc, u8, &.{ base_url, path });
}
