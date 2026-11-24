const std = @import("std");
const tui = @import("mytui");
const vt = @import("ghostty-vt");

test "fragmented Unicode frames preserve terminal glyphs, widths, styles, and resize transactions" {
    const allocator = std.testing.allocator;
    var terminal = try vt.Terminal.init(.failing, allocator, .{ .cols = 80, .rows = 24, .max_scrollback_bytes = 0 });
    defer terminal.deinit(allocator);
    var stream = terminal.vtStream();
    defer stream.deinit();
    stream.nextSlice("\x1b[?2027h");
    var renderer = try tui.Renderer.init(allocator, .{ .max_cells = 4800, .cluster_bytes = 32768 });
    defer renderer.deinit();
    const sizes = [_]tui.Size{
        .{ .width = 80, .height = 24 },
        .{ .width = 120, .height = 40 },
        .{ .width = 40, .height = 12 },
        .{ .width = 2, .height = 1 },
    };
    const glyphs = [_][]const u8{ "a", "e\u{301}", "界", "👩‍💻", "🇮🇳", "1\u{fe0f}\u{20e3}", "©\u{fe0f}", "©\u{fe0e}", "·", "x\u{308}\u{301}", "🇮", "🇳" };
    for (sizes, 0..) |size, i| {
        try terminal.resize(allocator, .{ .cols = size.width, .rows = size.height });
        try renderer.resize(size);
        // Each size exercises a repaint, a diff, and an unchanged frame after each.
        for (0..4) |turn| {
            const iteration = i * 4 + turn;
            renderer.synchronized = turn < 2;
            var frame = renderer.begin();
            for (0..size.height) |y| {
                const style: tui.Style = .{
                    .foreground = .{ .rgb = @truncate((y + iteration / 2) * 0x12345) },
                    .background = .{ .indexed = @truncate(y * 7) },
                    .bold = y & 1 != 0,
                    .dim = y & 2 != 0,
                    .italic = y & 4 != 0,
                    .underline = y & 8 != 0,
                    .reverse = y & 16 != 0,
                    .blink = y & 1 != 0,
                    .hidden = y & 2 != 0,
                    .strike = y & 4 != 0,
                    .underline_color = .{ .rgb = 0x334455 },
                };
                for (0..size.width / 2) |x|
                    try frame.text(@intCast(x * 2), @intCast(y), glyphs[(x + y + iteration / 2) % glyphs.len], style);
                try frame.text(size.width - 1, @intCast(y), "e\u{301}", style);
            }
            try frame.text(0, 0, "क्", .{});
            try frame.text(1, 0, "क", .{});
            try frame.text(2, 0, "👩‍", .{});
            try frame.text(4, 0, "💻", .{});
            if (iteration / 2 % 3 != 0) frame.setCaret(.{ .x = size.width - 1, .y = size.height - 1, .shape = .bar });
            const caret = renderer.back.caret;
            renderer.submit();
            var total: usize = 0;
            while (true) switch (renderer.step()) {
                .output => |bytes| {
                    const count = @min(bytes.len, if (iteration % 4 < 2) 1 else 1 + total % 113);
                    stream.nextSlice(bytes[0..count]);
                    try std.testing.expect(!stream.handler.semantic_failure);
                    renderer.consume(count);
                    total += count;
                },
                .yielded, .cleared => {},
                .complete => break,
            };
            try std.testing.expect(stream.ground());
            try std.testing.expect(terminal.modes.get(.grapheme_cluster));
            try std.testing.expect(!terminal.modes.get(.synchronized_output));
            try std.testing.expectEqual(caret != null, terminal.modes.get(.cursor_visible));
            if (caret) |position| {
                try std.testing.expectEqual(position.x, terminal.screens.active.cursor.x);
                try std.testing.expectEqual(position.y, terminal.screens.active.cursor.y);
            }
            if (iteration % 2 == 1) try std.testing.expectEqual(@as(usize, 0), total);
            for (0..size.count()) |index| {
                const x: u16 = @intCast(index % size.width);
                const y: u16 = @intCast(index / size.width);
                var scalar: [4]u8 = undefined;
                const expected = renderer.inspectCommitted(x, y, &scalar).?;
                const actual = terminal.screens.active.pages.getCell(.{ .active = .{ .x = x, .y = y } }).?;
                const width: u2 = switch (actual.cell.wide) {
                    .narrow => 1,
                    .wide => 2,
                    .spacer_tail => 0,
                    .spacer_head => return error.UnexpectedWrap,
                };
                if (width != expected.width)
                    std.debug.print("frame {d}, cell {d}: width {d}, expected {d}\n", .{ iteration, index, width, expected.width });
                try std.testing.expectEqual(expected.width, width);
                if (width == 0) continue;
                var bytes: [48]u8 = undefined;
                var length: usize = try std.unicode.utf8Encode(if (actual.cell.codepoint() == 0) ' ' else actual.cell.codepoint(), bytes[0..4]);
                if (actual.node.page().lookupGrapheme(actual.cell)) |scalars| {
                    for (scalars) |cp| length += try std.unicode.utf8Encode(cp, bytes[length..][0..4]);
                }
                try std.testing.expectEqualStrings(expected.glyph, bytes[0..length]);
                const style = actual.style();
                const wanted_style = expected.style;
                inline for (.{ .{ wanted_style.foreground_kind, wanted_style.foreground, style.fg_color }, .{ wanted_style.background_kind, wanted_style.background, style.bg_color }, .{ wanted_style.underline_kind, wanted_style.underline_color, style.underline_color } }) |color| {
                    const wanted_color: vt.Style.Color = switch (color[0]) {
                        0 => .none,
                        1 => .{ .palette = @intCast(color[1]) },
                        2 => .{ .rgb = .{ .r = @truncate(color[1] >> 16), .g = @truncate(color[1] >> 8), .b = @truncate(color[1]) } },
                        else => unreachable,
                    };
                    try std.testing.expect(color[2].eql(wanted_color));
                }
                try std.testing.expectEqual(wanted_style.bold, style.flags.bold);
                try std.testing.expectEqual(wanted_style.dim, style.flags.faint);
                try std.testing.expectEqual(wanted_style.italic, style.flags.italic);
                try std.testing.expectEqual(wanted_style.underline, style.flags.underline != .none);
                try std.testing.expectEqual(wanted_style.reverse, style.flags.inverse);
                try std.testing.expectEqual(wanted_style.blink, style.flags.blink);
                try std.testing.expectEqual(wanted_style.hidden, style.flags.invisible);
                try std.testing.expectEqual(wanted_style.strike, style.flags.strikethrough);
            }
        }
    }
}

test "clear checkpoint replays a fragmented transfer; cancelled transfer drops terminal image data" {
    const a = std.testing.allocator;
    var terminal = try vt.Terminal.init(std.testing.io, a, .{ .cols = 8, .rows = 2, .kitty_image_storage_limit = 1024 * 1024 });
    defer terminal.deinit(a);
    var stream = terminal.vtStream();
    defer stream.deinit();
    var renderer = try tui.Renderer.init(a, .{ .max_cells = 16, .cluster_bytes = 64 });
    defer renderer.deinit();
    renderer.clear_checkpoint = true;
    try renderer.resize(.{ .width = 8, .height = 2 });
    renderer.synchronized = true;
    var sender = tui.graphics.Sender.init(.{});
    defer sender.deinit();
    const pixels: [4096]u8 = @splat(0xba);
    const cmd: tui.graphics.kitty.Command = .{ .transmit_and_display = .{ .transmission = .{ .width_pixels = 32, .height_pixels = 32, .identifiers = .{ .image_id = 11, .placement_id = 7 } }, .placement = .{ .virtual = true, .columns = 1, .rows = 1 } } };
    for (0..2) |cycle| {
        renderer.invalidate();
        var frame = renderer.begin();
        try frame.placeholder(0, 0, 0, 0, 11, 7);
        renderer.submit();
        var replays: usize = 0;
        while (true) switch (renderer.step()) {
            .output => |bytes| {
                stream.nextSlice(bytes);
                renderer.consume(bytes.len);
            },
            .yielded => {},
            .cleared => {
                replays += 1;
                try sender.begin(cmd, &pixels, .none);
                while (sender.outputStep()) |bytes| {
                    const n = @min(7, bytes.len);
                    stream.nextSlice(bytes[0..n]);
                    sender.consumeOutput(n);
                }
            },
            .complete => break,
        };
        try std.testing.expectEqual(@as(usize, 1), replays);
        const store = &terminal.screens.active.kitty_images;
        const image = store.imageById(11) orelse return error.ImageNotReplayed;
        try std.testing.expectEqualSlices(u8, &pixels, image.data.bytes().?);
        try std.testing.expectEqual(@as(usize, 1), store.placements.count());
        if (cycle == 1) {
            try sender.begin(cmd, &pixels, .none);
            const pending = (sender.outputStep()).?;
            stream.nextSlice(pending[0..3]);
            sender.consumeOutput(3);
            try sender.cancel(.{ .image_id = .{ .image_id = 11, .free_data = true } });
            while (sender.outputStep()) |bytes| {
                stream.nextSlice(bytes);
                sender.consumeOutput(bytes.len);
            }
            try std.testing.expect(store.imageById(11) == null and stream.ground());
        }
    }
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const initial_mode = std.mem.eql(u8, args[1], "on");
    var terminal = try vt.Terminal.init(init.io, init.gpa, .{ .cols = 80, .rows = 24, .max_scrollback_bytes = 0 });
    defer terminal.deinit(init.gpa);
    terminal.modes.set(.grapheme_cluster, initial_mode);
    var stream = terminal.vtStream();
    defer stream.deinit();
    stream.nextSlice("shell");
    var bytes: [4096]u8 = undefined;
    var entered = false;
    var alternate = false;
    while (true) {
        const count = std.os.linux.read(0, &bytes, bytes.len);
        if (std.os.linux.errno(count) == .INTR) continue;
        if (std.os.linux.errno(count) != .SUCCESS) return error.InputFailed;
        if (count == 0) break;
        for (bytes[0..count], 0..) |_, i| {
            stream.nextSlice(bytes[i..][0..1]);
            const active = terminal.screens.active_key == .alternate;
            if (active and !alternate) {
                entered = true;
                try std.testing.expect(terminal.modes.get(.grapheme_cluster));
            }
            alternate = active;
        }
    }
    try std.testing.expect(entered and stream.ground() and !stream.handler.semantic_failure);
    try std.testing.expect(terminal.screens.active_key == .primary);
    try std.testing.expect(terminal.modes.get(.cursor_visible));
    try std.testing.expect(!terminal.modes.get(.bracketed_paste));
    try std.testing.expectEqual(initial_mode, terminal.modes.get(.grapheme_cluster));
    for ("shell", 0..) |cp, i| {
        const cell = terminal.screens.active.pages.getCell(.{ .active = .{ .x = @intCast(i), .y = 0 } }).?;
        try std.testing.expectEqual(@as(u21, cp), cell.cell.codepoint());
    }
}
