const std = @import("std");
const config_runtime = @import("../config/config_runtime.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const host = @import("../hosts/host.zig");
const runtime_profile = @import("../hosts/runtime_profile.zig");
const io_mod = @import("../shared/io.zig");
const credentials = @import("../auth/credentials.zig");
const api_key_validator = @import("../auth/api_key_validator.zig");
const auth_runtime = @import("../auth/auth_runtime.zig");
const provider_catalog = @import("../auth/provider_catalog.zig");
const auth_transition = @import("../auth/auth_transition.zig");
const model_provider = @import("../config/model_provider.zig");
const model_catalog = @import("../gateway/model_catalog.zig");
const provider_runtime = @import("provider_runtime.zig");
const picker_state = @import("../input/picker_state.zig");
const provider_picker_runtime = @import("provider_picker_runtime.zig");
const provider_picker_catalog = @import("../auth/provider_picker_catalog.zig");
const app_worker_runtime = @import("app_worker_runtime.zig");
const types = @import("../shared/types.zig");

fn oauthAuthEnabled(comptime App: type) bool {
    return runtime_profile.allows(App, .native_auth) or
        runtime_profile.allows(App, .js_host_auth);
}

const ProviderSwitchDecision = auth_transition.ProviderSwitchDecision;
const ProviderSwitchIntent = auth_transition.ProviderSwitchIntent;
const decideProviderSwitch = auth_transition.decideProviderSwitch;
const provider_busy_message = "Provider switching is unavailable until active and queued work finishes.";

fn providerFailureMessage(
    intent: ProviderSwitchIntent,
    ordinary: []const u8,
    after_oauth: []const u8,
) []const u8 {
    return if (intent == .post_oauth) after_oauth else ordinary;
}

fn selectCatalogModel(
    entries: []const model_catalog.ModelCatalogEntry,
    primary: ?[]const u8,
    secondary: ?[]const u8,
) ?[]const u8 {
    for ([_]?[]const u8{ primary, secondary }) |maybe_candidate| {
        const candidate = maybe_candidate orelse continue;
        for (entries) |entry| {
            if (std.mem.eql(u8, candidate, entry.id)) return entry.id;
        }
    }
    if (entries.len > 0) return entries[0].id;
    // A catalog-less endpoint (configured, OpenAI-compatible) cannot enumerate
    // models, so the model chosen for it is accepted as-is.
    return primary orelse secondary;
}

fn optionalGatewayApiKey(credential: anytype) ?[]const u8 {
    if (comptime @typeInfo(@TypeOf(credential.api_key)) == .optional) {
        return credential.api_key;
    }
    return credential.api_key;
}

fn gatewayCredentialSource(credential: anytype) ?credentials.Source {
    if (comptime @hasField(@TypeOf(credential), "source")) {
        return credential.source;
    }
    return null;
}

fn hostManagesAuth(app: anytype) bool {
    if (comptime @hasDecl(@TypeOf(app.auth), "isHostManaged")) {
        return app.auth.isHostManaged();
    }
    return false;
}

const TeamCatalogValidation = union(enum) {
    rejected,
    accepted: ?[]u8,

    fn deinit(self: *TeamCatalogValidation, alloc: std.mem.Allocator) void {
        switch (self.*) {
            .accepted => |model| if (model) |owned| alloc.free(owned),
            .rejected => {},
        }
        self.* = undefined;
    }
};

pub const PendingPromptCredentialReadiness = enum {
    pending,
    current,
    rejected,
};

pub fn Runtime(comptime App: type) type {
    return struct {
        fn compactionOwnsCredentialFeedback(app: *const App) bool {
            return if (comptime @hasField(App, "submission")) app.submission.compaction_pending else false;
        }

        fn ensurePromptCredential(app: *App) !bool {
            if (comptime @hasField(App, "provider_selection")) {
                if (app.provider_selection.model_requests_blocked) {
                    try writeAuthNotice(app, .{
                        .topic = "auth",
                        .tone = .@"error",
                        .body = "Repair profile settings and restart fx before sending a message.",
                    });
                    return false;
                }
            }
            if (try rejectPendingPreparation(app)) return false;
            if (comptime provider_runtime.supported(App) and
                @hasDecl(@TypeOf(app.auth), "selectForProvider"))
            {
                const provider = provider_runtime.provider(app);
                if (provider == .configured or !model_provider.authorizesCredential(provider, app.auth.credentialSource())) {
                    const selection = selectProviderCredential(app, provider) catch |err| {
                        if (err == error.OutOfMemory) return err;
                        debug_trace.logf("auth", "prompt credential preference load failed err={s}", .{@errorName(err)});
                        if (compactionOwnsCredentialFeedback(app)) return false;
                        try writeAuthNotice(app, .{
                            .topic = "auth",
                            .tone = .@"error",
                            .body = "Could not load authentication settings. Check user settings, then press enter to retry.",
                        });
                        return false;
                    };
                    switch (selection) {
                        .selected => applyCredentialChange(app, true),
                        .unchanged => {},
                        .failed => |failure| return recoverCredentialFailure(app, failure.source, failure.err),
                        .missing => return missingPromptCredential(app, provider),
                    }
                }
            }
            if (app.auth.credentialSource() != null) return true;
            return missingPromptCredential(app, .openrouter);
        }

        fn selectProviderCredential(app: *App, provider: model_provider.ProviderId) !auth_runtime.ProviderCredentialSelection {
            if (hostManagesAuth(app) or (provider != .configured and model_provider.authorizesCredential(provider, app.auth.credentialSource()))) return .unchanged;
            var preferred: ?credentials.Source = null;
            if (provider == .openrouter) {
                var settings = try config_runtime.loadMergedSettings(app.alloc, app.workspace_root);
                defer settings.deinit(app.alloc);
                preferred = settings.credential_source;
            }
            return app.auth.selectForProvider(app.alloc, provider, preferred);
        }

        pub fn restoreSessionCredential(app: *App, previous_provider: model_provider.ProviderId) !void {
            // Hydration can run before App.init returns, so it must not start background tasks.
            const provider = provider_runtime.provider(app);
            const provider_changed = !previous_provider.same_authority(provider);
            if (provider_changed) {
                app.model_cache.resetForProviderChange();
            }
            if (hostManagesAuth(app)) return;
            const selection = selectProviderCredential(app, provider) catch |err| {
                if (err == error.OutOfMemory) return err;
                debug_trace.logf("auth", "resumed credential preference load failed err={s}", .{@errorName(err)});
                try app.writeDomainNotice(.{
                    .topic = "auth",
                    .tone = .@"error",
                    .body = "Could not load authentication settings for the resumed session. Check user settings and retry.",
                }, true);
                app.shell.render_requests.request(.footer);
                return;
            };
            switch (selection) {
                .selected => app.model_cache.reset(),
                .unchanged => {},
                .missing => try app.writeDomainNotice(.{
                    .topic = "auth",
                    .tone = .warning,
                    .body = switch (provider) {
                        .openrouter, .groq, .openai_compatible => credentials.missing_interactive_credential_message,
                        .configured => "Configured provider authentication is unavailable. Check settings.json and its environment variable.",
                    },
                }, true),
                .failed => |failure| {
                    const classified = auth_runtime.classifyCredentialFailure(failure.source, failure.err);
                    const message = if (auth_runtime.preparationError(classified)) |err|
                        auth_runtime.preparationFailureNotice(err).?
                    else
                        "Authentication is unavailable. Run /provider to repair this source.";
                    debug_trace.logf("auth", "resumed credential unavailable source={t} err={s}", .{ failure.source, @errorName(failure.err) });
                    const body = try std.fmt.allocPrint(app.alloc, "{s}: {s}", .{ credentials.sourceLabel(failure.source), message });
                    defer app.alloc.free(body);
                    try app.writeDomainNotice(.{ .topic = "auth", .tone = .@"error", .body = body }, true);
                },
            }
            app.shell.render_requests.request(.footer);
        }

        fn missingPromptCredential(app: *App, provider: model_provider.ProviderId) !bool {
            if (provider != .openrouter) {
                if (compactionOwnsCredentialFeedback(app)) return false;
                try app.writeDomainNotice(.{
                    .topic = "auth",
                    .tone = .warning,
                    .body = if (provider == .configured)
                        "Configured provider authentication is unavailable. Check settings.json and its environment variable."
                    else if (provider == .openrouter)
                        credentials.missing_interactive_credential_message
                    else
                        credentials.missing_interactive_credential_message,
                }, true);
                app.shell.render_requests.request(.footer);
                return false;
            }

            const auth_view = app.auth.view();
            if (compactionOwnsCredentialFeedback(app)) return false;
            // Startup already stated the requirement. Repeating it on every turn
            // only pushed the conversation down the transcript.
            if (auth_view.onboarding_skipped) return false;
            app.auth.noteCredentialGuidanceShown();
            try app.writeDomainNotice(.{
                .topic = "auth",
                .tone = .warning,
                .body = credentials.missing_interactive_credential_message,
            }, true);
            app.shell.render_requests.request(.footer);
            return false;
        }

        /// Deletes one provider's saved key so a different one can be pasted.
        /// The provider's environment key, if any, is not touched. Removal
        /// clears the remembered source and re-runs precedence so the runtime
        /// never keeps running on the credential that was just deleted.
        pub fn removeStoredKey(app: *App, provider: model_provider.ProviderId) !void {
            if (try rejectPendingPreparation(app)) return;
            const stored = provider_picker_catalog.providerStoredCredential(provider) orelse {
                try writeAuthNotice(app, .{
                    .topic = "auth",
                    .tone = .warning,
                    .body = "This provider has no saved API key to remove.",
                });
                return;
            };
            const slot = credentials.secretSlotFor(stored) orelse {
                try writeAuthNotice(app, .{
                    .topic = "auth",
                    .tone = .warning,
                    .body = "This provider has no saved API key to remove.",
                });
                return;
            };
            try app.flushBeforeBlockingExternalWork();
            const removed = app.auth.secretStore().removeFor(slot) catch |err| {
                debug_trace.logf("auth", "saved key removal failed err={s}", .{@errorName(err)});
                try writeAuthNotice(app, .{
                    .topic = "auth",
                    .tone = .@"error",
                    .body = "Could not remove the saved API key. The current key is unchanged.",
                });
                return;
            };
            if (!removed) {
                try app.auth.refreshSourceInventory(app.alloc);
                try writeAuthNotice(app, .{
                    .topic = "auth",
                    .tone = .warning,
                    .body = "No saved API key found.",
                });
                return;
            }
            // A remembered source must not survive the key it pointed at, and
            // the runtime must re-resolve before the next request.
            _ = app.auth.forgetRememberedSource(app.alloc);
            applyCredentialChange(app, try app.auth.reselectByPrecedence(app.alloc));
            try writeAuthNotice(app, .{
                .topic = "auth",
                .tone = .neutral,
                .body = "Removed the saved API key. Paste a new one to replace it.",
            });
        }

        pub fn runProviderCommand(app: *App) !void {
            if (comptime !runtime_profile.allows(App, .native_auth)) {
                try app.writeDomainNotice(.{
                    .topic = "auth",
                    .tone = .warning,
                    .body = "API key setup is unavailable in this WASM session.",
                }, true);
                return;
            }
            // Title the screen the same way /help titles its menu, so the
            // command explains itself instead of opening a bare list.
            try writeProviderCommandTitle(app);
            try beginProviderPickerInventoryRefresh(app, .provider_picker_command);
        }

        /// The `/provider` header block. It states the one credential fx accepts
        /// and where a pasted key lands, matching the help menu's terse voice.
        fn writeProviderCommandTitle(app: *App) !void {
            const body =
                \\fx provider
                \\
                \\Connect fx to a model provider with an API key.
                \\
                \\Pick a provider, then a key source below, or paste a new one.
                \\New keys are saved to the credential store.
                \\
                \\You can also set OPENROUTER_API_KEY or GROQ_API_KEY in the environment.
                \\
            ;
            const runtime = app_worker_runtime.Runtime(App);
            try runtime.pushCommandOutput(app, null, .stdout, body);
            try runtime.pushCommandOutputComplete(app, null);
        }

        pub fn openSetupHub(app: *App) !void {
            if (hostManagesAuth(app)) {
                try writeAuthNotice(app, .{ .topic = "auth", .tone = .neutral, .body = credentials.host_managed_auth_message });
                return;
            }
            if (comptime !runtime_profile.allows(App, .native_auth)) {
                try app.writeDomainNotice(.{
                    .topic = "auth",
                    .tone = .warning,
                    .body = "API key setup is unavailable in this WASM session.",
                }, true);
                return;
            }
            switch (app.auth.beginSourceInventoryRefresh(app.alloc, .{
                .provider = provider_runtime.provider(app),
            })) {
                .started => {},
                .busy => try writeAuthNotice(app, .{
                    .topic = "auth",
                    .tone = .warning,
                    .body = "Authentication inventory refresh is already in progress.",
                }),
                .failed => try writeAuthNotice(app, .{
                    .topic = "auth",
                    .tone = .@"error",
                    .body = "Authentication sources could not be checked. The picker remains closed.",
                }),
            }
        }

        /// Reports blocked provider interaction without changing the composer.
        pub fn reject_provider_picker_if_busy(app: *App) !bool {
            if (!auth_transition.provider_work_busy(app.stream.active, app.worker.queuedPromptCount())) return false;
            try app.writeDomainNotice(.{
                .topic = "provider",
                .tone = .neutral,
                .body = provider_busy_message,
            }, true);
            app.shell.render_requests.request(.footer);
            return true;
        }

        fn beginProviderPickerInventoryRefresh(
            app: *App,
            destination: auth_runtime.InventoryRefreshDestination,
        ) !void {
            if (try reject_provider_picker_if_busy(app)) return;
            const prefix = picker_state.provider_prefix;
            // `/provider` opens on the provider column so every provider is
            // offered as a row, matching how the model menu opens on its items
            // instead of its filters. It no longer prefills OpenRouter's key
            // stage: that shortcut hid Groq behind a provider the user had not
            // chosen.
            var prepared = try app.input_runtime.textReplacementState().prepare(app.alloc, prefix);
            defer prepared.deinit(app.alloc);
            switch (app.auth.beginSourceInventoryRefresh(app.alloc, .{
                .provider = provider_runtime.provider(app),
                .destination = destination,
            })) {
                .started => {
                    app.input_runtime.textReplacementState().commit(app.alloc, &prepared);
                    app.shell.render_requests.request(.footer);
                },
                .busy => try writeAuthNotice(app, .{
                    .topic = "auth",
                    .tone = .warning,
                    .body = "Authentication inventory refresh is already in progress.",
                }),
                .failed => try writeAuthNotice(app, .{
                    .topic = "auth",
                    .tone = .@"error",
                    .body = "Authentication sources could not be checked. The picker remains closed.",
                }),
            }
        }

        pub fn collectSourceInventoryFacts(app: *App) !void {
            const result = app.auth.takeSourceInventoryRefresh() orelse return;
            switch (result) {
                .ready => |action| {
                    if (action.destination != .auth_picker and try reject_provider_picker_if_busy(app)) {
                        debug_trace.logf("auth", "provider picker publication dropped destination={t} reason=work_in_progress", .{action.destination});
                        if (comptime @hasField(App, "input_runtime")) {
                            if (app.input_runtime.picker.activeProviderPickerQuery(&app.input_runtime.edit_state) != null) {
                                app.input_runtime.picker.dismissInlinePicker(.provider);
                            }
                        }
                        return;
                    }
                    var unavailable = app.auth.pickerView().unavailable_sources.iterator();
                    while (unavailable.next()) |source| {
                        const body = try std.fmt.allocPrint(
                            app.alloc,
                            "{s} is unavailable. Check the saved credential or choose another option.",
                            .{credentials.sourceLabel(source)},
                        );
                        defer app.alloc.free(body);
                        try writeAuthNotice(app, .{ .topic = "auth", .tone = .warning, .body = body });
                    }
                    switch (action.destination) {
                        .auth_picker => app.auth.openPickerForProvider(app.alloc, action.provider),
                        .provider_picker_command => {},
                    }
                    app.shell.render_requests.request(.footer);
                },
                .failed => |action| {
                    if (comptime @hasField(App, "input_runtime")) {
                        if (action.destination != .auth_picker and
                            app.input_runtime.picker.activeProviderPickerQuery(&app.input_runtime.edit_state) != null)
                        {
                            app.input_runtime.picker.dismissInlinePicker(.provider);
                        }
                    }
                    try writeAuthNotice(app, .{
                        .topic = "auth",
                        .tone = .@"error",
                        .body = "Authentication sources could not be checked. The picker was not opened with stale data.",
                    });
                },
            }
        }

        pub fn applyPickerChoice(app: *App, choice: auth_runtime.Choice) !void {
            if (try rejectPendingPreparation(app)) return;
            if (comptime !oauthAuthEnabled(App)) {
                try app.writeDomainNotice(.{
                    .topic = "auth",
                    .tone = .warning,
                    .body = "Browser authentication is supplied by the embedding SDK.",
                }, true);
                return;
            }
            switch (choice) {
                // Selecting the OpenAI-compatible provider walks the inline base
                // URL then key fields; the picker owns that flow and never
                // reaches here for it. Any other provider switches directly.
                .provider => |provider| try switchProvider(app, provider, .manual),
                .source => |source| _ = try applySourceChoice(app, source),
                .action => |action| switch (action) {
                    .connections => unreachable,
                    .setup => {
                        if (comptime !runtime_profile.allows(App, .native_auth)) {
                            try app.writeDomainNotice(.{
                                .topic = "auth",
                                .tone = .warning,
                                .body = "API key setup is unavailable in this WASM session.",
                            }, true);
                            return;
                        }
                        prepareApiKeyInputBoundary(app);
                        app.auth.openApiKeyPickerFromRootForProvider(app.alloc, provider_runtime.provider(app));
                    },
                    .switch_credential => app.auth.openSwitchCredentialPicker(app.alloc),
                    .switch_provider => app.auth.openProviderPicker(app.alloc, provider_runtime.provider(app)),
                    .automatic => try applyAutomaticCredential(app),
                },
            }
        }

        pub fn routeAuthPickerByte(app: *App, byte: u8) !bool {
            if (app.auth.baseUrlEntryActive()) {
                switch (byte) {
                    3, 4 => cancelAndPopPickerStage(app),
                    '\r', '\n' => try submitBaseUrlEntry(app),
                    8, 127 => _ = app.auth.deleteBaseUrlByte(),
                    else => _ = try app.auth.appendBaseUrlByte(app.alloc, byte),
                }
                app.shell.render_requests.request(.footer);
                return true;
            }
            if (!app.auth.apiKeyEntryActive()) return false;
            switch (byte) {
                3, 4 => cancelAndPopPickerStage(app),
                '\r', '\n' => try submitApiKeyEntry(app),
                8, 127 => _ = app.auth.deleteApiKeyByte(),
                else => _ = try app.auth.appendApiKeyByte(app.alloc, byte),
            }
            app.shell.render_requests.request(.footer);
            return true;
        }

        pub fn routeAuthPickerEscapeAction(app: *App, action: anytype) bool {
            // Both inline fields own their bytes the same way, so the base URL
            // field has to stand down the same semantic keys the key field does.
            if (!app.auth.inlineEntryActive()) return false;
            return switch (action) {
                .escape, .remapped_byte, .paste_start, .paste_end => false,
                else => true,
            };
        }

        fn cancelAndPopPickerStage(app: *App) void {
            cancelPromptRetryAfterAuth(app);
            _ = app.auth.popPickerStage(app.alloc);
        }

        fn finishSubscriptionSignIn(
            app: *App,
            provider: model_provider.ProviderId,
        ) !void {
            try app.auth.refreshSourceInventory(app.alloc);
            switch (auth_transition.signInCompletion(
                provider,
                comptime provider_runtime.supported(App),
            )) {
                .switch_provider => |target| {
                    app.auth.closePicker(app.alloc);
                    try switchProvider(app, target, false, .post_oauth);
                },
                .activate_source => |source| {
                    if (!try selectCredentialSource(app, source)) {
                        cancelPromptRetryAfterAuth(app);
                        _ = app.auth.popPickerStage(app.alloc);
                        try writeAuthNotice(app, .{
                            .topic = "auth",
                            .tone = .@"error",
                            .body = "Signed in, but the stored credential could not be loaded.",
                        });
                        return;
                    }
                    app.auth.closePicker(app.alloc);
                    try writeAuthNotice(app, .{
                        .topic = "auth",
                        .tone = .neutral,
                        .body = "Signed in with OpenRouter.",
                    });
                    try resumePromptAfterAuth(app);
                },
            }
        }

        fn prepareApiKeyInputBoundary(app: *App) void {
            if (comptime @hasDecl(App, "prepareApiKeyInputBoundary")) {
                app.prepareApiKeyInputBoundary();
            }
        }

        fn submitBaseUrlEntry(app: *App) !void {
            const typed = app.auth.baseUrlInput();
            if (typed.len == 0) return;
            // Persist first so the value survives a restart, then apply it to the
            // live runtime so the current session can use it immediately.
            if (comptime @hasDecl(App, "persistOpenAiCompatibleBaseUrl")) {
                app.persistOpenAiCompatibleBaseUrl(typed) catch {};
            }
            if (comptime @hasField(App, "provider_selection")) {
                app.provider_selection.setOpenAiCompatibleBaseUrl(typed) catch {};
            }
            // Return to the key-source column for the same provider, with the
            // picker stage and composer breadcrumb updated together.
            if (comptime provider_picker_runtime.supported(App)) {
                try provider_picker_runtime.Runtime(App).openKeySourceStageAfterBaseUrl(app);
            } else {
                app.auth.openApiKeyPickerInline(app.alloc, .openai_compatible);
                app.shell.render_requests.request(.footer);
            }
        }

        fn submitApiKeyEntry(app: *App) !void {
            if (app.auth.pickerView().api_key_mask_count == 0) return;
            // The key belongs to the provider the entry was opened for, so the
            // gateway check must use that provider's validator rather than the
            // compiled default (which is OpenRouter).
            const validator: ?api_key_validator.Provider = if (comptime @hasDecl(App, "apiKeyValidator"))
                app.apiKeyValidator(app.auth.provider_picker_active)
            else
                null;
            switch (app.auth.beginApiKeySave(app.alloc, validator)) {
                .started => app.shell.render_requests.request(.footer),
                .empty => {},
                .busy => try app.writeDomainNotice(.{
                    .topic = "auth",
                    .tone = .warning,
                    .body = "Still saving the previous API key. Nothing was stored for this one; try again in a moment.",
                }, true),
            }
        }

        /// Polled from the event loop so a save that blocks on a locked key store
        /// or a slow gateway never stalls rendering.
        pub fn collectApiKeySaveFacts(app: *App) !void {
            // Runs every tick: the key column has to retire whenever its entry
            // ended, whether it was saved, cancelled, or replaced.
            defer provider_picker_runtime.Runtime(App).closeKeyColumn(app);
            const result = app.auth.takeApiKeySaveResult(app.alloc) orelse return;
            try applyApiKeySaveResult(app, result);
            // The key flow is finished once its result has landed; leaving the
            // auth picker open would surface the legacy "Setup" panel.
            app.auth.closePicker(app.alloc);
        }

        fn applyApiKeySaveResult(app: *App, result: auth_runtime.ApiKeySaveResult) !void {
            switch (result) {
                .empty => return,
                .saved => |changed| {
                    applyCredentialChange(app, changed);
                    rememberCredentialSource(
                        app,
                        credentials.storedSourceFor(app.auth.provider_picker_active) orelse .stored_key,
                    );
                    const body = try std.fmt.allocPrint(
                        app.alloc,
                        "Saved the API key to {s} and made it active.",
                        .{credentials.stored_key_backend_label},
                    );
                    defer app.alloc.free(body);
                    try app.writeDomainNotice(.{
                        .topic = "auth",
                        .tone = .neutral,
                        .body = body,
                    }, true);
                    // The key was entered under a specific provider column, so a
                    // successful save is also the user's request to run on that
                    // provider. Switch to whichever provider the entry was opened
                    // for, not a hardcoded gateway, so saving a Groq key activates
                    // Groq the same way saving an OpenRouter key activates
                    // OpenRouter.
                    if (comptime provider_runtime.supported(App) and provider_picker_runtime.supported(App)) {
                        const saved_provider = app.auth.provider_picker_active;
                        if (app.input_runtime.picker.provider_picker_stage == .api_key and
                            !provider_runtime.provider(app).eql(saved_provider))
                        {
                            try switchProvider(app, saved_provider, .manual);
                        }
                    }
                },
                .gateway_refused => {
                    const body = try std.fmt.allocPrint(
                        app.alloc,
                        "{s} refused that API key. Nothing was stored.",
                        .{provider_catalog.label(app.auth.provider_picker_active)},
                    );
                    defer app.alloc.free(body);
                    try app.writeDomainNotice(.{ .topic = "auth", .tone = .@"error", .body = body }, true);
                },
                .gateway_unavailable => {
                    const body = try std.fmt.allocPrint(
                        app.alloc,
                        "Could not verify that API key with {s}. Nothing was stored.",
                        .{provider_catalog.label(app.auth.provider_picker_active)},
                    );
                    defer app.alloc.free(body);
                    try app.writeDomainNotice(.{ .topic = "auth", .tone = .@"error", .body = body }, true);
                },
                .store_failed => {
                    const body = try std.fmt.allocPrint(
                        app.alloc,
                        "Could not save the API key to {s}. Nothing was stored.",
                        .{credentials.stored_key_backend_label},
                    );
                    defer app.alloc.free(body);
                    try app.writeDomainNotice(.{
                        .topic = "auth",
                        .tone = .@"error",
                        .body = body,
                    }, true);
                },
                .reload_failed => {
                    const body = try std.fmt.allocPrint(
                        app.alloc,
                        "Saved the API key to {s}, but could not make it active.",
                        .{credentials.stored_key_backend_label},
                    );
                    defer app.alloc.free(body);
                    try app.writeDomainNotice(.{
                        .topic = "auth",
                        .tone = .warning,
                        .body = body,
                    }, true);
                },
            }
        }

        /// Clearing the remembered choice must also re-resolve, otherwise the
        /// session would keep running on a source precedence no longer selects.
        fn applyAutomaticCredential(app: *App) !void {
            forgetCredentialSource(app);
            app.auth.closePicker(app.alloc);
            applyCredentialChange(app, try app.auth.reselectByPrecedence(app.alloc));
            try app.writeDomainNotice(.{
                .topic = "auth",
                .tone = .neutral,
                .body = "Using automatic credential precedence again.",
            }, true);
            try resumePromptAfterAuth(app);
        }

        fn forgetCredentialSource(app: *App) void {
            var attempt = config_runtime.attemptUserPreferences(
                app.alloc,
                .{ .clear_credential_source = true },
            );
            defer attempt.deinit(app.alloc);
            switch (attempt) {
                .outcome => debug_trace.logf("auth", "credential choice cleared", .{}),
                .failure => |failure| debug_trace.logf(
                    "auth",
                    "credential choice not cleared err={s}",
                    .{@errorName(failure.err)},
                ),
            }
        }

        /// Reports whether the credential actually switched, so callers that
        /// chain further work (the inline picker's provider switch) can stop
        /// when it did not. Failure is already explained to the user here.
        pub fn applySourceChoice(app: *App, source: credentials.Source) !bool {
            if (try rejectPendingPreparation(app)) return false;
            const body = try std.fmt.allocPrint(
                app.alloc,
                "Switched credential to {s}.",
                .{credentials.sourceLabel(source)},
            );
            defer app.alloc.free(body);

            if (!try selectCredentialSource(app, source)) {
                try app.writeDomainNotice(.{
                    .topic = "auth",
                    .tone = .warning,
                    .body = "That credential is no longer available. The current source is unchanged.",
                }, true);
                return false;
            }

            rememberCredentialSource(app, source);
            try app.writeDomainNotice(.{
                .topic = "auth",
                .tone = .neutral,
                .body = body,
            }, true);
            try resumePromptAfterAuth(app);
            return true;
        }

        /// An explicit source choice outlives the session. Failing to persist
        /// leaves the source active for this run rather than refusing a working
        /// credential the user already selected.
        fn rememberCredentialSource(app: *App, source: credentials.Source) void {
            if (source == .stored_key or source == .groq_stored_key) return;
            if (comptime @hasDecl(App, "persistCredentialSourcePreference")) {
                app.persistCredentialSourcePreference(source);
                return;
            }

            var attempt = config_runtime.attemptUserPreferences(
                app.alloc,
                .{ .credential_source = source },
            );
            defer attempt.deinit(app.alloc);
            switch (attempt) {
                .outcome => debug_trace.logf("auth", "credential choice persisted source={t}", .{source}),
                .failure => |failure| debug_trace.logf(
                    "auth",
                    "credential choice not persisted source={t} err={s}",
                    .{ source, @errorName(failure.err) },
                ),
            }
        }

        fn switchProvider(
            app: *App,
            target: model_provider.ProviderId,
            intent: ProviderSwitchIntent,
        ) !void {
            try startProviderSwitch(app, target, intent, null);
        }

        fn startProviderSwitch(
            app: *App,
            target: model_provider.ProviderId,
            intent: ProviderSwitchIntent,
            fallback: ?model_provider.ProviderId,
        ) !void {
            if (comptime !provider_runtime.supported(App) or
                !@hasDecl(App, "providerCatalog") or
                !@hasDecl(@TypeOf(app.auth), "beginProviderPreparation"))
            {
                try app.writeDomainNotice(.{
                    .topic = "provider",
                    .tone = .warning,
                    .body = "Provider switching is unavailable in this host.",
                }, true);
                return;
            }
            if (try rejectPendingPreparation(app)) return;
            switch (decideProviderSwitch(.{
                .current = provider_runtime.provider(app),
                .target = target,
                .target_credential_ready = model_provider.authorizesCredential(target, app.auth.credentialSource()),
                .intent = intent,
                .stream_active = app.stream.active or pendingPromptBlocksPreparation(app),
                .queued_prompts = app.worker.queuedPromptCount(),
            })) {
                .prepare => {},
                .no_change => {
                    const body = try std.fmt.allocPrint(app.alloc, "Already using {s}.", .{provider_catalog.label(target)});
                    defer app.alloc.free(body);
                    try app.writeDomainNotice(.{
                        .topic = "provider",
                        .tone = .neutral,
                        .body = body,
                    }, true);
                    return;
                },
                .busy => {
                    try app.writeDomainNotice(.{
                        .topic = "provider",
                        .tone = .warning,
                        .body = providerFailureMessage(intent, provider_busy_message, "Subscription sign-in completed, but provider activation is unavailable until active and queued work finishes. The current provider is unchanged."),
                    }, true);
                    return;
                },
            }
            var settings = config_runtime.loadMergedSettings(app.alloc, app.workspace_root) catch |err| {
                debug_trace.logf("provider", "settings load failed err={s}", .{@errorName(err)});
                try app.writeDomainNotice(.{
                    .topic = "provider",
                    .tone = .@"error",
                    .body = "Could not load the saved provider selection. The current provider is unchanged.",
                }, true);
                return;
            };
            defer settings.deinit(app.alloc);
            const catalog_provider = app.providerCatalog(target) orelse {
                try app.writeDomainNotice(.{
                    .topic = "provider",
                    .tone = .@"error",
                    .body = "The target provider catalog is unavailable. The current provider is unchanged.",
                }, true);
                return;
            };
            try beginPreparation(app, .{
                .intent = .{ .provider = .{ .target = target, .origin = intent, .fallback = fallback } },
                .catalog_provider = catalog_provider,
                .models_path = app.model_cache.models_path,
                .preferred_source = preferred_source: {
                    // A remembered source belongs to the provider that stored
                    // it. Offering another provider's source as a preference
                    // resolves no credential at all, which the user then reads
                    // as "no API key" even though one is saved.
                    const saved = if (target == .openrouter) settings.credential_source else null;
                    if (saved) |source| {
                        if (model_provider.authorizesCredential(target, source)) {
                            break :preferred_source source;
                        }
                    }
                    break :preferred_source null;
                },
                .primary_model = if (intent == .post_oauth and provider_runtime.provider(app).eql(target)) provider_runtime.model(app) else null,
                .preferred_model = if (intent == .post_oauth) settings.models.get(target) else io_mod.getenv("FX_MODEL") orelse settings.models.get(target),
            });
        }

        fn pendingPromptBlocksPreparation(app: *const App) bool {
            if (comptime !@hasField(App, "submission")) return false;
            const pending = app.submission.pending orelse return false;
            return pending.credential_admitted or pending.phase == .queued;
        }

        fn pendingPromptNeedsAdoption(app: *const App) bool {
            if (comptime !@hasField(App, "submission")) return false;
            const pending = app.submission.pending orelse return false;
            return pending.phase == .awaiting_frame or pending.phase == .awaiting_adoption;
        }

        fn rejectPendingPreparation(app: *App) !bool {
            if (comptime !@hasDecl(@TypeOf(app.auth), "providerPreparationPending")) return false;
            if (!app.auth.providerPreparationPending()) return false;
            try app.writeDomainNotice(.{
                .topic = "provider",
                .tone = .neutral,
                .body = "Provider preparation is still in progress. ctrl+c cancels.",
            }, true);
            return true;
        }

        fn beginPreparation(app: *App, input: auth_runtime.ProviderPreparationInput) !void {
            app.auth.beginProviderPreparation(app.alloc, input) catch |err| {
                debug_trace.logf("provider", "preparation start failed err={s}", .{@errorName(err)});
                try app.writeDomainNotice(.{
                    .topic = "provider",
                    .tone = .@"error",
                    .body = "Could not start provider preparation. The current provider is unchanged.",
                }, true);
                return;
            };
            const body = try std.fmt.allocPrint(app.alloc, "Preparing {s}.", .{provider_catalog.label(input.target())});
            defer app.alloc.free(body);
            try app.writeDomainNotice(.{
                .topic = "provider",
                .tone = .neutral,
                .body = body,
            }, true);
        }

        pub fn collectProviderPreparationFacts(app: *App) !void {
            if (comptime !@hasDecl(@TypeOf(app.auth), "takeProviderPreparation")) return;
            if (pendingPromptNeedsAdoption(app)) return;
            const task = app.auth.takeProviderPreparation() orelse return;
            defer task.deinit();
            if (task.cancel_requested.load(.seq_cst)) {
                holdPromptAfterPreparationFailure(app);
                try app.writeDomainNotice(.{
                    .topic = "provider",
                    .tone = .neutral,
                    .body = "Provider preparation cancelled. The current provider is unchanged.",
                }, true);
                return;
            }
            const applied = switch (task.input.intent) {
                .provider => try finishProviderSwitch(app, task),
            };
            if (applied) {
                if (comptime @hasField(App, "submission")) {
                    if (app.submission.pending) |pending| {
                        if (pending.phase == .awaiting_auth) requestPromptRetryAfterAuth(app);
                    }
                }
                try resumePromptAfterAuth(app);
                return;
            }
            if (task.input.intent == .provider) {
                if (task.input.intent.provider.fallback) |target| {
                    try startProviderSwitch(app, target, .manual, null);
                    if (app.auth.providerPreparationPending()) return;
                }
            }
            holdPromptAfterPreparationFailure(app);
        }

        fn holdPromptAfterPreparationFailure(app: *App) void {
            if (comptime !@hasField(App, "submission")) return;
            if (app.submission.pending) |*pending| {
                if (pending.phase == .adopted) {
                    pending.phase = .awaiting_auth;
                    app.submission.retry_after_auth = app.auth.apiKeyEntryActive();
                    debug_trace.logf("provider", "pending prompt retained after preparation failure", .{});
                }
            }
        }

        fn finishProviderSwitch(app: *App, task: *auth_runtime.ProviderPreparation) !bool {
            const request = task.input.intent.provider;
            const target = request.target;
            const intent = request.origin;
            if (task.failure) |err| {
                debug_trace.logf("provider", "preparation failed target={t} err={s}", .{ target, @errorName(err) });
                if (task.credential == null and !hostManagesAuth(app)) {
                    const body = try auth_runtime.preparationFailureText(app.alloc, target, err);
                    defer app.alloc.free(body);
                    try app.writeDomainNotice(.{
                        .topic = "auth",
                        .tone = .@"error",
                        .body = body,
                    }, true);
                } else {
                    try app.writeDomainNotice(.{
                        .topic = "provider",
                        .tone = .@"error",
                        .body = providerFailureMessage(intent, "Could not load the target provider catalog. The current provider is unchanged.", "Subscription sign-in completed, but its model catalog could not be loaded. The current provider is unchanged."),
                    }, true);
                }
                return false;
            }
            if (task.credential == null and !hostManagesAuth(app)) {
                try app.writeDomainNotice(.{
                    .topic = "provider",
                    .tone = .warning,
                    .body = credentials.missing_interactive_credential_message,
                }, true);
                return false;
            }
            const fetched = task.catalog orelse return false;
            task.catalog = null;
            var catalog = switch (fetched) {
                .catalog => |catalog| catalog,
                .failure => |failure| {
                    debug_trace.logf("provider", "catalog rejected provider={t} category={t}", .{ target, failure.category });
                    try app.writeDomainNotice(.{
                        .topic = "provider",
                        .tone = .@"error",
                        .body = if (failure.category == .cancellation) "Provider switching was cancelled. The current provider is unchanged." else providerFailureMessage(intent, "The target provider catalog could not be validated. The current provider is unchanged.", "Subscription sign-in completed, but its model catalog could not be validated. The current provider is unchanged."),
                    }, true);
                    return false;
                },
            };
            defer model_catalog.freeModelCatalog(app.alloc, &catalog);
            const selected_model = selectCatalogModel(catalog.items, task.input.primary_model, task.input.preferred_model) orelse {
                try app.writeDomainNotice(.{
                    .topic = "provider",
                    .tone = .@"error",
                    .body = providerFailureMessage(intent, "The target provider returned no supported models. The current provider is unchanged.", "Subscription sign-in completed, but its model catalog returned no supported models. The current provider is unchanged."),
                }, true);
                return false;
            };
            var credential = task.credential;
            task.credential = null;
            defer if (credential) |*value| value.deinit(app.alloc);
            const access: credentials.CatalogAccess = if (hostManagesAuth(app)) .host_managed else credentials.catalogAccessForCredentialAndAccount(credential.?.source, credential.?.token, null, null);
            var owned_model = try app.alloc.dupe(u8, selected_model);
            defer app.alloc.free(owned_model);

            if (auth_transition.provider_work_busy(app.stream.active, app.worker.queuedPromptCount())) {
                try app.writeDomainNotice(.{
                    .topic = "provider",
                    .tone = .warning,
                    .body = providerFailureMessage(
                        intent,
                        provider_busy_message,
                        "Subscription sign-in completed, but provider activation is unavailable until active and queued work finishes. The current provider is unchanged.",
                    ),
                }, true);
                return false;
            }

            app.model_cache.adoptOwnedCatalog(access, &catalog);
            app.provider_selection.adoptOwned(target, &owned_model);
            if (credential) |*value| _ = app.auth.adoptCredential(app.alloc, value);
            reconcileGatewayCredential(app);

            const body = try std.fmt.allocPrint(
                app.alloc,
                "Switched to {s} with {s}.",
                .{ provider_catalog.label(target), provider_runtime.model(app) },
            );
            defer app.alloc.free(body);
            if (comptime @hasDecl(App, "persistRuntimePreferences")) {
                var persistence = app.persistRuntimePreferences(.{
                    .provider = target,
                    .model = provider_runtime.model(app),
                });
                defer persistence.deinit(app.alloc);
                if (persistence.settings_error != null or persistence.session_error != null) {
                    debug_trace.logf(
                        "provider",
                        "runtime switch persistence failed settings={s} session={s}",
                        .{
                            if (persistence.settings_error) |err| @errorName(err) else "none",
                            if (persistence.session_error) |err| @errorName(err) else "none",
                        },
                    );
                    try app.writeDomainNotice(.{
                        .topic = "provider",
                        .tone = .warning,
                        .body = "Provider switched for this run, but the selection could not be saved.",
                    }, true);
                } else {
                    try app.writeDomainNotice(.{
                        .topic = "provider",
                        .tone = .neutral,
                        .body = body,
                    }, true);
                }
            } else {
                var persistence = config_runtime.attemptUserPreferences(app.alloc, .{
                    .provider = target,
                    .model_preference = .{
                        .provider = target,
                        .model = provider_runtime.model(app),
                    },
                });
                defer persistence.deinit(app.alloc);
                switch (persistence) {
                    .outcome => try app.writeDomainNotice(.{ .topic = "provider", .tone = .neutral, .body = body }, true),
                    .failure => |failure| {
                        debug_trace.logf("provider", "runtime switch persistence failed err={s}", .{@errorName(failure.err)});
                        try app.writeDomainNotice(.{
                            .topic = "provider",
                            .tone = .warning,
                            .body = "Provider switched for this run, but the selection could not be saved.",
                        }, true);
                    },
                }
            }
            app.shell.render_requests.request(.footer);
            return true;
        }

        /// OpenRouter has no account or team concept: the picker goes straight
        /// to choosing a credential source or saving a key.
        pub const TeamColumn = enum {
            /// The picker has nothing left to load.
            ready,
        };

        pub fn loadTeamsForProviderPicker(app: *App) !TeamColumn {
            _ = app;
            return .ready;
        }

        pub fn selectCredentialSource(app: *App, source: credentials.Source) !bool {
            const changed = (try app.auth.selectSource(app.alloc, source)) orelse return false;
            applyCredentialChange(app, changed);
            return true;
        }

        fn refreshFxLoginCredentialIfNeeded(app: *App) !void {
            const change = try app.auth.refreshSelectedCredentialIfNeeded(app.alloc);
            applyCredentialRefreshChange(app, change);
        }

        fn applyCredentialRefreshChange(
            app: *App,
            change: auth_transition.CredentialChange,
        ) void {
            if (change == .none) return;
            reconcileGatewayCredential(app);
            if (app.auth.modelCatalogAccess().authorizationCredential() == null) return;
            if (change == .authority) app.model_cache.reset();
            if (comptime @hasDecl(App, "startModelCacheWarmup")) {
                app.startModelCacheWarmup();
            }
        }

        pub fn admitPromptCredential(app: *App) !bool {
            if (comptime !oauthAuthEnabled(App)) {
                if (app.auth.apiKey() != null) return true;
                if (compactionOwnsCredentialFeedback(app)) return false;
                try app.writeDomainNotice(.{
                    .topic = "auth",
                    .tone = .warning,
                    .body = "Missing FX_API_KEY. Supply it through createFxTerminal().",
                }, true);
                return false;
            }
            if (!try ensurePromptCredential(app)) return false;
            return preparePromptCredential(app);
        }

        pub fn startPromptCredentialPrewarm(app: *App) void {
            if (comptime @hasDecl(@TypeOf(app.auth), "providerPreparationPending")) {
                if (app.auth.providerPreparationPending()) return;
            }
            if (comptime !@hasDecl(@TypeOf(app.auth), "beginPromptCredentialRefresh")) return;
            if (comptime provider_runtime.supported(App)) {
                if (!model_provider.authorizesCredential(provider_runtime.provider(app), app.auth.credentialSource())) return;
            }
            const outcome = app.auth.beginPromptCredentialRefresh();
            debug_trace.logf(
                "auth",
                "prompt credential prewarm start outcome={s}",
                .{@tagName(outcome)},
            );
        }

        pub fn collectPendingPromptCredential(
            app: *App,
        ) !PendingPromptCredentialReadiness {
            if (comptime @hasDecl(@TypeOf(app.auth), "providerPreparationPending")) {
                if (app.auth.providerPreparationPending()) return .pending;
            }
            if (!try ensurePromptCredential(app)) return .rejected;
            const source = app.auth.credentialSource() orelse return .rejected;
            // An OpenRouter key is a static secret with no refresh lifecycle, so
            // there is never a background refresh to wait on here.
            _ = source;
            return if (app.auth.gatewayCredential() != null) .current else .rejected;
        }

        pub fn retryPendingPromptCredential(
            app: *App,
        ) !PendingPromptCredentialReadiness {
            if (comptime @hasDecl(@TypeOf(app.auth), "providerPreparationPending")) {
                if (app.auth.providerPreparationPending()) return .pending;
            }
            if (!try ensurePromptCredential(app)) return .rejected;
            if (comptime @hasDecl(@TypeOf(app.auth), "credentialFailure")) {
                if (app.auth.credentialFailure()) |failure| {
                    if (!failure.retryable()) {
                        return if (try preparePromptCredential(app)) .current else .rejected;
                    }
                }
            }
            // A static API key never needs a refresh round trip, so the answer
            // is simply whether one is already loaded.
            return if (app.auth.gatewayCredential() != null or try preparePromptCredential(app)) .current else .rejected;
        }

        fn preparePromptCredential(app: *App) !bool {
            if (comptime @hasDecl(@TypeOf(app.auth), "credentialFailure")) {
                if (app.auth.credentialFailure()) |failure| {
                    if (failure.requiresSignIn()) {
                        try beginCredentialRepair(app, failure);
                        return false;
                    }
                }
            }
            for (0..2) |_| {
                refreshFxLoginCredentialIfNeeded(app) catch |err| switch (err) {
                    error.OutOfMemory => return err,
                    else => return recoverPromptCredentialRefreshFailure(app, err),
                };
                if (app.auth.gatewayCredential() != null) return true;
            }
            return recoverPromptCredentialRefreshFailure(app, error.CredentialRefreshUnavailable);
        }

        fn beginCredentialRepair(
            app: *App,
            failure: auth_runtime.CredentialFailure,
        ) !void {
            requestPromptRetryAfterAuth(app);
            switch (failure.source) {
                .openrouter_api_key,
                .stored_key,
                .groq_api_key,
                .groq_stored_key,
                .openai_compatible_api_key,
                .openai_compatible_key,
                .host_managed,
                .configured,
                => {},
            }
        }

        fn requestPromptRetryAfterAuth(app: *App) void {
            if (comptime @hasDecl(App, "requestPromptRetryAfterAuth")) {
                app.requestPromptRetryAfterAuth();
            }
        }

        fn cancelPromptRetryAfterAuth(app: *App) void {
            if (comptime @hasDecl(App, "cancelPromptRetryAfterAuth")) {
                app.cancelPromptRetryAfterAuth();
            }
        }

        fn resumePromptAfterAuth(app: *App) !void {
            if (comptime @hasDecl(App, "resumePromptAfterAuth")) {
                try app.resumePromptAfterAuth();
            }
        }

        fn recoverPromptCredentialRefreshFailure(app: *App, err: anyerror) !bool {
            const active_source = app.auth.credentialSource();
            const source = if (active_source) |active|
                if (credentials.sourceRefreshable(active)) active else .openrouter_api_key
            else
                .openrouter_api_key;
            return recoverCredentialFailure(app, source, err);
        }

        fn recoverCredentialFailure(app: *App, source: credentials.Source, err: anyerror) !bool {
            debug_trace.logf("auth", "prompt credential refresh failed source={t} err={s}", .{ source, @errorName(err) });
            const failure = auth_runtime.classifyCredentialFailure(source, err);
            debug_trace.logf(
                "auth",
                "credential failure source={t} reason={t} retryable={s}",
                .{ failure.source, failure.reason, if (failure.retryable()) "true" else "false" },
            );
            const notify = !compactionOwnsCredentialFeedback(app);
            const should_notify = if (app.auth.credentialSource() == source and
                comptime @hasDecl(@TypeOf(app.auth), "recordCredentialFailure"))
                app.auth.recordCredentialFailure(failure, .{ .notify = notify })
            else
                notify;
            if (!should_notify) return false;
            const recovery = try credentialRecoveryText(app.alloc, failure);
            defer app.alloc.free(recovery);
            try app.writeDomainNotice(.{
                .topic = "auth",
                .tone = .@"error",
                .body = recovery,
            }, true);
            app.shell.render_requests.request(.footer);
            return false;
        }

        fn credentialRecoveryText(
            alloc: std.mem.Allocator,
            failure: auth_runtime.CredentialFailure,
        ) ![]u8 {
            const source_label = credentials.sourceLabel(failure.source);
            return switch (failure.reason) {
                .invalid_credential => std.fmt.allocPrint(
                    alloc,
                    "{s} sign-in expired.\npress enter to sign in again. Your prompt is saved.",
                    .{source_label},
                ),
                .invalid_storage => std.fmt.allocPrint(
                    alloc,
                    "{s}: Saved credential storage is unavailable.\nCheck credential storage, then press enter to retry. Your prompt is saved.",
                    .{source_label},
                ),
                .persistence_uncertain => std.fmt.allocPrint(
                    alloc,
                    "{s} refresh could not be saved.\npress enter to sign in again. Your prompt is saved.",
                    .{source_label},
                ),
                .authority_changed => std.fmt.allocPrint(
                    alloc,
                    "{s} account or team changed during refresh.\nReview authentication before retrying. Your prompt is saved.",
                    .{source_label},
                ),
                .temporary_unavailable => std.fmt.allocPrint(
                    alloc,
                    "{s} credential refresh failed.\npress enter to retry. Your prompt is saved.",
                    .{source_label},
                ),
            };
        }

        fn applyCredentialChange(app: *App, changed: bool) void {
            if (!changed) return;
            if (comptime @hasDecl(@TypeOf(app.auth), "cancelPromptCredentialRefresh")) {}
            reconcileGatewayCredential(app);
            app.model_cache.reset();
            if (comptime @hasDecl(App, "startModelCacheWarmup")) {
                app.startModelCacheWarmup();
            }
        }

        fn reconcileGatewayCredential(app: *App) void {
            if (comptime !runtime_profile.allows(App, .generation_usage)) return;
            if (comptime @hasField(App, "session") and
                @hasField(@TypeOf(app.session), "usage"))
            {
                if (app.auth.gatewayCredential()) |credential| {
                    if (gatewayCredentialSource(credential) == .host_managed) {
                        if (comptime @hasDecl(@TypeOf(app.session.usage), "replaceHostManagedReconciliationAuthority")) {
                            app.session.usage.replaceHostManagedReconciliationAuthority(
                                app.alloc,
                                provider_runtime.provider(app),
                            );
                        }
                        return;
                    }
                    const subscription = if (comptime @hasField(@TypeOf(credential), "source"))
                        credential.source == .stored_key or credential.source == .groq_stored_key
                    else
                        false;
                    if (subscription) {
                        app.session.usage.clearReconciliationCredential();
                    } else {
                        if (comptime @hasDecl(
                            @TypeOf(app.session.usage),
                            "replaceProviderReconciliationCredential",
                        )) {
                            if (optionalGatewayApiKey(credential)) |api_key| {
                                app.session.usage.replaceProviderReconciliationCredential(
                                    app.alloc,
                                    provider_runtime.provider(app),
                                    credential.source,
                                    null,
                                    api_key,
                                );
                            }
                        } else {
                            if (optionalGatewayApiKey(credential)) |api_key| {
                                app.session.usage.replaceReconciliationCredential(
                                    app.alloc,
                                    api_key,
                                );
                            }
                        }
                    }
                } else {
                    app.session.usage.clearReconciliationCredential();
                }
            }
        }

        fn writeAuthNotice(app: *App, notice: types.SemanticNotice) !void {
            try app.writeDomainNotice(notice, true);
            app.shell.render_requests.request(.first_frame);
            try app.flushBeforeBlockingExternalWork();
        }
    };
}

const TestModelCache = struct {
    models_path: []const u8 = "/models",
    reset_count: usize = 0,

    fn reset(self: *TestModelCache) void {
        self.reset_count += 1;
    }
};

const BusySignInAuth = struct {
    start_count: usize = 0,

    fn signInBrowserUrlAlloc(_: *BusySignInAuth, _: std.mem.Allocator) !?[]u8 {
        return null;
    }
};

const BusySignInApp = struct {
    pub const host_profile = runtime_profile.native;

    alloc: std.mem.Allocator = std.testing.allocator,
    selected_provider: model_provider.ProviderId = .openrouter,
    selected_model: std.ArrayList(u8) = .empty,
    auth: BusySignInAuth = .{},
    stream: struct { active: bool = false } = .{},
    worker: struct {
        queued_prompts: usize = 0,

        fn queuedPromptCount(self: @This()) usize {
            return self.queued_prompts;
        }

        pub fn pushEvent(self: *@This(), _: std.mem.Allocator, _: anytype) !void {
            _ = self;
        }
    } = .{},
    shell: struct { render_requests: TestRenderRequests = .{} } = .{},
    notice_count: usize = 0,
    flush_count: usize = 0,

    fn deinit(self: *BusySignInApp) void {
        self.selected_model.deinit(self.alloc);
    }

    fn writeDomainNotice(self: *BusySignInApp, _: types.SemanticNotice, _: bool) !void {
        self.notice_count += 1;
    }

    fn flushBeforeBlockingExternalWork(self: *BusySignInApp) !void {
        self.flush_count += 1;
    }

    fn urlOpener(_: *BusySignInApp) host.UrlOpener {
        return host.unavailable_url_opener;
    }
};

const TestTeam = struct {
    name: []const u8,
    slug: []const u8,
};

const test_teams = [_]TestTeam{.{
    .name = "OpenRouter",
    .slug = "openrouter-labs",
}};

const TestSelectedTeam = struct {
    fn deinit(_: *TestSelectedTeam, _: std.mem.Allocator) void {}
};

const TestTeamSelection = struct {
    teams: struct {
        items: []const TestTeam = &test_teams,
    } = .{},
    select_count: usize = 0,

    fn validationCredential(
        self: *const TestTeamSelection,
        alloc: std.mem.Allocator,
        index: usize,
    ) !credentials.Credential {
        if (index >= self.teams.items.len) return error.InvalidTeamSelection;
        return .{
            .token = try alloc.dupe(u8, "candidate-token"),
            .source = .openrouter_api_key,
            .team_slug = try alloc.dupe(u8, self.teams.items[index].slug),
        };
    }

    fn select(
        self: *TestTeamSelection,
        _: std.mem.Allocator,
        index: usize,
    ) error{ InvalidTeamSelection, SessionChanged, NoSession }!TestSelectedTeam {
        if (index >= self.teams.items.len) return error.InvalidTeamSelection;
        self.select_count += 1;
        return .{};
    }
};

const TestAuth = struct {
    select_result: ?bool = false,
    logout_changed: bool = false,
    refresh_change: auth_transition.CredentialChange = .none,
    refresh_error: ?anyerror = null,
    selected_source: ?credentials.Source = null,
    active_source: ?credentials.Source = .openrouter_api_key,
    onboarding_skipped: bool = false,
    refresh_count: usize = 0,
    logout_reconcile_count: usize = 0,
    source_inventory_refresh_count: usize = 0,
    credential_failure: ?auth_runtime.CredentialFailure = null,
    credential_notice_claimed: bool = false,
    picker_opened: bool = false,
    picker_provider: model_provider.ProviderId = .openrouter,
    provider_picker_active: model_provider.ProviderId = .openrouter,
    picker_closed: bool = false,
    gateway_ready: bool = true,
    catalog_ready: bool = true,
    gateway_ready_after_refresh_count: ?usize = null,
    team_selection: TestTeamSelection = .{},
    sign_in_url: ?[]const u8 = null,
    picker_pop_count: usize = 0,
    sign_in_entry_active: bool = false,
    sign_in_start_count: usize = 0,
    sign_in_code_entry_active: bool = false,
    sign_in_code_toggle_count: usize = 0,
    sign_in_code_toggle_succeeds: bool = true,
    sign_in_code_submit_count: usize = 0,
    sign_in_code_submit_succeeds: bool = true,
    inventory_refresh_action: ?auth_runtime.InventoryRefreshAction = null,
    inventory_refresh_fails: bool = false,
    prompt_refresh_start_count: usize = 0,

    fn openApiKeyPickerFromRoot(_: *TestAuth, _: std.mem.Allocator) void {}

    fn openApiKeyPickerFromRootForProvider(_: *TestAuth, _: std.mem.Allocator, _: model_provider.ProviderId) void {}

    fn noteCredentialGuidanceShown(self: *TestAuth) void {
        self.onboarding_skipped = true;
    }

    fn credentialSource(self: *const TestAuth) ?credentials.Source {
        return self.active_source;
    }

    fn view(self: *const TestAuth) auth_runtime.View {
        return .{
            .active_source = self.active_source,
            .available_inactive_sources = .empty,
            .stored_key_status = .not_attempted,
            .onboarding_skipped = self.onboarding_skipped,
        };
    }

    fn beginPromptCredentialRefresh(self: *TestAuth) auth_runtime.PromptCredentialRefreshStart {
        self.prompt_refresh_start_count += 1;
        return self.prompt_refresh_start;
    }

    fn cancelPromptCredentialRefresh(_: *TestAuth) void {}

    fn selectSource(self: *TestAuth, _: std.mem.Allocator, source: credentials.Source) !?bool {
        self.selected_source = source;
        if (self.select_result != null) self.active_source = source;
        return self.select_result;
    }

    fn pulseSignIn(_: *TestAuth, _: std.mem.Allocator) void {}

    fn popPickerStage(self: *TestAuth, _: std.mem.Allocator) bool {
        self.picker_pop_count += 1;
        return true;
    }

    fn signInEntryActive(self: *const TestAuth) bool {
        return self.sign_in_entry_active;
    }

    fn openSignInPicker(self: *TestAuth, _: std.mem.Allocator) !bool {
        if (self.sign_in_entry_active) return false;
        self.sign_in_entry_active = true;
        self.sign_in_start_count += 1;
        return true;
    }

    fn openSignInPickerFromRoot(self: *TestAuth, alloc: std.mem.Allocator) !bool {
        return self.openSignInPicker(alloc);
    }

    fn signInCodeEntryActive(self: *const TestAuth) bool {
        return self.sign_in_code_entry_active;
    }

    fn toggleSignInCodeEntry(self: *TestAuth) bool {
        self.sign_in_code_toggle_count += 1;
        if (!self.sign_in_code_toggle_succeeds) return false;
        self.sign_in_code_entry_active = !self.sign_in_code_entry_active;
        return true;
    }

    fn submitSignInCode(self: *TestAuth, _: std.mem.Allocator) !bool {
        self.sign_in_code_submit_count += 1;
        return self.sign_in_code_submit_succeeds;
    }

    fn deleteSignInCodeByte(_: *TestAuth) bool {
        return true;
    }

    fn appendSignInCodeByte(_: *TestAuth, _: std.mem.Allocator, _: u8) !bool {
        return true;
    }

    fn teamPickerActive(_: *const TestAuth) bool {
        return false;
    }

    fn deleteTeamQueryByte(_: *TestAuth) bool {
        return false;
    }

    fn appendTeamQueryByte(_: *TestAuth, _: std.mem.Allocator, _: u8) !bool {
        return false;
    }

    fn apiKeyEntryActive(_: *const TestAuth) bool {
        return false;
    }

    fn deleteApiKeyByte(_: *TestAuth) bool {
        return false;
    }

    fn appendApiKeyByte(_: *TestAuth, _: std.mem.Allocator, _: u8) !bool {
        return false;
    }

    fn pickerView(_: *const TestAuth) auth_runtime.PickerView {
        return .{
            .active = false,
            .available_sources = .empty,
            .selected_choice = null,
            .active_source = null,
            .include_skip = false,
        };
    }

    fn beginApiKeySave(_: *TestAuth, _: std.mem.Allocator, _: ?api_key_validator.Provider) auth_runtime.ApiKeySaveStart {
        return .empty;
    }

    fn refreshSelectedCredentialIfNeeded(
        self: *TestAuth,
        _: std.mem.Allocator,
    ) !auth_transition.CredentialChange {
        self.refresh_count += 1;
        if (self.refresh_error) |err| return err;
        if (self.gateway_ready_after_refresh_count == self.refresh_count) self.gateway_ready = true;
        return self.refresh_change;
    }

    fn gatewayCredential(self: *const TestAuth) ?TestGatewayCredential {
        return if (self.gateway_ready) .{ .api_key = "refreshed-key" } else null;
    }

    fn adoptPreparedCredential(
        self: *TestAuth,
        _: std.mem.Allocator,
        _: *credentials.Credential,
    ) auth_transition.CredentialChange {
        return self.refresh_change;
    }

    fn modelCatalogAccess(self: *const TestAuth) credentials.CatalogAccess {
        return if (self.catalog_ready)
            credentials.catalogAccessForCredential(.openrouter_api_key, "refreshed-key", "team_123")
        else
            .{ .public_only = .{ .openrouter_key_rejected = .openrouter_api_key } };
    }

    fn reconcileAfterFxLoginLogout(self: *TestAuth, _: std.mem.Allocator) !bool {
        self.logout_reconcile_count += 1;
        return self.logout_changed;
    }

    fn refreshSourceInventory(self: *TestAuth, _: std.mem.Allocator) !void {
        self.source_inventory_refresh_count += 1;
    }

    fn beginSourceInventoryRefresh(
        self: *TestAuth,
        _: std.mem.Allocator,
        action: auth_runtime.InventoryRefreshAction,
    ) auth_runtime.InventoryRefreshStart {
        if (self.inventory_refresh_action != null) return .busy;
        self.source_inventory_refresh_count += 1;
        self.inventory_refresh_action = action;
        return .started;
    }

    fn takeSourceInventoryRefresh(
        self: *TestAuth,
    ) ?auth_runtime.InventoryRefreshResult {
        const action = self.inventory_refresh_action orelse return null;
        self.inventory_refresh_action = null;
        return if (self.inventory_refresh_fails)
            .{ .failed = action }
        else
            .{ .ready = action };
    }

    fn recordCredentialFailure(
        self: *TestAuth,
        failure: auth_runtime.CredentialFailure,
        options: struct { notify: bool = true },
    ) bool {
        const same_failure = if (self.credential_failure) |current|
            current.source == failure.source and current.reason == failure.reason
        else
            false;
        if (!same_failure) {
            self.credential_failure = failure;
            self.credential_notice_claimed = false;
        }
        if (!options.notify or self.credential_notice_claimed) return false;
        self.credential_notice_claimed = true;
        return true;
    }

    fn credentialFailure(self: *const TestAuth) ?auth_runtime.CredentialFailure {
        return self.credential_failure;
    }

    fn openPickerForProvider(
        self: *TestAuth,
        _: std.mem.Allocator,
        provider: model_provider.ProviderId,
    ) void {
        self.picker_opened = true;
        self.picker_provider = provider;
    }

    fn loadedTeamSelection(self: *TestAuth) ?*TestTeamSelection {
        return &self.team_selection;
    }

    fn closePicker(self: *TestAuth, _: std.mem.Allocator) void {
        self.picker_closed = true;
    }

    fn signInBrowserUrlAlloc(self: *TestAuth, alloc: std.mem.Allocator) !?[]u8 {
        const url = self.sign_in_url orelse return null;
        return try alloc.dupe(u8, url);
    }
};

const TestGatewayCredential = struct {
    api_key: []const u8,
};

const TestUsage = struct {
    refresh_count: usize = 0,
    clear_count: usize = 0,
    last_key: ?[]const u8 = null,

    fn replaceReconciliationCredential(
        self: *TestUsage,
        _: std.mem.Allocator,
        api_key: []const u8,
    ) void {
        self.refresh_count += 1;
        self.last_key = api_key;
    }

    fn clearReconciliationCredential(self: *TestUsage) void {
        self.clear_count += 1;
        self.last_key = null;
    }
};

const TestRenderRequests = struct {
    footer_requested: bool = false,

    fn request(self: *TestRenderRequests, _: anytype) void {
        self.footer_requested = true;
    }
};

const TestUrlOpener = struct {
    calls: usize = 0,
    succeeds: bool = true,
    error_on_open: bool = false,
    opened_url: [256]u8 = undefined,
    opened_url_len: usize = 0,

    fn opener(self: *TestUrlOpener) host.UrlOpener {
        return .{
            .context = self,
            .open_fn = open,
        };
    }

    fn open(
        raw_context: ?*anyopaque,
        _: std.mem.Allocator,
        url: []const u8,
    ) host.UrlOpenError!bool {
        const self: *TestUrlOpener = @ptrCast(@alignCast(raw_context.?));
        self.calls += 1;
        if (url.len > self.opened_url.len) return error.OutOfMemory;
        @memcpy(self.opened_url[0..url.len], url);
        self.opened_url_len = url.len;
        if (self.error_on_open) return error.OutOfMemory;
        return self.succeeds;
    }

    fn openedUrl(self: *const TestUrlOpener) []const u8 {
        return self.opened_url[0..self.opened_url_len];
    }
};

const TestApp = struct {
    alloc: std.mem.Allocator = std.testing.allocator,
    submission: @import("input_submit_runtime.zig").State = .{},
    selected_provider: model_provider.ProviderId = .openrouter,
    auth: TestAuth = .{},
    input_runtime: @import("../input/runtime.zig").Runtime = .{},
    stream: struct { active: bool = false } = .{},
    worker: struct {
        queued_prompts: usize = 0,

        fn queuedPromptCount(self: @This()) usize {
            return self.queued_prompts;
        }

        pub fn pushEvent(self: *@This(), _: std.mem.Allocator, _: anytype) !void {
            _ = self;
        }
    } = .{},
    model_cache: TestModelCache = .{},
    session: struct {
        usage: TestUsage = .{},
    } = .{},
    model_cache_warmup_count: usize = 0,
    notice_write_count: usize = 0,
    transcript: std.ArrayList(u8) = .empty,
    test_url_opener: TestUrlOpener = .{},
    preference_write_count: usize = 0,
    last_preference_source: ?credentials.Source = null,
    preference_write_succeeds: bool = true,
    team_catalog_accepted: bool = true,
    shell: struct {
        render_requests: TestRenderRequests = .{},
    } = .{},

    fn deinit(self: *TestApp) void {
        self.input_runtime.deinit(self.alloc);
        self.transcript.deinit(self.alloc);
    }

    fn startModelCacheWarmup(self: *TestApp) void {
        self.model_cache_warmup_count += 1;
    }

    fn writeTranscriptClassified(self: *TestApp, text: []const u8, _: bool, _: anytype) !void {
        try self.transcript.appendSlice(self.alloc, text);
    }

    fn writeDomainNotice(self: *TestApp, notice: types.SemanticNotice, _: bool) !void {
        self.notice_write_count += 1;
        try self.transcript.appendSlice(self.alloc, notice.body);
        try self.transcript.append(self.alloc, '\n');
    }

    fn flushBeforeBlockingExternalWork(_: *TestApp) !void {}

    fn urlOpener(self: *TestApp) host.UrlOpener {
        return self.test_url_opener.opener();
    }

    fn persistCredentialSourcePreference(self: *TestApp, source: credentials.Source) void {
        self.preference_write_count += 1;
        if (self.preference_write_succeeds) self.last_preference_source = source;
    }

    fn providerCatalog(self: *TestApp, _: model_provider.ProviderId) ?model_catalog.Provider {
        return .{ .context = self, .fetch_fn = fetchTestCatalog };
    }

    fn fetchTestCatalog(raw: ?*anyopaque, _: std.mem.Allocator, _: model_catalog.FetchInput) std.mem.Allocator.Error!model_catalog.ProviderResult {
        const self: *TestApp = @ptrCast(@alignCast(raw.?));
        if (!self.team_catalog_accepted) {
            return .{ .failure = .{ .category = .authentication } };
        }
        var entries: std.ArrayList(model_catalog.ModelCatalogEntry) = .empty;
        errdefer model_catalog.freeModelCatalog(self.alloc, &entries);
        try entries.append(self.alloc, .{
            .id = try self.alloc.dupe(u8, "test/model"),
            .model_type = try self.alloc.dupe(u8, "language"),
        });
        return .{ .catalog = entries };
    }
};
