"""End-to-end terminal ownership, interruption, and backpressure checks."""
import errno
import fcntl
import json
import os
import pathlib
import re
import select
import signal
import struct
import subprocess
import sys
import termios
import time


class Child:
    def __init__(self, program, *args, size=(80, 24), report=False):
        self.master, self.slave = os.openpty()
        self.report = None
        if report:
            self.report, report_write = os.pipe()
            os.set_inheritable(report_write, True)
            args = (args[0], str(report_write), *args[1:])
        self.original = termios.tcgetattr(self.slave)
        self.resize(*size)
        self.pid = os.fork()
        if self.pid == 0:
            os.setsid()
            signal.pthread_sigmask(signal.SIG_BLOCK, [signal.SIGUSR1])
            fcntl.ioctl(self.slave, termios.TIOCSCTTY, 0)
            for fd in range(3):
                os.dup2(self.slave, fd)
            os.close(self.master)
            os.close(self.slave)
            if report:
                os.close(self.report)
            os.execv(program, [program, *args])
        if report:
            os.close(report_write)
        os.set_blocking(self.master, False)
        self.output = bytearray()
        self.reaped = False

    def resize(self, width, height):
        fcntl.ioctl(self.slave, termios.TIOCSWINSZ, struct.pack("HHHH", height, width, 0, 0))

    def proc_fields(self, name):
        return dict(line.split(":", 1) for line in pathlib.Path(f"/proc/{self.pid}/{name}").read_text().splitlines())

    def usage(self):
        ticks = 0
        for path in pathlib.Path(f"/proc/{self.pid}/task").glob("*/stat"):
            fields = path.read_text().rsplit(")", 1)[1].split()
            ticks += int(fields[11]) + int(fields[12])
        io = self.proc_fields("io")
        status = self.proc_fields("status")
        return {
            "cpu_ns": ticks * 1_000_000_000 // os.sysconf("SC_CLK_TCK"),
            "reads": int(io["syscr"]), "writes": int(io["syscw"]),
            "rss_kib": int(status["VmRSS"].split()[0]),
            "peak_rss_kib": int(status["VmHWM"].split()[0]),
        }

    def read(self):
        try:
            self.output.extend(os.read(self.master, 65536))
        except BlockingIOError:
            pass
        except OSError as error:
            if error.errno != errno.EIO:
                raise

    def until(self, predicate, timeout=3, read_output=True):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if read_output:
                self.read()
            if predicate():
                return
            select.select([self.master] if read_output else [], [], [], 0.01)
        raise AssertionError(f"timeout: {self.output[-1000:]!r}")

    def ready(self):
        self.until(lambda: b"\x1b[?2004h" in self.output and b"\x1b[2J" in self.output)
        assert not termios.tcgetattr(self.slave)[3] & termios.ICANON

    def finish(self, success=True, entered=True, drain=True):
        status = None

        def exited():
            nonlocal status
            pid, status = os.waitpid(self.pid, os.WNOHANG)
            self.reaped = bool(pid)
            return self.reaped

        self.until(exited, read_output=drain)
        self.read()
        assert os.WIFEXITED(status), status
        assert os.WEXITSTATUS(status) == (0 if success else 1), (status, self.output[-2000:])
        assert termios.tcgetattr(self.slave) == self.original
        if entered and drain:
            assert b"\x1b[?25h\x1b[?1049l" in self.output
        elif not entered:
            assert b"\x1b[?2004h" not in self.output

    def stopped(self):
        def is_stopped():
            pid, status = os.waitpid(self.pid, os.WNOHANG | os.WUNTRACED)
            if pid:
                self.reaped = not os.WIFSTOPPED(status)
                assert os.WIFSTOPPED(status), status
            return bool(pid)

        self.until(is_stopped)

    def close(self):
        if not self.reaped:
            os.kill(self.pid, signal.SIGKILL)
            os.waitpid(self.pid, 0)
        os.close(self.master)
        os.close(self.slave)
        if self.report is not None:
            os.close(self.report)


fixture = sys.argv[1]
if sys.argv[2:3] == ["--terminal"]:
    for mode in ("idle", "worker", "start_error_worker", "draw_error", "resume"):
        child = Child(fixture, mode)
        try:
            if mode in ("start_error_worker", "draw_error"):
                child.finish(success=False)
            else:
                child.ready()
                if mode == "resume":
                    os.write(child.master, b"\x1a")
                    child.stopped()
                    os.kill(child.pid, signal.SIGCONT)
                    child.until(lambda: child.output.count(b"\x1b[?2004h") == 2)
                os.write(child.master, b"q")
                child.finish()
            for initial_mode in ("on", "off"):
                subprocess.run([sys.argv[3], initial_mode], input=child.output, check=True, timeout=10)
        finally:
            child.close()
    print("Ghostty verified runner entry, exit, partial startup, failure, suspension, and saved grapheme mode")
    sys.exit(0)

if sys.argv[2:] == ["--mixed"]:
    for sources in (1, 16, 128):
        for blocked in (False, True):
            child = Child(fixture, "mixed", str(sources), "blocked" if blocked else "drained",
                          size=(240, 80), report=True)
            try:
                child.ready()
                started = time.monotonic()
                next_resize = started + 0.05
                sent = 0
                while time.monotonic() - started < 1.0:
                    try:
                        sent += os.write(child.master, b"r" * 4096)
                    except BlockingIOError:
                        pass
                    now = time.monotonic()
                    if now >= next_resize:
                        child.resize(240 if int((now - started) * 20) & 1 else 200, 80)
                        next_resize = now + 0.05
                    if not blocked and int((now - started) * 20) & 1:
                        child.read()
                        child.output.clear()
                    select.select([], [], [], 0.001)
                before_stop = time.perf_counter_ns()
                os.kill(child.pid, signal.SIGTERM)
                child.finish(success=not blocked, drain=not blocked)
                shutdown_ns = time.perf_counter_ns() - before_stop
                report = json.loads(os.read(child.report, 4096))
                assert report["input_events"] > 0
                assert report["resizes"] > 0
                assert report["deadlines"] >= 20, report
                assert report["minimum_ready_per_source"] >= 2, report
                assert report["deadline_max_ms"] < 500, report
                assert shutdown_ns < 2_000_000_000, shutdown_ns
                print(json.dumps(dict(report, blocked=blocked, sent=sent, shutdown_ns=shutdown_ns)))
            finally:
                child.close()
    sys.exit(0)

if sys.argv[2:] == ["--bench"]:
    for mode, key in (("idle", b"r"), ("worker", b"w")):
        child = Child(fixture, mode)
        try:
            child.until(lambda: b"AAAAAA" in child.output)
            child.until(lambda: child.proc_fields("status")["State"].strip().startswith("S"))
            idle_switches = int(child.proc_fields("status")["voluntary_ctxt_switches"])
            time.sleep(0.25)
            idle_switches = int(child.proc_fields("status")["voluntary_ctxt_switches"]) - idle_switches
            samples = []
            io_before = child.proc_fields("io")
            for iteration in range(1050):
                child.output.clear()
                marker = b"BBBBBB" if iteration % 2 == 0 else b"AAAAAA"
                started = time.perf_counter_ns()
                os.write(child.master, key)
                child.until(lambda: marker in child.output)
                elapsed = time.perf_counter_ns() - started
                if iteration >= 50:
                    samples.append(elapsed)
            io_after = child.proc_fields("io")
            status = child.proc_fields("status")
            samples.sort()
            os.write(child.master, b"q")
            child.finish()
            print(json.dumps({
                "scenario": "key_to_output" if mode == "idle" else "key_worker_to_output",
                "width": 80, "height": 24, "samples": len(samples),
                "p50_ns": samples[len(samples) // 2],
                "p99_ns": samples[len(samples) * 99 // 100], "max_ns": samples[-1],
                "idle_switches_250ms": idle_switches,
                "reads_per_event": (int(io_after["syscr"]) - int(io_before["syscr"])) / 1050,
                "writes_per_event": (int(io_after["syscw"]) - int(io_before["syscw"])) / 1050,
                "rss_kib": int(status["VmRSS"].split()[0]),
            }))
        finally:
            child.close()
    for mode, key, batch in (("load_input", b"r", 2048), ("load_worker", b"w", 256),
                             ("load_blocked", b"r", 1)):
        blocked = mode == "load_blocked"
        size = (240, 80) if blocked else (80, 24)
        child = Child(fixture, mode, size=size)
        try:
            child.until(lambda: b"Completed: 0!" in child.output)
            for warmup in range(50):
                child.output.clear()
                assert os.write(child.master, key * batch) == batch
                marker = f"Completed: {(warmup + 1) * batch}!".encode()
                child.until(lambda: marker in child.output)
            samples = []
            before = child.usage()
            started = time.perf_counter_ns()
            batches = 0
            stalled_writes = 0
            stalled_cpu_ns = 0
            while batches < 100 or (batches < 1_000_000 and time.perf_counter_ns() - started < 2_000_000_000):
                child.output.clear()
                sent = time.perf_counter_ns()
                assert os.write(child.master, key * batch) == batch
                if blocked:
                    time.sleep(0.01)
                    stalled_before = child.usage()
                    time.sleep(0.01)
                    stalled_after = child.usage()
                    stalled_writes += stalled_after["writes"] - stalled_before["writes"]
                    stalled_cpu_ns += stalled_after["cpu_ns"] - stalled_before["cpu_ns"]
                batches += 1
                marker = f"Completed: {(batches + 50) * batch}!".encode()
                child.until(lambda: marker in child.output)
                samples.append(time.perf_counter_ns() - sent)
            elapsed = time.perf_counter_ns() - started
            after = child.usage()
            samples.sort()
            os.write(child.master, b"q")
            child.finish()
            print(json.dumps({
                "scenario": mode, "width": size[0], "height": size[1],
                "batch_events": batch, "batches": batches, "events": batches * batch,
                "elapsed_ns": elapsed, "events_per_second": batches * batch * 1e9 / elapsed,
                "batch_p50_ns": samples[len(samples) // 2],
                "batch_p99_ns": samples[len(samples) * 99 // 100], "batch_max_ns": samples[-1],
                "cpu_ns": after["cpu_ns"] - before["cpu_ns"],
                "reads": after["reads"] - before["reads"],
                "writes": after["writes"] - before["writes"],
                "rss_before_kib": before["rss_kib"], "rss_after_kib": after["rss_kib"],
                "peak_rss_kib": after["peak_rss_kib"],
                "stalled_writes": stalled_writes, "stalled_cpu_ns": stalled_cpu_ns,
            }))
        finally:
            child.close()
    sys.exit(0)

for action in ("q", "ctrl_c", "signal", "resize", "suspend", "suspend_resize", "paste", "idle"):
    child = Child(fixture, "idle")
    try:
        child.ready()
        if action == "signal":
            os.kill(child.pid, signal.SIGTERM)
        elif action == "ctrl_c":
            os.write(child.master, b"\x03")
        else:
            if action == "resize":
                child.resize(100, 30)
                child.until(lambda: child.output.count(b"\x1b[2J") >= 2)
            elif action in ("suspend", "suspend_resize"):
                os.write(child.master, b"\x1a")
                child.stopped()
                assert termios.tcgetattr(child.slave) == child.original
                if action == "suspend_resize":
                    child.resize(100, 30)
                os.kill(child.pid, signal.SIGCONT)
                child.until(lambda: child.output.count(b"\x1b[?2004h") >= 2)
                if action == "suspend_resize":
                    child.until(lambda: b"Resizes: 1" in child.output)
            elif action == "paste":
                # Literal q inside bracketed paste remains text, even across fragments.
                child.until(lambda: b"AAAAAA" in child.output)
                start = len(child.output)
                for fragment in (b"\x1b[20", b"0~qqq\x1b", b"[201~"):
                    os.write(child.master, fragment)
                os.write(child.master, b"r")
                child.until(lambda: b"BBBBBB" in child.output[start:])
                assert os.waitpid(child.pid, os.WNOHANG)[0] == 0
            elif action == "idle":
                child.until(lambda: child.proc_fields("status")["State"].strip().startswith("S"))
                switches = int(child.proc_fields("status")["voluntary_ctxt_switches"])
                time.sleep(0.2)
                assert int(child.proc_fields("status")["voluntary_ctxt_switches"]) == switches, "idle runner woke without an event"
            os.write(child.master, b"q")
        child.finish()
    finally:
        child.close()

child = Child(fixture, "graphics")
try:
    child.ready()
    child.until(lambda: b"QUJDRA==\x1b\\" in child.output)
    os.write(child.master, b"i")
    child.until(lambda: child.output.count(b"QUJDRA==\x1b\\") == 2)
    os.write(child.master, b"q")
    child.finish()
    for repaint in child.output.split(b"\x1b[2J")[1:]:
        assert repaint.startswith(b"\x1b_Ga=t,") and b"i=123" in repaint.split(b";", 1)[0]
finally:
    child.close()

child = Child(fixture, "protocols")
try:
    child.ready()
    assert b"\x1b[?u" in child.output and b"\x1b[?2026$p" in child.output
    assert b"\x1b[>31u" not in child.output and b"\x1b[?2026h" not in child.output
    image_id = re.search(rb"\x1b_Gi=(\d+),a=q", child.output)[1]
    os.write(child.master, b"\x1b_Gi=1;OK\x1b\\\x1b[?0u\x1b[?2026;2$y\x1b_Gi=" + image_id + b";OK\x1b\\r")
    child.until(lambda: b"\x1b[>31u" in child.output and b"\x1b[?2026l" in child.output)
    frame = child.output.split(b"\x1b[?2026h", 1)[1].split(b"\x1b[?2026l", 1)[0]
    assert frame and b"\x1b[>31u" not in frame
    os.write(child.master, b"\x1b[113;1:3u\x1b[114u")
    child.until(lambda: child.output.count(b"\x1b[?2026h") >= 2)
    os.write(child.master, b"\x1a")
    child.stopped()
    child.read()
    assert b"\x1b[<u" in child.output and b"\x1b[?1003l" in child.output and b"\x1b[?1004l" in child.output
    os.kill(child.pid, signal.SIGCONT)
    child.until(lambda: child.output.count(b"\x1b[?2026$p") == 2)
    os.write(child.master, b"q")
    child.finish()
    assert child.output.count(b"\x1b[>31u") == child.output.count(b"\x1b[<u") == 1
finally:
    child.close()

for mode in ("start_error_empty", "start_error_pipe", "start_error_worker", "draw_error",
             "update_error", "capacity", "watch_capacity", "process_capacity", "ready_error"):
    child = Child(fixture, mode)
    try:
        child.finish(success=False)
    finally:
        child.close()

child = Child(fixture, "initial_capacity")
try:
    child.finish(success=False, entered=False)
finally:
    child.close()

for mode in ("stop_priority", "resume_quit", "resume", "resize_capacity", "slow_deadline", "reopen"):
    child = Child(fixture, mode)
    try:
        child.ready()
        if mode == "stop_priority":
            # Queue lifecycle signals together so quit must precede resize delivery.
            os.kill(child.pid, signal.SIGSTOP)
            child.stopped()
            child.resize(100, 30)
            os.kill(child.pid, signal.SIGTERM)
            os.kill(child.pid, signal.SIGTSTP)
            os.kill(child.pid, signal.SIGCONT)
        elif mode == "resume_quit":
            os.write(child.master, b"\x1a")
            child.stopped()
            assert termios.tcgetattr(child.slave) == child.original
            os.kill(child.pid, signal.SIGTERM)
            os.kill(child.pid, signal.SIGCONT)
        elif mode == "resume":
            for cycle in range(1, 4):
                os.write(child.master, b"\x1a")
                child.stopped()
                assert termios.tcgetattr(child.slave) == child.original
                child.resize(80 + cycle, 24 + cycle)
                os.kill(child.pid, signal.SIGCONT)
                child.until(lambda: f"Draws: {cycle + 1}".encode() in child.output)
                child.until(lambda: child.proc_fields("status")["State"].strip().startswith("S"))
                child.read()
                assert child.output.count(b"\x1b[2J") == cycle + 1, "resume must coalesce into one repaint"
                assert f"Resizes: {cycle}".encode() in child.output
            os.write(child.master, b"\x03")
        elif mode == "resize_capacity":
            child.resize(300, 300)
        elif mode == "reopen":
            child.until(lambda: b"ready" in child.output)
            assert child.output.count(b"\x1b[?2004h") == 2
            os.write(child.master, b"\x03")
        child.finish(success=mode != "resize_capacity")
    finally:
        child.close()

child = Child(fixture, "blocked_resize", size=(240, 80))
try:
    child.ready()
    # Keep the large initial frame blocked while input and resize request its successor.
    assert os.write(child.master, b"r" * 200) == 200
    child.resize(100, 30)
    time.sleep(0.1)
    child.until(lambda: b"Changes: 200" in child.output and b"Draws: 2" in child.output)
    os.write(child.master, b"\x03")
    child.finish()
    assert child.output.count(b"\x1b[2J") == 2, "blocked redraw requests must coalesce"
    assert b"Resizes: 1" in child.output
finally:
    child.close()

for mode in ("deadline_past", "deadline_rearm", "watch_reuse", "write_ready", "hangup_ready", "process"):
    child = Child(fixture, mode)
    try:
        child.finish()
    finally:
        child.close()

for mode in ("deadline_cancel", "deadline_replace", "deadline_resume"):
    child = Child(fixture, mode)
    try:
        child.ready()
        if mode == "deadline_cancel":
            os.write(child.master, b"ac")
            time.sleep(0.2)
            child.read()
            assert b"Deadline" not in child.output
        elif mode == "deadline_replace":
            os.write(child.master, b"ab")
            time.sleep(0.15)
            child.read()
            assert b"Deadline" not in child.output, "replacement retained the old deadline"
            child.until(lambda: b"Deadline 1" in child.output)
        else:
            os.write(child.master, b"a\x1a")
            child.stopped()
            time.sleep(0.15)
            os.kill(child.pid, signal.SIGCONT)
            child.until(lambda: b"Deadline 1" in child.output)
        child.until(lambda: child.proc_fields("status")["State"].strip().startswith("S"))
        switches = int(child.proc_fields("status")["voluntary_ctxt_switches"])
        time.sleep(0.2)
        assert int(child.proc_fields("status")["voluntary_ctxt_switches"]) == switches, "one-shot deadline remained armed"
        os.write(child.master, b"q")
        child.finish()
    finally:
        child.close()

for mode in ("worker", "worker_blocked", "worker_quit"):
    child = Child(fixture, mode, size=(240, 80) if mode == "worker_blocked" else (80, 24))
    try:
        child.ready()
        os.write(child.master, b"wq" if mode == "worker_quit" else b"w")
        if mode != "worker_quit":
            if mode == "worker_blocked":
                time.sleep(0.15)
            child.until(lambda: b"BBBBBB" in child.output)
            child.until(lambda: child.proc_fields("status")["State"].strip().startswith("S"))
            switches = int(child.proc_fields("status")["voluntary_ctxt_switches"])
            time.sleep(0.15)
            assert int(child.proc_fields("status")["voluntary_ctxt_switches"]) == switches, "drained notification kept waking the loop"
            os.write(child.master, b"q")
        child.finish()
    finally:
        child.close()

child = Child(fixture, "flood")
try:
    child.ready()
    # Stop draining output so the terminal's queue applies backpressure.
    time.sleep(0.25)
    writes = int(child.proc_fields("io")["syscw"])
    time.sleep(0.2)
    assert int(child.proc_fields("io")["syscw"]) == writes, "timer events retried blocked output"
    os.kill(child.pid, signal.SIGTERM)
    time.sleep(1.2)
    pid, status = os.waitpid(child.pid, os.WNOHANG)
    assert pid == child.pid, "shutdown must finish while output is blocked"
    child.reaped = True
    assert os.WIFEXITED(status)
    assert os.WEXITSTATUS(status) == 1, "output failure must preserve its error after worker cleanup"
    assert termios.tcgetattr(child.slave) == child.original
finally:
    child.close()

print("PTY lifecycle, deadlines, descriptor reuse, worker wakeup/cleanup, resize, suspension, paste, failure, idle wakeup, and backpressure checks passed")
