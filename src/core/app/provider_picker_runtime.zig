//! Behavior for the columnar `/provider` picker.
//!
//! The picker walks left to right: provider, then the sign-in method for the
//! gateway (`oauth`/`api-key`), then either the the team (oauth with a live
//! session), the which-key column (`env`/`saved`/`new`), or the masked key
//! entry field. Each list column writes its choice into the composer, so the
//! next column anchors under its own argument the way `/model` does.
//!
//! Terminal actions are not reimplemented here. Every commit is expressed as an
//! `auth_runtime.Choice` and handed to the auth runtime, which already owns
//! provider switching, OAuth, API key entry, and team selection.

const std = @import("std");
const auth_runtime = @import("../auth/auth_runtime.zig");
const credentials = @import("../auth/credentials.zig");
const provider_catalog = @import("../auth/provider_catalog.zig");
const provider_picker_catalog = @import("../auth/provider_picker_catalog.zig");
const model_provider = @import("../config/model_provider.zig");
const picker_state = @import("../input/picker_state.zig");
const list_window = @import("../shared/list_window.zig");
const runtime_profile = @import("../hosts/runtime_profile.zig");
const app_auth_runtime = @import("app_auth_runtime.zig");
const provider_runtime = @import("provider_runtime.zig");

const ProviderPickerStage = picker_state.ProviderPickerStage;
const max_options = provider_picker_catalog.max_column_options;
/// Row label for the OpenAI-compatible endpoint option inside the key column.
const base_url_row_slug = "base-url";

/// Scratch for one column: stack-local in key handlers, container-retained in
/// the render path. Team labels borrow from the auth runtime's team list, so
/// no slice may be kept past the frame or key press that filled the buffer.
pub const ColumnBuffer = struct {
    labels: [max_options][]const u8 = undefined,
    annotations: [max_options][]const u8 = undefined,
    count: usize = 0,
    /// Backing bytes for the API key column, whose single row is composed per
    /// frame rather than picked from a list.
    field: [provider_picker_catalog.max_key_field_bytes]u8 = undefined,
};

/// Hosts without a composer, an auth runtime, a provider selection, or native
/// auth have no `/provider` picker; every entry point below is inert for them.
/// The native-auth gate matters because the picker triggers on typed text: the
/// command handlers refuse politely on WASM, but the composer would otherwise
/// still open columns whose leaves (key entry, OAuth) cannot run there.
pub fn supported(comptime App: type) bool {
    return runtime_profile.allows(App, .native_auth) and
        @hasField(App, "input_runtime") and
        @hasField(App, "auth") and
        provider_runtime.supported(App);
}

pub fn Runtime(comptime App: type) type {
    return struct {
        /// Fills one column with its options and their `current` annotations,
        /// then narrows both to what the typed query matches.
        pub fn columnOptions(
            app: *App,
            query: picker_state.ProviderPickerQuery,
            column: *ColumnBuffer,
        ) usize {
            // Emptied up front so early returns leave no stale slice count in
            // a caller-retained buffer.
            column.count = 0;
            if (comptime !supported(App)) return 0;
            if (app.auth.sourceInventoryRefreshActive()) {
                column.labels[0] = "checking credentials...";
                column.annotations[0] = "";
                column.count = 1;
                return column.count;
            }
            const active_provider = provider_runtime.provider(app);
            var count: usize = 0;
            switch (query.stage) {
                .provider => {
                    var slugs: [provider_picker_catalog.max_provider_options][]const u8 = undefined;
                    count = provider_picker_catalog.providerOptions(&slugs);
                    for (slugs[0..count], 0..) |slug, i| {
                        column.labels[i] = slug;
                        const id = provider_catalog.parse(slug) orelse .openrouter;
                        column.annotations[i] = if (id.eql(active_provider) and
                            model_provider.authorizesCredential(id, app.auth.credentialSource())) "current" else "";
                    }
                },
                .method => {
                    const pending = app.input_runtime.picker.provider_picker_pending_provider.items;
                    const provider = provider_catalog.parse(pending) orelse return 0;
                    const active_source = app.auth.credentialSource();
                    const methods = provider_picker_catalog.providerMethods(provider);
                    for (methods, 0..) |method, i| {
                        column.labels[i] = provider_picker_catalog.methodSlug(method);
                        const in_use = provider.eql(active_provider) and
                            if (active_source) |source| provider_picker_catalog.methodMatchesSource(method, source, provider) else false;
                        column.annotations[i] = if (in_use) "current" else "";
                    }
                    count = methods.len;
                },
                .key_source => {
                    const view = app.auth.pickerView();
                    const pending = app.input_runtime.picker.provider_picker_pending_provider.items;
                    const provider = provider_catalog.parse(pending) orelse .openrouter;
                    // The endpoint must exist before a key can be validated, so
                    // until a base URL is set the column offers only that step.
                    if (provider == .openai_compatible) {
                        const configured: ?[]const u8 = if (comptime @hasField(App, "provider_selection"))
                            app.provider_selection.openAiCompatibleBaseUrl()
                        else
                            null;
                        if (configured == null or configured.?.len == 0) {
                            column.labels[0] = base_url_row_slug;
                            column.annotations[0] = "required · set the endpoint URL first";
                            column.count = 1;
                            return 1;
                        }
                    }
                    // `current` always means "used for inference right now",
                    // so a key is only current while the gateway is active.
                    const active = if (provider.eql(active_provider)) app.auth.credentialSource() else null;
                    // A provider holds at most one saved key. While it does, the
                    // paste row is withdrawn and only the delete row is offered,
                    // so a second paste cannot overwrite without an explicit
                    // delete first.
                    const has_saved = if (provider_picker_catalog.providerStoredCredential(provider)) |stored|
                        view.available_sources.contains(stored)
                    else
                        false;
                    inline for (@typeInfo(provider_picker_catalog.KeySource).@"enum".fields) |field| {
                        const key_source = @field(provider_picker_catalog.KeySource, field.name);
                        const credential = provider_picker_catalog.keySourceCredential(key_source, provider);
                        const detected = switch (key_source) {
                            .new => !has_saved,
                            .remove => has_saved,
                            else => if (credential) |value| view.available_sources.contains(value) else true,
                        };
                        if (detected) {
                            column.labels[count] = provider_picker_catalog.keySourceSlug(key_source);
                            column.annotations[count] = provider_picker_catalog.keySourceAnnotation(
                                key_source,
                                credential != null and credential == active,
                                provider,
                            );
                            count += 1;
                        }
                    }
                    // The OpenAI-compatible provider also offers an endpoint row
                    // in the same column, so its flow matches Groq and OpenRouter
                    // exactly with one extra option.
                    if (provider == .openai_compatible) {
                        const configured: ?[]const u8 = if (comptime @hasField(App, "provider_selection"))
                            app.provider_selection.openAiCompatibleBaseUrl()
                        else
                            null;
                        column.labels[count] = base_url_row_slug;
                        column.annotations[count] = if (configured) |url|
                            if (url.len > 0) url else "set a custom endpoint URL"
                        else
                            "set a custom endpoint URL";
                        count += 1;
                    }
                },
                .base_url => {
                    const pending = app.input_runtime.picker.provider_picker_pending_provider.items;
                    const provider_label = if (provider_catalog.parse(pending)) |provider|
                        provider_catalog.label(provider)
                    else
                        provider_catalog.label(.openrouter);
                    column.labels[0] = provider_picker_catalog.writeBaseUrlField(
                        &column.field,
                        app.auth.baseUrlInput(),
                        provider_label,
                    );
                    column.annotations[0] = "";
                    column.count = 1;
                    return 1;
                },
                .api_key => {
                    // The column outlives the entry while the save thread
                    // works; an empty ready-looking field there would invite
                    // pasting the key again, into the composer this time.
                    const pending = app.input_runtime.picker.provider_picker_pending_provider.items;
                    const provider_label = if (provider_catalog.parse(pending)) |provider|
                        provider_catalog.label(provider)
                    else
                        provider_catalog.label(.openrouter);
                    column.labels[0] = if (app.auth.apiKeySaveInFlight())
                        "saving the key..."
                    else
                        provider_picker_catalog.writeKeyField(&column.field, app.auth.apiKeyMaskCount(), provider_label);
                    column.annotations[0] = "";
                    column.count = 1;
                    return 1;
                },
                .team => {
                    const selection = null orelse return 0;
                    // `current` always means "used for inference right now".
                    // The login session remembers a team even while a
                    // subscription provider or an API key is doing the actual
                    // inference; that remembered team earns no marker then.
                    const oauth_inference_active = active_provider == .openrouter and
                        app.auth.credentialSource() == .openrouter_api_key;
                    const current = if (oauth_inference_active) selection.currentTeam() else null;
                    for (selection.teams.items) |team| {
                        if (count >= provider_picker_catalog.max_team_options) break;
                        column.labels[count] = team.slug;
                        const is_current = if (current) |slug|
                            std.mem.eql(u8, slug, team.slug) or std.mem.eql(u8, slug, team.id)
                        else
                            false;
                        column.annotations[count] = if (is_current) "current" else "";
                        count += 1;
                    }
                },
            }
            column.count = picker_state.filterAnnotatedLabels(
                query.query,
                &column.labels,
                &column.annotations,
                count,
            );
            return column.count;
        }

        pub fn hasQuery(app: *App) bool {
            if (comptime !supported(App)) return false;
            return app.input_runtime.picker.activeProviderPickerQuery(&app.input_runtime.edit_state) != null;
        }

        pub fn navigate(app: *App, delta: i32) void {
            if (comptime !supported(App)) return;
            if (app.auth.sourceInventoryRefreshActive()) return;
            if (!hasQuery(app)) return;
            const query = app.input_runtime.picker.activeProviderPickerQuery(&app.input_runtime.edit_state) orelse return;
            var column: ColumnBuffer = .{};
            const count = columnOptions(app, query, &column);
            const picker = &app.input_runtime.picker;
            switch (query.stage) {
                .provider => list_window.advanceSelection(&picker.provider_column_index, &picker.provider_column_window_start, count, delta),
                .method => list_window.advanceSelection(&picker.method_column_index, &picker.method_column_window_start, count, delta),
                .team => list_window.advanceSelection(&picker.team_column_index, &picker.team_column_window_start, count, delta),
                .key_source => list_window.advanceSelection(&picker.key_source_column_index, &picker.key_source_column_window_start, count, delta),
                .base_url, .api_key => {},
            }
        }

        /// Tab: write the highlighted option into the composer without moving
        /// to the next column. The rewrite clears the picker flow (every full
        /// composer replacement does), so the stage is re-established after.
        pub fn autocomplete(app: *App) !void {
            if (comptime !supported(App)) return;
            if (app.auth.sourceInventoryRefreshActive()) return;
            if (!hasQuery(app)) return;
            const query = app.input_runtime.picker.activeProviderPickerQuery(&app.input_runtime.edit_state) orelse return;
            const stage = query.stage;
            if (stage == .api_key or stage == .base_url) return;
            var column: ColumnBuffer = .{};
            _ = columnOptions(app, query, &column);
            const selected = selectedLabel(app, query, &column) orelse return;

            const picker = &app.input_runtime.picker;
            const prefix = try app.alloc.dupe(u8, query.prefix);
            defer app.alloc.free(prefix);
            const provider_slug = try app.alloc.dupe(u8, picker.provider_picker_pending_provider.items);
            defer app.alloc.free(provider_slug);
            const method_slug = try app.alloc.dupe(u8, picker.provider_picker_pending_method.items);
            defer app.alloc.free(method_slug);

            switch (stage) {
                .provider => try setComposerText(app, "{s}{s}", .{ prefix, selected }),
                .method => {
                    try setComposerText(app, "{s}{s} {s}", .{ prefix, provider_slug, selected });
                    try picker.beginProviderPickerFlow(app.alloc, provider_slug, "", .method);
                },
                .team, .key_source => {
                    try setComposerText(app, "{s}{s} {s} {s}", .{ prefix, provider_slug, method_slug, selected });
                    try picker.beginProviderPickerFlow(app.alloc, provider_slug, method_slug, stage);
                },
                .base_url, .api_key => unreachable,
            }
            app.shell.render_requests.request(.footer);
        }

        /// Space advances only when the exact typed token opens another column
        /// with no side effects: a provider that has a method column, or the
        /// `api-key` method (its next column is local). Everything that acts
        /// (switching, OAuth, saving) stays on Enter, so a reflexive space
        /// never commits and never touches the network.
        pub fn advanceOnSpace(app: *App) !bool {
            if (comptime !supported(App)) return false;
            if (app.auth.sourceInventoryRefreshActive()) return false;
            if (!hasQuery(app)) return false;
            const query = app.input_runtime.picker.activeProviderPickerQuery(&app.input_runtime.edit_state) orelse return false;
            if (app.input_runtime.edit_state.cursor != app.input_runtime.edit_state.input.items.len) return false;
            if (std.mem.trim(u8, query.query, " \t").len == 0) return false;

            var column: ColumnBuffer = .{};
            _ = columnOptions(app, query, &column);
            const selected = exactLabel(query.query, &column) orelse return false;
            switch (query.stage) {
                .provider => {
                    const provider = provider_catalog.parse(selected) orelse return false;
                    if (provider_picker_catalog.providerMethods(provider).len == 0) return false;
                },
                .method => {
                    if (provider_picker_catalog.parseMethod(selected) != .api_key) return false;
                },
                .team, .key_source, .base_url, .api_key => return false,
            }
            return try submit(app);
        }

        /// True when the OpenAI-compatible provider has no endpoint address yet.
        /// Without one there is no route to switch to, and a key cannot be
        /// validated, so the endpoint has to come before anything else.
        fn openAiCompatibleEndpointMissing(app: *const App) bool {
            const configured: ?[]const u8 = if (comptime @hasField(App, "provider_selection"))
                app.provider_selection.openAiCompatibleBaseUrl()
            else
                null;
            return configured == null or configured.?.len == 0;
        }

        /// Enter: open the next column, or hand the completed choice to the
        /// auth runtime.
        pub fn submit(app: *App) !bool {
            if (comptime !supported(App)) return false;
            if (!hasQuery(app)) return false;
            if (app.auth.sourceInventoryRefreshActive()) return true;
            const query = app.input_runtime.picker.activeProviderPickerQuery(&app.input_runtime.edit_state) orelse return false;
            var column: ColumnBuffer = .{};
            _ = columnOptions(app, query, &column);
            // No matching option: let Enter fall through so the router reports
            // the unknown text instead of silently eating the key.
            const selected = selectedLabel(app, query, &column) orelse return false;

            switch (query.stage) {
                .provider => {
                    const provider = provider_catalog.parse(selected) orelse return false;
                    const methods = provider_picker_catalog.providerMethods(provider);
                    if (methods.len == 0) {
                        try commit(app, .{ .provider = provider });
                        return true;
                    }
                    // An OpenAI-compatible endpoint needs an address before a key
                    // means anything. With none configured there is no route to
                    // switch to, so the choice leads to the endpoint step
                    // instead of a switch that cannot succeed.
                    if (provider == .openai_compatible and
                        openAiCompatibleEndpointMissing(app))
                    {
                        try openBaseUrlStage(app, query.prefix);
                        return true;
                    }
                    const active_provider = provider_runtime.provider(app);
                    // Switching to a provider that already holds a key is a
                    // single step: re-asking for the method and then the key
                    // would only re-offer a credential the user already saved.
                    // The active provider keeps the drill-down so its key
                    // stays removable.
                    if (!provider.eql(active_provider)) {
                        try app.auth.refreshSourceInventory(app.alloc);
                        const view = app.auth.pickerView();
                        const stored_source = provider_picker_catalog.providerStoredCredential(provider);
                        const env_source = provider_picker_catalog.providerEnvCredential(provider);
                        const existing: ?credentials.Source = if (stored_source != null and view.available_sources.contains(stored_source.?))
                            stored_source.?
                        else if (view.available_sources.contains(env_source))
                            env_source
                        else
                            null;
                        if (existing) |source| {
                            try commitSource(app, source, provider);
                            return true;
                        }
                    }
                    // Nothing is applied yet: the provider is only a heading
                    // until the method, and then the team, are chosen too.
                    const slug = provider_catalog.find(provider).slug;
                    try setComposerText(app, "{s}{s} ", .{ query.prefix, slug });
                    try app.input_runtime.picker.beginProviderPickerFlow(app.alloc, slug, "", .method);
                    app.shell.render_requests.request(.footer);
                    return true;
                },
                .method => {
                    const method = provider_picker_catalog.parseMethod(selected) orelse return false;
                    // The inventory is what says whether this method already
                    // has a credential to switch to; it goes stale the moment
                    // a key lands in the environment or the keychain.
                    try app.auth.refreshSourceInventory(app.alloc);
                    if (method == .api_key) {
                        // Every provider shows the same key-source column, so the
                        // flow is identical; the OpenAI-compatible provider simply
                        // adds a base URL row to it.
                        try openKeyStage(app, query.prefix, .key_source);
                        return true;
                    }
                    // An API key is the only method left, and it has no team
                    // step, so the choice goes straight to the key stage.
                    try openKeyStage(app, query.prefix, .api_key);
                    return true;
                },
                .key_source => {
                    const pending_provider = provider_catalog.parse(
                        app.input_runtime.picker.provider_picker_pending_provider.items,
                    ) orelse .openrouter;
                    if (pending_provider == .openai_compatible) {
                        // No endpoint yet: every choice leads to the base URL
                        // step, because a key cannot be validated without it.
                        if (openAiCompatibleEndpointMissing(app)) {
                            try openBaseUrlStage(app, query.prefix);
                            return true;
                        }
                    }
                    // The endpoint row opens the base URL field; after it is set
                    // the same column returns so a key can be chosen next.
                    if (pending_provider == .openai_compatible and std.mem.eql(u8, selected, base_url_row_slug)) {
                        try openBaseUrlStage(app, query.prefix);
                        return true;
                    }
                    const key_source = provider_picker_catalog.parseKeySource(selected) orelse return false;
                    switch (key_source) {
                        .new => try openKeyStage(app, query.prefix, .api_key),
                        .remove => {
                            app.input_runtime.inputResetState().clearCurrent(app.alloc);
                            try app_auth_runtime.Runtime(App).removeStoredKey(app, pending_provider);
                            // The notice tells the user to paste a new key, so
                            // stay on the column that takes one instead of
                            // dropping them out of `/provider`.
                            try openKeySourceStageFor(app, pending_provider);
                        },
                        .env, .saved => if (provider_picker_catalog.keySourceCredential(
                            key_source,
                            pending_provider,
                        )) |credential| {
                            try commitSource(app, credential, pending_provider);
                        },
                    }
                    return true;
                },
                // Enter is consumed by the key and base URL fields themselves,
                // which the auth runtime routes before the composer ever sees
                // the byte. There is no team column to enter from.
                .base_url, .api_key, .team => return false,
            }
        }

        /// Opens one of the api-key stages under the `api-key` argument: the
        /// which-key list, or the masked entry field (whose bytes the auth
        /// runtime owns; the composer only carries the breadcrumb).
        fn openKeyStage(app: *App, prefix: []const u8, stage: ProviderPickerStage) !void {
            const provider_slug = try app.alloc.dupe(u8, app.input_runtime.picker.provider_picker_pending_provider.items);
            defer app.alloc.free(provider_slug);
            const method_slug = provider_picker_catalog.methodSlug(.api_key);
            const stable_prefix = try app.alloc.dupe(u8, prefix);
            defer app.alloc.free(stable_prefix);

            try setComposerText(app, "{s}{s} {s} ", .{ stable_prefix, provider_slug, method_slug });
            try app.input_runtime.picker.beginProviderPickerFlow(app.alloc, provider_slug, method_slug, stage);
            if (stage == .api_key) {
                const provider = provider_catalog.parse(provider_slug) orelse .openrouter;
                app.auth.openApiKeyPickerInline(app.alloc, provider);
            }
            app.shell.render_requests.request(.footer);
        }

        /// Opens the base URL field for the OpenAI-compatible endpoint under the
        /// provider argument. The field is inline, matching the API key field.
        fn openBaseUrlStage(app: *App, prefix: []const u8) !void {
            const provider_slug = provider_catalog.find(.openai_compatible).slug;
            const method_slug = provider_picker_catalog.methodSlug(.api_key);
            const stable_prefix = try app.alloc.dupe(u8, prefix);
            defer app.alloc.free(stable_prefix);

            try setComposerText(app, "{s}{s} {s} ", .{ stable_prefix, provider_slug, method_slug });
            try app.input_runtime.picker.beginProviderPickerFlow(app.alloc, provider_slug, method_slug, .base_url);
            app.auth.openBaseUrlPickerInline(app.alloc, .openai_compatible);
            app.shell.render_requests.request(.footer);
        }

        /// Returns from the base URL field to the key-source column for the
        /// OpenAI-compatible provider, keeping the composer breadcrumb and the
        /// picker stage in step so the key can be chosen next.
        pub fn openKeySourceStageAfterBaseUrl(app: *App) !void {
            app.auth.endBaseUrlEntry(app.alloc);
            try openKeySourceStageFor(app, .openai_compatible);
        }

        /// Reopens the key-source column for one provider. Used after a step
        /// that leaves the column in a different shape, such as setting the
        /// endpoint or deleting the saved key, so the user stays on the column
        /// and picks the next thing rather than being dropped out of `/provider`.
        pub fn openKeySourceStageFor(app: *App, provider: model_provider.ProviderId) !void {
            const slug = provider_catalog.find(provider).slug;
            const method_slug = provider_picker_catalog.methodSlug(.api_key);
            try setComposerText(app, "/provider {s} {s} ", .{ slug, method_slug });
            try app.input_runtime.picker.beginProviderPickerFlow(app.alloc, slug, method_slug, .key_source);
            app.shell.render_requests.request(.footer);
        }

        /// Left arrow at the start of a column: reopen the column to its left.
        pub fn stepBack(app: *App) !bool {
            if (comptime !supported(App)) return false;
            if (!hasQuery(app)) return false;
            const query = app.input_runtime.picker.activeProviderPickerQuery(&app.input_runtime.edit_state) orelse return false;
            if (query.stage == .provider) return false;

            const picker = &app.input_runtime.picker;
            const prefix = try app.alloc.dupe(u8, query.prefix);
            defer app.alloc.free(prefix);
            const provider_slug = try app.alloc.dupe(u8, picker.provider_picker_pending_provider.items);
            defer app.alloc.free(provider_slug);

            switch (query.stage) {
                .provider => return false,
                // Arrow keys never reach here while the key field is active;
                // its entry routing consumes them. Esc is the way out.
                .base_url, .api_key => return false,
                .method => {
                    // Back to the full provider column, not to the committed
                    // token as a filter: the point of stepping back is seeing
                    // the alternatives again, with the old choice preselected.
                    try setComposerText(app, "{s}", .{prefix});
                    picker.clearProviderPickerFlow();
                    syncProviderSelection(app, provider_slug);
                },
                .team, .key_source => {
                    const method_slug = try app.alloc.dupe(u8, picker.provider_picker_pending_method.items);
                    defer app.alloc.free(method_slug);
                    try setComposerText(app, "{s}{s} ", .{ prefix, provider_slug });
                    try picker.beginProviderPickerFlow(app.alloc, provider_slug, "", .method);
                    syncMethodSelection(app, provider_slug, method_slug);
                },
            }
            app.shell.render_requests.request(.footer);
            return true;
        }

        pub fn abandon(app: *App) void {
            if (comptime !supported(App)) return;
            if (app.input_runtime.picker.provider_picker_stage == .provider) return;
            app.auth.cancelInlineApiKeyEntry(app.alloc);
            app.input_runtime.picker.clearProviderPickerFlow();
        }

        /// Retires the key column once the entry it was showing has ended, so a
        /// saved or cancelled key does not leave the breadcrumb behind.
        pub fn closeKeyColumn(app: *App) void {
            if (comptime !supported(App)) return;
            if (app.input_runtime.picker.provider_picker_stage != .api_key) return;
            if (app.auth.apiKeyInlineActive()) return;
            // Enter pops the entry stage before the save thread finishes; the
            // column must outlive the save so the switch-to-gateway gate can
            // still see where the key came from when the result lands.
            if (app.auth.apiKeySaveInFlight()) return;
            app.input_runtime.picker.clearProviderPickerFlow();
            app.input_runtime.inputResetState().clearCurrent(app.alloc);
            app.shell.render_requests.request(.footer);
        }

        fn commit(app: *App, choice: auth_runtime.Choice) !void {
            // Clear first: the choice may open the device-code or API key
            // screen, and a leftover `/provider ...` line under it reads as if the
            // picker were still waiting for input.
            app.input_runtime.picker.clearProviderPickerFlow();
            app.input_runtime.inputResetState().clearCurrent(app.alloc);
            try app_auth_runtime.Runtime(App).applyPickerChoice(app, choice);
            app.shell.render_requests.request(.footer);
        }

        /// An ambient OIDC token satisfies the oauth method without a browser
        /// round trip. It is the only source worth switching to here: a stored
        /// fx login session that reached this point was already judged dead by
        /// the team load, so offering it back would switch to a corpse.
        fn ambientOauthSource(app: *App) ?credentials.Source {
            const view = app.auth.pickerView();
            if (!view.available_sources.contains(.openrouter_api_key)) return null;
            if (app.auth.credentialSource() == .openrouter_api_key) return null;
            return .openrouter_api_key;
        }

        /// Switching to a detected credential is a complete leaf: apply the
        /// source, then the provider it authenticates.
        fn commitSource(app: *App, source: credentials.Source, provider: model_provider.ProviderId) !void {
            app.input_runtime.picker.clearProviderPickerFlow();
            app.input_runtime.inputResetState().clearCurrent(app.alloc);
            const auth_rt = app_auth_runtime.Runtime(App);
            // The provider only follows a credential that actually applied;
            // switching after a failed selection would strand the provider
            // without the credential the user just asked it to use.
            if (try auth_rt.applySourceChoice(app, source)) {
                if (!provider_runtime.provider(app).eql(provider)) {
                    try auth_rt.applyPickerChoice(app, .{ .provider = provider });
                }
            }
            app.shell.render_requests.request(.footer);
        }

        /// The team is the last column, so this is where the whole path
        fn selectedLabel(
            app: *App,
            query: picker_state.ProviderPickerQuery,
            column: *const ColumnBuffer,
        ) ?[]const u8 {
            if (column.count == 0) return null;
            if (exactLabel(query.query, column)) |label| return label;
            const index = currentIndex(app, query.stage) % column.count;
            return column.labels[index];
        }

        fn currentIndex(app: *App, stage: ProviderPickerStage) usize {
            const picker = &app.input_runtime.picker;
            return switch (stage) {
                .provider => picker.provider_column_index,
                .method => picker.method_column_index,
                .team => picker.team_column_index,
                .key_source => picker.key_source_column_index,
                .base_url, .api_key => 0,
            };
        }

        /// There is one built-in provider and it has no teams, so the team column
        /// is never presented.
        fn teamIndex(_: *App, _: []const u8) ?usize {
            return null;
        }

        fn selectCurrentTeam(app: *App) void {
            const picker = &app.input_runtime.picker;
            picker.team_column_index = 0;
            picker.team_column_window_start = 0;

            const selection = null orelse return;
            const current = selection.currentTeam() orelse return;
            for (selection.teams.items, 0..) |team, index| {
                if (!std.mem.eql(u8, current, team.slug) and !std.mem.eql(u8, current, team.id)) continue;
                picker.team_column_index = index;
                picker.team_column_window_start = list_window.updateEdgeStart(
                    0,
                    selection.teams.items.len,
                    index,
                    list_window.default_max_picker_rows,
                );
                return;
            }
        }

        fn syncMethodSelection(app: *App, provider_slug: []const u8, method_slug: []const u8) void {
            const provider = provider_catalog.parse(provider_slug) orelse return;
            for (provider_picker_catalog.providerMethods(provider), 0..) |method, index| {
                if (!std.mem.eql(u8, provider_picker_catalog.methodSlug(method), method_slug)) continue;
                app.input_runtime.picker.method_column_index = index;
                return;
            }
        }

        fn syncProviderSelection(app: *App, slug: []const u8) void {
            var slugs: [provider_picker_catalog.max_provider_options][]const u8 = undefined;
            const count = provider_picker_catalog.providerOptions(&slugs);
            for (slugs[0..count], 0..) |candidate, index| {
                if (!std.mem.eql(u8, candidate, slug)) continue;
                app.input_runtime.picker.provider_column_index = index;
                app.input_runtime.picker.provider_column_window_start = list_window.updateEdgeStart(
                    0,
                    count,
                    index,
                    list_window.default_max_picker_rows,
                );
                return;
            }
        }

        fn setComposerText(app: *App, comptime fmt: []const u8, args: anytype) !void {
            const text = try std.fmt.allocPrint(app.alloc, fmt, args);
            defer app.alloc.free(text);
            try app.input_runtime.textReplacementState().replace(app.alloc, text);
        }
    };
}

fn exactLabel(raw_query: []const u8, column: *const ColumnBuffer) ?[]const u8 {
    const query = std.mem.trim(u8, raw_query, " \t");
    if (query.len == 0) return null;
    for (column.labels[0..column.count]) |candidate| {
        if (std.ascii.eqlIgnoreCase(candidate, query)) return candidate;
    }
    return null;
}

const core_input_runtime = @import("../input/runtime.zig");
const ColumnTestApp = struct {
    alloc: std.mem.Allocator,
    input_runtime: core_input_runtime.Runtime = .{},
    provider_selection: provider_runtime.Runtime,
    auth: TestAuth = .{},
    shell: struct {
        render_requests: struct {
            fn request(_: *@This(), _: enum { footer }) void {}
        } = .{},
    } = .{},

    const TestAuth = struct {
        source: ?credentials.Source = null,
        mask_count: usize = 0,
        save_in_flight: bool = false,
        inventory_refresh_active: bool = false,
        available: auth_runtime.SourceSet = .empty,

        fn sourceInventoryRefreshActive(self: *const TestAuth) bool {
            return self.inventory_refresh_active;
        }

        fn credentialSource(self: *const TestAuth) ?credentials.Source {
            return self.source;
        }

        fn pickerView(self: *const TestAuth) auth_runtime.PickerView {
            return .{
                .active = false,
                .available_sources = self.available,
                .selected_choice = null,
                .active_source = self.source,
                .include_skip = false,
            };
        }

        fn apiKeyMaskCount(self: *const TestAuth) usize {
            return self.mask_count;
        }

        fn apiKeyInlineActive(_: *const TestAuth) bool {
            return true;
        }

        fn apiKeySaveInFlight(self: *const TestAuth) bool {
            return self.save_in_flight;
        }

        fn loadedTeamSelection(_: *TestAuth) ?*anyopaque {
            return null;
        }
    };

    fn init(alloc: std.mem.Allocator) ColumnTestApp {
        return .{ .alloc = alloc, .provider_selection = .{ .alloc = alloc } };
    }

    fn deinit(self: *ColumnTestApp) void {
        self.input_runtime.deinit(self.alloc);
        self.provider_selection.deinit();
    }
};

fn columnFor(app: *ColumnTestApp, stage: ProviderPickerStage, query: []const u8) ColumnBuffer {
    var column: ColumnBuffer = .{};
    _ = Runtime(ColumnTestApp).columnOptions(app, .{
        .stage = stage,
        .prefix = "/provider ",
        .query = query,
        .token_start = 0,
    }, &column);
    return column;
}
