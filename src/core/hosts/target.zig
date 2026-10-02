const builtin = @import("builtin");
const std = @import("std");

/// The WebAssembly surfaces are removed. Every host-gated branch that this
/// flag used to select is now unreachable, so it is a compile-time false
/// rather than a target check.
pub const is_wasm = false;

comptime {
    std.debug.assert(builtin.os.tag != .wasi);
}
