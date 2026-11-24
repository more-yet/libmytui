const std = @import("std");
const text_module = @import("text.zig");

const geometry = @import("geometry.zig");
const Size = geometry.Size;
const Rect = geometry.Rect;

pub const Caret = struct {
    x: u16,
    y: u16,
    shape: enum(u8) { default = 0, blinking_block, block, blinking_underline, underline, blinking_bar, bar } = .default,
};

pub const Color = union(enum) {
    default,
    indexed: u8,
    rgb: u24,
};
pub const ColorProfile = enum { rgb, indexed, ansi16 };

const ansi_rgb = [16]u24{ 0, 0x800000, 0x008000, 0x808000, 0x000080, 0x800080, 0x008080, 0xc0c0c0, 0x808080, 0xff0000, 0x00ff00, 0xffff00, 0x0000ff, 0xff00ff, 0x00ffff, 0xffffff };
const levels = [6]u8{ 0, 95, 135, 175, 215, 255 };
fn paletteRgb(index: u8) u24 {
    if (index < 16) return ansi_rgb[index];
    if (index >= 232) return @as(u24, 8 + (index - 232) * 10) * 0x010101;
    const i = index - 16;
    return (@as(u24, levels[i / 36]) << 16) | (@as(u24, levels[i / 6 % 6]) << 8) | levels[i % 6];
}
fn mapColor(color: Color, profile: ColorProfile) Color {
    if (profile == .rgb or color == .default) return color;
    if (color == .indexed and (profile == .indexed or color.indexed < 16)) return color;
    const rgb = if (color == .rgb) color.rgb else paletteRgb(color.indexed);
    var best: u8 = 0;
    var distance: u32 = std.math.maxInt(u32);
    for (0..if (profile == .ansi16) @as(usize, 16) else 256) |i| {
        const c = paletteRgb(@intCast(i));
        var d: u32 = 0;
        inline for (.{ 0, 8, 16 }) |shift| {
            const delta = @as(i32, @as(u8, @truncate(rgb >> shift))) - @as(i32, @as(u8, @truncate(c >> shift)));
            d += @intCast(delta * delta);
        }
        if (d < distance) {
            distance = d;
            best = @intCast(i);
            if (d == 0) break;
        }
    }
    return .{ .indexed = best };
}

pub const Style = struct {
    foreground: Color = .default,
    background: Color = .default,
    underline_color: Color = .default,
    blink: bool = false,
    hidden: bool = false,
    strike: bool = false,
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    underline: bool = false,
    reverse: bool = false,

    fn pack(self: Style, profile: ColorProfile) PackedStyle {
        const fg = mapColor(self.foreground, profile);
        const bg = mapColor(self.background, profile);
        const ul = mapColor(self.underline_color, profile);
        return .{
            .underline_color = colorValue(ul),
            .underline_kind = @intCast(@backingInt(std.meta.activeTag(ul))),
            .blink = self.blink,
            .hidden = self.hidden,
            .strike = self.strike,
            .foreground = colorValue(fg),
            .background = colorValue(bg),
            .foreground_kind = if (profile == .ansi16 and fg == .indexed) 3 else @intCast(@backingInt(std.meta.activeTag(fg))),
            .background_kind = if (profile == .ansi16 and bg == .indexed) 3 else @intCast(@backingInt(std.meta.activeTag(bg))),
            .bold = self.bold,
            .dim = self.dim,
            .italic = self.italic,
            .underline = self.underline,
            .reverse = self.reverse,
        };
    }
};

pub const PackedStyle = packed struct(u96) {
    foreground: u24 = 0,
    background: u24 = 0,
    foreground_kind: u2 = 0,
    background_kind: u2 = 0,
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    underline: bool = false,
    reverse: bool = false,
    underline_color: u24 = 0,
    underline_kind: u2 = 0,
    blink: bool = false,
    hidden: bool = false,
    strike: bool = false,
    padding: u10 = 0,
};

pub const Cell = struct {
    style: PackedStyle align(4) = .{},
    glyph: u32 = ' ',
    width: u2 = 1,
    isolate: bool = false,
};
pub const CellView = struct { glyph: []const u8, style: PackedStyle, width: u2 };

pub fn braille(pixels: [4][2]bool) u21 {
    const dots = [4][2]u3{ .{ 0, 3 }, .{ 1, 4 }, .{ 2, 5 }, .{ 6, 7 } };
    var mask: u8 = 0;
    for (pixels, dots) |row, bits| for (row, bits) |on, bit| {
        mask |= @as(u8, @intFromBool(on)) << bit;
    };
    return 0x2800 + @as(u21, mask);
}

const Text = text_module.Text;
pub const StyledText = struct {
    value: Text,
    spans: []const Span,
    pub const Span = struct { end: usize, style: Style };
    pub fn init(value: Text, spans: []const Span) !StyledText {
        var it = value.clusters();
        for (spans) |s| {
            if (s.end <= it.offset or s.end > value.bytes.len) return error.InvalidSpan;
            while (it.offset < s.end) _ = it.next();
            if (it.offset != s.end) return error.InvalidSpan;
        }
        if (it.offset != value.bytes.len) return error.InvalidSpan;
        return .{ .value = value, .spans = spans };
    }
};

pub const Limits = struct {
    max_cells: u32 = 65_536,
    cluster_bytes: u32 = 256 * 1024,
};

const complex_bit: u32 = 1 << 31;

const Buffer = struct {
    cells: []Cell,
    clusters: []u8,
    used: usize = 0,
    caret: ?Caret = null,
    size: Size = .{ .width = 0, .height = 0 },

    fn glyphBytes(self: *const Buffer, cell: Cell, scratch: *[4]u8) []const u8 {
        if (cell.glyph & complex_bit != 0) {
            const offset = cell.glyph & ~complex_bit;
            return self.clusters[offset + 1 ..][0..self.clusters[offset]];
        }
        const len = std.unicode.utf8Encode(@intCast(cell.glyph), scratch) catch unreachable;
        return scratch[0..len];
    }
    fn cellAt(self: *const Buffer, x: u16, y: u16, scalar: *[4]u8) CellView {
        const c = self.cells[@as(usize, y) * self.size.width + x];
        return .{ .glyph = if (c.width == 0) "" else self.glyphBytes(c, scalar), .width = c.width, .style = c.style };
    }

    fn detach(self: *Buffer, index: usize) void {
        switch (self.cells[index].width) {
            0 => {
                std.debug.assert(index % self.size.width > 0);
                self.cells[index - 1] = .{};
            },
            2 => self.cells[index + 1] = .{},
            1 => {},
            else => unreachable,
        }
    }

    fn put(self: *Buffer, index: usize, cluster: text_module.Cluster, style: PackedStyle) !void {
        const scalar_len = std.unicode.utf8ByteSequenceLength(cluster.bytes[0]) catch unreachable;
        const glyph: u32 = if (scalar_len == cluster.bytes.len)
            @call(.always_inline, std.unicode.utf8Decode, .{cluster.bytes}) catch unreachable
        else glyph: {
            const required = cluster.bytes.len + 1;
            if (required > self.clusters.len - self.used) return error.FrameTextCapacity;
            const offset: u32 = @intCast(self.used);
            self.clusters[self.used] = @intCast(cluster.bytes.len);
            @memcpy(self.clusters[self.used + 1 ..][0..cluster.bytes.len], cluster.bytes);
            self.used += required;
            break :glyph complex_bit | offset;
        };
        self.detach(index);
        if (cluster.width == 2) self.detach(index + 1);
        self.cells[index] = .{ .glyph = glyph, .width = cluster.width, .style = style, .isolate = cluster.isolate };
        if (cluster.width == 2) self.cells[index + 1] = .{ .width = 0, .style = style };
    }
};

pub const Frame = struct {
    buffer: *Buffer,
    bounds: Rect,
    wide_ambiguous: bool,
    color_profile: ColorProfile,

    pub fn size(self: Frame) Size {
        return .{ .width = self.bounds.width, .height = self.bounds.height };
    }

    pub fn screenPoint(self: Frame, x: u16, y: u16) ?struct { x: u16, y: u16 } {
        if (x >= self.bounds.width or y >= self.bounds.height) return null;
        return .{ .x = x + self.bounds.x, .y = y + self.bounds.y };
    }

    pub fn inspect(self: Frame, x: u16, y: u16, scalar: *[4]u8) ?CellView {
        const p = self.screenPoint(x, y) orelse return null;
        return self.buffer.cellAt(p.x, p.y, scalar);
    }

    pub fn styled(self: *Frame, content: StyledText, wrap: ?Text.Wrap) !void {
        var t = content.value;
        t.wide_ambiguous = self.wide_ambiguous;
        var rows = t.rows(if (wrap != null) self.bounds.width else std.math.maxInt(usize), wrap orelse .grapheme);
        var span: usize = 0;
        for (0..self.bounds.height) |y| {
            const start = rows.it.offset;
            const line_value = rows.next() orelse break;
            var it = line_value.clusters();
            var x: usize = 0;
            const row = (self.bounds.y + y) * self.buffer.size.width + self.bounds.x;
            paint: while (it.offset < line_value.bytes.len and x < self.bounds.width) {
                while (start + it.offset >= content.spans[span].end) span += 1;
                const style = content.spans[span].style.pack(self.color_profile);
                const end = @min(line_value.bytes.len, content.spans[span].end - start);
                while (it.offset < end) {
                    const g = it.next().?;
                    if (x + g.width > self.bounds.width) break :paint;
                    try self.buffer.put(row + x, g, style);
                    x += g.width;
                }
            }
        }
    }

    /// Formats the first logical line in the first row of this region.
    pub fn paddedLine(self: *Frame, value: Text, marker: Text, alignment: geometry.Alignment, style: Style) !void {
        var body = value;
        body.wide_ambiguous = self.wide_ambiguous;
        var suffix = marker;
        suffix.wide_ambiguous = self.wide_ambiguous;
        const parts = body.truncated(self.bounds.width, suffix);
        body.bytes = parts.body;
        suffix.bytes = parts.suffix;
        const width = body.measure().columns;
        const x: u16 = @intCast(geometry.alignedOffset(self.bounds.width, width + suffix.measure().columns, alignment));
        var row = self.region(.{ .x = 0, .y = 0, .width = self.bounds.width, .height = 1 });
        row.fill(style);
        try row.line(x, 0, body, style);
        try row.line(@intCast(x + width), 0, suffix, style);
    }

    pub fn setCaret(self: Frame, value: ?Caret) void {
        self.buffer.caret = if (value) |c| blk: {
            const p = self.screenPoint(c.x, c.y) orelse break :blk null;
            break :blk .{ .x = p.x, .y = p.y, .shape = c.shape };
        } else null;
    }
    pub fn placeholder(self: *Frame, x: u16, y: u16, row: u16, column: u16, image: u32, placement: u24) !void {
        if (image == 0) return error.InvalidImageId;
        var scratch: [16]u8 = undefined;
        const bytes = try @import("graphics/placeholder.zig").encodeCell(&scratch, row, column, image);
        const p = self.screenPoint(x, y) orelse return;
        const style: Style = .{ .foreground = .{ .rgb = @truncate(image) }, .underline_color = .{ .rgb = placement } };
        try self.buffer.put(@as(usize, p.y) * self.buffer.size.width + p.x, .{ .bytes = bytes, .width = 1 }, style.pack(.rgb));
    }

    pub fn region(self: Frame, rect: Rect) Frame {
        const x = @min(rect.x, self.bounds.width);
        const y = @min(rect.y, self.bounds.height);
        return .{
            .buffer = self.buffer,
            .wide_ambiguous = self.wide_ambiguous,
            .color_profile = self.color_profile,
            .bounds = .{
                .x = self.bounds.x + x,
                .y = self.bounds.y + y,
                .width = @min(rect.width, self.bounds.width - x),
                .height = @min(rect.height, self.bounds.height - y),
            },
        };
    }

    pub fn text(self: *Frame, x: u16, y: u16, bytes: []const u8, style: Style) !void {
        try self.paintLine(x, y, .{ .bytes = bytes, .wide_ambiguous = self.wide_ambiguous }, style, false);
    }

    /// Draw the first logical row of validated text.
    pub fn line(self: *Frame, x: u16, y: u16, value: text_module.Text, style: Style) !void {
        var iterator = value.clusters();
        iterator.wide_ambiguous = self.wide_ambiguous;
        try self.paintLine(x, y, iterator, style, true);
    }

    fn paintLine(self: *Frame, x: u16, y: u16, clusters: text_module.Iterator, style: Style, comptime admitted: bool) !void {
        var it = clusters;
        if (self.screenPoint(x, y)) |p| {
            var room = self.bounds.width - x;
            var index = @as(usize, p.y) * self.buffer.size.width + p.x;
            const packed_style = style.pack(self.color_profile);
            while (room > 0) {
                const g = (if (admitted) it.next() else try it.checkedNext()) orelse return;
                if (g.width == 0 or g.width > room) break;
                try self.buffer.put(index, g, packed_style);
                room -= g.width;
                index += g.width;
            }
        }
        if (!admitted) while (try it.checkedNext() != null) {};
    }

    pub fn print(self: *Frame, x: u16, y: u16, comptime format: []const u8, args: anytype, style: Style) !void {
        var bytes: [1024]u8 = undefined;
        const formatted = std.fmt.bufPrint(&bytes, format, args) catch return error.FormattedTextCapacity;
        try self.text(x, y, formatted, style);
    }

    pub fn fill(self: *Frame, style: Style) void {
        self.paint(' ', style);
    }
    pub const Fill = struct { rect: Rect, char: u8 = ' ', style: Style = .{} };
    pub fn fills(self: *Frame, batch: []const Fill) !void {
        for (batch) |f| if (f.char < 32 or f.char > 126) return error.InvalidFill;
        for (batch) |f| {
            self.region(f.rect).paint(f.char, f.style);
        }
    }
    pub fn fillAscii(self: *Frame, char: u8, style: Style) !void {
        if (char < 32 or char > 126) return error.InvalidFill;
        self.paint(char, style);
    }
    fn paint(self: Frame, char: u8, style: Style) void {
        if (self.bounds.width == 0) return;
        const packed_style = style.pack(self.color_profile);
        for (0..self.bounds.height) |row| {
            const start = (self.bounds.y + row) * self.buffer.size.width + self.bounds.x;
            const end = start + self.bounds.width;
            self.buffer.detach(start);
            self.buffer.detach(end - 1);
            @memset(self.buffer.cells[start..end], .{ .style = packed_style, .glyph = char });
        }
    }
};

pub const Renderer = struct {
    owned: ?struct { allocator: std.mem.Allocator, cells: []Cell, clusters: []u8 } = null,
    front: Buffer,
    back: Buffer,
    size: Size = .{ .width = 0, .height = 0 },
    wide_ambiguous: bool = false,
    phase: enum { idle, drawing, presenting } = .idle,
    invalid: bool = true,
    synchronized: bool = false,
    grapheme_mode: bool = true,
    color_profile: ColorProfile = .rgb,
    finished: bool = false,
    work_budget: u32 = 4096,
    clear_checkpoint: bool = false,
    awaiting_clear: bool = false,
    cancelling: bool = false,
    stats: Stats = .{},
    scan: usize = 0,
    output: [16 * 1024]u8 = undefined,
    output_len: usize = 0,
    accepted: usize = 0,

    pub const Step = union(enum) { output: []const u8, yielded, cleared, complete };
    pub const Stats = struct { scanned: usize = 0, changed: usize = 0, runs: usize = 0, bytes: usize = 0, yielded: usize = 0 };

    pub fn init(allocator: std.mem.Allocator, limits: Limits) !Renderer {
        const n = try storageSize(limits);
        const cells = try allocator.alloc(Cell, n.cells);
        errdefer allocator.free(cells);
        const clusters = try allocator.alloc(u8, n.cluster_bytes);
        var r = splitGrids(cells, clusters);
        r.owned = .{ .allocator = allocator, .cells = cells, .clusters = clusters };
        return r;
    }
    pub fn storageSize(limits: Limits) !struct { cells: usize, cluster_bytes: usize } {
        if (limits.max_cells == 0 or limits.cluster_bytes >= complex_bit) return error.InvalidLimits;
        return .{ .cells = try std.math.mul(usize, limits.max_cells, 2), .cluster_bytes = try std.math.mul(usize, limits.cluster_bytes, 2) };
    }
    pub fn initStorage(limits: Limits, cells: []Cell, clusters: []u8) !Renderer {
        const n = try storageSize(limits);
        if (cells.len < n.cells or clusters.len < n.cluster_bytes) return error.RendererCapacity;
        return splitGrids(cells[0..n.cells], clusters[0..n.cluster_bytes]);
    }
    fn splitGrids(cells: []Cell, clusters: []u8) Renderer {
        return .{
            .front = .{ .cells = cells[0 .. cells.len / 2], .clusters = clusters[0 .. clusters.len / 2] },
            .back = .{ .cells = cells[cells.len / 2 ..], .clusters = clusters[clusters.len / 2 ..] },
        };
    }

    pub fn deinit(self: *Renderer) void {
        if (self.owned) |o| {
            o.allocator.free(o.cells);
            o.allocator.free(o.clusters);
        }
        self.* = undefined;
    }

    /// Set the dimensions for the next draw; submitted grids retain their size.
    pub fn resize(self: *Renderer, size: Size) !void {
        if (size.count() > self.back.cells.len) return error.ScreenCapacity;
        self.size = size;
    }

    pub fn begin(self: *Renderer) Frame {
        std.debug.assert(self.phase == .idle);
        const size = self.size;
        self.back.size = size;
        self.back.used = 0;
        self.back.caret = null;
        @memset(self.back.cells[0..size.count()], .{});
        self.phase = .drawing;
        return .{
            .buffer = &self.back,
            .bounds = .{ .x = 0, .y = 0, .width = size.width, .height = size.height },
            .wide_ambiguous = self.wide_ambiguous,
            .color_profile = self.color_profile,
        };
    }

    pub fn submit(self: *Renderer) void {
        std.debug.assert(self.phase == .drawing);
        if (!std.meta.eql(self.front.size, self.back.size)) self.invalid = true;
        self.phase = .presenting;
        self.finished = false;
        self.stats = .{};
        self.cancelling = false;
        self.awaiting_clear = false;
        self.scan = 0;
    }

    pub fn cancelDraw(self: *Renderer) void {
        std.debug.assert(self.phase == .drawing);
        self.phase = .idle;
    }

    pub fn invalidate(self: *Renderer) void {
        std.debug.assert(self.phase != .presenting);
        self.invalid = true;
    }
    pub fn inspectCommitted(self: *const Renderer, x: u16, y: u16, scalar: *[4]u8) ?CellView {
        if (x >= self.front.size.width or y >= self.front.size.height) return null;
        return self.front.cellAt(x, y, scalar);
    }
    /// Drain step/consume to complete before allowing another producer to write.
    pub fn cancelPresentation(self: *Renderer) void {
        std.debug.assert(self.phase == .presenting);
        self.cancelling = true;
    }

    pub fn step(self: *Renderer) Step {
        std.debug.assert(self.phase == .presenting);
        if (self.accepted < self.output_len) return .{ .output = self.output[self.accepted..self.output_len] };
        if (self.cancelling) {
            if (self.synchronized and self.stats.bytes != 0 and !self.finished) {
                const close = "\x1b[?2026l";
                @memcpy(self.output[0..close.len], close);
                self.accepted = 0;
                self.output_len = close.len;
                self.finished = true;
                return .{ .output = self.output[0..close.len] };
            }
            self.invalid = true;
            self.phase = .idle;
            return .complete;
        }
        if (self.awaiting_clear) {
            self.awaiting_clear = false;
            self.stats.yielded += 1;
            return .cleared;
        }
        const sync_on = "\x1b[?2026h";
        const emitted = self.stats.bytes != 0;
        const prefix: []const u8 = if (emitted) "" else if (self.synchronized) sync_on else if (self.front.caret != null) "\x1b[?25l" else "";
        var writer = std.Io.Writer.fixed(self.output[prefix.len..]);
        if (self.invalid and !emitted) {
            writer.writeAll("\x1b[0m\x1b[2J") catch unreachable;
            self.awaiting_clear = self.clear_checkpoint;
        }
        var work: usize = 0;
        var scan = self.scan;
        const count = self.back.size.count();
        const budget: usize = @max(2, self.work_budget);
        while (!self.awaiting_clear and scan < count and work < budget and writer.buffered().len + 192 <= writer.buffer.len) {
            var cell = self.back.cells[scan];
            if (cell.width == 0 or (!self.invalid and self.equal(scan))) {
                scan += 1;
                work += 1;
                continue;
            }
            if (work + cell.width > budget) break;
            const row = scan / self.back.size.width;
            const end = (row + 1) * self.back.size.width;
            const style = cell.style;
            var isolate = cell.isolate;
            if (scan % self.back.size.width > 0) {
                const previous = scan - @as(usize, if (self.back.cells[scan - 1].width == 0) 2 else 1);
                isolate = isolate or self.back.cells[previous].isolate;
            }
            writer.print("\x1b[{d};{d}H", .{ row + 1, scan % self.back.size.width + 1 }) catch unreachable;
            encodeStyle(&writer, style);
            self.stats.runs += 1;
            while (true) {
                if (isolate and self.grapheme_mode) {
                    var scratch: [4]u8 = undefined;
                    const bytes = self.back.glyphBytes(cell, &scratch);
                    const first = std.unicode.utf8ByteSequenceLength(bytes[0]) catch unreachable;
                    writer.writeAll("\x1b[?2027l") catch unreachable;
                    writer.writeAll(bytes[0..first]) catch unreachable;
                    writer.writeAll("\x1b[?2027h") catch unreachable;
                    writer.writeAll(bytes[first..]) catch unreachable;
                    isolate = false;
                } else if (cell.glyph < 0x80) {
                    writer.writeByte(@intCast(cell.glyph)) catch unreachable;
                } else {
                    var scratch: [4]u8 = undefined;
                    writer.writeAll(self.back.glyphBytes(cell, &scratch)) catch unreachable;
                }
                scan += cell.width;
                work += cell.width;
                self.stats.changed += cell.width;
                if (cell.isolate or scan == end or work == budget or
                    writer.buffered().len + text_module.max_cluster_bytes > writer.buffer.len) break;
                const next = self.back.cells[scan];
                if (next.isolate or @as(u96, @bitCast(next.style)) != @as(u96, @bitCast(style)) or
                    work + next.width > budget or (!self.invalid and self.equal(scan))) break;
                cell = next;
            }
        }
        self.scan = scan;
        self.stats.scanned += work;
        if (!self.awaiting_clear and scan == count and !self.finished and writer.buffer.len - writer.buffered().len >= 64) {
            const changed = self.invalid or !std.meta.eql(self.front.caret, self.back.caret);
            if (self.back.caret) |caret| {
                if (changed or emitted or writer.buffered().len != 0) writer.print("\x1b[{d};{d}H\x1b[{d} q\x1b[?25h", .{ @as(u32, caret.y) + 1, @as(u32, caret.x) + 1, @backingInt(caret.shape) }) catch unreachable;
            } else if (changed) writer.writeAll("\x1b[?25l") catch unreachable;
            if (self.synchronized and (emitted or writer.buffered().len != 0)) writer.writeAll("\x1b[?2026l") catch unreachable;
            self.finished = true;
        }
        self.accepted = 0;
        self.output_len = writer.buffered().len;
        if (self.output_len != 0) {
            @memcpy(self.output[0..prefix.len], prefix);
            self.output_len += prefix.len;
            return .{ .output = self.output[0..self.output_len] };
        }
        if (self.scan < count) {
            self.stats.yielded += 1;
            return .yielded;
        }
        std.mem.swap(Buffer, &self.front, &self.back);
        self.phase = .idle;
        self.invalid = false;
        return .complete;
    }

    pub fn consume(self: *Renderer, count: usize) void {
        std.debug.assert(self.phase == .presenting and count <= self.output_len - self.accepted);
        self.accepted += count;
        self.stats.bytes += count;
    }

    fn equal(self: *const Renderer, index: usize) bool {
        const a = self.front.cells[index];
        const b = self.back.cells[index];
        if (a.width != b.width or @as(u96, @bitCast(a.style)) != @as(u96, @bitCast(b.style))) return false;
        if (a.glyph & complex_bit == 0 and b.glyph & complex_bit == 0) return a.glyph == b.glyph;
        var a_bytes: [4]u8 = undefined;
        var b_bytes: [4]u8 = undefined;
        return std.mem.eql(u8, self.front.glyphBytes(a, &a_bytes), self.back.glyphBytes(b, &b_bytes));
    }
};

fn colorValue(color: Color) u24 {
    return switch (color) {
        .default => 0,
        .indexed => |value| value,
        .rgb => |value| value,
    };
}

test "styled graphemes and clipped drawing share layout in borrowed grids" {
    var cells: [24]Cell = undefined;
    var arena: [128]u8 = undefined;
    var r = try Renderer.initStorage(.{ .max_cells = 12, .cluster_bytes = 64 }, &cells, &arena);
    defer r.deinit();
    try r.resize(.{ .width = 4, .height = 3 });
    var f = r.begin();
    const t = try Text.init("e\u{301}界z", .{});
    try std.testing.expectError(error.InvalidSpan, StyledText.init(t, &.{.{ .end = 1, .style = .{} }}));
    const s = try StyledText.init(t, &.{ .{ .end = 3, .style = .{ .strike = true } }, .{ .end = t.bytes.len, .style = .{ .blink = true } } });
    var box = f.region(.{ .x = 1, .y = 0, .width = 2, .height = 3 });
    try box.styled(s, .word);
    var scratch: [4]u8 = undefined;
    try std.testing.expectEqualStrings("e\u{301}", box.inspect(0, 0, &scratch).?.glyph);
    try std.testing.expect(box.inspect(0, 0, &scratch).?.style.strike);
    try std.testing.expectEqualStrings("界", box.inspect(0, 1, &scratch).?.glyph);
    try std.testing.expect(box.inspect(1, 1, &scratch).?.width == 0 and box.inspect(0, 2, &scratch).?.style.blink);
    try f.fills(&.{.{ .rect = .{ .x = 2, .y = 1, .height = 1, .width = 1 }, .char = '#' }});
    try std.testing.expectEqualStrings(" ", box.inspect(0, 1, &scratch).?.glyph);
    try box.paddedLine(t, try Text.init(".", .{}), .end, .{});
    try std.testing.expectEqualStrings(".", box.inspect(1, 0, &scratch).?.glyph);
}

test "cancellation preserves exposed output, closes synchronized frame and forces full comparison reset" {
    var r = try Renderer.init(std.testing.allocator, .{ .max_cells = 8, .cluster_bytes = 0 });
    defer r.deinit();
    r.synchronized = true;
    r.work_budget = 2;
    r.clear_checkpoint = true;
    try r.resize(.{ .width = 8, .height = 1 });
    var f = r.begin();
    try f.fillAscii('x', .{});
    r.submit();
    const clear = r.step().output;
    try std.testing.expect(std.mem.endsWith(u8, clear, "\x1b[2J"));
    r.consume(clear.len);
    try std.testing.expect(r.step() == .cleared);
    const part = r.step().output;
    r.consume(1);
    r.cancelPresentation();
    try std.testing.expectEqualStrings(part[1..], r.step().output);
    r.consume(part.len - 1);
    const cleanup = r.step().output;
    try std.testing.expectEqualStrings("\x1b[?2026l", cleanup);
    r.consume(cleanup.len);
    try std.testing.expect(r.step() == .complete and r.invalid and r.front.size.width == 0);
    try std.testing.expect(r.stats.scanned == 2 and r.stats.changed == 2 and r.stats.runs == 1 and r.stats.yielded == 1 and r.stats.bytes == clear.len + part.len + cleanup.len);
}

fn encodeStyle(writer: *std.Io.Writer, style: PackedStyle) void {
    writer.writeAll("\x1b[0") catch unreachable;
    if (style.bold) writer.writeAll(";1") catch unreachable;
    if (style.dim) writer.writeAll(";2") catch unreachable;
    if (style.italic) writer.writeAll(";3") catch unreachable;
    if (style.underline) writer.writeAll(";4") catch unreachable;
    if (style.reverse) writer.writeAll(";7") catch unreachable;
    if (style.blink) writer.writeAll(";5") catch unreachable;
    if (style.hidden) writer.writeAll(";8") catch unreachable;
    if (style.strike) writer.writeAll(";9") catch unreachable;
    inline for (.{ .{ style.foreground_kind, style.foreground, @as(u8, 38) }, .{ style.background_kind, style.background, @as(u8, 48) }, .{ style.underline_kind, style.underline_color, @as(u8, 58) } }) |color| {
        switch (color[0]) {
            0 => {},
            1 => writer.print(";{d};5;{d}", .{ color[2], color[1] }) catch unreachable,
            2 => writer.print(";{d};2;{d};{d};{d}", .{ color[2], color[1] >> 16, (color[1] >> 8) & 255, color[1] & 255 }) catch unreachable,
            3 => writer.print(";{d}", .{color[2] - 8 + color[1] % 8 + (if (color[1] >= 8) @as(u8, 60) else 0)}) catch unreachable,
        }
    }
    writer.writeByte('m') catch unreachable;
}

test "caret-only frames and synchronization commit on final acknowledgment" {
    var r = try Renderer.init(std.testing.allocator, .{ .max_cells = 8, .cluster_bytes = 0 });
    defer r.deinit();
    r.synchronized = true;
    r.color_profile = .ansi16;
    const size: Size = .{ .width = 8, .height = 1 };
    try r.resize(size);
    for (0..4) |i| {
        var frame = r.begin();
        try frame.text(0, 0, "x", .{ .foreground = .{ .rgb = 0xff0000 } });
        const region = frame.region(.{ .x = 2, .y = 0, .width = 3, .height = 1 });
        region.setCaret(.{ .x = if (i == 0) 0 else 1, .y = 0, .shape = .blinking_bar });
        if (i == 2) {
            r.cancelDraw();
            continue;
        }
        r.submit();
        if (i == 3) {
            try std.testing.expect(r.step() == .complete);
            break;
        }
        const bytes = r.step().output;
        try std.testing.expect(std.mem.startsWith(u8, bytes, "\x1b[?2026h"));
        try std.testing.expect(std.mem.endsWith(u8, bytes, "\x1b[5 q\x1b[?25h\x1b[?2026l"));
        if (i == 0) try std.testing.expect(std.mem.indexOf(u8, bytes, ";91m") != null);
        r.consume(bytes.len - 1);
        try std.testing.expectEqualStrings("l", r.step().output);
        try std.testing.expectEqual(if (i == 0) null else @as(?u16, 2), if (r.front.caret) |c| c.x else null);
        r.consume(1);
        try std.testing.expect(r.step() == .complete);
    }
}

test "failed drawing and cancelled resize preserve the committed frame and repaint state" {
    var renderer = try Renderer.init(std.testing.allocator, .{ .max_cells = 8, .cluster_bytes = 0 });
    defer renderer.deinit();
    const size: Size = .{ .width = 8, .height = 1 };
    try renderer.resize(size);
    var frame = renderer.begin();
    try frame.text(0, 0, "界", .{});
    renderer.submit();
    while (true) switch (renderer.step()) {
        .output => |output| renderer.consume(output.len),
        .yielded, .cleared => {},
        .complete => break,
    };
    frame = renderer.begin();
    try frame.text(0, 0, "界", .{});
    try std.testing.expectError(error.FrameTextCapacity, frame.text(1, 0, "e\u{301}", .{}));
    try std.testing.expectEqual(@as(u2, 2), renderer.back.cells[0].width);
    try std.testing.expectEqual(@as(u2, 0), renderer.back.cells[1].width);
    renderer.cancelDraw();
    try std.testing.expectEqual(@as(u32, '界'), renderer.front.cells[0].glyph);
    try renderer.resize(.{ .width = 4, .height = 1 });
    _ = renderer.begin();
    renderer.cancelDraw();
    try renderer.resize(size);
    try std.testing.expectError(error.ScreenCapacity, renderer.resize(.{ .width = 9, .height = 1 }));
    frame = renderer.begin();
    try frame.text(0, 0, "界", .{});
    renderer.submit();
    try std.testing.expect(renderer.step() == .complete);
}

test "resized frames keep committed storage stable across output batches and partial writes" {
    var renderer = try Renderer.init(std.testing.allocator, .{ .max_cells = 9600, .cluster_bytes = 40_000 });
    defer renderer.deinit();
    var committed_size: Size = .{ .width = 0, .height = 0 };
    const sizes = [_]Size{
        .{ .width = 80, .height = 24 },
        .{ .width = 120, .height = 80 },
        .{ .width = 40, .height = 32 },
    };
    for (sizes) |size| {
        try renderer.resize(size);
        var frame = renderer.begin();
        for (0..size.height) |y| {
            for (0..size.width) |x| {
                try frame.text(@intCast(x), @intCast(y), "e\u{301}", .{
                    .background = .{ .indexed = @intCast(x % 2) },
                });
            }
        }
        renderer.submit();
        const committed_cells = try std.testing.allocator.dupe(Cell, renderer.front.cells[0..committed_size.count()]);
        defer std.testing.allocator.free(committed_cells);
        const committed_clusters = try std.testing.allocator.dupe(u8, renderer.front.clusters[0..renderer.front.used]);
        defer std.testing.allocator.free(committed_clusters);
        var batches: usize = 0;
        var pending: [16 * 1024]u8 = undefined;
        while (true) {
            switch (renderer.step()) {
                .output => |output| {
                    batches += 1;
                    @memcpy(pending[0..output.len], output);
                    var accepted: usize = 0;
                    while (accepted < output.len) {
                        const suffix = renderer.step().output;
                        try std.testing.expectEqualSlices(u8, pending[accepted..output.len], suffix);
                        try std.testing.expectEqual(committed_size, renderer.front.size);
                        const count = @min(suffix.len, 1 + accepted % 257);
                        renderer.consume(count);
                        accepted += count;
                    }
                    try std.testing.expectEqualSlices(Cell, committed_cells, renderer.front.cells[0..committed_size.count()]);
                    try std.testing.expectEqualSlices(u8, committed_clusters, renderer.front.clusters[0..renderer.front.used]);
                },
                .yielded, .cleared => {},
                .complete => break,
            }
        }
        try std.testing.expect(batches > 1);
        try std.testing.expectEqual(size, renderer.front.size);
        committed_size = size;
    }
}
