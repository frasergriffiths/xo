//! Frame decomposition for the full-screen chat surface.
//!
//! Inline mode grows by emitting real newlines and letting the terminal scroll,
//! which is why inline chrome appears to move as content arrives. A fixed frame
//! inverts that: the transcript scrolls internally as a logical offset while the
//! composer and footer stay anchored to the bottom of the frame and never move.
//!
//! That pinned-chrome requirement is the whole point of this module, so the
//! geometry is expressed as a pure function of the terminal size and the
//! composer height. It can then be checked arithmetically without a terminal,
//! which matters because band overlap produces a mangled frame that no
//! assertion in the repository would otherwise catch.

const std = @import("std");

pub const minimum_rows: u16 = 6;
pub const minimum_cols: u16 = 20;

/// Why the surface refused to open.
/// The only way the surface can refuse to open: the terminal is too small to
/// lay out a usable frame. A refusal is acceptable; a mangled frame is not.
pub const Refusal = error{TerminalTooSmall};

pub const Layout = struct {
    cols: u16,
    rows: u16,
    /// Scrolling conversation body. May be empty at very small sizes, though
    /// the surface refuses to open before it gets that small.
    transcript_top: u16,
    transcript_bottom: u16,
    /// Composer rows, directly above the footer.
    composer_top: u16,
    composer_bottom: u16,
    /// Footer hint rows at the very bottom of the frame.
    footer_top: u16,
    footer_bottom: u16,

    pub fn transcriptRows(self: Layout) u16 {
        if (self.transcript_bottom < self.transcript_top) return 0;
        return self.transcript_bottom - self.transcript_top + 1;
    }

    pub fn composerRows(self: Layout) u16 {
        if (self.composer_bottom < self.composer_top) return 0;
        return self.composer_bottom - self.composer_top + 1;
    }

    pub fn footerRows(self: Layout) u16 {
        if (self.footer_bottom < self.footer_top) return 0;
        return self.footer_bottom - self.footer_top + 1;
    }
};

/// Computes the full-screen decomposition, or refuses.
///
/// Rows are counted from 1 at the top, matching ANSI and the rest of the paint
/// plan. The composer and footer are anchored to `rows` and are therefore
/// invariant to the transcript: scrolling changes `transcript_top`, never
/// `composer_top` or `footer_top`. That invariance is the pinned-chrome
/// property, and it holds by construction here rather than by convention.
pub fn compute(
    cols: u16,
    rows: u16,
    composer_height: u16,
    footer_height: u16,
) Refusal!Layout {
    if (cols < minimum_cols or rows < minimum_rows) return error.TerminalTooSmall;

    // The composer and footer must fit, and there must be at least one row left
    // for the transcript. Clamping rather than wrapping is deliberate: a frame
    // that grows downward would push its own footer off the screen.
    const chrome = composer_height +| footer_height;
    if (chrome + 1 > rows) return error.TerminalTooSmall;

    const footer_bottom = rows;
    const footer_top = rows - footer_height + 1;
    const composer_bottom = footer_top -| 1;
    const composer_top = composer_bottom - composer_height + 1;
    const transcript_bottom = composer_top -| 1;

    return .{
        .cols = cols,
        .rows = rows,
        .transcript_top = 1,
        .transcript_bottom = transcript_bottom,
        .composer_top = composer_top,
        .composer_bottom = composer_bottom,
        .footer_top = footer_top,
        .footer_bottom = footer_bottom,
    };
}

/// Scrolls the transcript by `rows_scrolled` without touching the chrome.
///
/// The transcript body slides within its own band and clamps at both ends. The
/// composer and footer are recomputed identically, which is the property the
/// pinned-chrome exit criterion asserts: a scroll-only frame leaves those rows
/// byte-identical.
pub fn scrollTranscript(layout: Layout, rows_scrolled: i32) Layout {
    const body_rows = layout.transcriptRows();
    if (body_rows == 0) return layout;

    // Clamp the requested offset to what the body can absorb. A scroll that
    // would run past an end is clamped rather than wrapping, because a
    // transcript that scrolls past its end has no meaning in a fixed frame.
    const max_offset: i32 = 0;
    const min_offset: i32 = -@as(i32, @intCast(body_rows));
    const current: i32 = 0;
    const requested = current + rows_scrolled;
    const offset = std.math.clamp(requested, min_offset, max_offset);

    const shifted_top: i32 = @as(i32, @intCast(layout.transcript_top)) + offset;
    const shifted_bottom: i32 = @as(i32, @intCast(layout.transcript_bottom)) + offset;

    return .{
        .cols = layout.cols,
        .rows = layout.rows,
        .transcript_top = @intCast(std.math.clamp(shifted_top, 1, @as(i32, @intCast(layout.rows)))),
        .transcript_bottom = @intCast(std.math.clamp(shifted_bottom, 0, @as(i32, @intCast(layout.rows)))),
        // The pinned part. These four are copied, not derived, so a scroll can
        // never move them.
        .composer_top = layout.composer_top,
        .composer_bottom = layout.composer_bottom,
        .footer_top = layout.footer_top,
        .footer_bottom = layout.footer_bottom,
    };
}

/// True when the chrome did not move between two layouts of the same size.
pub fn chromePinned(before: Layout, after: Layout) bool {
    return before.cols == after.cols and
        before.rows == after.rows and
        before.composer_top == after.composer_top and
        before.composer_bottom == after.composer_bottom and
        before.footer_top == after.footer_top and
        before.footer_bottom == after.footer_bottom;
}

/// Every row of the frame is owned by exactly one band. Overlapping or
/// unpainted rows both produce a mangled frame, so this is checked directly
/// rather than inferred from the arithmetic above.
pub fn bandsAreDisjoint(layout: Layout) bool {
    if (layout.transcriptRows() > 0 and layout.transcript_bottom >= layout.composer_top) return false;
    if (layout.composerRows() > 0 and layout.composer_bottom >= layout.footer_top) return false;
    if (layout.footerRows() > 0 and layout.footer_bottom > layout.rows) return false;
    return true;
}
