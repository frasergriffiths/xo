const std = @import("std");
const model_provider = @import("../config/model_provider.zig");
const types = @import("../shared/types.zig");

pub const Entry = struct {
    id: model_provider.ProviderId,
    slug: []const u8,
    aliases: []const []const u8 = &.{},
    name: []const u8,
    route_name: []const u8,
    description: []const u8,
    subscription: bool,
    login_source: types.CredentialSource,
};

pub const entries = [_]Entry{
    .{
        .id = .openrouter,
        .slug = "openrouter",
        .name = "OpenRouter",
        .route_name = "OpenRouter",
        .description = "OpenRouter API key",
        .subscription = false,
        .login_source = .openrouter_api_key,
    },
    .{
        .id = .groq,
        .slug = "groq",
        .name = "Groq",
        .route_name = "Groq",
        .description = "Groq API key",
        .subscription = false,
        .login_source = .groq_api_key,
    },
    .{
        .id = .openai_compatible,
        .slug = "openai-compatible",
        .aliases = &.{ "openai-compatable", "openai_compatible", "compatible" },
        .name = "OpenAI-compatible",
        .route_name = "OpenAI-compatible",
        .description = "OpenAI-compatible API endpoint",
        .subscription = false,
        .login_source = .openai_compatible_api_key,
    },
};

pub fn parse(value: []const u8) ?model_provider.ProviderId {
    for (&entries) |*entry| {
        if (std.ascii.eqlIgnoreCase(value, entry.slug)) return entry.id;
        for (entry.aliases) |alias| if (std.ascii.eqlIgnoreCase(value, alias)) return entry.id;
    }
    return null;
}

const configured_entry = Entry{
    .id = model_provider.parse("configured").?,
    .slug = "configured",
    .name = "Configured provider",
    .route_name = "Configured provider",
    .description = "Endpoint and authentication from profile settings",
    .subscription = false,
    .login_source = .configured,
};

pub fn find(id: model_provider.ProviderId) *const Entry {
    if (id == .configured) return &configured_entry;
    for (&entries) |*entry| if (entry.id.eql(id)) return entry;
    unreachable;
}

pub fn label(id: model_provider.ProviderId) []const u8 {
    return find(id).route_name;
}
