//! Permission mode contract.
//!
//! fx has one permission mode. This pins the accepted spelling and confirms
//! every retired label is rejected rather than silently aliased.

const std = @import("std");
const testing = std.testing;

const config_runtime = @import("../src/core/config/config_runtime.zig");
const types = @import("../src/core/shared/types.zig");

test "yolo is the only accepted permission mode spelling" {
    for ([_][]const u8{ "yolo", "YOLO", "YoLo" }) |raw| {
        try testing.expectEqual(types.PermissionMode.yolo, config_runtime.parsePermissionMode(raw).?);
    }
}

test "retired permission mode labels are not aliases" {
    // These all used to resolve to full access. They must not come back.
    for ([_][]const u8{
        "full-access", "full_access", "full access", "fullaccess",
        "ask",         "auto",        "none",        "default",
        "",            " yolo",       "yolo ",       "full-access ",
    }) |raw| {
        try testing.expectEqual(
            @as(?types.PermissionMode, null),
            config_runtime.parsePermissionMode(raw),
        );
    }
}

test "permission actions are unaffected by the permission mode change" {
    try testing.expectEqual(types.PermissionAction.allow, config_runtime.parsePermissionAction("allow").?);
    try testing.expectEqual(types.PermissionAction.ask, config_runtime.parsePermissionAction("ask").?);
    try testing.expectEqual(types.PermissionAction.deny, config_runtime.parsePermissionAction("deny").?);
    try testing.expectEqual(@as(?types.PermissionAction, null), config_runtime.parsePermissionAction("maybe"));
}

test "full access is the compiled default mode" {
    try testing.expectEqual(types.PermissionMode.yolo, config_runtime.default_permission_mode);
}

test "the default is the only mode the type can hold" {
    // A single-variant enum is the compile-time guarantee that no caller can
    // reintroduce a restricted mode.
    try testing.expectEqual(@as(usize, 1), @typeInfo(types.PermissionMode).@"enum".fields.len);
    try testing.expectEqualStrings("full access", permissions_display_label());
}

fn permissions_display_label() []const u8 {
    const permissions = @import("../src/core/permissions/permissions.zig");
    return permissions.permissionModeDisplayLabel(.yolo);
}

test "the persisted label and the display label differ on purpose" {
    const permissions = @import("../src/core/permissions/permissions.zig");
    // The wire/persisted spelling is what round-trips through settings.json.
    try testing.expectEqualStrings("yolo", permissions.permissionModeLabel(.yolo));
    // The display spelling is the human phrase.
    try testing.expectEqualStrings("full access", permissions.permissionModeDisplayLabel(.yolo));
}
