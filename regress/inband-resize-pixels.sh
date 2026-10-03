#!/bin/sh

# In-band resize (mode 2048) when only the size of the terminal's cells in
# pixels changes: it is a resize, and the pane is told its new size. The test
# is the terminal: it sets the size tmux reads, in cells and pixels.

PATH=/bin:/usr/bin
TERM=screen

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)

python3 - "$TEST_TMUX" <<'PY'
import fcntl
import os
import select
import signal
import struct
import subprocess
import sys
import termios
import time

tmux = sys.argv[1]
label = "testA%d" % os.getpid()
server = [tmux, "-L" + label, "-f/dev/null"]
failed = False

def fail(msg):
    global failed
    print("FAIL: " + msg)
    failed = True

def run(*args):
    return subprocess.run(server + list(args), check=True,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout.decode()

def set_size(fd, rows, cols, xpixel, ypixel):
    fcntl.ioctl(fd, termios.TIOCSWINSZ,
        struct.pack("HHHH", rows, cols, cols * xpixel, rows * ypixel))

class Terminal:
    """A client attached in a pty whose master is the terminal."""

    def __init__(self, xda, xpixel, ypixel):
        self.xda = xda
        self.out = b""
        self.pid, self.fd = os.forkpty()
        if self.pid == 0:
            os.environ["TERM"] = "xterm-256color"
            os.environ.pop("TMUX", None)
            os.execv(tmux, server + ["attach"])
        set_size(self.fd, 10, 80, xpixel, ypixel)
        os.kill(self.pid, signal.SIGWINCH)
        os.set_blocking(self.fd, False)

    def answer(self, data):
        if b"\033[>q" in data and self.xda is not None:
            os.write(self.fd, b"\033P>|" + self.xda + b"\033\\")

    def pump(self, until, timeout=20):
        """Read what tmux writes, answering it, until until() is true."""
        end = time.time() + timeout
        while time.time() < end:
            if until():
                return True
            r, _, _ = select.select([self.fd], [], [], 0.05)
            if self.fd in r:
                try:
                    chunk = os.read(self.fd, 65536)
                except (BlockingIOError, OSError):
                    chunk = b""
                self.out += chunk
                self.answer(chunk)
        return until()

    def send(self, data):
        os.write(self.fd, data)

    def close(self):
        os.kill(self.pid, signal.SIGTERM)
        os.waitpid(self.pid, 0)
        os.close(self.fd)

def capture():
    return run("capturep", "-p").split("\n")[0].rstrip()

run("new", "-d", "-x80", "-y10", "exec sleep 1000")
run("set", "-g", "status", "off")

term = Terminal(None, 16, 32)
run("respawnp", "-k",
    "stty raw -echo; printf '\\033[?2048h'; exec cat -v")
want = "^[[48;10;80;320;1280t"
if not term.pump(lambda: capture() == want):
    fail("2048 report is %r, not %r" % (capture(), want))
set_size(term.fd, 10, 80, 9, 18)
os.kill(term.pid, signal.SIGWINCH)
want = "^[[48;10;80;320;1280t^[[48;10;80;180;720t"
if not term.pump(lambda: capture() == want):
    fail("after a pixel resize the pane has %r, not %r" % (capture(), want))
term.close()

run("kill-server")
sys.exit(1 if failed else 0)
PY
