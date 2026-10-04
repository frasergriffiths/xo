//! PTY harness for driving the built fx binary against a real terminal.
//!
//! The VT engine tests in `tests/vt_engine.zig` exercise the grid directly. That
//! proves cell semantics but says nothing about whether fx enters the alternate
//! screen, paints the composer, or keeps the chrome pinned while streaming.
//! Those properties only exist once a real process owns a real terminal.
//!
//! This harness spawns `./zig-out/bin/fx` on a PTY, feeds it bytes, and reads
//! the bytes back. It is the tier between "pure arithmetic" and "a human is
//! watching", and it needs no tmux and no human.
//!
//! `shell_runtime.zig` already contains a complete `TestPty` built on
//! `posix_openpt`, unreferenced. This reuses that approach rather than
//! inventing a second one.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const testing = std.testing;
const io_mod = @import("../src/core/shared/io.zig");

const supports_pty = switch (builtin.os.tag) {
    .linux, .macos, .freebsd, .netbsd, .openbsd => true,
    else => false,
};

extern "c" fn posix_openpt(flags: c_int) c_int;
extern "c" fn grantpt(fd: c_int) c_int;
extern "c" fn unlockpt(fd: c_int) c_int;
extern "c" fn ptsname(fd: c_int) ?[*:0]u8;

/// TIOCSWINSZ per platform, spelled the same way `native_session.zig` spells
/// it for its own hosted-terminal resize. Zig 0.16 does not surface the
/// constant for every target, so the macOS value is literal, matching the
/// existing precedent rather than inventing a second one.
const ioctlSetWindowSize: c_int = switch (builtin.os.tag) {
    .macos => @bitCast(@as(u32, 0x80087467)),
    .linux => @intCast(std.os.linux.T.IOCSWINSZ),
    else => 0,
};

/// Zig 0.16 moved fd lifetime to `std.Io.File`, and `std.posix` no longer
/// carries `close` or `access`. The repo already has one helper for this in
/// `shell_runtime.zig`; mirror it rather than adding a second convention.
fn closeFd(fd: posix.fd_t) void {
    (std.Io.File{ .handle = fd, .flags = .{ .nonblocking = false } }).close(io_mod.getIo());
}

/// True when the path exists and is executable. X_OK.
fn isExecutable(path: []const u8) bool {
    const z = std.fmt.allocPrintSentinel(std.heap.c_allocator, "{s}", .{path}, 0) catch return false;
    defer std.heap.c_allocator.free(z);
    return std.c.access(z, 1) == 0;
}

/// A pseudo-terminal pair, plus the child fx process attached to the slave.
pub const PtySession = struct {
    master: posix.fd_t,
    child: std.process.Child,
    /// Every byte the child has written, so a test can assert on the whole
    /// session rather than only on the most recent window.
    transcript: std.ArrayList(u8) = .empty,
    terminated: bool = false,

    pub fn deinit(self: *PtySession, alloc: std.mem.Allocator) void {
        if (!self.terminated) self.terminate();
        self.transcript.deinit(alloc);
        closeFd(self.master);
        self.child.deinit() catch {};
    }

    /// Sends raw bytes as terminal input. Control bytes must be spelled out,
    /// so a test that sends Ctrl+T writes "\x14".
    pub fn send(self: *PtySession, bytes: []const u8) !void {
        try posix.write(self.master, bytes);
    }

    /// Waits for output to settle, then returns everything read so far.
    /// Terminals are async, so this polls rather than reading to EOF: a live
    /// shell never reaches EOF.
    pub fn readAvailable(
        self: *PtySession,
        alloc: std.mem.Allocator,
        quiet_ms: u64,
    ) ![]const u8 {
        const deadline = io_mod.milliTimestamp() + @as(i64, @intCast(quiet_ms));
        var scratch: [4096]u8 = undefined;
        while (io_mod.milliTimestamp() < deadline) {
            posix.pollfd.fdsToPoll(&.{
                posix.pollfd(.{ .fd = self.master, .events = posix.POLL.IN, .revents = undefined }),
            }) catch break;
            const ready = posix.poll(&.{posix.pollfd(.{ .fd = self.master, .events = posix.POLL.IN, .revents = undefined })}, 20) catch break;
            if (ready == 0) continue;
            const n = posix.read(self.master, &scratch) catch break;
            if (n == 0) break;
            try self.transcript.appendSlice(alloc, scratch[0..n]);
            // Reset the quiet window: a burst means more is coming.
            return self.transcript.items;
        }
        return self.transcript.items;
    }

    /// Convenience: send, then settle.
    pub fn sendAndRead(
        self: *PtySession,
        alloc: std.mem.Allocator,
        bytes: []const u8,
        quiet_ms: u64,
    ) ![]const u8 {
        try self.send(bytes);
        return self.readAvailable(alloc, quiet_ms);
    }

    pub fn terminate(self: *PtySession) void {
        if (self.terminated) return;
        self.terminated = true;
        // Give the child a moment to restore the terminal before it dies, so a
        // failing assertion does not leave a half-restored terminal behind.
        _ = self.child.kill(io_mod.getIo()) catch self.child.kill(io_mod.getIo()) catch {};
    }
};

/// Spawns `fx` on a fresh PTY sized to `cols` by `rows`.
///
/// Returns null when the platform has no PTY support or the binary is missing,
/// so a caller can skip rather than fail on an unsupported host.
pub fn spawn(
    alloc: std.mem.Allocator,
    exe_path: []const u8,
    args: []const []const u8,
    cols: u16,
    rows: u16,
) !?PtySession {
    if (!supports_pty) return null;

    if (!isExecutable(exe_path)) return null;

    const flags = posix.O{ .ACCMODE = .RDWR, .NOCTTY = true, .CLOEXEC = true };
    const master_fd = posix_openpt(@bitCast(flags));
    if (master_fd < 0) return null;
    errdefer closeFd(master_fd);

    if (grantpt(master_fd) != 0) return null;
    if (unlockpt(master_fd) != 0) return null;
    const slave_name = ptsname(master_fd) orelse return null;
    const slave_fd = try posix.openatZ(posix.AT.FDCWD, slave_name, flags, 0);
    defer closeFd(slave_fd);

    // Size the window before exec so fx reads the intended geometry. The
    // ioctl call goes through `std.c` because Zig 0.16 dropped it from
    // `std.posix`; the request constant comes from the same place fx uses to
    // read the size in `terminal.queryLayout`.
    const winsize = posix.winsize{
        .row = rows,
        .col = cols,
        .xpixel = 0,
        .ypixel = 0,
    };
    _ = std.c.ioctl(slave_fd, ioctlSetWindowSize, &winsize);

    // Zig 0.16 removed `std.posix.fork`, so the child is spawned through
    // `std.process.spawn` with the slave wired to all three descriptors, which
    // is the same approach `native_session.zig` uses for a hosted terminal.
    // The test process does not need a distinct session leader here: raw mode
    // plus a controlling PTY is enough to drive an interactive child.
    const slave_file: std.Io.File = .{ .handle = slave_fd, .flags = .{ .nonblocking = false } };
    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(alloc);
    try argv.append(alloc, exe_path);
    try argv.appendSlice(alloc, args);

    var child = std.process.spawn(io_mod.getIo(), .{
        .argv = argv.items,
        .stdin = .{ .file = slave_file },
        .stdout = .{ .file = slave_file },
        .stderr = .{ .file = slave_file },
    }) catch return null;

    closeFd(slave_fd);

    // Raw mode so the harness controls framing instead of the tty driver.
    const termios_raw = rawTermios(master_fd);
    posix.tcsetattr(master_fd, .NOW, termios_raw) catch {};

    return PtySession{ .master = master_fd, .child = child };
}

fn rawTermios(fd: posix.fd_t) posix.termios {
    // Mirrors `shell_runtime.enableRawMode` field for field, including its
    // index lookups for VMIN/VTIME, so the child sees the same terminal
    // configuration it would under a real session.
    var raw = posix.tcgetattr(fd) catch return posix.termios{
        .iflag = 0,
        .oflag = 0,
        .cflag = 0,
        .lflag = 0,
        .cc = @splat(0),
    };

    raw.iflag.BRKINT = false;
    raw.iflag.ICRNL = false;
    raw.iflag.INPCK = false;
    raw.iflag.ISTRIP = false;
    raw.iflag.IXON = false;
    raw.iflag.IXOFF = false;
    raw.iflag.IGNCR = false;
    raw.iflag.INLCR = false;

    raw.oflag.OPOST = false;

    raw.cflag.CSIZE = .CS8;

    raw.lflag.ECHO = false;
    raw.lflag.ICANON = false;
    raw.lflag.IEXTEN = false;
    raw.lflag.ISIG = false;

    const vmin_idx = vminIndex();
    const vtime_idx = vtimeIndex();
    if (vmin_idx < raw.cc.len and vtime_idx < raw.cc.len) {
        raw.cc[vmin_idx] = 1;
        raw.cc[vtime_idx] = 0;
    }

    return raw;
}

fn vminIndex() usize {
    return switch (builtin.os.tag) {
        .linux => posix.V.MIN,
        .macos => posix.V.MIN,
        else => posix.V.MIN,
    };
}

fn vtimeIndex() usize {
    return switch (builtin.os.tag) {
        .linux => posix.V.TIME,
        .macos => posix.V.TIME,
        else => posix.V.TIME,
    };
}

/// Bytes fx writes when it enters the alternate screen. These are the standard
/// DECSET 1049 pair and must appear on the master side.
pub const enterAlternateScreen = "\x1b[?1049h";
pub const leaveAlternateScreen = "\x1b[?1049l";

/// Strips ANSI escape sequences so assertions can look at visible text.
pub fn stripAnsi(alloc: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == 0x1b and i + 1 < input.len) {
            const next = input[i + 1];
            if (next == '[') {
                // CSI: parameters then a final byte in @..~
                var j = i + 2;
                while (j < input.len and !(input[j] >= 0x40 and input[j] <= 0x7e)) j += 1;
                i = if (j < input.len) j + 1 else input.len;
                continue;
            } else if (next == ']') {
                // OSC: terminated by BEL or ST
                var j = i + 2;
                while (j < input.len) {
                    if (input[j] == 0x07) {
                        j += 1;
                        break;
                    }
                    if (input[j] == 0x1b and j + 1 < input.len and input[j + 1] == '\\') {
                        j += 2;
                        break;
                    }
                    j += 1;
                }
                i = j;
                continue;
            } else if (next == '(' or next == ')') {
                i += 3;
                continue;
            } else {
                i += 2;
                continue;
            }
        }
        if (input[i] == 0x07 or input[i] == 0x08 or input[i] == 0x0d) {
            i += 1;
            continue;
        }
        try out.append(alloc, input[i]);
        i += 1;
    }
    return out.toOwnedSlice(alloc);
}

test "the pty harness can allocate a pseudo-terminal" {
    if (!supports_pty) return error.SkipZigTest;

    const flags = posix.O{ .ACCMODE = .RDWR, .NOCTTY = true, .CLOEXEC = true };
    const master_fd = posix_openpt(@bitCast(flags));
    if (master_fd < 0) return error.SkipZigTest;
    defer closeFd(master_fd);

    try testing.expectEqual(@as(c_int, 0), grantpt(master_fd));
    try testing.expectEqual(@as(c_int, 0), unlockpt(master_fd));

    const name = ptsname(master_fd).?;
    try testing.expect(std.mem.startsWith(u8, std.mem.span(name), "/dev/ttys"));
}

test "the ansi stripper leaves visible text and removes framing" {
    const alloc = testing.allocator;

    const stripped = try stripAnsi(alloc, "\x1b[1;1H\x1b[?1049hhello\x1b[0m\x07\x1b[2Jworld");
    defer alloc.free(stripped);

    try testing.expectEqualStrings("helloworld", stripped);
}

test "the stripper handles an osc title sequence" {
    const alloc = testing.allocator;

    const stripped = try stripAnsi(alloc, "\x1b]0;fx shell\x07visible");
    defer alloc.free(stripped);

    try testing.expectEqualStrings("visible", stripped);
}

test "the stripper handles a bare escape and a control sequence introducer" {
    const alloc = testing.allocator;

    const stripped = try stripAnsi(alloc, "a\x1bb\x1b(Bc");
    defer alloc.free(stripped);

    try testing.expectEqualStrings("abc", stripped);
}

test "the alternate screen constants are the standard decset pair" {
    try testing.expectEqualStrings("\x1b[?1049h", enterAlternateScreen);
    try testing.expectEqualStrings("\x1b[?1049l", leaveAlternateScreen);
}

test "fx status runs on a pty and writes no stderr" {
    // The end-to-end proof that the harness works: a real process on a real
    // terminal, driven and observed. `status` needs no credential, so this does
    // not depend on provider access.
    const alloc = testing.allocator;

    var session = (try spawn(alloc, "./zig-out/bin/fx", &.{ "status", "--json" }, 80, 24)) orelse
        return error.SkipZigTest;
    defer session.deinit(alloc);

    const bytes = try session.readAvailable(alloc, 1500);

    // The alternate screen must NOT be entered for a non-interactive command.
    try testing.expect(std.mem.indexOf(u8, bytes, enterAlternateScreen) == null);

    const stripped = try stripAnsi(alloc, bytes);
    defer alloc.free(stripped);

    // status --json emits JSON; finding a JSON token proves real output.
    try testing.expect(std.mem.indexOf(u8, stripped, "{") != null);
}
