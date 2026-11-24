const std = @import("std");
const text_module = @import("text.zig");
const Text = text_module.Text;

pub const Editor = struct {
    allocator: ?std.mem.Allocator = null,
    storage: []u8,
    records: []Record,
    live: []u8,
    len: usize = 0,
    selected: Selection = .{},
    journal: []u8,
    transaction_limit: u16,
    applied_transactions: usize = 0,
    stage: []u8,
    multiline: bool,
    wide_ambiguous: bool,
    index: usize = 0,
    last: usize = 0,
    group_depth: usize = 0,
    group_written: bool = false,

    pub const Selection = struct { anchor: usize = 0, cursor: usize = 0 };
    pub const Record = struct { start: usize, payload: usize, removed: usize, inserted: usize, before: Selection, cursor: usize, first: bool };
    pub const Options = struct {
        capacity: u32,
        history: u16 = 0,
        history_records: ?u32 = null,
        history_bytes: ?u32 = null,
        multiline: bool = false,
        wide_ambiguous: bool = false,
    };

    pub fn storageBytes(options: Options) !usize {
        const docs = try std.math.mul(usize, options.capacity, 2);
        return std.math.add(usize, docs, if (options.history == 0) 0 else if (options.history_bytes) |n| n else docs);
    }
    pub fn recordCount(options: Options) usize {
        return if (options.history == 0) 0 else options.history_records orelse @as(u32, options.history) * 4;
    }

    pub fn init(allocator: std.mem.Allocator, options: Options) !Editor {
        const storage = try allocator.alloc(u8, try storageBytes(options));
        errdefer allocator.free(storage);
        const slots = try allocator.alloc(Record, recordCount(options));
        return fromStorage(allocator, storage, slots, options);
    }

    pub fn initStorage(bytes: []u8, history: []Record, options: Options) !Editor {
        const count = recordCount(options);
        const need = try storageBytes(options);
        if (history.len < count or bytes.len < need) return error.EditorCapacity;
        return fromStorage(null, bytes[0..need], history[0..count], options);
    }

    fn fromStorage(allocator: ?std.mem.Allocator, storage: []u8, records: []Record, options: Options) Editor {
        const n: usize = options.capacity;
        return .{ .allocator = allocator, .storage = storage, .records = records, .live = storage[0..n], .stage = storage[n..][0..n], .journal = storage[n * 2 ..], .transaction_limit = options.history, .multiline = options.multiline, .wide_ambiguous = options.wide_ambiguous };
    }

    pub fn clear(self: *Editor) void {
        std.crypto.secureZero(u8, self.storage);
        std.crypto.secureZero(u8, std.mem.sliceAsBytes(self.records));
        self.len = 0;
        self.selected = .{};
        self.applied_transactions = 0;
        self.index = 0;
        self.last = 0;
        self.group_depth = 0;
        self.group_written = false;
    }

    pub fn deinit(self: *Editor) void {
        self.clear();
        if (self.allocator) |a| {
            a.free(self.storage);
            a.free(self.records);
        }
        self.* = undefined;
    }

    pub fn text(self: *const Editor) Text {
        return .{ .bytes = self.live[0..self.len], .multiline = self.multiline, .wide_ambiguous = self.wide_ambiguous };
    }

    pub fn selection(self: *const Editor) Selection {
        return self.selected;
    }
    pub fn selectedText(self: *const Editor) []const u8 {
        const s = self.selection();
        return self.text().bytes[@min(s.anchor, s.cursor)..@max(s.anchor, s.cursor)];
    }
    pub fn canUndo(self: *const Editor) bool {
        return self.group_depth == 0 and self.index != 0;
    }
    pub fn canRedo(self: *const Editor) bool {
        return self.group_depth == 0 and self.index != self.last;
    }

    pub fn select(self: *Editor, anchor: usize, cursor: usize) !void {
        const t = self.text();
        if (t.ceilBoundary(anchor) != anchor or t.ceilBoundary(cursor) != cursor) return error.InvalidBoundary;
        self.selected = .{ .anchor = anchor, .cursor = cursor };
    }

    pub const Direction = enum { backward, forward };

    fn adjacent(self: *const Editor, direction: Direction) usize {
        const cursor = self.selection().cursor;
        const t = self.text();
        var it = t.clusters();
        if (direction == .forward) {
            it.offset = cursor;
            _ = it.next();
            return it.offset;
        }
        while (it.offset < cursor) {
            const head = it.offset;
            _ = it.next();
            if (it.offset == cursor) return head;
        }
        return 0;
    }

    pub fn move(self: *Editor, direction: Direction, extend: bool) void {
        const pos = self.adjacent(direction);
        const s = &self.selected;
        s.cursor = pos;
        if (!extend) s.anchor = pos;
    }

    fn wordEdge(self: *const Editor, direction: Direction) usize {
        const cursor = self.selection().cursor;
        const t = self.text();
        var words = t.words();
        var gs = t.clusters();
        var previous: usize = 0;
        while (words.next() != null) {
            while (gs.offset < words.offset) _ = gs.next();
            if (gs.offset != words.offset) continue;
            if (direction == .backward and words.offset >= cursor) return previous;
            if (words.offset > cursor) return words.offset;
            previous = words.offset;
        }
        return previous;
    }

    pub fn moveWord(self: *Editor, direction: Direction, extend: bool) void {
        const s = &self.selected;
        s.cursor = self.wordEdge(direction);
        if (!extend) s.anchor = s.cursor;
    }

    pub fn deleteWord(self: *Editor, direction: Direction) !void {
        const s = self.selection();
        const other = if (s.cursor == s.anchor) self.wordEdge(direction) else s.anchor;
        try self.edit(@min(s.cursor, other), @max(s.cursor, other), "");
    }

    pub fn delete(self: *Editor, direction: Direction) !void {
        const s = self.selection();
        const other = if (s.cursor == s.anchor) self.adjacent(direction) else s.anchor;
        try self.edit(@min(s.cursor, other), @max(s.cursor, other), "");
    }

    pub fn replace(self: *Editor, bytes: []const u8) !void {
        const s = self.selection();
        try self.edit(@min(s.anchor, s.cursor), @max(s.anchor, s.cursor), bytes);
    }

    fn edit(self: *Editor, start: usize, end: usize, bytes: []const u8) !void {
        if (start == end and bytes.len == 0) return;
        const old = self.text().bytes;
        @memcpy(self.stage[0..start], old[0..start]);
        const limit = self.stage.len - (old.len - end);
        var pos = start;
        var i: usize = 0;
        while (i < bytes.len) : (i += 1) {
            if (pos == limit) return error.EditorCapacity;
            var b = bytes[i];
            if (b == '\r') {
                if (i + 1 < bytes.len and bytes[i + 1] == '\n') i += 1;
                b = '\n';
            }
            self.stage[pos] = b;
            pos += 1;
        }
        const len = pos + (old.len - end);
        @memcpy(self.stage[pos..len], old[end..]);
        // A join can change every subsequent RI pair, but never crosses LF.
        const first = if (std.mem.lastIndexOfScalar(u8, old[0..start], '\n')) |lf| lf + 1 else 0;
        const limit_end = pos + (std.mem.indexOfScalar(u8, old[end..], '\n') orelse (old.len - end));
        var scan: text_module.Iterator = .{ .bytes = self.stage[0..limit_end], .offset = first, .wide_ambiguous = self.wide_ambiguous, .multiline = self.multiline };
        var cursor = pos;
        while (try scan.checkedNext()) |g| {
            if (scan.offset - g.bytes.len < pos and scan.offset >= pos) cursor = scan.offset;
        }
        if (self.transaction_limit != 0) try self.recordEdit(start, old[start..end], self.stage[start..pos], cursor);
        std.mem.swap([]u8, &self.live, &self.stage);
        self.len = len;
        self.selected = .{ .cursor = cursor, .anchor = cursor };
    }

    fn recordEdit(self: *Editor, start: usize, removed: []const u8, inserted: []const u8, cursor: usize) !void {
        const fresh = self.group_depth == 0 or !self.group_written;
        const need = removed.len + inserted.len;
        if (need > self.journal.len or self.records.len == 0) return error.HistoryCapacity;
        const used = if (self.index == 0) 0 else blk: {
            const r = self.records[self.index - 1];
            break :blk r.payload + r.removed + r.inserted;
        };
        var drop: usize = 0;
        var skip: usize = 0;
        var groups = self.applied_transactions + @intFromBool(fresh);
        while (self.index - drop >= self.records.len or used - skip > self.journal.len - need or groups > self.transaction_limit) {
            if (!fresh and groups == 1) return error.HistoryCapacity;
            while (true) {
                const r = self.records[drop];
                skip = r.payload + r.removed + r.inserted;
                drop += 1;
                if (drop == self.index or self.records[drop].first) break;
            }
            groups -= 1;
        }
        if (drop != 0) {
            @memmove(self.records[0 .. self.index - drop], self.records[drop..self.index]);
            self.index -= drop;
            for (self.records[0..self.index]) |*r| r.payload -= skip;
            @memmove(self.journal[0 .. used - skip], self.journal[skip..used]);
        }
        const at = used - skip;
        @memcpy(self.journal[at..][0..removed.len], removed);
        @memcpy(self.journal[at + removed.len ..][0..inserted.len], inserted);
        self.records[self.index] = .{ .start = start, .payload = at, .removed = removed.len, .inserted = inserted.len, .before = self.selected, .cursor = cursor, .first = fresh };
        self.index += 1;
        self.last = self.index;
        self.applied_transactions = groups;
        self.group_written = self.group_depth != 0;
    }

    pub fn beginGroup(self: *Editor) void {
        if (self.group_depth == 0) self.group_written = false;
        self.group_depth += 1;
    }

    pub fn endGroup(self: *Editor) void {
        std.debug.assert(self.group_depth != 0);
        self.group_depth -= 1;
    }

    pub fn undo(self: *Editor) bool {
        std.debug.assert(self.group_depth == 0);
        if (self.index == 0) return false;
        while (true) {
            self.index -= 1;
            self.replay(self.records[self.index], false);
            if (self.records[self.index].first) break;
        }
        self.applied_transactions -= 1;
        return true;
    }

    pub fn redo(self: *Editor) bool {
        std.debug.assert(self.group_depth == 0);
        if (self.index == self.last) return false;
        while (true) {
            self.replay(self.records[self.index], true);
            self.index += 1;
            if (self.index == self.last or self.records[self.index].first) break;
        }
        self.applied_transactions += 1;
        return true;
    }

    fn replay(self: *Editor, r: Record, forward: bool) void {
        const drop = if (forward) r.removed else r.inserted;
        const put = if (forward) r.inserted else r.removed;
        const at = r.payload + if (forward) r.removed else 0;
        const tail = self.live[r.start + drop .. self.len];
        @memmove(self.live[r.start + put ..][0..tail.len], tail);
        @memcpy(self.live[r.start..][0..put], self.journal[at..][0..put]);
        self.len = self.len - drop + put;
        self.selected = if (forward) .{ .cursor = r.cursor, .anchor = r.cursor } else r.before;
    }
};

/// Stages bytes independently of the editor. Only commit edits the then-current selection.
pub const Paste = struct {
    storage: []u8,
    used: usize = 0,
    active: bool = true,

    pub fn append(self: *Paste, bytes: []const u8) !void {
        if (!self.active) return error.PasteClosed;
        if (bytes.len > self.storage.len - self.used) {
            self.cancel();
            return error.PasteCapacity;
        }
        @memcpy(self.storage[self.used..][0..bytes.len], bytes);
        self.used += bytes.len;
    }
    pub fn cancel(self: *Paste) void {
        std.crypto.secureZero(u8, self.storage[0..self.used]);
        self.used = 0;
        self.active = false;
    }
    pub fn commit(self: *Paste, editor: *Editor) !void {
        if (!self.active) return error.PasteClosed;
        defer self.cancel();
        try editor.replace(self.storage[0..self.used]);
    }
};

pub const WrappedView = struct {
    columns: usize,
    wrap: Text.Wrap = .grapheme,
    viewport: @import("navigation.zig").Viewport = .{},
    affinity: @FieldType(Text.Hit, "affinity") = .downstream,
    preferred_column: ?usize = null,

    pub fn resetCaret(self: *WrappedView) void {
        self.affinity = .downstream;
        self.preferred_column = null;
    }

    pub fn position(self: WrappedView, editor: *const Editor) text_module.Position {
        return editor.text().visualPosition(self.columns, self.wrap, .{ .offset = editor.selection().cursor, .affinity = self.affinity });
    }

    pub fn place(self: *WrappedView, editor: *Editor, pos: text_module.Position, extend: bool) void {
        const hit = editor.text().visualHit(self.columns, self.wrap, pos);
        const s = &editor.selected;
        s.cursor = hit.offset;
        if (!extend) s.anchor = s.cursor;
        self.affinity = hit.affinity;
        self.preferred_column = null;
    }

    pub const Command = enum { up, down, home, end, page_up, page_down };
    pub fn move(self: *WrappedView, editor: *Editor, command: Command, height: usize, extend: bool) void {
        var pos = self.position(editor);
        const goal = self.preferred_column orelse pos.column;
        pos.column = goal;
        switch (command) {
            .home => pos.column = 0,
            .end => pos.column = std.math.maxInt(usize),
            .up => pos.row -|= 1,
            .down => pos.row +|= 1,
            .page_up => pos.row -|= height,
            .page_down => pos.row +|= height,
        }
        self.place(editor, pos, extend);
        if (command != .home and command != .end) self.preferred_column = goal;
    }

    pub fn reveal(self: *WrappedView, editor: *const Editor, height: usize) void {
        const t = editor.text();
        const last = t.visualPosition(self.columns, self.wrap, .{ .offset = t.bytes.len });
        self.viewport.reveal(self.position(editor).row, last.row + 1, height);
    }

    /// Starts at the first visible row. The caller draws at most its viewport height.
    pub fn visibleRows(self: WrappedView, editor: *const Editor) Text.Rows {
        var rows = editor.text().rows(self.columns, self.wrap);
        for (0..self.viewport.offset) |_| {
            if (rows.next() == null) break;
        }
        return rows;
    }
};

test "atomic joining edits, normalized paste, grouped history and eviction" {
    var e = try Editor.init(std.testing.allocator, .{ .capacity = 16, .history = 2, .multiline = true });
    defer e.deinit();
    try e.replace("🇦\r\n🇧");
    try e.select(4, 5);
    try e.delete(.backward);
    try std.testing.expectEqualStrings("🇦🇧", e.text().bytes);
    try std.testing.expectEqual(@as(usize, 8), e.selection().cursor);
    try std.testing.expect(e.undo());
    try std.testing.expectEqualStrings("🇦\n🇧", e.text().bytes);
    try std.testing.expectError(error.InvalidUtf8, e.replace("\xff"));
    try std.testing.expectError(error.EditorCapacity, e.replace("01234567890123456"));
    try std.testing.expectError(error.InvalidBoundary, e.select(1, 1));
    try std.testing.expectEqual(Editor.Selection{ .anchor = 4, .cursor = 5 }, e.selection());
    try std.testing.expect(e.redo());
    e.beginGroup();
    try e.replace("e");
    try e.replace("\u{301}");
    e.endGroup();
    e.move(.backward, true);
    try std.testing.expectEqual(@as(usize, 8), e.selection().cursor);
    try std.testing.expect(e.undo());
    try std.testing.expect(e.undo());
    try std.testing.expect(!e.undo());
    try e.replace("x");
    try std.testing.expect(!e.redo());
    e.clear();
    try std.testing.expect(std.mem.allEqual(u8, e.storage, 0));
}

test "a valid insertion can exceed the cluster bound only at the join" {
    const marks: [23][2]u8 = @splat("\xcc\x81".*);
    var field = try Editor.init(std.testing.allocator, .{ .capacity = 64, .history = 1 });
    defer field.deinit();
    try field.replace("e");
    try field.replace(std.mem.asBytes(&marks));
    try std.testing.expectError(error.GraphemeTooLong, field.replace("\u{301}"));
    try std.testing.expectError(error.ControlCharacter, field.replace("\r\n"));
    try std.testing.expectEqual(@as(usize, 47), field.selection().cursor);
    try std.testing.expectEqualStrings(std.mem.asBytes(&marks), field.text().bytes[1..]);
    try std.testing.expect(field.undo());
    try std.testing.expectEqualStrings("e", field.text().bytes);
    try std.testing.expect(field.redo());
    try std.testing.expectEqual(@as(usize, 47), field.text().bytes.len);
}

test "journal admission never evicts redo or part of the open transaction on failure" {
    var e = try Editor.init(std.testing.allocator, .{ .capacity = 64, .history = 8, .history_bytes = 5, .history_records = 3 });
    defer e.deinit();
    try e.replace("ab");
    e.beginGroup();
    try e.replace("cd");
    try e.replace("e");
    try std.testing.expectError(error.HistoryCapacity, e.replace("fff"));
    e.endGroup();
    try std.testing.expectEqualStrings("abcde", e.text().bytes);
    try std.testing.expect(e.undo());
    try std.testing.expectError(error.HistoryCapacity, e.replace("123456"));
    try std.testing.expect(e.redo());
    try e.replace("xyz");
    try std.testing.expect(e.undo() and !e.undo());
    try std.testing.expectEqualStrings("abcde", e.text().bytes);
}

test "caller storage, nested history and cancelled paste share the edit transaction" {
    var buf: [48]u8 = undefined;
    var history: [2]Editor.Record = undefined;
    var e = try Editor.initStorage(&buf, &history, .{ .capacity = 16, .history = 1, .history_records = 2, .history_bytes = 16, .multiline = true });
    defer e.deinit();
    var stage: [8]u8 = undefined;
    var p: Paste = .{ .storage = &stage };
    e.beginGroup();
    e.beginGroup();
    try p.append("a\r");
    try p.append("\nb");
    try p.commit(&e);
    e.endGroup();
    try e.replace("c");
    e.endGroup();
    p = .{ .storage = &stage };
    try p.append("123");
    try std.testing.expectError(error.PasteCapacity, p.append("456789"));
    try std.testing.expectError(error.PasteClosed, p.commit(&e));
    try std.testing.expectEqualStrings("a\nbc", e.text().bytes);
    try std.testing.expect(e.canUndo() and e.undo() and !e.canUndo() and e.canRedo());
    try std.testing.expectEqualStrings("", e.text().bytes);
}
