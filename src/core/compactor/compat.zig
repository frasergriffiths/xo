//! Durable-format compatibility for compaction state.
//!
//! A compaction writes two things that outlive the process: the state artifact
//! and the short-name alias index beside it. Both are read by a later fx, which
//! may be newer or older than the one that wrote them. This module is the single
//! place that decides what a stored version means, so the ladder is auditable
//! instead of scattered across readers.
//!
//! Rules the ladder follows:
//!
//!   * An unknown future version is refused, never guessed at. A reader must not
//!     invent meaning for data it does not understand.
//!   * A missing version field is treated as the original version, because that
//!     is what the first format wrote.
//!   * Refusing a stored version degrades to "no short names available", which
//!     leaves every long handle still readable. It never blocks a read.

const std = @import("std");
const testing = std.testing;
const aliases = @import("aliases.zig");

/// The version this build writes.
pub const current_version: u32 = 2;
/// The original alias index version, before the message table existed.
pub const first_version: u32 = 1;

/// Every version this build can read, oldest first.
pub const readable_versions = [_]u32{ first_version, current_version };

/// What a stored index turned out to be.
pub const Support = enum {
    /// Fully understood, including message and tool tables.
    current,
    /// Written by an older build. Tool names still resolve; message names were
    /// never recorded, so they resolve to nothing.
    legacy,
    /// Not readable. Callers must behave as though no index exists.
    unsupported,
};

/// Classifies a stored index.
///
/// `bytes` is the raw file. A document this build cannot parse at all is
/// `unsupported` rather than an error, because a damaged file must not be able
/// to block an ordinary long-handle read.
pub fn classify(alloc: std.mem.Allocator, bytes: []const u8) Support {
    const version = readVersion(alloc, bytes) orelse return .unsupported;
    if (version == current_version) return .current;
    if (version == first_version) return .legacy;
    return .unsupported;
}

/// The version a document declares, or null when it declares none or is not
/// valid JSON.
fn readVersion(alloc: std.mem.Allocator, bytes: []const u8) ?u32 {
    if (bytes.len == 0) return null;
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const value = parsed.value.object.get("version") orelse return null;
    if (value != .integer) return null;
    if (value.integer < 0 or value.integer > std.math.maxInt(u32)) return null;
    return @intCast(value.integer);
}

/// Whether this build can read a stored index of the given version.
pub fn canRead(version: u32) bool {
    for (readable_versions) |readable| {
        if (readable == version) return true;
    }
    return false;
}

/// True when a message short name can be expected to resolve. Legacy indexes
/// recorded no message table, so `M` names were never available to them.
pub fn resolvesMessageNames(support: Support) bool {
    return support == .current;
}

/// True when a tool short name can be expected to resolve. Both readable
/// versions recorded the tool table.
pub fn resolvesToolNames(support: Support) bool {
    return support == .current or support == .legacy;
}

// --- Tests ---

test "the version this build writes is the current one" {
    try testing.expectEqual(@as(u32, 2), current_version);
    try testing.expectEqual(@as(u32, 1), first_version);
    try testing.expectEqual(aliases.format_version, current_version);
}

test "the current version is classified as current" {
    const document =
        \\{"version":2,"messages":[],"tools":[]}
    ;
    try testing.expectEqual(Support.current, classify(testing.allocator, document));
    try testing.expect(resolvesMessageNames(classify(testing.allocator, document)));
    try testing.expect(resolvesToolNames(classify(testing.allocator, document)));
}

test "the first version is readable but has no message names" {
    // Version 1 recorded only tool names. Loading one must still resolve `T`
    // names, because those were always present.
    const document =
        \\{"version":1,"tools":[{"alias":"T1","handle":"result-aa"}]}
    ;
    try testing.expectEqual(Support.legacy, classify(testing.allocator, document));
    try testing.expect(!resolvesMessageNames(classify(testing.allocator, document)));
    try testing.expect(resolvesToolNames(classify(testing.allocator, document)));
}

test "an unknown future version is refused rather than guessed at" {
    // A newer fx wrote this. Reading it as version 2 would be wrong, and a
    // partial read would be worse than none.
    for ([_][]const u8{
        "{\"version\":3,\"messages\":[],\"tools\":[]}",
        "{\"version\":99,\"messages\":[],\"tools\":[]}",
    }) |document| {
        try testing.expectEqual(Support.unsupported, classify(testing.allocator, document));
        try testing.expect(!resolvesMessageNames(classify(testing.allocator, document)));
        try testing.expect(!resolvesToolNames(classify(testing.allocator, document)));
    }
}

test "a document with no version is unsupported" {
    // The current format requires an explicit version, so its absence means the
    // document is damaged or truncated rather than ancient.
    try testing.expectEqual(Support.unsupported, classify(testing.allocator, "{}"));
    try testing.expectEqual(Support.unsupported, classify(testing.allocator, "{\"messages\":[],\"tools\":[]}"));
}

test "a damaged document is unsupported rather than an error" {
    // A damaged file must never be able to block an ordinary long-handle read.
    for ([_][]const u8{
        "",
        "{",
        "null",
        "[]",
        "\"version\"",
        "{\"version\":\"2\"}",
        "{\"version\":-1}",
        "{\"version\":1.5}",
    }) |document| {
        try testing.expectEqual(Support.unsupported, classify(testing.allocator, document));
    }
}

test "every readable version is reported as readable" {
    for (readable_versions) |version| {
        try testing.expect(canRead(version));
    }
}

test "an unreadable version is reported as unreadable" {
    for ([_]u32{ 0, 3, 4, 100, std.math.maxInt(u32) }) |version| {
        if (version == current_version or version == first_version) continue;
        try testing.expect(!canRead(version));
    }
}

test "an unsupported index never claims to resolve anything" {
    // The only guarantee an unreadable index gives is that no short name resolves,
    // which leaves every long handle still usable.
    try testing.expect(!resolvesMessageNames(.unsupported));
    try testing.expect(!resolvesToolNames(.unsupported));
}

test "classification is allocation-free for a caller that reuses an arena" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const document =
        \\{"version":2,"messages":[],"tools":[]}
    ;
    try testing.expectEqual(Support.current, classify(arena.allocator(), document));
}
