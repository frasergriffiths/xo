//! Compacted-turn and tool-call identifiers.
//!
//! After a compaction the model can only cite long content-addressed handles
//! such as `compaction-arguments-<64 hex>`. `M1` and `T1` are short, stable
//! within one compaction, and far easier to reference, so the handoff names
//! originals with them and `read_tool_result` accepts them directly.
//!
//! An alias is never stored as a real artifact. Real handles always begin with
//! `result-`, `image-`, `diff-`, or `compaction-`, so the `M`/`T` prefixes can
//! never collide with one.
//!
//! Every parser here validates the whole string before any lookup, and no
//! function in this file builds a filesystem path from its input.

const std = @import("std");
const testing = std.testing;

/// Prefix for a compacted user message or turn.
pub const message_prefix: u8 = 'M';
/// Prefix for a compacted tool call and its result.
pub const tool_prefix: u8 = 'T';

/// Longest alias this module will ever produce or accept, e.g. `T4294967295`.
const max_alias_len: usize = 12;

pub const MessageKind = enum {
    user,
    assistant,
    handoff,
    permission_feedback,

    pub fn label(self: MessageKind) []const u8 {
        return switch (self) {
            .user => "user",
            .assistant => "assistant",
            .handoff => "handoff",
            .permission_feedback => "permission_feedback",
        };
    }

    pub fn parse(raw: []const u8) ?MessageKind {
        for (std.enums.values(MessageKind)) |kind| {
            if (std.mem.eql(u8, raw, kind.label())) return kind;
        }
        return null;
    }
};

/// A parsed alias: which table it addresses and which one-based entry.
pub const Alias = struct {
    prefix: u8,
    index: usize,

    pub fn isMessage(self: Alias) bool {
        return self.prefix == message_prefix;
    }

    pub fn isTool(self: Alias) bool {
        return self.prefix == tool_prefix;
    }
};

/// Renders the alias for a one-based index.
pub fn formatMessage(alloc: std.mem.Allocator, index: usize) ![]u8 {
    return format(alloc, message_prefix, index);
}

/// Renders the alias for a one-based tool-call index.
pub fn formatTool(alloc: std.mem.Allocator, index: usize) ![]u8 {
    return format(alloc, tool_prefix, index);
}

fn format(alloc: std.mem.Allocator, prefix: u8, index: usize) ![]u8 {
    // One-based, so index 0 is never rendered.
    if (index == 0) return error.InvalidAlias;
    return std.fmt.allocPrint(alloc, "{c}{d}", .{ prefix, index });
}

/// True when `raw` is exactly `M<digits>` or `T<digits>`. This is the cheap
/// gate callers use to decide whether alias resolution is worth attempting.
pub fn isAlias(raw: []const u8) bool {
    return parse(raw) != null;
}

/// Parses a well-formed alias. Returns null for anything else, including a bare
/// prefix, a zero index, a signed number, embedded whitespace, and any string
/// carrying a character that could otherwise influence a lookup.
pub fn parse(raw: []const u8) ?Alias {
    if (raw.len < 2 or raw.len > max_alias_len) return null;
    const prefix = raw[0];
    if (prefix != message_prefix and prefix != tool_prefix) return null;
    // Reject a leading zero so an alias has exactly one spelling.
    if (raw[1] == '0') return null;
    for (raw[1..]) |byte| {
        if (!std.ascii.isDigit(byte)) return null;
    }
    const index = std.fmt.parseUnsigned(usize, raw[1..], 10) catch return null;
    if (index == 0) return null;
    return .{ .prefix = prefix, .index = index };
}

test "aliases are rendered one-based" {
    {
        const alias = try formatMessage(testing.allocator, 1);
        defer testing.allocator.free(alias);
        try testing.expectEqualStrings("M1", alias);
    }
    {
        const alias = try formatTool(testing.allocator, 12);
        defer testing.allocator.free(alias);
        try testing.expectEqualStrings("T12", alias);
    }
}

test "index zero is never rendered" {
    try testing.expectError(error.InvalidAlias, formatMessage(testing.allocator, 0));
    try testing.expectError(error.InvalidAlias, formatTool(testing.allocator, 0));
}

test "well-formed aliases parse back to what was rendered" {
    for ([_]u8{ message_prefix, tool_prefix }) |prefix| {
        var index: usize = 1;
        while (index <= 300) : (index += 1) {
            const rendered = try format(testing.allocator, prefix, index);
            defer testing.allocator.free(rendered);
            const parsed = parse(rendered) orelse {
                std.debug.print("failed to reparse {s}\n", .{rendered});
                return error.TestExpectedAlias;
            };
            try testing.expectEqual(prefix, parsed.prefix);
            try testing.expectEqual(index, parsed.index);
        }
    }
}

test "aliases are recognized by their single-letter prefix" {
    try testing.expect(isAlias("M1"));
    try testing.expect(isAlias("T1"));
    try testing.expect(isAlias("T4294967295"));
}

test "malformed aliases are rejected" {
    // Anything here that reached a filesystem lookup would be a bug.
    for ([_][]const u8{
        "",     "M",   "T",     "M0",     "T0",
        "Mx",   "Tx",  "M-1",   "T-1",    "M 1",
        "T 1",  "M1 ", "m1",    "t1",     "R1",
        "M1.0", "M1/", "../T1", "M../T1", "T1\n",
        "M1x",  "MT1", "M+1",   "T_1",    " 1",
    }) |raw| {
        if (isAlias(raw)) {
            std.debug.print("accepted malformed alias {s}\n", .{raw});
            return error.TestAcceptedMalformedAlias;
        }
    }
}

test "an alias has exactly one spelling" {
    // Leading zeros would make the same entry reachable several ways.
    try testing.expect(!isAlias("M01"));
    try testing.expect(!isAlias("T007"));
}

test "an absurdly long alias is rejected before any lookup" {
    const long = "T" ++ ("1" ** 64);
    try testing.expect(!isAlias(long));
    try testing.expectEqual(@as(?Alias, null), parse(long));
}

test "message kinds round-trip through their labels" {
    for (std.enums.values(MessageKind)) |kind| {
        try testing.expectEqual(kind, MessageKind.parse(kind.label()).?);
    }
    try testing.expectEqual(@as(?MessageKind, null), MessageKind.parse("other"));
}

test "parse never accepts a non-ascii digit" {
    // Full-width digits must not slip through a byte-wise check.
    try testing.expect(!isAlias("M\u{ff11}"));
    try testing.expect(!isAlias("T\u{0661}"));
}
