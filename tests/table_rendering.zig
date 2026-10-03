//! Transcript table rendering.
//!
//! Tables are rendered into a fixed-width terminal, so the invariants that
//! matter are structural: the grid is closed and balanced, degenerate input
//! does not produce a blank band, and nothing overflows the terminal width.
//!
//! Line counts follow from the border rules. A table with N rows and a real
//! header draws `2N + 1` lines; when the header carries no text it draws one
//! rule fewer, so `2N`.

const std = @import("std");
const testing = std.testing;

const transcript_blocks = @import("../src/ui/render_engine/transcript_blocks.zig");
const assistant_presentation = @import("../src/core/agent/assistant_presentation.zig");
const display_width = @import("../src/core/shared/display_width.zig");

fn render(rows: []const []const []const u8, cols: u16) ![]u8 {
    var table = assistant_presentation.TablePayload{
        .rows = try testing.allocator.alloc(assistant_presentation.TableRow, rows.len),
        .alignments = try testing.allocator.alloc(assistant_presentation.TableColumnAlign, rows.len),
        .column_count = if (rows.len == 0) 0 else rows[0].len,
    };
    errdefer testing.allocator.free(table.rows);
    errdefer testing.allocator.free(table.alignments);

    for (rows, 0..) |row, i| {
        var cells = try testing.allocator.alloc([]u8, row.len);
        errdefer testing.allocator.free(cells);
        for (row, 0..) |cell, c| cells[c] = try testing.allocator.dupe(u8, cell);
        table.rows[i] = .{ .cells = cells };
        table.alignments[i] = .left;
    }

    const rendered = transcript_blocks.renderTableForTranscript(testing.allocator, table, cols);
    table.deinit(testing.allocator);
    return rendered;
}

/// Counts occurrences of one codepoint. Box-drawing characters are multi-byte,
/// so counting bytes would be wrong.
fn countCodepoint(haystack: []const u8, needle: []const u8) usize {
    var total: usize = 0;
    var i: usize = 0;
    while (i < haystack.len) {
        const len = std.unicode.utf8ByteSequenceLength(haystack[i]) catch 1;
        if (i + len <= haystack.len and std.mem.eql(u8, haystack[i .. i + len], needle)) total += 1;
        i += len;
    }
    return total;
}

fn expectWidthsWithin(out: []const u8, cols: u16) !void {
    var lines = std.mem.splitScalar(u8, out, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        try testing.expect(display_width.visibleWidthIgnoringAnsi(line) <= cols);
    }
}

test "a table with a real header renders as a closed grid" {
    const out = try render(
        &.{
            &.{ "Name", "Role" },
            &.{ "Language", "Zig" },
            &.{ "License", "Apache-2.0" },
        },
        80,
    );
    defer testing.allocator.free(out);

    try testing.expectEqual(countCodepoint(out, "\n"), 7); // 2N + 1 with N = 3
    try testing.expectEqual(countCodepoint(out, "┌"), 1);
    try testing.expectEqual(countCodepoint(out, "└"), 1);
    try testing.expectEqual(countCodepoint(out, "┬"), countCodepoint(out, "┴"));
    try testing.expectEqual(countCodepoint(out, "┼"), countCodepoint(out, "┤"));
    try testing.expectEqual(countCodepoint(out, "├"), 2); // header rule plus one interior
}

test "an empty header row draws no blank band" {
    // The reported case: a markdown table with an empty header produced an
    // empty emphasized row plus a rule under it, which read as a stray box.
    const out = try render(
        &.{
            &.{ "", "" },
            &.{ "What", "A native terminal coding agent" },
            &.{ "License", "Apache-2.0" },
        },
        80,
    );
    defer testing.allocator.free(out);

    try testing.expectEqual(countCodepoint(out, "\n"), 6); // 2N, one rule fewer
    try testing.expectEqual(countCodepoint(out, "├"), 1); // only the License separator
    try testing.expectEqual(countCodepoint(out, "┌"), 1);
}

test "a two-row table drops exactly the header rule" {
    {
        const with_header = try render(
            &.{ &.{ "Name", "Role" }, &.{ "Language", "Zig" } },
            80,
        );
        defer testing.allocator.free(with_header);
        try testing.expectEqual(countCodepoint(with_header, "\n"), 5);
        try testing.expectEqual(countCodepoint(with_header, "├"), 1);
    }
    {
        const without_header = try render(
            &.{ &.{ "", "" }, &.{ "Language", "Zig" } },
            80,
        );
        defer testing.allocator.free(without_header);
        try testing.expectEqual(countCodepoint(without_header, "\n"), 4);
        try testing.expectEqual(countCodepoint(without_header, "├"), 0);
    }
}

test "a header of only whitespace counts as empty" {
    const out = try render(
        &.{ &.{ "  ", " " }, &.{ "a", "b" } },
        80,
    );
    defer testing.allocator.free(out);

    try testing.expectEqual(countCodepoint(out, "\n"), 4);
    try testing.expectEqual(countCodepoint(out, "├"), 0);
}

test "a header with text in only one cell still counts as a header" {
    const out = try render(
        &.{ &.{ "", "Role" }, &.{ "Language", "Zig" } },
        80,
    );
    defer testing.allocator.free(out);

    try testing.expectEqual(countCodepoint(out, "├"), 1);
}

test "cell content survives rendering" {
    const out = try render(
        &.{
            &.{ "Name", "Role" },
            &.{ "Language", "Zig" },
            &.{ "License", "Apache-2.0" },
        },
        80,
    );
    defer testing.allocator.free(out);

    for ([_][]const u8{ "Name", "Role", "Language", "Zig", "License", "Apache-2.0" }) |needle| {
        if (std.mem.indexOf(u8, out, needle) == null) {
            std.debug.print("rendered table is missing '{s}'\n", .{needle});
            return error.TestMissingCellText;
        }
    }
}

test "a long value wraps without exceeding the terminal width" {
    const cols: u16 = 60;
    const out = try render(
        &.{
            &.{ "Key", "Value" },
            &.{ "Description", "A deliberately long value that has to wrap across several lines" },
        },
        cols,
    );
    defer testing.allocator.free(out);

    try expectWidthsWithin(out, cols);
    // The wrapped text is still present, just split across lines.
    try testing.expect(std.mem.indexOf(u8, out, "deliberately") != null);
}

test "a very narrow terminal degrades instead of overflowing" {
    for ([_]u16{ 4, 8, 12, 20 }) |cols| {
        const out = try render(
            &.{
                &.{ "k", "v" },
                &.{ "long-key-name", "long-value-name" },
            },
            cols,
        );
        defer testing.allocator.free(out);
        try expectWidthsWithin(out, cols);
    }
}

test "wide characters do not push a row past the terminal width" {
    const cols: u16 = 40;
    const out = try render(
        &.{
            &.{ "Name", "Value" },
            &.{ "language", "\u{4f60}\u{597d}\u{4e16}\u{754c}" },
        },
        cols,
    );
    defer testing.allocator.free(out);

    try expectWidthsWithin(out, cols);
}

test "every rendered line in a boxed grid starts and ends on a border column" {
    const out = try render(
        &.{
            &.{ "Name", "Role" },
            &.{ "Language", "Zig" },
        },
        80,
    );
    defer testing.allocator.free(out);

    var lines = std.mem.splitScalar(u8, out, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        // Each line is a full row: border, cells, border.
        if (line[0] != '│' and !isBorderGlyph(line[0..])) continue;
        const last = line[display_width.previousRuneStart(line, line.len)];
        if (last != '│' and !isBorderGlyph(line[line.len - 3 ..])) {
            std.debug.print("row does not close on a border: {s}\n", .{line});
            return error.TestUnclosedRow;
        }
    }
}

fn isBorderGlyph(slice: []const u8) bool {
    return std.mem.indexOf(u8, "┌┬┐├┼┤└┴┘│─", slice) != null;
}
