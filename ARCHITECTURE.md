# Architecture

The application owns content, bindings, layout constraints, graphics resources and timing.
The runner owns one terminal session. All callbacks and terminal writes run on its thread.

| Owner | State and lifetime |
| --- | --- |
| [`Session`](src/run.zig) | Schedule, requested draw, lifecycle phase and completed-frame statistics; borrows terminal capability and keyboard state. Valid from `start` through `stop`. |
| [`Schedule`](src/schedule.zig) | Timer and watch slots in exclusive caller storage. Each watch borrows an fd. A polling turn borrows the schedule and its caller's poll records. |
| [`Terminal`](src/linux.zig) | TTY, original termios, optional signalfd and saved mask, command buffer and its accepted prefix. A supplied TTY stays caller-owned. |
| [`Parser`](src/input.zig) | Incomplete input framing and borrowed paste storage. Events lend payloads through delivery; owned events copy them. |
| [`Renderer`](src/screen.zig) | Committed and drawing grids, glyph arenas and one pending output chunk. `Frame` borrows the drawing grid. |
| [`Editor`](src/editor.zig) | Live and candidate documents, selection, journal records and payloads. `WrappedView` owns the visual caret and viewport. |
| [`Scrollback`](src/scrollback.zig) | Line slots in a ring; the tail stages incoming bytes. |
| [`Sender`](src/graphics/sender.zig) | Application-owned transfer: admitted header, remaining source slice and exposed output suffix. |

## A turn

`run` enters the terminal before `start`. Cleanup is armed first, so a partially
successful `start` has a matching `stop`. Workers inherit the runner's signal mask.
The application unwatches their descriptors and joins them in `stop`; terminal
restoration follows.

1. `Schedule.prepare` records the next watch ID as the turn's cutoff and fills poll interests.
   The runner adds the TTY and signalfd and waits until readiness or the earliest
   input, timer or shutdown deadline. Pending output requests immediate work or
   write readiness after backpressure.
2. Apply signals, size changes, input expiry and one TTY read. Decode input into
   events. `Terminal.observe` correlates protocol replies against accepted queries.
3. Deliver readiness for live registrations below that cutoff. Sample the clock, mark due
   timers, then clear each due slot before delivery. Replacing or cancelling a
   timer clears its mark. A timer armed during this batch waits for the next one.
4. Apply every callback result through `Session.dispatch`. Redraw requests coalesce;
   a repaint also invalidates the comparison grid. Advance one output operation.

Quit and suspension stop application dispatch and bound the drain of a submitted
frame or active transfer. Suspension restores terminal state before stopping the
process. Continuation reenters, discards partial input framing, checks dimensions
and repaints. Watch identities and absolute timer deadlines survive suspension.

## Ingestion and transactions

- [`Text`](src/text.zig) validates UTF-8, drawable grapheme width and cluster size.
  Its rows, clips and indexes borrow validated bytes. `StyledText` admits ordered
  span ends at grapheme boundaries. Drawing and hit-testing share the same
  segmentation and wrapping. [`geometry`](src/geometry.zig) supplies cell extents
  to input, layout, the renderer and PTYs. Weighted layouts admit both axes
  before writing caller storage.
- **Edit:** normalize the replacement into candidate storage, account for the
  retained suffix and validate the affected logical lines, including both joins.
  Compute record and byte capacity against the applied history prefix. Only
  after admission, evict complete oldest transactions, drop redo, append the
  record and swap documents. A first-record bit delimits each transaction.
  Undo replaces inserted bytes with removed bytes in reverse order; redo runs
  forward. Replay restores recorded selections even when an edit changed a
  grapheme boundary. Clear and teardown erase document and journal storage.
- **Scrollback:** accumulate one line in the tail slot and validate it at LF
  or EOF. Admission advances the tail and, at capacity, evicts the oldest
  line. Invalid and oversized lines reuse the same staging slot.
- **Process:** `PtyProcess.start` waits for a close-on-exec handshake. Its
  pidfd identifies the direct child; the PTY master independently carries
  output through EOF. An unreaped leader pins its initial process group.
  A timed-out wait leaves the descriptors and reaping obligation with the caller.
- **Publication:** a worker publishes under application synchronization, then
  signals a `Notification` eventfd. The runner drains the wakeup and consumes
  published data. Unwatch, stop and join publishers, then close the eventfd.

## One output stream

Mode commands, graphics APCs and frame bytes all use prefix acknowledgment.
The terminal records byte ends for saved modes and probes. One accepted entry
offset determines which modes to restore and which replies can be observed.
An acknowledged keyboard push owns one stack entry until leave.

`Renderer.begin` clears private drawing storage. Scalar glyphs fit in a cell;
multi-scalar glyphs borrow the frame arena. A wide head owns its continuation.
Writing either side repairs the pair. `submit` freezes the grid, and `step`
scans bounded runs. `consume(n)` advances the exposed suffix. After the last
acknowledgment the renderer commits by swapping grids. Cancellation drains
the exposed suffix and synchronized-output trailer, preserves the committed
grid and requests a full repaint.

Graphics owns the output stream between frames or after an acknowledged clear.
The sender validates a command and formats its header at admission; subsequent
steps encode bounded source chunks. Cancellation queues a delete behind the
already-exposed suffix. A completed send acknowledges local transport. The
application uses correlated replies to release backing resources and chooses
what to replay after a clear.

## Bounds and verification

| Resource | Bound |
| --- | --- |
| Renderer | `2 × (max_cells × @sizeOf(Cell) + cluster_bytes)` plus 16 KiB output and fixed state; default scan budget 4096 cells. |
| Editor | `2 × capacity + history_bytes` bytes and `history_records` records. Eviction moves the retained journal; replay moves one document suffix per record. |
| Scrollback | `(line_count + 1) × (line_bytes + @sizeOf(usize))` bytes. |
| Sender | 480-byte header, 4608-byte output; at most 3072 direct source bytes per chunk. |
| Poll turn | Linear scans of configured watch/timer slots; at most one delivery per slot, one 4096-byte TTY read and eight signal records. |
| PTY and notification | Two persistent fds per child; one fd per notification. |

Unicode corpora check segmentation. Transaction tests exercise admission failure,
short writes, cancellation and replay. Private PTYs check acquisition, callback
ordering, descriptor reuse, timer mutation and restoration under backpressure.
Mixed load exercises 1, 16 and 128 sources. Libvterm checks cells and styles;
Ghostty consumes fragmented streams and verifies terminal state and images.
See the [verification commands](README.md#verification) for both build modes
and the sparse and dense rendering benchmarks.

At 120×40 cells on this Linux x86-64 host, the ReleaseFast headless benchmark
(seven batches of 1000 frames) measured 10.4 µs/frame unchanged or with one
cell changed, 33.7 µs for dense ASCII, 103.6 µs for dense Unicode and
240.2 µs for per-cell style changes. Unchanged frames emitted zero bytes.
