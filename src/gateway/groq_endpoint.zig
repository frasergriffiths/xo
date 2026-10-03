//! Canonical Groq endpoint facts.
//!
//! This module is a leaf: it imports nothing from the rest of the tree so both
//! the transport (`groq.zig`) and the settings parser
//! (`configured_provider.zig`) can depend on it without a cycle. Every value
//! here is a default the user may override in `settings.json` under
//! `providers.groq`.
const std = @import("std");

/// OpenAI-compatible API prefix. Both the chat and model endpoints are derived
/// from it so they can never disagree.
pub const default_base_url = "https://api.groq.com/openai/v1";

/// Settings key and built-in provider id. Also the one reserved name the
/// `providers` map accepts, so the built-in endpoint stays user-overridable.
pub const default_base_url_id = "groq";

pub const default_chat_path = "/chat/completions";
pub const default_models_path = "/models";

/// Groq publishes no `/key` endpoint, so the API key validator probes the
/// models endpoint instead.
pub const key_probe_path = default_models_path;

/// Environment variable read when no key has been saved through `/provider`.
pub const default_api_key_env = "GROQ_API_KEY";

/// Built-in default model when the profile has no saved selection. Tool-capable
/// and long-context; pin the exact id against Groq's live catalog before a
/// release. Kept in this leaf so the settings parser and the transport agree.
pub const default_model = "llama-3.3-70b-versatile";

/// Groq does not ask for OpenRouter's client attribution, so the list is empty.
/// It keeps the shared shape so callers treat every built-in the same way.
pub const AttributionHeader = struct { name: []const u8, value: []const u8 };

pub const attribution_headers = [_]AttributionHeader{};

/// Build a validated endpoint URL from a base prefix, or explain why it is not
/// usable. Callers own the returned bytes.
pub fn join(alloc: std.mem.Allocator, base_url: []const u8, path: []const u8) ![]u8 {
    return std.mem.concat(alloc, u8, &.{ base_url, path });
}
