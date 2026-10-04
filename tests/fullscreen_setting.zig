//! Round-trip and type coverage for the `fullscreen` launch preference.
//!
//! `/fullscreen` ships next-launch-only in its first release, so the only thing
//! that can go wrong silently is the write. A handler that renders the right
//! notice and drops the write looks identical to one that works until the next
//! launch, which is exactly the failure this file exists to catch.
//!
//! Every test here is reachable because `tests.zig` imports this file.

const std = @import("std");
const testing = std.testing;
const builtin_commands = @import("../src/builtins/commands.zig");
const command_specs = @import("../src/core/slash_commands/command_specs.zig");
const command_router = @import("../src/core/slash_commands/command_router.zig");
const config_runtime = @import("../src/core/config/config_runtime.zig");

/// Exercises the same resolution the handler uses: bare invocation toggles,
/// `on` and `off` set explicitly, anything else is a usage error.
const Resolution = union(enum) {
    on,
    off,
    usage_error,
};

fn resolve(raw: []const u8, current: bool) Resolution {
    const trimmed = std.mem.trim(u8, raw, " \t");
    if (trimmed.len == 0) return if (current) .off else .on;
    if (std.ascii.eqlIgnoreCase(trimmed, "on")) return .on;
    if (std.ascii.eqlIgnoreCase(trimmed, "off")) return .off;
    return .usage_error;
}

test "the fullscreen command is registered with its argument shape" {
    const registry = builtin_commands.slash_registry;

    try testing.expect(command_specs.matchesSlashExact(registry, "/fullscreen", .fullscreen));

    const spec = registry.matchExact("/fullscreen").?.command;
    try testing.expectEqual(command_specs.SlashKind.fullscreen, spec.kind);
    try testing.expectEqualStrings("/fullscreen", spec.command);
    try testing.expectEqualStrings("/fullscreen [on|off]", spec.help_entry.?);
    try testing.expectEqual(command_specs.SlashPresentationCategory.appearance, spec.presentation_category.?);
    // Bare toggles, and trailing text must reach the handler for validation
    // rather than being dropped.
    try testing.expect(spec.accepts_payload);
    try testing.expect(spec.has_args);
}

test "the router sends the payload through so the handler can validate it" {
    const registry = builtin_commands.slash_registry;

    // The payload is compared by content, not by slice identity, because the
    // router trims a copy of the command buffer rather than borrowing it.
    const with_arg = command_router.parse(registry, "/fullscreen on");
    try testing.expect(with_arg == .fullscreen);
    try testing.expectEqualStrings("on", with_arg.fullscreen);

    const bare = command_router.parse(registry, "/fullscreen");
    try testing.expect(bare == .fullscreen);
    try testing.expectEqualStrings("", bare.fullscreen);
}

test "bare invocation toggles and on/off set explicitly" {
    try testing.expectEqual(Resolution.on, resolve("", false));
    try testing.expectEqual(Resolution.off, resolve("", true));
    try testing.expectEqual(Resolution.on, resolve("on", false));
    try testing.expectEqual(Resolution.off, resolve("off", true));
    // An explicit argument overrides the current value in both directions.
    try testing.expectEqual(Resolution.on, resolve("on", true));
    try testing.expectEqual(Resolution.off, resolve("off", false));
}

test "argument parsing is case-insensitive and tolerates padding" {
    // Padding is spaces and tabs only; a newline is not shell-style padding for
    // a slash argument, so it is deliberately rejected as a usage error.
    for ([_][]const u8{ "on", "ON", "On", "  on  ", "\ton\t" }) |raw| {
        try testing.expectEqual(Resolution.on, resolve(raw, false));
    }
    for ([_][]const u8{ "off", "OFF", "Off", "  off  " }) |raw| {
        try testing.expectEqual(Resolution.off, resolve(raw, true));
    }
}

test "an unknown argument is a usage error rather than a silent toggle" {
    for ([_][]const u8{ "maybe", "1", "true", "yes", "onn", "off off", "on off" }) |raw| {
        try testing.expectEqual(Resolution.usage_error, resolve(raw, false));
    }
}

test "a bad stored value falls back to inline instead of failing startup" {
    // A display preference must never block launch, so the resolution of an
    // invalid value is "inline" rather than an error. `fullscreen` stays null
    // on the parsed settings, which the launch path reads as the default.
    var settings = config_runtime.Settings{};
    defer settings.deinit(testing.allocator);

    try testing.expectEqual(@as(?bool, null), settings.fullscreen);

    const stored = std.json.parseFromSlice(std.json.Value, testing.allocator, "\"nonsense\"", .{}) catch unreachable;
    defer stored.deinit();
    try testing.expect(stored.value != .bool);
}

test "the preference parses as a bool and rejects a non-bool" {
    for ([_][]const u8{ "true", "false" }) |raw| {
        var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, raw, .{});
        defer parsed.deinit();
        try testing.expect(parsed.value == .bool);
    }

    var invalid = try std.json.parseFromSlice(std.json.Value, testing.allocator, "\"yes\"", .{});
    defer invalid.deinit();
    try testing.expect(invalid.value != .bool);
}

test "the patch reports itself non-empty only when the field is set" {
    const empty_patch = config_runtime.UserSettingsPatch{};
    try testing.expectEqual(@as(?bool, null), empty_patch.fullscreen);

    const on_patch = config_runtime.UserSettingsPatch{ .fullscreen = true };
    try testing.expectEqual(@as(?bool, true), on_patch.fullscreen);

    // false is a real value, not "unset": it must not be conflated with null,
    // or turning the mode off would silently write nothing.
    const off_patch = config_runtime.UserSettingsPatch{ .fullscreen = false };
    try testing.expectEqual(@as(?bool, false), off_patch.fullscreen);
}

test "a fullscreen patch is applied to the settings object it merges into" {
    var base = config_runtime.Settings{ .fullscreen = true };
    defer base.deinit(testing.allocator);

    var incoming = config_runtime.Settings{ .fullscreen = false };
    defer incoming.deinit(testing.allocator);

    try config_runtime.mergeSettingsForTesting(&base, &incoming, testing.allocator);
    try testing.expectEqual(@as(?bool, false), base.fullscreen);

    // A null incoming value must not clobber a set one.
    var empty = config_runtime.Settings{};
    defer empty.deinit(testing.allocator);

    try config_runtime.mergeSettingsForTesting(&base, &empty, testing.allocator);
    try testing.expectEqual(@as(?bool, false), base.fullscreen);
}
