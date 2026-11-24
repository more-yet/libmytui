# Architecture

## One thread owns the terminal

[`run`](src/run.zig) allocates the session storage, enters the terminal, calls
`start`, and runs the event loop. Every callback and terminal write runs on
this thread. `stop` releases application resources before terminal restoration,
including after a failed `start`.

| Owner | State |
| --- | --- |
| Application | Model, layout, bindings, worker lifetimes and graphics resources. |
| Loop | Input parser, lifecycle phase, redraw request and current output work. |
| Session | Schedule and last committed frame statistics; lends access to terminal capabilities and desired keyboard flags. |
| [Terminal](src/terminal.zig) | TTY modes, saved termios, signal mask, probe correlation and mode-command acknowledgments. |
| [Schedule](src/schedule.zig) | Bounded timer and watch slots; each watch borrows its fd. |
| [Renderer](src/screen.zig) | Two cell grids, their glyph arenas and one output buffer. |

Each turn waits for the TTY, signals, registered fds or the earliest deadline.
The loop applies signals and resize, expires input framing and feeds one TTY
read to the [parser](src/input.zig). It dispatches readiness, samples the clock
for due timers, then advances output. Callbacks may change registrations:
a turn's watch-ID cutoff excludes replacements, and timer delivery releases
each slot before calling the application. Redraw requests coalesce.

Suspension and shutdown stop dispatch and bound the output drain. Suspension
restores the terminal before stopping the process; continuation reenters,
resets input framing, samples the size and repaints.

## Text admission and storage

[`Text`](src/text.zig) borrows immutable UTF-8. Admission establishes drawable
widths and a maximum cluster size. Rows, clips and indexes preserve grapheme
boundaries; layout and drawing use the same iterator. An indexed view borrows
both the bytes and its row storage. Style spans are admitted against that text.

An [editor](src/editor.zig) stages replacements in a second document buffer.
Joining two valid fragments can change grapheme boundaries across the edited
line. The editor scans the affected lines, resolves the resulting caret and
reserves journal space before swapping the documents. Eviction drops whole
transactions; replay restores the recorded selection. Failed admission leaves
the live document and history intact.

[Scrollback](src/scrollback.zig) stages input in the ring's spare slot. LF or
EOF triggers validation. A successful commit publishes that slot and rotates
the ring; a rejected line reuses the slot.

## Output ownership transfers on acknowledgment

Between frames the loop services mode commands, graphics and drawing in that
order. A short write leaves its suffix with the same producer. Backpressure
adds write readiness to the next poll; input and scheduled work remain live.

- **Modes:** accepted byte offsets identify which saves, pushes and probes
  reached the terminal. Those offsets determine restoration and reply matching.
- **Frames:** a wide cell owns its continuation. Drawing repairs the pair when
  either half changes. Submission freezes the drawing grid. The renderer scans
  bounded runs and commits by swapping grids after the final acknowledgment.
  Cancellation drains exposed bytes, closes synchronized output and invalidates
  the next comparison.
- **Graphics:** the [sender](src/graphics.zig) admits the command header and
  borrows the source. It encodes one bounded chunk at a time. An acknowledged
  clear can lend the stream to graphics before text resumes. Cancellation
  queues a delete behind the exposed suffix.

## Descriptor lifetimes

A [PTY process](src/process.zig) owns its direct child, pidfd and PTY master.
The close-on-exec handshake completes startup. Exit readiness and PTY EOF can
arrive in either order. An unreaped leader pins its initial process group;
reaping releases that identity.

A worker publishes data under application synchronization, then signals a
[notification](src/linux.zig). The application unwatches before closing a
descriptor and joins publishers before releasing their notification or data.
