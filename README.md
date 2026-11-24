# libmytui

A Linux terminal UI library for Zig 0.17.1 and libc. Applications choose the
content, bindings, placement and timing. The library delivers events, edits
text atomically and presents complete frames.

## Build and run

`zig build run` opens the [counter](examples/counter.zig). Use `+` and `-` to
count, Tab to edit the label and `q` in counting mode to quit.

Add `.mytui = .{ .path = "../libmytui" }` to your `build.zig.zon` dependencies.
In `build.zig`:

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

Call `run` on the main thread. Each `update` returns an action: `.none`,
`.redraw`, `.repaint` (clear and redraw), `.cancel_paste`, `.@"suspend"` or
`.quit`. Bind these to the keys your application uses. SIGTERM and SIGINT
request shutdown; SIGTSTP requests suspension.

For run-scoped resources implement `start(*tui.Session) !void` and `stop() void`.
The session and its schedule are available from terminal entry through `stop`.
Record each acquisition before the next fallible operation: `stop` runs even
after partial startup. Create workers in this scope and join them during cleanup.

## Input and terminal ownership

- `.key` reports key identity, modifiers, press/repeat/release and optional
  associated UTF-8 `text`. `key.is('q')` matches a printable key on press or
  repeat. `.mouse` coordinates are zero-based screen cells; `.focus` reports
  focus changes. `.resize` includes cell dimensions and pixel dimensions when
  available.
- `Options.protocols` selects mouse, focus, keyboard, cursor, graphics and
  synchronized-output protocols. Probes run asynchronously. During `update`,
  `session.capabilities` reports support and `session.matched_reply` identifies
  an outstanding query's response. Set `Options.keyboard` or assign
  `session.keyboard.*` to select Kitty's five enhancement flags. Updates are
  serialized between frames.
- `.reply` carries cursor position, keyboard flags, DEC mode status or a graphics
  reply. `raw_replies = true` also delivers unrecognized CSI and control-string
  replies with their delimiters, up to 260 bytes. Treat reply bytes as data.
- Events borrow payloads for the callback. `event.owned(allocator)` copies them;
  `event.ownedStorage(bytes)` uses `event.payloadBytes()` disjoint caller bytes.
  `deinit()` erases the copied payload in either case.
- Buffered paste delivers one `.paste` or `.input_overflow`. `streamed_paste = true`
  uses `paste_bytes` as a reusable chunk (minimum 16). Handle `.paste_start`,
  `.paste_chunk`, then `.paste_end`. Only `.complete` commits, including the final
  `tail`. `Paste.append` stages bytes in application storage; `commit(&editor)`
  replaces the selection once. Cancel remaining staging during shutdown.

The runner opens `/dev/tty` or borrows `Options.terminal_fd`, an exclusive
nonblocking read/write TTY. `entry` selects raw termios, grapheme mode, cursor
hiding and bracketed paste. Alternate screen and protocol choices are independent.
Keep entry policy fixed through restoration.

Custom loops use `Terminal.open(io, alternate_screen, cleanup_ms)` or
`Terminal.borrow(io, fd, alternate_screen, cleanup_ms, manage_signals)`.
With `manage_signals = false` the caller owns the signal mask and collection.
Use `enter`/`leave` for bounded synchronous output, or `beginEnter`/`beginLeave`,
`modeOutput()` and `consumeMode(n)` for partial writes. Feed typed replies to
`observe`; serialize negotiated commands between frames. Call `restore()` after
incremental leave, including on output failure, and `deinit()` for fd and signal
cleanup. Borrowed TTYs retain their original ownership and file flags.

## Drawing and layout

Each `draw` describes the whole frame. `frame.region(rect)` clips and translates
local coordinates. A frame borrow ends on submission or cancellation.

| Operation | Result |
| --- | --- |
| `text(x,y,bytes,style)`, `print(...)` | Validate and paint a single line. `print` accepts up to 1024 formatted bytes. |
| `line(x,y,text,style)` | Paint the first logical row of validated text. |
| `styled(content,wrap)` | Paint validated `StyledText` with optional grapheme or word wrapping. |
| `paddedLine(value,marker,alignment,style)` | Fill the first row and align the fitted text and truncation marker. |
| `fill(style)`, `fillAscii(char,style)`, `fills(batch)` | Paint spaces, a printable ASCII cell, or ordered rectangular fills. A batch admits all characters before painting. |
| `setCaret(caret)` | Place a region-local native caret; null or a clipped position hides it. |
| `screenPoint(x,y)`, `inspect(x,y,&scratch)` | Translate or inspect a visible cell. Wide continuations have width zero. |

Styles support foreground, background, underline color and text attributes.
Choose `.rgb`, `.indexed` or `.ansi16` for the terminal. `braille([4][2]bool)`
maps pixel rows to a scalar. `inspect` borrows scalar scratch or the frame arena.
`renderer.inspectCommitted` reads the last acknowledged grid; consume its glyph
before the next commit or teardown.

`Text.init(bytes, options)` borrows immutable, validated UTF-8. Drawable
graphemes occupy one or two cells, with a 48-byte cluster limit. Multiline text
accepts LF. Match `wide_ambiguous` to the terminal. `StyledText.init(text, spans)`
borrows ordered `{end, style}` spans; exclusive ends fall on grapheme boundaries
and cover the text.

```zig
const text = try tui.Text.init("A界\nsecond line", .{ .multiline = true });
var rows = text.rows(8, .word);
var y: u16 = 0;
while (y < frame.size().height) : (y += 1) {
    try frame.line(0, y, rows.next() orelse break, .{});
}
```

`clusters`, `words` and `lineBreaks` use Unicode 17. `position`, `byteOffset`,
`ceilBoundary` and `clip` map bytes and cells at whole graphemes. `rows(columns,
mode)` yields validated row views, preserving empty lines. `indexRows` fills
caller storage for repeated hit tests; rebuild it when text or wrapping changes.

`Rect` provides containment, insets, splits, equal grid cells and constrained
placement. `geometry.tracks(origin,extent,gap,specs,storage)` reserves gaps and
minima, divides free cells by weight in input order and redistributes capped
shares. Rounding carries forward; spare space trails saturated tracks.
`geometry.weightedGrid(bounds, columns, rows)` admits both axes before writing
intervals. Each axis takes `{specs,storage,gap}` or null for a spanning interval.
`grid.rect(col,row)` computes the requested rectangle.

## Editing, navigation and scrollback

```zig
var field = try tui.Editor.init(gpa, .{ .capacity = 4096, .history = 16, .multiline = true });
defer field.deinit();
try field.replace("one\r\ntwo");
try field.select(0, 3);
try field.replace("first");
_ = field.undo();
```

`replace` normalizes CR/CRLF to LF, validates joins and rounds the caret up to
a resulting boundary. `select` accepts anchor and cursor byte offsets at grapheme
boundaries. `move`, `delete`, `moveWord` and `deleteWord` operate on the active
selection. `text()` and `selectedText()` borrow until the next mutation.
`WrappedView` owns wrap policy, sticky column, viewport and affinity at soft
breaks. Its `move`, `place`, `reveal` and `visibleRows` use the same row geometry.
Call `resetCaret` after independent editing or a width change.

`beginGroup`/`endGroup` nest. The journal admits edits against transaction
(`history`), record (`history_records`, default `4 × history`) and payload
(`history_bytes`, default `2 × capacity` with history enabled) limits. It evicts
whole oldest transactions. `HistoryCapacity` preserves live text, selection,
the open transaction and redo. `undo` and `redo` restore one transaction and
its selection. Successful branching edits discard redo. `clear` and `deinit`
erase documents and journal storage.

`Viewport.visible` and `reveal` clamp one scroll axis. `navigation.moveSelection`
clamps an index; `Focus.move` and `reconcile` use unique application IDs.
`hitTarget`, `directional`, `ItemRows` and `Viewport.thumb` compute candidates,
row hits and scrollbar geometry from application data.

`Scrollback.init(gpa, lines, line_bytes)` reserves fixed-size line slots.
`feed` accepts fragmented LF/CRLF input and `finish` closes the final partial
line. Both report appended, evicted, invalid and overlong counts. `line(i,wide)`
borrows a validated row until mutation. Use `viewport.evictLeading` to preserve
a scrolled position or `revealLast` to follow the tail.

## Caller storage and presentation

Supply stable, disjoint, exclusively writable slices through `initStorage`:

| Value | Capacity calculation and storage |
| --- | --- |
| `Editor` | `storageBytes(options)` bytes and `recordCount(options)` `Editor.Record` entries. |
| `Renderer` | `storageSize(limits)` supplies total cell count and cluster bytes for both grids. |
| `Scrollback` | `storageSize(lines,line_bytes)` supplies `slots` lengths (`usize`) and `bytes`, including the staging slot. |

The runner defaults to 65,536 cells, 256 KiB of cluster storage per grid,
64 KiB of paste storage, 16 watches and 16 timers. Allocation happens at
startup. `shutdown_ms` bounds the terminal output drain; the application owns
its worker shutdown deadlines.

`Renderer.begin(size,wide)` returns the private frame. `cancelDraw` discards it;
`submit` freezes it. Repeatedly call `step`: write `.output` and `consume(n)`
for the accepted prefix; continue on `.yielded`, use `.cleared` for optional
graphics replay, and finish on `.complete`. The front grid changes only on a
fully acknowledged commit.
`work_budget` bounds the scan per step, with a two-cell minimum for wide glyphs.
`stats` reports scanned and changed cells, runs, accepted bytes and yields;
`session.last_frame` exposes completed statistics in `run`.

`cancelPresentation` requests cancellation: drive `step`/`consume` through
`.complete` to finish exposed bytes and close synchronized output. The next
frame repaints. Call `invalidate` at an idle boundary after another producer
changes the screen. In custom loops set `renderer.synchronized` from
`terminal.sync_frames` between frames and copy `renderer.sync_active` to
`terminal.sync_active` after consumption for cleanup on failure.

## Scheduling and processes

Use `session.schedule` on the runner thread. `arm(id, at)` sets a one-shot at
an absolute awake-clock time in milliseconds; `cancel(id)` removes it. `watch`
borrows a descriptor and returns a unique identity for `.ready` events. Unwatch
before replacing or closing the fd. Readiness flags can include hangup and data
together. Keep I/O and callbacks bounded.

Custom loops use the same turns:

```zig
var schedule = tui.Schedule.init(io, &sources, &alarms);
// Register interests, then repeat each turn:
var turn = try schedule.prepare(&pollfds);
try schedule.wait(turn.interests, turn.deadline);
while (turn.nextReady()) |event| try app.ready(event);
turn.beginTimers(schedule.nowMs());
while (turn.nextTimer()) |id| try app.timer(id);
```

One turn borrows the schedule and poll slice. For extra descriptors reserve a
prefix, pass the suffix to `prepare`, and wait on the combined used slice at
the earliest chosen deadline. Watch identity suppresses stale readiness after
reuse. Timer delivery clears its slot first. Mutation suppresses a replaced due
timer; rearming from a timer callback schedules a future turn.

For cross-thread work, publish data under application synchronization and
`signal()` a `Notification`. Watch its fd, `consume()` the wakeup, then consume
published results. Unwatch, request termination, join publishers and deinit.

`PtyProcess.start(path,argv,env,size)` opens a child PTY and waits for the exec
handshake. Supply an explicit executable path and null-terminated vectors;
`prepareStrings` builds vectors in caller storage. Linux 5.11+ provides the
required pidfd, peer and close-range operations. Keep SIGCHLD waitable and let
the owner reap the child.

Watch `master` for output and `completion` for exit. `read` returns null to
retry and zero at EOF; `write` accepts a prefix. `collect` caches exit status.
The master can still have data after exit. `signalGroup` targets the initial
group while its leader remains unreaped. `pollChange` also observes stops and
continues. `waitUntil` and `killAndWait` take absolute deadlines; timeout retains
ownership. Unwatch before `closeMaster` or `deinit`. `deinit` kills and reaps
a live direct child before closing descriptors.

## Kitty graphics

`graphics.Sender.begin(command, bytes, response)` admits a transfer, placement,
delete, query or animation command. `transmission.medium` determines whether
bytes are direct data or a local file/shared-memory name. Supply `""` for a
command with no payload. The sender borrows bytes through completion. Write
`outputStep()` and acknowledge the actual count with `consumeOutput`. Direct
chunks encode at most 3072 source bytes. `cancel(selector)` queues a delete
after the exposed suffix. Drain while keeping the transport; `deinit` erases
local state after drain or disconnect.

Set `Options.graphics_sender` to serialize the sender with runner output.
`.screen_clear` grants a replay point after the clear and before text;
`.graphics_sent` acknowledges local transport. In a custom loop, enable
`clear_checkpoint` and pump the sender on a `.cleared` step,
or between frames. `frame.placeholder` paints virtual placements using protocol
RGB identifiers and image-cell coordinates 0–296.

Use image IDs below `0x80000000` when sharing the probe namespace. Match
`.reply.graphics` with `matches(ids)` and inspect `remoteError()`. Keep file and
shared-memory resources available until a correlated reply; request `.all` to
observe success. Applications own replay, retries and remote cleanup.

## Verification

```sh
zig fmt --check build.zig build.zig.zon src test bench examples
zig build test test-pty test-screen test-terminal test-stress -Dterminal-tests=true -j2
zig build test test-pty test-screen test-terminal test-stress -Dterminal-tests=true -Doptimize=ReleaseSafe -j2
python3 tools/unicode.py --check
zig build bench -Doptimize=ReleaseFast -- 1000 120 40
zig build bench-pty -Doptimize=ReleaseFast
```

PTY checks use Python 3; screen checks use libvterm and the pinned test-only
Ghostty engine. Unicode generation also accepts `--source-dir PATH`.
[Architecture](ARCHITECTURE.md) describes ownership, resource bounds and the
invariants exercised by these checks.
