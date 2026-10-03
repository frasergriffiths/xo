const std = @import("std");
const builtin = @import("builtin");
const debug_trace = @import("../shared/debug_trace.zig");
const host = @import("../hosts/host.zig");
const io_mod = @import("../shared/io.zig");
const model_provider = @import("../config/model_provider.zig");
const groq_endpoint = @import("../../gateway/groq_endpoint.zig");
const openai_compatible = @import("../../gateway/openai_compatible.zig");
const openrouter = @import("../../gateway/openrouter.zig");
const secret = @import("secret.zig");
const types = @import("../shared/types.zig");

pub const Source = types.CredentialSource;

/// The environment variable source that belongs to one built-in provider.
pub fn envSourceFor(provider: model_provider.ProviderId) ?Source {
    return switch (provider) {
        .openrouter => .openrouter_api_key,
        .groq => .groq_api_key,
        .openai_compatible => .openai_compatible_api_key,
        .configured => .configured,
    };
}

/// The persisted source that belongs to one built-in provider. A configured
/// endpoint keeps its credential in its own environment variable, so it has no
/// persisted slot.
pub fn storedSourceFor(provider: model_provider.ProviderId) ?Source {
    return switch (provider) {
        .openrouter => .stored_key,
        .groq => .groq_stored_key,
        .openai_compatible => .openai_compatible_key,
        .configured => null,
    };
}

/// True for sources read from a saved key store rather than the environment.
pub fn isStoredSource(source: Source) bool {
    return source == .stored_key or source == .groq_stored_key or source == .openai_compatible_key;
}

/// The physical store slot one persisted source lives in. Each provider owns a
/// separate slot so saving one key can never replace another's.
pub fn secretSlotFor(source: Source) ?host.SecretSlot {
    return switch (source) {
        .stored_key => .openrouter,
        .groq_stored_key => .groq,
        .openai_compatible_key => .openai_compatible,
        .openrouter_api_key, .groq_api_key, .openai_compatible_api_key, .host_managed, .configured => null,
    };
}

pub const AuthMode = enum {
    local,
    host_managed,
};

pub const AuthModeError = error{InvalidAuthMode};

pub fn parseAuthMode(value: ?[]const u8) AuthModeError!AuthMode {
    const raw = value orelse return .local;
    if (std.mem.eql(u8, raw, "local")) return .local;
    if (std.mem.eql(u8, raw, "host-managed")) return .host_managed;
    return error.InvalidAuthMode;
}

pub const CatalogPublicOnly = union(enum) {
    no_credential,
    /// The OpenRouter catalog is public, so a rejected key still leaves a usable
    /// model list behind. The payload records which key was refused.
    openrouter_key_rejected: Source,
    credential_refresh_required: Source,
    credential_refresh_failed: Source,

    fn credentialSource(self: CatalogPublicOnly) ?Source {
        return switch (self) {
            .no_credential => null,
            .openrouter_key_rejected => |source| source,
            .credential_refresh_required => |source| source,
            .credential_refresh_failed => |source| source,
        };
    }
};

pub const CatalogPublicOnlyReason = std.meta.Tag(CatalogPublicOnly);

pub const CatalogAuthenticatedSource = enum {
    openrouter_api_key,
    stored_key,
    groq_api_key,
    groq_stored_key,
    openai_compatible_api_key,
    openai_compatible_key,

    fn credentialSource(self: CatalogAuthenticatedSource) Source {
        return switch (self) {
            .openrouter_api_key => .openrouter_api_key,
            .stored_key => .stored_key,
            .groq_api_key => .groq_api_key,
            .groq_stored_key => .groq_stored_key,
            .openai_compatible_api_key => .openai_compatible_api_key,
            .openai_compatible_key => .openai_compatible_key,
        };
    }
};

const CatalogAuthority = enum {
    automatic,
    explicit,
};

/// A borrowed authorization decision for one model-catalog request. Public-only
/// states cannot carry credential or team bytes; authenticated states carry the
/// only values the request is allowed to send.
pub const CatalogAccess = union(enum) {
    public_only: CatalogPublicOnly,
    authenticated: struct {
        source: CatalogAuthenticatedSource,
        credential: []const u8,
        team_context: ?[]const u8,
        account_id: ?[]const u8 = null,
        authority: CatalogAuthority = .automatic,
    },
    host_managed,

    pub fn credentialSource(self: CatalogAccess) ?Source {
        return switch (self) {
            .public_only => |access| access.credentialSource(),
            .authenticated => |access| access.source.credentialSource(),
            .host_managed => .host_managed,
        };
    }

    pub fn publicOnlyReason(self: CatalogAccess) ?CatalogPublicOnlyReason {
        const access = self.publicOnly() orelse return null;
        return std.meta.activeTag(access);
    }

    pub fn publicOnly(self: CatalogAccess) ?CatalogPublicOnly {
        return switch (self) {
            .public_only => |access| access,
            .authenticated, .host_managed => null,
        };
    }

    pub fn publicFallbackAfterRejection(self: CatalogAccess) ?CatalogAccess {
        return switch (self) {
            .public_only => null,
            .host_managed => null,
            .authenticated => |access| if (access.authority == .explicit)
                null
            else
                CatalogAccess{ .public_only = .{ .openrouter_key_rejected = access.source.credentialSource() } },
        };
    }

    pub fn withExplicitAuthority(self: CatalogAccess) CatalogAccess {
        return switch (self) {
            .public_only => |access| .{ .public_only = access },
            .authenticated => |access| .{ .authenticated = .{
                .source = access.source,
                .credential = access.credential,
                .team_context = access.team_context,
                .account_id = access.account_id,
                .authority = .explicit,
            } },
            .host_managed => .host_managed,
        };
    }

    pub fn authorizationCredential(self: CatalogAccess) ?[]const u8 {
        return switch (self) {
            .public_only => null,
            .authenticated => |access| access.credential,
            .host_managed => null,
        };
    }

    pub fn teamContext(self: CatalogAccess) ?[]const u8 {
        const team = switch (self) {
            .public_only => return null,
            .authenticated => |access| access.team_context orelse return null,
            .host_managed => return null,
        };
        return if (team.len > 0) team else null;
    }

    pub fn accountId(self: CatalogAccess) ?[]const u8 {
        const account_id = switch (self) {
            .public_only => return null,
            .authenticated => |access| access.account_id orelse return null,
            .host_managed => return null,
        };
        return if (account_id.len > 0) account_id else null;
    }
};

pub fn catalogAccessAt(credential: ?Credential, now_ms: i64) CatalogAccess {
    _ = now_ms;
    const selected = credential orelse return .{ .public_only = .no_credential };
    return catalogAccessForCredentialAndAccount(selected.source, selected.token, null, null);
}

pub fn catalogAccessAfterRefreshFailure(source: Source) CatalogAccess {
    return .{
        .public_only = .{
            .credential_refresh_failed = source,
        },
    };
}

pub fn catalogAccessForCredential(
    source: ?Source,
    credential: []const u8,
    team_context: ?[]const u8,
) CatalogAccess {
    return catalogAccessForCredentialAndAccount(source, credential, team_context, null);
}

pub fn catalogAccessForCredentialAndAccount(
    source: ?Source,
    credential: []const u8,
    team_context: ?[]const u8,
    account_id: ?[]const u8,
) CatalogAccess {
    _ = team_context;
    _ = account_id;
    const selected_source = source orelse return .{ .public_only = .no_credential };
    if (selected_source == .host_managed) return .host_managed;
    // A configured endpoint reads its own environment variable at the
    // transport edge and never participates in a shared catalog fetch.
    if (selected_source == .configured) return .{ .public_only = .no_credential };
    const authenticated_source: CatalogAuthenticatedSource = switch (selected_source) {
        .openrouter_api_key => .openrouter_api_key,
        .groq_api_key => .groq_api_key,
        .stored_key => .stored_key,
        .groq_stored_key => .groq_stored_key,
        .openai_compatible_api_key => .openai_compatible_api_key,
        .openai_compatible_key => .openai_compatible_key,
        .configured, .host_managed => unreachable,
    };
    return .{
        .authenticated = .{
            .source = authenticated_source,
            .credential = credential,
            .team_context = null,
            .account_id = null,
        },
    };
}

/// Current native product copy. Store mechanics and availability come from the
/// injected host port; Core retains the stable user-facing source name.
pub const stored_key_backend_label = if (builtin.os.tag == .macos) "macOS Keychain" else "profile file";

/// Both modes resolve the same source set. `stored` forbids any write or network
/// side effect, which a diagnostic such as `fx doctor` depends on.
pub const LoadMode = enum { stored, refresh_if_needed };

pub const missing_credential_message = "fx needs an API key. Run `fx setup` to save one, or set the provider's API key environment variable.";
pub const missing_interactive_credential_message = "fx needs an API key. Run /provider to save one, or set the provider's API key environment variable.";
pub const unreadable_store_message = "fx could not read the stored API key from " ++ stored_key_backend_label ++ ". A key may be saved but unreadable. Set FX_TRACE_LOG for the failing step, or set " ++ openrouter.api_key_env ++ ".";
pub const host_managed_auth_message = "Authentication is managed by the host.";

pub const Credential = struct {
    token: []u8,
    source: Source,

    pub fn clone(self: Credential, alloc: std.mem.Allocator) !Credential {
        const token = try alloc.dupe(u8, self.token);
        errdefer secret.zeroAndFree(alloc, token);
        return .{
            .token = token,
            .source = self.source,
        };
    }

    pub fn deinit(self: *Credential, alloc: std.mem.Allocator) void {
        secret.zeroAndFree(alloc, self.token);
        self.* = undefined;
    }
};

pub const StoredKeyReadStatus = enum {
    not_attempted,
    not_found,
    unavailable,
};

pub const LoadFailure = struct {
    source: Source,
    err: anyerror,
};

pub const Resolution = struct {
    credential: ?Credential = null,
    stored_key_status: StoredKeyReadStatus = .not_attempted,
    failure: ?LoadFailure = null,
};

/// The single credential resolution method. Walks source precedence, then falls back to
/// the stored key, reporting why that store was silent when it produced nothing.
pub fn resolve(
    alloc: std.mem.Allocator,
    secret_store: host.SecretStore,
    mode: LoadMode,
) !Resolution {
    return resolvePreferring(alloc, secret_store, mode, null);
}

pub fn resolveForProvider(
    alloc: std.mem.Allocator,
    secret_store: host.SecretStore,
    mode: LoadMode,
    provider: model_provider.ProviderId,
    preferred: ?Source,
) !Resolution {
    if (provider == .configured) {
        var registry = try @import("../config/config_runtime.zig").loadConfiguredProviders(alloc);
        defer registry.deinit(alloc);
        const bound = try provider.bind(registry);
        const definition = registry.get(bound.label()).?;
        return switch (definition.auth) {
            .none => .{ .credential = .{ .token = try alloc.dupe(u8, ""), .source = .configured } },
            .bearer => |env| .{ .credential = try loadEnvCredential(alloc, env, .configured) },
        };
    }
    return resolveWithProvider(alloc, secret_store, mode, provider, preferred);
}

/// `preferred` is the source the user last chose in the hub. It is an exact
/// authority choice, not a precedence hint: absence must not silently select a
/// different key store. Only null runs automatic precedence.
pub fn resolvePreferring(
    alloc: std.mem.Allocator,
    secret_store: host.SecretStore,
    mode: LoadMode,
    preferred: ?Source,
) !Resolution {
    return resolveWithProvider(alloc, secret_store, mode, .openrouter, preferred);
}

/// Provider-aware automatic precedence: the provider's own environment variable
/// outranks that provider's saved key, and no other provider's key is consulted.
fn resolveWithProvider(
    alloc: std.mem.Allocator,
    secret_store: host.SecretStore,
    mode: LoadMode,
    provider: model_provider.ProviderId,
    preferred: ?Source,
) !Resolution {
    _ = mode;
    const env_source = envSourceFor(provider) orelse return .{};
    const stored_source = storedSourceFor(provider) orelse return .{};
    // A remembered source only speaks for the provider that owns it. Honoring
    // another provider's key here would adopt a credential the selected route
    // then refuses, which surfaces as a permanent request failure rather than
    // a missing key. Such a preference is ignored so normal precedence for
    // this provider runs instead.
    if (preferred) |source| {
        if (!model_provider.authorizesCredential(provider, source)) {
            debug_trace.logf(
                "auth",
                "preferred source not authorized for provider source={t} provider={t}",
                .{ source, provider },
            );
        } else {
            if (isStoredSource(source) and secret_store.isDisabled()) {
                debug_trace.logf("auth", "explicit source unavailable source={t} reason=disabled", .{source});
                return .{};
            }
            const chosen = loadSource(alloc, secret_store, source) catch |err| {
                if (err == error.OutOfMemory) return err;
                debug_trace.logf("auth", "explicit source load failed source={t} err={s}", .{ source, @errorName(err) });
                return .{ .failure = .{ .source = source, .err = err } };
            };
            if (chosen) |credential| return .{ .credential = credential };
            debug_trace.logf("auth", "explicit source unavailable source={t}", .{source});
            return missingExplicitResolution(source);
        }
    }

    if (try loadSource(alloc, secret_store, env_source)) |credential| return .{ .credential = credential };
    if (secret_store.isDisabled()) return .{};

    var status: StoredKeyReadStatus = .not_found;
    var failure: ?LoadFailure = null;
    const stored = loadSource(alloc, secret_store, stored_source) catch |err| blk: {
        if (err == error.OutOfMemory) return err;
        status = .unavailable;
        failure = .{ .source = stored_source, .err = err };
        debug_trace.logf("auth", "stored key load failed err={s} status={t}", .{ @errorName(err), status });
        break :blk null;
    };
    if (stored) |credential| return .{ .credential = credential };
    return .{ .stored_key_status = status, .failure = failure };
}

fn missingExplicitResolution(source: Source) Resolution {
    return switch (source) {
        .stored_key, .groq_stored_key, .openai_compatible_key => .{ .stored_key_status = .not_found },
        else => .{},
    };
}

pub fn loadSource(
    alloc: std.mem.Allocator,
    secret_store: host.SecretStore,
    source: Source,
) !?Credential {
    return switch (source) {
        .openrouter_api_key => loadEnvCredential(alloc, openrouter.api_key_env, source),
        .groq_api_key => loadEnvCredential(alloc, groq_endpoint.default_api_key_env, source),
        .openai_compatible_api_key => loadEnvCredential(alloc, openai_compatible.default_api_key_env, source),
        .stored_key, .groq_stored_key, .openai_compatible_key => loadStoredKeyCredential(alloc, secret_store, source),
        .host_managed, .configured => null,
    };
}

pub fn sourceExists(
    alloc: std.mem.Allocator,
    secret_store: host.SecretStore,
    source: Source,
) !bool {
    _ = alloc;
    return switch (source) {
        .openrouter_api_key => nonEmptyEnvValue(openrouter.api_key_env) != null,
        .groq_api_key => nonEmptyEnvValue(groq_endpoint.default_api_key_env) != null,
        .openai_compatible_api_key => nonEmptyEnvValue(openai_compatible.default_api_key_env) != null,
        .stored_key, .groq_stored_key, .openai_compatible_key => blk: {
            if (secret_store.isDisabled()) break :blk false;
            const slot = secretSlotFor(source) orelse break :blk false;
            break :blk switch (secret_store.presenceFor(slot)) {
                .present => true,
                .missing => false,
                .unavailable => {
                    debug_trace.logf(
                        "auth",
                        "source probe failed source=stored_key err=StoredKeyUnreadable",
                        .{},
                    );
                    return error.StoredKeyUnreadable;
                },
            };
        },
        .host_managed, .configured => false,
    };
}

pub fn sourcePresence(
    secret_store: host.SecretStore,
    source: Source,
) host.SecretStorePresence {
    return switch (source) {
        .openrouter_api_key => envPresence(openrouter.api_key_env),
        .groq_api_key => envPresence(groq_endpoint.default_api_key_env),
        .openai_compatible_api_key => envPresence(openai_compatible.default_api_key_env),
        .stored_key, .groq_stored_key, .openai_compatible_key => blk: {
            if (secret_store.isDisabled()) break :blk .missing;
            const slot = secretSlotFor(source) orelse break :blk .missing;
            break :blk secret_store.presenceFor(slot);
        },
        .host_managed, .configured => .missing,
    };
}

fn envPresence(name: []const u8) host.SecretStorePresence {
    return if (nonEmptyEnvValue(name) != null) .present else .missing;
}

fn loadEnvCredential(
    alloc: std.mem.Allocator,
    name: []const u8,
    source: Source,
) !?Credential {
    const value = nonEmptyEnvValue(name) orelse return null;
    return .{
        .token = try alloc.dupe(u8, value),
        .source = source,
    };
}

fn loadStoredKeyCredential(
    alloc: std.mem.Allocator,
    secret_store: host.SecretStore,
    source: Source,
) !?Credential {
    if (secret_store.isDisabled()) return null;
    const slot = secretSlotFor(source) orelse return null;
    const value = (try secret_store.loadFor(alloc, slot)) orelse return null;
    return .{ .token = value, .source = source };
}

fn nonEmptyEnvValue(name: []const u8) ?[]const u8 {
    return nonEmptyValue(io_mod.getenv(name));
}

fn nonEmptyValue(value: ?[]const u8) ?[]const u8 {
    const raw = value orelse return null;
    if (std.mem.trim(u8, raw, " \t\r\n").len == 0) return null;
    return raw;
}

/// True when a source's credential has a lifecycle beyond a static key. An
/// OpenRouter key never expires, so no source is refreshable today; the
/// predicate stays so callers do not hard-code that assumption.
pub fn sourceRefreshable(source: Source) bool {
    _ = source;
    return false;
}

pub fn sourceLabel(source: Source) []const u8 {
    return switch (source) {
        .openrouter_api_key => openrouter.api_key_env,
        .groq_api_key => groq_endpoint.default_api_key_env,
        .openai_compatible_api_key => openai_compatible.default_api_key_env,
        .stored_key, .groq_stored_key, .openai_compatible_key => "stored API key (" ++ stored_key_backend_label ++ ")",
        .host_managed => "host managed",
        .configured => "configured provider",
    };
}

var stable_credential_test_environ: ?*std.process.Environ.Map = null;

fn stableCredentialTestEnviron() !*const std.process.Environ.Map {
    if (stable_credential_test_environ) |map| return map;

    const alloc = std.heap.page_allocator;
    const map = try alloc.create(std.process.Environ.Map);
    map.* = std.process.Environ.Map.init(alloc);
    stable_credential_test_environ = map;
    return map;
}

const CredentialTestEnv = struct {
    alloc: std.mem.Allocator,
    map: std.process.Environ.Map,

    /// Installs exactly `entries`, so anything the resolver reads from the real
    /// environment, `HOME` included, is absent for the duration of the test.
    /// The Keychain is force-disabled: it is keyed by service and account, not
    /// by `HOME`, so without this a fixture session written under a tmp HOME
    /// migrates into the developer's real fx credential item and destroys
    /// their fx login.
    fn install(alloc: std.mem.Allocator, entries: []const [2][]const u8) !*CredentialTestEnv {
        _ = try stableCredentialTestEnviron();

        const self = try alloc.create(CredentialTestEnv);
        errdefer alloc.destroy(self);
        self.* = .{
            .alloc = alloc,
            .map = std.process.Environ.Map.init(alloc),
        };
        errdefer self.map.deinit();

        try self.map.put("FX_DISABLE_KEYCHAIN", "1");
        for (entries) |entry| try self.map.put(entry[0], entry[1]);
        io_mod.setEnvironMap(&self.map);
        return self;
    }

    fn deinit(self: *CredentialTestEnv) void {
        if (stable_credential_test_environ) |map| io_mod.setEnvironMap(map);
        self.map.deinit();
        const alloc = self.alloc;
        alloc.destroy(self);
    }
};

const SecretStoreFixture = struct {
    value: ?[]const u8 = null,
    disabled: bool = false,
    unreadable: bool = false,
    load_calls: usize = 0,
    presence_calls: usize = 0,

    fn provider(self: *@This()) host.SecretStore {
        return .{
            .context = self,
            .backend_label = "test credential store",
            .is_disabled_fn = isDisabled,
            .presence_fn = presence,
            .load_fn = load,
            .store_fn = store,
            .store_interactive_fn = storeInteractive,
        };
    }

    fn isDisabled(raw_context: ?*anyopaque) bool {
        const self: *@This() = @ptrCast(@alignCast(raw_context.?));
        return self.disabled;
    }

    fn presence(raw_context: ?*anyopaque, _: host.SecretSlot) host.SecretStorePresence {
        const self: *@This() = @ptrCast(@alignCast(raw_context.?));
        self.presence_calls += 1;
        if (self.unreadable) return .unavailable;
        return if (self.value == null) .missing else .present;
    }

    fn load(
        raw_context: ?*anyopaque,
        alloc: std.mem.Allocator,
        _: host.SecretSlot,
    ) host.SecretStoreLoadError!?[]u8 {
        const self: *@This() = @ptrCast(@alignCast(raw_context.?));
        self.load_calls += 1;
        if (self.unreadable) return error.StoredKeyUnreadable;
        const value = self.value orelse return null;
        return try alloc.dupe(u8, value);
    }

    fn store(
        _: ?*anyopaque,
        _: std.mem.Allocator,
        _: host.SecretSlot,
        _: []const u8,
    ) host.SecretStoreWriteError!void {
        return error.StoredKeyWriteFailed;
    }

    fn storeInteractive(
        _: ?*anyopaque,
        _: host.SecretSlot,
    ) host.SecretStoreWriteError!bool {
        return false;
    }
};
