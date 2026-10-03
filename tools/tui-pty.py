#!/usr/bin/env python3
"""Drive a TUI program under a real pty and dump the rendered screen.

`fx` renders inline, so a capture is the only honest way to see what a user
sees. This sets an explicit window size, feeds keystrokes with delays, and
prints the pane plus an ANSI-stripped text view.
"""
import argparse
import fcntl
import os
import pty
import re
import select
import signal
import struct
import sys
import termios
import time

ANSI = re.compile(rb"\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b[=>][ -~]*|\x1b[ -\/]*[@-~]")


def strip(data: bytes) -> str:
    return ANSI.sub(b"", data).decode("utf8", "replace")


def set_size(fd, rows, cols):
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--rows", type=int, default=30)
    ap.add_argument("--cols", type=int, default=100)
    ap.add_argument("--settle", type=float, default=1.5)
    ap.add_argument("--script", action="append", default=[],
                    help="KEYS[:WAIT] where KEYS is send-keys text (\\n Enter, \\t Tab, \\e Escape)")
    ap.add_argument("--raw", action="store_true", help="show escape codes")
    ap.add_argument("cmd", nargs=argparse.REMAINDER)
    args = ap.parse_args()

    cmd = args.cmd[1:] if args.cmd and args.cmd[0] == "--" else args.cmd
    if not cmd:
        ap.error("no command given")

    pid, fd = pty.fork()
    if pid == 0:
        os.environ["TERM"] = "xterm-256color"
        os.environ["COLUMNS"] = str(args.cols)
        os.environ["LINES"] = str(args.rows)
        os.execvp(cmd[0], cmd)

    set_size(fd, args.rows, args.cols)
    buf = bytearray()

    def pump(seconds):
        end = time.time() + seconds
        while time.time() < end:
            r, _, _ = select.select([fd], [], [], 0.1)
            if fd in r:
                try:
                    chunk = os.read(fd, 65536)
                except OSError:
                    return False
                if not chunk:
                    return False
                buf.extend(chunk)
        return True

    pump(args.settle)
    for step in args.script:
        if ":" in step:
            keys, _, wait = step.rpartition(":")
            wait = float(wait)
        else:
            keys, wait = step, args.settle
        os.write(fd, keys.encode().decode("unicode_escape").encode("latin1"))
        if not pump(wait):
            break

    try:
        os.kill(pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    os.waitpid(pid, 0)

    out = bytes(buf)
    if args.raw:
        sys.stdout.write(repr(out))
    else:
        sys.stdout.write(strip(out))
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
