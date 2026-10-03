//! Credential resolution behaviour.
//!
//! Covers the precedence rules that decide which key a request actually uses,
//! including the rule that a remembered source may never be reused for a
//! provider it does not belong to.

const std = @import("std");
const testing = std.testing;

const credentials = @import("../src/core/auth/credentials.zig");
const model_provider = @import("../src/core/config/model_provider.zig");
const types = @import("../src/core/shared/types.zig");
const host = @import("../src/core/hosts/host.zig");

const Source = types.CredentialSource;

/// A secret store backed by an in-memory table, so resolution is observable
/// without touching the real keychain.
const FakeSecretStore = struct {
    entries: std.EnumArray(host.SecretSlot, ?[]const u8) =
        std.EnumArray(host.SecretSlot, ?[]const u8).initFill(null),

    fn isDisabled(_: ?*anyopaque) bool {
        return false;
    }

    fn presence(ctx: ?*anyopaque, slot: host.SecretSlot) host.SecretStorePresence {
        const self: *FakeSecretStore = @ptrCast(@alignCast(ctx.?));
        return if (self.entries.get(slot) != null) .present else .missing;
    }

    fn load(ctx: ?*anyopaque, alloc: std.mem.Allocator, slot: host.SecretSlot) host.SecretStoreLoadError!?[]u8 {
        const self: *FakeSecretStore = @ptrCast(@alignCast(ctx.?));
        const value = self.entries.get(slot) orelse return null;
        return try alloc.dupe(u8, value);
    }

    fn store(_: ?*anyopaque, _: std.mem.Allocator, _: host.SecretSlot, _: []const u8) host.SecretStoreWriteError!void {
        return error.StoredKeyWriteFailed;
    }

    fn storeInteractive(_: ?*anyopaque, _: host.SecretSlot) host.SecretStoreWriteError!bool {
        return false;
    }

    fn set(self: *FakeSecretStore, slot: host.SecretSlot, value: []const u8) void {
        self.entries.set(slot, value);
    }

    fn asSecretStore(self: *FakeSecretStore) host.SecretStore {
        return .{
            .context = self,
            .backend_label = "fake",
            .is_disabled_fn = isDisabled,
            .presence_fn = presence,
            .load_fn = load,
            .store_fn = store,
            .store_interactive_fn = storeInteractive,
        };
    }
};

test "a provider only accepts credentials from its own source slots" {
    try testing.expect(model_provider.authorizesCredential(.openrouter, .openrouter_api_key));
    try testing.expect(model_provider.authorizesCredential(.openrouter, .stored_key));

    // These are the cross-provider sources that must never be treated as valid
    // for OpenRouter. Treating them as valid is what made chat fail forever.
    try testing.expect(!model_provider.authorizesCredential(.openrouter, .openai_compatible_key));
    try testing.expect(!model_provider.authorizesCredential(.openrouter, .openai_compatible_api_key));
    try testing.expect(!model_provider.authorizesCredential(.openrouter, .groq_stored_key));
    try testing.expect(!model_provider.authorizesCredential(.openrouter, .groq_api_key));

    try testing.expect(model_provider.authorizesCredential(.groq, .groq_stored_key));
    try testing.expect(!model_provider.authorizesCredential(.groq, .stored_key));
    try testing.expect(model_provider.authorizesCredential(.openai_compatible, .openai_compatible_key));
    try testing.expect(!model_provider.authorizesCredential(.openai_compatible, .stored_key));

    // A missing credential authorizes nothing.
    try testing.expect(!model_provider.authorizesCredential(.openrouter, null));
}

test "an unauthorized remembered source is ignored, not adopted" {
    // Reproduces the reported failure: the profile selected OpenRouter while
    // the remembered preference still named the OpenAI-compatible key.
    // Resolution must fall through to OpenRouter's own store rather than
    // returning a key the OpenRouter route would reject.
    var store = FakeSecretStore{};
    store.set(.openrouter, "openrouter-secret");
    store.set(.openai_compatible, "compatible-secret");

    var resolution = try credentials.resolveForProvider(
        testing.allocator,
        store.asSecretStore(),
        .stored,
        .openrouter,
        .openai_compatible_key,
    );
    defer if (resolution.credential) |*c| c.deinit(testing.allocator);

    const chosen = resolution.credential orelse {
        std.debug.print("expected OpenRouter's own stored key\n", .{});
        return error.TestExpectedCredential;
    };
    try testing.expectEqualStrings("openrouter-secret", chosen.token);
    try testing.expectEqual(Source.stored_key, chosen.source);
}

test "an authorized remembered source is honored exactly" {
    var store = FakeSecretStore{};
    store.set(.openrouter, "openrouter-secret");
    store.set(.openai_compatible, "compatible-secret");

    var resolution = try credentials.resolveForProvider(
        testing.allocator,
        store.asSecretStore(),
        .stored,
        .openrouter,
        .stored_key,
    );
    defer if (resolution.credential) |*c| c.deinit(testing.allocator);

    const chosen = resolution.credential orelse return error.TestExpectedCredential;
    try testing.expectEqualStrings("openrouter-secret", chosen.token);
}

test "no remembered source resolves the selected provider's own key" {
    var store = FakeSecretStore{};
    store.set(.groq, "groq-secret");

    var resolution = try credentials.resolveForProvider(
        testing.allocator,
        store.asSecretStore(),
        .stored,
        .groq,
        null,
    );
    defer if (resolution.credential) |*c| c.deinit(testing.allocator);

    const chosen = resolution.credential orelse return error.TestExpectedCredential;
    try testing.expectEqualStrings("groq-secret", chosen.token);
}

test "a provider with no stored key never borrows another provider's key" {
    var store = FakeSecretStore{};
    store.set(.openrouter, "openrouter-secret");

    var resolution = try credentials.resolveForProvider(
        testing.allocator,
        store.asSecretStore(),
        .stored,
        .groq,
        null,
    );
    defer if (resolution.credential) |*c| c.deinit(testing.allocator);

    try testing.expect(resolution.credential == null);
}

test "an empty profile resolves to no credential" {
    var store = FakeSecretStore{};

    var resolution = try credentials.resolveForProvider(
        testing.allocator,
        store.asSecretStore(),
        .stored,
        .openrouter,
        null,
    );
    defer if (resolution.credential) |*c| c.deinit(testing.allocator);

    try testing.expect(resolution.credential == null);
    try testing.expect(resolution.failure == null);
}

test "each provider maps to its own environment and stored slots" {
    try testing.expectEqual(Source.openrouter_api_key, credentials.envSourceFor(.openrouter).?);
    try testing.expectEqual(Source.stored_key, credentials.storedSourceFor(.openrouter).?);

    try testing.expectEqual(Source.groq_api_key, credentials.envSourceFor(.groq).?);
    try testing.expectEqual(Source.groq_stored_key, credentials.storedSourceFor(.groq).?);

    try testing.expectEqual(
        Source.openai_compatible_api_key,
        credentials.envSourceFor(.openai_compatible).?,
    );
    try testing.expectEqual(
        Source.openai_compatible_key,
        credentials.storedSourceFor(.openai_compatible).?,
    );
}

test "only persisted sources report as stored" {
    try testing.expect(credentials.isStoredSource(.stored_key));
    try testing.expect(credentials.isStoredSource(.groq_stored_key));
    try testing.expect(credentials.isStoredSource(.openai_compatible_key));
    try testing.expect(!credentials.isStoredSource(.openrouter_api_key));
    try testing.expect(!credentials.isStoredSource(.host_managed));
}

test "a disabled store yields no stored credential" {
    var store = FakeSecretStore{};
    store.set(.openrouter, "openrouter-secret");
    var disabled = store.asSecretStore();
    disabled.is_disabled_fn = struct {
        fn always(_: ?*anyopaque) bool {
            return true;
        }
    }.always;

    var resolution = try credentials.resolveForProvider(
        testing.allocator,
        disabled,
        .stored,
        .openrouter,
        null,
    );
    defer if (resolution.credential) |*c| c.deinit(testing.allocator);

    try testing.expect(resolution.credential == null);
}
