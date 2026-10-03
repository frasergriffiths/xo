const std = @import("std");
const builtin = @import("builtin");
const model_provider = @import("../config/model_provider.zig");
const http_pool = @import("../shared/http_pool.zig");

const Allocator = std.mem.Allocator;

/// The strings a built OpenAI-compatible definition borrows. The caller owns
/// them and must keep them alive for as long as the definition is used.
pub const OpenAiCompatibleDefinition = struct {
    definition: @import("../config/configured_provider.zig").Definition,
    id: []u8,
    bearer: []u8,

    pub fn deinit(self: OpenAiCompatibleDefinition, alloc: Allocator) void {
        alloc.free(self.id);
        alloc.free(self.bearer);
    }
};

/// Builds the OpenAI-compatible endpoint definition from a base URL. An empty
/// URL yields null, because without an address there is no route to build.
///
/// The returned definition borrows `base_url`, so the caller must keep that
/// buffer alive for as long as the definition is used. The returned `id` and
/// `bearer` are owned by the returned value.
///
/// This is the single place that knows what an OpenAI-compatible endpoint is,
/// so the interactive session and the noninteractive commands describe the
/// same endpoint from the same settings value.
pub fn buildOpenAiCompatibleDefinition(
    alloc: Allocator,
    base_url: []const u8,
) Allocator.Error!?OpenAiCompatibleDefinition {
    const gateway = @import("../../gateway/openai_compatible.zig");
    if (base_url.len == 0) return null;
    const id = try alloc.dupe(u8, "openai-compatible");
    errdefer alloc.free(id);
    const bearer = try alloc.dupe(u8, gateway.default_api_key_env);
    errdefer alloc.free(bearer);
    return .{
        .definition = .{
            .id = id,
            .protocol = .@"openai-chat-completions",
            .base_url = base_url,
            .auth = .{ .bearer = bearer },
            .credential_sources = &.{ .openai_compatible_api_key, .openai_compatible_key },
            .tool_choice_mode = .send,
            .upstream_routing = false,
            .headers = &.{},
            .is_builtin_override = false,
            .reviewer_model = null,
            .model_metadata = &.{},
        },
        .id = id,
        .bearer = bearer,
    };
}

pub const Runtime = struct {
    const Self = @This();

    alloc: Allocator,
    active_provider: model_provider.ProviderId = .openrouter,
    model: std.ArrayList(u8) = .empty,
    definitions: @import("../config/configured_provider.zig").Registry = .{},
    /// Owned base URL for the OpenAI-compatible endpoint, or null when the
    /// profile has not configured one. Freed in deinit.
    openai_compatible_base_url: ?[]u8 = null,
    /// Owned provider id string for the OpenAI-compatible definition.
    openai_compatible_id: ?[]u8 = null,
    /// Owned bearer slot name for the OpenAI-compatible definition.
    openai_compatible_bearer: ?[]u8 = null,
    /// Definition built from the base URL above. Valid while the three owned
    /// strings live; rebuilt whole whenever the base URL changes.
    openai_compatible_definition: ?@import("../config/configured_provider.zig").Definition = null,
    model_requests_blocked: bool = false,
    /// Process-long pooled HTTP client for gateway chat traffic. Heap-allocated
    /// so the pointer stays stable when this Runtime is copied by value; null
    /// when allocation failed (requests then dial per attempt, as before).
    gateway_http_pool: ?*http_pool.HttpPool = null,

    pub fn init(alloc: Allocator) Self {
        return .{ .alloc = alloc };
    }

    /// Creates the gateway pool once. Safe to call repeatedly. Allocation
    /// failure leaves the pool absent rather than failing the caller.
    pub fn ensureGatewayHttpPool(self: *Self) void {
        if (self.gateway_http_pool != null) return;
        const pool = self.alloc.create(http_pool.HttpPool) catch return;
        pool.* = http_pool.HttpPool.init(self.alloc);
        self.gateway_http_pool = pool;
    }

    pub fn deinit(self: *Self) void {
        if (self.gateway_http_pool) |pool| {
            if (pool.deinit() == .destroyed) self.alloc.destroy(pool);
        }
        self.clearOpenAiCompatible();
        self.model.deinit(self.alloc);
        self.definitions.deinit(self.alloc);
        self.* = undefined;
    }

    fn clearOpenAiCompatible(self: *Self) void {
        self.openai_compatible_definition = null;
        if (self.openai_compatible_base_url) |value| self.alloc.free(value);
        if (self.openai_compatible_id) |value| self.alloc.free(value);
        if (self.openai_compatible_bearer) |value| self.alloc.free(value);
        self.openai_compatible_base_url = null;
        self.openai_compatible_id = null;
        self.openai_compatible_bearer = null;
    }

    /// Rebuilds the OpenAI-compatible endpoint definition from `base_url`.
    /// Passing an empty URL clears it. All fallible allocation happens before
    /// the visible state changes.
    pub fn setOpenAiCompatibleBaseUrl(self: *Self, base_url: []const u8) !void {
        var owned_url: ?[]u8 = null;
        errdefer if (owned_url) |value| self.alloc.free(value);
        if (base_url.len != 0) owned_url = try self.alloc.dupe(u8, base_url);
        const built = try buildOpenAiCompatibleDefinition(self.alloc, owned_url orelse "");
        errdefer if (built) |value| value.deinit(self.alloc);

        self.clearOpenAiCompatible();
        if (owned_url) |url| {
            self.openai_compatible_base_url = url;
            self.openai_compatible_id = built.?.id;
            self.openai_compatible_bearer = built.?.bearer;
            self.openai_compatible_definition = built.?.definition;
        }
    }

    /// Borrowed base URL for the OpenAI-compatible endpoint, or null when the
    /// profile has not configured one.
    pub fn openAiCompatibleBaseUrl(self: *const Self) ?[]const u8 {
        return self.openai_compatible_base_url;
    }

    /// The returned model slice is borrowed until the next mutation or deinit.
    pub fn selection(self: *const Self) model_provider.ProviderSelection {
        return .{
            .provider = self.active_provider,
            .model = self.model.items,
        };
    }

    pub fn replaceModel(self: *Self, value: []const u8) !void {
        var owned = try self.alloc.dupe(u8, value);
        self.adoptOwned(self.active_provider, &owned);
    }

    pub fn replaceSelection(
        self: *Self,
        target_provider: model_provider.ProviderId,
        model_value: []const u8,
    ) !void {
        const bound = try target_provider.bind(self.definitions);
        var owned = try self.alloc.dupe(u8, model_value);
        self.adoptOwned(bound, &owned);
    }

    /// Transfers `owned_model` into the runtime. All fallible preparation must
    /// finish before this no-fail publication boundary.
    pub fn adoptOwned(
        self: *Self,
        target_provider: model_provider.ProviderId,
        owned_model: *[]u8,
    ) void {
        self.model.deinit(self.alloc);
        self.model = .fromOwnedSlice(owned_model.*);
        owned_model.* = &.{};
        self.active_provider = target_provider;
    }
};

pub fn supported(comptime App: type) bool {
    return @hasField(App, "provider_selection") or
        (builtin.is_test and @hasField(App, "selected_model"));
}

pub fn model(app: anytype) []const u8 {
    const App = @TypeOf(app.*);
    if (comptime @hasField(App, "provider_selection")) {
        return app.provider_selection.selection().model;
    }
    if (comptime builtin.is_test and @hasField(App, "selected_model")) {
        return app.selected_model.items;
    }
    @compileError("app must own provider_selection");
}

pub fn provider(app: anytype) model_provider.ProviderId {
    const App = @TypeOf(app.*);
    if (comptime @hasField(App, "provider_selection")) {
        return app.provider_selection.selection().provider;
    }
    if (comptime builtin.is_test and @hasField(App, "selected_provider")) {
        return app.selected_provider;
    }
    if (comptime builtin.is_test and @hasField(App, "selected_model")) {
        return .openrouter;
    }
    @compileError("app must own provider_selection");
}

pub fn replaceModel(app: anytype, value: []const u8) !void {
    const App = @TypeOf(app.*);
    if (comptime @hasField(App, "provider_selection")) {
        return app.provider_selection.replaceModel(value);
    }
    if (comptime builtin.is_test and @hasField(App, "selected_model")) {
        const stable = try app.alloc.dupe(u8, value);
        defer app.alloc.free(stable);
        try app.selected_model.ensureTotalCapacity(app.alloc, stable.len);
        app.selected_model.clearRetainingCapacity();
        app.selected_model.appendSliceAssumeCapacity(stable);
        return;
    }
    @compileError("app must own provider_selection");
}

pub fn replaceSelection(
    app: anytype,
    selected_provider: model_provider.ProviderId,
    value: []const u8,
) !void {
    const App = @TypeOf(app.*);
    if (comptime @hasField(App, "provider_selection")) {
        return app.provider_selection.replaceSelection(selected_provider, value);
    }
    if (comptime builtin.is_test and @hasField(App, "selected_model")) {
        if (@hasField(App, "selected_provider")) app.selected_provider = selected_provider;
        return replaceModel(app, value);
    }
    @compileError("app must own provider_selection");
}
