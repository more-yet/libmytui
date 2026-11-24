const std = @import("std");
const tui = @import("mytui");

const Scenario = enum { unchanged, one_cell, full_frame, unicode, ascii_full, unicode_full, styled_cells };

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const iterations = if (args.len > 1) try std.fmt.parseInt(usize, args[1], 10) else 10_000;
    const size: tui.Size = .{
        .width = if (args.len > 2) try std.fmt.parseInt(u16, args[2], 10) else 120,
        .height = if (args.len > 3) try std.fmt.parseInt(u16, args[3], 10) else 40,
    };
    if (iterations == 0 or size.width == 0 or size.height == 0 or size.width > 512 or size.height > 256)
        return error.InvalidBenchmarkBounds;
    const cells = @as(u32, size.width) * size.height;
    var renderer = try tui.Renderer.init(init.gpa, .{ .max_cells = cells, .cluster_bytes = cells * 16 });
    defer renderer.deinit();
    for (std.enums.values(Scenario)) |scenario| {
        try draw(&renderer, scenario, 1, size);
        while (true) switch (renderer.step()) {
            .output => |output| renderer.consume(output.len),
            .yielded, .cleared => {},
            .complete => break,
        };
        var bytes: usize = 0;
        var steps: usize = 0;
        var batches: [7]i96 = undefined;
        for (&batches) |*elapsed| {
            const start = std.Io.Clock.awake.now(init.io).nanoseconds;
            for (0..iterations) |iteration| {
                try draw(&renderer, scenario, iteration, size);
                while (true) {
                    steps += 1;
                    switch (renderer.step()) {
                        .output => |output| {
                            bytes += output.len;
                            renderer.consume(output.len);
                        },
                        .yielded, .cleared => {},
                        .complete => break,
                    }
                }
            }
            elapsed.* = std.Io.Clock.awake.now(init.io).nanoseconds - start;
        }
        std.mem.sort(i96, &batches, {}, std.sort.asc(i96));
        var output: [512]u8 = undefined;
        var stdout = std.Io.File.stdout().writer(init.io, &output);
        try stdout.interface.print(
            "{{\"scenario\":\"{s}\",\"width\":{d},\"height\":{d},\"frames\":{d},\"median_ns\":{d},\"bytes\":{d},\"steps\":{d}}}\n",
            .{ @tagName(scenario), size.width, size.height, iterations * batches.len, @divTrunc(batches[batches.len / 2], iterations), bytes, steps },
        );
        try stdout.interface.flush();
    }
}

fn draw(renderer: *tui.Renderer, scenario: Scenario, iteration: usize, size: tui.Size) !void {
    var frame = try renderer.begin(size, false);
    switch (scenario) {
        .unchanged, .one_cell => try frame.text(2, 2, if (scenario == .one_cell and iteration & 1 == 0) "A" else "B", .{}),
        .full_frame => frame.fill(.{ .background = .{ .indexed = @intCast(iteration & 1) } }),
        .unicode => try frame.text(2, 2, if (iteration & 1 == 0) "界e\u{301}👩‍💻" else "語a\u{301}👨‍💻", .{}),
        .ascii_full, .unicode_full => {
            const first = "界e\u{301}👩‍💻";
            const second = "語a\u{301}👨‍💻";
            const bytes = switch (scenario) {
                .ascii_full => if (iteration & 1 == 0) &@as([512]u8, @splat('a')) else &@as([512]u8, @splat('b')),
                .unicode_full => if (iteration & 1 == 0)
                    std.mem.asBytes(&@as([103][first.len]u8, @splat(first.*)))
                else
                    std.mem.asBytes(&@as([103][second.len]u8, @splat(second.*))),
                else => unreachable,
            };
            const length = if (scenario == .ascii_full) size.width else @min(bytes.len, (@as(usize, size.width) + 4) / 5 * first.len);
            for (0..frame.size().height) |y| try frame.text(0, @intCast(y), bytes[0..length], .{});
        },
        .styled_cells => for (0..size.height) |y| {
            for (0..size.width) |x| {
                try frame.text(@intCast(x), @intCast(y), "x", .{
                    .foreground = .{ .rgb = @truncate((x + iteration) * 0x12345) },
                    .background = .{ .indexed = @truncate(y) },
                    .bold = x & 1 != 0,
                });
            }
        },
    }
    renderer.submit();
}
