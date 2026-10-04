//! Tiered input routing for the full-screen chat surface.
//!
//! The reader-mode gate this replaces was a single boolean. When the alternate
//! screen was active it either took a decoded byte or it did not, and because
//! `keyForAction` had no composer branch, printable input fell through to a
//! composer living in an inline band the alternate screen never painted.
//! Keystrokes were accepted and invisible.
//!
//! Full-screen needs one byte to reach up to three different consumers, so
//! routing is decided by tier rather than by a boolean:
//!
//!   * screen   control bytes and navigation that belong to the surface itself
//!   * viewport scrolling that belongs to the transcript body
//!   * composer everything else, which is what makes the surface live
//!
//! The routing decision is a pure function of the decoded action, so it is
//! testable without a terminal, a file descriptor, or a running app.

const std = @import("std");
const input_action = @import("input_action.zig");
const transcript_presentation = @import("../output/transcript_presentation.zig");
const types = @import("../shared/types.zig");

/// Which consumer a decoded input belongs to.
pub const Tier = enum {
    /// The surface itself: open, close, interrupt, redraw.
    screen,
    /// Transcript scrolling.
    viewport,
    /// Ordinary text editing into the composer.
    composer,
    /// Nothing wants it. The caller should not consume the byte.
    ignore,
};

/// What the surface should do with a screen-tier action.
pub const ScreenAction = union(enum) {
    toggle,
    close,
    interrupt,
    redraw,
    navigate: transcript_presentation.Event,
    /// Accept the byte but do nothing, which is what a redraw-only press means.
    consumed_noop,
    reject,
};

/// Scrolling inside the surface is a viewport concern rather than a
/// presentation-depth transition, so a viewport-tier action maps to
/// `consumed_noop` here. The caller applies the scroll through the transcript
/// presentation state; this table only decides who owns the byte.
///
/// `transcript_presentation.Event` carries only `toggle`, `left`, and `right`,
/// so it is not the vocabulary for vertical scrolling.
///
/// Byte-level control handling. Ctrl+C interrupts and Ctrl+L redraws; both
/// are screen-tier so a running turn stays stoppable from inside the surface.
pub fn tierForControlByte(byte: u8) Tier {
    return switch (byte) {
        // Ctrl+C interrupts the running turn. It must not be swallowed by the
        // composer, or the user cannot stop a runaway tool call from inside the
        // surface.
        3 => .screen,
        12 => .screen,
        16 => .screen,
        20 => .screen,
        // A retired binding must resolve to nothing rather than silently do
        // something adjacent, which is why bytes 15 and 20 are absent.
        15 => .ignore,
        // Ctrl+W is a composer editing chord (delete previous word), so it must
        // stay with the composer rather than being treated as a screen control.
        else => .composer,
    };
}

pub fn screenActionForControlByte(byte: u8) ScreenAction {
    return switch (byte) {
        3 => .interrupt,
        12 => .redraw,
        16 => .consumed_noop,
        20 => .toggle,
        15 => .reject,
        else => .reject,
    };
}

/// Cursor and scroll keys belong to the viewport so the transcript moves while
/// the composer keeps focus. Navigation inside the composer is a different
/// concern and arrives as a composer action instead.
pub fn tierForAction(action: input_action.Action) Tier {
    return switch (action) {
        .toggle_fullscreen => .screen,
        .escape => .screen,
        .cursor_up, .cursor_down => .viewport,
        .page_up, .page_down => .viewport,
        .mouse_wheel => .viewport,
        .cursor_left, .cursor_right => .composer,
        .remapped_byte => |byte| tierForControlByte(byte),
        else => .composer,
    };
}

pub fn screenActionForAction(action: input_action.Action) ScreenAction {
    return switch (action) {
        .toggle_fullscreen => .toggle,
        .escape => .close,
        .cursor_up => .consumed_noop,
        .cursor_down => .consumed_noop,
        .page_up => .consumed_noop,
        .page_down => .consumed_noop,
        .mouse_wheel => .consumed_noop,
        .remapped_byte => |byte| screenActionForControlByte(byte),
        else => .reject,
    };
}

/// True when the approval surface is active. Approval is a separate
/// alternate-screen owner, so while it holds the buffer the chat surface must
/// not claim the byte. Leaving it a predicate rather than folding it into the
/// tier keeps the priority decision in one place.
pub fn composerOwnsInput(surface_active: bool, approval_active: bool) bool {
    return surface_active and !approval_active;
}

/// Mouse wheel events reach the viewport as offsets rather than as directions
/// once a physical scroll has been applied by the terminal, so they are treated
/// as consumed without further navigation.
pub fn wheelIsConsumed(direction: types.MouseWheel) bool {
    _ = direction;
    return true;
}
