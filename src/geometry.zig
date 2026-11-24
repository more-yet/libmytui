const std = @import("std");

pub const Alignment = enum { start, center, end };
pub fn alignedOffset(space: usize, used: usize, alignment: Alignment) usize {
    const free = space -| used;
    return switch (alignment) {
        .start => 0,
        .center => free / 2,
        .end => free,
    };
}

pub const Size = struct {
    width: u16,
    height: u16,
    pixel_width: u16 = 0,
    pixel_height: u16 = 0,

    pub fn count(self: Size) usize {
        return @as(usize, self.width) * self.height;
    }
};

pub const Rect = struct {
    x: u16,
    y: u16,
    width: u16,
    height: u16,
    pub fn contains(self: Rect, x: u16, y: u16) bool {
        return x >= self.x and y >= self.y and x - self.x < self.width and y - self.y < self.height;
    }
    pub fn inset(self: Rect, horizontal: u16, vertical: u16) Rect {
        return self.insetSides(horizontal, vertical, horizontal, vertical);
    }
    pub fn insetSides(self: Rect, left: u16, top: u16, right: u16, bottom: u16) Rect {
        return .{ .x = self.x +| @min(left, self.width), .y = self.y +| @min(top, self.height), .width = self.width -| left -| right, .height = self.height -| top -| bottom };
    }
    pub fn place(self: Rect, wanted: Size, minimum: Size, maximum: Size, horizontal: Alignment, vertical: Alignment) !Rect {
        if (minimum.width > @min(self.width, maximum.width) or minimum.height > @min(self.height, maximum.height)) return error.LayoutSpace;
        const w = std.math.clamp(wanted.width, minimum.width, @min(self.width, maximum.width));
        const h = std.math.clamp(wanted.height, minimum.height, @min(self.height, maximum.height));
        return .{ .x = try std.math.add(u16, self.x, @intCast(alignedOffset(self.width, w, horizontal))), .y = try std.math.add(u16, self.y, @intCast(alignedOffset(self.height, h, vertical))), .width = w, .height = h };
    }
    pub const Axis = enum { horizontal, vertical };
    pub fn split(self: Rect, axis: Axis, cells: u16, gap: u16) [2]Rect {
        var a = self;
        var b = self;
        if (axis == .horizontal) {
            a.width = @min(cells, self.width);
            const dx = @min(self.width, a.width +| gap);
            b.x +|= dx;
            b.width -= dx;
        } else {
            a.height = @min(cells, self.height);
            const dy = @min(self.height, a.height +| gap);
            b.y +|= dy;
            b.height -= dy;
        }
        return .{ a, b };
    }
    pub fn grid(self: Rect, col: u16, row: u16, cols: u16, rows: u16) ?Rect {
        if (col >= cols or row >= rows) return null;
        const x: u16 = @intCast(@as(u32, self.width) * col / cols);
        const y: u16 = @intCast(@as(u32, self.height) * row / rows);
        return .{ .x = self.x +| x, .y = self.y +| y, .width = @intCast(@as(u32, self.width) * (col + 1) / cols - x), .height = @intCast(@as(u32, self.height) * (row + 1) / rows - y) };
    }
};
pub const Constraint = struct { min: u16 = 0, max: u16 = 65535, weight: u16 = 1 };
pub const Track = struct {
    start: u16,
    size: u16,
    pub fn cell(column: Track, row: Track) Rect {
        return .{ .x = column.start, .y = row.start, .width = column.size, .height = row.size };
    }
};

/// Absolute row/column starts, shared by splits and grids. Spare space trails
/// the tracks when every positive weight is capped. Later tracks win rounding ties.
pub fn tracks(origin: u16, extent: u16, gap: u16, specs: []const Constraint, storage: []Track) ![]Track {
    if (@as(u32, origin) + extent > 65535) return error.LayoutOverflow;
    const free = try trackSpace(extent, gap, specs, storage);
    return divideTracks(origin, free, gap, specs, storage);
}
fn trackSpace(extent: u16, gap: u16, specs: []const Constraint, storage: []Track) !u16 {
    if (specs.len > storage.len) return error.LayoutCapacity;
    const gaps = try std.math.mul(usize, specs.len -| 1, gap);
    if (gaps > extent) return error.LayoutSpace;
    var free: u16 = extent - @as(u16, @intCast(gaps));
    for (specs) |s| {
        if (s.min > s.max or free < s.min) return error.LayoutSpace;
        free -= s.min;
    }
    return free;
}
fn divideTracks(origin: u16, available: u16, gap: u16, specs: []const Constraint, storage: []Track) []Track {
    var free = available;
    const result = storage[0..specs.len];
    for (specs, result) |s, *t| t.* = .{ .start = 0, .size = s.min };
    while (free != 0) {
        var total: u128 = 0;
        for (specs, result) |s, t| if (t.size < s.max) {
            total += s.weight;
        };
        if (total == 0) break;
        const budget = free;
        var carry: u128 = 0;
        for (specs, result) |s, *t| {
            if (t.size == s.max) continue;
            carry += @as(u128, budget) * s.weight;
            const added: u16 = @intCast(@min(carry / total, s.max - t.size));
            t.size += added;
            free -= added;
            carry %= total;
        }
    }
    var pos = origin;
    for (result, 0..) |*t, i| {
        if (i != 0) pos += gap;
        t.start = pos;
        pos += t.size;
    }
    return result;
}

pub const AxisTracks = struct { specs: []const Constraint, storage: []Track, gap: u16 = 0 };
pub const Grid = struct {
    bounds: Rect,
    columns: ?[]const Track,
    rows: ?[]const Track,
    pub fn rect(self: Grid, col: usize, row: usize) ?Rect {
        const column = trackAt(self.columns, col, self.bounds.x, self.bounds.width) orelse return null;
        const line = trackAt(self.rows, row, self.bounds.y, self.bounds.height) orelse return null;
        return Track.cell(column, line);
    }
    fn trackAt(axis: ?[]const Track, index: usize, start: u16, extent: u16) ?Track {
        if (axis) |items| return if (index < items.len) items[index] else null;
        return if (index == 0) .{ .start = start, .size = extent } else null;
    }
};
/// A null axis is one unsplit track. Admit both axes before writing either.
pub fn weightedGrid(bounds: Rect, columns: ?AxisTracks, rows: ?AxisTracks) !Grid {
    if (@as(u32, bounds.x) + bounds.width > 65535 or @as(u32, bounds.y) + bounds.height > 65535) return error.LayoutOverflow;
    const x = if (columns) |a| try trackSpace(bounds.width, a.gap, a.specs, a.storage) else 0;
    const y = if (rows) |a| try trackSpace(bounds.height, a.gap, a.specs, a.storage) else 0;
    return .{ .bounds = bounds, .columns = if (columns) |a| divideTracks(bounds.x, x, a.gap, a.specs, a.storage) else null, .rows = if (rows) |a| divideTracks(bounds.y, y, a.gap, a.specs, a.storage) else null };
}

test "layout admission preserves caller storage across failures on either axis" {
    var out: [3]Track = undefined;
    const specs = [_]Constraint{ .{ .weight = 1 }, .{ .weight = 9, .max = 1 }, .{ .weight = 1 } };
    _ = try tracks(2, 12, 1, &specs, &out);
    try std.testing.expectEqualSlices(Track, &.{ .{ .start = 2, .size = 4 }, .{ .start = 7, .size = 1 }, .{ .start = 9, .size = 5 } }, &out);
    const saved = out;
    try std.testing.expectError(error.LayoutOverflow, tracks(65535, 1, 0, &specs, &out));
    try std.testing.expectError(error.LayoutCapacity, tracks(0, 5, 1, &specs, out[0..2]));
    try std.testing.expectError(error.LayoutSpace, tracks(0, 1, 1, &specs, &out));
    try std.testing.expectEqualSlices(Track, &saved, &out);
    try std.testing.expectError(error.LayoutCapacity, weightedGrid(.{ .x = 0, .y = 0, .width = 8, .height = 8 }, .{ .specs = &specs, .storage = &out }, .{ .specs = &specs, .storage = &.{} }));
    try std.testing.expectEqualSlices(Track, &saved, &out);
}
