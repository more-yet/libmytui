const std = @import("std");
const tui = @import("mytui");

pub fn main(init: std.process.Init) !void {
    var counter: Counter = .{ .label = try .init(init.gpa, .{ .capacity = 1024, .history = 8, .multiline = true }) };
    defer counter.label.deinit();
    defer if (counter.paste) |*p| p.cancel();
    try counter.label.replace("Counter");
    try tui.run(init, &counter, .{ .protocols = .{ .mouse = true, .kitty_keyboard = true, .synchronized_output = true }, .streamed_paste = true, .paste_bytes = 256 });
}

const Counter = struct {
    value: i64 = 0,
    label: tui.Editor,
    editing: bool = false,
    view: tui.WrappedView = .{ .columns = 1, .wrap = .word },
    field: tui.Rect = .{ .x = 2, .y = 1, .width = 0, .height = 0 },
    paste_bytes: [1024]u8 = undefined,
    paste: ?tui.Paste = null,

    pub fn update(self: *Counter, event: tui.Event) !tui.Action {
        switch (event) {
            .key => |key| {
                if (key.action == .release) return .none;
                if (key.alt or key.super or key.hyper or key.meta) return .none;
                if (key.control and !key.shift and key.action == .press and key.code == .character) switch (key.code.character) {
                    'c' => return .quit,
                    'z' => if (!self.editing) return .@"suspend",
                    else => {},
                };
                if (key.code == .tab) {
                    if (key.control or key.shift or key.action != .press) return .none;
                    self.editing = !self.editing;
                    return .redraw;
                }
                if (self.editing) {
                    switch (key.code) {
                        .character => |cp| {
                            if (key.control) {
                                if (key.shift) return .none;
                                switch (cp) {
                                    'z' => _ = self.label.undo(),
                                    'y' => _ = self.label.redo(),
                                    else => return .none,
                                }
                            } else {
                                var encoded: [4]u8 = undefined;
                                const n = try std.unicode.utf8Encode(cp, &encoded);
                                self.label.replace(if (key.text.len != 0) key.text else encoded[0..n]) catch return .none;
                            }
                        },
                        .backspace, .delete => {
                            const dir: tui.Editor.Direction = if (key.code == .backspace) .backward else .forward;
                            if (key.control) self.label.deleteWord(dir) catch return .none else self.label.delete(dir) catch return .none;
                        },
                        .left, .right => {
                            const dir: tui.Editor.Direction = if (key.code == .left) .backward else .forward;
                            if (key.control) self.label.moveWord(dir, key.shift) else self.label.move(dir, key.shift);
                        },
                        inline .up, .down, .home, .end, .page_up, .page_down => |_, tag| {
                            self.view.move(&self.label, @field(tui.WrappedView.Command, @tagName(tag)), self.field.height, key.shift);
                            return .redraw;
                        },
                        .enter => self.label.replace("\n") catch return .none,
                        .escape => self.editing = false,
                        else => return .none,
                    }
                    self.view.resetCaret();
                    return .redraw;
                }
                if (key.is('q')) return .quit;
                if (key.is('+') or key.is('=')) {
                    self.value +|= 1;
                    return .redraw;
                }
                if (key.is('-')) {
                    self.value -|= 1;
                    return .redraw;
                }
            },
            .paste_start => {
                if (!self.editing) return .cancel_paste;
                self.paste = .{ .storage = &self.paste_bytes };
                return .none;
            },
            .paste_chunk => |bytes| {
                self.paste.?.append(bytes) catch return .cancel_paste;
                return .none;
            },
            .paste_end => |end| {
                if (self.paste) |*p| {
                    defer {
                        p.cancel();
                        self.paste = null;
                    }
                    if (end.status != .complete) return .none;
                    p.append(end.tail) catch return .none;
                    p.commit(&self.label) catch return .none;
                    self.view.resetCaret();
                    return .redraw;
                }
            },
            .mouse => |m| if (m.button == .left and (m.action == .press or m.action == .drag) and self.field.contains(m.x, m.y)) {
                self.editing = true;
                self.view.place(&self.label, .{ .row = self.view.viewport.offset + m.y - self.field.y, .column = m.x - self.field.x }, m.shift or m.action == .drag);
                return .redraw;
            },
            else => {},
        }
        return .none;
    }

    pub fn draw(self: *Counter, frame: *tui.Frame) !void {
        var field = frame.region(.{ .x = 2, .y = 1, .width = frame.size().width, .height = 3 });
        self.field = field.bounds;
        const columns = @max(1, self.field.width -| 1);
        if (self.view.columns != columns) self.view.resetCaret();
        self.view.columns = columns;
        if (self.editing) self.view.reveal(&self.label, self.field.height) else self.view.viewport.offset = 0;
        var lines = self.view.visibleRows(&self.label);
        for (0..self.field.height) |y| {
            try field.line(0, @intCast(y), lines.next() orelse break, .{ .bold = true, .foreground = .{ .indexed = 6 } });
        }
        if (self.editing and self.field.height != 0) {
            const pos = self.view.position(&self.label);
            field.setCaret(.{ .x = @intCast(pos.column), .y = @intCast(pos.row - self.view.viewport.offset), .shape = .bar });
        }
        try frame.print(2, 4, "Value: {d}", .{self.value}, .{});
        try frame.text(2, 5, if (self.editing) "Tab finish   Ctrl-Z undo   Ctrl-Y redo" else "+ / - change   Tab edit label   q quit   Ctrl-Z suspend", .{ .dim = true });
        try frame.text(2, 7, "Unicode: 界  e\u{301}  👩‍💻", .{});
    }
};
