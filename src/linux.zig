const std = @import("std");
const linux = std.os.linux;

pub const Notification = struct {
    fd: std.posix.fd_t,

    pub fn init() !Notification {
        const result = linux.eventfd(0, linux.EFD.NONBLOCK | linux.EFD.CLOEXEC);
        if (linux.errno(result) != .SUCCESS) return error.NotificationOpen;
        return .{ .fd = @intCast(result) };
    }

    pub fn signal(self: *const Notification) !void {
        const increment: u64 = 1;
        while (true) switch (linux.errno(linux.write(self.fd, std.mem.asBytes(&increment), 8))) {
            .SUCCESS, .AGAIN => return,
            .INTR => continue,
            else => return error.NotificationWrite,
        };
    }

    pub fn consume(self: *const Notification) !bool {
        var count: u64 = undefined;
        while (true) switch (linux.errno(linux.read(self.fd, std.mem.asBytes(&count), 8))) {
            .SUCCESS => return true,
            .AGAIN => return false,
            .INTR => continue,
            else => return error.NotificationRead,
        };
    }

    pub fn deinit(self: *Notification) void {
        _ = linux.close(self.fd);
        self.* = undefined;
    }
};

pub fn now(io: std.Io) i96 {
    return @divFloor(std.Io.Clock.awake.now(io).nanoseconds, std.time.ns_per_ms);
}

pub fn read(fd: std.posix.fd_t, bytes: []u8) !?usize {
    const result = linux.read(fd, bytes.ptr, bytes.len);
    return switch (linux.errno(result)) {
        .SUCCESS => result,
        .INTR, .AGAIN => null,
        .IO => 0,
        else => error.InputFailed,
    };
}

pub fn write(fd: std.posix.fd_t, bytes: []const u8) !?usize {
    const result = linux.write(fd, bytes.ptr, bytes.len);
    return switch (linux.errno(result)) {
        .SUCCESS => if (result == 0) error.OutputClosed else result,
        .INTR, .AGAIN => null,
        else => error.OutputFailed,
    };
}

pub fn pollUntil(io: std.Io, descriptors: []std.posix.pollfd, deadline: ?i96) !void {
    const timeout: i32 = if (deadline) |d| @intCast(std.math.clamp(d -| now(io), 0, std.math.maxInt(i32))) else -1;
    const result = std.posix.system.poll(descriptors.ptr, @intCast(descriptors.len), timeout);
    switch (std.posix.errno(result)) {
        .SUCCESS => {},
        .INTR => {
            for (descriptors) |*descriptor| descriptor.revents = 0;
            return;
        },
        else => return error.PollFailed,
    }
    for (descriptors) |descriptor| {
        if (descriptor.revents & std.posix.POLL.NVAL != 0) return error.ClosedDescriptor;
    }
}
