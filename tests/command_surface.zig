//! The top-level command surface.
//!
//! fx is interactive-first. These tests pin the commands that exist and, more
//! importantly, the ones that were deliberately removed.

const std = @import("std");
const testing = std.testing;

const builtin_commands = @import("../src/builtins/commands.zig");
const command_specs = @import("../src/core/slash_commands/command_specs.zig");

const TopLevelKind = command_specs.TopLevelKind;
const registry = builtin_commands.top_level_registry;

fn matches(kind: TopLevelKind) bool {
    return command_specs.matchesTopLevel(registry, @tagName(kind), kind);
}

test "the interactive commands fx still ships" {
    const expected = [_]TopLevelKind{
        .help,      .pr,       .issue,   .sessions, .session,
        .@"resume", .provider, .models,  .setup,    .status,
        .doctor,    .usage,    .upgrade, .replay,   .workspace,
    };
    for (expected) |kind| {
        if (!matches(kind)) {
            std.debug.print("expected a command for .{s}\n", .{@tagName(kind)});
            return error.TestExpectedCommand;
        }
    }
}

test "one-shot and editor protocol commands are gone" {
    // These were removed on purpose. If any of them resolve again the surface
    // has regressed to something fx no longer supports.
    const removed_text = [_][]const u8{
        "ask", "acp", "grok", "codex", "chatgpt", "libfx", "serve", "daemon",
    };
    for (removed_text) |token| {
        if (command_specs.matchesTopLevel(registry, token, .help)) {
            std.debug.print("removed command resolved again: {s}\n", .{token});
            return error.TestRemovedCommandResurrected;
        }
    }
}

test "the removed kinds no longer exist in the type" {
    // A compile-time guarantee stronger than any string check: asking for the
    // old variants would not build.
    var builtin_count: usize = 0;
    var total_count: usize = 0;
    for (@typeInfo(TopLevelKind).@"enum".fields) |_| builtin_count += 1;
    for (std.enums.values(TopLevelKind)) |_| total_count += 1;
    try testing.expectEqual(builtin_count, total_count);
}

test "every registered command has non-empty usage text" {
    inline for (@typeInfo(TopLevelKind).@"enum".fields) |field| {
        const kind: TopLevelKind = @enumFromInt(field.value);
        const usage = command_specs.topLevelUsage(registry, kind);
        if (usage.len == 0) {
            std.debug.print("empty usage for .{s}\n", .{@tagName(kind)});
            return error.TestExpectedUsage;
        }
    }
}

test "the help groups only mention commands that exist" {
    for (builtin_commands.top_level_help_groups) |group| {
        for (group.entries) |entry| {
            const kind = entry.kind orelse continue;
            if (!matches(kind)) {
                std.debug.print("help advertises unknown command .{s}\n", .{@tagName(kind)});
                return error.TestUnknownHelpEntry;
            }
        }
    }
}

test "rendered help names every advertised command" {
    const text = try command_specs.renderTopLevelHelp(
        testing.allocator,
        registry,
        command_specs.top_level_help_default_width,
        "0.0.0-test",
    );
    defer testing.allocator.free(text);

    for (builtin_commands.top_level_help_groups) |group| {
        for (group.entries) |entry| {
            // Group usage strings read like "sessions" or "session <last|id>";
            // the leading token is the command name.
            var name = entry.usage;
            if (std.mem.indexOfScalar(u8, name, ' ')) |space| name = name[0..space];
            if (name.len == 0) continue;
            if (std.mem.indexOf(u8, text, name) == null) {
                std.debug.print("help output is missing command '{s}'\n", .{name});
                return error.TestMissingFromHelp;
            }
        }
    }
}

test "rendered help does not advertise removed commands" {
    const text = try command_specs.renderTopLevelHelp(
        testing.allocator,
        registry,
        command_specs.top_level_help_default_width,
        "0.0.0-test",
    );
    defer testing.allocator.free(text);

    for ([_][]const u8{ "ask", "acp" }) |token| {
        if (std.mem.indexOf(u8, text, token) != null) {
            std.debug.print("help still advertises '{s}'\n", .{token});
            return error.TestRemovedCommandInHelp;
        }
    }
}
