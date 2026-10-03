//! Durable alias index for compacted turns and tool results.
//!
//! After a compaction the model can only cite long content-addressed handles
//! such as `result-<64 hex>` or `compaction-source-<64 hex>`. Those are correct
//! but unpleasant to type and impossible to hold in context reliably. This
//! index gives each compacted user message and each compacted tool result a
//! short, stable name, `M1`, `T1`, and up, and persists the mapping so
//! `read_tool_result` can resolve the short name back to a real handle and byte
//! range.
//!
//! The index is a single small file in the session's tool-result route. It is
//! rewritten in full by each compaction, so an index always describes the
//! handoff the model is currently looking at and can never describe a stale one.
//!
//! Every parser validates the entire document before any lookup happens, and no
//! function here builds a filesystem path from model-supplied text. A malformed
//! index is treated as absent rather than trusted.

const std = @import("std");
const testing = std.testing;
const io_mod = @import("../shared/io.zig");
const result_store = @import("../session/result_store.zig");
const child_store = @import("../session/session_child_store.zig");
const identifiers = @import("identifiers.zig");
const compat = @import("compat.zig");

const Allocator = std.mem.Allocator;

/// File name inside the session tool-result route. Fixed so `read_tool_result`
/// can find it without scanning the session directory.
pub const index_file = "compaction-aliases.json";

/// Format version. A future format bumps this; an index carrying any other
/// value is ignored rather than guessed at.
pub const format_version: u32 = 2;

/// The original version, which recorded tool names but no message names.
pub const legacy_format_version: u32 = 1;

/// An index this large is treated as corrupt rather than parsed, so a damaged
/// file cannot turn into unbounded work.
const max_index_bytes: usize = 4 * 1024 * 1024;
/// Cap on recorded entries, matching the compaction policy's own record cap.
const max_entries: usize = 8192;

pub const MessageAlias = struct {
    alias: []u8,
    /// Byte offset of this user's text inside the source archive.
    start_byte: usize,
    /// Byte length of this user's text inside the source archive.
    byte_count: usize,
};

/// Where a message alias lives inside the source archive.
pub const MessageRange = struct {
    start_byte: usize,
    byte_count: usize,
};

pub const ToolAlias = struct {
    alias: []u8,
    /// The real content-addressed handle the alias stands for.
    handle: []u8,
};

/// Owns every allocation. Callers get a `Index` whose slices are valid until
/// `deinit` runs.
pub const Index = struct {
    messages: []MessageAlias,
    tools: []ToolAlias,
    /// The source archive the message offsets are relative to. Null when the
    /// compaction recorded no readable source archive.
    source_handle: ?[]u8,

    pub fn deinit(self: *Index, alloc: Allocator) void {
        for (self.messages) |*entry| alloc.free(entry.alias);
        alloc.free(self.messages);
        for (self.tools) |*entry| {
            alloc.free(entry.alias);
            alloc.free(entry.handle);
        }
        alloc.free(self.tools);
        if (self.source_handle) |handle| alloc.free(handle);
        self.* = undefined;
    }

    /// The handle a tool alias stands for, or null when the alias is unknown.
    pub fn resolveTool(self: Index, alloc: Allocator, alias: []const u8) !?[]u8 {
        const parsed = identifiers.parse(alias) orelse return null;
        if (!parsed.isTool()) return null;
        for (self.tools) |entry| {
            if (entry.alias.len != alias.len) continue;
            if (std.mem.eql(u8, entry.alias, alias)) return try alloc.dupe(u8, entry.handle);
        }
        return null;
    }

    /// The source-archive range a message alias stands for, or null when the
    /// alias is unknown. `read_tool_result` turns this into a range read against
    /// the source archive.
    pub fn resolveMessage(self: Index, alias: []const u8) ?MessageRange {
        const parsed = identifiers.parse(alias) orelse return null;
        if (!parsed.isMessage()) return null;
        for (self.messages) |entry| {
            if (entry.alias.len != alias.len) continue;
            if (std.mem.eql(u8, entry.alias, alias)) {
                return .{ .start_byte = entry.start_byte, .byte_count = entry.byte_count };
            }
        }
        return null;
    }

    /// True when the index can answer for this alias at all. Callers use this to
    /// decide whether an alias-shaped request deserves an alias-specific
    /// diagnostic or should fall through to the ordinary missing-handle path.
    pub fn knowsAlias(self: Index, alias: []const u8) bool {
        const parsed = identifiers.parse(alias) orelse return false;
        if (parsed.isTool()) {
            for (self.tools) |entry| {
                if (entry.alias.len == alias.len and std.mem.eql(u8, entry.alias, alias)) return true;
            }
            return false;
        }
        for (self.messages) |entry| {
            if (entry.alias.len == alias.len and std.mem.eql(u8, entry.alias, alias)) return true;
        }
        return false;
    }
};

/// A borrowed view of an index, used when writing one. Unlike `Index`, nothing
/// here is owned, so the caller may pass slices that live in a wider arena.
pub const Snapshot = struct {
    messages: []const MessageAlias = &.{},
    tools: []const ToolAlias = &.{},
    source_handle: ?[]const u8 = null,
};

const Wire = struct {
    /// No default on purpose. A document missing its version must fail to parse
    /// rather than silently adopt the current one, otherwise a truncated file
    /// would be read as a valid index.
    version: u32,
    source_handle: ?[]const u8 = null,
    messages: []const WireMessage = &.{},
    tools: []const WireTool = &.{},
};

const WireMessage = struct {
    alias: []const u8,
    start_byte: usize,
    byte_count: usize,
};

const WireTool = struct {
    alias: []const u8,
    handle: []const u8,
};

/// Serializes an index. The caller owns the returned bytes.
pub fn encode(alloc: Allocator, index: Snapshot) ![]u8 {
    return encodeVersion(alloc, index, format_version);
}

/// Serializes an index at an explicit version, used to prove the version 1
/// reader still works by writing the older shape on purpose.
pub fn encodeVersion(alloc: Allocator, index: Snapshot, version: u32) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.writeAll("{\"version\":");
    try out.writer.print("{d}", .{version});
    if (index.source_handle) |handle| {
        try out.writer.writeAll(",\"source_handle\":");
        try std.json.Stringify.value(handle, .{}, &out.writer);
    }
    // Version 1 had no message table, so writing one would produce a document
    // that contradicts the version it declares.
    const write_messages = version != legacy_format_version;
    try out.writer.writeAll(",\"messages\":[");
    for (if (write_messages) index.messages else index.messages[0..0], 0..) |entry, i| {
        if (i > 0) try out.writer.writeByte(',');
        try out.writer.writeAll("{\"alias\":");
        try std.json.Stringify.value(entry.alias, .{}, &out.writer);
        try out.writer.print(",\"start_byte\":{d},\"byte_count\":{d}}}", .{ entry.start_byte, entry.byte_count });
    }
    try out.writer.writeAll("],\"tools\":[");
    for (index.tools, 0..) |entry, i| {
        if (i > 0) try out.writer.writeByte(',');
        try out.writer.writeAll("{\"alias\":");
        try std.json.Stringify.value(entry.alias, .{}, &out.writer);
        try out.writer.writeAll(",\"handle\":");
        try std.json.Stringify.value(entry.handle, .{}, &out.writer);
        try out.writer.writeByte('}');
    }
    try out.writer.writeAll("]}");
    return out.toOwnedSlice();
}

/// Parses an index. Returns null for anything malformed rather than an error,
/// so a damaged index degrades to "no aliases available" and never blocks an
/// ordinary handle read.
pub fn decode(alloc: Allocator, bytes: []const u8) !?Index {
    if (bytes.len == 0 or bytes.len > max_index_bytes) return null;
    const parsed = std.json.parseFromSlice(Wire, alloc, bytes, .{}) catch return null;
    defer parsed.deinit();
    const wire = parsed.value;
    // Version 1 is readable but recorded no message table, so a legacy index
    // resolves tool names only. Anything else is refused.
    if (wire.version != format_version and wire.version != legacy_format_version) return null;
    const has_messages = wire.version != legacy_format_version;
    if (wire.messages.len > max_entries or wire.tools.len > max_entries) return null;

    // Validate everything before allocating anything. A document is accepted
    // whole or not at all, so there is no half-built index to clean up and no
    // partially trusted entry that a later read could reach.
    if (wire.source_handle) |handle| {
        if (!isReadableHandle(handle)) return null;
    }
    for (wire.messages) |entry| {
        if (!has_messages) return null;
        if (canonicalAlias(entry.alias, identifiers.message_prefix) == null) return null;
        if (entry.byte_count == 0) return null;
    }
    for (wire.tools) |entry| {
        if (canonicalAlias(entry.alias, identifiers.tool_prefix) == null) return null;
        if (!isReadableHandle(entry.handle)) return null;
    }

    const source_handle = if (wire.source_handle) |handle| try alloc.dupe(u8, handle) else null;
    errdefer if (source_handle) |handle| alloc.free(handle);

    const messages = try alloc.alloc(MessageAlias, wire.messages.len);
    errdefer {
        for (messages) |*entry| alloc.free(entry.alias);
        alloc.free(messages);
    }
    for (wire.messages, 0..) |entry, i| {
        messages[i] = .{
            .alias = try alloc.dupe(u8, entry.alias),
            .start_byte = entry.start_byte,
            .byte_count = entry.byte_count,
        };
    }

    const tools = try alloc.alloc(ToolAlias, wire.tools.len);
    errdefer {
        for (tools[0..wire.tools.len]) |*entry| {
            alloc.free(entry.alias);
            alloc.free(entry.handle);
        }
        alloc.free(tools);
    }
    for (wire.tools, 0..) |entry, i| {
        tools[i] = .{
            .alias = try alloc.dupe(u8, entry.alias),
            .handle = try alloc.dupe(u8, entry.handle),
        };
    }

    return .{
        .messages = messages,
        .tools = tools,
        .source_handle = source_handle,
    };
}

/// True when a handle names something the result store can actually read.
///
/// Only the prefixes this codebase mints are accepted, and only over an
/// allowlist of the characters real handles contain: ASCII alphanumerics, `-`,
/// `_`, and `.`. A separator character therefore cannot appear at all, and a
/// `..` sequence is refused outright, so a persisted index can never redirect a
/// read outside the result store.
pub fn isReadableHandle(handle: []const u8) bool {
    if (handle.len == 0 or handle.len > 512) return false;
    const prefixed = std.mem.startsWith(u8, handle, "result-") or
        std.mem.startsWith(u8, handle, "compaction-") or
        std.mem.startsWith(u8, handle, "image-") or
        std.mem.startsWith(u8, handle, "diff-");
    if (!prefixed) return false;
    if (std.mem.indexOf(u8, handle, "..") != null) return false;
    for (handle) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_' and byte != '.') return false;
    }
    return true;
}

/// The alias must be exactly what `identifiers` would render for its prefix and
/// index, so `M1` is accepted and `M01` or `Mx` is not.
fn canonicalAlias(raw: []const u8, prefix: u8) ?usize {
    const parsed = identifiers.parse(raw) orelse return null;
    if (parsed.prefix != prefix) return null;
    var buffer: [12]u8 = undefined;
    const rendered = std.fmt.bufPrint(&buffer, "{c}{d}", .{ prefix, parsed.index }) catch return null;
    if (!std.mem.eql(u8, raw, rendered)) return null;
    return parsed.index;
}

// --- Persistence ---

/// Writes the index into the session's tool-result route, replacing any earlier
/// index. Ownership of the capability is not taken.
pub fn saveManaged(alloc: Allocator, capability: *child_store.SessionChildCapability, index: Snapshot) !void {
    const bytes = try encode(alloc, index);
    defer alloc.free(bytes);
    var managed = capability.createExclusiveFile(alloc, .tool_results, index_file) catch |err| switch (err) {
        // Each compaction rewrites the whole index, so an existing file is the
        // expected case rather than a conflict.
        error.PathAlreadyExists => brk: {
            capability.delete(.tool_results, index_file) catch {};
            break :brk try capability.createExclusiveFile(alloc, .tool_results, index_file);
        },
        else => return err,
    };
    defer managed.deinit();
    try managed.writeAll(bytes);
    try managed.sync();
}

/// Reads the index from a session capability, returning null when the session
/// has never compacted or the stored index is unusable.
pub fn loadManaged(alloc: Allocator, capability: *child_store.SessionChildCapability) !?Index {
    var managed = capability.openFileReadOnly(alloc, .tool_results, index_file) catch |err| switch (err) {
        error.FileNotFound, error.SessionPathUnsafe, error.NotDir, error.SymLinkLoop => return null,
        else => return err,
    };
    defer managed.deinit();
    const stat = managed.stat() catch return null;
    if (stat.size > max_index_bytes) return null;
    const bytes = managed.readToEnd(alloc, max_index_bytes) catch return null;
    defer alloc.free(bytes);
    // The version ladder decides what the stored bytes mean. An index this build
    // cannot classify behaves as though none exists, which leaves every long
    // handle in the handoff still readable.
    switch (compat.classify(alloc, bytes)) {
        .unsupported => return null,
        .current, .legacy => {},
    }
    return decode(alloc, bytes);
}

// --- Tests ---

const testing_allocator = testing.allocator;

fn testIndex(alloc: Allocator, source: ?[]const u8) !Index {
    const messages = try alloc.alloc(MessageAlias, 2);
    errdefer alloc.free(messages);
    messages[0] = .{ .alias = try alloc.dupe(u8, "M1"), .start_byte = 20, .byte_count = 100 };
    messages[1] = .{ .alias = try alloc.dupe(u8, "M2"), .start_byte = 130, .byte_count = 250 };
    const tools = try alloc.alloc(ToolAlias, 2);
    errdefer alloc.free(tools);
    tools[0] = .{ .alias = try alloc.dupe(u8, "T1"), .handle = try alloc.dupe(u8, "result-" ++ ("a" ** 64)) };
    tools[1] = .{ .alias = try alloc.dupe(u8, "T2"), .handle = try alloc.dupe(u8, "compaction-arguments-" ++ ("b" ** 64)) };
    return .{
        .messages = messages,
        .tools = tools,
        .source_handle = if (source) |handle| try alloc.dupe(u8, handle) else null,
    };
}

fn snapshotOf(index: Index) Snapshot {
    return .{ .messages = index.messages, .tools = index.tools, .source_handle = index.source_handle };
}

test "an index round-trips through encode and decode" {
    var index = try testIndex(testing_allocator, "compaction-source-" ++ ("c" ** 64));
    defer index.deinit(testing_allocator);
    const bytes = try encode(testing_allocator, snapshotOf(index));
    defer testing_allocator.free(bytes);

    var decoded = (try decode(testing_allocator, bytes)).?;
    defer decoded.deinit(testing_allocator);

    try testing.expectEqual(@as(usize, 2), decoded.messages.len);
    try testing.expectEqual(@as(usize, 2), decoded.tools.len);
    try testing.expectEqualStrings("M1", decoded.messages[0].alias);
    try testing.expectEqual(@as(usize, 130), decoded.messages[1].start_byte);
    try testing.expectEqualStrings("T2", decoded.tools[1].alias);
    try testing.expectEqualStrings("compaction-arguments-" ++ ("b" ** 64), decoded.tools[1].handle);
}

test "an empty index round-trips" {
    const empty: Snapshot = .{};
    const bytes = try encode(testing_allocator, empty);
    defer testing_allocator.free(bytes);
    var decoded = (try decode(testing_allocator, bytes)).?;
    defer decoded.deinit(testing_allocator);
    try testing.expectEqual(@as(usize, 0), decoded.messages.len);
    try testing.expectEqual(@as(usize, 0), decoded.tools.len);
    try testing.expectEqual(@as(?[]u8, null), decoded.source_handle);
}

test "tool aliases resolve to their real handle" {
    var index = try testIndex(testing_allocator, null);
    defer index.deinit(testing_allocator);
    const handle = (try index.resolveTool(testing_allocator, "T2")).?;
    defer testing_allocator.free(handle);
    try testing.expectEqualStrings("compaction-arguments-" ++ ("b" ** 64), handle);
}

test "an unknown or malformed alias resolves to nothing" {
    var index = try testIndex(testing_allocator, null);
    defer index.deinit(testing_allocator);
    for ([_][]const u8{ "T3", "T0", "Tx", "", "M1", "../T1", "T 1", "t1" }) |raw| {
        try testing.expectEqual(@as(?[]u8, null), try index.resolveTool(testing_allocator, raw));
    }
}

test "message aliases resolve to a source range" {
    var index = try testIndex(testing_allocator, null);
    defer index.deinit(testing_allocator);
    const range = index.resolveMessage("M2").?;
    try testing.expectEqual(@as(usize, 130), range.start_byte);
    try testing.expectEqual(@as(usize, 250), range.byte_count);
    try testing.expectEqual(@as(?MessageRange, null), index.resolveMessage("M3"));
    try testing.expectEqual(@as(?MessageRange, null), index.resolveMessage("T1"));
}

test "the index reports which aliases it knows" {
    var index = try testIndex(testing_allocator, null);
    defer index.deinit(testing_allocator);
    try testing.expect(index.knowsAlias("M1"));
    try testing.expect(index.knowsAlias("T2"));
    try testing.expect(!index.knowsAlias("M3"));
    try testing.expect(!index.knowsAlias("T3"));
    try testing.expect(!index.knowsAlias("nonsense"));
}

test "a malformed document decodes to nothing rather than erroring" {
    // A damaged index must never turn into an error that blocks an ordinary
    // handle read, so every case here returns null.
    for ([_][]const u8{
        "",
        "{",
        "null",
        "[]",
        "\"M1\"",
        // No version at all.
        "{\"messages\":[],\"tools\":[]}",
        // A version this build does not know, in either direction.
        "{\"version\":0,\"messages\":[],\"tools\":[]}",
        "{\"version\":3,\"messages\":[],\"tools\":[]}",
        // Version 1 recorded no message table, so a document claiming one is
        // inconsistent with the format it declares.
        "{\"version\":1,\"messages\":[{\"alias\":\"M1\",\"start_byte\":0,\"byte_count\":1}],\"tools\":[]}",
        "{\"version\":2,\"messages\":[{\"alias\":\"M1\",\"start_byte\":0,\"byte_count\":0}],\"tools\":[]}",
        "{\"version\":2,\"messages\":[{\"alias\":\"M01\",\"start_byte\":0,\"byte_count\":1}],\"tools\":[]}",
        "{\"version\":2,\"messages\":[{\"alias\":\"T1\",\"start_byte\":0,\"byte_count\":1}],\"tools\":[]}",
        "{\"version\":2,\"messages\":[],\"tools\":[{\"alias\":\"T1\",\"handle\":\"../../etc/passwd\"}]}",
        "{\"version\":2,\"messages\":[],\"tools\":[{\"alias\":\"T1\",\"handle\":\"\"}]}",
        "{\"version\":2,\"source_handle\":\"nope\",\"messages\":[],\"tools\":[]}",
    }) |raw| {
        if (try decode(testing_allocator, raw)) |leaked| {
            var mutable = leaked;
            mutable.deinit(testing_allocator);
            std.debug.print("accepted malformed index: {s}\n", .{raw});
            return error.TestAcceptedMalformedIndex;
        }
    }
}

test "an index cannot point a read outside the result store" {
    for ([_][]const u8{
        "",
        "/etc/passwd",
        "../../secret",
        "result",
        "compaction",
        "unknown-abc",
        "result-../../x",
        "result-a/b",
        "result-a b",
        "result-a\u{0}b",
        "compaction-source-..",
        "image-../diff",
        "result-\u{ff0e}\u{ff0e}/x",
    }) |handle| {
        try testing.expect(!isReadableHandle(handle));
    }
    try testing.expect(isReadableHandle("result-" ++ ("a" ** 64)));
    try testing.expect(isReadableHandle("compaction-arguments-" ++ ("b" ** 64)));
    try testing.expect(isReadableHandle("image-" ++ ("c" ** 64)));
    try testing.expect(isReadableHandle("diff-" ++ ("d" ** 64)));
}

test "an absurdly long handle is refused" {
    const long = "result-" ++ ("a" ** 4096);
    try testing.expect(!isReadableHandle(long));
}

test "the encoded index is plain JSON with no raw control bytes" {
    // Aliases and handles are minted internally, but the index is persisted and
    // parsed as JSON, so encode must never emit a byte that needs escaping and
    // decode must accept exactly what encode produced.
    var index = try testIndex(testing_allocator, "compaction-source-" ++ ("c" ** 64));
    defer index.deinit(testing_allocator);
    const bytes = try encode(testing_allocator, snapshotOf(index));
    defer testing_allocator.free(bytes);

    for (bytes) |byte| {
        const printable = byte >= 0x20 and byte < 0x7f;
        try testing.expect(printable);
    }
    var decoded = (try decode(testing_allocator, bytes)).?;
    defer decoded.deinit(testing_allocator);
    try testing.expectEqual(@as(usize, 2), decoded.messages.len);
    try testing.expectEqual(@as(usize, 2), decoded.tools.len);
}

test "an index carrying a handle the store could not mint is refused" {
    // The allowlist and the encoder have to agree: anything encode could emit
    // must decode, and anything decode would refuse must not be producible.
    for ([_][]const u8{
        "result-\"quote\"",
        "result-a b",
        "result-a/b",
        "compaction-source-..",
    }) |handle| {
        // The index owns the slice, so its deinit is the only free.
        const tools = try testing_allocator.alloc(ToolAlias, 1);
        tools[0] = .{
            .alias = try testing_allocator.dupe(u8, "T1"),
            .handle = try testing_allocator.dupe(u8, handle),
        };
        var index: Index = .{ .messages = &.{}, .tools = tools, .source_handle = null };
        defer index.deinit(testing_allocator);

        const bytes = try encode(testing_allocator, snapshotOf(index));
        defer testing_allocator.free(bytes);
        const decoded = try decode(testing_allocator, bytes);
        if (decoded) |leaked| {
            var mutable = leaked;
            mutable.deinit(testing_allocator);
            std.debug.print("accepted unmintable handle: {s}\n", .{handle});
            return error.TestAcceptedUnmintableHandle;
        }
    }
}

test "a version 1 index still resolves tool names" {
    // Version 1 recorded tool names but no message table. An fx that wrote one
    // must keep working, so the older shape is still readable.
    var index = try testIndex(testing_allocator, null);
    defer index.deinit(testing_allocator);
    const bytes = try encodeVersion(testing_allocator, snapshotOf(index), legacy_format_version);
    defer testing_allocator.free(bytes);

    var decoded = (try decode(testing_allocator, bytes)).?;
    defer decoded.deinit(testing_allocator);
    try testing.expectEqual(@as(usize, 0), decoded.messages.len);
    try testing.expectEqual(@as(usize, 2), decoded.tools.len);
    const handle = (try decoded.resolveTool(testing_allocator, "T1")).?;
    defer testing_allocator.free(handle);
    try testing.expectEqualStrings("result-" ++ ("a" ** 64), handle);
    // A message name was never recorded, so it resolves to nothing rather than
    // to the wrong bytes.
    try testing.expectEqual(@as(?MessageRange, null), decoded.resolveMessage("M1"));
    try testing.expect(!decoded.knowsAlias("M1"));
}

test "a huge document is refused without being parsed" {
    var big: [max_index_bytes + 1]u8 = undefined;
    @memset(&big, 'x');
    try testing.expectEqual(@as(?Index, null), try decode(testing_allocator, &big));
}

/// A writable capability over a fresh temporary session directory.
///
/// Session directories are only accepted when their permissions are exactly
/// 0700, so the test creates its own directory and sets them rather than
/// relying on what the platform hands back for a temp directory.
fn testCapability(alloc: Allocator) !child_store.SessionChildCapability {
    const io = io_mod.getIo();
    const tmp = std.testing.tmpDir(.{});
    try tmp.dir.createDir(io, "session", std.Io.File.Permissions.fromMode(0o700));
    const session_dir = try tmp.dir.openDir(io, "session", .{
        .iterate = true,
        .follow_symlinks = false,
    });
    defer session_dir.close(io);
    const path = try io_mod.dirRealpathAlloc(alloc, session_dir, ".");
    defer alloc.free(path);
    return child_store.SessionChildCapability.initForTesting(alloc, session_dir, path, .writable, .{});
}

test "an index saved to a session reads back unchanged" {
    var capability = try testCapability(testing_allocator);
    defer capability.deinit();

    // Nothing saved yet.
    if (try loadManaged(testing_allocator, &capability)) |loaded| {
        var mutable = loaded;
        mutable.deinit(testing_allocator);
        return error.TestExpectedAbsentIndex;
    }

    var index = try testIndex(testing_allocator, "compaction-source-" ++ ("c" ** 64));
    defer index.deinit(testing_allocator);
    try saveManaged(testing_allocator, &capability, snapshotOf(index));

    var loaded_index = (try loadManaged(testing_allocator, &capability)).?;
    defer loaded_index.deinit(testing_allocator);
    try testing.expectEqualStrings("T1", loaded_index.tools[0].alias);
    try testing.expectEqualStrings("M2", loaded_index.messages[1].alias);
    try testing.expectEqualStrings("compaction-source-" ++ ("c" ** 64), loaded_index.source_handle.?);

    // Saving again replaces the earlier index rather than failing.
    var replacement = try testIndex(testing_allocator, null);
    defer replacement.deinit(testing_allocator);
    try saveManaged(testing_allocator, &capability, snapshotOf(replacement));
    var reloaded = (try loadManaged(testing_allocator, &capability)).?;
    defer reloaded.deinit(testing_allocator);
    try testing.expectEqual(@as(?[]u8, null), reloaded.source_handle);
}

test "a session with no compaction resolves no aliases" {
    var capability = try testCapability(testing_allocator);
    defer capability.deinit();
    const loaded_index = (try loadManaged(testing_allocator, &capability));
    if (loaded_index) |found| {
        var mutable = found;
        mutable.deinit(testing_allocator);
        return error.TestExpectedAbsentIndex;
    }
}
