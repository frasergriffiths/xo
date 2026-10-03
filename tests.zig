//! Entry point for the core test suite that lives in `tests/`.
//!
//! This file sits at the repository root on purpose. Zig scopes `@import` to
//! the module's root directory, so a test file inside `tests/` cannot reach
//! `src/` unless both directories belong to the same module. Anchoring the
//! module here is what lets `tests/*.zig` exercise the real modules.
//!
//! Each suite file links the same source the binary links, so a green run is
//! evidence about shipped behaviour rather than about a copy of it.

const std = @import("std");

pub const command_surface = @import("tests/command_surface.zig");
pub const compactor_aliases = @import("tests/compactor_aliases.zig");
pub const context_compaction = @import("tests/context_compaction.zig");
pub const credential_coherence = @import("tests/credential_coherence.zig");
pub const credential_resolution = @import("tests/credential_resolution.zig");
pub const json_encoding = @import("tests/json_encoding.zig");
pub const permission_mode = @import("tests/permission_mode.zig");
pub const provider_identity = @import("tests/provider_identity.zig");
pub const summary_model_selection = @import("tests/summary_model_selection.zig");
pub const table_rendering = @import("tests/table_rendering.zig");
pub const text_measurement = @import("tests/text_measurement.zig");

test {
    std.testing.refAllDecls(@This());
}
