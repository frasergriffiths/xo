//! Test-only aliases for the OpenRouter provider surface.
//!
//! Several suites need a concrete stream provider, model catalog, permission
//! reviewer, and search provider to exercise dispatch without a network. This
//! module re-exports the real OpenRouter wiring under the names those suites
//! expect, so tests and production cannot drift apart.
const std = @import("std");
const auto_classifier = @import("../core/permissions/auto_classifier.zig");
const model_catalog = @import("../core/gateway/model_catalog.zig");
const model_provider = @import("../core/config/model_provider.zig");
const openrouter = @import("openrouter.zig");
const streams = @import("../core/agent/stream_provider.zig");

const identity: model_provider.ProviderId = .openrouter;

fn stubReview(
    _: ?*anyopaque,
    _: std.mem.Allocator,
    _: auto_classifier.ProviderInput,
    _: auto_classifier.ReviewRequest,
) anyerror!auto_classifier.ParseOutcome {
    return .{ .invalid = .provider_failed };
}

pub const agent_stream = openrouter.provider_bundle.agent_stream.?;
pub const model_catalog_provider = openrouter.provider_bundle.model_catalog.?;
pub const cli_model_catalog_provider = openrouter.provider_bundle.cli_model_catalog.?;
pub const provider_bundle = openrouter.provider_bundle;
pub const default_web_search_provider = openrouter.provider_bundle.fx_search.?;
pub const permission_reviewer = openrouter.provider_bundle.permission_reviewer orelse auto_classifier.Provider{ .review_fn = stubReview };
pub const provider = agent_stream;

/// The chat URL as a resolver, for suites that assert endpoint identity.
pub const chat_url_provider = struct {
    const Self = @This();
    pub const resolve_fn: *const fn () []const u8 = resolve;
    fn resolve() []const u8 {
        return openrouter.chat_url;
    }
};

/// Serializes an agent request exactly as the OpenRouter transport does.
pub fn buildRequest(alloc: std.mem.Allocator, request: streams.RequestData) ![]u8 {
    return @import("chat_completions_protocol.zig").build_request(alloc, request, .{
        .tool_choice_mode = openrouter.definition.tool_choice_mode,
        .provider = &identity,
        .upstream_routing = .{
            .order = request.provider_options.provider_order,
            .allow_fallback = !request.provider_options.provider_strict,
        },
    });
}
