const std = @import("std");
const Rect = @import("geometry.zig").Rect;

pub const Viewport = struct {
    offset: usize = 0,

    pub const Range = struct { start: usize, end: usize };

    pub fn visible(self: *Viewport, count: usize, extent: usize) Range {
        self.offset = @min(self.offset, count -| extent);
        return .{ .start = self.offset, .end = @min(count, self.offset +| extent) };
    }

    pub fn reveal(self: *Viewport, index: usize, count: usize, extent: usize) void {
        const range = self.visible(count, extent);
        if (count == 0 or extent == 0) return;
        const item = @min(index, count - 1);
        if (item < range.start) self.offset = item;
        if (item >= range.end) self.offset = item - (extent - 1);
    }

    pub fn evictLeading(self: *Viewport, rows: usize) void {
        self.offset -|= rows;
    }

    pub fn revealLast(self: *Viewport, count: usize, extent: usize) void {
        self.offset = count -| extent;
    }

    pub fn thumb(self: Viewport, count: usize, extent: usize, track: usize) Range {
        if (count <= extent or track == 0) return .{ .start = 0, .end = track };
        const len: usize = @max(1, @as(usize, @intCast(@as(u128, extent) * track / count)));
        const start: usize = @intCast(@as(u128, @min(self.offset, count - extent)) * (track - len) / (count - extent));
        return .{ .start = start, .end = start + len };
    }
};

pub const Target = struct { id: u64, rect: Rect, enabled: bool = true, focusable: bool = true };
pub const Direction = enum { left, right, up, down };

pub fn hitTarget(targets: []const Target, x: u16, y: u16) ?u64 {
    var i = targets.len;
    while (i > 0) {
        i -= 1;
        const t = targets[i];
        if (t.enabled and t.focusable and t.rect.contains(x, y)) return t.id;
    }
    return null;
}

pub fn directional(targets: []const Target, from: Rect, direction: Direction) ?u64 {
    const horizontal = direction == .left or direction == .right;
    const fx = @as(i32, from.x) * 2 + from.width;
    const fy = @as(i32, from.y) * 2 + from.height;
    var best: ?u64 = null;
    var score: [3]u32 = undefined;
    for (targets) |t| {
        const r = t.rect;
        if (!t.enabled or !t.focusable or r.width == 0 or r.height == 0) continue;
        const dx = @as(i32, r.x) * 2 + r.width - fx;
        const dy = @as(i32, r.y) * 2 + r.height - fy;
        const distance = switch (direction) {
            .left => -dx,
            .right => dx,
            .up => -dy,
            .down => dy,
        };
        if (distance <= 0) continue;
        const across = if (horizontal) @abs(dy) else @abs(dx);
        const beam = if (horizontal) @as(u32, from.height) + r.height else @as(u32, from.width) + r.width;
        const candidate = [3]u32{ @intFromBool(across >= beam), @intCast(distance), across };
        if (best == null or std.mem.order(u32, &candidate, &score) == .lt) {
            score = candidate;
            best = t.id;
        }
    }
    return best;
}

/// Borrows the item heights and one start offset per item.
pub const ItemRows = struct {
    starts: []const usize,
    heights: []const u16,
    total: usize,

    pub fn init(heights: []const u16, gap: u16, offsets: []usize) !ItemRows {
        if (offsets.len < heights.len) return error.ItemCapacity;
        var total: usize = 0;
        for (heights, 0..) |h, i| {
            if (i != 0) total = try std.math.add(usize, total, gap);
            offsets[i] = total;
            total = try std.math.add(usize, total, h);
        }
        return .{ .starts = offsets[0..heights.len], .heights = heights, .total = total };
    }

    pub fn range(self: ItemRows, index: usize) Viewport.Range {
        const start = self.starts[index];
        return .{ .start = start, .end = start + self.heights[index] };
    }

    pub fn hit(self: ItemRows, row: usize) ?usize {
        var lo: usize = 0;
        var hi = self.starts.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.starts[mid] <= row) lo = mid + 1 else hi = mid;
        }
        return if (lo != 0 and row < self.range(lo - 1).end) lo - 1 else null;
    }
};

pub fn moveSelection(index: usize, count: usize, delta: isize) ?usize {
    if (count == 0) return null;
    const from = @min(index, count - 1);
    return if (delta < 0) from -| @abs(delta) else @min(count - 1, from +| @abs(delta));
}

pub const Focus = struct {
    id: ?u64 = null,

    /// Resolves the focused identity in the current order.
    pub fn reconcile(self: *Focus, order: []const u64) ?usize {
        const id = self.id orelse return null;
        if (std.mem.indexOfScalar(u64, order, id)) |i| return i;
        self.id = null;
        return null;
    }

    pub fn move(self: *Focus, order: []const u64, delta: isize) void {
        const from = self.reconcile(order);
        if (order.len != 0)
            self.id = order[if (from) |i| moveSelection(i, order.len, delta).? else if (delta < 0) order.len - 1 else 0];
    }
};

test "viewport shrink, overflow and removal of focused identity" {
    var view: Viewport = .{};
    view.reveal(std.math.maxInt(usize), std.math.maxInt(usize), 5);
    try std.testing.expectEqual(std.math.maxInt(usize) - 5, view.offset);
    try std.testing.expectEqual(Viewport.Range{ .start = 0, .end = 3 }, view.visible(3, 5));
    var focus: Focus = .{ .id = 2 };
    try std.testing.expectEqual(0, focus.reconcile(&.{ 2, 1 }));
    focus.move(&.{ 2, 1 }, std.math.maxInt(isize));
    try std.testing.expectEqual(1, focus.id);
    try std.testing.expect(focus.reconcile(&.{2}) == null and focus.id == null);
}
