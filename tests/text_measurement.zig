//! Terminal text measurement.
//!
//! fx lays out every line through this module, so wrapping and alignment depend
//! on display cells rather than bytes or codepoints. These cases pin the
//! behavior that keeps the grid aligned: wide characters cost two cells,
//! combining marks cost none, and escape sequences are not measured when the
//! caller asks for the rendered width.
//!
//! Note that `visibleWidth` is deliberately not ANSI-aware and is one greater
//! than the cell count for plain ASCII; it measures the columns a string
//! occupies. Use `visibleWidthIgnoringAnsi` for already-styled text.

const std = @import("std");
const testing = std.testing;

const display_width = @import("../src/core/shared/display_width.zig");

test "plain ascii has a predictable measured width" {
    try testing.expectEqual(@as(usize, 1), display_width.visibleWidth("a"));
    try testing.expectEqual(@as(usize, 6), display_width.visibleWidth("banana"));
    try testing.expectEqual(display_width.visibleWidth("banana"), display_width.visibleWidthIgnoringAnsi("banana"));
}

test "cjk characters occupy two cells" {
    try testing.expectEqual(@as(usize, 2), display_width.visibleWidth("\u{4f60}"));
    try testing.expectEqual(@as(usize, 4), display_width.visibleWidth("\u{4f60}\u{597d}"));
    // Mixed content sums cells, not bytes.
    try testing.expectEqual(@as(usize, 4), display_width.visibleWidth("a\u{4f60}b"));
}

test "combining marks add no width" {
    // "e" plus a combining acute stays one cell.
    try testing.expectEqual(@as(usize, 1), display_width.visibleWidth("e\u{0301}"));
}

test "ansi escapes are invisible to the ansi-aware measurement" {
    const styled = "\x1b[31mabc\x1b[0m";
    // The plain measurement counts the escape bytes, so it is strictly larger.
    try testing.expect(display_width.visibleWidth(styled) > display_width.visibleWidthIgnoringAnsi(styled));
    try testing.expectEqual(display_width.visibleWidth("abc"), display_width.visibleWidthIgnoringAnsi(styled));
}

test "an osc hyperlink contributes no visible cells" {
    const linked = "\x1b]8;;https://example\x07ok\x1b]8;;\x07";
    try testing.expectEqual(display_width.visibleWidth("ok"), display_width.visibleWidthIgnoringAnsi(linked));
}

test "prefixByWidth never splits a wide character" {
    const text = "\u{4f60}\u{597d}\u{4e16}";
    try testing.expectEqualStrings("", display_width.prefixByWidth(text, 0));
    // A two-cell character does not fit a one-cell budget, so nothing is taken
    // rather than returning half of a character.
    try testing.expectEqualStrings("", display_width.prefixByWidth(text, 1));
    try testing.expectEqualStrings("\u{4f60}", display_width.prefixByWidth(text, 2));
    try testing.expectEqualStrings("\u{4f60}\u{597d}", display_width.prefixByWidth(text, 4));
    try testing.expectEqualStrings(text, display_width.prefixByWidth(text, 6));
}

test "prefixByWidth can cut inside an ascii run" {
    try testing.expectEqualStrings("abc", display_width.prefixByWidth("abcdef", 3));
    try testing.expectEqualStrings("", display_width.prefixByWidth("abcdef", 0));
    try testing.expectEqualStrings("abcdef", display_width.prefixByWidth("abcdef", 99));
}

test "suffixByWidth returns the trailing cells" {
    try testing.expectEqualStrings("def", display_width.suffixByWidth("abcdef", 3));
}

test "widestFitting returns the first variant that fits" {
    // The function is first-fit, not best-fit: order in the slice is the
    // preference order and the first entry that fits wins.
    const ordered = [_][]const u8{ "ab", "abcd", "a" };
    try testing.expectEqualStrings("ab", display_width.widestFitting(&ordered, 2));
    try testing.expectEqualStrings("ab", display_width.widestFitting(&ordered, 3));

    const none_fit = [_][]const u8{ "abcd", "efgh" };
    try testing.expectEqualStrings("efgh", display_width.widestFitting(&none_fit, 1));
}

test "shouldWrapAt is true only past the right margin" {
    // One-based columns: a run fits while col + w - 1 stays within cols.
    try testing.expect(!display_width.shouldWrapAt(1, 1, 10));
    try testing.expect(!display_width.shouldWrapAt(10, 1, 10));
    try testing.expect(display_width.shouldWrapAt(11, 1, 10));
    // A two-cell character starting in the last column does not fit.
    try testing.expect(display_width.shouldWrapAt(10, 2, 10));
    // It does fit one column earlier.
    try testing.expect(!display_width.shouldWrapAt(9, 2, 10));
}

test "nextTabStopColumn advances to the next eight-column stop" {
    // Columns are one-based, and callers must pass non-zero columns.
    try testing.expectEqual(@as(u16, 9), display_width.nextTabStopColumn(1, 80));
    try testing.expectEqual(@as(u16, 9), display_width.nextTabStopColumn(8, 80));
    try testing.expectEqual(@as(u16, 17), display_width.nextTabStopColumn(9, 80));
    // Already at or past the margin clamps to the margin.
    try testing.expectEqual(@as(u16, 80), display_width.nextTabStopColumn(80, 80));
    try testing.expectEqual(@as(u16, 20), display_width.nextTabStopColumn(19, 20));
}

test "displayUnitAt reports one codepoint's bytes and cells" {
    {
        const unit = display_width.displayUnitAt("a\u{4f60}z", 0);
        try testing.expectEqual(@as(usize, 1), unit.byte_len);
        try testing.expectEqual(@as(usize, 1), unit.cell_width);
    }
    {
        const unit = display_width.displayUnitAt("\u{4f60}x", 0);
        try testing.expectEqual(@as(usize, 3), unit.byte_len);
        try testing.expectEqual(@as(usize, 2), unit.cell_width);
    }
}

test "previousRuneStart walks back over a whole codepoint" {
    const text = "a\u{4f60}";
    try testing.expectEqual(@as(usize, 1), display_width.previousRuneStart(text, text.len));
    try testing.expectEqual(@as(usize, 0), display_width.previousRuneStart(text, 1));
}

test "the ansi sequence scanner finds the end of an escape" {
    const text = "\x1b[31mrest";
    try testing.expectEqual(@as(usize, 5), display_width.ansiSequenceEnd(text, 0));
}

test "trimBreakWhitespace drops leading indent whitespace" {
    try testing.expectEqualStrings("abc", display_width.trimBreakWhitespace("  abc"));
    try testing.expectEqualStrings("abc", display_width.trimBreakWhitespace("\tabc"));
    try testing.expectEqualStrings("", display_width.trimBreakWhitespace("   "));
    // Text with no leading whitespace is returned untouched.
    try testing.expectEqualStrings("abc ", display_width.trimBreakWhitespace("abc "));
}
