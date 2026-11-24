# libmytui

A Linux terminal UI library for Zig 0.17.1 and libc. The application updates
its model in response to events and draws complete frames in cell coordinates.

## Getting started

Run `zig build run` to try the [counter](examples/counter.zig). Use `+` and `-`
to count, Tab to edit the label and `q` in counting mode to quit.

Add `.mytui = .{ .path = "../libmytui" }` to your package dependencies and
import the module in `build.zig`:

```zig
const dep = b.dependency("mytui", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("mytui", dep.module("mytui"));
```

```zig
const std = @import("std");
const tui = @import("mytui");

pub fn main(init: std.process.Init) !void {
    var app: App = .{};
    try tui.run(init, &app, .{});
}

const App = struct {
    pub fn update(_: *App, event: tui.Event) !tui.Action {
        if (event == .key and event.key.is('q')) return .quit;
        return .none;
    }

    pub fn draw(_: *App, frame: *tui.Frame) !void {
        try frame.text(0, 0, "Hello, world!", .{ .bold = true });
    }
};
```

## Running an application

Call `run` on the main thread. It opens `/dev/tty` or borrows an exclusive,
nonblocking read/write `Options.terminal_fd`. Set `entry`, `alternate_screen`
and `protocols` to choose terminal modes.

Return `.redraw` after a model change, `.repaint` for a full clear, and `.none`
to keep the current frame. `.quit` and `.@"suspend"` drain submitted output
within `shutdown_ms`. SIGINT and SIGTERM request shutdown; SIGTSTP requests
suspension.

For run-scoped resources, implement `start(*tui.Session) !void` and `stop() void`.
Record each acquisition as it succeeds: `stop` also runs after partial startup.
Unwatch descriptors and join workers there, while the session is still live.

- **Input.** Key events carry identity, modifiers, action and optional UTF-8 text.
  Mouse and resize events use screen cells. Events lend their payload for the
  callback; use `event.owned(allocator)` or `event.ownedStorage(storage)` to
  retain it, then `deinit` the copy.
- **Paste.** Buffered input delivers `.paste` or an input error. Streamed input
  delivers `.paste_start`, chunks, and `.paste_end`. Append the final `tail` and
  commit on `.complete`; cancel staging on other endings or shutdown.
  `Paste.commit(&editor)` applies the whole paste to the current selection.
- **Probes.** During `update`, `session.matched_reply` identifies a response to
  an outstanding probe. Read `session.capabilities` for support and assign
  `session.keyboard.*` to change negotiated keyboard flags.
- **Scheduling.** `session.schedule.arm(id, at)` sets a one-shot at an absolute
  `nowMs()` deadline. `watch(fd, interest)` lends the schedule an fd and returns
  its `.ready` identity. Unwatch before closing or replacing the fd.
  Workers can publish under application synchronization and signal a
  `Notification`; consume the wakeup and read the published data on the runner.

## Drawing and editing

`frame.region(rect)` clips and translates drawing into local coordinates.
`text` paints raw single-line UTF-8. For repeated layout or drawing, admit the
bytes once with `Text.init` and keep them immutable for the borrow. Printable
graphemes occupy one or two cells and fit in 48 bytes. Multiline text uses LF.
Use the same `wide_ambiguous` setting for layout and presentation.

```zig
const text = try tui.Text.init("A界\nsecond line", .{ .multiline = true });
var rows = text.rows(frame.size().width, .word);
for (0..frame.size().height) |y| {
    try frame.line(0, @intCast(y), rows.next() orelse break, .{});
}
```

`StyledText.init` admits style spans at grapheme boundaries. `frame.styled`
wraps and paints them; `setCaret` places a native caret. `Rect` and
`geometry.weightedGrid` divide cell space, and `Viewport` tracks the visible
range. `Text.indexRows` caches row boundaries in caller storage for hit testing.
Rebuild the index when the text or wrapping changes.

`Editor.replace` normalizes line endings, validates both joins and commits the
edit and selection together. `select` uses grapheme-aligned byte offsets.
`beginGroup`/`endGroup` group edits for undo and redo. History capacity limits
apply to whole transactions. `WrappedView` tracks the visual caret and scroll
position; call `resetCaret` after independent edits or width changes.

`Scrollback.feed` accepts fragmented LF/CRLF lines; `finish` processes the
final partial line. Both report admission and eviction counts. `line` lends a
validated row until the next mutation. `Editor`, `Renderer` and `Scrollback`
support allocator-owned or exclusive caller storage through `init` and
`initStorage`.

## Processes and graphics

`PtyProcess.start` takes an executable path, null-terminated argument and
environment vectors, and a size. It uses Linux 5.11+ and requires a waitable
SIGCHLD. Watch `master` for data and `completion` for exit. Drain through EOF;
the master and child have independent lifetimes. `waitUntil` and `killAndWait`
use absolute deadlines. On timeout the caller retains the child. Unwatch
before closing; `deinit` reaps the direct child and closes its descriptors.

Pass a `graphics.Sender` in `Options.graphics_sender` to serialize Kitty
commands with frame output. `begin` borrows transfer data through completion.
`.screen_clear` is a replay point before text; `.graphics_sent` acknowledges
local transport. Match `.reply.graphics` to image identifiers before releasing
remote backing resources. Application image IDs below `0x80000000` are
disjoint from terminal probes.

## Custom loops

`Terminal.open` acquires a TTY; `Terminal.borrow` uses a supplied descriptor.
`enter`/`leave` perform bounded writes. For incremental operation, drive
`beginEnter`/`beginLeave` with `modeOutput`/`consumeMode`, then `restore` termios
after leave, including on write failure. `deinit` releases owned descriptors
and the signal mask.

`Schedule.prepare` fills caller poll records. Wait on the used records and
deadline, drain `turn.nextReady()`, then call `turn.beginTimers(now)` and drain
`turn.nextTimer()`. Reserve a poll-record prefix for additional descriptors.

`renderer.resize(size)` admits the dimensions for subsequent draws.
`renderer.begin()` lends a frame until `submit` or `cancelDraw`. After submission,
drive `step`: write `.output` and `consume` the accepted count, continue on
`.yielded`, and finish on `.complete`. A `.cleared` checkpoint permits graphics
replay. Cancellation follows the same drain protocol. Set `synchronized` from
`terminal.sync_frames` between frames. The terminal restores the negotiated mode
on leave, including after an interrupted frame.

See [Architecture](ARCHITECTURE.md) for the ownership and commit boundaries.

## Verification

```sh
zig fmt --check build.zig build.zig.zon src test bench examples
zig build test test-pty test-terminal test-stress -Dterminal-tests=true -j2
zig build test test-pty test-terminal test-stress -Dterminal-tests=true -Doptimize=ReleaseSafe -j2
python3 tools/unicode.py --check
zig build bench -Doptimize=ReleaseFast -- 1000 120 40
```

PTY tests use Python 3. Terminal verification uses the pinned Ghostty engine.
