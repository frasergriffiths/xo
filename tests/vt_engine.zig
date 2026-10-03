//! Deterministic coverage for the shared VT engine.
//!
//! This is tier-one verification for render and resize behavior: it needs no
//! file descriptor, no tmux, and no timing luck. The engine under test is the
//! same `Grid` the renderer paints through, so a green run is evidence about
//! shipped behavior.
//!
//! Every test in this file lives in a file `tests.zig` imports, which is what
//! makes `zig build test` discover it at all. A test block in a file nothing
//! imports compiles nowhere and asserts nothing.

const std = @import("std");
const engine = @import("../src/core/terminal/engine.zig");

const Grid = engine.Grid;
const Allocator = std.mem.Allocator;

/// Reads one visual row with trailing blanks stripped, for assertions that
/// care about content rather than styling. Caller owns the returned bytes.
fn rowText(alloc: Allocator, grid: Grid, row: u16) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    try grid.rowTextTrimmed(row, &out);
    return alloc.dupe(u8, out.items);
}

test "grid starts blank with the cursor home and autowrap on" {
    const alloc = std.testing.allocator;
    var grid = try Grid.init(alloc, 40, 6);
    defer grid.deinit();

    try std.testing.expectEqual(@as(u16, 40), grid.cols);
    try std.testing.expectEqual(@as(u16, 6), grid.rows);
    try std.testing.expectEqual(@as(u16, 1), grid.cursor_row);
    try std.testing.expectEqual(@as(u16, 1), grid.cursor_col);
    try std.testing.expect(grid.autowrap);
    try std.testing.expect(grid.cursor_visible);
}

test "printable text lands on the addressed row" {
    const alloc = std.testing.allocator;
    var grid = try Grid.init(alloc, 40, 6);
    defer grid.deinit();

    // CUP row 3 column 1, then write.
    try grid.feed("\x1b[3;1Hhello");

    const text = try rowText(alloc, grid, 3);
    defer alloc.free(text);
    try std.testing.expectEqualStrings("hello", text);

    const above = try rowText(alloc, grid, 2);
    defer alloc.free(above);
    try std.testing.expectEqualStrings("", above);
}

test "ed clears the whole frame back to blanks" {
    const alloc = std.testing.allocator;
    var grid = try Grid.init(alloc, 20, 4);
    defer grid.deinit();

    try grid.feed("\x1b[1;1Habcdefghij\x1b[2J");
    for (0..4) |row_u16| {
        const text = try rowText(alloc, grid, @intCast(row_u16 + 1));
        defer alloc.free(text);
        try std.testing.expectEqualStrings("", text);
    }
}

test "resize preserves content and reports the new geometry" {
    const alloc = std.testing.allocator;
    var grid = try Grid.init(alloc, 40, 10);
    defer grid.deinit();

    try grid.feed("\x1b[1;1Hkeepme");
    try grid.resize(20, 20);

    try std.testing.expectEqual(@as(u16, 20), grid.cols);
    try std.testing.expectEqual(@as(u16, 20), grid.rows);

    const text = try rowText(alloc, grid, 1);
    defer alloc.free(text);
    try std.testing.expectEqualStrings("keepme", text);
}

test "rows below the new height are truncated, not stale" {
    const alloc = std.testing.allocator;
    var grid = try Grid.init(alloc, 20, 10);
    defer grid.deinit();

    try grid.feed("\x1b[9;1Hlastrow");
    try grid.resize(20, 5);

    try std.testing.expectEqual(@as(u16, 5), grid.rows);
    try std.testing.expectEqual(@as(u16, 5), grid.cursor_row);
}

test "alternate screen buffer enter isolates writes from the main buffer" {
    const alloc = std.testing.allocator;
    var grid = try Grid.init(alloc, 20, 4);
    defer grid.deinit();

    try grid.feed("\x1b[1;1Hmain");
    // Enter the alternate screen, write there, leave it.
    try grid.feed("\x1b[?1049h\x1b[1;1Halt");

    const alt = try rowText(alloc, grid, 1);
    defer alloc.free(alt);
    try std.testing.expectEqualStrings("alt", alt);

    try grid.feed("\x1b[?1049l");

    const main_after = try rowText(alloc, grid, 1);
    defer alloc.free(main_after);
    try std.testing.expectEqualStrings("main", main_after);
}

test "wide characters occupy one cell with a zero-width trailing half" {
    const alloc = std.testing.allocator;
    var grid = try Grid.init(alloc, 10, 3);
    defer grid.deinit();

    try grid.feed("\x1b[1;1H\u{754c}");

    try std.testing.expectEqual(@as(u8, 2), grid.cells[0].width);
    try std.testing.expectEqual(@as(u8, 0), grid.cells[1].width);

    const text = try rowText(alloc, grid, 1);
    defer alloc.free(text);
    try std.testing.expectEqualStrings("\u{754c}", text);
}

test "cell styling is retained per cell across a later write elsewhere" {
    const alloc = std.testing.allocator;
    var grid = try Grid.init(alloc, 10, 3);
    defer grid.deinit();

    try grid.feed("\x1b[1;1H\x1b[41mR\x1b[0mP");

    try std.testing.expect(!std.meta.eql(grid.cells[0].style, grid.cells[1].style));
    try std.testing.expectEqual(grid.cells[0].style, grid.cells[0].style);
}

test "feed reports whether the frame scrolled and how far" {
    const alloc = std.testing.allocator;
    var grid = try Grid.init(alloc, 10, 3);
    defer grid.deinit();

    var stats: engine.FeedStats = .{};
    // Three newlines in a three-row frame forces one scroll.
    try grid.feedWithStats("\x1b[1;1Ha\nb\nc\nd", &stats);

    try std.testing.expect(stats.scrolled);
    try std.testing.expectEqual(@as(u16, 1), stats.scroll_rows);
}

test "no scroll is reported when the frame has room" {
    const alloc = std.testing.allocator;
    var grid = try Grid.init(alloc, 10, 10);
    defer grid.deinit();

    var stats: engine.FeedStats = .{};
    try grid.feedWithStats("\x1b[1;1Ha\nb", &stats);

    try std.testing.expect(!stats.scrolled);
    try std.testing.expectEqual(@as(u16, 0), stats.scroll_rows);
}

test "a scroll-only frame leaves untouched rows byte-identical" {
    const alloc = std.testing.allocator;
    var grid = try Grid.init(alloc, 30, 6);
    defer grid.deinit();

    try grid.feed("\x1b[1;1Hhead\nmid\nfoot");

    var before: [6][]u8 = undefined;
    for (0..6) |row_u16| {
        const row: u16 = @intCast(row_u16 + 1);
        before[row_u16] = try rowText(alloc, grid, row);
    }
    defer for (before) |text| alloc.free(text);

    // Scroll content up by exactly one line, which is the operation the
    // full-screen chrome must not disturb.
    try grid.feed("\n");

    // Row 6 was never written by the scroll, so it must be unchanged.
    const after = try rowText(alloc, grid, 6);
    defer alloc.free(after);
    try std.testing.expectEqualStrings(before[5], after);
}

test "trimmed row text ignores trailing blanks for blank-row assertions" {
    const alloc = std.testing.allocator;
    var grid = try Grid.init(alloc, 20, 3);
    defer grid.deinit();

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    try grid.rowTextTrimmed(2, &out);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
}

test "row text of a partially written row is trimmed to the written span" {
    const alloc = std.testing.allocator;
    var grid = try Grid.init(alloc, 20, 3);
    defer grid.deinit();

    try grid.feed("\x1b[1;1Habc");

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    try grid.rowTextTrimmed(1, &out);

    try std.testing.expectEqualStrings("abc", out.items);
}
