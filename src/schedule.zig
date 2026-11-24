const std = @import("std");
const linux = @import("linux.zig");

pub const Watch = enum(u64) { _ };
pub const Timer = enum(u64) { _ };
pub const Ready = struct {
    watch: Watch,
    readable: bool,
    writable: bool,
    hangup: bool,
    failed: bool,
};

pub const Schedule = struct {
    io: std.Io,
    timers: []Alarm,
    sources: []Source,
    source_count: usize = 0,
    next_watch: u64 = 1,

    pub const Source = struct {
        id: u64 = 0,
        fd: std.posix.fd_t = -1,
        events: i16 = 0,
    };

    pub const Alarm = struct {
        id: ?Timer = null,
        at: i96 = undefined,
        due: bool = false,
    };

    pub fn arm(self: *Schedule, id: Timer, at: i96) !void {
        var empty: ?*Alarm = null;
        for (self.timers) |*alarm| {
            if (alarm.id == id) {
                alarm.* = .{ .id = id, .at = at };
                return;
            }
            if (empty == null and alarm.id == null) empty = alarm;
        }
        const alarm = empty orelse return error.TimerCapacity;
        alarm.* = .{ .id = id, .at = at };
    }

    pub fn cancel(self: *Schedule, id: Timer) bool {
        for (self.timers) |*alarm| {
            if (alarm.id == id) {
                alarm.* = .{};
                return true;
            }
        }
        return false;
    }

    pub fn earliest(self: *const Schedule) ?i96 {
        var at: ?i96 = null;
        for (self.timers) |alarm| {
            if (alarm.id != null) at = @min(at orelse alarm.at, alarm.at);
        }
        return at;
    }

    pub fn nowMs(self: *const Schedule) i96 {
        return linux.now(self.io);
    }

    pub fn init(io: std.Io, sources: []Source, alarms: []Alarm) Schedule {
        @memset(sources, .{});
        @memset(alarms, .{});
        return .{ .io = io, .sources = sources, .timers = alarms };
    }

    pub const Turn = struct {
        schedule: *Schedule,
        interests: []std.posix.pollfd = &.{},
        deadline: ?i96 = null,
        // Registrations created during dispatch can reuse an already-polled slot.
        watch_limit: u64 = 0,
        ready_index: usize = 0,
        timer_index: usize = 0,
        pub fn nextReady(turn: *Turn) ?Ready {
            while (turn.ready_index < turn.interests.len) {
                const i = turn.ready_index;
                turn.ready_index += 1;
                const s = turn.schedule.sources[i];
                const bits = turn.interests[i].revents;
                if (bits == 0 or s.id == 0 or s.id >= turn.watch_limit) continue;
                return .{ .watch = @fromBackingInt(s.id), .readable = bits & std.posix.POLL.IN != 0, .writable = bits & std.posix.POLL.OUT != 0, .hangup = bits & std.posix.POLL.HUP != 0, .failed = bits & std.posix.POLL.ERR != 0 };
            }
            return null;
        }
        pub fn beginTimers(turn: *Turn, now: i96) void {
            for (turn.schedule.timers) |*a| a.due = a.id != null and a.at <= now;
            turn.timer_index = 0;
        }
        pub fn nextTimer(turn: *Turn) ?Timer {
            while (turn.timer_index < turn.schedule.timers.len) {
                const a = &turn.schedule.timers[turn.timer_index];
                turn.timer_index += 1;
                if (!a.due) continue;
                const id = a.id.?;
                a.* = .{};
                return id;
            }
            return null;
        }
    };
    pub fn prepare(self: *Schedule, storage: []std.posix.pollfd) !Turn {
        const n = self.source_count;
        if (n > storage.len) return error.PollCapacity;
        for (self.sources[0..n], storage[0..n]) |s, *fd| {
            fd.* = .{ .fd = s.fd, .events = s.events, .revents = 0 };
        }
        return .{ .schedule = self, .interests = storage[0..n], .deadline = self.earliest(), .watch_limit = self.next_watch };
    }
    pub fn wait(self: *const Schedule, descriptors: []std.posix.pollfd, deadline: ?i96) !void {
        try linux.pollUntil(self.io, descriptors, deadline);
    }

    pub fn watch(self: *Schedule, fd: std.posix.fd_t, interest: enum { read, write, read_write }) !Watch {
        if (fd < 0) return error.InvalidDescriptor;
        var index = self.source_count;
        for (self.sources[0..self.source_count], 0..) |source, i| {
            if (source.id == 0) {
                index = @min(index, i);
            } else if (source.fd == fd) return error.AlreadyWatched;
        }
        if (index == self.sources.len) return error.WatchCapacity;
        if (self.next_watch == std.math.maxInt(u64)) return error.WatchIdExhausted;
        const source = &self.sources[index];
        source.id = self.next_watch;
        self.next_watch += 1;
        self.source_count = @max(self.source_count, index + 1);
        source.fd = fd;
        source.events = switch (interest) {
            .read => std.posix.POLL.IN,
            .write => std.posix.POLL.OUT,
            .read_write => std.posix.POLL.IN | std.posix.POLL.OUT,
        };
        return @fromBackingInt(source.id);
    }

    pub fn unwatch(self: *Schedule, id: Watch) void {
        for (self.sources[0..self.source_count]) |*source| {
            if (source.id == @backingInt(id)) {
                source.* = .{};
                while (self.source_count > 0 and self.sources[self.source_count - 1].id == 0)
                    self.source_count -= 1;
                return;
            }
        }
    }
};
