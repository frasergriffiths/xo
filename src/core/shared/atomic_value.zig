const std = @import("std");

/// fx builds only for native targets, which all support real atomics. This
/// alias exists so callers can name the atomic type through one module.
pub fn Value(comptime T: type) type {
    return std.atomic.Value(T);
}
