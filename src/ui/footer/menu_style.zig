//! Shared visual vocabulary for slash-command menus.
const std = @import("std");
const ui_render = @import("../render.zig");
const row_text = @import("row_text.zig");
const display_width = @import("../../core/shared/display_width.zig");

pub const header_rows: u16 = 2;
pub const column_gap: usize = 4;

pub fn itemStyle(selected: bool) []const u8 {
    return if (selected) ui_render.selected_completion_style else ui_render.dim_style;
}

/// Returns the visible gutter width. The caller owns the row and its reset.
pub fn appendItemPrefix(alloc: std.mem.Allocator, row: *std.ArrayList(u8), selected: bool, width: u16) !usize {
    try row.appendSlice(alloc, itemStyle(selected));
    const gutter: usize = @min(@as(usize, width), 2);
    try row_text.appendClipped(alloc, row, if (selected) "› " else "  ", @intCast(gutter));
    return gutter;
}

pub fn appendTitle(alloc: std.mem.Allocator, row: *std.ArrayList(u8), title: []const u8, count: ?usize) !void {
    try row.appendSlice(alloc, ui_render.selected_completion_style);
    try row.appendSlice(alloc, title);
    if (count) |value| {
        var buf: [32]u8 = undefined;
        try row.appendSlice(alloc, try std.fmt.bufPrint(&buf, " {d}", .{value}));
    }
    try row.appendSlice(alloc, ui_render.reset_style);
}

pub fn appendTab(alloc: std.mem.Allocator, row: *std.ArrayList(u8), label: []const u8, active: bool) !void {
    try row.appendSlice(alloc, itemStyle(active));
    if (active) try row.append(alloc, '[');
    try row.appendSlice(alloc, label);
    if (active) try row.append(alloc, ']');
    try row.appendSlice(alloc, ui_render.reset_style);
}

pub fn composeHeader(alloc: std.mem.Allocator, title: []const u8, count: ?usize, context: ?[]const u8, width: u16) !std.ArrayList(u8) {
    var wide: std.ArrayList(u8) = .empty;
    defer wide.deinit(alloc);
    try appendTitle(alloc, &wide, title, count);
    if (context) |label| {
        try wide.appendSlice(alloc, "  ");
        try appendTab(alloc, &wide, label, true);
        if (display_width.visibleWidthIgnoringAnsi(wide.items) > width) {
            wide.clearRetainingCapacity();
            try appendTab(alloc, &wide, label, true);
        }
    }
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    try row_text.appendClipped(alloc, &row, wide.items, width);
    try row.appendSlice(alloc, ui_render.reset_style);
    return row;
}
