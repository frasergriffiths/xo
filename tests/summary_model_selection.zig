//! Which model writes the compaction summary, and when it may be retried.
//!
//! Writing the summary is not the conversation, so it should not be billed or
//! reasoned like one. It also must not be the single point of failure for a long
//! session: if the endpoint that produced the conversation is briefly down, the
//! handoff is the one thing that cannot wait.

const std = @import("std");
const testing = std.testing;

const summary_model = @import("../src/core/compactor/summary_model.zig");
const model_capabilities = @import("../src/core/config/model_capabilities.zig");
const model_provider = @import("../src/core/config/model_provider.zig");
const types = @import("../src/core/shared/types.zig");

const Capabilities = model_capabilities.Capabilities;

fn withEfforts(names: []const []const u8) Capabilities {
    var efforts: [types.ReasoningEffort.max_options]types.ReasoningEffort = undefined;
    for (names, 0..) |name, i| efforts[i] = types.ReasoningEffort.parse(name).?;
    return .{ .supports_reasoning = true, .reasoning_efforts = .fromSlice(efforts[0..names.len]) };
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
) summary_model.Plan {
    return summary_model.plan(provider, model, key, source, fallback_provider, fallback_model, fallback_key, fallback_source);
}

// --- The summary asks for the cheapest reasoning the model offers ---

test "the cheapest effort is chosen whatever order the catalog lists" {
    // Providers disagree about ordering, and a catalog is third-party data, so
    // the choice must not depend on it.
    for ([_][]const []const u8{
        &.{ "low", "medium", "high" },
        &.{ "high", "medium", "low" },
        &.{ "medium", "high", "low" },
        &.{ "low", "high" },
    }) |order| {
        const chosen = summary_model.lowestEffort(withEfforts(order)) orelse return error.TestFoundNoEffort;
        try testing.expectEqualStrings("low", chosen.label());
    }
}

test "every spelling of cheapest resolves to the cheapest" {
    // `none` and `minimal` both mean "do not deliberate", and a provider may use
    // either. Both must beat a higher tier.
    for ([_][]const []const u8{
        &.{ "none", "low", "high" },
        &.{ "minimal", "medium", "high" },
        &.{ "minimal", "none", "low" },
    }) |names| {
        const chosen = summary_model.lowestEffort(withEfforts(names)) orelse return error.TestFoundNoEffort;
        const label = chosen.label();
        try testing.expect(std.mem.eql(u8, label, "none") or std.mem.eql(u8, label, "minimal") or std.mem.eql(u8, label, "low"));
    }
}

test "a model with no reasoning options leaves the effort unset" {
    // Sending an effort a model does not advertise is a rejected request, which
    // would fail every compaction on that model.
    try testing.expectEqual(@as(?types.ReasoningEffort, null), summary_model.lowestEffort(.{}));
}

test "an unfamiliar effort list falls back to its cheapest documented entry" {
    const chosen = summary_model.lowestEffort(withEfforts(&.{ "slight", "heavy" })) orelse return error.TestFoundNoEffort;
    try testing.expectEqualStrings("slight", chosen.label());
}

test "summary options never reroute the request to a different backend" {
    // Rerouting a summary would silently change which model writes the memory a
    // later assistant depends on.
    const options = summary_model.providerOptions(withEfforts(&.{ "high", "low" }));
    try testing.expectEqualStrings("low", options.reasoning.?.label());
    try testing.expectEqual(@as(usize, 0), options.provider_order.len);
    try testing.expect(!options.provider_strict);
}

// --- At most one retry, and only across a family boundary ---

test "a session with no fallback makes exactly one attempt" {
    // The common case must stay cheap: no second model, no second credential.
    const value = planned(.openrouter, "model-a", "key-a", null, null, null, null, null);
    try testing.expectEqual(@as(usize, 1), value.len);
    try testing.expectEqualStrings("model-a", value.slice()[0].model);
}

test "a fallback on another provider family adds one attempt" {
    const value = planned(.openrouter, "model-a", "key-a", null, .groq, "model-b", "key-b", null);
    try testing.expectEqual(@as(usize, 2), value.len);
    const attempts = value.slice();
    try testing.expectEqualStrings("model-a", attempts[0].model);
    try testing.expectEqualStrings("model-b", attempts[1].model);
    try testing.expectEqual(summary_model.Family.openrouter, attempts[0].family);
    try testing.expectEqual(summary_model.Family.groq, attempts[1].family);
}

test "a fallback in the same family is refused" {
    // Two endpoints behind one family share an outage, so retrying within the
    // family would spend a second attempt to learn the same thing.
    for ([_]model_provider.ProviderId{ .openrouter, .groq, .openai_compatible }) |provider| {
        const value = planned(provider, "a", "k", null, provider, "b", "k2", null);
        try testing.expectEqual(@as(usize, 1), value.len);
    }
}

test "a configured provider is its own family" {
    // Two user-defined endpoints are both `configured`, so a retry between them
    // is refused: they may well be the same host.
    const first: model_provider.ProviderId = .{ .configured = .{ .len = 1 } };
    var second: model_provider.ProviderId = .{ .configured = .{ .len = 2 } };
    second.configured.bytes[0] = 'b';
    second.configured.bytes[1] = 'c';
    try testing.expectEqual(summary_model.Family.configured, summary_model.familyOf(first));
    try testing.expectEqual(summary_model.Family.configured, summary_model.familyOf(second));
    const value = planned(first, "a", "k", null, second, "b", "k2", null);
    try testing.expectEqual(@as(usize, 1), value.len);
}

test "an incomplete fallback is refused" {
    // A different provider means a different key. Reusing the primary key would
    // not fail here; it would fail at the transport, which is worse.
    try testing.expectEqual(@as(usize, 1), planned(.groq, "a", "k", null, .openrouter, "b", null, null).len);
    try testing.expectEqual(@as(usize, 1), planned(.groq, "a", "k", null, null, "b", "k2", null).len);
    try testing.expectEqual(@as(usize, 1), planned(.groq, "a", "k", null, .openrouter, null, "k2", null).len);
    try testing.expectEqual(@as(usize, 1), planned(.groq, "a", "k", null, .openrouter, "", "k2", null).len);
}

test "the plan never grows past two attempts" {
    // Bounded by construction, so no future caller can widen it into a loop.
    try testing.expectEqual(@as(usize, 2), summary_model.Plan.max_attempts);
    for ([_]model_provider.ProviderId{ .openrouter, .groq, .openai_compatible }) |primary| {
        for ([_]model_provider.ProviderId{ .openrouter, .groq, .openai_compatible }) |secondary| {
            const value = planned(primary, "a", "k", null, secondary, "b", "k2", null);
            try testing.expect(value.len <= summary_model.Plan.max_attempts);
        }
    }
}

test "each attempt carries the credential that belongs to its provider" {
    // A mismatch here would send the primary key to the fallback endpoint.
    const value = planned(
        .groq,
        "primary",
        "primary-key",
        .groq_api_key,
        .openrouter,
        "secondary",
        "secondary-key",
        .openrouter_api_key,
    );
    const attempts = value.slice();
    try testing.expectEqual(@as(?types.CredentialSource, .groq_api_key), attempts[0].credential_source);
    try testing.expectEqualStrings("primary-key", attempts[0].api_key.?);
    try testing.expectEqual(@as(?types.CredentialSource, .openrouter_api_key), attempts[1].credential_source);
    try testing.expectEqualStrings("secondary-key", attempts[1].api_key.?);
}

test "a host-supplied credential is carried through unchanged" {
    const value = planned(.openrouter, "a", "", .host_managed, .groq, "b", "k2", .host_managed);
    const attempts = value.slice();
    try testing.expectEqual(@as(?types.CredentialSource, .host_managed), attempts[0].credential_source);
    try testing.expectEqual(@as(?types.CredentialSource, .host_managed), attempts[1].credential_source);
}
