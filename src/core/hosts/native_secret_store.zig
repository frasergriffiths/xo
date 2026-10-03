const std = @import("std");
const builtin = @import("builtin");
const debug_trace = @import("../shared/debug_trace.zig");
const host = @import("host.zig");
const io_mod = @import("../shared/io.zig");
const keychain = @import("native_keychain.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const secret = @import("../auth/secret.zig");

const Allocator = std.mem.Allocator;

/// Names the backend that answers on this platform so operators can tell where a
/// stored key lives without knowing how the backend is selected.
const backend_label = if (builtin.os.tag == .macos) "macOS Keychain" else "profile file";

const max_key_file_bytes: usize = 8 * 1024;

const LoadError = host.SecretStoreLoadError;
const StoreError = host.SecretStoreWriteError;

/// Where one provider's saved credential physically lives on this platform.
const SlotLocation = struct {
    keychain_service: []const u8,
    profile_file_name: []const u8,
};

fn locationFor(slot: host.SecretSlot) SlotLocation {
    return switch (slot) {
        .openrouter => .{
            .keychain_service = keychain.service_name,
            .profile_file_name = profile_paths.api_key_file_name,
        },
        .groq => .{
            .keychain_service = keychain.groq_service_name,
            .profile_file_name = profile_paths.groq_api_key_file_name,
        },
        .openai_compatible => .{
            .keychain_service = keychain.openai_compatible_service_name,
            .profile_file_name = profile_paths.openai_compatible_api_key_file_name,
        },
    };
}

pub const provider: host.SecretStore = .{
    .backend_label = backend_label,
    .is_disabled_fn = isDisabledCallback,
    .presence_fn = presenceCallback,
    .load_fn = loadCallback,
    .store_fn = storeCallback,
    .store_interactive_fn = storeInteractiveCallback,
    .remove_fn = removeCallback,
};

/// The disable switch is named for the macOS backend, so its reader stays there.
fn isDisabled() bool {
    return keychain.isDisabled();
}

/// Returns the stored key, or null when no key is stored. An error means the store
/// could not be read, which callers must keep distinct from absence.
fn load(alloc: Allocator, slot: host.SecretSlot) LoadError!?[]u8 {
    const location = locationFor(slot);
    if (comptime builtin.os.tag == .macos) {
        return keychain.loadForSlot(alloc, slot) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.KeychainItemNotFound => null,
            else => error.StoredKeyUnreadable,
        };
    }
    return loadFromProfile(alloc, location.profile_file_name);
}

fn store(
    alloc: Allocator,
    slot: host.SecretSlot,
    value: []const u8,
) StoreError!void {
    if (value.len == 0) return error.StoredKeyWriteFailed;
    const location = locationFor(slot);
    if (comptime builtin.os.tag == .macos) {
        keychain.storeValueForService(location.keychain_service, value) catch |err|
            return writeFailed("keychain", err);
        return;
    }
    return storeInProfile(alloc, location.profile_file_name, value);
}

/// Let the platform credential store own terminal input when it supports a
/// secure prompt, keeping plaintext out of the fx process.
fn storeInteractive(slot: host.SecretSlot) StoreError!bool {
    if (comptime builtin.os.tag == .macos) {
        keychain.storeInteractiveForService(locationFor(slot).keychain_service) catch |err|
            return writeFailed("keychain_interactive", err);
        return true;
    }
    return false;
}

/// Deletes the slot's saved credential, reporting whether one was present.
fn remove(alloc: Allocator, slot: host.SecretSlot) StoreError!bool {
    if (comptime builtin.os.tag == .macos) {
        return keychain.deleteServiceItem(
            alloc,
            locationFor(slot).keychain_service,
        ) catch |err| switch (err) {
            error.KeychainItemNotFound => false,
            else => deleteFailed("keychain", err),
        };
    }
    return deleteFromProfile(alloc, locationFor(slot).profile_file_name);
}

fn isDisabledCallback(_: ?*anyopaque) bool {
    return isDisabled();
}

fn presenceCallback(_: ?*anyopaque, slot: host.SecretSlot) host.SecretStorePresence {
    if (isDisabled()) return .missing;
    if (comptime builtin.os.tag == .macos) {
        return keychain.containsForSlot(slot) catch .unavailable;
    }
    return presenceInProfile(locationFor(slot).profile_file_name);
}

fn presenceInProfile(file_name: []const u8) host.SecretStorePresence {
    const home = io_mod.getenv("HOME") orelse return .unavailable;
    var home_dir = std.Io.Dir.openDirAbsolute(io_mod.getIo(), home, .{}) catch
        return .unavailable;
    defer home_dir.close(io_mod.getIo());
    var fx_dir = home_dir.openDir(io_mod.getIo(), profile_paths.root_dir_name, .{
        .follow_symlinks = false,
    }) catch |err| return if (err == error.FileNotFound) .missing else .unavailable;
    defer fx_dir.close(io_mod.getIo());
    const stat = fx_dir.statFile(io_mod.getIo(), file_name, .{
        .follow_symlinks = false,
    }) catch |err| return if (err == error.FileNotFound) .missing else .unavailable;
    if (stat.kind != .file or stat.permissions.toMode() & 0o077 != 0) return .unavailable;
    return if (stat.size == 0) .missing else .present;
}

fn loadCallback(
    _: ?*anyopaque,
    alloc: Allocator,
    slot: host.SecretSlot,
) LoadError!?[]u8 {
    return load(alloc, slot);
}

fn storeCallback(
    _: ?*anyopaque,
    alloc: Allocator,
    slot: host.SecretSlot,
    value: []const u8,
) StoreError!void {
    return store(alloc, slot, value);
}

fn storeInteractiveCallback(
    _: ?*anyopaque,
    slot: host.SecretSlot,
) StoreError!bool {
    return storeInteractive(slot);
}

fn removeCallback(_: ?*anyopaque, slot: host.SecretSlot) StoreError!bool {
    return remove(std.heap.page_allocator, slot);
}

fn loadFromProfile(alloc: Allocator, file_name: []const u8) LoadError!?[]u8 {
    const home = io_mod.getenv("HOME") orelse {
        debug_trace.logf("stored_key", "load failed step=home err=HomeNotSet", .{});
        return error.StoredKeyUnreadable;
    };
    var home_dir = std.Io.Dir.openDirAbsolute(io_mod.getIo(), home, .{ .iterate = true }) catch |err| {
        debug_trace.logf("stored_key", "load failed step=open_home err={s}", .{@errorName(err)});
        return error.StoredKeyUnreadable;
    };
    defer home_dir.close(io_mod.getIo());

    var fx_dir = home_dir.openDir(io_mod.getIo(), profile_paths.root_dir_name, .{
        .iterate = true,
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => {
            debug_trace.logf("stored_key", "load failed step=open_profile err={s}", .{@errorName(err)});
            return error.StoredKeyUnreadable;
        },
    };
    defer fx_dir.close(io_mod.getIo());

    return loadFromDir(alloc, &fx_dir, file_name);
}

fn loadFromDir(
    alloc: Allocator,
    fx_dir: *std.Io.Dir,
    file_name: []const u8,
) LoadError!?[]u8 {
    var file = fx_dir.openFile(io_mod.getIo(), file_name, .{
        .mode = .read_only,
        .allow_directory = false,
        .follow_symlinks = false,
        .resolve_beneath = true,
    }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => {
            debug_trace.logf("stored_key", "load failed step=open_file err={s}", .{@errorName(err)});
            return error.StoredKeyUnreadable;
        },
    };
    defer file.close(io_mod.getIo());

    const stat = file.stat(io_mod.getIo()) catch |err| {
        debug_trace.logf("stored_key", "load failed step=stat err={s}", .{@errorName(err)});
        return error.StoredKeyUnreadable;
    };
    if (stat.kind != .file or stat.permissions.toMode() & 0o077 != 0) {
        debug_trace.logf("stored_key", "load failed step=permissions err=StoredKeyInsecure", .{});
        return error.StoredKeyInsecure;
    }

    const bytes = io_mod.readFileToEnd(alloc, &file, max_key_file_bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            debug_trace.logf("stored_key", "load failed step=read err={s}", .{@errorName(err)});
            return error.StoredKeyUnreadable;
        },
    };
    var borrowed = false;
    defer if (!borrowed) secret.zeroAndFree(alloc, bytes);

    const trimmed = std.mem.trim(u8, bytes, "\r\n");
    if (trimmed.len == 0) return null;
    if (trimmed.len == bytes.len) {
        borrowed = true;
        return bytes;
    }
    return try alloc.dupe(u8, trimmed);
}

fn storeInProfile(
    alloc: Allocator,
    file_name: []const u8,
    value: []const u8,
) StoreError!void {
    const home = io_mod.getenv("HOME") orelse return writeFailed("home", error.HomeNotSet);
    var home_dir = io_mod.VerifiedDir{
        .dir = std.Io.Dir.openDirAbsolute(io_mod.getIo(), home, .{ .iterate = true }) catch |err| {
            return writeFailed("open_home", err);
        },
    };
    defer home_dir.close();

    var fx_dir = io_mod.openOrCreateVerifiedPrivateDir(&home_dir, profile_paths.root_dir_name) catch |err| {
        return writeFailed("open_profile", err);
    };
    defer fx_dir.close();

    return storeInDir(alloc, &fx_dir, file_name, value);
}

/// `durableReplaceVerified` creates the file at 0600 and re-stats it after the rename,
/// so the mode this store depends on is enforced rather than assumed.
fn storeInDir(
    alloc: Allocator,
    fx_dir: *io_mod.VerifiedDir,
    file_name: []const u8,
    value: []const u8,
) StoreError!void {
    io_mod.durableReplaceVerified(alloc, fx_dir, file_name, value) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return writeFailed("replace", err),
    };
}

fn deleteFromProfile(alloc: Allocator, file_name: []const u8) StoreError!bool {
    _ = alloc;
    const home = io_mod.getenv("HOME") orelse return false;
    var home_dir = std.Io.Dir.openDirAbsolute(io_mod.getIo(), home, .{ .iterate = true }) catch
        return deleteFailed("open_home", error.HomeNotSet);
    defer home_dir.close(io_mod.getIo());
    var fx_dir = home_dir.openDir(io_mod.getIo(), profile_paths.root_dir_name, .{
        .iterate = true,
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return deleteFailed("open_profile", err),
    };
    defer fx_dir.close(io_mod.getIo());
    fx_dir.deleteFile(io_mod.getIo(), file_name) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return deleteFailed("delete", err),
    };
    return true;
}

fn writeFailed(step: []const u8, err: anyerror) StoreError {
    debug_trace.logf("stored_key", "store failed step={s} err={s}", .{ step, @errorName(err) });
    return error.StoredKeyWriteFailed;
}

fn deleteFailed(step: []const u8, err: anyerror) StoreError {
    debug_trace.logf("stored_key", "delete failed step={s} err={s}", .{ step, @errorName(err) });
    return error.StoredKeyWriteFailed;
}
