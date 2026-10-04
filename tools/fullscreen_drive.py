#!/usr/bin/env python3
"""Drive the fx binary inside a real pty with a real window size.

script(1) allocates a pty but leaves the window size at 0x0, so fx refuses to
start with UnableToReadTerminalSize. This harness forks the binary onto a pty,
sets TIOCSWINSZ, drives it with keystrokes, and captures what it writes so the
alternate-screen and composer behavior can be asserted from a test.
"""

import fcntl
import os
import pty
import select
import signal
import struct
import subprocess
import sys
import termios
import time

BINARY = os.environ.get("FX_BIN", "./zig-out/bin/fx")


class PtySession:
    """A running fx process attached to a pty of a known size."""

    def __init__(self, binary=BINARY, cols=100, rows=30, env=None, args=None):
        self.cols = cols
        self.rows = rows
        self.output = bytearray()
        argv = [binary] + (args or [])

        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            os.environ["TERM"] = "xterm-256color"
            os.environ["COLUMNS"] = str(cols)
            os.environ["LINES"] = str(rows)
            if env:
                os.environ.update(env)
            try:
                os.execv(argv[0], argv)
            finally:
                os._exit(127)

        self._set_size(cols, rows)

    def _set_size(self, cols, rows):
        fcntl.ioctl(
            self.fd,
            termios.TIOCSWINSZ,
            struct.pack("HHHH", rows, cols, 0, 0),
        )

    def resize(self, cols, rows):
        """Resize the pty, which is how fx receives SIGWINCH."""
        self.cols, self.rows = cols, rows
        self._set_size(cols, rows)
        os.kill(self.pid, signal.SIGWINCH)

    def read_available(self, timeout=0.25):
        """Drain whatever is pending, returning False once the child exits."""
        deadline = time.monotonic() + timeout
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return True
            try:
                ready, _, _ = select.select([self.fd], [], [], remaining)
            except (OSError, ValueError):
                return False
            if not ready:
                return True
            try:
                chunk = os.read(self.fd, 65536)
            except OSError:
                return False
            if not chunk:
                return False
            self.output.extend(chunk)

    def send(self, data, settle=0.35):
        """Write raw bytes to the pty and let the app settle."""
        payload = data.encode() if isinstance(data, str) else data
        os.write(self.fd, payload)
        self.read_available(settle)

    def send_line(self, text, settle=0.5):
        self.send(text + "\r", settle)

    def wait(self, timeout=5.0):
        """Wait for exit, draining output. Returns the exit status."""
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            done, status = os.waitpid(self.pid, os.WNOHANG)
            if done:
                self.read_available(0.2)
                return os.waitstatus_to_exitcode(status)
            self.read_available(0.1)
        return None

    def close(self):
        try:
            os.kill(self.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        try:
            os.waitpid(self.pid, 0)
        except ChildProcessError:
            pass
        try:
            os.close(self.fd)
        except OSError:
            pass

    def text(self):
        return self.output.decode("utf-8", errors="replace")

    def enter_alt_screen(self):
        return b"\x1b[?1049h" in self.output

    def leave_alt_screen(self):
        return b"\x1b[?1049l" in self.output

    def write_cursor_position(self):
        """Position of the last reported hardware cursor, if any."""
        import re

        matches = re.findall(rb"\x1b\[(\d+);(\d+)H", self.output)
        if not matches:
            return None
        row, col = matches[-1]
        return int(row), int(col)


def main():
    session = PtySession(cols=100, rows=30, env={"HOME": os.environ.get("HOME", "/tmp")})
    try:
        time.sleep(1.0)
        session.read_available(1.0)
        print("=== startup ok:", "UnableToReadTerminalSize" not in session.text())
        session.send_line("/fullscreen")
        session.read_available(0.6)
        session.send_line("/quit")
        status = session.wait(6)
        print("=== exit status:", status)
        out = session.text()
        print("=== alt screen entered:", b"\x1b[?1049h" in session.output)
        print("=== output bytes:", len(out))
        tail = out[-400:].replace("\x1b", "<ESC>")
        print("=== tail:", repr(tail))
    finally:
        session.close()


if __name__ == "__main__":
    sys.exit(main() or 0)