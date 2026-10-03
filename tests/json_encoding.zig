//! JSON writing helpers.
//!
//! `writeJsonStr` is the project's escaping primitive for hand-written JSON.
//! These cases are the ones that break silently if it regresses.

const std = @import("std");
const testing = std.testing;

const json_str = @import("../src/core/shared/json_str.zig");

fn render(value: []const u8) ![]u8 {
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    try json_str.writeJsonStr(value, &buf.writer);
    return testing.allocator.dupe(u8, buf.written());
}

test "plain text is quoted unchanged" {
    const out = try render("banana");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("\"banana\"", out);
}

test "quotes and backslashes are escaped" {
    {
        const out = try render("say \"hi\"");
        defer testing.allocator.free(out);
        try testing.expectEqualStrings("\"say \\\"hi\\\"\"", out);
    }
    {
        const out = try render("a\\b");
        defer testing.allocator.free(out);
        try testing.expectEqualStrings("\"a\\\\b\"", out);
    }
}

test "control characters use their short escapes" {
    const cases = [_]struct { input: []const u8, expected: []const u8 }{
        .{ .input = "a\nb", .expected = "\"a\\nb\"" },
        .{ .input = "a\rb", .expected = "\"a\\rb\"" },
        .{ .input = "a\tb", .expected = "\"a\\tb\"" },
        .{ .input = "a\x08b", .expected = "\"a\\bb\"" },
        .{ .input = "a\x0cb", .expected = "\"a\\fb\"" },
    };
    for (cases) |case| {
        const out = try render(case.input);
        defer testing.allocator.free(out);
        try testing.expectEqualStrings(case.expected, out);
    }
}

test "remaining C0 controls use a unicode escape" {
    const out = try render("\x01");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("\"\\u0001\"", out);
}

test "an empty string still produces a valid empty token" {
    const out = try render("");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("\"\"", out);
}

test "escaped output parses back to the original value" {
    // The real invariant: escaping must round-trip through a JSON parser.
    const original = "tab\there \"quoted\" \\ back \x01 end";
    const escaped = try render(original);
    defer testing.allocator.free(escaped);

    var parsed = try std.json.parseFromSlice([]const u8, testing.allocator, escaped, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings(original, parsed.value);
}

test "non-ascii text is emitted literally and round-trips" {
    const original = "caf\u{00e9} \u{1f680}";
    const escaped = try render(original);
    defer testing.allocator.free(escaped);

    var parsed = try std.json.parseFromSlice([]const u8, testing.allocator, escaped, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings(original, parsed.value);
}
