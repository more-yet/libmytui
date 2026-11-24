const std = @import("std");
const unicode = @import("unicode.zig");
const lb = @import("line_break.zig");

pub const max_cluster_bytes = 48;
pub const Error = error{ InvalidUtf8, ControlCharacter, GraphemeTooLong, ZeroWidthGrapheme };

pub const Cluster = struct {
    bytes: []const u8,
    width: u2,
    isolate: bool = false,
};

const Grapheme = struct {
    previous: unicode.Gcb = .control,
    regional_odd: bool = false,
    emoji: enum { none, base, joined } = .none,
    indic: enum { none, base, linked } = .none,

    pub fn push(self: *Grapheme, properties: unicode.Properties) bool {
        const current = properties.gcb;
        const attached = if (self.previous == .cr and current == .lf)
            true
        else if (isControl(self.previous) or isControl(current))
            false
        else
            self.previous == .prepend or
                (self.indic == .linked and properties.incb == .consonant) or
                (self.previous == .zwj and self.emoji == .joined and properties.pictographic) or
                (self.previous == .regional_indicator and current == .regional_indicator and self.regional_odd) or
                switch (current) {
                    .extend, .zwj, .spacing_mark => true,
                    .l => self.previous == .l,
                    .v, .lv => self.previous == .l or (current == .v and (self.previous == .lv or self.previous == .v)),
                    .lvt => self.previous == .l,
                    .t => self.previous == .lv or self.previous == .v or self.previous == .lvt or self.previous == .t,
                    else => false,
                };
        if (!attached) self.* = .{};
        self.regional_odd = current == .regional_indicator and !self.regional_odd;
        if (properties.pictographic) {
            self.emoji = .base;
        } else switch (current) {
            .extend => {},
            .zwj => self.emoji = if (self.emoji == .base) .joined else .none,
            else => self.emoji = .none,
        }
        switch (properties.incb) {
            .consonant => self.indic = .base,
            .extend => {},
            .linker => if (self.indic != .none) {
                self.indic = .linked;
            },
            .none => self.indic = .none,
        }
        self.previous = current;
        return !attached;
    }
};

pub const Iterator = struct {
    bytes: []const u8,
    offset: usize = 0,
    wide_ambiguous: bool,
    multiline: bool = false,

    pub fn checkedNext(self: *Iterator) Error!?Cluster {
        return self.scan(false);
    }

    pub fn next(self: *Iterator) ?Cluster {
        return self.scan(true) catch unreachable;
    }

    fn scan(self: *Iterator, comptime validated: bool) Error!?Cluster {
        if (self.offset == self.bytes.len) return null;
        const start = self.offset;
        if (self.multiline and self.bytes[start] == '\n') {
            self.offset += 1;
            return .{ .bytes = self.bytes[start..self.offset], .width = 0 };
        }
        if (self.bytes[start] >= 0x20 and self.bytes[start] <= 0x7e and
            (start + 1 == self.bytes.len or self.bytes[start + 1] < 0x80))
        {
            self.offset += 1;
            return .{ .bytes = self.bytes[start..self.offset], .width = 1 };
        }
        var grapheme: Grapheme = .{};
        var width: u2 = 0;
        var pictographic = false;
        var emoji_presentation = false;
        var text_selector = false;
        var emoji_selector = false;
        var joined = false;
        var isolate = false;
        while (self.offset < self.bytes.len) {
            const tail = self.bytes[self.offset..];
            const length = std.unicode.utf8ByteSequenceLength(tail[0]) catch
                if (validated) unreachable else return error.InvalidUtf8;
            if (!validated and length > tail.len) return error.InvalidUtf8;
            const cp = @call(.always_inline, std.unicode.utf8Decode, .{tail[0..length]}) catch
                if (validated) unreachable else return error.InvalidUtf8;
            const properties = unicode.properties(cp);
            const current = properties.gcb;
            const previous = grapheme;
            if (grapheme.push(properties) and self.offset > start) {
                grapheme = previous;
                break;
            }
            if (self.offset == start)
                isolate = current == .extend or current == .zwj or current == .spacing_mark;
            if (!validated and isControl(current)) return error.ControlCharacter;
            if (!validated and self.offset - start + length > max_cluster_bytes) return error.GraphemeTooLong;
            if (current != .extend and current != .zwj) {
                const wide = properties.wide or (self.wide_ambiguous and properties.ambiguous);
                width = @max(width, if (wide) @as(u2, 2) else 1);
            }
            pictographic = pictographic or properties.pictographic;
            emoji_presentation = emoji_presentation or properties.emoji;
            text_selector = text_selector or cp == 0xfe0e;
            emoji_selector = emoji_selector or cp == 0xfe0f;
            joined = joined or current == .zwj;
            self.offset += length;
        }
        if ((emoji_selector and width != 0) or (pictographic and joined) or
            (emoji_presentation and !text_selector)) width = 2;
        if (!validated and width == 0) return error.ZeroWidthGrapheme;
        isolate = isolate or grapheme.indic == .linked or
            (grapheme.previous == .zwj and grapheme.emoji == .joined) or
            (grapheme.previous == .regional_indicator and grapheme.regional_odd) or
            switch (grapheme.previous) {
                .prepend, .l, .v, .t, .lv, .lvt => true,
                else => false,
            };
        return .{ .bytes = self.bytes[start..self.offset], .width = width, .isolate = isolate };
    }
};

pub const Position = struct { row: usize = 0, column: usize = 0 };

/// Immutable borrowed text. LF is a line break in multiline text.
pub const Text = struct {
    bytes: []const u8,
    wide_ambiguous: bool,
    multiline: bool,

    pub const Options = struct { wide_ambiguous: bool = false, multiline: bool = false };

    pub fn init(bytes: []const u8, options: Options) Error!Text {
        const text: Text = .{ .bytes = bytes, .wide_ambiguous = options.wide_ambiguous, .multiline = options.multiline };
        var it = text.clusters();
        while (try it.checkedNext() != null) {}
        return text;
    }

    pub fn clusters(self: Text) Iterator {
        return .{ .bytes = self.bytes, .wide_ambiguous = self.wide_ambiguous, .multiline = self.multiline };
    }

    pub fn words(self: Text) @import("word.zig").Words {
        return .{ .bytes = self.bytes };
    }

    /// Boundary at or after a clamped byte offset.
    pub fn ceilBoundary(self: Text, offset: usize) usize {
        var it = self.clusters();
        while (it.offset < @min(offset, self.bytes.len)) _ = it.next();
        return it.offset;
    }

    pub fn position(self: Text, offset: usize) Position {
        var pos: Position = .{};
        var it = self.clusters();
        while (it.offset < @min(offset, self.bytes.len)) {
            const g = it.next().?;
            if (it.offset > offset) break;
            if (g.width == 0) {
                pos.row += 1;
                pos.column = 0;
            } else pos.column += g.width;
        }
        return pos;
    }

    pub fn byteOffset(self: Text, pos: Position) usize {
        var it = self.clusters();
        var row: usize = 0;
        var column: usize = 0;
        while (it.next()) |g| {
            if (row == pos.row and (g.width == 0 or column + g.width > pos.column))
                return it.offset - g.bytes.len;
            if (g.width == 0) {
                row += 1;
                column = 0;
            } else column += g.width;
        }
        return it.offset;
    }

    pub fn measure(self: Text) struct { columns: usize, lines: usize } {
        var columns: usize = 0;
        var current: usize = 0;
        var lines: usize = 1;
        var it = self.clusters();
        while (it.next()) |g| {
            if (g.width == 0) {
                lines += 1;
                columns = @max(columns, current);
                current = 0;
            } else current += g.width;
        }
        return .{ .columns = @max(columns, current), .lines = lines };
    }

    pub const Rows = struct {
        it: Iterator,
        columns: usize,
        done: bool = false,
        breaks: ?lb.Iterator = null,
        boundary: ?lb.Boundary = null,

        /// A grapheme wider than an empty row occupies a row alone.
        pub fn next(self: *Rows) ?Text {
            if (self.done) return null;
            const start = self.it.offset;
            var cells: usize = 0;
            var last_break = start;
            while (self.it.next()) |g| {
                const head = self.it.offset - g.bytes.len;
                if (g.width == 0) return self.line(start, head);
                if (self.breaks) |*opportunities| {
                    while (self.boundary == null or self.boundary.?.offset < head) {
                        self.boundary = opportunities.next().?;
                    }
                    if (self.boundary.?.offset == head and self.boundary.?.kind != .prohibited) last_break = head;
                }
                if (head != start and g.width > self.columns -| cells) {
                    self.it.offset = if (last_break > start) last_break else head;
                    return self.line(start, self.it.offset);
                }
                cells += g.width;
            }
            self.done = true;
            return self.line(start, self.it.offset);
        }
        fn line(self: *const Rows, start: usize, end: usize) Text {
            return .{ .bytes = self.it.bytes[start..end], .wide_ambiguous = self.it.wide_ambiguous, .multiline = false };
        }
    };

    pub const Wrap = enum { grapheme, word };
    pub fn rows(self: Text, columns: usize, mode: Wrap) Rows {
        return .{ .it = self.clusters(), .columns = columns, .breaks = if (mode == .word) self.lineBreaks() else null };
    }
    pub fn lineBreaks(self: Text) lb.Iterator {
        return .{ .input = self.bytes };
    }

    pub const Hit = struct {
        offset: usize,
        affinity: enum { upstream, downstream } = .downstream,
    };

    pub const Row = struct { start: usize, end: usize };
    pub const RowIndex = struct {
        text: Text,
        entries: []const Row,

        pub fn line(self: RowIndex, row: usize) Text {
            const r = self.entries[row];
            return .{ .bytes = self.text.bytes[r.start..r.end], .multiline = false, .wide_ambiguous = self.text.wide_ambiguous };
        }

        pub fn position(self: RowIndex, caret: Hit) Position {
            var lo: usize = 0;
            var hi = self.entries.len;
            while (lo + 1 < hi) {
                const mid = lo + (hi - lo) / 2;
                if (self.entries[mid].start <= caret.offset) lo = mid else hi = mid;
            }
            if (lo != 0 and caret.affinity == .upstream and self.entries[lo - 1].end == caret.offset) lo -= 1;
            return .{ .row = lo, .column = self.line(lo).position(caret.offset - self.entries[lo].start).column };
        }

        pub fn hit(self: RowIndex, pos: Position) Hit {
            const row = @min(pos.row, self.entries.len - 1);
            const offset = self.entries[row].start + self.line(row).byteOffset(.{ .column = pos.column });
            return .{ .offset = offset, .affinity = if (row + 1 < self.entries.len and self.entries[row + 1].start == offset) .upstream else .downstream };
        }
    };

    /// Borrows immutable text and caller storage until either changes.
    pub fn indexRows(self: Text, columns: usize, mode: Wrap, storage: []Row) !RowIndex {
        var it = self.rows(columns, mode);
        var count: usize = 0;
        while (!it.done) {
            if (count == storage.len) return error.RowCapacity;
            const start = it.it.offset;
            storage[count] = .{ .start = start, .end = start + it.next().?.bytes.len };
            count += 1;
        }
        return .{ .text = self, .entries = storage[0..count] };
    }

    pub fn visualPosition(self: Text, columns: usize, mode: Wrap, hit: Hit) Position {
        var lines = self.rows(columns, mode);
        var row: usize = 0;
        while (true) : (row += 1) {
            const start = lines.it.offset;
            const line = lines.next().?;
            const end = start + line.bytes.len;
            if (hit.offset < end or lines.done or (hit.offset == end and
                (hit.affinity == .upstream or lines.it.offset > end)))
            {
                return .{ .row = row, .column = line.position(hit.offset -| start).column };
            }
        }
    }

    pub fn visualHit(self: Text, columns: usize, mode: Wrap, pos: Position) Hit {
        var lines = self.rows(columns, mode);
        var row: usize = 0;
        while (true) : (row += 1) {
            const start = lines.it.offset;
            const line = lines.next().?;
            if (row == pos.row or lines.done) {
                const local = line.byteOffset(.{ .column = pos.column });
                return .{ .offset = start + local, .affinity = if (local == line.bytes.len and !lines.done and lines.it.offset == start + local) .upstream else .downstream };
            }
        }
    }

    /// Longest complete first-line prefix fitting the cell budget.
    pub fn prefix(self: Text, cells: usize) []const u8 {
        return self.bytes[0..self.byteOffset(.{ .column = cells })];
    }

    pub fn truncated(self: Text, cells: usize, marker: Text) struct { body: []const u8, suffix: []const u8 } {
        const prefix_bytes = self.prefix(cells);
        if (prefix_bytes.len == self.bytes.len or self.bytes[prefix_bytes.len] == '\n')
            return .{ .body = prefix_bytes, .suffix = "" };
        const suffix = marker.prefix(cells);
        const width = marker.position(suffix.len).column;
        return .{ .body = self.prefix(cells - width), .suffix = suffix };
    }

    pub const Clip = struct { indent: usize, line: Text };

    /// Clip a logical row, leaving a blank at a split wide left edge.
    pub fn clip(self: Text, pos: Position, cells: usize) Clip {
        var it = self.clusters();
        var row: usize = 0;
        while (row < pos.row) : (row += 1) {
            const lf = std.mem.indexOfScalar(u8, self.bytes[it.offset..], '\n') orelse {
                it.offset = self.bytes.len;
                break;
            };
            it.offset += lf + 1;
        }
        var column: usize = 0;
        while (column < pos.column and it.offset < self.bytes.len and self.bytes[it.offset] != '\n') {
            column += it.next().?.width;
        }
        const indent = @min(cells, column -| pos.column);
        const tail: Text = .{ .bytes = self.bytes[it.offset..], .wide_ambiguous = self.wide_ambiguous, .multiline = self.multiline };
        return .{ .indent = indent, .line = .{ .bytes = tail.prefix(cells - indent), .wide_ambiguous = self.wide_ambiguous, .multiline = false } };
    }
};

test "row indexes and streaming hits resolve to the same grapheme boundaries" {
    const t = try Text.init("say can't 一二\ne\u{301}\n", .{ .multiline = true });
    var buf: [32]Text.Row = undefined;
    for ([_]Text.Wrap{ .grapheme, .word }) |mode| {
        const index = try t.indexRows(4, mode, &buf);
        for (0..index.entries.len + 1) |row| for (0..7) |column| {
            const p: Position = .{ .row = row, .column = column };
            const hit = index.hit(p);
            try std.testing.expectEqual(hit.offset, t.ceilBoundary(hit.offset));
            try std.testing.expectEqual(t.visualHit(4, mode, p), hit);
            try std.testing.expectEqual(t.visualPosition(4, mode, hit), index.position(hit));
        };
    }
}

fn isControl(property: unicode.Gcb) bool {
    return property == .cr or property == .lf or property == .control;
}

test "Unicode 17 grapheme boundaries and drawable iterator agree with the official corpus" {
    const corpus = @embedFile("grapheme_cases");
    var lines = std.mem.splitScalar(u8, corpus, '\n');
    var cases: usize = 0;
    var line_number: usize = 0;
    while (lines.next()) |line| {
        line_number += 1;
        var tokens = std.mem.tokenizeAny(u8, line[0 .. std.mem.indexOfScalar(u8, line, '#') orelse line.len], " \t\r");
        var grapheme: Grapheme = .{};
        var boundary = true;
        var bytes: [1024]u8 = undefined;
        var ends: [128]usize = undefined;
        var len: usize = 0;
        var count: usize = 0;
        while (tokens.next()) |token| {
            if (std.mem.eql(u8, token, "÷") or std.mem.eql(u8, token, "×")) {
                boundary = std.mem.eql(u8, token, "÷");
                if (boundary and len > 0) {
                    ends[count] = len;
                    count += 1;
                }
                continue;
            }
            const cp = try std.fmt.parseInt(u21, token, 16);
            const actual = grapheme.push(unicode.properties(cp));
            if (actual != boundary) std.debug.print("GraphemeBreakTest line {d}, U+{X}\n", .{ line_number, cp });
            try std.testing.expectEqual(boundary, actual);
            len += try std.unicode.utf8Encode(cp, bytes[len..][0..4]);
        }
        if (len == 0) continue;
        cases += 1;
        var iterator: Iterator = .{ .bytes = bytes[0..len], .wide_ambiguous = false };
        var start: usize = 0;
        for (ends[0..count]) |end| {
            const cluster = iterator.checkedNext() catch |err| switch (err) {
                error.ControlCharacter, error.ZeroWidthGrapheme, error.GraphemeTooLong => {
                    iterator.offset = end;
                    start = end;
                    continue;
                },
                else => return err,
            };
            try std.testing.expectEqualSlices(u8, bytes[start..end], cluster.?.bytes);
            start = end;
        }
        try std.testing.expectEqual(null, try iterator.checkedNext());
    }
    try std.testing.expectEqual(@as(usize, 766), cases);
}

test "terminal width policy covers selectors, emoji, ambiguous text, and drawing limits" {
    const Case = struct { bytes: []const u8, narrow: u2, wide: u2 };
    const cases = [_]Case{
        .{ .bytes = "a", .narrow = 1, .wide = 1 },
        .{ .bytes = "e\u{301}", .narrow = 1, .wide = 1 },
        .{ .bytes = "界", .narrow = 2, .wide = 2 },
        .{ .bytes = "·", .narrow = 1, .wide = 2 },
        .{ .bytes = "©", .narrow = 1, .wide = 1 },
        .{ .bytes = "©\u{fe0f}", .narrow = 2, .wide = 2 },
        .{ .bytes = "©\u{fe0e}", .narrow = 1, .wide = 1 },
        .{ .bytes = "👩‍💻", .narrow = 2, .wide = 2 },
        .{ .bytes = "🇮🇳", .narrow = 2, .wide = 2 },
        .{ .bytes = "1\u{fe0f}\u{20e3}", .narrow = 2, .wide = 2 },
        .{ .bytes = "\u{1100}\u{1161}\u{11a8}", .narrow = 2, .wide = 2 },
    };
    for (cases) |case| {
        for ([_]bool{ false, true }) |wide| {
            var iterator = (try Text.init(case.bytes, .{ .wide_ambiguous = wide })).clusters();
            const cluster = iterator.next().?;
            try std.testing.expectEqualSlices(u8, case.bytes, cluster.bytes);
            try std.testing.expectEqual(if (wide) case.wide else case.narrow, cluster.width);
            try std.testing.expectEqual(null, iterator.next());
        }
    }
    try std.testing.expectError(error.InvalidUtf8, Text.init("\xc0\x80", .{}));
    try std.testing.expectError(error.InvalidUtf8, Text.init("a\xf0\x9f", .{}));
    try std.testing.expectError(error.ControlCharacter, Text.init("\r\n", .{}));
    try std.testing.expectError(error.ZeroWidthGrapheme, Text.init("\u{301}", .{}));
    const marks: [24][2]u8 = @splat("\xcc\x81".*);
    var bytes: [50]u8 = undefined;
    @memcpy(bytes[0..2], "é");
    @memcpy(bytes[2..], std.mem.asBytes(&marks));
    _ = try Text.init(bytes[0..48], .{});
    try std.testing.expectError(error.GraphemeTooLong, Text.init(&bytes, .{}));
}
