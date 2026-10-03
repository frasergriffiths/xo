//! Credential selection and the settings keys that steer it.
//!
//! A profile may name a provider and remember which key to use for it. Those two
//! are written independently, so they can disagree. Honoring a mismatched pair
//! selects a key the provider then refuses, which surfaces as a permanent
//! request failure rather than a missing key, so the pair has to be checked and
//! the mismatch has to be visible.

const std = @import("std");
const testing = std.testing;

const config_runtime = @import("../src/core/config/config_runtime.zig");
const model_provider = @import("../src/core/config/model_provider.zig");
const types = @import("../src/core/shared/types.zig");
const threshold = @import("../src/core/compactor/threshold.zig");

const ProviderId = model_provider.ProviderId;
const CredentialSource = types.CredentialSource;

const built_in_providers = [_]ProviderId{ .openrouter, .groq, .openai_compatible };
const all_sources = [_]CredentialSource{
    .openrouter_api_key,
    .stored_key,
    .groq_api_key,
    .groq_stored_key,
    .openai_compatible_api_key,
    .openai_compatible_key,
    .host_managed,
    .configured,
};

// --- A provider authorizes only its own keys ---

test "every built-in provider authorizes exactly its own keys plus the host" {
    // A remembered key must never be borrowed across providers: the request
    // would go out carrying a credential the endpoint does not accept.
    for (built_in_providers) |provider| {
        for (all_sources) |source| {
            const expected = source == .host_managed or switch (provider) {
                .openrouter => source == .openrouter_api_key or source == .stored_key,
                .groq => source == .groq_api_key or source == .groq_stored_key,
                .openai_compatible => source == .openai_compatible_api_key or source == .openai_compatible_key,
                .configured => source == .configured,
            };
            try testing.expectEqual(expected, model_provider.authorizesCredential(provider, source));
        }
    }
}

test "no provider is missing" {
    try testing.expectEqual(@as(bool, false), model_provider.authorizesCredential(.openrouter, null));
    try testing.expectEqual(@as(bool, false), model_provider.authorizesCredential(.groq, null));
}

test "a provider never authorizes another provider's key" {
    for (built_in_providers) |provider| {
        for (all_sources) |source| {
            if (source == .host_managed or source == .configured) continue;
            const owner: ?ProviderId = switch (source) {
                .openrouter_api_key, .stored_key => .openrouter,
                .groq_api_key, .groq_stored_key => .groq,
                .openai_compatible_api_key, .openai_compatible_key => .openai_compatible,
                else => null,
            };
            const actual_owner = owner orelse continue;
            if (actual_owner.eql(provider)) continue;
            try testing.expect(!model_provider.authorizesCredential(provider, source));
        }
    }
}

// --- A mismatched pair is dropped, not honored ---

test "a matching pair is kept" {
    try testing.expectEqual(
        @as(?CredentialSource, .openrouter_api_key),
        config_runtime.coherentCredentialSource(.openrouter, .openrouter_api_key),
    );
    try testing.expectEqual(
        @as(?CredentialSource, .groq_stored_key),
        config_runtime.coherentCredentialSource(.groq, .groq_stored_key),
    );
    try testing.expectEqual(
        @as(?CredentialSource, .openai_compatible_key),
        config_runtime.coherentCredentialSource(.openai_compatible, .openai_compatible_key),
    );
}

test "a mismatched pair is dropped so ordinary precedence runs" {
    // This is the exact state a profile lands in after switching provider
    // without clearing the remembered key.
    try testing.expectEqual(
        @as(?CredentialSource, null),
        config_runtime.coherentCredentialSource(.openrouter, .openai_compatible_key),
    );
    try testing.expectEqual(
        @as(?CredentialSource, null),
        config_runtime.coherentCredentialSource(.groq, .stored_key),
    );
    try testing.expectEqual(
        @as(?CredentialSource, null),
        config_runtime.coherentCredentialSource(.openai_compatible, .groq_api_key),
    );
}

test "the host-supplied credential is always authorized" {
    // An embedding host owns its own authentication, so it applies to whichever
    // provider is selected.
    for (built_in_providers) |provider| {
        try testing.expectEqual(
            @as(?CredentialSource, .host_managed),
            config_runtime.coherentCredentialSource(provider, .host_managed),
        );
    }
}

test "a remembered key with no provider chosen is left alone" {
    // Nothing has been selected yet, so there is nothing to contradict.
    try testing.expectEqual(
        @as(?CredentialSource, .stored_key),
        config_runtime.coherentCredentialSource(null, .stored_key),
    );
}

test "a provider with no remembered key is not a mismatch" {
    for (built_in_providers) |provider| {
        try testing.expectEqual(@as(?CredentialSource, null), config_runtime.coherentCredentialSource(provider, null));
        try testing.expect(!config_runtime.credentialSourceIsIncoherent(provider, null));
    }
}

test "the mismatch predicate agrees with the resolver" {
    // Two statements of the same rule must never disagree, or a caller could
    // warn about a pair the resolver considers fine.
    for (built_in_providers) |provider| {
        for (all_sources) |source| {
            const incoherent = config_runtime.credentialSourceIsIncoherent(provider, source);
            const coherent = config_runtime.coherentCredentialSource(provider, source) != null;
            try testing.expectEqual(!incoherent, coherent);
        }
    }
}

test "every mismatch is reported as a mismatch" {
    var seen: usize = 0;
    for (built_in_providers) |provider| {
        for (all_sources) |source| {
            if (config_runtime.credentialSourceIsIncoherent(provider, source)) seen += 1;
        }
    }
    // 3 built-in providers, 8 sources, 1 always authorized, and each provider's
    // own two keys: 3 * 5 mismatched pairs.
    try testing.expectEqual(@as(usize, 15), seen);
}

// --- The compaction threshold setting ---

test "auto_compact_percent accepts exactly the documented range" {
    for ([_][]const u8{ "10", "11", "50", "79", "80" }) |raw| {
        const parsed = threshold.parsePercent(raw) orelse return error.TestRejectedValidPercent;
        try testing.expect(parsed >= threshold.min_percent and parsed <= threshold.max_percent);
    }
    for ([_][]const u8{ "0", "1", "9", "81", "100", "-1", "abc", "" }) |raw| {
        try testing.expectEqual(@as(?u8, null), threshold.parsePercent(raw));
    }
}

test "auto_compact_percent is a share of usable input, not of the window" {
    // 80% of 91808 usable tokens is 73446. If this ever used the raw window the
    // assertion below would fail, which is the point: compaction has to fire
    // before the request is over capacity, not at it.
    const usable: usize = 91_808;
    try testing.expectEqual(@as(usize, 73_446), threshold.highWaterTokens(usable, 80));
    try testing.expect(threshold.highWaterTokens(usable, 80) < usable);
}

test "auto_compact_percent never delays compaction past a usable threshold" {
    // A value above the range behaves like the maximum valid share, so a typo
    // cannot let a request reach the window limit before compaction fires.
    const usable: usize = 10_000;
    const ceiling = threshold.highWaterTokens(usable, threshold.max_percent);
    for ([_]u8{ 100, 200, 255 }) |percent| {
        try testing.expectEqual(ceiling, threshold.highWaterTokens(usable, percent));
    }
    // A value below the range behaves like the minimum, so a typo cannot switch
    // the threshold off and silently strand a session with no context.
    const floor = threshold.highWaterTokens(usable, threshold.min_percent);
    for ([_]u8{ 0, 5, 9 }) |percent| {
        try testing.expectEqual(floor, threshold.highWaterTokens(usable, percent));
    }
}

test "the threshold is monotonic in the configured share" {
    var previous: usize = 0;
    var percent: u8 = threshold.min_percent;
    while (percent <= threshold.max_percent) : (percent += 1) {
        const mark = threshold.highWaterTokens(91_808, percent);
        try testing.expect(mark >= previous);
        previous = mark;
    }
}

test "an invalid environment override never disables compaction" {
    // A typo in the environment must not stop a session compacting, which would
    // look like a silent memory leak to the user.
    for ([_][]const u8{ "abc", "95", "-1", "", "  " }) |raw| {
        try testing.expectEqual(threshold.default_percent, threshold.resolvePercent(80, raw));
    }
    // The configured value is still honored when the override is nonsense.
    try testing.expectEqual(@as(u8, 25), threshold.resolvePercent(25, "nonsense"));
}

// --- The setting survives every merge layer ---

test "auto_compact_percent survives the merge that startup performs" {
    // Regression: the parsed value was carried into the streaming startup view
    // but dropped by the merged-Settings path, so `fx doctor` and every session
    // silently fell back to the default while the file said otherwise.
    var incoming: config_runtime.Settings = .{ .auto_compact_percent = 35 };
    var target: config_runtime.Settings = .{};
    defer target.deinit(testing.allocator);
    try config_runtime.mergeSettingsForTesting(&target, &incoming, testing.allocator);
    try testing.expectEqual(@as(?u8, 35), target.auto_compact_percent);
    incoming.deinit(testing.allocator);
}

test "auto_compact_percent is only replaced when a later layer sets it" {
    var incoming: config_runtime.Settings = .{};
    var target: config_runtime.Settings = .{ .auto_compact_percent = 60 };
    defer target.deinit(testing.allocator);
    try config_runtime.mergeSettingsForTesting(&target, &incoming, testing.allocator);
    try testing.expectEqual(@as(?u8, 60), target.auto_compact_percent);
    incoming.deinit(testing.allocator);
}
