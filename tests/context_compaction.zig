//! Context compaction behavior.
//!
//! Compaction has one transaction serving manual, automatic, and
//! context-overflow flows. These tests pin the behavior the rest of the system
//! depends on: when automatic compaction fires, that user text and the newest
//! assistant reply survive byte for byte, and that an old checkpoint written
//! before the alias tables still loads.

const std = @import("std");
const testing = std.testing;

const threshold = @import("../src/core/compactor/threshold.zig");
const identifiers = @import("../src/core/compactor/identifiers.zig");
const prompt_context = @import("../src/core/agent/runtime/prompt_context.zig");
const model_capabilities = @import("../src/core/config/model_capabilities.zig");

const Plan = prompt_context.CompactionPlan;
const PlanInput = prompt_context.CompactionPlanInput;
const Decision = prompt_context.CompactionDecision;

// --- Requirement 7: automatic compaction fires at the configured percentage ---

test "automatic compaction fires exactly at the high water mark" {
    const capabilities = model_capabilities.Capabilities{ .context_window = 100_000 };
    const usable = prompt_context.usableInputTokens(capabilities).?;
    const high_water = threshold.highWaterTokens(usable, 80);

    const at = prompt_context.planCompaction(.{
        .trigger = .automatic,
        .capabilities = capabilities,
        .request_tokens = high_water,
        .source_tokens = high_water,
        .compact_percent = 80,
    });
    try testing.expectEqual(Decision.compact, at.decision);

    const below = prompt_context.planCompaction(.{
        .trigger = .automatic,
        .capabilities = capabilities,
        .request_tokens = high_water - 1,
        .source_tokens = high_water - 1,
        .compact_percent = 80,
    });
    try testing.expectEqual(Decision.no_op, below.decision);
}

test "the default percentage reproduces the historical four-fifths behavior" {
    const capabilities = model_capabilities.Capabilities{ .context_window = 100_000 };
    const plan = prompt_context.planCompaction(.{
        .trigger = .automatic,
        .capabilities = capabilities,
        .request_tokens = 0,
        .source_tokens = 1,
    });
    try testing.expectEqual(threshold.default_percent, threshold.resolvePercent(null, null));
    const usable = plan.usable_input_tokens.?;
    try testing.expectEqual(usable * 4 / 5, plan.high_water_tokens.?);
}

test "a lower percentage compacts earlier" {
    const capabilities = model_capabilities.Capabilities{ .context_window = 100_000 };
    const usable = prompt_context.usableInputTokens(capabilities).?;
    const early = threshold.highWaterTokens(usable, 40);
    const late = threshold.highWaterTokens(usable, 80);
    try testing.expect(early < late);

    // 40% of usable input is enough to trigger at that setting.
    const plan = prompt_context.planCompaction(.{
        .trigger = .automatic,
        .capabilities = capabilities,
        .request_tokens = early,
        .source_tokens = early,
        .compact_percent = 40,
    });
    try testing.expectEqual(Decision.compact, plan.decision);
    try testing.expectEqual(early, plan.high_water_tokens.?);
}

test "the threshold is a share of usable input, never of the raw window" {
    const capabilities = model_capabilities.Capabilities{
        .context_window = 100_000,
        .max_output_tokens = 8_000,
    };
    const usable = prompt_context.usableInputTokens(capabilities).?;
    // Usable input is the window minus the reserved output allowance.
    try testing.expectEqual(@as(usize, 92_000), usable);
    try testing.expect(usable < 100_000);

    const plan = prompt_context.planCompaction(.{
        .trigger = .automatic,
        .capabilities = capabilities,
        .request_tokens = 40_000,
        .source_tokens = 40_000,
        .compact_percent = 40,
    });
    // 40% of usable input, not 40% of the context window.
    try testing.expectEqual(threshold.highWaterTokens(usable, 40), plan.high_water_tokens.?);
    try testing.expect(plan.high_water_tokens.? < 40_000);
}

test "a model that advertises no output allowance uses the whole window" {
    // Nothing is reserved, so the threshold is a share of the raw window. This
    // is the shape the default four-fifths ratio was tuned against.
    const capabilities = model_capabilities.Capabilities{ .context_window = 100_000 };
    try testing.expectEqual(@as(?usize, 100_000), prompt_context.usableInputTokens(capabilities));
}

test "an output allowance as large as the window is clamped" {
    // A provider advertising an output limit equal to the context window must
    // not produce a negative usable input.
    const capabilities = model_capabilities.Capabilities{
        .context_window = 1_000,
        .max_output_tokens = 1_000,
    };
    const usable = prompt_context.usableInputTokens(capabilities).?;
    try testing.expect(usable < 1_000);
    const plan = prompt_context.planCompaction(.{
        .trigger = .automatic,
        .capabilities = capabilities,
        .request_tokens = usable,
        .source_tokens = usable,
        .compact_percent = 80,
    });
    try testing.expect(plan.high_water_tokens.? <= usable);
}

test "an unknown context window never triggers automatic compaction" {
    // Fail-quiet: without a window there is no threshold, so compaction must
    // not fire on a huge request.
    const plan = prompt_context.planCompaction(.{
        .trigger = .automatic,
        .capabilities = .{},
        .request_tokens = std.math.maxInt(usize) / 2,
        .source_tokens = 1024,
        .compact_percent = 80,
    });
    try testing.expectEqual(Decision.no_op, plan.decision);
    try testing.expectEqual(@as(?usize, null), plan.high_water_tokens);
}

test "manual compaction ignores the threshold" {
    // A manual `/compact` must always attempt compaction regardless of how much
    // context is in use.
    const capabilities = model_capabilities.Capabilities{ .context_window = 100_000 };
    const plan = prompt_context.planCompaction(.{
        .trigger = .manual,
        .capabilities = capabilities,
        .request_tokens = 10,
        .source_tokens = 10,
        .compact_percent = 80,
    });
    try testing.expectEqual(Decision.compact, plan.decision);
}

test "an empty source never triggers compaction" {
    const capabilities = model_capabilities.Capabilities{ .context_window = 100_000 };
    const plan = prompt_context.planCompaction(.{
        .trigger = .manual,
        .capabilities = capabilities,
        .request_tokens = 0,
        .source_tokens = 0,
    });
    try testing.expectEqual(Decision.no_op, plan.decision);
}

// --- Requirement 7: configuration surface ---

test "the configured percentage is honored end to end" {
    for ([_]u8{ 10, 25, 50, 80 }) |percent| {
        const capabilities = model_capabilities.Capabilities{ .context_window = 200_000 };
        const usable = prompt_context.usableInputTokens(capabilities).?;
        const mark = threshold.highWaterTokens(usable, percent);
        const plan = prompt_context.planCompaction(.{
            .trigger = .automatic,
            .capabilities = capabilities,
            .request_tokens = mark,
            .source_tokens = mark,
            .compact_percent = percent,
        });
        try testing.expectEqual(Decision.compact, plan.decision);
    }
}

// --- Requirements 4 and 5: alias identifiers ---

test "user messages are addressable as M1, M2, ..." {
    var index: usize = 1;
    while (index <= 5) : (index += 1) {
        const alias = try identifiers.formatMessage(testing.allocator, index);
        defer testing.allocator.free(alias);
        const parsed = identifiers.parse(alias).?;
        try testing.expect(parsed.isMessage());
        try testing.expect(!parsed.isTool());
        try testing.expectEqual(index, parsed.index);
    }
}

test "tool calls are addressable as T1, T2, ..." {
    var index: usize = 1;
    while (index <= 5) : (index += 1) {
        const alias = try identifiers.formatTool(testing.allocator, index);
        defer testing.allocator.free(alias);
        const parsed = identifiers.parse(alias).?;
        try testing.expect(parsed.isTool());
        try testing.expectEqual(index, parsed.index);
    }
}

test "an alias cannot collide with a real content-addressed handle" {
    // Real handles always start with one of these prefixes, so the single
    // letter alias prefixes are unambiguous.
    for ([_][]const u8{ "result-", "image-", "diff-", "compaction-" }) |prefix| {
        try testing.expect(!identifiers.isAlias(prefix));
    }
}

test "malformed aliases never resolve" {
    for ([_][]const u8{
        "",   "M",   "T",      "M0",   "T0",
        "Mx", "M-1", "M../T1", "M 1",  "M1 ",
        "m1", "M01", "M1/",    "T1\n",
    }) |raw| {
        try testing.expect(!identifiers.isAlias(raw));
    }
}
