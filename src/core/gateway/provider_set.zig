const std = @import("std");
const stream_provider = @import("../agent/stream_provider.zig");
const model_provider = @import("../config/model_provider.zig");
const model_capabilities = @import("../config/model_capabilities.zig");
const provider_catalog = @import("../auth/provider_catalog.zig");
const generation_usage_provider = @import("../session/generation_usage_provider.zig");
const gateway_provider = @import("gateway_provider.zig");
const web_search_provider = @import("../tooling/web_search_provider.zig");
const auto_classifier = @import("../permissions/auto_classifier.zig");
const model_catalog = @import("model_catalog.zig");

const Allocator = std.mem.Allocator;

pub const Bundle = struct {
    pub const AuthStrategy = enum {
        api_key,
    };
    pub const Capabilities = struct {
        gateway_prompt_caching: bool = false,
        fx_search: bool = false,
        vision_fallback: bool = false,
    };

    capabilities: Capabilities = .{},
    presentation: ?*const provider_catalog.Entry = null,
    auth_strategy: ?AuthStrategy = null,
    /// Fixed low-cost model used for session title generation side calls.
    /// Null disables generated titles for the provider.
    title_model: ?[]const u8 = null,
    fallback_model_capabilities_fn: *const fn ([]const u8) model_capabilities.Capabilities = emptyModelCapabilities,
    agent_stream: ?stream_provider.Provider = null,
    cli_model_catalog: ?gateway_provider.CliModelCatalogProvider = null,
    model_catalog: ?model_catalog.Provider = null,
    /// Confirms a candidate API key against this provider's own endpoint, so a
    /// retargeted built-in validates against the address it will actually use.
    api_key_validator: ?@import("../auth/api_key_validator.zig").Provider = null,
    permission_reviewer: ?auto_classifier.Provider = null,
    deferred_usage: ?generation_usage_provider.Provider = null,
    fx_search: ?web_search_provider.Provider = null,

    pub fn agent_stream_or_unavailable(self: Bundle) stream_provider.Provider {
        return self.agent_stream orelse stream_provider.unavailable_provider;
    }

    pub fn fallbackModelCapabilities(self: Bundle, model: []const u8) model_capabilities.Capabilities {
        return self.fallback_model_capabilities_fn(model);
    }
};

fn emptyModelCapabilities(_: []const u8) model_capabilities.Capabilities {
    return .{};
}

pub const Set = struct {
    openrouter: Bundle,
    /// The compiled Groq route. Groq does not support a `providers.groq`
    /// retarget entry in the first cut, so its bundle is used as compiled.
    groq: Bundle = .{},
    /// The compiled route used when the OpenAI-compatible provider has no
    /// configured endpoint definition yet.
    openai_compatible: Bundle = .{},
    /// Runtime definition for the OpenAI-compatible provider, built from
    /// profile settings. Null means the user has not configured it.
    openai_compatible_definition: ?*const @import("../config/configured_provider.zig").Definition = null,
    /// Builds the OpenAI-compatible route against a configured definition.
    openai_compatible_fn: ?*const fn (*const @import("../config/configured_provider.zig").Definition) Bundle = null,
    definitions: []const @import("../config/configured_provider.zig").Definition = &.{},
    configured_fn: ?*const fn (*const @import("../config/configured_provider.zig").Definition) Bundle = null,
    /// Builds the built-in route against a user-supplied endpoint definition.
    /// Without it a `providers.openrouter` entry is ignored and the compiled
    /// default is used.
    builtin_override_fn: ?*const fn (*const @import("../config/configured_provider.zig").Definition) Bundle = null,

    pub fn select(self: Set, provider: model_provider.ProviderId) Bundle {
        return switch (provider) {
            .openrouter => self.openrouterBundle(),
            .groq => self.groq,
            .openai_compatible => blk: {
                const definition = self.openai_compatible_definition orelse break :blk self.openai_compatible;
                const factory = self.openai_compatible_fn orelse break :blk self.openai_compatible;
                break :blk factory(definition);
            },
            .configured => blk: {
                const factory = self.configured_fn orelse break :blk .{};
                const registry = @import("../config/configured_provider.zig").Registry{ .definitions = self.definitions };
                const bound = provider.bind(registry) catch break :blk .{};
                break :blk factory(registry.get(bound.label()).?);
            },
        };
    }

    /// A user `providers.openrouter` entry retargets the built-in endpoint
    /// without changing anything else about its route.
    fn openrouterBundle(self: Set) Bundle {
        const factory = self.builtin_override_fn orelse return self.openrouter;
        for (self.definitions) |*definition| {
            if (!definition.is_builtin_override) continue;
            return factory(definition);
        }
        return self.openrouter;
    }

    pub fn deferredUsageProviders(self: Set) generation_usage_provider.Set {
        return .{
            .openrouter = self.select(.openrouter).deferred_usage,
            .groq = self.select(.groq).deferred_usage,
            .openai_compatible = self.select(.openai_compatible).deferred_usage,
        };
    }
};

pub fn openrouter_only(openrouter: Bundle) Set {
    return .{ .openrouter = openrouter };
}
