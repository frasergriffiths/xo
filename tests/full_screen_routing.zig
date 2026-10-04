//! Coverage for the tiered full-screen input router.
//!
//! This is the Phase 1 blocker: the boolean gate it replaces sent printable
//! input to a composer the alternate screen never painted, so keystrokes were
//! accepted and invisible. The routing table is a pure function, so every
//! property below is checkable without a TTY.

const std = @import("std");
const testing = std.testing;
const routing = @import("../src/core/input/full_screen_routing.zig");
const input_action = @import("../src/core/input/input_action.zig");

test "ctrl+t toggles full screen and ctrl+o is retired" {
    try testing.expectEqual(routing.Tier.screen, routing.tierForControlByte(20));
    try testing.expectEqual(routing.ScreenAction.toggle, routing.screenActionForControlByte(20));

    // The retired reader binding must consume nothing. If it ever resolves to a
    // screen action again, Ctrl+O has come back from the dead.
    try testing.expectEqual(routing.Tier.ignore, routing.tierForControlByte(15));
    try testing.expectEqual(routing.ScreenAction.reject, routing.screenActionForControlByte(15));
}

test "ctrl+c interrupts rather than being swallowed by the composer" {
    // Security-relevant: a runaway turn must be stoppable from inside the
    // surface. If Ctrl+C were composer-tier, the user could not halt fx while
    // looking at the full-screen view.
    try testing.expectEqual(routing.Tier.screen, routing.tierForControlByte(3));
    try testing.expectEqual(routing.ScreenAction.interrupt, routing.screenActionForControlByte(3));
}

test "scroll keys reach the viewport, not the composer" {
    for ([_]input_action.Action{ .cursor_up, .cursor_down, .page_up, .page_down }) |action| {
        try testing.expectEqual(routing.Tier.viewport, routing.tierForAction(action));
    }
}

test "cursor left and right stay with the composer" {
    // Horizontal cursor movement is text editing inside a focused composer. If
    // it were viewport-tier, arrowing left and right would scroll the
    // transcript instead of moving the caret.
    try testing.expectEqual(routing.Tier.viewport, routing.tierForAction(.cursor_up));
    try testing.expectEqual(routing.Tier.composer, routing.tierForAction(.cursor_left));
    try testing.expectEqual(routing.Tier.composer, routing.tierForAction(.cursor_right));
}

test "escape closes the surface and the toggle action toggles it" {
    try testing.expectEqual(routing.Tier.screen, routing.tierForAction(.escape));
    try testing.expectEqual(routing.ScreenAction.close, routing.screenActionForAction(.escape));
    try testing.expectEqual(routing.Tier.screen, routing.tierForAction(.toggle_fullscreen));
    try testing.expectEqual(routing.ScreenAction.toggle, routing.screenActionForAction(.toggle_fullscreen));
}

test "ordinary editing actions reach the composer" {
    // The liveness property. Before the tiered router these fell through to a
    // composer nobody could see, so this list is the regression guard.
    const composer_actions = [_]input_action.Action{
        .insert_newline,
        .delete_to_line_start,
        .delete_to_line_end,
        .delete_word_left,
        .delete_word_right,
        .delete_next,
        .clear_line,
        .toggle_permission_mode,
    };
    for (composer_actions) |action| {
        try testing.expectEqual(routing.Tier.composer, routing.tierForAction(action));
    }
}

test "remapped control bytes are routed by the byte table" {
    // A remapped byte must not silently become composer-tier, or a bound
    // control byte would start typing into the composer.
    const action = input_action.Action{ .remapped_byte = 20 };
    try testing.expectEqual(routing.Tier.screen, routing.tierForAction(action));
    try testing.expectEqual(routing.ScreenAction.toggle, routing.screenActionForAction(action));

    const retired = input_action.Action{ .remapped_byte = 15 };
    try testing.expectEqual(routing.Tier.ignore, routing.tierForAction(retired));
}

test "the composer owns input only when the surface is active and no approval is" {
    try testing.expect(routing.composerOwnsInput(true, false));
    // While approval holds the buffer, the chat surface must not claim input.
    try testing.expect(!routing.composerOwnsInput(true, true));
    // Inline mode: nothing to route to.
    try testing.expect(!routing.composerOwnsInput(false, false));
    try testing.expect(!routing.composerOwnsInput(false, true));
}

test "no decoded action is routed to the ignore tier by accident" {
    // Every action the surface cares about must land on a real tier. A
    // stray `else => .ignore` would make a key do nothing.
    const actions = [_]input_action.Action{
        .escape,
        .toggle_fullscreen,
        .cursor_up,
        .cursor_down,
        .cursor_left,
        .cursor_right,
        .page_up,
        .page_down,
        .insert_newline,
        .delete_to_line_end,
        .clear_line,
        .toggle_permission_mode,
    };
    for (actions) |action| {
        try testing.expect(routing.tierForAction(action) != .ignore);
    }
}
