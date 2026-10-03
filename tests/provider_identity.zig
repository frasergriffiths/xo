//! Provider identity and the provider surface fx ships.
//!
//! fx supports OpenRouter, Groq, and custom OpenAI-compatible endpoints. This
//! pins the accepted identifiers and confirms the retired providers cannot be
//! named.

const std = @import("std");
const testing = std.testing;

const model_provider = @import("../src/core/config/model_provider.zig");
const configured_provider = @import("../src/core/config/configured_provider.zig");
const provider_set = @import("../src/core/gateway/provider_set.zig");

const ProviderId = model_provider.ProviderId;

test "the three built-in providers parse from their slugs" {
    try testing.expectEqual(ProviderId.openrouter, model_provider.parse("openrouter").?);
    try testing.expectEqual(ProviderId.groq, model_provider.parse("groq").?);
    try testing.expectEqual(ProviderId.openai_compatible, model_provider.parse("openai-compatible").?);
}

test "provider slugs parse case-insensitively" {
    try testing.expectEqual(ProviderId.openrouter, model_provider.parse("OpenRouter").?);
    try testing.expectEqual(ProviderId.groq, model_provider.parse("GROQ").?);
    try testing.expectEqual(ProviderId.openai_compatible, model_provider.parse("OpenAI-Compatible").?);
}

test "the common OpenAI-compatible misspellings are still accepted" {
    // Users type these constantly, so they are deliberate conveniences rather
    // than compatibility shims for a removed provider.
    try testing.expectEqual(ProviderId.openai_compatible, model_provider.parse("openai-compatable").?);
    try testing.expectEqual(ProviderId.openai_compatible, model_provider.parse("openai_compatible").?);
}

test "retired providers cannot be named" {
    for ([_][]const u8{ "grok", "xai", "codex", "chatgpt", "openai", "gateway", "vercel" }) |name| {
        const parsed = model_provider.parse(name);
        // A retired built-in name must not resolve to a built-in provider. It
        // may only fall through to a user-defined configured provider.
        if (parsed) |provider| {
            try testing.expect(std.meta.activeTag(provider) == .configured);
        }
    }
}

test "built-in providers expose a stable label" {
    const openrouter: ProviderId = .openrouter;
    const groq: ProviderId = .groq;
    const compatible: ProviderId = .openai_compatible;
    try testing.expectEqualStrings("openrouter", openrouter.label());
    try testing.expectEqualStrings("groq", groq.label());
    try testing.expectEqualStrings("openai-compatible", compatible.label());
}

test "providers report whether they are distinct" {
    const openrouter: ProviderId = .openrouter;
    const groq: ProviderId = .groq;
    const compatible: ProviderId = .openai_compatible;
    try testing.expect(!openrouter.same_authority(groq));
    try testing.expect(!openrouter.same_authority(compatible));
    try testing.expect(openrouter.same_authority(.openrouter));
    try testing.expect(groq.same_authority(.groq));
}

test "the provider set exposes exactly the three built-in routes" {
    // Every built-in route must resolve to a bundle. A route left unwired would
    // silently fall back to an unavailable provider at request time.
    const builtin = @import("../src/builtins/providers.zig").native;
    _ = builtin.select(.openrouter);
    _ = builtin.select(.groq);
    _ = builtin.select(.openai_compatible);
}

test "an empty provider set still answers the openrouter route" {
    // Every provider id must resolve to a bundle, even when the profile wired
    // nothing, so callers never have to handle a missing route.
    const set = provider_set.Set{ .openrouter = .{} };
    _ = set.select(.openrouter);
    _ = set.select(.groq);
    _ = set.select(.openai_compatible);
    // With no wired route there is no generated-title model.
    try testing.expectEqual(@as(?[]const u8, null), set.select(.groq).title_model);
}

test "configured provider identifiers are validated" {
    // An empty or over-long id cannot name a provider.
    try testing.expectError(error.InvalidProviderId, configured_provider.validate_id(""));
    try testing.expectError(error.InvalidProviderId, configured_provider.validate_id("has space"));
    // Built-in names stay reserved so a user connection cannot shadow one.
    try testing.expectError(error.ReservedProviderId, configured_provider.validate_id("openrouter"));
    try testing.expectError(error.ReservedProviderId, configured_provider.validate_id("Groq"));
}
