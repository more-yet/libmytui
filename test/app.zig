const std = @import("std");
const tui = @import("mytui");
const tick: tui.Timer = @fromBackingInt(1);
const other: tui.Timer = @fromBackingInt(2);

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (std.mem.eql(u8, args[1], "mixed")) {
        var mixed: Mixed = .{
            .io = init.io,
            .report_fd = try std.fmt.parseInt(i32, args[2], 10),
            .source_count = try std.fmt.parseInt(usize, args[3], 10),
        };
        if (mixed.source_count == 0 or mixed.source_count > mixed.sources.len) return error.InvalidSourceCount;
        tui.run(init, &mixed, .{ .max_sources = @intCast(mixed.source_count) }) catch |err| {
            if (err == error.OutputTimeout and std.mem.eql(u8, args[4], "blocked")) std.process.exit(1);
            return err;
        };
        return;
    }
    var app: App = .{ .mode = std.meta.stringToEnum(Mode, args[1]).?, .io = init.io };
    var original_mask = std.posix.sigemptyset();
    std.posix.sigprocmask(std.posix.SIG.BLOCK, null, &original_mask);
    if (app.mode == .reopen) {
        var failed: App = .{ .mode = .draw_error, .io = init.io };
        if (tui.run(init, &failed, .{})) |_| {
            std.process.exit(2);
        } else |err| {
            if (err != error.InjectedDrawFailure) std.process.exit(2);
        }
        if (failed.starts != 1 or failed.stops != 1 or failed.worker != null or failed.pipe != null)
            std.process.exit(2);
    }
    const result = tui.run(init, &app, .{
        .graphics_sender = if (app.mode == .graphics) &app.sender else null,
        .protocols = if (app.mode == .protocols) .{ .kitty_keyboard = true, .focus = true, .mouse = true, .graphics_probe = true, .synchronized_output = true } else .{},
        .limits = .{
            .max_cells = if (app.mode == .initial_capacity) 1 else 65_536,
            .cluster_bytes = if (app.mode == .capacity) 0 else 256 * 1024,
        },
        .max_sources = if (app.mode == .watch_capacity or app.mode == .process_capacity) 1 else 4,
        .max_timers = 2,
    });
    const expected_starts: usize = if (app.mode == .initial_capacity) 0 else 1;
    if (app.starts != expected_starts or app.stops != expected_starts or app.worker != null or app.pipe != null)
        std.process.exit(2);
    if (app.notification != null or app.second_pipe != null or app.watch != null or app.second_watch != null or app.child != null)
        std.process.exit(2);
    var restored_mask = std.posix.sigemptyset();
    std.posix.sigprocmask(std.posix.SIG.BLOCK, null, &restored_mask);
    for ([_]std.posix.SIG{ .INT, .TERM, .TSTP, .CONT, .WINCH, .USR1 }) |sig| {
        if (std.posix.sigismember(&original_mask, sig) != std.posix.sigismember(&restored_mask, sig))
            std.process.exit(2);
    }
    const expected_error: ?anyerror = switch (app.mode) {
        .start_error_empty, .start_error_pipe, .start_error_worker => error.InjectedStartFailure,
        .draw_error => error.InjectedDrawFailure,
        .update_error => error.InjectedUpdateFailure,
        .capacity => error.FrameTextCapacity,
        .resize_capacity, .initial_capacity => error.ScreenCapacity,
        .flood => error.OutputTimeout,
        .watch_capacity, .process_capacity => error.WatchCapacity,
        .ready_error => error.InjectedReadinessFailure,
        else => null,
    };
    result catch |err| {
        if (expected_error == null or err != expected_error.?) std.process.exit(2);
        std.process.exit(1);
    };
    if (expected_error != null) std.process.exit(2);
}

const Mode = enum {
    idle,
    protocols,
    graphics,
    reopen,
    initial_capacity,
    capacity,
    start_error_empty,
    start_error_pipe,
    start_error_worker,
    draw_error,
    update_error,
    ready_error,
    flood,
    watch_capacity,
    process,
    process_capacity,
    watch_reuse,
    write_ready,
    hangup_ready,
    slow_deadline,
    deadline_past,
    deadline_rearm,
    deadline_cancel,
    deadline_replace,
    deadline_resume,
    worker,
    worker_blocked,
    worker_quit,
    load_input,
    load_worker,
    load_blocked,
    stop_priority,
    resize_capacity,
    resume_quit,
    @"resume",
    blocked_resize,
};

const App = struct {
    sender: tui.graphics.Sender = tui.graphics.Sender.init(.{}),
    mode: Mode,
    io: std.Io,
    deadlines: usize = 0,
    resizes: usize = 0,
    draws: usize = 0,
    changes: usize = 0,
    callback_finished: i96 = 0,
    starts: usize = 0,
    stops: usize = 0,
    pipe: ?[2]std.posix.fd_t = null,
    worker: ?std.Thread = null,
    worker_finished: bool = false,
    session: *tui.Session = undefined,
    notification: ?tui.Notification = null,
    second_pipe: ?[2]std.posix.fd_t = null,
    watch: ?tui.Watch = null,
    second_watch: ?tui.Watch = null,
    results: [16]u32 = undefined,
    published: std.atomic.Value(u32) = .init(0),
    replaced: bool = false,
    child: ?tui.PtyProcess = null,
    child_bytes: usize = 0,

    pub fn start(self: *App, session: *tui.Session) !void {
        self.session = session;
        const schedule = &session.schedule;
        self.starts += 1;
        if (self.starts != 1 or self.stops != 0 or !terminalOwned()) return error.InvalidStartupOrder;
        if (self.mode == .start_error_empty) return error.InjectedStartFailure;
        if (self.mode == .process or self.mode == .process_capacity) {
            self.child = try tui.PtyProcess.start("/bin/sh", &.{ "sh", "-c", if (self.mode == .process) "printf done; exit 12" else "exec /bin/sleep 60" }, &.{}, .{ .width = 80, .height = 24 });
            self.watch = try schedule.watch(self.child.?.master, .read);
            self.second_watch = try schedule.watch(self.child.?.completion, .read);
            return;
        }
        var descriptors: [2]std.posix.fd_t = undefined;
        if (std.os.linux.errno(std.os.linux.pipe2(&descriptors, .{ .CLOEXEC = true })) != .SUCCESS)
            return error.PipeFailed;
        self.pipe = descriptors;
        if (self.mode == .start_error_pipe) return error.InjectedStartFailure;
        switch (self.mode) {
            .worker,
            .worker_blocked,
            .worker_quit,
            .load_worker,
            .watch_capacity,
            .watch_reuse,
            .write_ready,
            .ready_error,
            => {
                self.notification = try .init();
                self.watch = try schedule.watch(self.notification.?.fd, if (self.mode == .write_ready) .write else .read);
            },
            else => {},
        }
        self.worker = try std.Thread.spawn(.{}, waitForStop, .{ self, descriptors[0] });
        switch (self.mode) {
            .start_error_worker => return error.InjectedStartFailure,
            .slow_deadline => try schedule.arm(tick, schedule.nowMs() + 300),
            .flood, .update_error => try schedule.arm(tick, schedule.nowMs() + 1),
            .deadline_past, .deadline_rearm => try schedule.arm(tick, std.math.minInt(i96)),
            else => {},
        }
        if (self.mode == .deadline_rearm) {
            try schedule.arm(other, schedule.nowMs());
            if (schedule.arm(@fromBackingInt(3), 0)) return error.TimerLimitMissing else |err| {
                if (err != error.TimerCapacity) return err;
            }
        }
        if (self.mode == .watch_capacity or self.mode == .watch_reuse or self.mode == .hangup_ready) {
            var second: [2]std.posix.fd_t = undefined;
            if (std.os.linux.errno(std.os.linux.pipe2(&second, .{ .CLOEXEC = true, .NONBLOCK = true })) != .SUCCESS)
                return error.PipeFailed;
            self.second_pipe = second;
            if (self.mode == .hangup_ready) {
                self.watch = try schedule.watch(second[0], .read);
                _ = std.os.linux.close(second[1]);
                self.second_pipe.?[1] = -1;
            } else {
                self.second_watch = try schedule.watch(second[0], .read);
                try self.notification.?.signal();
                if (std.os.linux.write(second[1], "x", 1) != 1) return error.NotifyFailed;
            }
        }
        if (self.mode == .ready_error) try self.notification.?.signal();
    }

    pub fn stop(self: *App) void {
        self.stops += 1;
        if (self.starts != 1 or self.stops != 1 or !terminalOwned()) std.process.exit(2);
        if (self.watch) |id| self.session.schedule.unwatch(id);
        if (self.second_watch) |id| self.session.schedule.unwatch(id);
        self.watch = null;
        self.second_watch = null;
        if (self.child) |*child| {
            const pid = child.pid;
            child.deinit() catch std.process.exit(2);
            self.child = null;
            var status: i32 = undefined;
            if (std.os.linux.errno(std.os.linux.waitpid(pid, &status, std.os.linux.W.NOHANG)) != .CHILD) std.process.exit(2);
        }
        if (self.pipe) |descriptors| {
            _ = std.os.linux.close(descriptors[1]);
            if (self.worker) |worker| {
                worker.join();
                self.worker = null;
                if (!self.worker_finished) std.process.exit(2);
            }
            _ = std.os.linux.close(descriptors[0]);
            self.pipe = null;
        }
        if (self.notification) |*notify| notify.deinit();
        if (self.second_pipe) |descriptors| {
            _ = std.os.linux.close(descriptors[0]);
            if (descriptors[1] >= 0) _ = std.os.linux.close(descriptors[1]);
        }
        self.notification = null;
        self.second_pipe = null;
    }

    fn waitForStop(self: *App, fd: std.posix.fd_t) void {
        var byte: [256]u8 = undefined;
        while (true) {
            const result = std.os.linux.read(fd, &byte, if (self.mode == .load_worker) byte.len else 1);
            switch (std.os.linux.errno(result)) {
                .SUCCESS => {
                    if (result == 0) {
                        self.worker_finished = terminalOwned();
                        return;
                    }
                    if (self.mode == .load_worker) {
                        _ = self.published.fetchAdd(@intCast(result), .release);
                        self.notification.?.signal() catch return;
                        continue;
                    }
                    if (self.published.load(.acquire) != 0) return;
                    for (&self.results, 0..) |*value, index| value.* = @intCast(index + 1);
                    self.published.store(self.results.len, .release);
                    self.notification.?.signal() catch return;
                },
                .INTR => continue,
                else => return,
            }
        }
    }

    pub fn update(self: *App, event: tui.Event) !tui.Action {
        if (self.mode == .graphics) switch (event) {
            .screen_clear => {
                try self.sender.begin(.{ .transmit = .{ .width_pixels = 1, .height_pixels = 1, .identifiers = .{ .image_id = 123 } } }, "ABCD", .none);
                return .none;
            },
            .graphics_sent => {
                self.changes += 1;
                return .none;
            },
            .key => |key| if (key.is('i')) {
                return .repaint;
            },
            else => {},
        };
        if (self.starts != 1 or self.stops != 0) return error.InvalidCallbackOrder;
        if (self.mode == .protocols and event == .reply and event.reply == .graphics) {
            const g = event.reply.graphics;
            const caps = self.session.capabilities;
            if (g.id == 1) {
                if (self.session.matched_reply or caps.graphics != .unknown) return error.UncorrelatedReply;
            } else if (!self.session.matched_reply or caps.graphics != .supported or caps.kitty_keyboard != .supported or caps.synchronized_output != .supported)
                return error.MissingProbeResult;
        }
        if (event == .key and event.key.is('q')) return .quit;
        if (event == .key and event.key.action == .press and event.key.control and event.key.code == .character) switch (event.key.code.character) {
            'c' => return .quit,
            'z' => return .@"suspend",
            else => {},
        };
        if (event == .key and event.key.is('w')) {
            if (std.os.linux.write(self.pipe.?[1], "w", 1) != 1) return error.NotifyFailed;
            return .none;
        }
        if (event == .key and event.key.is('a')) {
            try self.session.schedule.arm(tick, self.session.schedule.nowMs() + 80);
            return .none;
        }
        if (event == .key and event.key.is('b')) {
            try self.session.schedule.arm(tick, self.session.schedule.nowMs() + 250);
            return .none;
        }
        if (event == .key and event.key.is('c')) {
            _ = self.session.schedule.cancel(tick);
            return .none;
        }
        if (event == .key and event.key.is('r')) {
            self.changes += 1;
            return .redraw;
        }
        if (event == .resize) {
            if (self.mode == .stop_priority or self.mode == .resize_capacity)
                return error.UnexpectedResize;
            self.resizes += 1;
        }
        if (event == .ready) {
            const ready = event.ready;
            if (self.child) |*child| {
                if (ready.watch == self.watch) {
                    var bytes: [2]u8 = undefined;
                    const n = try child.read(&bytes) orelse return .none;
                    if (!std.mem.startsWith(u8, "done"[self.child_bytes..], bytes[0..n])) return error.UnexpectedOutput;
                    self.child_bytes += n;
                    if (n == 0) {
                        if (self.child_bytes != 4) return error.OutputMissing;
                        self.session.schedule.unwatch(ready.watch);
                        self.watch = null;
                    }
                } else if (ready.watch == self.second_watch) {
                    const status = try child.collect() orelse return error.UnexpectedReadiness;
                    if (status != .exited or status.exited != 12) return error.UnexpectedExit;
                    self.session.schedule.unwatch(ready.watch);
                    self.second_watch = null;
                } else return error.UnknownWatch;
                return if (self.watch == null and self.second_watch == null) .quit else .none;
            }
            if (self.mode == .ready_error) return error.InjectedReadinessFailure;
            if (self.mode == .watch_reuse) {
                if (ready.watch == self.watch) {
                    try self.notification.?.signal();
                    if (!try self.notification.?.consume() or try self.notification.?.consume()) return error.NotCoalesced;
                    self.session.schedule.unwatch(self.second_watch.?);
                    self.second_watch = null;
                    const old_fd = self.second_pipe.?[0];
                    _ = std.os.linux.close(old_fd);
                    _ = std.os.linux.close(self.second_pipe.?[1]);
                    self.second_pipe = null;
                    var second: [2]std.posix.fd_t = undefined;
                    if (std.os.linux.errno(std.os.linux.pipe2(&second, .{ .CLOEXEC = true, .NONBLOCK = true })) != .SUCCESS)
                        return error.PipeFailed;
                    self.second_pipe = second;
                    if (second[0] != old_fd) return error.DescriptorNotReused;
                    self.second_watch = try self.session.schedule.watch(second[0], .read);
                    self.session.schedule.unwatch(self.watch.?);
                    self.watch = null;
                    try self.session.schedule.arm(tick, self.session.schedule.nowMs());
                    return .none;
                }
                if (ready.watch != self.second_watch or !self.replaced) return error.StaleReadiness;
                var byte: [1]u8 = undefined;
                if (std.os.linux.read(self.second_pipe.?[0], &byte, 1) != 1) return error.StaleReadiness;
                return .quit;
            }
            if (ready.watch != self.watch or ready.failed) return error.UnexpectedReadiness;
            if (self.mode == .write_ready) {
                if (!ready.writable or ready.readable) return error.UnexpectedReadiness;
                return .quit;
            }
            if (self.mode == .hangup_ready) {
                if (!ready.hangup) return error.UnexpectedReadiness;
                return .quit;
            }
            if (!ready.readable or ready.hangup) return error.UnexpectedReadiness;
            if (!try self.notification.?.consume()) return error.NotifyFailed;
            if (self.mode == .load_worker) {
                self.changes += self.published.swap(0, .acquire);
                return .redraw;
            }
            const published = self.published.load(.acquire);
            if (published != self.results.len) return error.InvalidPublication;
            for (self.results, 0..) |value, index| {
                if (value != index + 1) return error.InvalidPublication;
            }
            self.published.store(0, .release);
            self.changes += 1;
            return .redraw;
        }
        if (event == .timer) {
            self.deadlines += 1;
            if (self.session.schedule.cancel(event.timer)) return error.DeadlineStillArmed;
            switch (self.mode) {
                .update_error => return error.InjectedUpdateFailure,
                .flood => {
                    try self.session.schedule.arm(tick, self.session.schedule.nowMs() + 1);
                    return .redraw;
                },
                .watch_reuse => {
                    self.replaced = true;
                    if (std.os.linux.write(self.second_pipe.?[1], "y", 1) != 1) return error.NotifyFailed;
                    return .none;
                },
                .deadline_past => return .quit,
                .deadline_rearm => {
                    switch (self.deadlines) {
                        1 => {
                            if (event.timer != tick) return error.UnexpectedTimer;
                            try self.session.schedule.arm(other, self.session.schedule.nowMs());
                            try self.session.schedule.arm(tick, self.session.schedule.nowMs());
                        },
                        2 => {
                            if (self.draws == 0 or event.timer != tick) return error.StaleTimer;
                            try self.session.schedule.arm(tick, self.session.schedule.nowMs());
                        },
                        3 => {
                            if (event.timer != other or !self.session.schedule.cancel(tick)) return error.TimerStarved;
                            return .quit;
                        },
                        else => return error.UnexpectedTimer,
                    }
                    return .redraw;
                },
                .slow_deadline => {
                    if (self.deadlines == 1) {
                        try self.session.schedule.arm(tick, self.session.schedule.nowMs() + 300);
                        try std.Io.sleep(self.io, .fromMilliseconds(450), .awake);
                        self.callback_finished = std.Io.Clock.awake.now(self.io).nanoseconds;
                        return .none;
                    }
                    if (std.Io.Clock.awake.now(self.io).nanoseconds - self.callback_finished >
                        200 * std.time.ns_per_ms) return error.StaleWaitDeadline;
                    return .quit;
                },
                .deadline_cancel, .deadline_replace, .deadline_resume => {
                    if (self.deadlines != 1) return error.RepeatedDeadline;
                    return .redraw;
                },
                else => {},
            }
        }
        return .none;
    }

    pub fn draw(self: *App, frame: *tui.Frame) !void {
        if (self.starts != 1 or self.stops != 0) return error.InvalidCallbackOrder;
        self.draws += 1;
        switch (self.mode) {
            .stop_priority, .resume_quit => if (self.draws > 1) return error.UnnecessaryDraw,
            .draw_error => return error.InjectedDrawFailure,
            .capacity => try frame.text(0, 0, "e\u{301}", .{}),
            else => {},
        }
        frame.fill(.{ .background = .{ .indexed = @intCast(self.deadlines & 1) } });
        if (self.mode == .blocked_resize or self.mode == .worker_blocked or self.mode == .load_blocked) {
            for (0..frame.size().height) |y| {
                for (0..frame.size().width) |x| {
                    try frame.text(@intCast(x), @intCast(y), "x", .{
                        .background = .{ .indexed = @intCast((x + self.changes) % 2) },
                    });
                }
            }
        }
        try frame.text(0, 0, "ready", .{});
        try frame.print(0, 1, "Resizes: {d}", .{self.resizes}, .{});
        try frame.print(0, 2, "Draws: {d}", .{self.draws}, .{});
        try frame.print(0, 3, "Changes: {d}", .{self.changes}, .{});
        try frame.text(0, 4, if (self.changes & 1 == 0) "AAAAAA" else "BBBBBB", .{});
        if (self.deadlines > 0) try frame.print(0, 6, "Deadline {d}", .{self.deadlines}, .{});
        if (self.mode == .load_input or self.mode == .load_worker or self.mode == .load_blocked)
            try frame.print(0, frame.size().height - 1, "Completed: {d}!", .{self.changes}, .{
                .foreground = .{ .rgb = @truncate(self.changes) },
            });
    }
};

const Mixed = struct {
    io: std.Io,
    report_fd: i32,
    source_count: usize,
    sources: [128]struct {
        notification: tui.Notification,
        watch: ?tui.Watch = null,
        sent_ns: std.atomic.Value(i64) = .init(0),
        ready: usize = 0,
    } = undefined,
    created: usize = 0,
    cancellation: ?tui.Notification = null,
    worker: ?std.Thread = null,
    schedule: *tui.Schedule = undefined,
    target_ms: i96 = 0,
    lateness: [1024]u32 = undefined,
    deadlines: usize = 0,
    ready_latency: [1024]usize = @splat(0),
    max_ready_ns: u64 = 0,
    changes: usize = 0,
    resizes: usize = 0,
    draws: usize = 0,

    pub fn start(self: *Mixed, session: *tui.Session) !void {
        const schedule = &session.schedule;
        self.schedule = schedule;
        self.cancellation = try .init();
        for (self.sources[0..self.source_count]) |*source| {
            source.* = .{ .notification = try .init() };
            self.created += 1;
            source.watch = try schedule.watch(source.notification.fd, .read);
        }
        self.target_ms = schedule.nowMs() + 5;
        try schedule.arm(tick, self.target_ms);
        self.worker = try std.Thread.spawn(.{}, publish, .{self});
    }

    fn publish(self: *Mixed) void {
        var wait = [_]std.posix.pollfd{.{ .fd = self.cancellation.?.fd, .events = std.posix.POLL.IN, .revents = 0 }};
        while (true) {
            const result = std.posix.system.poll(&wait, 1, 1);
            if (result < 0 and std.posix.errno(result) == .INTR) continue;
            if (result != 0) return;
            const now: i64 = @intCast(std.Io.Clock.awake.now(self.io).nanoseconds);
            for (self.sources[0..self.created]) |*source| {
                if (source.sent_ns.cmpxchgStrong(0, now, .release, .monotonic) != null) continue;
                source.notification.signal() catch return;
            }
        }
    }

    pub fn update(self: *Mixed, event: tui.Event) !tui.Action {
        switch (event) {
            .key => |key| {
                if (key.is('q')) return .quit;
                self.changes += 1;
                return .redraw;
            },
            .resize => self.resizes += 1,
            .ready => |ready| {
                for (self.sources[0..self.created]) |*source| {
                    if (source.watch != ready.watch) continue;
                    if (!ready.readable or ready.failed or ready.hangup) return error.InvalidReadiness;
                    if (!try source.notification.consume()) return error.InvalidNotification;
                    const sent = source.sent_ns.swap(0, .acquire);
                    if (sent == 0) return error.InvalidPublication;
                    const elapsed: u64 = @intCast(std.Io.Clock.awake.now(self.io).nanoseconds - sent);
                    self.ready_latency[@min(self.ready_latency.len - 1, elapsed / 100_000)] += 1;
                    self.max_ready_ns = @max(self.max_ready_ns, elapsed);
                    source.ready += 1;
                    return .none;
                }
                return error.UnknownWatch;
            },
            .timer => {
                if (self.deadlines == self.lateness.len) return error.StressDurationExceeded;
                self.lateness[self.deadlines] = @intCast(self.schedule.nowMs() - self.target_ms);
                self.deadlines += 1;
                self.target_ms += 5;
                try self.schedule.arm(tick, self.target_ms);
                return .redraw;
            },
            else => {},
        }
        return .none;
    }

    pub fn draw(self: *Mixed, frame: *tui.Frame) !void {
        self.draws += 1;
        for (0..frame.size().height) |y| {
            for (0..frame.size().width) |x| {
                try frame.text(@intCast(x), @intCast(y), if (self.draws & 1 == 0) "x" else "y", .{
                    .background = .{ .indexed = @intCast(x & 1) },
                });
            }
        }
    }

    pub fn stop(self: *Mixed) void {
        if (!terminalOwned()) std.process.exit(2);
        for (self.sources[0..self.created]) |source| {
            if (source.watch) |watch| self.schedule.unwatch(watch);
        }
        if (self.cancellation) |*note| {
            note.signal() catch std.process.exit(2);
            if (self.worker) |worker| worker.join();
            note.deinit();
        }
        var total: usize = 0;
        var minimum: usize = std.math.maxInt(usize);
        for (self.sources[0..self.created]) |*source| {
            source.notification.deinit();
            total += source.ready;
            minimum = @min(minimum, source.ready);
        }
        var cumulative: usize = 0;
        var p99: usize = 0;
        for (self.ready_latency, 0..) |count, i| {
            cumulative += count;
            if (cumulative * 100 >= total * 99) {
                p99 = if (i == self.ready_latency.len - 1) self.max_ready_ns else (i + 1) * 100_000;
                break;
            }
        }
        std.mem.sort(u32, self.lateness[0..self.deadlines], {}, std.sort.asc(u32));
        var bytes: [1024]u8 = undefined;
        const report = std.fmt.bufPrint(
            &bytes,
            "{{\"sources\":{d},\"input_events\":{d},\"resizes\":{d},\"draws\":{d},\"deadlines\":{d},\"deadline_p99_ms\":{d},\"deadline_max_ms\":{d},\"ready_events\":{d},\"minimum_ready_per_source\":{d},\"ready_p99_upper_ns\":{d},\"ready_max_ns\":{d}}}\n",
            .{ self.source_count, self.changes, self.resizes, self.draws, self.deadlines, if (self.deadlines == 0) 0 else self.lateness[self.deadlines * 99 / 100], if (self.deadlines == 0) 0 else self.lateness[self.deadlines - 1], total, minimum, p99, self.max_ready_ns },
        ) catch unreachable;
        if (std.os.linux.write(self.report_fd, report.ptr, report.len) != report.len) std.process.exit(2);
    }
};

fn terminalOwned() bool {
    var mask = std.posix.sigemptyset();
    std.posix.sigprocmask(std.posix.SIG.BLOCK, null, &mask);
    for ([_]std.posix.SIG{ .INT, .TERM, .TSTP, .CONT, .WINCH }) |sig| {
        if (!std.posix.sigismember(&mask, sig)) return false;
    }
    var attributes: std.os.linux.termios = undefined;
    if (std.os.linux.errno(std.os.linux.tcgetattr(0, &attributes)) != .SUCCESS) return false;
    return !attributes.lflag.ICANON and !attributes.lflag.ECHO;
}
