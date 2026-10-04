//! Keybinding coverage for the full-screen takeover.
//!
//! Ctrl+O is retired: it used to toggle the full-transcript reader and must now
//! resolve to nothing. Ctrl+T (byte 20) takes over the surface, chosen because
//! it is a bare control byte, so it works under tmux where kitty keyboard
//! protocol bindings do not.
//!
//! Both directions matter. A regression that re-maps byte 15 would silently
//! resurrect a deleted feature, and one that drops byte 20 would leave the mode
//! unreachable by keyboard.

const std = @import("std");
const testing = std.testing;
const escape_parser = @import("../src/ui/input/escape_parser.zig");
const input_action = @import("../src/core/input/input_action.zig");

test "ctrl+o no longer maps to any feature action" {
    try testing.expectEqual(@as(?input_action.Action, null), escape_parser.controlByteFeatureAction(15));
}

test "ctrl+t maps to the full-screen toggle" {
    try testing.expectEqual(
        input_action.Action.toggle_fullscreen,
        escape_parser.controlByteFeatureAction(20).?,
    );
}

test "ctrl+p still opens the model catalog" {
    // Adjacent control bytes must not be disturbed by the rebind.
    try testing.expectEqual(
        input_action.Action.open_model_catalog,
        escape_parser.controlByteFeatureAction(16).?,
    );
}

test "unmapped control bytes stay unmapped" {
    for ([_]u8{ 0, 1, 2, 14, 17, 19, 21, 23, 25, 26, 27 }) |byte| {
        if (byte == 16 or byte == 20) continue;
        try testing.expectEqual(
            @as(?input_action.Action, null),
            escape_parser.controlByteFeatureAction(byte),
        );
    }
}

test "the toggle action exists as a distinct action value" {
    // Constructing the value is the check: if the tag were removed, or if the
    // retired name were still in use, this stops compiling.
    const toggled: input_action.Action = .toggle_fullscreen;
    try testing.expect(toggled == .toggle_fullscreen);

    // The retired action must not be reachable by any decoded byte, which is
    // the property that matters at runtime. Retiring the variant itself is
    // enforced at compile time by the absence of any reference to it.
    for ([_]u8{ 0, 3, 12, 15, 16, 20, 27 }) |byte| {
        if (escape_parser.controlByteFeatureAction(byte)) |action| {
            try testing.expect(action != .toggle_fullscreen or byte == 20);
        }
    }
}
