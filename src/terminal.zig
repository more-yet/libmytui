const std = @import("std");
const linux = std.os.linux;
const sys = @import("linux.zig");
const Size = @import("geometry.zig").Size;
const Reply = @import("input.zig").Reply;

const signals = [_]std.posix.SIG{ .WINCH, .INT, .TERM, .TSTP, .CONT };
var installed: std.atomic.Value(bool) = .init(false);
// Only the exclusive Terminal owner allocates probe IDs.
var next_image_query: u32 = 0x80000000;

pub const Terminal = struct {
    io: std.Io,
    fd: std.posix.fd_t,
    signal_fd: std.posix.fd_t,
    owns_fd: bool = false,
    original: linux.termios,
    old_mask: std.posix.sigset_t,
    alternate_screen: bool,
    frame_cursor: bool = false,
    cleanup_ms: u32,
    protocols: Protocols = .{},
    entry: Entry = .{},
    ends: EntryEnds = .{},
    entry_accepted: usize = 0,
    desired_keys: Keyboard = .{},
    applied_keys: ?Keyboard = null,
    pending_keys: Keyboard = .{},
    capabilities: Capabilities = .{},
    image_query: ?u32 = null,
    sync_frames: bool = false,
    mode: enum { idle, entry, keyboard, leave } = .idle,
    mode_bytes: [256]u8 = undefined,
    accepted: usize = 0,
    length: usize = 0,

    const absent = std.math.maxInt(u16);
    const EntryEnds = struct {
        grapheme: u16 = absent,
        screen: u16 = absent,
        cursor: u16 = absent,
        paste: u16 = absent,
        mouse_encoding: u16 = absent,
        mouse_motion: u16 = absent,
        focus: u16 = absent,
        keyboard_query: u16 = absent,
        sync_query: u16 = absent,
        image_query: u16 = absent,
        cursor_query: u16 = absent,
    };
    pub const Entry = struct { raw: bool = true, grapheme: bool = true, hide_cursor: bool = true, paste: bool = true };
    pub const Keyboard = packed struct(u5) { disambiguate: bool = true, actions: bool = true, alternate: bool = true, all_keys: bool = true, text: bool = true };

    pub const Protocols = struct {
        mouse: bool = false,
        focus: bool = false,
        kitty_keyboard: bool = false,
        synchronized_output: bool = false,
        graphics_probe: bool = false,
        cursor_query: bool = false,
    };
    pub const Support = enum { unknown, supported, unsupported };
    pub const Capabilities = struct {
        kitty_keyboard: Support = .unknown,
        synchronized_output: Support = .unknown,
        graphics: Support = .unknown,
    };

    pub fn open(io: std.Io, alternate_screen: bool, cleanup_ms: u32) !Terminal {
        const fd = try std.posix.openat(std.posix.AT.FDCWD, "/dev/tty", .{
            .ACCMODE = .RDWR,
            .NONBLOCK = true,
            .CLOEXEC = true,
        }, 0);
        errdefer _ = linux.close(fd);
        var terminal = try borrow(io, fd, alternate_screen, cleanup_ms, true);
        terminal.owns_fd = true;
        return terminal;
    }
    pub fn borrow(io: std.Io, fd: std.posix.fd_t, alternate_screen: bool, cleanup_ms: u32, manage_signals: bool) !Terminal {
        if (installed.cmpxchgStrong(false, true, .acq_rel, .acquire) != null) return error.AlreadyRunning;
        errdefer installed.store(false, .release);
        const fl = linux.fcntl(fd, linux.F.GETFL, 0);
        if (linux.errno(fl) != .SUCCESS) return error.InvalidDescriptor;
        const flags: linux.O = @bitCast(@as(u32, @intCast(fl)));
        if (!flags.NONBLOCK or flags.ACCMODE != .RDWR) return error.NeedNonblockingTerminal;
        var original: linux.termios = undefined;
        while (true) switch (linux.errno(linux.tcgetattr(fd, &original))) {
            .SUCCESS => break,
            .INTR => continue,
            else => return error.TerminalRead,
        };
        var mask = std.posix.sigemptyset();
        for (signals) |signal| std.posix.sigaddset(&mask, signal);
        var old_mask = std.posix.sigemptyset();
        if (manage_signals) std.posix.sigprocmask(std.posix.SIG.BLOCK, &mask, &old_mask);
        errdefer if (manage_signals) std.posix.sigprocmask(std.posix.SIG.SETMASK, &old_mask, null);
        const signal_fd = if (manage_signals) try std.posix.signalfd(-1, &mask, linux.SFD.NONBLOCK | linux.SFD.CLOEXEC) else -1;
        return .{
            .io = io,
            .fd = fd,
            .signal_fd = signal_fd,
            .original = original,
            .old_mask = old_mask,
            .alternate_screen = alternate_screen,
            .cleanup_ms = cleanup_ms,
        };
    }

    pub fn deinit(self: *Terminal) void {
        self.leave() catch {};
        if (self.signal_fd >= 0) {
            _ = linux.close(self.signal_fd);
            std.posix.sigprocmask(std.posix.SIG.SETMASK, &self.old_mask, null);
        }
        if (self.owns_fd) _ = linux.close(self.fd);
        installed.store(false, .release);
        self.* = undefined;
    }

    pub fn enter(self: *Terminal) !void {
        try self.beginEnter();
        try self.drain();
    }

    pub fn beginEnter(self: *Terminal) !void {
        std.debug.assert(self.mode == .idle);
        if (self.entry.raw) {
            var raw = self.original;
            raw.iflag.IGNBRK = false;
            raw.iflag.BRKINT = false;
            raw.iflag.PARMRK = false;
            raw.iflag.ISTRIP = false;
            raw.iflag.INLCR = false;
            raw.iflag.IGNCR = false;
            raw.iflag.ICRNL = false;
            raw.iflag.IXON = false;
            raw.oflag.OPOST = false;
            raw.lflag.ECHO = false;
            raw.lflag.ECHONL = false;
            raw.lflag.ICANON = false;
            raw.lflag.ISIG = false;
            raw.lflag.IEXTEN = false;
            raw.cflag.CSIZE = .CS8;
            raw.cflag.PARENB = false;
            raw.cc[@backingInt(std.posix.V.MIN)] = 1;
            raw.cc[@backingInt(std.posix.V.TIME)] = 0;
            try self.setTermios(raw);
        }
        self.capabilities = .{};
        self.ends = .{};
        self.entry_accepted = 0;
        self.mode = .entry;
        var w = std.Io.Writer.fixed(&self.mode_bytes);
        inline for (.{
            .{ self.entry.grapheme, "\x1b[?2027s", "\x1b[?2027h", "grapheme" },
            .{ self.alternate_screen, "\x1b[?1049h", "", "screen" },
            .{ self.entry.hide_cursor or self.frame_cursor, "\x1b[?25s", if (self.entry.hide_cursor) "\x1b[?25l" else "", "cursor" },
            .{ self.entry.paste, "\x1b[?2004s", "\x1b[?2004h", "paste" },
            .{ self.protocols.mouse, "\x1b[?1006s", "\x1b[?1006h", "mouse_encoding" },
            .{ self.protocols.mouse, "\x1b[?1003s", "\x1b[?1003h", "mouse_motion" },
            .{ self.protocols.focus, "\x1b[?1004s", "\x1b[?1004h", "focus" },
        }) |command| {
            if (command[0]) {
                try w.writeAll(command[1]);
                @field(self.ends, command[3]) = @intCast(w.end);
                try w.writeAll(command[2]);
            }
        }
        if (self.protocols.kitty_keyboard) {
            try w.writeAll("\x1b[?u");
            self.ends.keyboard_query = @intCast(w.end);
        }
        if (self.protocols.synchronized_output) {
            try w.writeAll("\x1b[?2026$p");
            self.ends.sync_query = @intCast(w.end);
        }
        if (self.protocols.graphics_probe) {
            if (next_image_query == std.math.maxInt(u32)) return error.ProbeIdExhausted;
            self.image_query = next_image_query;
            next_image_query += 1;
            try w.print("\x1b_Gi={d},a=q,t=d,f=24,s=1,v=1;AAAA\x1b\\", .{self.image_query.?});
            self.ends.image_query = @intCast(w.end);
        }
        if (self.protocols.cursor_query) {
            try w.writeAll("\x1b[6n");
            self.ends.cursor_query = @intCast(w.end);
        }
        self.length = w.buffered().len;
        self.accepted = 0;
    }

    pub fn observe(self: *Terminal, reply: Reply) bool {
        if (self.mode == .idle or self.mode == .leave) return false;
        switch (reply) {
            .raw => {},
            .keyboard_flags => if (self.entry_accepted >= self.ends.keyboard_query) {
                self.ends.keyboard_query = absent;
                self.capabilities.kitty_keyboard = .supported;
                return true;
            },
            .graphics => |g| if (self.entry_accepted >= self.ends.image_query and g.id == self.image_query) {
                self.ends.image_query = absent;
                self.capabilities.graphics = if (g.ok) .supported else .unsupported;
                return true;
            },
            .mode => |m| if (self.entry_accepted >= self.ends.sync_query and m.number == 2026) {
                self.ends.sync_query = absent;
                self.capabilities.synchronized_output = if (m.state >= 1 and m.state <= 3) .supported else .unsupported;
                // Acquire synchronized output only when the terminal reports it reset.
                self.sync_frames = m.state == 2;
                return true;
            },
            .cursor => if (self.entry_accepted >= self.ends.cursor_query) {
                self.ends.cursor_query = absent;
                return true;
            },
        }
        return false;
    }

    /// Commit negotiated modes only between output transactions.
    pub fn modeOutput(self: *Terminal) []const u8 {
        if (self.accepted == self.length and (self.mode == .entry or self.mode == .keyboard) and self.capabilities.kitty_keyboard == .supported and !std.meta.eql(self.applied_keys, @as(?Keyboard, self.desired_keys))) {
            self.mode = .keyboard;
            self.pending_keys = self.desired_keys;
            const push = std.fmt.bufPrint(&self.mode_bytes, "\x1b[{c}{d}u", .{ @as(u8, if (self.applied_keys != null) '=' else '>'), @as(u5, @bitCast(self.pending_keys)) }) catch unreachable;
            self.accepted = 0;
            self.length = push.len;
        }
        return self.mode_bytes[self.accepted..self.length];
    }

    pub fn consumeMode(self: *Terminal, accepted: usize) void {
        std.debug.assert(accepted <= self.length - self.accepted);
        self.accepted += accepted;
        if (self.mode == .entry) self.entry_accepted = self.accepted;
        if (self.mode == .keyboard and self.accepted == self.length) {
            self.applied_keys = self.pending_keys;
        }
    }

    pub fn leave(self: *Terminal) !void {
        if (self.mode == .idle) return;
        self.beginLeave();
        const output_result = self.drain();
        try self.restore();
        try output_result;
    }

    pub fn beginLeave(self: *Terminal) void {
        std.debug.assert(self.mode != .idle);
        if (self.mode == .leave) return;
        self.mode = .leave;
        var w = std.Io.Writer.fixed(&self.mode_bytes);
        w.writeAll("\x18\x1b\\") catch unreachable;
        if (self.sync_frames) w.writeAll("\x1b[?2026l") catch unreachable;
        if (self.applied_keys != null) w.writeAll("\x1b[<u") catch unreachable;
        const end = self.entry_accepted;
        if (end >= self.ends.mouse_motion) w.writeAll("\x1b[?1003l\x1b[?1003r") catch unreachable;
        if (end >= self.ends.mouse_encoding) w.writeAll("\x1b[?1006l\x1b[?1006r") catch unreachable;
        if (end >= self.ends.focus) w.writeAll("\x1b[?1004l\x1b[?1004r") catch unreachable;
        w.writeAll("\x1b[0 q\x1b[0m") catch unreachable;
        if (end >= self.ends.paste) w.writeAll("\x1b[?2004l") catch unreachable;
        if (end >= self.ends.cursor) w.writeAll("\x1b[?25h") catch unreachable;
        if (end >= self.ends.screen) w.writeAll("\x1b[?1049l") catch unreachable;
        if (end >= self.ends.cursor) w.writeAll("\x1b[?25r") catch unreachable;
        if (end >= self.ends.paste) w.writeAll("\x1b[?2004r") catch unreachable;
        if (end >= self.ends.grapheme) w.writeAll("\x1b[?2027r") catch unreachable;
        self.accepted = 0;
        self.length = w.buffered().len;
    }

    /// Also usable after a failed display drain; termios restoration is independent.
    pub fn restore(self: *Terminal) !void {
        std.debug.assert(self.mode == .leave);
        if (self.entry.raw) try self.setTermios(self.original);
        self.mode = .idle;
        self.accepted = 0;
        self.length = 0;
        self.applied_keys = null;
        self.sync_frames = false;
        self.image_query = null;
    }

    pub fn suspendProcess(self: *Terminal) !void {
        try self.leave();
        try std.posix.raise(.STOP);
        try self.enter();
    }

    pub fn size(self: *const Terminal) !?Size {
        var dimensions: std.posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
        while (true) switch (linux.errno(linux.ioctl(self.fd, linux.T.IOCGWINSZ, @intFromPtr(&dimensions)))) {
            .SUCCESS => break,
            .INTR => continue,
            else => return error.TerminalSize,
        };
        if (dimensions.col == 0 or dimensions.row == 0) return null;
        return .{ .width = dimensions.col, .height = dimensions.row, .pixel_width = dimensions.xpixel, .pixel_height = dimensions.ypixel };
    }

    fn setTermios(self: *Terminal, value: linux.termios) !void {
        while (true) switch (linux.errno(linux.tcsetattr(self.fd, .NOW, &value))) {
            .SUCCESS => return,
            .INTR => continue,
            else => return error.TerminalRestore,
        };
    }

    fn drain(self: *Terminal) !void {
        const deadline = sys.now(self.io) + self.cleanup_ms;
        while (self.accepted < self.length) {
            if (try sys.write(self.fd, self.mode_bytes[self.accepted..self.length])) |count| {
                self.consumeMode(count);
            } else {
                var descriptors = [_]std.posix.pollfd{.{ .fd = self.fd, .events = std.posix.POLL.OUT, .revents = 0 }};
                try sys.pollUntil(self.io, &descriptors, deadline);
            }
            if (self.accepted < self.length and sys.now(self.io) >= deadline) return error.OutputTimeout;
        }
    }
};

test "borrowed PTY mode acknowledgments gate restoration, query replies and keyboard stack depth" {
    const io = std.testing.io;
    var child = try @import("process.zig").PtyProcess.start("/bin/sleep", &.{ "sleep", "30" }, &.{}, .{ .width = 8, .height = 3 });
    defer child.deinit() catch unreachable;
    var terminal = try Terminal.borrow(io, child.master, true, 50, false);
    defer terminal.deinit();
    try std.testing.expect(terminal.signal_fd == -1 and !terminal.owns_fd);
    terminal.entry = .{ .raw = false, .grapheme = false, .hide_cursor = false, .paste = false };
    terminal.protocols.kitty_keyboard = true;
    for (0..3) |trial| {
        try terminal.beginEnter();
        const entry = terminal.modeOutput();
        try std.testing.expectEqualStrings("\x1b[?1049h\x1b[?u", entry);
        try std.testing.expect(!terminal.observe(.{ .keyboard_flags = 0 }));
        if (trial == 0) terminal.consumeMode(4) else {
            terminal.consumeMode(entry.len);
            try std.testing.expect(terminal.observe(.{ .keyboard_flags = 0 }));
            const push = terminal.modeOutput();
            try std.testing.expectEqualStrings("\x1b[>31u", push);
            terminal.consumeMode(push.len - 1);
            if (trial == 2) {
                terminal.desired_keys.text = false;
                terminal.consumeMode(1);
                const set = terminal.modeOutput();
                try std.testing.expectEqualStrings("\x1b[=15u", set);
                terminal.consumeMode(2);
            }
        }
        terminal.beginLeave();
        const restore_modes = terminal.modeOutput();
        try std.testing.expectEqual(trial != 0, std.mem.indexOf(u8, restore_modes, "\x1b[?1049l") != null);
        try std.testing.expectEqual(trial == 2, std.mem.indexOf(u8, restore_modes, "\x1b[<u") != null);
        try std.testing.expect(std.mem.indexOf(u8, restore_modes, "\x1b[?2004l") == null);
        terminal.consumeMode(restore_modes.len);
        try terminal.restore();
    }
}
