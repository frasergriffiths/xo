//! Compacted-turn identifiers and the durable short-name index.
//!
//! A compaction replaces long content-addressed handles with short names the
//! model can hold in context and cite by heart. These tests pin the two halves
//! of that contract: the names are unambiguous, and an index can never be used
//! to redirect a read outside the result store.

const std = @import("std");
const testing = std.testing;

const aliases = @import("../src/core/compactor/aliases.zig");
const identifiers = @import("../src/core/compactor/identifiers.zig");
const compat = @import("../src/core/compactor/compat.zig");

// --- Names are unambiguous ---

test "message and tool names occupy separate spaces" {
    try testing.expect(identifiers.parse("M1").?.isMessage());
    try testing.expect(!identifiers.parse("M1").?.isTool());
    try testing.expect(identifiers.parse("T1").?.isTool());
    try testing.expect(!identifiers.parse("T1").?.isMessage());
}

test "a name and its real handle can never be confused" {
    // A real handle is long, prefixed, and content-addressed. A short name is
    // one letter and digits. Nothing can satisfy both descriptions.
    const short = try identifiers.formatTool(testing.allocator, 7);
    defer testing.allocator.free(short);
    const real = "result-read-aabbccdd-eeff0011.txt";
    try testing.expect(identifiers.isAlias(short));
    try testing.expect(!identifiers.isAlias(real));
    try testing.expect(!aliases.isReadableHandle(short));
    try testing.expect(aliases.isReadableHandle(real));
}

test "every name a compaction can mint is one this build accepts" {
    for ([_]u8{ identifiers.message_prefix, identifiers.tool_prefix }) |prefix| {
        var index: usize = 1;
        while (index <= 4_096) : (index += 1) {
            const rendered = switch (prefix) {
                identifiers.message_prefix => try identifiers.formatMessage(testing.allocator, index),
                else => try identifiers.formatTool(testing.allocator, index),
            };
            defer testing.allocator.free(rendered);
            const parsed = identifiers.parse(rendered) orelse return error.TestRejectedOwnName;
            try testing.expectEqual(index, parsed.index);
        }
    }
}

test "a name with a leading zero is refused so each entry has one spelling" {
    // Without this rule `T1`, `T01`, and `T001` would all reach entry one, which
    // makes a name the model cites ambiguous about what it referred to.
    for ([_][]const u8{ "T01", "T001", "M01", "M0000001" }) |raw| {
        try testing.expect(!identifiers.isAlias(raw));
    }
}

// --- The index is a closed, validated document ---

fn buildIndex(source: ?[]const u8) !aliases.Index {
    const messages = try testing.allocator.alloc(aliases.MessageAlias, 3);
    errdefer testing.allocator.free(messages);
    messages[0] = .{ .alias = try testing.allocator.dupe(u8, "M1"), .start_byte = 16, .byte_count = 40 };
    messages[1] = .{ .alias = try testing.allocator.dupe(u8, "M2"), .start_byte = 60, .byte_count = 8 };
    messages[2] = .{ .alias = try testing.allocator.dupe(u8, "M3"), .start_byte = 61, .byte_count = 12 };
    const tools = try testing.allocator.alloc(aliases.ToolAlias, 1);
    errdefer testing.allocator.free(tools);
    tools[0] = .{
        .alias = try testing.allocator.dupe(u8, "T1"),
        .handle = try testing.allocator.dupe(u8, "compaction-arguments-" ++ ("a" ** 64)),
    };
    return .{
        .messages = messages,
        .tools = tools,
        .source_handle = if (source) |handle| try testing.allocator.dupe(u8, handle) else null,
    };
}

fn snapshotOf(index: aliases.Index) aliases.Snapshot {
    return .{ .messages = index.messages, .tools = index.tools, .source_handle = index.source_handle };
}

test "an index round-trips without losing a single name" {
    var index = try buildIndex("compaction-source-" ++ ("b" ** 64));
    defer index.deinit(testing.allocator);
    const bytes = try aliases.encode(testing.allocator, snapshotOf(index));
    defer testing.allocator.free(bytes);

    var decoded = (try aliases.decode(testing.allocator, bytes)).?;
    defer decoded.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), decoded.messages.len);
    try testing.expectEqual(@as(usize, 1), decoded.tools.len);
    for (index.messages, decoded.messages) |before, after| {
        try testing.expectEqualStrings(before.alias, after.alias);
        try testing.expectEqual(before.start_byte, after.start_byte);
        try testing.expectEqual(before.byte_count, after.byte_count);
    }
}

test "an index always resolves the names it recorded" {
    var index = try buildIndex("compaction-source-" ++ ("b" ** 64));
    defer index.deinit(testing.allocator);
    const bytes = try aliases.encode(testing.allocator, snapshotOf(index));
    defer testing.allocator.free(bytes);
    var decoded = (try aliases.decode(testing.allocator, bytes)).?;
    defer decoded.deinit(testing.allocator);

    const range = decoded.resolveMessage("M1").?;
    try testing.expectEqual(@as(usize, 16), range.start_byte);
    try testing.expectEqual(@as(usize, 40), range.byte_count);
    const handle = (try decoded.resolveTool(testing.allocator, "T1")).?;
    defer testing.allocator.free(handle);
    try testing.expectEqualStrings("compaction-arguments-" ++ ("a" ** 64), handle);
}

test "a name the index does not record resolves to nothing" {
    var index = try buildIndex(null);
    defer index.deinit(testing.allocator);
    for ([_][]const u8{ "M0", "M4", "T2", "T0", "M01", "t1", "M 1", "../M1", "" }) |raw| {
        try testing.expectEqual(@as(?aliases.MessageRange, null), index.resolveMessage(raw));
        try testing.expectEqual(@as(?[]u8, null), try index.resolveTool(testing.allocator, raw));
        try testing.expect(!index.knowsAlias(raw));
    }
}

test "an index cannot point a read at anything but a stored artifact" {
    // A persisted index is data. If it could name any path, a corrupted or
    // hand-edited file would turn a read into an arbitrary file disclosure.
    for ([_][]const u8{
        "/etc/passwd",
        "~/.fx/settings.json",
        "../../settings.json",
        "settings.json",
        "compaction-source/../../x",
        "result-a/b",
        "result-a b",
        "",
    }) |handle| {
        try testing.expect(!aliases.isReadableHandle(handle));
    }
}

test "an index naming an unreadable handle is refused whole" {
    // One bad entry invalidates the document, rather than being skipped, so a
    // partially trusted index can never resolve to the wrong bytes.
    const document =
        \\{"version":2,"messages":[],"tools":[{"alias":"T1","handle":"result-aa"},{"alias":"T2","handle":"../../etc/passwd"}]}
    ;
    try testing.expectEqual(@as(?aliases.Index, null), try aliases.decode(testing.allocator, document));
}

test "an index with a zero-length message range is refused" {
    // A range of zero bytes would resolve to an empty read that looks like a
    // successful one, which is worse than a clear failure.
    const document =
        \\{"version":2,"messages":[{"alias":"M1","start_byte":10,"byte_count":0}],"tools":[]}
    ;
    try testing.expectEqual(@as(?aliases.Index, null), try aliases.decode(testing.allocator, document));
}

// --- The version ladder ---

test "an index written by this build classifies as current" {
    var index = try buildIndex(null);
    defer index.deinit(testing.allocator);
    const bytes = try aliases.encode(testing.allocator, snapshotOf(index));
    defer testing.allocator.free(bytes);
    try testing.expectEqual(compat.Support.current, compat.classify(testing.allocator, bytes));
}

test "an index written by the previous build classifies as legacy" {
    var index = try buildIndex(null);
    defer index.deinit(testing.allocator);
    const bytes = try aliases.encodeVersion(testing.allocator, snapshotOf(index), aliases.legacy_format_version);
    defer testing.allocator.free(bytes);
    try testing.expectEqual(compat.Support.legacy, compat.classify(testing.allocator, bytes));
    // Legacy still resolves tool names, because that table was always written.
    try testing.expect(compat.resolvesToolNames(compat.Support.legacy));
    try testing.expect(!compat.resolvesMessageNames(compat.Support.legacy));
}

test "an index from a future build is refused rather than guessed at" {
    const document =
        \\{"version":99,"messages":[],"tools":[]}
    ;
    try testing.expectEqual(compat.Support.unsupported, compat.classify(testing.allocator, document));
    try testing.expectEqual(@as(?aliases.Index, null), try aliases.decode(testing.allocator, document));
}

test "a truncated index is refused rather than half-read" {
    // Half an index is worse than none: it would resolve some names and silently
    // fail others, which is the hardest failure for a model to work around.
    for ([_][]const u8{
        "",
        "{\"version\":2,",
        "{\"version\":2,\"messages\":[{\"alias\":\"M1\"",
        "not json at all",
        "{\"messages\":[],\"tools\":[]}",
    }) |document| {
        try testing.expectEqual(compat.Support.unsupported, compat.classify(testing.allocator, document));
        try testing.expectEqual(@as(?aliases.Index, null), try aliases.decode(testing.allocator, document));
    }
}

test "the version ladder and the decoder agree on every version" {
    // Two independent statements of "what can I read" must never disagree, or a
    // caller could pass a classification check and still fail to decode.
    for ([_]u32{ 0, 1, 2, 3, 7, 99 }) |version| {
        var buffer: [128]u8 = undefined;
        const document = try std.fmt.bufPrint(&buffer, "{{\"version\":{d},\"messages\":[],\"tools\":[]}}", .{version});
        const decoded = try aliases.decode(testing.allocator, document);
        const readable = decoded != null;
        try testing.expectEqual(compat.canRead(version), readable);
        if (!compat.canRead(version)) {
            try testing.expectEqual(compat.Support.unsupported, compat.classify(testing.allocator, document));
        }
    }
}
