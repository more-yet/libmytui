const std = @import("std");
const screen = @import("screen.zig");
const input = @import("input.zig");
const linux = @import("linux.zig");
const Sender = @import("graphics/sender.zig").Sender;

pub const Action = enum { none, redraw, repaint, cancel_paste, @"suspend", quit };

const Schedule = @import("schedule.zig").Schedule;

pub const Session = struct {
    schedule: Schedule,
    capabilities: *const linux.Terminal.Capabilities,
    keyboard: *linux.Terminal.Keyboard,
    last_frame: screen.Renderer.Stats = .{},
    matched_reply: bool = false,
    phase: enum { running, suspending, quitting } = .running,
    draw: enum { clean, dirty, repaint } = .repaint,

    fn dispatch(self: *Session, app: anytype, event: input.Event, parser: *input.Parser) !void {
        switch (try app.update(event)) {
            .none => {},
            .redraw => if (self.draw == .clean) {
                self.draw = .dirty;
            },
            .repaint => self.draw = .repaint,
            .cancel_paste => parser.cancelPaste(),
            .@"suspend" => self.phase = .suspending,
            .quit => self.phase = .quitting,
        }
    }
};

pub const Options = struct {
    graphics_sender: ?*Sender = null,
    terminal_fd: ?std.posix.fd_t = null,
    entry: linux.Terminal.Entry = .{},
    keyboard: linux.Terminal.Keyboard = .{},
    raw_replies: bool = false,
    protocols: linux.Terminal.Protocols = .{},
    color_profile: screen.ColorProfile = .rgb,
    limits: screen.Limits = .{},
    work_budget: u32 = 4096,
    paste_bytes: u32 = 64 * 1024,
    streamed_paste: bool = false,
    wide_ambiguous: bool = false,
    alternate_screen: bool = true,
    max_sources: u16 = 16,
    max_timers: u16 = 16,
    escape_ms: u32 = 30,
    sequence_ms: u32 = 250,
    shutdown_ms: u32 = 500,
};

pub fn run(init: std.process.Init, app: anytype, options: Options) !void {
    if (@import("builtin").os.tag != .linux) @compileError("libmytui's runner targets Linux");
    const App = @typeInfo(@TypeOf(app)).pointer.child;
    const has_lifecycle = @hasDecl(App, "start");
    if (has_lifecycle != @hasDecl(App, "stop"))
        @compileError("application resource ownership requires both start(*Session) !void and stop() void");
    if (options.shutdown_ms == 0) return error.InvalidOptions;
    var renderer = try screen.Renderer.init(init.gpa, options.limits);
    defer renderer.deinit();
    renderer.color_profile = options.color_profile;
    renderer.clear_checkpoint = options.graphics_sender != null;
    renderer.work_budget = options.work_budget;
    renderer.grapheme_mode = options.entry.grapheme;
    const paste = try init.gpa.alloc(u8, options.paste_bytes);
    defer init.gpa.free(paste);
    const sources = try init.gpa.alloc(Schedule.Source, options.max_sources);
    defer init.gpa.free(sources);
    const timers = try init.gpa.alloc(Schedule.Alarm, options.max_timers);
    defer init.gpa.free(timers);
    const descriptors = try init.gpa.alloc(std.posix.pollfd, sources.len + 2);
    defer init.gpa.free(descriptors);
    var parser = if (options.streamed_paste) try input.Parser.initStreamed(paste) else input.Parser.init(paste);
    var terminal = if (options.terminal_fd) |fd| try linux.Terminal.borrow(init.io, fd, options.alternate_screen, options.shutdown_ms, true) else try linux.Terminal.open(init.io, options.alternate_screen, options.shutdown_ms);
    defer terminal.deinit();
    terminal.protocols = options.protocols;
    terminal.entry = options.entry;
    terminal.frame_cursor = true;
    terminal.desired_keys = options.keyboard;
    parser.raw_replies = options.raw_replies;
    var session: Session = .{ .schedule = Schedule.init(init.io, sources, timers), .capabilities = &terminal.capabilities, .keyboard = &terminal.desired_keys };
    var size = (try terminal.size()) orelse @import("geometry.zig").Size{ .width = 80, .height = 24 };
    if (size.count() > options.limits.max_cells) return error.ScreenCapacity;
    try terminal.enter();

    {
        defer if (has_lifecycle) app.stop();
        if (has_lifecycle) try app.start(&session);
        var output_blocked = false;
        var sending = false;
        var stop_deadline: ?i96 = null;
        var input_deadline: ?i96 = null;
        var bytes: [4096]u8 = undefined;
        while (true) {
            var check_size = false;
            if (session.phase != .running and renderer.phase == .idle and !sending) {
                if (session.phase == .quitting) break;
                try terminal.suspendProcess();
                output_blocked = false;
                const interrupted_paste = parser.streamed and parser.state == .paste;
                _ = parser.finish();
                input_deadline = null;
                stop_deadline = null;
                session.phase = .running;
                check_size = true;
                session.draw = .repaint;
                if (interrupted_paste) try session.dispatch(app, .{ .paste_end = .{ .status = .cancelled } }, &parser);
            }
            const current = linux.now(init.io);
            if (stop_deadline) |deadline| {
                if (current >= deadline) return error.OutputTimeout;
            }
            var turn: Schedule.Turn = if (session.phase == .running) try session.schedule.prepare(descriptors[2..]) else .{ .schedule = &session.schedule };
            var wake: ?i96 = if (switch (renderer.phase) {
                .idle => !output_blocked and (session.draw != .clean or (options.graphics_sender != null and options.graphics_sender.?.isActive()) or terminal.modeOutput().len != 0),
                .presenting => !output_blocked,
                .drawing => unreachable,
            }) current else null;
            for ([_]?i96{ input_deadline, turn.deadline, stop_deadline }) |maybe| {
                if (maybe) |deadline| {
                    wake = @min(wake orelse deadline, deadline);
                }
            }
            descriptors[0] = .{
                .fd = terminal.fd,
                .events = (if (session.phase == .running) std.posix.POLL.IN else @as(i16, 0)) |
                    (if (output_blocked) @as(i16, std.posix.POLL.OUT) else 0),
                .revents = 0,
            };
            descriptors[1] = .{ .fd = terminal.signal_fd, .events = std.posix.POLL.IN, .revents = 0 };
            try session.schedule.wait(descriptors[0 .. turn.interests.len + 2], wake);
            if (descriptors[1].revents & std.posix.POLL.IN != 0) {
                var records: [8]std.os.linux.signalfd_siginfo = undefined;
                if (try linux.read(terminal.signal_fd, std.mem.sliceAsBytes(&records))) |count| {
                    for (records[0 .. count / @sizeOf(std.os.linux.signalfd_siginfo)]) |record| {
                        switch (record.signo) {
                            @backingInt(std.posix.SIG.INT), @backingInt(std.posix.SIG.TERM) => session.phase = .quitting,
                            @backingInt(std.posix.SIG.TSTP) => if (session.phase != .quitting) {
                                session.phase = .suspending;
                            },
                            @backingInt(std.posix.SIG.WINCH), @backingInt(std.posix.SIG.CONT) => {
                                check_size = true;
                                if (record.signo == @backingInt(std.posix.SIG.CONT)) session.draw = .repaint;
                            },
                            else => {},
                        }
                    }
                }
            }
            if (descriptors[0].revents & std.posix.POLL.OUT != 0) output_blocked = false;
            if (descriptors[0].revents & (std.posix.POLL.HUP | std.posix.POLL.ERR) != 0 and descriptors[0].revents & std.posix.POLL.IN == 0) {
                if (session.phase == .running) {
                    if (parser.finish()) |event| try session.dispatch(app, event, &parser);
                }
                session.phase = .quitting;
                output_blocked = false;
            }
            if (check_size and session.phase == .running) {
                if (try terminal.size()) |resized| {
                    if (resized.count() > options.limits.max_cells) return error.ScreenCapacity;
                    if (!std.meta.eql(size, resized)) {
                        size = resized;
                        session.draw = .repaint;
                        try session.dispatch(app, .{ .resize = size }, &parser);
                    }
                }
            }
            if (session.phase == .running) {
                if (input_deadline) |deadline| {
                    if (linux.now(init.io) >= deadline) {
                        input_deadline = null;
                        if (parser.expire()) |event| try session.dispatch(app, event, &parser);
                    }
                }
            }
            if (session.phase == .running and descriptors[0].revents & std.posix.POLL.IN != 0) {
                if (try linux.read(terminal.fd, &bytes)) |count| {
                    if (count == 0) {
                        if (parser.finish()) |event| try session.dispatch(app, event, &parser);
                        session.phase = .quitting;
                    }
                    for (bytes[0..count]) |byte| {
                        if (parser.feed(byte)) |event| {
                            session.matched_reply = event == .reply and terminal.observe(event.reply);
                            try session.dispatch(app, event, &parser);
                            session.matched_reply = false;
                        }
                        if (session.phase != .running) break;
                    }
                    input_deadline = if (parser.timeoutKind()) |kind|
                        linux.now(init.io) + switch (kind) {
                            .escape => options.escape_ms,
                            .sequence => options.sequence_ms,
                        }
                    else
                        null;
                }
            }
            while (session.phase == .running) {
                const event = turn.nextReady() orelse break;
                try session.dispatch(app, event, &parser);
            }
            if (session.phase == .running) {
                turn.beginTimers(session.schedule.nowMs());
                while (turn.nextTimer()) |id| {
                    try session.dispatch(app, .{ .timer = id }, &parser);
                    if (session.phase != .running) break;
                }
            }
            if (session.phase != .running) {
                input_deadline = null;
                if (stop_deadline == null) stop_deadline = linux.now(init.io) + options.shutdown_ms;
            }
            if (output_blocked) continue;
            if (session.phase == .running and renderer.phase == .idle and !sending) {
                const command = terminal.modeOutput();
                if (command.len != 0) {
                    if (try linux.write(terminal.fd, command)) |n| terminal.consumeMode(n) else output_blocked = true;
                    continue;
                }
                renderer.synchronized = terminal.sync_frames;
            }
            if (options.graphics_sender) |sender| {
                if (sending or (session.phase == .running and renderer.phase == .idle and sender.isActive())) {
                    sending = true;
                    const output = sender.outputStep().?;
                    if (try linux.write(terminal.fd, output)) |n| sender.consumeOutput(n) else output_blocked = true;
                    if (!sender.isActive()) {
                        sending = false;
                        if (session.phase == .running) {
                            try session.dispatch(app, .graphics_sent, &parser);
                            sending = session.phase == .running and renderer.phase == .presenting and sender.isActive();
                        }
                    }
                    continue;
                }
            }
            if (session.phase == .running and renderer.phase == .idle) {
                if (session.draw == .clean) continue;
                if (session.draw == .repaint) renderer.invalidate();
                var frame = try renderer.begin(size, options.wide_ambiguous);
                try app.draw(&frame);
                renderer.submit();
                session.draw = .clean;
            }
            if (renderer.phase == .presenting) switch (renderer.step()) {
                .output => |output| {
                    if (try linux.write(terminal.fd, output)) |count| {
                        renderer.consume(count);
                        terminal.sync_active = renderer.sync_active;
                    } else output_blocked = true;
                },
                .yielded => {},
                .cleared => if (session.phase == .running) {
                    try session.dispatch(app, .screen_clear, &parser);
                    sending = session.phase == .running and options.graphics_sender.?.isActive();
                },
                .complete => session.last_frame = renderer.stats,
            };
        }
    }
    try terminal.leave();
}
