const std = @import("std");
const model_catalog = @import("../core/gateway/model_catalog.zig");
const host_stream = @import("host_stream_provider.zig");
const openrouter = @import("openrouter.zig");
const openrouter_models = @import("openrouter_models.zig");
const Allocator = std.mem.Allocator;

/// Borrows the host transport for the lifetime of the provider. The embedding
/// host performs the fetch, so the browser build never needs a direct socket.
pub fn provider(transport: *host_stream.Transport) model_catalog.Provider {
    return .{
        .context = transport,
        .fetch_fn = fetch,
        .provider_id = .openrouter,
        .refresh_interval_ms = openrouter_models.model_catalog_provider.refresh_interval_ms,
    };
}

fn fetch(raw: ?*anyopaque, alloc: Allocator, input: model_catalog.FetchInput) Allocator.Error!model_catalog.ProviderResult {
    const transport: *host_stream.Transport = @ptrCast(@alignCast(raw.?));
    const auth = if (input.access.authorizationCredential()) |credential|
        try std.fmt.allocPrint(alloc, "Bearer {s}", .{credential})
    else
        null;
    defer if (auth) |value| alloc.free(value);
    const Header = struct { name: []const u8, value: []const u8 };
    var headers: std.ArrayList(Header) = .empty;
    defer headers.deinit(alloc);
    if (auth) |value| try headers.append(alloc, .{ .name = "authorization", .value = value });
    var encoded: std.Io.Writer.Allocating = .init(alloc);
    defer encoded.deinit();
    std.json.Stringify.value(headers.items, .{}, &encoded.writer) catch return error.OutOfMemory;
    if (cancelled(input)) return .{ .failure = .{ .category = .cancellation } };
    const handle = transport.open_fn(transport.context, "GET", openrouter.models_path, encoded.written(), "") catch
        return .{ .failure = .{ .category = .transport } };
    if (handle < 0) return .{ .failure = .{ .category = .transport } };
    defer transport.close_fn(transport.context, handle);
    var status: u16 = 0;
    while (true) {
        if (cancelled(input)) return .{ .failure = .{ .category = .cancellation } };
        const state = transport.status_fn(transport.context, handle, &status);
        if (state == 1) break;
        if (state < 0) return .{ .failure = .{ .category = if (state == -2) .cancellation else .transport } };
    }
    if (status != 200) return .{ .failure = model_catalog.failureForHttpStatus(@enumFromInt(status)) };
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(alloc);
    var chunk: [16 * 1024]u8 = undefined;
    while (true) {
        if (cancelled(input)) return .{ .failure = .{ .category = .cancellation } };
        const count = transport.next_fn(transport.context, handle, &chunk);
        if (count == -3) continue;
        if (count < 0) return .{ .failure = .{ .category = if (count == -2) .cancellation else .transport } };
        if (count == 0) break;
        const size: usize = @intCast(count);
        if (size > chunk.len or size > 8 * 1024 * 1024 -| body.items.len) return .{ .failure = .{ .category = .resource_exhausted } };
        try body.appendSlice(alloc, chunk[0..size]);
    }
    const catalog = openrouter_models.parseCatalog(alloc, body.items) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .{ .failure = .{ .category = .malformed_response } };
    };
    return .{ .catalog = catalog };
}

fn cancelled(input: model_catalog.FetchInput) bool {
    return if (input.cancel_flag) |flag| flag.load(.seq_cst) else false;
}
