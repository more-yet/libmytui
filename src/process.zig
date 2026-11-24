const std = @import("std");
const linux = std.os.linux;
const tty = @import("linux.zig");
const Size = @import("geometry.zig").Size;

pub const PtyProcess = struct {
    master: i32,
    completion: i32,
    pid: linux.pid_t,
    status: ?Status = null,

    pub const Status = union(enum) { exited: u8, signaled: linux.SIG };
    pub const Change = union(enum) { exit: Status, stopped: linux.SIG, continued };
    pub const Target = enum { child, group };
    pub const Strings = [:null]const ?[*:0]const u8;
    pub fn prepareStrings(items: []const []const u8, storage: []u8, pointers: []?[*:0]const u8) !Strings {
        if (pointers.len <= items.len) return error.ArgumentCapacity;
        var used: usize = 0;
        for (items, 0..) |item, i| {
            if (std.mem.indexOfScalar(u8, item, 0) != null) return error.EmbeddedNul;
            if (item.len >= storage.len - used) return error.ArgumentCapacity;
            @memcpy(storage[used..][0..item.len], item);
            storage[used + item.len] = 0;
            pointers[i] = storage[used..][0..item.len :0].ptr;
            used += item.len + 1;
        }
        pointers[items.len] = null;
        return pointers[0..items.len :null];
    }
    const Failure = enum(u8) { signals, terminal, descriptors, missing, denied, exec };

    pub fn start(path: [*:0]const u8, argv: Strings, env: Strings, size: Size) !PtyProcess {
        if (argv.len == 0 or argv[0] == null) return error.InvalidArguments;
        var disposition: linux.Sigaction = undefined;
        if (linux.errno(linux.sigaction(.CHLD, null, &disposition)) != .SUCCESS or
            disposition.handler.handler == linux.SIG.IGN or disposition.flags & linux.SA.NOCLDWAIT != 0)
            return error.ChildNotWaitable;

        const master = try std.posix.openat(std.posix.AT.FDCWD, "/dev/ptmx", .{
            .ACCMODE = .RDWR,
            .NOCTTY = true,
            .CLOEXEC = true,
            .NONBLOCK = true,
        }, 0);
        errdefer _ = linux.close(master);
        try setSize(master, size);
        const unlock: i32 = 0;
        if (linux.errno(linux.ioctl(master, linux.T.IOCSPTLCK, @intFromPtr(&unlock))) != .SUCCESS)
            return error.PtyUnlock;
        const flags: linux.O = .{ .ACCMODE = .RDWR, .NOCTTY = true, .CLOEXEC = true };
        const slave_result = linux.ioctl(master, linux.T.IOCGPTPEER, @as(u32, @bitCast(flags)));
        if (linux.errno(slave_result) != .SUCCESS) return error.PtySlave;
        const slave: i32 = @intCast(slave_result);
        defer _ = linux.close(slave);
        var pipe: [2]i32 = undefined;
        if (linux.errno(linux.pipe2(&pipe, .{ .CLOEXEC = true })) != .SUCCESS) return error.StartupPipe;
        defer _ = linux.close(pipe[0]);
        const child = fork: {
            defer _ = linux.close(pipe[1]);
            const blocked = linux.sigfillset();
            var saved: linux.sigset_t = undefined;
            if (linux.errno(linux.sigprocmask(linux.SIG.SETMASK, &blocked, &saved)) != .SUCCESS)
                return error.SignalMask;
            defer std.debug.assert(linux.sigprocmask(linux.SIG.SETMASK, &saved, null) == 0);
            const result = linux.fork();
            if (linux.errno(result) != .SUCCESS) return error.ForkFailed;
            if (result == 0) {
                var report = pipe[1];
                if (report < 3) {
                    const fd = linux.fcntl(report, linux.F.DUPFD_CLOEXEC, 3);
                    if (linux.errno(fd) != .SUCCESS) fail(report, .descriptors);
                    report = @intCast(fd);
                }
                if (linux.errno(linux.setsid()) != .SUCCESS or
                    linux.errno(linux.ioctl(slave, linux.T.IOCSCTTY, 0)) != .SUCCESS) fail(report, .terminal);
                for (0..3) |i| {
                    const fd: i32 = @intCast(i);
                    const rc = if (fd == slave) linux.fcntl(fd, linux.F.SETFD, 0) else linux.dup2(slave, fd);
                    if (linux.errno(rc) != .SUCCESS) fail(report, .descriptors);
                }
                if (linux.errno(linux.close_range(3, -1, .{ .UNSHARE = false, .CLOEXEC = true })) != .SUCCESS)
                    fail(report, .descriptors);
                const empty = linux.sigemptyset();
                const reset: linux.Sigaction = .{ .handler = .{ .handler = linux.SIG.DFL }, .mask = empty, .flags = 0 };
                for (1..linux.NSIG) |i| {
                    const sig: linux.SIG = @fromBackingInt(@intCast(i));
                    if (sig != .KILL and sig != .STOP and linux.errno(linux.sigaction(sig, &reset, null)) != .SUCCESS)
                        fail(report, .signals);
                }
                if (linux.errno(linux.sigprocmask(linux.SIG.SETMASK, &empty, null)) != .SUCCESS) fail(report, .signals);
                fail(report, switch (linux.errno(linux.execve(path, argv.ptr, env.ptr))) {
                    .NOENT, .NOTDIR => .missing,
                    .ACCES => .denied,
                    else => .exec,
                });
            }
            break :fork @as(linux.pid_t, @intCast(result));
        };
        errdefer {
            _ = linux.kill(child, .KILL);
            _ = wait(child, 0) catch unreachable;
        }
        const fd = linux.pidfd_open(child, 0);
        if (linux.errno(fd) != .SUCCESS) return error.CompletionDescriptor;
        const completion: i32 = @intCast(fd);
        errdefer _ = linux.close(completion);
        var failure: Failure = undefined;
        while (true) {
            const n = linux.read(pipe[0], std.mem.asBytes(&failure), 1);
            switch (linux.errno(n)) {
                .INTR => continue,
                .SUCCESS => if (n == 0) break else return switch (failure) {
                    .missing => error.FileNotFound,
                    .denied => error.AccessDenied,
                    .terminal => error.ChildTerminal,
                    .signals => error.ChildSignals,
                    .descriptors => error.ChildDescriptors,
                    .exec => error.ChildExec,
                },
                else => return error.StartupPipe,
            }
        }
        return .{ .master = master, .completion = completion, .pid = child };
    }

    fn fail(fd: i32, reason: Failure) noreturn {
        while (linux.errno(linux.write(fd, std.mem.asBytes(&reason), 1)) == .INTR) {}
        linux.exit(127);
    }

    fn setSize(fd: i32, size: Size) !void {
        if (size.width == 0 or size.height == 0) return error.InvalidDimensions;
        const ws: std.posix.winsize = .{ .row = size.height, .col = size.width, .xpixel = size.pixel_width, .ypixel = size.pixel_height };
        while (true) switch (linux.errno(linux.ioctl(fd, linux.T.IOCSWINSZ, @intFromPtr(&ws)))) {
            .SUCCESS => return,
            .INTR => continue,
            else => return error.PtySize,
        };
    }

    pub fn resize(self: *const PtyProcess, size: Size) !void {
        try setSize(self.master, size);
    }

    pub fn read(self: *const PtyProcess, buffer: []u8) !?usize {
        std.debug.assert(buffer.len != 0);
        return tty.read(self.master, buffer);
    }

    pub fn write(self: *const PtyProcess, bytes: []const u8) !?usize {
        if (bytes.len == 0) return 0;
        return tty.write(self.master, bytes);
    }

    fn wait(pid: linux.pid_t, flags: u32) !?Change {
        var status: i32 = undefined;
        while (true) {
            const result = linux.waitpid(pid, &status, flags);
            switch (linux.errno(result)) {
                .INTR => continue,
                .SUCCESS => {
                    if (result == 0) return null;
                    const bits: u32 = @bitCast(status);
                    if (bits == 0xffff) return .continued;
                    if (linux.W.IFSTOPPED(bits)) return .{ .stopped = linux.W.STOPSIG(bits) };
                    if (linux.W.IFEXITED(bits)) return .{ .exit = .{ .exited = linux.W.EXITSTATUS(bits) } };
                    if (linux.W.IFSIGNALED(bits)) return .{ .exit = .{ .signaled = linux.W.TERMSIG(bits) } };
                },
                else => return error.ChildWait,
            }
        }
    }

    pub fn collect(self: *PtyProcess) !?Status {
        if (self.status == null) {
            if (try wait(self.pid, linux.W.NOHANG)) |change| self.status = change.exit;
        }
        return self.status;
    }

    /// pidfds notify exit only. Poll this operation explicitly for job-control transitions.
    pub fn pollChange(self: *PtyProcess) !?Change {
        if (self.status != null) return null;
        const change = try wait(self.pid, linux.W.NOHANG | linux.W.UNTRACED | linux.W.CONTINUED) orelse return null;
        if (change == .exit) self.status = change.exit;
        return change;
    }

    pub fn signal(self: *const PtyProcess, sig: linux.SIG) !void {
        if (self.status != null) return;
        switch (linux.errno(linux.pidfd_send_signal(self.completion, sig, null, 0))) {
            .SUCCESS, .SRCH => {},
            else => return error.ChildSignal,
        }
    }

    pub fn cancel(self: *PtyProcess) !void {
        if (self.status != null) return;
        try self.signal(.KILL);
        self.status = (try wait(self.pid, 0)).?.exit;
    }

    pub fn signalGroup(self: *const PtyProcess, sig: linux.SIG) !void {
        // Until reaping, the session leader's PID cannot name an unrelated group.
        if (self.status != null) return error.ChildAlreadyReaped;
        switch (linux.errno(linux.kill(-self.pid, sig))) {
            .SUCCESS, .SRCH => {},
            else => return error.ChildSignal,
        }
    }

    /// Absolute awake-clock deadline, in Schedule.nowMs units. Timeout retains ownership.
    pub fn killAndWait(self: *PtyProcess, io: std.Io, deadline_ms: i96, target: Target) !Status {
        if (self.status) |status| return status;
        switch (target) {
            .child => try self.signal(.KILL),
            .group => try self.signalGroup(.KILL),
        }
        return self.waitUntil(io, deadline_ms);
    }

    pub fn waitUntil(self: *PtyProcess, io: std.Io, deadline_ms: i96) !Status {
        var fd = [_]std.posix.pollfd{.{ .fd = self.completion, .events = std.posix.POLL.IN, .revents = 0 }};
        while (true) {
            if (try self.collect()) |status| return status;
            if (tty.now(io) >= deadline_ms) return error.ChildTimeout;
            try tty.pollUntil(io, &fd, deadline_ms);
        }
    }

    pub fn closeMaster(self: *PtyProcess) void {
        if (self.master >= 0) _ = linux.close(self.master);
        self.master = -1;
    }

    pub fn deinit(self: *PtyProcess) !void {
        try self.cancel();
        self.closeMaster();
        _ = linux.close(self.completion);
        self.* = undefined;
    }
};

test "child startup handshake, waitable exit before drain, explicit environment and reaping" {
    const size: Size = .{ .width = 32, .height = 8 };
    try std.testing.expectError(error.FileNotFound, PtyProcess.start("/dev/null/missing", &.{"missing"}, &.{}, size));
    var proc = try PtyProcess.start("/bin/sh", &.{ "sh", "-c", "stty size; printf '%s' \"$VALUE\"; exit 42" }, &.{ "VALUE=result", "PATH=/usr/bin:/bin" }, size);
    defer proc.deinit() catch unreachable;
    var fds = [_]std.posix.pollfd{.{ .fd = proc.completion, .events = std.posix.POLL.IN, .revents = 0 }};
    try tty.pollUntil(std.testing.io, &fds, tty.now(std.testing.io) + 3000);
    try std.testing.expect(fds[0].revents & std.posix.POLL.IN != 0);
    try std.testing.expectEqual(@as(u8, 42), (try proc.collect()).?.exited);
    var output: [64]u8 = undefined;
    var len: usize = 0;
    while (try proc.read(output[len..])) |n| {
        if (n == 0) break;
        len += n;
    } else return error.UnexpectedBlock;
    try std.testing.expectEqualStrings("8 32\r\nresult", output[0..len]);
    var status: i32 = undefined;
    try std.testing.expectEqual(linux.E.CHILD, linux.errno(linux.waitpid(proc.pid, &status, linux.W.NOHANG)));
}

test "stalled PTY accepts bounded writes and cancellation reaps the child" {
    var proc = try PtyProcess.start("/bin/sh", &.{ "sh", "-c", "stty raw -echo && printf . && exec sleep 60" }, &.{"PATH=/usr/bin:/bin"}, .{ .width = 1, .height = 1 });
    defer proc.deinit() catch unreachable;
    try proc.resize(.{ .width = 20, .height = 20 });
    var bytes: [4096]u8 = @splat('x');
    var fds = [_]std.posix.pollfd{.{ .fd = proc.master, .events = std.posix.POLL.IN, .revents = 0 }};
    try tty.pollUntil(std.testing.io, &fds, tty.now(std.testing.io) + 3000);
    try std.testing.expectEqual(1, try proc.read(&bytes));
    try std.testing.expectEqual(@as(u8, '.'), bytes[0]);
    try std.testing.expect(try proc.read(&bytes) == null);
    try std.testing.expect(try proc.collect() == null);
    for (0..1024) |_| {
        if (try proc.write(&bytes) == null) break;
    } else return error.NoBackpressure;
    try proc.cancel();
    try std.testing.expectEqual(linux.SIG.KILL, (try proc.collect()).?.signaled);
}

test "child restores default dispositions and unblocks inherited signals before exec" {
    const ignored: linux.Sigaction = .{ .handler = .{ .handler = linux.SIG.IGN }, .mask = linux.sigemptyset(), .flags = 0 };
    var original: linux.Sigaction = undefined;
    try std.testing.expectEqual(0, linux.sigaction(.PIPE, &ignored, &original));
    defer _ = linux.sigaction(.PIPE, &original, null);
    var mask = linux.sigemptyset();
    linux.sigaddset(&mask, .PIPE);
    var saved: linux.sigset_t = undefined;
    try std.testing.expectEqual(0, linux.sigprocmask(linux.SIG.BLOCK, &mask, &saved));
    defer _ = linux.sigprocmask(linux.SIG.SETMASK, &saved, null);
    var proc = try PtyProcess.start("/bin/sh", &.{ "sh", "-c", "kill -PIPE $$; exit 77" }, &.{}, .{ .width = 10, .height = 2 });
    defer proc.deinit() catch unreachable;
    var fds = [_]std.posix.pollfd{.{ .fd = proc.completion, .events = std.posix.POLL.IN, .revents = 0 }};
    try tty.pollUntil(std.testing.io, &fds, tty.now(std.testing.io) + 3000);
    const status = try proc.collect() orelse return error.ChildStillRunning;
    try std.testing.expectEqual(PtyProcess.Status{ .signaled = .PIPE }, status);
}

test "group stop/continue and bounded reap retain the master until descendants release the slave" {
    const io = std.testing.io;
    var storage: [128]u8 = undefined;
    var pointers: [4]?[*:0]const u8 = undefined;
    const argv = try PtyProcess.prepareStrings(&.{ "sh", "-c", "sleep 10 & printf R; wait" }, &storage, &pointers);
    var proc = try PtyProcess.start("/bin/sh", argv, &.{"PATH=/bin:/usr/bin"}, .{ .width = 10, .height = 2 });
    defer proc.deinit() catch unreachable;
    defer if (proc.status == null) proc.signalGroup(.KILL) catch {};
    var fd = [_]std.posix.pollfd{.{ .fd = proc.master, .events = std.posix.POLL.IN, .revents = 0 }};
    try tty.pollUntil(std.testing.io, &fd, tty.now(std.testing.io) + 3000);
    var byte: [1]u8 = undefined;
    try std.testing.expectEqual(1, try proc.read(&byte));
    try std.testing.expectError(error.ChildTimeout, proc.waitUntil(io, tty.now(io)));
    for ([_]linux.SIG{ .STOP, .CONT }) |sig| {
        try proc.signalGroup(sig);
        const until = tty.now(io) + 3000;
        while (true) {
            if (try proc.pollChange()) |change| {
                try std.testing.expect(if (sig == .STOP) change == .stopped and change.stopped == .STOP else change == .continued);
                break;
            }
            if (tty.now(io) >= until) return error.MissingTransition;
            try std.Io.sleep(io, .fromMilliseconds(1), .awake);
        }
    }
    const status = try proc.killAndWait(io, tty.now(io) + 3000, .group);
    try std.testing.expectEqual(linux.SIG.KILL, status.signaled);
    try tty.pollUntil(std.testing.io, &fd, tty.now(std.testing.io) + 3000);
    try std.testing.expectEqual(0, try proc.read(&byte));
    try std.testing.expectError(error.ChildAlreadyReaped, proc.signalGroup(.KILL));
    proc.closeMaster();
}
