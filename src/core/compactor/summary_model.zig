//! Which model writes the compaction summary.
//!
//! Writing the summary is not the conversation. It needs broad context and
//! careful instruction following, but it does not need the reasoning depth the
//! turn itself used, and it must keep working when the turn's own model is
//! unavailable. Two rules follow from that:
//!
//! 1. Ask for the lowest reasoning effort the model supports. A summary is a
//!    compression task, so paying for deliberation buys nothing.
//! 2. Allow exactly one retry against a different provider family. A summary
//!    that fails because one endpoint is down is a lost conversation, and one
//!    cross-family retry is enough to survive a single provider outage without
//!    turning a failed compaction into a retry storm.
//!
//! Both rules are decided here as pure functions, so the choice can be tested
//! without a provider, a network, or a session.

const std = @import("std");
const testing = std.testing;
const types = @import("../shared/types.zig");
const capabilities_mod = @import("../config/model_capabilities.zig");
const model_provider = @import("../config/model_provider.zig");

const Capabilities = capabilities_mod.Capabilities;

/// Effort names in ascending order of cost, checked before any catalog order.
/// Providers disagree about how they label the cheapest level, so a fixed list
/// of the names that mean "cheapest" is more reliable than trusting whatever
/// order a catalog happens to list.
const lowest_effort_names = [_][]const u8{ "none", "minimal", "low" };

/// The lowest reasoning effort worth using for a summary.
///
/// Returns null when the model advertises no reasoning options, which is the
/// signal to leave the effort unset rather than to guess.
pub fn lowestEffort(capabilities: Capabilities) ?types.ReasoningEffort {
    const advertised = capabilities.reasoning_efforts.slice();
    for (lowest_effort_names) |name| {
        for (advertised) |effort| {
            if (std.mem.eql(u8, effort.label(), name)) return effort;
        }
    }
    // No well-known cheapest label. Fall back to the first advertised option,
    // which every provider documents as its cheapest.
    if (advertised.len == 0) return null;
    return advertised[0];
}

/// Provider families, for deciding whether a retry would actually change
/// anything. Two endpoints behind the same family share an outage, so retrying
/// within one is pointless.
pub const Family = enum {
    openrouter,
    groq,
    openai_compatible,
    configured,

    pub fn label(self: Family) []const u8 {
        return @tagName(self);
    }
};

pub fn familyOf(provider: model_provider.ProviderId) Family {
    return switch (provider) {
        .openrouter => .openrouter,
        .groq => .groq,
        .openai_compatible => .openai_compatible,
        .configured => .configured,
    };
}

/// A summary call the compactor may make, in order.
pub const Attempt = struct {
    provider: model_provider.ProviderId,
    model: []const u8,
    /// The credential to use. Null reuses the primary credential, which is only
    /// valid when the provider is the primary one.
    api_key: ?[]const u8 = null,
    credential_source: ?types.CredentialSource = null,
    family: Family,
};

/// At most two attempts. The unused slot is left undefined and is never read:
/// every accessor is bounded by `len`.
pub const Plan = struct {
    pub const max_attempts: usize = 2;

    attempts: [max_attempts]Attempt = undefined,
    len: usize = 0,

    pub fn slice(self: *const Plan) []const Attempt {
        return self.attempts[0..self.len];
    }
};

/// Builds the ordered list of summary calls to try.
///
/// The primary attempt always comes first. A fallback is only appended when one
/// is supplied and its provider family differs from the primary, so the planner
/// never returns two attempts that would hit the same outage.
pub fn plan(
    primary_provider: model_provider.ProviderId,
    primary_model: []const u8,
    primary_api_key: []const u8,
    primary_credential_source: ?types.CredentialSource,
    fallback_provider: ?model_provider.ProviderId,
    fallback_model: ?[]const u8,
    fallback_api_key: ?[]const u8,
    fallback_credential_source: ?types.CredentialSource,
) Plan {
    var result: Plan = .{};
    result.attempts[0] = .{
        .provider = primary_provider,
        .model = primary_model,
        .api_key = primary_api_key,
        .credential_source = primary_credential_source,
        .family = familyOf(primary_provider),
    };
    result.len = 1;
    // Mark the unused slot so a slice over it can never be read, even in a
    // release build where the bounds check is compiled out.
    result.attempts[1] = .{
        .provider = primary_provider,
        .model = primary_model,
        .api_key = primary_api_key,
        .credential_source = primary_credential_source,
        .family = familyOf(primary_provider),
    };

    const fallback_provider_value = fallback_provider orelse return result;
    const fallback_model_value = fallback_model orelse return result;
    if (fallback_model_value.len == 0) return result;
    // A key is required: a different provider means a different credential, and
    // silently reusing the primary key would just fail at the transport.
    const fallback_key = fallback_api_key orelse return result;
    const family = familyOf(fallback_provider_value);
    if (family == result.attempts[0].family) return result;

    result.attempts[1] = .{
        .provider = fallback_provider_value,
        .model = fallback_model_value,
        .api_key = fallback_key,
        .credential_source = fallback_credential_source,
        .family = family,
    };
    result.len = 2;
    return result;
}

/// Provider options for a summary call: the lowest supported reasoning effort
/// and no gateway provider preference, because a summary must not silently
/// reroute to a different backend than the session is using.
pub fn providerOptions(capabilities: Capabilities) capabilities_mod.ResolvedProviderOptions {
    return .{
        .reasoning = lowestEffort(capabilities),
        .fast = false,
        .parallel_tool_calls = null,
        .prompt_caching = false,
        .provider_order = &.{},
        .provider_strict = false,
    };
}

// --- Tests ---

fn withEfforts(names: []const []const u8) Capabilities {
    var efforts: [types.ReasoningEffort.max_options]types.ReasoningEffort = undefined;
    for (names, 0..) |name, i| efforts[i] = types.ReasoningEffort.parse(name).?;
    return .{ .supports_reasoning = true, .reasoning_efforts = .fromSlice(efforts[0..names.len]) };
}

test "the cheapest well-known effort is chosen regardless of catalog order" {
    const capabilities = withEfforts(&.{ "high", "low", "medium" });
    try testing.expectEqualStrings("low", lowestEffort(capabilities).?.label());
}

test "none wins over minimal and low" {
    try testing.expectEqualStrings("none", lowestEffort(withEfforts(&.{ "high", "low", "minimal", "none" })).?.label());
    try testing.expectEqualStrings("minimal", lowestEffort(withEfforts(&.{ "high", "low", "minimal" })).?.label());
}

test "a model with no reasoning options leaves the effort unset" {
    // Guessing an effort a model does not accept is worse than leaving it unset.
    try testing.expectEqual(@as(?types.ReasoningEffort, null), lowestEffort(.{}));
    try testing.expectEqual(@as(?types.ReasoningEffort, null), lowestEffort(.{ .supports_reasoning = false }));
}

test "an unfamiliar effort list falls back to its first entry" {
    const capabilities = withEfforts(&.{ "trivial", "considerable" });
    try testing.expectEqualStrings("trivial", lowestEffort(capabilities).?.label());
}

test "a single advertised effort is used as is" {
    try testing.expectEqualStrings("medium", lowestEffort(withEfforts(&.{"medium"})).?.label());
}

test "summary provider options never reroute the request" {
    const options = providerOptions(withEfforts(&.{ "high", "low" }));
    try testing.expectEqualStrings("low", options.reasoning.?.label());
    try testing.expectEqual(@as(usize, 0), options.provider_order.len);
    try testing.expect(!options.provider_strict);
    try testing.expect(!options.fast);
}

test "providers map to their families" {
    try testing.expectEqual(Family.openrouter, familyOf(.openrouter));
    try testing.expectEqual(Family.groq, familyOf(.groq));
    try testing.expectEqual(Family.openai_compatible, familyOf(.openai_compatible));
    try testing.expectEqual(Family.configured, familyOf(.{ .configured = .{ .len = 0 } }));
}

test "the plan always begins with the primary attempt" {
    const plan_result = plan(.openrouter, "model-a", "key-a", null, null, null, null, null);
    try testing.expectEqual(@as(usize, 1), plan_result.len);
    try testing.expectEqualStrings("model-a", plan_result.slice()[0].model);
    try testing.expectEqualStrings("key-a", plan_result.slice()[0].api_key.?);
    try testing.expectEqual(Family.openrouter, plan_result.slice()[0].family);
}

test "a different provider family adds exactly one fallback" {
    const plan_result = plan(.openrouter, "model-a", "key-a", null, .groq, "model-b", "key-b", null);
    try testing.expectEqual(@as(usize, 2), plan_result.len);
    const attempts = plan_result.slice();
    try testing.expectEqualStrings("model-a", attempts[0].model);
    try testing.expectEqualStrings("model-b", attempts[1].model);
    try testing.expectEqualStrings("key-b", attempts[1].api_key.?);
    try testing.expectEqual(Family.groq, attempts[1].family);
}

test "a fallback in the same family is refused" {
    // Retrying against the same family would hit the same outage.
    const plan_result = plan(.openrouter, "model-a", "key-a", null, .openrouter, "model-b", "key-b", null);
    try testing.expectEqual(@as(usize, 1), plan_result.len);
}

test "an incomplete fallback is refused" {
    // No provider, no model, an empty model, or no credential each mean there is
    // nothing usable to retry with.
    try testing.expectEqual(@as(usize, 1), planned(.groq, "a", "k", null, .openrouter, "b", null, null).len);
    try testing.expectEqual(@as(usize, 1), planned(.groq, "a", "k", null, null, "b", "k2", null).len);
    try testing.expectEqual(@as(usize, 1), planned(.groq, "a", "k", null, .openrouter, "", "k2", null).len);
    try testing.expectEqual(@as(usize, 1), planned(.groq, "a", "k", null, .openrouter, null, "k2", null).len);
}

test "a fallback never exceeds two attempts" {
    // Bounded by construction: the plan has exactly two slots.
    try testing.expectEqual(@as(usize, 2), planned(.groq, "a", "k", null, .openrouter, "b", "k2", null).len);
    try testing.expectEqual(@as(usize, 2), planned(.openrouter, "a", "k", null, .groq, "b", "k2", null).len);
}

fn planned(
    provider: model_provider.ProviderId,
    model: []const u8,
    key: []const u8,
    source: ?types.CredentialSource,
    fallback_provider: ?model_provider.ProviderId,
    fallback_model: ?[]const u8,
    fallback_key: ?[]const u8,
    fallback_source: ?types.CredentialSource,
) Plan {
    return plan(provider, model, key, source, fallback_provider, fallback_model, fallback_key, fallback_source);
}

test "the fallback credential travels with the fallback attempt" {
    const plan_value = plan(.groq, "a", "k1", .openrouter_api_key, .openrouter, "b", "k2", .host_managed);
    const attempts = plan_value.slice();
    try testing.expectEqual(@as(?types.CredentialSource, .openrouter_api_key), attempts[0].credential_source);
    try testing.expectEqual(@as(?types.CredentialSource, .host_managed), attempts[1].credential_source);
}
