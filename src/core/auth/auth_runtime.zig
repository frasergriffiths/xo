const std = @import("std");
const api_key_validator = @import("api_key_validator.zig");
const auth_transition = @import("auth_transition.zig");
const credentials = @import("credentials.zig");
const host = @import("../hosts/host.zig");
const model_provider = @import("../config/model_provider.zig");
const model_catalog = @import("../gateway/model_catalog.zig");
const provider_catalog = @import("provider_catalog.zig");
const provider_picker_catalog = @import("provider_picker_catalog.zig");
const secret = @import("secret.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const text_utils = @import("../shared/text_utils.zig");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;

pub const SourceSet = std.EnumSet(credentials.Source);

pub const CredentialRefreshMode = enum {
    if_needed,
    force,
};

/// Every credential source the runtime probes when it builds its inventory.
const all_credential_sources = [_]credentials.Source{
    .openrouter_api_key,
    .stored_key,
    .groq_api_key,
    .groq_stored_key,
};

/// Automatic source order for one provider. The environment key wins so a shell
/// override is never silently shadowed by a saved key; that provider's store is
/// the durable fallback. No other provider's key is ever consulted.
fn sourcesForProvider(provider: model_provider.ProviderId) []const credentials.Source {
    return switch (provider) {
        .openrouter => &.{ .openrouter_api_key, .stored_key },
        .groq => &.{ .groq_api_key, .groq_stored_key },
        .openai_compatible => &.{ .openai_compatible_api_key, .openai_compatible_key },
        .configured => &.{},
    };
}

const SourceProbeFn = *const fn (?*anyopaque, Allocator, credentials.Source) anyerror!bool;
const CredentialLoaderFn = *const fn (?*anyopaque, Allocator, credentials.Source) anyerror!?credentials.Credential;
const StoredKeyStoreFn = *const fn (?*anyopaque, Allocator, credentials.Source, []const u8) anyerror!void;

const max_api_key_entry_bytes: usize = 8 * 1024;
const max_base_url_entry_bytes: usize = 2 * 1024;
const max_api_key_mask_glyphs = provider_picker_catalog.max_key_mask_glyphs;

fn sourceLabelOrMissing(source: ?credentials.Source) []const u8 {
    return credentials.sourceLabel(source orelse return "missing");
}

pub const CredentialFailureReason = enum {
    temporary_unavailable,
    invalid_credential,
    invalid_storage,
    persistence_uncertain,
    authority_changed,
};

pub const CredentialFailure = struct {
    source: credentials.Source,
    reason: CredentialFailureReason,

    pub fn retryable(self: CredentialFailure) bool {
        return self.reason == .temporary_unavailable;
    }

    /// True when the saved key must be replaced rather than retried.
    pub fn requiresSignIn(self: CredentialFailure) bool {
        return self.reason == .invalid_credential or self.reason == .persistence_uncertain;
    }
};

pub fn classifyCredentialFailure(
    source: credentials.Source,
    err: anyerror,
) CredentialFailure {
    return .{
        .source = source,
        .reason = switch (err) {
            error.CredentialRefreshRejected,
            error.CredentialRefreshUnavailable,
            => .invalid_credential,
            error.CredentialStorageUnavailable,
            error.DurablePathUnsafe,
            error.StoredKeyUnreadable,
            error.StoredKeyInsecure,
            error.KeychainReadFailed,
            error.KeychainItemNotFound,
            error.PrivateStatePermissionsUnsupported,
            error.HomeNotSet,
            error.UserNotSet,
            => .invalid_storage,
            error.KeychainWriteFailed,
            error.CredentialPersistenceFailed,
            error.DurableReplacePreRenameFailed,
            error.DurableReplacePostRenameFailed,
            => .persistence_uncertain,
            error.CredentialAuthorityChanged,
            error.SessionChanged,
            => .authority_changed,
            else => .temporary_unavailable,
        },
    };
}

pub const FailureReason = enum {
    credential_refresh_failed,
    http_unauthorized,
};

pub const FailureSnapshot = struct {
    source: credentials.Source,
    reason: FailureReason,
    http_status: ?std.http.Status = null,

    pub fn fromHttp(status: std.http.Status, source: ?credentials.Source) ?FailureSnapshot {
        if (status != .unauthorized) return null;
        return .{
            .source = source orelse return null,
            .reason = .http_unauthorized,
            .http_status = status,
        };
    }

    /// Returns owned, detail-free text. The caller owns the returned slice.
    pub fn renderText(self: FailureSnapshot, alloc: Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();

        try out.writer.print("{s} {s}", .{
            credentials.sourceLabel(self.source),
            switch (self.reason) {
                .credential_refresh_failed => "credential refresh failed",
                .http_unauthorized => "authentication failed",
            },
        });
        if (self.http_status) |status| {
            try out.writer.print(" · HTTP {d}", .{@intFromEnum(status)});
        }
        return try out.toOwnedSlice();
    }

    /// Returns owned JSON containing only the shared auth-failure facts.
    pub fn renderJson(self: FailureSnapshot, alloc: Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();

        try self.writeJson(&out.writer);
        return try out.toOwnedSlice();
    }

    pub fn writeJson(self: FailureSnapshot, writer: *std.Io.Writer) !void {
        try writer.writeAll("{\"source\":");
        try std.json.Stringify.value(credentials.sourceLabel(self.source), .{}, writer);
        try writer.writeAll(",\"reason\":");
        try std.json.Stringify.value(@tagName(self.reason), .{}, writer);
        if (self.http_status) |status| {
            try writer.print(",\"http_status\":{d}", .{@intFromEnum(status)});
        }
        try writer.writeByte('}');
    }
};

/// Process-local proof that a request-path credential load succeeded recently.
/// The request path's defensive `.if_needed` reload reads the OS secret store
/// (tens of milliseconds on macOS); when admission or an earlier step just
/// proved the credential, repeating that read only adds latency. A stale skip
/// costs one unauthorized response, which the existing force-refresh replay
/// already recovers from.
const request_path_verified_window_ms: u32 = 30_000;
const source_none: u8 = std.math.maxInt(u8);
// u32 keeps the stamp atomic-loadable on 32-bit wasm; wrapping subtraction
// keeps window comparisons correct across the ~49 day wrap.
var request_path_verified_ms = std.atomic.Value(u32).init(0);
var request_path_verified_source = std.atomic.Value(u8).init(source_none);

fn stampNowMs() u32 {
    return @truncate(@as(u64, @bitCast(io_mod.milliTimestamp())));
}

fn noteRequestPathCredentialVerified(source: credentials.Source) void {
    request_path_verified_source.store(@intFromEnum(source), .seq_cst);
    request_path_verified_ms.store(stampNowMs(), .seq_cst);
}

/// True when one refreshable source's credential was loaded successfully within
/// the skip window. Request-path callers use this to bypass a redundant
/// defensive reload; admission and forced refreshes must not consult it.
pub fn requestPathCredentialVerifiedRecently(source: credentials.Source) bool {
    const verified_ms = request_path_verified_ms.load(.seq_cst);
    if (verified_ms == 0) return false;
    if (request_path_verified_source.load(.seq_cst) != @intFromEnum(source)) return false;
    return stampNowMs() -% verified_ms < request_path_verified_window_ms;
}

fn resetRequestPathCredentialVerification() void {
    request_path_verified_ms.store(0, .seq_cst);
    request_path_verified_source.store(source_none, .seq_cst);
}

/// Re-reads one credential source. OpenRouter keys do not expire, so a forced
/// re-read is the whole of a refresh; there is no token rotation to perform.
pub fn refreshCredentialForAccount(
    alloc: Allocator,
    secret_store: host.SecretStore,
    source: credentials.Source,
    _: CredentialRefreshMode,
) !?credentials.Credential {
    switch (source) {
        .openrouter_api_key, .stored_key, .groq_api_key, .groq_stored_key, .openai_compatible_api_key, .openai_compatible_key => {},
        .host_managed, .configured => return null,
    }
    const credential = try credentials.loadSource(alloc, secret_store, source);
    if (credential != null) noteRequestPathCredentialVerified(source);
    return credential;
}

pub const CredentialPreparationError = Allocator.Error || error{
    CredentialStorageUnavailable,
    CredentialTemporarilyUnavailable,
    CredentialAuthorityChanged,
};

/// Resolves one provider credential. The returned value is owned by the caller
/// and must be released with `Credential.deinit`. Null means authentication is
/// needed; storage, transport and authority failures stay errors. A non-null
/// `preferred` is an exact credential source, not a precedence hint.
pub fn prepareCredential(
    alloc: Allocator,
    secret_store: host.SecretStore,
    provider: model_provider.ProviderId,
    preferred: ?credentials.Source,
) CredentialPreparationError!?credentials.Credential {
    var resolution = credentials.resolveForProvider(
        alloc,
        secret_store,
        .refresh_if_needed,
        provider,
        preferred,
    ) catch |err| failure: {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        debug_trace.logf(
            "auth",
            "credential preparation failed provider={t} source={s} err={s}",
            .{
                provider,
                if (requestedSource(provider, preferred)) |source| @tagName(source) else "automatic",
                @errorName(err),
            },
        );
        break :failure credentials.Resolution{ .failure = .{
            .source = requestedSource(provider, preferred) orelse .openrouter_api_key,
            .err = err,
        } };
    };
    return prepareResolvedCredential(alloc, provider, &resolution);
}

fn prepareResolvedCredential(
    alloc: Allocator,
    provider: model_provider.ProviderId,
    resolution: *credentials.Resolution,
) CredentialPreparationError!?credentials.Credential {
    var credential = resolution.credential orelse {
        if (resolution.failure) |failure| {
            if (preparationError(classifyCredentialFailure(failure.source, failure.err))) |err| return err;
            return null;
        }
        if (resolution.stored_key_status == .unavailable) return error.CredentialStorageUnavailable;
        return null;
    };
    resolution.credential = null;

    // An empty token only makes sense for a configured endpoint that declares
    // no authentication at all. Everything else must carry a real key.
    const unauthenticated_configured = provider == .configured and credential.source == .configured;
    if ((credential.token.len == 0 and !unauthenticated_configured) or
        !model_provider.authorizesCredential(provider, credential.source))
    {
        credential.deinit(alloc);
        return null;
    }
    noteRequestPathCredentialVerified(credential.source);
    return credential;
}

pub fn requestedSource(
    provider: model_provider.ProviderId,
    preferred: ?credentials.Source,
) ?credentials.Source {
    if (provider == .configured) return .configured;
    return if (model_provider.authorizesCredential(provider, preferred)) preferred else null;
}

pub fn preparationError(failure: CredentialFailure) ?CredentialPreparationError {
    return switch (failure.reason) {
        .invalid_credential => null,
        .invalid_storage => error.CredentialStorageUnavailable,
        .temporary_unavailable => error.CredentialTemporarilyUnavailable,
        .persistence_uncertain => error.CredentialStorageUnavailable,
        .authority_changed => error.CredentialAuthorityChanged,
    };
}

pub fn preparationFailureNotice(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.CredentialStorageUnavailable => "Saved API key storage is unavailable. Check the saved key, then retry.",
        error.CredentialTemporarilyUnavailable => "Reading the API key is temporarily unavailable. Retry shortly.",
        error.CredentialAuthorityChanged => "The credential changed. Review authentication before retrying.",
        else => null,
    };
}

/// Returns an owned, secret-free explanation shared by activation surfaces.
pub fn preparationFailureText(alloc: Allocator, provider: model_provider.ProviderId, err: anyerror) ![]u8 {
    const label = provider_catalog.label(provider);
    const failure = classifyCredentialFailure(provider_catalog.find(provider).login_source, err);
    const normalized = preparationError(failure) orelse
        return std.fmt.allocPrint(alloc, "{s} needs a valid API key.", .{label});
    return std.fmt.allocPrint(alloc, "{s}: {s}", .{ label, preparationFailureNotice(normalized).? });
}

pub const AcquisitionAction = enum {
    connections,
    setup,
    switch_credential,
    switch_provider,
    /// Clears a remembered choice so resolution returns to plain precedence.
    /// Without it the only way back would be editing settings.json by hand.
    automatic,
};

pub const PickerStage = enum {
    root,
    connections,
    provider,
    base_url,
    api_key,
    switch_credential,
};

pub const ApiKeySaveStart = enum {
    started,
    /// Nothing typed, so Enter is a no-op the user already understands.
    empty,
    /// A previous save is still in flight. The entered key is discarded rather
    /// than queued, so the caller must say so instead of failing silently.
    busy,
};

pub const ApiKeySaveResult = union(enum) {
    empty,
    saved: bool,
    gateway_refused,
    gateway_unavailable,
    store_failed,
    reload_failed,
};

/// The save does a gateway round trip and a key-store write, either of which can
/// take seconds. It runs on a worker so the event loop keeps drawing; the worker
/// performs I/O only and hands the loaded credential back for the main thread to
/// adopt, keeping `selected_credential` single-threaded.
pub const ApiKeySaveOutcome = union(enum) {
    gateway_refused,
    gateway_unavailable,
    store_failed,
    reload_failed,
    loaded: credentials.Credential,

    pub fn deinit(self: *ApiKeySaveOutcome, alloc: Allocator) void {
        switch (self.*) {
            .loaded => |*credential| credential.deinit(alloc),
            else => {},
        }
        self.* = .reload_failed;
    }
};

const ApiKeySaveDeps = struct {
    ctx: ?*anyopaque = null,
    validator: api_key_validator.Provider = api_key_validator.unavailable_provider,
    /// Which provider's persisted slot this key belongs to. Each provider owns
    /// a physically separate secret, so the save must target the slot of the
    /// provider the user was in when they pasted it.
    stored_source: credentials.Source = .stored_key,
    store: StoredKeyStoreFn = storeUnavailableSecret,
    loader: CredentialLoaderFn = loadCredentialSource,
};

/// The whole save sequence with no runtime state, so outcome behaviour can be
/// tested synchronously while the worker owns only threading.
fn performApiKeySave(alloc: Allocator, key: []const u8, deps: ApiKeySaveDeps) ApiKeySaveOutcome {
    switch (deps.validator.validate(alloc, key)) {
        .accepted => {},
        .refused => return .gateway_refused,
        .unavailable => return .gateway_unavailable,
    }
    deps.store(deps.ctx, alloc, deps.stored_source, key) catch |err| {
        debug_trace.logf("auth", "api key save failed step=store err={s}", .{@errorName(err)});
        return .store_failed;
    };
    const loaded = deps.loader(deps.ctx, alloc, deps.stored_source) catch |err| {
        debug_trace.logf("auth", "api key save failed step=reload err={s}", .{@errorName(err)});
        return .reload_failed;
    };
    const credential = loaded orelse return .reload_failed;
    if (credential.source != deps.stored_source) {
        var wrong = credential;
        wrong.deinit(alloc);
        return .reload_failed;
    }
    return .{ .loaded = credential };
}

const ApiKeySaveRuntime = struct {
    const Self = @This();

    mutex: std.Io.Mutex = .init,
    thread: ?std.Thread = null,
    running: bool = false,
    /// Owned for the worker's lifetime and zeroed by it, so the entry stage can
    /// drop its own buffer the moment the save starts.
    key: std.ArrayList(u8) = .empty,
    outcome: ?ApiKeySaveOutcome = null,
    deps: ApiKeySaveDeps = .{},

    fn start(self: *Self, alloc: Allocator, key: std.ArrayList(u8), deps: ApiKeySaveDeps) bool {
        self.mutex.lockUncancelable(io_mod.getIo());
        if (self.running or self.thread != null) {
            self.mutex.unlock(io_mod.getIo());
            var rejected = key;
            secret.zeroAndFree(alloc, rejected.allocatedSlice());
            return false;
        }
        self.running = true;
        self.key = key;
        self.deps = deps;
        self.mutex.unlock(io_mod.getIo());

        self.thread = std.Thread.spawn(.{}, workerMain, .{ self, alloc }) catch {
            self.mutex.lockUncancelable(io_mod.getIo());
            self.running = false;
            var abandoned = self.key;
            self.key = .empty;
            self.mutex.unlock(io_mod.getIo());
            secret.zeroAndFree(alloc, abandoned.allocatedSlice());
            debug_trace.logf("auth", "api key save worker failed to spawn", .{});
            return false;
        };
        return true;
    }

    fn workerMain(self: *Self, alloc: Allocator) void {
        const result = performApiKeySave(alloc, self.key.items, self.deps);

        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        var spent = self.key;
        self.key = .empty;
        secret.zeroAndFree(alloc, spent.allocatedSlice());
        self.outcome = result;
        self.running = false;
    }

    /// Returns the finished outcome once, joining the worker first. Ownership of a
    /// loaded credential passes to the caller.
    fn take(self: *Self, alloc: Allocator) ?ApiKeySaveOutcome {
        self.mutex.lockUncancelable(io_mod.getIo());
        if (self.running) {
            self.mutex.unlock(io_mod.getIo());
            return null;
        }
        const thread = self.thread;
        self.thread = null;
        const outcome = self.outcome;
        self.outcome = null;
        self.mutex.unlock(io_mod.getIo());

        if (thread) |handle| handle.join();
        _ = alloc;
        return outcome;
    }

    fn isSaving(self: *const Self) bool {
        const mutable = @constCast(self);
        mutable.mutex.lockUncancelable(io_mod.getIo());
        defer mutable.mutex.unlock(io_mod.getIo());
        return self.running;
    }

    fn deinit(self: *Self, alloc: Allocator) void {
        const thread = self.thread;
        self.thread = null;
        if (thread) |handle| handle.join();
        if (self.outcome) |*outcome| outcome.deinit(alloc);
        self.outcome = null;
        var spent = self.key;
        self.key = .empty;
        secret.zeroAndFree(alloc, spent.allocatedSlice());
        self.running = false;
    }
};

pub const InventoryRefreshDestination = enum {
    auth_picker,
    provider_picker_command,
};

pub const InventoryRefreshAction = struct {
    provider: model_provider.ProviderId,
    destination: InventoryRefreshDestination = .auth_picker,
};

pub const InventoryRefreshStart = enum {
    started,
    busy,
    failed,
};

pub const InventoryRefreshResult = union(enum) {
    ready: InventoryRefreshAction,
    failed: InventoryRefreshAction,
};

const InventoryRefreshDeps = struct {
    ctx: ?*anyopaque,
    probe: SourceProbeFn,
};

const SourceInventory = struct {
    available: SourceSet = .empty,
    unavailable: SourceSet = .empty,

    fn detect(alloc: Allocator, ctx: ?*anyopaque, probe: SourceProbeFn) !SourceInventory {
        var inventory: SourceInventory = .{};
        for (all_credential_sources) |source| {
            const present = probe(ctx, alloc, source) catch |err| switch (err) {
                error.CredentialStorageUnavailable => {
                    debug_trace.logf("auth", "inventory source unavailable source={t}", .{source});
                    inventory.unavailable.insert(source);
                    continue;
                },
                else => return err,
            };
            if (present) inventory.available.insert(source);
        }
        return inventory;
    }
};

pub const ProviderPreparationIntent = union(enum) {
    provider: struct {
        target: model_provider.ProviderId,
        origin: auth_transition.ProviderSwitchIntent,
        fallback: ?model_provider.ProviderId = null,
    },
};

pub const ProviderPreparationInput = struct {
    intent: ProviderPreparationIntent,
    catalog_provider: model_catalog.Provider,
    models_path: []const u8,
    preferred_source: ?credentials.Source = null,
    primary_model: ?[]const u8 = null,
    preferred_model: ?[]const u8 = null,
    candidate: ?credentials.Credential = null,

    pub fn target(self: ProviderPreparationInput) model_provider.ProviderId {
        return self.intent.provider.target;
    }
};

/// Owns the preparation inputs and outcome until the event loop consumes it.
/// Provider capabilities must outlive the task. Only the worker writes results;
/// the main thread reads them after the release/acquire completion and join.
pub const ProviderPreparation = struct {
    alloc: Allocator,
    input: ProviderPreparationInput,
    secret_store: host.SecretStore,
    host_managed: bool,
    thread: ?std.Thread = null,
    cancel_requested: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
    credential: ?credentials.Credential = null,
    catalog: ?model_catalog.ProviderResult = null,
    failure: ?anyerror = null,

    fn start(alloc: Allocator, runtime: *const Runtime, input: ProviderPreparationInput) !*ProviderPreparation {
        const self = try alloc.create(ProviderPreparation);
        self.* = .{
            .alloc = alloc,
            .input = input,
            .secret_store = runtime.secret_store,
            .host_managed = runtime.isHostManaged(),
        };
        self.input.primary_model = null;
        self.input.preferred_model = null;
        self.input.candidate = null;
        self.input.models_path = "";
        errdefer self.deinit();
        self.input.models_path = try alloc.dupe(u8, input.models_path);
        if (input.primary_model) |value| self.input.primary_model = try alloc.dupe(u8, value);
        if (input.preferred_model) |value| self.input.preferred_model = try alloc.dupe(u8, value);
        if (input.candidate) |candidate| self.input.candidate = try candidate.clone(alloc);
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }

    fn run(self: *ProviderPreparation) void {
        defer self.done.store(true, .release);
        if (self.cancel_requested.load(.seq_cst)) return;
        if (self.input.candidate) |candidate| {
            self.credential = candidate;
            self.input.candidate = null;
        } else if (!self.host_managed) {
            self.credential = prepareCredential(
                self.alloc,
                self.secret_store,
                self.input.target(),
                self.input.preferred_source,
            ) catch |err| {
                self.failure = err;
                return;
            };
            if (self.credential == null) return;
        }
        if (self.cancel_requested.load(.seq_cst)) return;
        const access: credentials.CatalogAccess = if (self.host_managed)
            .host_managed
        else
            credentials.catalogAccessForCredential(
                self.credential.?.source,
                self.credential.?.token,
                null,
            );
        self.catalog = self.input.catalog_provider.fetch(self.alloc, .{
            .access = access,
            .endpoint = self.input.models_path,
            .cancel_flag = &self.cancel_requested,
            .view = .picker,
        }) catch |err| {
            self.failure = err;
            return;
        };
    }

    pub fn requestCancel(self: *ProviderPreparation) void {
        if (!self.cancel_requested.swap(true, .seq_cst)) {
            debug_trace.logf("auth", "provider preparation cancelled target={t}", .{self.input.target()});
        }
    }

    pub fn deinit(self: *ProviderPreparation) void {
        if (self.thread) |thread| {
            self.requestCancel();
            thread.join();
        }
        if (self.credential) |*credential| credential.deinit(self.alloc);
        if (self.input.candidate) |*credential| credential.deinit(self.alloc);
        if (self.catalog) |*result| switch (result.*) {
            .catalog => |*catalog| model_catalog.freeModelCatalog(self.alloc, catalog),
            .failure => {},
        };
        if (self.input.primary_model) |value| self.alloc.free(value);
        if (self.input.preferred_model) |value| self.alloc.free(value);
        self.alloc.free(self.input.models_path);
        const alloc = self.alloc;
        alloc.destroy(self);
    }
};

const PreparationTestCatalog = struct {
    entered: std.atomic.Value(bool) = .init(false),
    release: std.atomic.Value(bool) = .init(false),
    cancelled: std.atomic.Value(bool) = .init(false),

    fn provider(self: *PreparationTestCatalog) model_catalog.Provider {
        return .{ .context = self, .fetch_fn = fetch };
    }

    fn fetch(raw: ?*anyopaque, alloc: Allocator, input: model_catalog.FetchInput) Allocator.Error!model_catalog.ProviderResult {
        const self: *PreparationTestCatalog = @ptrCast(@alignCast(raw.?));
        self.entered.store(true, .release);
        while (!self.release.load(.acquire)) {
            if (input.cancel_flag.?.load(.seq_cst)) {
                self.cancelled.store(true, .release);
                return .{ .failure = .{ .category = .cancellation } };
            }
            io_mod.sleep(std.time.ns_per_ms);
        }
        var catalog: std.ArrayList(model_catalog.ModelCatalogEntry) = .empty;
        errdefer model_catalog.freeModelCatalog(alloc, &catalog);
        const id = try alloc.dupe(u8, "test/prepared");
        errdefer alloc.free(id);
        const model_type = try alloc.dupe(u8, "language");
        errdefer alloc.free(model_type);
        try catalog.append(alloc, .{ .id = id, .model_type = model_type });
        return .{ .catalog = catalog };
    }
};

fn waitForPreparationTest(flag: *const std.atomic.Value(bool)) !void {
    const deadline = io_mod.milliTimestamp() + 5000;
    while (!flag.load(.acquire)) {
        if (io_mod.milliTimestamp() >= deadline) return error.TestUnexpectedResult;
        io_mod.sleep(std.time.ns_per_ms);
    }
}

const InventoryRefreshTask = struct {
    alloc: Allocator,
    thread: ?std.Thread = null,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    action: InventoryRefreshAction,
    deps: InventoryRefreshDeps,
    inventory: ?SourceInventory = null,
    failure: ?anyerror = null,

    fn start(
        alloc: Allocator,
        action: InventoryRefreshAction,
        deps: InventoryRefreshDeps,
    ) !*InventoryRefreshTask {
        const task = try alloc.create(InventoryRefreshTask);
        task.* = .{
            .alloc = alloc,
            .action = action,
            .deps = deps,
        };
        task.thread = std.Thread.spawn(.{}, workerMain, .{task}) catch |err| {
            alloc.destroy(task);
            return err;
        };
        return task;
    }

    fn workerMain(self: *InventoryRefreshTask) void {
        self.inventory = SourceInventory.detect(self.alloc, self.deps.ctx, self.deps.probe) catch |err| {
            self.failure = err;
            self.done.store(true, .release);
            return;
        };
        self.done.store(true, .release);
    }

    fn deinit(self: *InventoryRefreshTask) void {
        if (self.thread) |thread| thread.join();
        const alloc = self.alloc;
        alloc.destroy(self);
    }
};

const ApiKeyExitReason = enum {
    cancel,
    saved,
    screen_replacement,
    runtime_deinit,
};

const ManualCodeClearReason = enum {
    cancel,
    submitted,
    screen_replacement,
    runtime_deinit,
};

pub const Choice = union(enum) {
    provider: model_provider.ProviderId,
    source: credentials.Source,
    action: AcquisitionAction,

    pub fn eql(self: Choice, other: Choice) bool {
        return switch (self) {
            .provider => |provider| switch (other) {
                .provider => |other_provider| provider.eql(other_provider),
                .source, .action => false,
            },
            .source => |source| switch (other) {
                .source => |other_source| source == other_source,
                .provider, .action => false,
            },
            .action => |action| switch (other) {
                .provider, .source => false,
                .action => |other_action| action == other_action,
            },
        };
    }
};

pub const PickerView = struct {
    active: bool,
    available_sources: SourceSet,
    unavailable_sources: SourceSet = .empty,
    selected_choice: ?Choice,
    active_source: ?credentials.Source,
    active_provider: model_provider.ProviderId = .openrouter,
    include_skip: bool,
    stage: PickerStage = .root,
    api_key_mask_count: usize = 0,
    api_key_inline: bool = false,
    /// Names the provider whose key the api_key stage enters, so the field and
    /// its placeholder say which provider the pasted key belongs to.
    api_key_provider_label: []const u8 = "OpenRouter",
    /// The base URL typed so far for the OpenAI-compatible endpoint field.
    base_url_text: []const u8 = "",
    /// The base URL field is rendered as a `/provider` column, mirroring the
    /// inline API key field.
    base_url_inline: bool = false,

    pub fn activeSourceLabel(self: PickerView) []const u8 {
        return sourceLabelOrMissing(self.active_source);
    }

    pub fn choiceCount(self: PickerView) usize {
        return switch (self.stage) {
            .root => if (self.include_skip) 1 else 2,
            .connections => 1,
            .provider => provider_catalog.entries.len,
            .base_url, .api_key => 0,
            .switch_credential => gatewaySourceCount(self.available_sources) + 1,
        };
    }

    pub fn choiceAt(self: PickerView, index: usize) ?Choice {
        return switch (self.stage) { // There is one provider and one credential, so the root stage offers
            // one action: open the key field. An extra screen that only led to
            // the same field was a step without a decision.
            .root => if (self.include_skip)
                (if (index == 0) Choice{ .action = .setup } else null)
            else switch (index) {
                0 => .{ .action = .setup },
                1 => .{ .action = .switch_credential },
                else => null,
            },
            .connections => if (index == 0) .{ .action = .setup } else null,
            .provider => if (index < provider_catalog.entries.len)
                .{ .provider = provider_catalog.entries[index].id }
            else
                null,
            .api_key => null,
            .base_url => null,
            .switch_credential => if (index < gatewaySourceCount(self.available_sources))
                .{ .source = gatewaySourceAtIndex(self.available_sources, index).? }
            else if (index == gatewaySourceCount(self.available_sources))
                .{ .action = .automatic }
            else
                null,
        };
    }

    pub fn choiceIsSelected(self: PickerView, choice: Choice) bool {
        const selected = self.selected_choice orelse return false;
        return selected.eql(choice);
    }

    pub fn selectedIndex(self: PickerView) usize {
        const selected = self.selected_choice orelse return 0;
        var index: usize = 0;
        while (self.choiceAt(index)) |choice| : (index += 1) {
            if (choice.eql(selected)) return index;
        }
        return 0;
    }

    pub fn choiceLabel(self: PickerView, choice: Choice) []const u8 {
        return switch (choice) {
            .provider => |provider| provider_catalog.label(provider),
            .source => |source| credentials.sourceLabel(source),
            .action => |action| switch (action) {
                .connections => "Connections",
                .setup => if (self.include_skip) "Add an API key" else "API key",
                .switch_credential => "Switch credential",
                .switch_provider => "Switch provider",
                .automatic => "Automatic",
            },
        };
    }

    pub fn choiceDescription(self: PickerView, choice: Choice) []const u8 {
        return switch (choice) {
            .provider => |provider| if (provider.eql(self.active_provider)) "current" else "available",
            .source => |source| if (self.active_source == source) "current" else "available",
            .action => |action| switch (action) {
                .connections, .setup, .switch_credential, .switch_provider => "",
                .automatic => "use the first available source",
            },
        };
    }

    pub fn choiceEnabled(self: PickerView, choice: Choice) bool {
        _ = self;
        return switch (choice) {
            .action, .provider, .source => true,
        };
    }
};

pub const GatewayTeamStatus = enum {
    unset,

    pub fn label(self: GatewayTeamStatus) []const u8 {
        return switch (self) {
            .unset => "unset",
        };
    }
};

pub const MissingHelpSurface = enum {
    cli,
    interactive,
};

pub const StatusSnapshot = struct {
    active_source: ?credentials.Source = null,
    required_source: ?credentials.Source = null,
    stored_key_status: credentials.StoredKeyReadStatus = .not_attempted,
    failure: ?CredentialFailure = null,
    /// At least one OpenRouter key source resolved without an explicit choice.
    connected: bool = false,

    pub fn deinit(self: *StatusSnapshot, alloc: Allocator) void {
        _ = alloc;
        self.* = .{};
    }

    pub fn activeSourceLabel(self: StatusSnapshot) []const u8 {
        return sourceLabelOrMissing(self.active_source);
    }

    pub fn missingHelp(self: StatusSnapshot, surface: MissingHelpSurface) ?[]const u8 {
        if (self.active_source != null) return null;
        if (self.stored_key_status == .unavailable) {
            if (self.required_source == .stored_key) return switch (surface) {
                .cli => "The selected stored API key could not be read from " ++ credentials.stored_key_backend_label ++ ". Start fx and open /provider to choose an available credential; no other credential was selected.",
                .interactive => "The selected stored API key could not be read from " ++ credentials.stored_key_backend_label ++ ". Run /provider to choose an available credential; no other credential was selected.",
            };
            return credentials.unreadable_store_message;
        }
        if (self.failure) |failure| {
            if (preparationError(failure)) |err| return preparationFailureNotice(err);
        }
        const automatic_help: []const u8 = switch (surface) {
            .cli => credentials.missing_credential_message,
            .interactive => credentials.missing_interactive_credential_message,
        };
        const required_source = self.required_source orelse return automatic_help;
        return switch (required_source) {
            .openrouter_api_key => "OPENROUTER_API_KEY is selected but unavailable. Set OPENROUTER_API_KEY before starting fx; no other credential was selected.",
            .groq_api_key => "GROQ_API_KEY is selected but unavailable. Set GROQ_API_KEY before starting fx; no other credential was selected.",
            .stored_key, .groq_stored_key, .openai_compatible_key => switch (surface) {
                .cli => "A stored API key is selected but unavailable. Start fx and open /provider to choose an available credential; no other credential was selected.",
                .interactive => "A stored API key is selected but unavailable. Run /provider to choose an available credential; no other credential was selected.",
            },
            .openai_compatible_api_key => "FX_OPENAI_COMPATIBLE_API_KEY is selected but unavailable. Set FX_OPENAI_COMPATIBLE_API_KEY before starting fx; no other credential was selected.",
            .host_managed => automatic_help,
            .configured => "The configured provider credential is unavailable. Check its auth environment variable in settings.json; no other provider was selected.",
        };
    }

    /// Returns owned doctor status text containing no credential bytes.
    pub fn formatDoctorDetail(self: StatusSnapshot, alloc: Allocator) ![]u8 {
        if (self.missingHelp(.cli)) |help| return alloc.dupe(u8, help);

        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();
        try out.writer.print("{s} is configured", .{self.activeSourceLabel()});
        return try out.toOwnedSlice();
    }
};

pub fn loadStatusSnapshot(
    alloc: Allocator,
    secret_store: host.SecretStore,
    preferred: ?credentials.Source,
) !StatusSnapshot {
    return loadStatusSnapshotForProvider(alloc, secret_store, null, preferred);
}

pub fn loadStatusSnapshotForProvider(
    alloc: Allocator,
    secret_store: host.SecretStore,
    provider: ?model_provider.ProviderId,
    preferred: ?credentials.Source,
) !StatusSnapshot {
    // Resolves in `.stored` mode: a diagnostic must not write to the key store
    // or reach the network. It reports what is present, not what could be fixed.
    const resolution = (if (provider) |selected_provider|
        credentials.resolveForProvider(alloc, secret_store, .stored, selected_provider, preferred)
    else
        credentials.resolvePreferring(alloc, secret_store, .stored, preferred)) catch |err| switch (err) {
        error.OutOfMemory => return err,
        // The store could not be interrogated, so its contents are unknown rather than absent.
        else => blk: {
            debug_trace.logf("auth", "status snapshot failed step=resolve err={s}", .{@errorName(err)});
            break :blk credentials.Resolution{ .stored_key_status = .unavailable };
        },
    };
    const connected = resolution.credential != null;
    if (resolution.credential) |loaded| {
        var credential = loaded;
        defer credential.deinit(alloc);
        return .{
            .active_source = credential.source,
            .connected = connected,
        };
    }
    return .{
        .required_source = if (provider) |selected_provider| requestedSource(selected_provider, preferred) else preferred,
        .failure = if (resolution.failure) |failure| classifyCredentialFailure(failure.source, failure.err) else null,
        .connected = connected,
    };
}

pub const View = struct {
    active_source: ?credentials.Source,
    available_inactive_sources: SourceSet,
    stored_key_status: credentials.StoredKeyReadStatus,
    onboarding_skipped: bool,

    pub fn activeSourceLabel(self: View) []const u8 {
        return sourceLabelOrMissing(self.active_source);
    }

    pub fn gatewayTeamStatus(self: View) GatewayTeamStatus {
        _ = self;
        return .unset;
    }
};

pub const GatewayCredential = struct {
    api_key: ?[]const u8,
    source: credentials.Source,
};

pub const ProviderCredentialSelection = union(enum) {
    unchanged,
    selected,
    missing,
    failed: credentials.LoadFailure,
};

pub const Runtime = struct {
    const Self = @This();

    api_key_validator: api_key_validator.Provider = api_key_validator.unavailable_provider,
    secret_store: host.SecretStore = host.unavailable_secret_store,
    auth_mode: credentials.AuthMode = .local,
    selected_credential: ?credentials.Credential = null,
    credential_failure: ?struct {
        failure: CredentialFailure,
        notice_claimed: bool,
    } = null,
    source_inventory: SourceSet = .empty,
    unavailable_sources: SourceSet = .empty,
    stored_key_status: credentials.StoredKeyReadStatus = .not_attempted,
    onboarding_skipped: bool = false,
    picker_active: bool = false,
    picker_selection: ?Choice = null,
    picker_include_skip: bool = false,
    picker_stage: PickerStage = .root,
    provider_picker_active: model_provider.ProviderId = .openrouter,
    api_key_input: std.ArrayList(u8) = .empty,
    /// The key field is rendered as a `/provider` column instead of the staged
    /// panel, so the composer keeps showing which path the user walked.
    api_key_inline: bool = false,
    api_key_returns_to_root: bool = false,
    api_key_save: ApiKeySaveRuntime = .{},
    /// Base URL typed for a user-supplied OpenAI-compatible endpoint. It is not
    /// a secret, so it is stored as plain bytes and cleared on exit.
    base_url_input: std.ArrayList(u8) = .empty,
    /// The base URL field is rendered as a `/provider` column, mirroring the
    /// inline API key field.
    base_url_inline: bool = false,
    inventory_refresh_task: ?*InventoryRefreshTask = null,
    provider_preparation: ?*ProviderPreparation = null,

    pub fn init(
        validator: api_key_validator.Provider,
        secret_store: host.SecretStore,
    ) Self {
        return initWithMode(validator, secret_store, .local);
    }

    pub fn initWithMode(
        validator: api_key_validator.Provider,
        secret_store: host.SecretStore,
        auth_mode: credentials.AuthMode,
    ) Self {
        return .{
            .api_key_validator = validator,
            .secret_store = secret_store,
            .auth_mode = auth_mode,
        };
    }

    /// Fieldwise initialization avoids retaining inactive credential and
    /// worker payloads in a static release-binary template.
    pub fn initInto(
        storage: *Self,
        validator: api_key_validator.Provider,
        secret_store: host.SecretStore,
    ) void {
        initIntoWithMode(storage, validator, secret_store, .local);
    }

    pub fn initIntoWithMode(
        storage: *Self,
        validator: api_key_validator.Provider,
        secret_store: host.SecretStore,
        auth_mode: credentials.AuthMode,
    ) void {
        comptime {
            if (std.meta.fields(Self).len != 22) {
                @compileError("update Runtime.initInto for the changed field set");
            }
        }
        storage.* = undefined;
        storage.api_key_validator = validator;
        storage.secret_store = secret_store;
        storage.auth_mode = auth_mode;
        storage.selected_credential = null;
        storage.credential_failure = null;
        storage.source_inventory = .empty;
        storage.unavailable_sources = .empty;
        storage.stored_key_status = .not_attempted;
        storage.onboarding_skipped = false;
        storage.picker_active = false;
        storage.picker_selection = null;
        storage.picker_include_skip = false;
        storage.picker_stage = .root;
        storage.provider_picker_active = .openrouter;
        storage.api_key_input = .empty;
        storage.api_key_inline = false;
        storage.api_key_returns_to_root = false;
        storage.api_key_save = .{};
        storage.base_url_input = .empty;
        storage.base_url_inline = false;
        storage.inventory_refresh_task = null;
        storage.provider_preparation = null;
    }

    pub fn deinit(self: *Self, alloc: Allocator) void {
        self.stopProviderPreparation();
        if (self.inventory_refresh_task) |task| task.deinit();
        self.inventory_refresh_task = null;
        self.api_key_save.deinit(alloc);
        self.exitApiKeyStage(alloc, .runtime_deinit);
        if (self.selected_credential) |*credential| credential.deinit(alloc);
        self.* = .{};
    }

    /// Borrows the current credential until this runtime replaces or releases it.
    pub fn gatewayCredential(self: *const Self) ?GatewayCredential {
        if (self.auth_mode == .host_managed) return .{
            .api_key = null,
            .source = .host_managed,
        };
        const credential = self.selected_credential orelse return null;
        return .{
            .api_key = credential.token,
            .source = credential.source,
        };
    }

    pub fn apiKey(self: *const Self) ?[]const u8 {
        const credential = self.gatewayCredential() orelse return null;
        return credential.api_key;
    }

    pub fn isHostManaged(self: *const Self) bool {
        return self.auth_mode == .host_managed;
    }

    pub fn authMode(self: *const Self) credentials.AuthMode {
        return self.auth_mode;
    }

    pub fn secretStore(self: *const Self) host.SecretStore {
        return self.secret_store;
    }

    pub fn modelCatalogAccess(self: *const Self) credentials.CatalogAccess {
        if (self.auth_mode == .host_managed) return .host_managed;
        if (self.credentialFailure()) |failure| {
            return credentials.catalogAccessAfterRefreshFailure(failure.source);
        }
        return credentials.catalogAccessAt(self.selected_credential, io_mod.milliTimestamp());
    }

    /// Records recovery state even when silent. Returns true only when claiming
    /// the first requested notice of this failure episode.
    pub fn recordCredentialFailure(
        self: *Self,
        failure: CredentialFailure,
        options: struct { notify: bool = true },
    ) bool {
        std.debug.assert(self.credentialSource() == failure.source);
        const same_failure = if (self.credential_failure) |current|
            current.failure.source == failure.source and current.failure.reason == failure.reason
        else
            false;
        if (!same_failure) self.credential_failure = .{ .failure = failure, .notice_claimed = false };
        if (!options.notify or self.credential_failure.?.notice_claimed) return false;
        self.credential_failure.?.notice_claimed = true;
        return true;
    }

    /// Recovery and catalog access concern only the selected credential.
    pub fn credentialFailure(self: *const Self) ?CredentialFailure {
        const episode = self.credential_failure orelse return null;
        return if (self.credentialSource() == episode.failure.source) episode.failure else null;
    }

    pub fn credentialSource(self: *const Self) ?credentials.Source {
        if (self.auth_mode == .host_managed) return .host_managed;
        const credential = self.selected_credential orelse return null;
        return credential.source;
    }

    /// An OpenRouter API key identifies one account and belongs to no tenant, so
    /// neither an account id nor a team is ever part of its authority.
    pub fn accountId(self: *const Self) ?[]const u8 {
        _ = self;
        return null;
    }

    pub fn credentialNeedsRefresh(self: *const Self) bool {
        return self.credentialNeedsRefreshAt(io_mod.milliTimestamp());
    }

    fn credentialNeedsRefreshAt(self: *const Self, now_ms: i64) bool {
        const credential = self.selected_credential orelse return false;
        return credential.needsRefreshAt(now_ms);
    }

    pub fn statusSnapshot(self: *const Self, provider: model_provider.ProviderId, preferred: ?credentials.Source) StatusSnapshot {
        return self.statusSnapshotAt(io_mod.milliTimestamp(), provider, preferred);
    }

    fn statusSnapshotAt(self: *const Self, _: i64, provider: model_provider.ProviderId, preferred: ?credentials.Source) StatusSnapshot {
        if (self.auth_mode == .host_managed) return .{
            .active_source = .host_managed,
            .connected = true,
        };
        const connected = self.source_inventory.contains(.openrouter_api_key) or
            self.source_inventory.contains(.stored_key);
        const credential = self.selected_credential orelse return .{
            .required_source = requestedSource(provider, preferred),
            .failure = if (self.credential_failure) |episode|
                if (model_provider.authorizesCredential(provider, episode.failure.source)) episode.failure else null
            else
                null,
            .connected = connected,
        };
        return .{
            .active_source = credential.source,
            .connected = connected,
        };
    }

    pub fn view(self: *const Self) View {
        const active_source = self.credentialSource();
        var available_inactive_sources = self.source_inventory;
        if (active_source) |source| available_inactive_sources.remove(source);

        return .{
            .active_source = active_source,
            .available_inactive_sources = available_inactive_sources,
            .stored_key_status = self.stored_key_status,
            .onboarding_skipped = self.onboarding_skipped,
        };
    }

    pub fn recordStartupStatus(
        self: *Self,
        stored_key_status: credentials.StoredKeyReadStatus,
        load_failure: ?credentials.LoadFailure,
        onboarding_skipped: bool,
    ) void {
        self.stored_key_status = stored_key_status;
        self.onboarding_skipped = onboarding_skipped;
        if (self.auth_mode == .local and self.selected_credential == null) {
            self.credential_failure = if (load_failure) |failure| .{
                .failure = classifyCredentialFailure(failure.source, failure.err),
                .notice_claimed = true,
            } else null;
        }
    }

    pub fn beginProviderPreparation(self: *Self, alloc: Allocator, input: ProviderPreparationInput) !void {
        if (self.provider_preparation != null) return error.ProviderPreparationInProgress;
        self.provider_preparation = try ProviderPreparation.start(alloc, self, input);
    }

    pub fn providerPreparationPending(self: *const Self) bool {
        return self.provider_preparation != null;
    }

    pub fn cancelProviderPreparation(self: *Self) bool {
        const task = self.provider_preparation orelse return false;
        task.requestCancel();
        return true;
    }

    pub fn takeProviderPreparation(self: *Self) ?*ProviderPreparation {
        const task = self.provider_preparation orelse return null;
        if (!task.done.load(.acquire)) return null;
        if (task.thread) |thread| thread.join();
        task.thread = null;
        self.provider_preparation = null;
        return task;
    }

    pub fn stopProviderPreparation(self: *Self) void {
        const task = self.provider_preparation orelse return;
        self.provider_preparation = null;
        task.deinit();
    }

    pub fn skipOnboarding(self: *Self) void {
        self.onboarding_skipped = true;
    }

    /// Records that the missing-credential guidance has already been shown.
    /// fx states the requirement once at startup; repeating it on every turn
    /// pushed the conversation down the transcript without adding information.
    pub fn noteCredentialGuidanceShown(self: *Self) void {
        self.onboarding_skipped = true;
    }

    pub fn refreshSourceInventory(self: *Self, alloc: Allocator) !void {
        if (self.auth_mode == .host_managed) {
            self.source_inventory = .empty;
            self.unavailable_sources = .empty;
            return;
        }
        try self.refreshSourceInventoryWithProbe(alloc, self, probeCredentialSource);
    }

    pub fn beginSourceInventoryRefresh(
        self: *Self,
        alloc: Allocator,
        action: InventoryRefreshAction,
    ) InventoryRefreshStart {
        return self.beginSourceInventoryRefreshWithDeps(alloc, action, .{
            .ctx = self,
            .probe = probeCredentialSource,
        });
    }

    fn beginSourceInventoryRefreshWithDeps(
        self: *Self,
        alloc: Allocator,
        action: InventoryRefreshAction,
        deps: InventoryRefreshDeps,
    ) InventoryRefreshStart {
        if (self.inventory_refresh_task != null) return .busy;
        self.inventory_refresh_task = InventoryRefreshTask.start(
            alloc,
            action,
            deps,
        ) catch return .failed;
        return .started;
    }

    pub fn takeSourceInventoryRefresh(
        self: *Self,
    ) ?InventoryRefreshResult {
        const task = self.inventory_refresh_task orelse return null;
        if (!task.done.load(.acquire)) return null;
        if (task.thread) |thread| {
            thread.join();
            task.thread = null;
        }
        self.inventory_refresh_task = null;
        defer task.deinit();
        if (task.failure != null or task.inventory == null) {
            return .{ .failed = task.action };
        }
        self.applySourceInventory(task.inventory.?);
        return .{ .ready = task.action };
    }

    pub fn sourceInventoryRefreshActive(self: *const Self) bool {
        return self.inventory_refresh_task != null;
    }

    fn refreshSourceInventoryWithProbe(
        self: *Self,
        alloc: Allocator,
        ctx: ?*anyopaque,
        probe: SourceProbeFn,
    ) !void {
        self.applySourceInventory(try SourceInventory.detect(alloc, ctx, probe));
    }

    fn applySourceInventory(self: *Self, inventory: SourceInventory) void {
        self.source_inventory = inventory.available;
        self.unavailable_sources = inventory.unavailable;
        if (!inventory.available.contains(.stored_key) and !inventory.unavailable.contains(.stored_key)) {
            self.stored_key_status = .not_found;
        }
        if (self.credentialSource()) |source| {
            if (source != .host_managed and !inventory.unavailable.contains(source)) self.source_inventory.insert(source);
        } else if (self.credential_failure) |episode| {
            const failure = episode.failure;
            if (!inventory.available.contains(failure.source) and !inventory.unavailable.contains(failure.source)) {
                debug_trace.logf("auth", "credential load failure cleared source={t} reason=source_absent", .{failure.source});
                self.credential_failure = null;
            }
        }
    }

    pub fn openPicker(self: *Self, alloc: Allocator) void {
        self.openPickerForProvider(alloc, .openrouter);
    }

    pub fn openPickerForProvider(
        self: *Self,
        alloc: Allocator,
        active_provider: model_provider.ProviderId,
    ) void {
        self.provider_picker_active = active_provider;
        self.openPickerWithSkip(alloc, false);
    }

    fn openPickerWithSkip(self: *Self, alloc: Allocator, include_skip: bool) void {
        self.exitApiKeyStage(alloc, .screen_replacement);
        self.picker_active = true;
        self.picker_include_skip = include_skip;
        self.picker_stage = .root;
        self.picker_selection = self.pickerView().choiceAt(0);
    }

    pub fn pickerView(self: *const Self) PickerView {
        return .{
            .active = self.picker_active,
            .available_sources = self.source_inventory,
            .unavailable_sources = self.unavailable_sources,
            .selected_choice = self.picker_selection,
            .active_source = self.credentialSource(),
            .active_provider = self.provider_picker_active,
            .include_skip = self.picker_include_skip,
            .stage = self.picker_stage,
            .api_key_mask_count = self.apiKeyMaskCount(),
            .api_key_inline = self.api_key_inline,
            .api_key_provider_label = provider_catalog.label(self.provider_picker_active),
            .base_url_text = self.base_url_input.items,
            .base_url_inline = self.base_url_inline,
        };
    }

    pub fn movePicker(self: *Self, delta: i32) bool {
        if (!self.picker_active or delta == 0) return false;
        const picker = self.pickerView();
        const choice_count = picker.choiceCount();
        if (choice_count < 2) return false;
        var next_index = picker.selectedIndex();
        for (0..choice_count) |_| {
            next_index = if (delta < 0)
                if (next_index == 0) choice_count - 1 else next_index - 1
            else if (next_index + 1 == choice_count)
                0
            else
                next_index + 1;
            const choice = picker.choiceAt(next_index) orelse continue;
            if (!picker.choiceEnabled(choice)) continue;
            self.picker_selection = choice;
            return true;
        }
        return false;
    }

    fn openConnectionPicker(self: *Self, alloc: Allocator) void {
        self.exitApiKeyStage(alloc, .screen_replacement);
        self.picker_active = true;
        self.picker_stage = .connections;
        self.picker_selection = self.pickerView().choiceAt(0);
    }

    pub fn openProviderPicker(
        self: *Self,
        alloc: Allocator,
        active_provider: model_provider.ProviderId,
    ) void {
        self.exitApiKeyStage(alloc, .screen_replacement);
        self.picker_active = true;
        self.picker_include_skip = false;
        self.picker_stage = .provider;
        self.provider_picker_active = active_provider;
        self.picker_selection = .{ .provider = active_provider };
    }

    pub fn openSwitchCredentialPicker(self: *Self, alloc: Allocator) void {
        self.exitApiKeyStage(alloc, .screen_replacement);
        self.picker_stage = .switch_credential;
        const active_source = self.credentialSource();
        self.picker_selection = if (active_source) |source|
            if (self.source_inventory.contains(source))
                .{ .source = source }
            else
                self.pickerView().choiceAt(0)
        else
            self.pickerView().choiceAt(0);
    }

    pub fn openApiKeyPicker(self: *Self, alloc: Allocator) void {
        self.openApiKeyPickerWithParent(alloc, false);
    }

    pub fn openApiKeyPickerFromRoot(self: *Self, alloc: Allocator) void {
        self.openApiKeyPickerWithParent(alloc, true);
    }

    /// Opens the staged key field for a named provider, so the field labels the
    /// right provider and the save validates against it rather than the default.
    pub fn openApiKeyPickerForProvider(
        self: *Self,
        alloc: Allocator,
        provider: model_provider.ProviderId,
    ) void {
        self.provider_picker_active = provider;
        self.openApiKeyPickerWithParent(alloc, false);
    }

    pub fn openApiKeyPickerFromRootForProvider(
        self: *Self,
        alloc: Allocator,
        provider: model_provider.ProviderId,
    ) void {
        self.provider_picker_active = provider;
        self.openApiKeyPickerWithParent(alloc, true);
    }

    fn openApiKeyPickerWithParent(self: *Self, alloc: Allocator, returns_to_root: bool) void {
        self.exitApiKeyStage(alloc, .screen_replacement);
        self.picker_active = true;
        self.picker_stage = .api_key;
        self.picker_selection = null;
        self.api_key_returns_to_root = returns_to_root;
    }

    /// Opens the key field for the inline `/provider` picker. The stage is the
    /// same one the staged panel uses, so entry, saving, and cancelling all
    /// keep working; only the rendering differs.
    pub fn openApiKeyPickerInline(
        self: *Self,
        alloc: Allocator,
        provider: model_provider.ProviderId,
    ) void {
        self.provider_picker_active = provider;
        self.openApiKeyPickerWithParent(alloc, false);
        self.api_key_inline = true;
    }

    pub fn apiKeyInlineActive(self: *const Self) bool {
        return self.apiKeyEntryActive() and self.api_key_inline;
    }

    pub fn apiKeyMaskCount(self: *const Self) usize {
        return @min(self.api_key_input.items.len, max_api_key_mask_glyphs);
    }

    /// Leaves the key field without saving, zeroing whatever was typed.
    pub fn cancelInlineApiKeyEntry(self: *Self, alloc: Allocator) void {
        if (!self.apiKeyInlineActive()) return;
        self.exitApiKeyStage(alloc, .screen_replacement);
        self.picker_active = false;
        self.picker_stage = .root;
    }

    pub fn apiKeyEntryActive(self: *const Self) bool {
        return self.picker_active and self.picker_stage == .api_key;
    }

    pub fn appendApiKeyByte(self: *Self, alloc: Allocator, byte: u8) !bool {
        if (!self.apiKeyEntryActive()) return false;
        if (self.api_key_input.items.len >= max_api_key_entry_bytes) return true;
        if (byte < 0x20 or byte == 0x7f) return true;
        // Reserve the entry ceiling up front so growth never abandons an
        // unzeroed buffer holding part of the key.
        try self.api_key_input.ensureTotalCapacityPrecise(alloc, max_api_key_entry_bytes);
        self.api_key_input.appendAssumeCapacity(byte);
        return true;
    }

    /// Appends a whole pasted run to the key field. Terminals routinely append a
    /// trailing newline to a bracketed paste, and a pasted key is one line, so a
    /// single trailing line break is dropped rather than stored. Returns whether
    /// the paste was consumed by this field.
    pub fn appendApiKeyPaste(self: *Self, alloc: Allocator, bytes: []const u8) !bool {
        if (!self.apiKeyEntryActive()) return false;
        var trimmed = bytes;
        if (trimmed.len != 0 and trimmed[trimmed.len - 1] == '\n') trimmed = trimmed[0 .. trimmed.len - 1];
        if (trimmed.len != 0 and trimmed[trimmed.len - 1] == '\r') trimmed = trimmed[0 .. trimmed.len - 1];
        try self.api_key_input.ensureTotalCapacityPrecise(alloc, max_api_key_entry_bytes);
        for (trimmed) |byte| {
            if (byte < 0x20 or byte == 0x7f) continue;
            if (self.api_key_input.items.len >= max_api_key_entry_bytes) break;
            self.api_key_input.appendAssumeCapacity(byte);
        }
        return true;
    }

    pub fn deleteApiKeyByte(self: *Self) bool {
        if (!self.apiKeyEntryActive()) return false;
        if (self.api_key_input.items.len > 0) _ = self.api_key_input.pop();
        return true;
    }

    /// Hands the entered key to a worker and pops the stage immediately. The key
    /// store write can block for seconds on a locked keychain, and the gateway
    /// check is a network round trip; neither may run on the event loop.
    ///
    /// `validator_override` lets the caller check the key against the provider
    /// the entry was opened for. The runtime owns no provider set, so it cannot
    /// resolve one itself; `null` falls back to the injected default.
    pub fn beginApiKeySave(
        self: *Self,
        alloc: Allocator,
        validator_override: ?api_key_validator.Provider,
    ) ApiKeySaveStart {
        return self.beginApiKeySaveWithDeps(alloc, .{
            .ctx = self,
            .validator = validator_override orelse self.api_key_validator,
            .stored_source = credentials.storedSourceFor(self.provider_picker_active) orelse .stored_key,
            .store = storeRuntimeSecret,
            .loader = loadRuntimeCredentialSource,
        });
    }

    fn beginApiKeySaveWithDeps(self: *Self, alloc: Allocator, deps: ApiKeySaveDeps) ApiKeySaveStart {
        if (!self.apiKeyEntryActive() or self.api_key_input.items.len == 0) return .empty;

        // Ownership moves to the worker, so the stage exit below has nothing to zero.
        const key = self.api_key_input;
        self.api_key_input = .empty;

        const returns_to_root = self.api_key_returns_to_root;
        self.exitApiKeyStage(alloc, .saved);
        self.picker_active = returns_to_root;
        if (!returns_to_root or self.picker_include_skip) {
            self.picker_stage = .root;
            self.picker_selection = if (returns_to_root) .{ .action = .setup } else null;
        } else {
            self.picker_stage = .connections;
            self.picker_selection = .{ .action = .setup };
        }

        return if (self.api_key_save.start(alloc, key, deps)) .started else .busy;
    }

    pub fn apiKeySaveInFlight(self: *const Self) bool {
        return self.api_key_save.isSaving();
    }

    /// Applies a finished save on the main thread. Adopting the credential here
    /// keeps `selected_credential` off the worker.
    pub fn takeApiKeySaveResult(self: *Self, alloc: Allocator) ?ApiKeySaveResult {
        var outcome = self.api_key_save.take(alloc) orelse return null;
        return switch (outcome) {
            .gateway_refused => .gateway_refused,
            .gateway_unavailable => .gateway_unavailable,
            .store_failed => .store_failed,
            .reload_failed => .reload_failed,
            .loaded => |*credential| blk: {
                var owned = credential.*;
                outcome = .reload_failed;
                defer owned.deinit(alloc);
                break :blk .{ .saved = self.adoptCredential(alloc, &owned) };
            },
        };
    }

    pub fn popPickerStage(self: *Self, alloc: Allocator) bool {
        if (!self.picker_active) return false;
        const stage = self.picker_stage;
        if (stage == .root) {
            self.closePicker(alloc);
            return true;
        }
        if (stage == .provider) {
            self.picker_stage = .root;
            self.picker_selection = .{ .action = .switch_provider };
            return true;
        }
        if (stage == .connections) {
            self.picker_stage = .root;
            self.picker_selection = .{ .action = .connections };
            return true;
        }

        if (stage == .api_key) {
            const returns_to_root = self.api_key_returns_to_root;
            self.exitApiKeyStage(alloc, .cancel);
            if (!returns_to_root) {
                self.picker_active = false;
                self.picker_stage = .root;
                self.picker_selection = null;
                return true;
            }
            if (!self.picker_include_skip) {
                self.picker_stage = .connections;
                self.picker_selection = .{ .action = .setup };
                return true;
            }
        }

        self.picker_stage = .root;
        self.picker_selection = .{ .action = switch (stage) {
            .root => unreachable,
            .connections => unreachable,
            .provider => unreachable,
            .base_url, .api_key => .setup,
            .switch_credential => .switch_credential,
        } };
        return true;
    }

    pub fn closePicker(self: *Self, alloc: Allocator) void {
        self.exitApiKeyStage(alloc, .screen_replacement);
        self.picker_active = false;
        self.picker_stage = .root;
    }

    pub fn takePickerChoice(self: *Self, alloc: Allocator) ?Choice {
        if (!self.picker_active) return null;
        if (self.picker_stage == .api_key or self.picker_stage == .base_url) return null;
        const choice = self.picker_selection;
        const selected = choice orelse return null;
        if (!self.pickerView().choiceEnabled(selected)) return null;

        switch (self.picker_stage) {
            .api_key => {},
            .base_url => {},
            .connections => switch (selected) {
                .action => |action| switch (action) {
                    .setup => {},
                    .connections,
                    .switch_credential,
                    .switch_provider,
                    .automatic,
                    => unreachable,
                },
                .provider, .source => unreachable,
            },
            .provider => switch (selected) {
                .provider => self.closePicker(alloc),
                .source, .action => unreachable,
            },
            .root => switch (selected) {
                .provider => unreachable,
                .source => self.closePicker(alloc),
                .action => |action| switch (action) {
                    .connections => {
                        self.openConnectionPicker(alloc);
                        return null;
                    },
                    .switch_provider => {},
                    .switch_credential => {
                        self.openSwitchCredentialPicker(alloc);
                        return null;
                    },
                    .setup => {},
                    // Only reachable from the switch screen, never the root.
                    .automatic => unreachable,
                },
            },
            .switch_credential => switch (selected) {
                .source => self.closePicker(alloc),
                // Automatic is the only action this stage offers; the app
                // handler clears the stored choice and closes the picker.
                .action => |action| std.debug.assert(action == .automatic),
                .provider => unreachable,
            },
        }
        return choice;
    }

    /// Moves the credential into this session and returns whether any observed
    /// credential field changed. Callers that distinguish secret rotation from
    /// authority replacement should use `adoptPreparedCredential`.
    pub fn adoptCredential(self: *Self, alloc: Allocator, credential: *credentials.Credential) bool {
        return self.adoptPreparedCredential(alloc, credential) != .none;
    }

    /// Moves one complete prepared credential into this runtime. The result
    /// separates token/refresh-deadline rotation from provider, source,
    /// account, or team authority changes so callers can preserve valid caches.
    pub fn adoptPreparedCredential(
        self: *Self,
        alloc: Allocator,
        credential: *credentials.Credential,
    ) auth_transition.CredentialChange {
        const change = self.preparedCredentialChange(credential.*);
        if (change == .authority) _ = self.cancelProviderPreparation();
        const source = credential.source;
        if (self.selected_credential) |*selected| selected.deinit(alloc);

        self.selected_credential = credential.*;
        self.credential_failure = null;
        credential.token = &.{};
        self.source_inventory.insert(source);
        self.unavailable_sources.remove(source);
        if (source == .stored_key) self.stored_key_status = .not_attempted;
        return change;
    }

    pub fn preparedCredentialChange(
        self: *const Self,
        credential: credentials.Credential,
    ) auth_transition.CredentialChange {
        return if (self.selected_credential) |selected|
            auth_transition.decideCredentialChange(
                credentialAuthorityFacts(selected),
                credentialAuthorityFacts(credential),
                !std.mem.eql(u8, selected.token, credential.token),
            )
        else
            .authority;
    }

    fn selectSourceWithLoader(
        self: *Self,
        alloc: Allocator,
        source: credentials.Source,
        ctx: ?*anyopaque,
        loader: CredentialLoaderFn,
    ) !?bool {
        var credential = (try loader(ctx, alloc, source)) orelse return null;
        defer credential.deinit(alloc);
        if (credential.source != source) return error.CredentialSourceMismatch;
        return self.adoptCredential(alloc, &credential);
    }

    pub fn selectSource(self: *Self, alloc: Allocator, source: credentials.Source) !?bool {
        return self.selectSourceWithLoader(alloc, source, self, loadRuntimeCredentialSource);
    }

    pub fn selectForProvider(
        self: *Self,
        alloc: Allocator,
        provider: model_provider.ProviderId,
        preferred: ?credentials.Source,
    ) Allocator.Error!ProviderCredentialSelection {
        if (self.auth_mode == .host_managed or
            (provider != .configured and model_provider.authorizesCredential(provider, self.credentialSource()))) return .unchanged;

        var resolution = credentials.resolveForProvider(
            alloc,
            self.secret_store,
            .stored,
            provider,
            preferred,
        ) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return .{ .failed = .{
                .source = requestedSource(provider, preferred) orelse .openrouter_api_key,
                .err = err,
            } };
        };
        defer if (resolution.credential) |*credential| credential.deinit(alloc);
        if (resolution.credential) |*credential| {
            return if (self.adoptCredential(alloc, credential)) .selected else .unchanged;
        }
        if (resolution.failure) |failure| return .{ .failed = failure };
        return .missing;
    }

    /// An OpenRouter key never expires, so there is nothing to refresh in the
    /// background. The function is retained so callers have one spelling for
    /// "make sure the selected key is the one on disk".
    pub fn refreshSelectedCredentialIfNeeded(
        self: *Self,
        alloc: Allocator,
    ) !auth_transition.CredentialChange {
        const source = self.credentialSource() orelse return .none;
        const loaded = (try credentials.loadSource(alloc, self.secret_store, source)) orelse
            return error.CredentialRefreshUnavailable;
        var credential = loaded;
        defer credential.deinit(alloc);
        return self.adoptPreparedCredential(alloc, &credential);
    }

    /// Drops the current selection and re-runs precedence after the user clears
    /// a remembered credential source.
    pub fn reselectByPrecedence(self: *Self, alloc: Allocator) !bool {
        return self.reselectByPrecedenceWithDeps(alloc, self, probeCredentialSource, loadRuntimeCredentialSource);
    }

    /// Clears the runtime's remembered source after the key it pointed at is
    /// gone, so resolution returns to plain precedence instead of re-selecting a
    /// source that no longer resolves. Returns false when nothing changed.
    pub fn forgetRememberedSource(self: *Self, alloc: Allocator) bool {
        const had_selection = self.selected_credential != null;
        if (self.selected_credential) |*credential| credential.deinit(alloc);
        self.selected_credential = null;
        self.credential_failure = null;
        self.stored_key_status = .not_attempted;
        self.source_inventory = .empty;
        self.unavailable_sources = .empty;
        return had_selection;
    }

    fn reselectByPrecedenceWithDeps(
        self: *Self,
        alloc: Allocator,
        ctx: ?*anyopaque,
        probe: SourceProbeFn,
        loader: CredentialLoaderFn,
    ) !bool {
        const previous = self.credentialSource();
        if (self.selected_credential) |*credential| credential.deinit(alloc);
        self.selected_credential = null;
        self.credential_failure = null;

        try self.refreshSourceInventoryWithProbe(alloc, ctx, probe);
        for (all_credential_sources) |source| {
            if (source == .stored_key or source == .groq_stored_key) continue;
            if (!self.source_inventory.contains(source)) continue;
            if (try self.selectSourceWithLoader(alloc, source, ctx, loader) != null) {
                return self.credentialSource() != previous;
            }
            self.source_inventory.remove(source);
        }
        self.onboarding_skipped = false;
        return previous != null;
    }

    pub fn reconcileAfterFxLoginLogout(self: *Self, alloc: Allocator) !bool {
        return self.reconcileAfterFxLoginLogoutWithDeps(
            alloc,
            self,
            probeCredentialSource,
            loadRuntimeCredentialSource,
        );
    }

    fn reconcileAfterFxLoginLogoutWithDeps(
        self: *Self,
        alloc: Allocator,
        ctx: ?*anyopaque,
        probe: SourceProbeFn,
        loader: CredentialLoaderFn,
    ) !bool {
        const login_was_active = self.credentialSource() == .openrouter_api_key;
        if (login_was_active) {
            if (self.selected_credential) |*credential| credential.deinit(alloc);
            self.selected_credential = null;
            self.credential_failure = null;
        }

        try self.refreshSourceInventoryWithProbe(alloc, ctx, probe);
        if (!login_was_active) return false;

        for (all_credential_sources) |source| {
            if (source == .stored_key or source == .groq_stored_key) continue;
            if (!self.source_inventory.contains(source)) continue;
            if (try self.selectSourceWithLoader(alloc, source, ctx, loader) != null) return true;
            self.source_inventory.remove(source);
        }

        self.onboarding_skipped = false;
        return true;
    }

    fn currentTeamChoice(self: *const Self) ?Choice {
        const picker = self.pickerView();
        for (picker.teams, 0..) |_, index| {
            if (picker.teamIsCurrent(index)) return .{ .team = index };
        }
        return null;
    }

    fn resetTeamPickerSelection(self: *Self) void {
        self.picker_selection = if (self.team_query.items.len == 0)
            self.currentTeamChoice() orelse self.pickerView().choiceAt(0)
        else
            self.pickerView().choiceAt(0);
    }

    fn exitBaseUrlStage(self: *Self, alloc: Allocator) void {
        self.base_url_inline = false;
        if (self.base_url_input.capacity > 0) {
            alloc.free(self.base_url_input.allocatedSlice());
            self.base_url_input = .empty;
        }
    }

    /// Opens the base URL field for the inline `/provider` picker, used when the
    /// user selects the OpenAI-compatible provider.
    pub fn openBaseUrlPickerInline(self: *Self, alloc: Allocator, provider: model_provider.ProviderId) void {
        self.provider_picker_active = provider;
        self.exitApiKeyStage(alloc, .screen_replacement);
        self.exitBaseUrlStage(alloc);
        self.picker_active = true;
        self.picker_stage = .base_url;
        self.picker_selection = null;
        self.base_url_inline = true;
    }

    pub fn baseUrlEntryActive(self: *const Self) bool {
        return self.picker_active and self.picker_stage == .base_url;
    }

    /// True when either inline entry field owns the next byte. Bracketed paste
    /// and semantic keys are claimed by whichever field is active, so both the
    /// API key and the base URL behave the same way.
    pub fn inlineEntryActive(self: *const Self) bool {
        return self.apiKeyEntryActive() or self.baseUrlEntryActive();
    }

    /// Leaves the base URL field without saving. Used after the URL has been
    /// accepted so later typing reaches the picker instead of the URL buffer,
    /// and so the legacy "Setup" panel does not surface at the root stage.
    pub fn endBaseUrlEntry(self: *Self, alloc: Allocator) void {
        self.exitBaseUrlStage(alloc);
        self.picker_active = false;
        self.picker_stage = .root;
    }

    pub fn baseUrlInput(self: *const Self) []const u8 {
        return self.base_url_input.items;
    }

    pub fn appendBaseUrlByte(self: *Self, alloc: Allocator, byte: u8) !bool {
        if (!self.baseUrlEntryActive()) return false;
        if (self.base_url_input.items.len >= max_base_url_entry_bytes) return true;
        if (byte < 0x20 or byte == 0x7f) return true;
        try self.base_url_input.ensureTotalCapacityPrecise(alloc, max_base_url_entry_bytes);
        self.base_url_input.appendAssumeCapacity(byte);
        return true;
    }

    pub fn appendBaseUrlPaste(self: *Self, alloc: Allocator, bytes: []const u8) !bool {
        if (!self.baseUrlEntryActive()) return false;
        try self.base_url_input.ensureTotalCapacityPrecise(alloc, max_base_url_entry_bytes);
        for (bytes) |byte| {
            if (byte < 0x20 or byte == 0x7f) continue;
            if (self.base_url_input.items.len >= max_base_url_entry_bytes) break;
            self.base_url_input.appendAssumeCapacity(byte);
        }
        return true;
    }

    pub fn deleteBaseUrlByte(self: *Self) bool {
        if (!self.baseUrlEntryActive()) return false;
        if (self.base_url_input.items.len > 0) _ = self.base_url_input.pop();
        return true;
    }

    /// Copies the typed base URL into owned storage and clears the field. Null
    /// when the field is empty.
    pub fn takeBaseUrlInput(self: *Self, alloc: Allocator) !?[]u8 {
        if (self.base_url_input.items.len == 0) return null;
        const owned = try alloc.dupe(u8, self.base_url_input.items);
        self.base_url_input.clearRetainingCapacity();
        return owned;
    }

    fn exitApiKeyStage(self: *Self, alloc: Allocator, reason: ApiKeyExitReason) void {
        self.exitBaseUrlStage(alloc);
        self.api_key_inline = false;
        const byte_count = self.api_key_input.items.len;
        if (self.api_key_input.capacity > 0) {
            const allocated = self.api_key_input.allocatedSlice();
            secret.zeroAndFree(alloc, allocated);
            self.api_key_input = .empty;
        }
        self.api_key_returns_to_root = false;
        if (byte_count > 0) {
            debug_trace.logf(
                "auth",
                "api key entry cleared reason={s} bytes={d}",
                .{ @tagName(reason), byte_count },
            );
        }
    }
};

fn probeCredentialSource(raw_context: ?*anyopaque, _: Allocator, source: credentials.Source) !bool {
    const self: *Runtime = @ptrCast(@alignCast(raw_context.?));
    if (self.auth_mode == .host_managed) return false;
    return switch (credentials.sourcePresence(self.secret_store, source)) {
        .present => true,
        .missing => false,
        .unavailable => error.CredentialStorageUnavailable,
    };
}

fn loadCredentialSource(_: ?*anyopaque, alloc: Allocator, source: credentials.Source) !?credentials.Credential {
    return credentials.loadSource(alloc, host.unavailable_secret_store, source);
}

fn loadRuntimeCredentialSource(raw: ?*anyopaque, alloc: Allocator, source: credentials.Source) !?credentials.Credential {
    const self: *Runtime = @ptrCast(@alignCast(raw.?));
    // Interactive selection paths run on keypresses; a source that cannot be
    // read must report as "unavailable" (the callers all explain that) rather
    // than ride a `try` chain out of the event loop. `resolve()` keeps its own
    // error handling for startup status reporting.
    return credentials.loadSource(alloc, self.secret_store, source) catch |err| switch (err) {
        error.OutOfMemory => err,
        else => {
            debug_trace.logf("auth", "credential load failed source={t} err={s}", .{ source, @errorName(err) });
            return null;
        },
    };
}

fn storeRuntimeSecret(
    raw: ?*anyopaque,
    alloc: Allocator,
    source: credentials.Source,
    value: []const u8,
) !void {
    const self: *Runtime = @ptrCast(@alignCast(raw.?));
    const slot = credentials.secretSlotFor(source) orelse return error.StoredKeyWriteFailed;
    return self.secret_store.storeFor(alloc, slot, value);
}

fn storeUnavailableSecret(_: ?*anyopaque, _: Allocator, _: credentials.Source, _: []const u8) !void {
    return error.StoredKeyWriteFailed;
}

fn displayTeam(credential: credentials.Credential) ?[]const u8 {
    return credential.team_slug orelse credential.team_id;
}

fn takeDisplayTeam(alloc: Allocator, credential: *credentials.Credential) ?[]u8 {
    if (credential.team_slug) |team| {
        if (credential.team_id) |id| alloc.free(id);
        credential.team_id = null;
        return team;
    }
    const team = credential.team_id;
    credential.team_id = null;
    return team;
}

fn gatewaySourceCount(sources: SourceSet) usize {
    var count: usize = 0;
    for (all_credential_sources) |source| {
        if (!sources.contains(source)) continue;
        count += 1;
    }
    return count;
}

fn gatewaySourceAtIndex(sources: SourceSet, wanted_index: usize) ?credentials.Source {
    var index: usize = 0;
    for (all_credential_sources) |source| {
        if (!sources.contains(source)) continue;
        if (index == wanted_index) return source;
        index += 1;
    }
    return null;
}

fn credentialAuthorityFacts(credential: credentials.Credential) auth_transition.CredentialAuthorityFacts {
    return .{
        .provider = .openrouter,
        .source = credential.source,
        .account_id = null,
        .team = null,
    };
}

fn makeTestCredential(
    alloc: Allocator,
    token: []const u8,
    source: credentials.Source,
) !credentials.Credential {
    const owned_token = try alloc.dupe(u8, token);
    errdefer secret.zeroAndFree(alloc, owned_token);
    return .{ .token = owned_token, .source = source };
}

const ApiKeySaveFixture = struct {
    validation: api_key_validator.Result = .accepted,
    fail_store: bool = false,
    fail_load: bool = false,
    /// Holds the worker inside `store` so a test can observe the in-flight
    /// window without racing it.
    gate: ?*std.atomic.Value(bool) = null,
    validate_calls: usize = 0,
    store_calls: usize = 0,
    load_calls: usize = 0,

    fn validate(raw_ctx: ?*anyopaque, _: Allocator, _: []const u8) api_key_validator.Result {
        const self: *@This() = @ptrCast(@alignCast(raw_ctx.?));
        self.validate_calls += 1;
        return self.validation;
    }

    fn validator(self: *@This()) api_key_validator.Provider {
        return .{
            .context = self,
            .validate_fn = validate,
        };
    }

    fn secretStore(self: *@This()) host.SecretStore {
        return .{
            .context = self,
            .backend_label = "test credential store",
            .is_disabled_fn = secretStoreIsDisabled,
            .load_fn = secretStoreLoad,
            .store_fn = secretStoreWrite,
            .store_interactive_fn = secretStoreInteractiveWrite,
        };
    }

    fn secretStoreIsDisabled(_: ?*anyopaque) bool {
        return false;
    }

    fn secretStoreLoad(
        raw_ctx: ?*anyopaque,
        alloc: Allocator,
        _: host.SecretSlot,
    ) host.SecretStoreLoadError!?[]u8 {
        const self: *@This() = @ptrCast(@alignCast(raw_ctx.?));
        self.load_calls += 1;
        if (self.fail_load) return error.StoredKeyUnreadable;
        return try alloc.dupe(u8, "loaded-key");
    }

    fn secretStoreWrite(
        raw_ctx: ?*anyopaque,
        _: Allocator,
        _: host.SecretSlot,
        _: []const u8,
    ) host.SecretStoreWriteError!void {
        const self: *@This() = @ptrCast(@alignCast(raw_ctx.?));
        if (self.gate) |gate| while (!gate.load(.seq_cst)) {};
        self.store_calls += 1;
        if (self.fail_store) return error.StoredKeyWriteFailed;
    }

    fn secretStoreInteractiveWrite(
        _: ?*anyopaque,
        _: host.SecretSlot,
    ) host.SecretStoreWriteError!bool {
        return false;
    }

    fn store(raw_ctx: ?*anyopaque, _: Allocator, _: credentials.Source, _: []const u8) !void {
        const self: *@This() = @ptrCast(@alignCast(raw_ctx.?));
        if (self.gate) |gate| while (!gate.load(.seq_cst)) {};
        self.store_calls += 1;
        if (self.fail_store) return error.TestStoreFailed;
    }

    fn load(
        raw_ctx: ?*anyopaque,
        alloc: Allocator,
        source: credentials.Source,
    ) !?credentials.Credential {
        const self: *@This() = @ptrCast(@alignCast(raw_ctx.?));
        self.load_calls += 1;
        if (self.fail_load) return error.TestLoadFailed;
        return try makeTestCredential(alloc, "loaded-key", source);
    }
};

fn enterTestApiKey(runtime: *Runtime, alloc: Allocator, value: []const u8) !void {
    runtime.openApiKeyPicker(alloc);
    for (value) |byte| try std.testing.expect(try runtime.appendApiKeyByte(alloc, byte));
}

fn expectApiKeyAllocationCleared(
    runtime: *const Runtime,
    backing: []const u8,
    sentinel: []const u8,
) !void {
    try std.testing.expectEqual(@as(usize, 0), runtime.api_key_input.items.len);
    try std.testing.expectEqual(@as(usize, 0), runtime.api_key_input.capacity);
    try std.testing.expect(std.mem.indexOf(u8, backing, sentinel) == null);
}

const LogoutFixture = struct {
    existing: SourceSet,
    load_count: usize = 0,

    fn probe(ctx: ?*anyopaque, _: Allocator, source: credentials.Source) !bool {
        const self: *@This() = @ptrCast(@alignCast(ctx.?));
        return self.existing.contains(source);
    }

    fn load(ctx: ?*anyopaque, alloc: Allocator, source: credentials.Source) !?credentials.Credential {
        const self: *@This() = @ptrCast(@alignCast(ctx.?));
        self.load_count += 1;
        if (!self.existing.contains(source)) return null;
        return try makeTestCredential(
            alloc,
            @tagName(source),
            source,
        );
    }
};
