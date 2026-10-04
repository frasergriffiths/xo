//! Geometry coverage for the full-screen frame decomposition.
//!
//! The pinned-chrome requirement is the one the user called out by name: the
//! footer line and the input row must not move while the transcript scrolls.
//! These tests assert it arithmetically, over many sizes, with no terminal.

const std = @import("std");
const testing = std.testing;
const layout = @import("../src/ui/render_engine/full_screen_layout.zig");

test "the frame fills the terminal with disjoint bands" {
    const cases = [_][3]u16{
        .{ 80, 24, 1 },
        .{ 80, 24, 3 },
        .{ 120, 40, 1 },
        .{ 120, 40, 5 },
        .{ 20, 6, 1 },
        .{ 200, 60, 2 },
        .{ 40, 10, 4 },
    };
    for (cases) |case| {
        const cols = case[0];
        const rows = case[1];
        const composer_height = case[2];
        const computed = try layout.compute(cols, rows, composer_height, 1);
        try testing.expect(layout.bandsAreDisjoint(computed));
        // Nothing may be painted past the bottom of the terminal.
        try testing.expect(computed.footer_bottom <= rows);
        try testing.expect(computed.footer_bottom == rows);
    }
}

test "the footer occupies the bottom row of the frame" {
    const computed = try layout.compute(80, 24, 1, 1);
    try testing.expectEqual(@as(u16, 24), computed.footer_bottom);
    try testing.expectEqual(@as(u16, 24), computed.footer_top);
    try testing.expectEqual(@as(u16, 1), computed.footerRows());
}

test "the composer sits directly above the footer with no gap" {
    const computed = try layout.compute(80, 24, 1, 1);
    // A gap between the input and the status line is a visible defect, so the
    // rows must be contiguous.
    try testing.expectEqual(computed.footer_top - 1, computed.composer_bottom);
    try testing.expectEqual(computed.composer_bottom - 1, computed.transcript_bottom);
}

test "a multiline composer grows upward and takes rows from the transcript" {
    const single = try layout.compute(80, 24, 1, 1);
    const triple = try layout.compute(80, 24, 3, 1);

    try testing.expectEqual(@as(u16, 3), triple.composerRows());
    try testing.expectEqual(@as(u16, 1), single.composerRows());

    // The composer grows toward the transcript, and the footer does not move.
    try testing.expect(triple.composer_top < single.composer_top);
    try testing.expectEqual(single.footer_top, triple.footer_top);
    try testing.expectEqual(single.footer_bottom, triple.footer_bottom);

    // The transcript absorbed exactly the difference.
    try testing.expectEqual(
        single.transcriptRows() - 2,
        triple.transcriptRows(),
    );
    try testing.expect(layout.bandsAreDisjoint(triple));
}

test "scrolling never moves the composer or the footer" {
    // The pinned-chrome property, checked across sizes and every scroll amount
    // in a plausible range. A scroll-only frame must leave both rows exactly
    // where they were.
    const sizes = [_][2]u16{
        .{ 80, 24 },
        .{ 120, 40 },
        .{ 20, 8 },
        .{ 60, 12 },
    };
    const scrolls = [_]i32{ -50, -24, -10, -3, -1, 0, 1, 3, 10, 24, 50 };

    for (sizes) |size| {
        const cols = size[0];
        const rows = size[1];
        const base = try layout.compute(cols, rows, 2, 1);
        for (scrolls) |amount| {
            const scrolled = layout.scrollTranscript(base, amount);
            try testing.expect(layout.chromePinned(base, scrolled));
        }
    }
}

test "scrolling clamps instead of running off either end" {
    const base = try layout.compute(80, 24, 1, 1);

    // A huge scroll in either direction must stay inside the frame.
    for ([_]i32{ -1000, -24, -1, 0, 1, 24, 1000 }) |amount| {
        const scrolled = layout.scrollTranscript(base, amount);
        try testing.expect(scrolled.transcript_top >= 1);
        try testing.expect(scrolled.transcript_bottom <= base.rows);
        try testing.expect(layout.bandsAreDisjoint(scrolled));
        try testing.expect(layout.chromePinned(base, scrolled));
    }
}

test "the transcript cannot scroll into the composer" {
    const base = try layout.compute(80, 24, 1, 1);
    // Extreme negative offset pins the transcript to the top of the frame,
    // which must not push it into the composer rows.
    const scrolled = layout.scrollTranscript(base, -10_000);
    try testing.expectEqual(@as(u16, 1), scrolled.transcript_top);
    try testing.expect(scrolled.transcript_bottom < scrolled.composer_top);
}

test "a terminal too small for the chrome refuses instead of mangling the frame" {
    // The plan calls this out explicitly: a refusal is acceptable, a mangled
    // frame is not.
    try testing.expectError(error.TerminalTooSmall, layout.compute(80, 5, 1, 1));
    try testing.expectError(error.TerminalTooSmall, layout.compute(80, 3, 1, 1));
    // A composer plus footer that cannot leave room for the transcript. At six
    // rows a four-row composer leaves exactly one transcript row, which is
    // still a usable frame, so the boundary is checked at five.
    try testing.expectError(error.TerminalTooSmall, layout.compute(80, 6, 5, 1));
    // Too narrow to render a usable frame.
    try testing.expectError(error.TerminalTooSmall, layout.compute(10, 24, 1, 1));
}

test "the smallest accepted terminal still produces a usable frame" {
    const computed = try layout.compute(layout.minimum_cols, layout.minimum_rows, 1, 1);
    try testing.expect(layout.bandsAreDisjoint(computed));
    try testing.expect(computed.transcriptRows() >= 1);
}

test "the composer never grows past the top of the frame" {
    // A tall composer on a short terminal is the case most likely to underflow
    // into row 0, which is where arithmetic bugs show up as a corrupt frame.
    for ([_]u16{ 1, 2, 3, 4, 5, 6, 8, 12 }) |composer_height| {
        if (composer_height + 2 > layout.minimum_rows) continue;
        const computed = layout.compute(80, layout.minimum_rows, composer_height, 1) catch continue;
        try testing.expect(computed.composer_top >= 2);
        try testing.expect(computed.transcript_top >= 1);
        try testing.expect(layout.bandsAreDisjoint(computed));
    }
}

test "band rows sum to the frame height" {
    // Every row is owned. Unpainted rows show as gaps in a real terminal.
    for ([_]u16{ 6, 10, 24, 40, 60 }) |rows| {
        const computed = try layout.compute(80, rows, 2, 1);
        const total = computed.transcriptRows() + computed.composerRows() + computed.footerRows();
        try testing.expectEqual(rows, total);
    }
}
