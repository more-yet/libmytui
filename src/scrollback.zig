const std = @import("std");
const Text = @import("text.zig").Text;

pub const Scrollback = struct {
    allocator: ?std.mem.Allocator = null,
    bytes: []u8,
    lengths: []usize,
    line_bytes: usize,
    tail: usize = 0,
    count: usize = 0,
    staged: usize = 0,
    overlong: bool = false,
    cr: bool = false,

    pub const Changes = struct {
        appended: usize = 0,
        evicted: usize = 0,
        invalid: usize = 0,
        overlong: usize = 0,
    };

    pub fn init(allocator: std.mem.Allocator, lines: u32, line_bytes: u32) !Scrollback {
        const n = try storageSize(lines, line_bytes);
        const bytes = try allocator.alloc(u8, n.bytes);
        errdefer allocator.free(bytes);
        const lengths = try allocator.alloc(usize, n.slots);
        return .{ .allocator = allocator, .bytes = bytes, .lengths = lengths, .line_bytes = line_bytes };
    }
    pub fn storageSize(lines: usize, line_bytes: u32) !struct { slots: usize, bytes: usize } {
        if (lines == 0 or line_bytes == 0) return error.InvalidCapacity;
        const n = try std.math.add(usize, lines, 1);
        return .{ .slots = n, .bytes = try std.math.mul(usize, n, line_bytes) };
    }
    pub fn initStorage(lengths: []usize, bytes: []u8, line_bytes: u32) !Scrollback {
        const n = try storageSize(lengths.len -| 1, line_bytes);
        if (bytes.len < n.bytes) return error.InvalidCapacity;
        return .{ .bytes = bytes[0..n.bytes], .lengths = lengths, .line_bytes = line_bytes };
    }

    pub fn deinit(self: *Scrollback) void {
        if (self.allocator) |a| {
            a.free(self.bytes);
            a.free(self.lengths);
        }
        self.* = undefined;
    }

    pub fn line(self: *const Scrollback, index: usize, wide_ambiguous: bool) Text {
        std.debug.assert(index < self.count);
        const slot = (self.tail + self.lengths.len - self.count + index) % self.lengths.len;
        return .{ .bytes = self.bytes[slot * self.line_bytes ..][0..self.lengths[slot]], .wide_ambiguous = wide_ambiguous, .multiline = false };
    }

    pub fn feed(self: *Scrollback, bytes: []const u8) Changes {
        var delta: Changes = .{};
        for (bytes) |byte| {
            if (byte == '\n') {
                self.commit(&delta);
                continue;
            }
            if (self.cr) self.append('\r');
            self.cr = byte == '\r';
            if (!self.cr) self.append(byte);
        }
        return delta;
    }

    pub fn finish(self: *Scrollback) Changes {
        var delta: Changes = .{};
        if (self.cr) self.append('\r');
        if (self.staged != 0 or self.overlong) self.commit(&delta);
        return delta;
    }

    fn append(self: *Scrollback, byte: u8) void {
        if (self.staged == self.line_bytes) {
            self.overlong = true;
            return;
        }
        self.bytes[self.tail * self.line_bytes + self.staged] = byte;
        self.staged += 1;
    }

    fn commit(self: *Scrollback, delta: *Changes) void {
        defer {
            self.staged = 0;
            self.cr = false;
            self.overlong = false;
        }
        if (self.overlong) {
            delta.overlong += 1;
            return;
        }
        const staged = self.bytes[self.tail * self.line_bytes ..][0..self.staged];
        _ = Text.init(staged, .{}) catch {
            delta.invalid += 1;
            return;
        };
        self.lengths[self.tail] = self.staged;
        self.tail = (self.tail + 1) % self.lengths.len;
        if (self.count == self.lengths.len - 1) delta.evicted += 1 else self.count += 1;
        delta.appended += 1;
    }
};

test "fragmented lines, capacity recovery, eviction and final partial line" {
    var ring = try Scrollback.init(std.testing.allocator, 2, 3);
    defer ring.deinit();
    _ = ring.feed("123\r");
    const d = ring.feed("\n1234\n\xff\n\n\xe7");
    try std.testing.expectEqual(Scrollback.Changes{ .appended = 2, .overlong = 1, .invalid = 1 }, d);
    _ = ring.feed("\x95\x8c");
    try std.testing.expectEqual(@as(usize, 1), ring.finish().evicted);
    const rejected = ring.feed("\xff\n1234\n");
    try std.testing.expectEqual(Scrollback.Changes{ .invalid = 1, .overlong = 1 }, rejected);
    try std.testing.expectEqualStrings("", ring.line(0, false).bytes);
    try std.testing.expectEqualStrings("界", ring.line(1, false).bytes);
    try std.testing.expectEqual(@as(usize, 0), ring.finish().appended);
}
