const std = @import("std");
const screen = @import("screen.zig");
const input = @import("input.zig");
const linux = @import("linux.zig");
const Terminal = @import("terminal.zig").Terminal;
const Sender = @import("graphics.zig").Sender;
const Schedule = @import("schedule.zig").Schedule;

pub const Action = enum { none, redraw, repaint, cancel_paste, @"suspend", quit };

pub const Session = struct {
    schedule: Schedule,
    capabilities: *const Terminal.Capabilities,
    keyboard: *Terminal.Keyboard,
    last_frame: screen.Renderer.Stats = .{},
    matched_reply: bool = false,
};

const Loop = struct {
    session: Session,
    parser: input.Parser,
    phase: enum { running, suspending, quitting } = .running,
    draw: enum { clean, dirty, repaint } = .repaint,

    fn dispatch(self: *Loop, app: anytype, event: input.Event) !void {
        switch (try app.update(event)) {
            .none => {},
            .redraw => if (self.draw == .clean) {
                self.draw = .dirty;
            },
            .repaint => self.draw = .repaint,
            .cancel_paste => self.parser.cancelPaste(),
            .@"suspend" => self.phase = .suspending,
            .quit => self.phase = .quitting,
        }
    }
};

pub const Options = struct {
    graphics_sender: ?*Sender = null,
    terminal_fd: ?std.posix.fd_t = null,
    entry: Terminal.Entry = .{},
    keyboard: Terminal.Keyboard = .{},
    raw_replies: bool = false,
    protocols: Terminal.Protocols = .{},
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
    renderer.wide_ambiguous = options.wide_ambiguous;
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
    var terminal = if (options.terminal_fd) |fd| try Terminal.borrow(init.io, fd, options.alternate_screen, options.shutdown_ms, true) else try Terminal.open(init.io, options.alternate_screen, options.shutdown_ms);
    defer terminal.deinit();
    terminal.protocols = options.protocols;
    terminal.entry = options.entry;
    terminal.frame_cursor = true;
    terminal.desired_keys = options.keyboard;
    var loop: Loop = .{
        .parser = if (options.streamed_paste) try input.Parser.initStreamed(paste) else input.Parser.init(paste),
        .session = .{ .schedule = Schedule.init(init.io, sources, timers), .capabilities = &terminal.capabilities, .keyboard = &terminal.desired_keys },
    };
    loop.parser.raw_replies = options.raw_replies;
    const session = &loop.session;
    try renderer.resize((try terminal.size()) orelse .{ .width = 80, .height = 24 });
    try terminal.enter();

    {
        defer if (has_lifecycle) app.stop();
        if (has_lifecycle) try app.start(session);
        var output: enum { ready, blocked, idle } = .ready;
        var transfer: ?*Sender = null;
        var stop_deadline: ?i96 = null;
        var input_deadline: ?i96 = null;
        var bytes: [4096]u8 = undefined;
        while (true) {
            var check_size = false;
            if (loop.phase != .running and renderer.phase == .idle and transfer == null) {
                if (loop.phase == .quitting) break;
                try terminal.suspendProcess();
                output = .ready;
                input_deadline = null;
                stop_deadline = null;
                loop.phase = .running;
                check_size = true;
                loop.draw = .repaint;
                if (loop.parser.finish()) |event| {
                    if (event == .paste_end) try loop.dispatch(app, .{ .paste_end = .{ .status = .cancelled } });
                }
            }
            const current = linux.now(init.io);
            if (stop_deadline) |deadline| {
                if (current >= deadline) return error.OutputTimeout;
            }
            var turn: Schedule.Turn = if (loop.phase == .running) try session.schedule.prepare(descriptors[2..]) else .{ .schedule = &session.schedule };
            var wake: ?i96 = if (output == .ready) current else null;
            for ([_]?i96{ input_deadline, turn.deadline, stop_deadline }) |maybe| {
                if (maybe) |deadline| {
                    wake = @min(wake orelse deadline, deadline);
                }
            }
            descriptors[0] = .{
                .fd = terminal.fd,
                .events = (if (loop.phase == .running) std.posix.POLL.IN else @as(i16, 0)) |
                    (if (output == .blocked) @as(i16, std.posix.POLL.OUT) else 0),
                .revents = 0,
            };
            descriptors[1] = .{ .fd = terminal.signal_fd, .events = std.posix.POLL.IN, .revents = 0 };
            try session.schedule.wait(descriptors[0 .. turn.interests.len + 2], wake);
            if (descriptors[1].revents & std.posix.POLL.IN != 0) {
                var records: [8]std.os.linux.signalfd_siginfo = undefined;
                if (try linux.read(terminal.signal_fd, std.mem.sliceAsBytes(&records))) |count| {
                    for (records[0 .. count / @sizeOf(std.os.linux.signalfd_siginfo)]) |record| {
                        switch (record.signo) {
                            @backingInt(std.posix.SIG.INT), @backingInt(std.posix.SIG.TERM) => loop.phase = .quitting,
                            @backingInt(std.posix.SIG.TSTP) => if (loop.phase != .quitting) {
                                loop.phase = .suspending;
                            },
                            @backingInt(std.posix.SIG.WINCH), @backingInt(std.posix.SIG.CONT) => {
                                check_size = true;
                                if (record.signo == @backingInt(std.posix.SIG.CONT)) loop.draw = .repaint;
                            },
                            else => {},
                        }
                    }
                }
            }
            if (descriptors[0].revents & std.posix.POLL.OUT != 0) output = .ready;
            if (descriptors[0].revents & (std.posix.POLL.HUP | std.posix.POLL.ERR) != 0 and descriptors[0].revents & std.posix.POLL.IN == 0) {
                if (loop.phase == .running) {
                    if (loop.parser.finish()) |event| try loop.dispatch(app, event);
                }
                loop.phase = .quitting;
                output = .ready;
            }
            if (check_size and loop.phase == .running) {
                if (try terminal.size()) |resized| {
                    if (!std.meta.eql(renderer.size, resized)) {
                        try renderer.resize(resized);
                        loop.draw = .repaint;
                        try loop.dispatch(app, .{ .resize = resized });
                    }
                }
            }
            if (loop.phase == .running) {
                if (input_deadline) |deadline| {
                    if (linux.now(init.io) >= deadline) {
                        input_deadline = null;
                        if (loop.parser.expire()) |event| try loop.dispatch(app, event);
                    }
                }
            }
            if (loop.phase == .running and descriptors[0].revents & std.posix.POLL.IN != 0) {
                if (try linux.read(terminal.fd, &bytes)) |count| {
                    if (count == 0) {
                        if (loop.parser.finish()) |event| try loop.dispatch(app, event);
                        loop.phase = .quitting;
                    }
                    for (bytes[0..count]) |byte| {
                        if (loop.parser.feed(byte)) |event| {
                            session.matched_reply = event == .reply and terminal.observe(event.reply);
                            try loop.dispatch(app, event);
                            session.matched_reply = false;
                        }
                        if (loop.phase != .running) break;
                    }
                    input_deadline = if (loop.parser.timeoutKind()) |kind|
                        linux.now(init.io) + switch (kind) {
                            .escape => options.escape_ms,
                            .sequence => options.sequence_ms,
                        }
                    else
                        null;
                }
            }
            while (loop.phase == .running) {
                const ready = turn.nextReady() orelse break;
                try loop.dispatch(app, .{ .ready = ready });
            }
            if (loop.phase == .running) {
                turn.beginTimers(session.schedule.nowMs());
                while (turn.nextTimer()) |id| {
                    try loop.dispatch(app, .{ .timer = id });
                    if (loop.phase != .running) break;
                }
            }
            if (loop.phase != .running) {
                input_deadline = null;
                if (stop_deadline == null) stop_deadline = linux.now(init.io) + options.shutdown_ms;
            }
            if (output == .blocked) continue;
            output = .ready;
            if (renderer.phase == .idle and transfer == null) {
                if (loop.phase != .running) continue;
                const command = terminal.modeOutput();
                if (command.len != 0) {
                    if (try linux.write(terminal.fd, command)) |n| terminal.consumeMode(n) else output = .blocked;
                    continue;
                }
                if (options.graphics_sender) |sender| {
                    if (sender.isActive()) transfer = sender;
                }
                if (transfer == null) {
                    if (loop.draw == .clean) {
                        output = .idle;
                        continue;
                    }
                    if (loop.draw == .repaint) renderer.invalidate();
                    renderer.synchronized = terminal.sync_frames;
                    var frame = renderer.begin();
                    try app.draw(&frame);
                    renderer.submit();
                    loop.draw = .clean;
                }
            }
            if (transfer) |sender| {
                if (try linux.write(terminal.fd, sender.outputStep().?)) |n| sender.consumeOutput(n) else output = .blocked;
                if (!sender.isActive()) {
                    transfer = null;
                    if (loop.phase == .running) {
                        try loop.dispatch(app, .graphics_sent);
                        if (loop.phase == .running and renderer.phase == .presenting and sender.isActive()) transfer = sender;
                    }
                }
                continue;
            }
            switch (renderer.step()) {
                .output => |chunk| {
                    if (try linux.write(terminal.fd, chunk)) |count| renderer.consume(count) else output = .blocked;
                },
                .yielded => {},
                .cleared => if (loop.phase == .running) {
                    try loop.dispatch(app, .screen_clear);
                    const sender = options.graphics_sender.?;
                    if (loop.phase == .running and sender.isActive()) transfer = sender;
                },
                .complete => session.last_frame = renderer.stats,
            }
        }
    }
    try terminal.leave();
}
