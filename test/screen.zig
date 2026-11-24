const std = @import("std");
const tui = @import("mytui");
const c = @import("vterm");

test "terminal cells match submitted frames across fragmented output, resize, clipping, and cancellation" {
    const terminal = c.vterm_new(24, 80) orelse return error.OutOfMemory;
    defer c.vterm_free(terminal);
    c.vterm_set_utf8(terminal, 1);
    const screen = c.vterm_obtain_screen(terminal).?;
    c.vterm_screen_reset(screen, 1);
    c.vterm_state_set_bold_highbright(c.vterm_obtain_state(terminal), 0);
    var renderer = try tui.Renderer.init(std.testing.allocator, .{ .max_cells = 4800, .cluster_bytes = 8192 });
    defer renderer.deinit();
    const sizes = [_]tui.Size{
        .{ .width = 80, .height = 24 },
        .{ .width = 120, .height = 40 },
        .{ .width = 40, .height = 12 },
        .{ .width = 1, .height = 1 },
        .{ .width = 2, .height = 1 },
    };
    for (0..100) |iteration| {
        const size = sizes[iteration / 20];
        c.vterm_set_size(terminal, size.height, size.width);
        var frame = try renderer.begin(size, false);
        var random: u64 = iteration / 2 + 1;
        const ascii = iteration / 2 % 2 == 0;
        const glyphs: []const []const u8 = if (ascii) &.{ "a", " ", "z", "xyz" } else &.{ "a", " ", "界", "e\u{301}", "語", "x\u{308}\u{301}" };
        for (0..120) |_| {
            var region = frame.region(.{
                .x = @intCast(next(&random) % size.width),
                .y = @intCast(next(&random) % size.height),
                .width = @intCast(1 + next(&random) % size.width),
                .height = @intCast(1 + next(&random) % size.height),
            });
            const flags = next(&random);
            const style: tui.Style = .{
                .foreground = if (flags & 1 == 0) .default else .{ .rgb = @truncate(next(&random)) },
                .background = if (flags & 2 == 0) .default else .{ .indexed = @truncate(next(&random)) },
                .bold = flags & 4 != 0,
                .italic = flags & 8 != 0,
                .underline = flags & 16 != 0,
                .reverse = flags & 32 != 0,
            };
            if (flags % 3 == 0) region.fill(style) else try region.text(0, 0, glyphs[next(&random) % glyphs.len], style);
        }
        try frame.text(size.width - 1, size.height - 1, "Z", .{});
        const submitted = renderer.back;
        renderer.submit();
        var emitted: usize = 0;
        while (true) switch (renderer.step()) {
            .output => |output| {
                const count = @min(output.len, if (iteration % 4 == 0) 1 else 1 + next(&random) % 257);
                renderer.consume(0);
                try std.testing.expectEqualSlices(u8, output, renderer.step().output);
                if (ascii) {
                    try std.testing.expectEqual(count, c.vterm_input_write(terminal, output.ptr, count));
                } else if (renderer.accepted == 0) {
                    try std.testing.expectEqual(output.len, c.vterm_input_write(terminal, output.ptr, output.len));
                }
                renderer.consume(count);
                emitted += count;
            },
            .yielded, .cleared => {},
            .complete => break,
        };
        if (iteration % 2 == 1) try std.testing.expectEqual(@as(usize, 0), emitted);
        expectScreen(&submitted, screen) catch |err| {
            std.debug.print("frame {d}\n", .{iteration});
            return err;
        };
        _ = try renderer.begin(.{ .width = 3, .height = 2 }, false);
        renderer.cancelDraw();
        try expectScreen(&submitted, screen);
    }
}

fn expectScreen(frame: anytype, screen: *c.VTermScreen) !void {
    for (frame.cells[0 .. @as(usize, frame.size.width) * frame.size.height], 0..) |expected, index| {
        var actual: c.TestCell = undefined;
        try std.testing.expectEqual(@as(c_int, 1), c.test_vterm_cell(screen, .{
            .row = @intCast(index / frame.size.width),
            .col = @intCast(index % frame.size.width),
        }, &actual));
        var chars: [6]u32 = @splat(0);
        if (expected.width > 0) {
            if (expected.glyph & (1 << 31) == 0) {
                chars[0] = expected.glyph;
            } else {
                const offset = expected.glyph & ~@as(u32, 1 << 31);
                var scalars = (try std.unicode.Utf8View.init(frame.clusters[offset + 1 ..][0..frame.clusters[offset]])).iterator();
                var i: usize = 0;
                while (scalars.nextCodepoint()) |cp| : (i += 1) chars[i] = cp;
            }
        }
        if (!std.mem.eql(u32, &chars, &actual.chars) or actual.width != expected.width)
            std.debug.print("cell {d},{d}: expected {any}/{d}, actual {any}/{d}\n", .{
                index % frame.size.width, index / frame.size.width, chars, expected.width, actual.chars, actual.width,
            });
        try std.testing.expectEqualSlices(u32, &chars, &actual.chars);
        try std.testing.expectEqual(@as(u32, expected.width), actual.width);
        const style = expected.style;
        if (actual.foreground != @as(u32, style.foreground_kind) << 24 | style.foreground)
            std.debug.print("foreground at {d},{d}, width {d}\n", .{ index % frame.size.width, index / frame.size.width, expected.width });
        try std.testing.expectEqual(@as(u32, style.foreground_kind) << 24 | style.foreground, actual.foreground);
        try std.testing.expectEqual(@as(u32, style.background_kind) << 24 | style.background, actual.background);
        const attributes = @as(u32, @intFromBool(style.bold)) | @as(u32, @intFromBool(style.italic)) << 1 |
            @as(u32, @intFromBool(style.underline)) << 2 | @as(u32, @intFromBool(style.reverse)) << 3;
        try std.testing.expectEqual(attributes, actual.attributes);
    }
}

fn next(state: *u64) u64 {
    state.* = state.* *% 6364136223846793005 +% 1442695040888963407;
    return state.* >> 32;
}
