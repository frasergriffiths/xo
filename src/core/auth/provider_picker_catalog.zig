//! Column contents for the `/provider` picker.
//!
//! List columns hold whitespace-free tokens that are also the labels shown to
//! the user, so what the picker writes into the composer is exactly what the
//! row displays. The one exception is the API key column, whose single row is
//! a masked entry field and never reaches the composer.

const std = @import("std");
const model_provider = @import("../config/model_provider.zig");
const provider_catalog = @import("provider_catalog.zig");
const types = @import("../shared/types.zig");
const openrouter_endpoint = @import("../../gateway/openrouter_endpoint.zig");
const groq_endpoint = @import("../../gateway/groq_endpoint.zig");
const openai_compatible = @import("../../gateway/openai_compatible.zig");

/// How a provider is authenticated. OpenRouter has a single method, so the
/// picker skips straight to the key list instead of showing single-option
/// provider and method columns.
pub const Method = enum {
    /// A pasted OpenRouter key held in the keychain or profile.
    api_key,
};

pub const max_provider_options = provider_catalog.entries.len;
const max_method_options = 1;
/// The team column lists at most this many teams; accounts beyond it see the
/// first 128 and can still change teams through the sign-in flow.
pub const max_team_options = 128;
pub const max_column_options = @max(max_team_options, @max(max_provider_options, max_method_options));

/// The API key column names the provider whose key is entered, then shows one
/// bullet per typed byte or a prompt while the field is empty. The row renderer
/// draws the `›` selection gutter, so the field itself carries no marker. It
/// matches the help and model menus: a two-space row with brightness selection,
/// not the composer's box marker.
const key_field_prompt_head = "Paste or type your ";
const key_field_prompt_tail = " key";
const key_field_typed_separator = " key ";
const key_field_bullet = "\u{2022}";
/// Longest provider label the field will print before clipping. Longer labels
/// still render, truncated, without overrunning the column buffer.
pub const max_provider_label_bytes: usize = 32;
pub const max_key_mask_glyphs: usize = 32;
pub const max_key_field_bytes = @max(
    key_field_prompt_head.len + max_provider_label_bytes + key_field_prompt_tail.len,
    max_provider_label_bytes + key_field_typed_separator.len + max_key_mask_glyphs * key_field_bullet.len,
);

fn clampProviderLabel(provider_label: []const u8) []const u8 {
    return provider_label[0..@min(provider_label.len, max_provider_label_bytes)];
}

/// Writes the provider-named prompt shown while the field is empty.
pub fn keyFieldPlaceholder(out: *[max_key_field_bytes]u8, provider_label: []const u8) []const u8 {
    const label = clampProviderLabel(provider_label);
    var end: usize = 0;
    @memcpy(out[end..][0..key_field_prompt_head.len], key_field_prompt_head);
    end += key_field_prompt_head.len;
    @memcpy(out[end..][0..label.len], label);
    end += label.len;
    @memcpy(out[end..][0..key_field_prompt_tail.len], key_field_prompt_tail);
    end += key_field_prompt_tail.len;
    return out[0..end];
}

/// Writes the field label: the provider-named prompt while empty, or the
/// provider name followed by one bullet per typed byte. The caller draws the
/// selection gutter, so no marker is written here.
pub fn writeKeyField(out: *[max_key_field_bytes]u8, mask_count: usize, provider_label: []const u8) []const u8 {
    if (mask_count == 0) return keyFieldPlaceholder(out, provider_label);
    const label = clampProviderLabel(provider_label);
    var end: usize = 0;
    @memcpy(out[end..][0..label.len], label);
    end += label.len;
    @memcpy(out[end..][0..key_field_typed_separator.len], key_field_typed_separator);
    end += key_field_typed_separator.len;
    for (0..@min(mask_count, max_key_mask_glyphs)) |_| {
        @memcpy(out[end..][0..key_field_bullet.len], key_field_bullet);
        end += key_field_bullet.len;
    }
    return out[0..end];
}

const base_url_field_prompt_head = "Enter the ";
const base_url_field_prompt_tail = " base URL";

/// Writes the base URL field: what has been typed, or a placeholder naming the
/// provider. URLs are not secret, so the value is rendered in the clear.
pub fn writeBaseUrlField(
    out: *[max_key_field_bytes]u8,
    typed: []const u8,
    provider_label: []const u8,
) []const u8 {
    if (typed.len == 0) {
        const label = clampProviderLabel(provider_label);
        var end: usize = 0;
        @memcpy(out[end..][0..base_url_field_prompt_head.len], base_url_field_prompt_head);
        end += base_url_field_prompt_head.len;
        @memcpy(out[end..][0..label.len], label);
        end += label.len;
        const tail_len = @min(base_url_field_prompt_tail.len, out.len - end);
        @memcpy(out[end..][0..tail_len], base_url_field_prompt_tail[0..tail_len]);
        end += tail_len;
        return out[0..end];
    }
    const len = @min(typed.len, out.len);
    @memcpy(out[0..len], typed[0..len]);
    return out[0..len];
}

/// The key-source column: detected keys to switch to, or `new` to paste one.
/// The distinction is who supplies the key, not where the secret sleeps: an
/// `env` key may well live in a password manager the user's shell reads.
pub const KeySource = enum {
    /// The provider's API key handed to fx through the environment.
    env,
    /// The key fx saved itself when one was pasted.
    saved,
    /// Paste a key fx does not have yet. Only offered while the provider has
    /// no saved key, so a provider never holds two saved keys at once.
    new,
    /// Delete the saved key so a different one can be pasted.
    remove,
};

pub fn keySourceSlug(source: KeySource) []const u8 {
    return switch (source) {
        .env => "env",
        .saved => "saved",
        .new => "new",
        .remove => "remove",
    };
}

/// The environment credential a provider reads when its key arrives through
/// the shell.
pub fn providerEnvCredential(provider: model_provider.ProviderId) types.CredentialSource {
    return switch (provider) {
        .openrouter => .openrouter_api_key,
        .groq => .groq_api_key,
        .openai_compatible => .openai_compatible_api_key,
        .configured => .configured,
    };
}

/// The saved-key credential a provider owns, or null when it has no slot.
pub fn providerStoredCredential(provider: model_provider.ProviderId) ?types.CredentialSource {
    return switch (provider) {
        .openrouter => .stored_key,
        .groq => .groq_stored_key,
        .openai_compatible => .openai_compatible_key,
        .configured => null,
    };
}

/// The environment variable name a provider's key is read from.
pub fn providerEnvVar(provider: model_provider.ProviderId) []const u8 {
    return switch (provider) {
        .openrouter => openrouter_endpoint.default_api_key_env,
        .groq => groq_endpoint.default_api_key_env,
        .openai_compatible => openai_compatible.default_api_key_env,
        .configured => "",
    };
}

/// Row annotation: where the key comes from, with `current` appended when it
/// is the active credential. Labels match the help menu's description column:
/// full origin plus state, not terse tokens.
pub fn keySourceAnnotation(source: KeySource, current: bool, provider: model_provider.ProviderId) []const u8 {
    return switch (source) {
        .env => envSourceAnnotation(provider, current),
        .saved => if (current) "saved by fx · current" else "saved by fx",
        .new => "paste a new key",
        .remove => "delete the saved key",
    };
}

/// The environment-variable annotation. Every arm is comptime-known, so the
/// `current` suffix is concatenated at compile time rather than folding a
/// runtime slice.
fn envSourceAnnotation(provider: model_provider.ProviderId, current: bool) []const u8 {
    return switch (provider) {
        .openrouter => if (current)
            openrouter_endpoint.default_api_key_env ++ " · current"
        else
            openrouter_endpoint.default_api_key_env,
        .groq => if (current)
            groq_endpoint.default_api_key_env ++ " · current"
        else
            groq_endpoint.default_api_key_env,
        .openai_compatible => if (current)
            openai_compatible.default_api_key_env ++ " · current"
        else
            openai_compatible.default_api_key_env,
        .configured => if (current) "configured credential · current" else "configured credential",
    };
}

pub fn parseKeySource(value: []const u8) ?KeySource {
    inline for (@typeInfo(KeySource).@"enum".fields) |field| {
        const source = @field(KeySource, field.name);
        if (std.ascii.eqlIgnoreCase(value, keySourceSlug(source))) return source;
    }
    return null;
}

pub fn keySourceCredential(source: KeySource, provider: model_provider.ProviderId) ?types.CredentialSource {
    return switch (source) {
        .env => providerEnvCredential(provider),
        .saved => providerStoredCredential(provider),
        .new, .remove => null,
    };
}

pub fn methodSlug(method: Method) []const u8 {
    return switch (method) {
        .api_key => "api-key",
    };
}

pub fn parseMethod(value: []const u8) ?Method {
    if (std.ascii.eqlIgnoreCase(value, methodSlug(.api_key))) return .api_key;
    return null;
}

/// Writes the visible provider slugs into `out` and returns how many landed.
pub fn providerOptions(out: *[max_provider_options][]const u8) usize {
    var count: usize = 0;
    for (&provider_catalog.entries) |*entry| {
        out[count] = entry.slug;
        count += 1;
    }
    return count;
}

pub fn providerMethods(id: model_provider.ProviderId) []const Method {
    return switch (id) {
        .openrouter, .groq, .openai_compatible => &.{.api_key},
        .configured => &.{},
    };
}

/// True when `source` is one of the ways `method` can be satisfied for this
/// provider. The API key method covers every key origin the provider owns, not
/// just the environment variable.
pub fn methodMatchesSource(
    method: Method,
    source: types.CredentialSource,
    provider: model_provider.ProviderId,
) bool {
    return switch (method) {
        .api_key => blk: {
            if (source == providerEnvCredential(provider)) break :blk true;
            const stored = providerStoredCredential(provider) orelse break :blk false;
            break :blk source == stored;
        },
    };
}
