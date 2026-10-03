//! Automatic-compaction threshold resolution.
//!
//! The share of usable input at which automatic compaction fires. `default_percent`
//! matches the ratio this codebase has always used (4/5), so a profile that sets
//! nothing behaves exactly as before.
//!
//! Usable input is the context window minus the reserved output allowance, never
//! the raw window. Callers must pass the result of `usableInputTokens`.

const std = @import("std");
const testing = std.testing;

/// Default share of usable input that triggers automatic compaction.
pub const default_percent: u8 = 80;
/// Below this, compaction fires so eagerly that the handoff would dominate.
pub const min_percent: u8 = 10;
/// Above this, requests fail before compaction can help.
pub const max_percent: u8 = 80;

/// Environment variable that overrides the configured percentage for one run.
pub const env_var = "FX_AUTO_COMPACT_PERCENT";

/// Parses a configured percentage, returning null for anything out of range or
/// malformed. Callers treat null as "not configured" so a typo never silently
/// disables compaction.
pub fn parsePercent(raw: ?[]const u8) ?u8 {
    const trimmed = std.mem.trim(u8, raw orelse return null, " \t\r\n");
    if (trimmed.len == 0) return null;
    if (!std.ascii.isDigit(trimmed[0])) return null;
    for (trimmed) |byte| {
        if (!std.ascii.isDigit(byte)) return null;
    }
    const value = std.fmt.parseUnsigned(u16, trimmed, 10) catch return null;
    if (value < min_percent or value > max_percent) return null;
    return @intCast(value);
}

/// Resolves the effective percentage: a valid environment override wins, then
/// the configured value, then the compiled default.
pub fn resolvePercent(configured: ?u8, process_override: ?[]const u8) u8 {
    if (parsePercent(process_override)) |value| return value;
    if (configured) |value| {
        // Settings already validate this, but a value that reaches here out of
        // range must not be able to push the threshold anywhere.
        if (value >= min_percent and value <= max_percent) return value;
    }
    return default_percent;
}

/// The token count at which automatic compaction triggers.
///
/// Saturating, so a huge window cannot wrap the multiplication, and clamped to
/// the usable input it is derived from.
///
/// The share is clamped into the valid band on both sides. That is defence in
/// depth: `resolvePercent` already refuses an out-of-range value, but a caller
/// that reaches this function directly with a bad share must not be able to defer
/// compaction until the context is already full, nor disable it entirely.
pub fn highWaterTokens(usable_input_tokens: usize, percent: u8) usize {
    const requested = @as(usize, percent);
    const bounded = @min(@max(requested, min_percent), max_percent);
    const whole = usable_input_tokens / 100 * bounded;
    const remainder = usable_input_tokens % 100 * bounded / 100;
    return @min(whole +| remainder, usable_input_tokens);
}

test "the default percentage matches the ratio this codebase always used" {
    try testing.expectEqual(@as(u8, 80), default_percent);
    try testing.expectEqual(@as(u8, 80), resolvePercent(null, null));
    // 4/5 of the input, expressed through the configurable path.
    try testing.expectEqual(
        80_000,
        highWaterTokens(100_000, default_percent),
    );
}

test "every value in the valid range is accepted" {
    var value: usize = min_percent;
    while (value <= max_percent) : (value += 1) {
        const raw = try std.fmt.allocPrint(testing.allocator, "{d}", .{value});
        defer testing.allocator.free(raw);
        try testing.expectEqual(@as(?u8, @intCast(value)), parsePercent(raw));
    }
}

test "out of range and malformed percentages are rejected" {
    for ([_][]const u8{
        "0",   "1",      "9", "81", "100",  "1000", "-1",
        "+5",  "abc",    "",  "  ", "80.5", "8 0",  "0x50",
        "80%", "eighty",
    }) |raw| {
        try testing.expectEqual(@as(?u8, null), parsePercent(raw));
    }
}

test "null and whitespace-only input are rejected" {
    try testing.expectEqual(@as(?u8, null), parsePercent(null));
    try testing.expectEqual(@as(?u8, null), parsePercent(""));
    try testing.expectEqual(@as(?u8, null), parsePercent("\t \r\n"));
}

test "surrounding whitespace is tolerated" {
    try testing.expectEqual(@as(?u8, 25), parsePercent("  25  "));
    try testing.expectEqual(@as(?u8, 25), parsePercent("\t25\r\n"));
}

test "a valid environment override wins over configuration" {
    try testing.expectEqual(@as(u8, 25), resolvePercent(80, "25"));
    try testing.expectEqual(@as(u8, 60), resolvePercent(null, "60"));
    try testing.expectEqual(@as(u8, 10), resolvePercent(80, "10"));
}

test "an invalid environment override is ignored, not fatal" {
    // A typo in the environment must not stop compaction from happening.
    try testing.expectEqual(@as(u8, 80), resolvePercent(80, "95"));
    try testing.expectEqual(@as(u8, 80), resolvePercent(80, "junk"));
    try testing.expectEqual(@as(u8, 80), resolvePercent(80, ""));
    try testing.expectEqual(@as(u8, 80), resolvePercent(null, "nonsense"));
}

test "an out of range configured value falls back to the default" {
    try testing.expectEqual(@as(u8, 80), resolvePercent(95, null));
    try testing.expectEqual(@as(u8, 80), resolvePercent(0, null));
}

test "the high water mark is a share of usable input" {
    try testing.expectEqual(@as(usize, 40_000), highWaterTokens(100_000, 40));
    try testing.expectEqual(@as(usize, 73_446), highWaterTokens(91_808, 80));
    try testing.expectEqual(@as(usize, 9_180), highWaterTokens(91_808, 10));
}

test "the high water mark never exceeds the usable input" {
    try testing.expectEqual(@as(usize, 0), highWaterTokens(0, 80));
    try testing.expectEqual(@as(usize, 800), highWaterTokens(1000, 80));
}

test "an out of range share is clamped into the valid band" {
    // Too high behaves like the maximum, not like 100 percent, so a misconfigured
    // value cannot defer compaction until the context is already full. Too low
    // behaves like the minimum, so it cannot disable compaction outright.
    const floor = highWaterTokens(1000, min_percent);
    const ceiling = highWaterTokens(1000, max_percent);
    try testing.expectEqual(ceiling, highWaterTokens(1000, 255));
    try testing.expectEqual(floor, highWaterTokens(1000, 0));
    try testing.expectEqual(floor, highWaterTokens(1000, 5));
    // Every input, valid or not, lands inside the band.
    var percent: usize = 0;
    while (percent <= 255) : (percent += 1) {
        const mark = highWaterTokens(1000, @intCast(percent));
        try testing.expect(mark >= floor);
        try testing.expect(mark <= ceiling);
    }
}

test "the high water mark does not overflow on a huge window" {
    const huge = std.math.maxInt(usize) / 2;
    const result = highWaterTokens(huge, 80);
    try testing.expect(result <= huge);
}

test "the high water mark is monotonic in the percentage" {
    var previous: usize = 0;
    var percent: usize = min_percent;
    while (percent <= max_percent) : (percent += 1) {
        const value = highWaterTokens(91_808, @intCast(percent));
        try testing.expect(value >= previous);
        previous = value;
    }
}
