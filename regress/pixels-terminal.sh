#!/bin/sh

# Mouse in pixels (mode 1016) against a terminal tmux can only learn about
# from its answers and its size. The test is the terminal: it answers tmux's
# queries as kitty or xterm would, sets the size tmux reads (in cells and
# pixels) and writes mouse reports.
#
# - kitty and ghostty send pixels from 0, xterm (and foot and WezTerm) from 1:
#   a pane in tmux gets them from 0 either way, as kitty sends them.
# - With the cell size unknown, a pane that asked for pixels gets the cell's
#   top left in the cell size tmux gave it, not the cell number.

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
        if b"\033[?1016$p" in data:
            os.write(self.fd, b"\033[?1016;2$y")

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
        # Leave a pane without the mouse for the next terminal.
        run("respawnp", "-k", "exec sleep 1000")
        os.kill(self.pid, signal.SIGTERM)
        os.waitpid(self.pid, 0)
        os.close(self.fd)

def capture():
    return run("capturep", "-p").split("\n")[0].rstrip()

# The pane asks for pixels; once it has them (and tmux has asked the
# terminal for them with pixels set), the terminal sends report.
def check_mouse(term, report, want, pixels):
    mark = len(term.out)
    run("respawnp", "-k",
        "stty raw -echo; printf '\\033[?1000h\\033[?1016h'; exec cat -v")
    if not term.pump(lambda: run("display", "-p", "#{mouse_pixels_flag}")
            == "1\n"):
        fail("pane did not ask for pixels")
        return
    if pixels and not term.pump(lambda: b"\033[?1016h" in term.out[mark:]):
        fail("tmux did not ask the terminal for pixels")
        return
    term.send(report)
    if not term.pump(lambda: capture() == want, timeout=10):
        fail("%r: pane got %r, not %r" % (report, capture(), want))

run("new", "-d", "-x80", "-y10", "exec sleep 1000")
run("set", "-g", "status", "off")

# kitty: pixels from 0.
term = Terminal(b"kitty(0.49.1)", 10, 20)
check_mouse(term, b"\033[<0;10;20M", "^[[<0;10;20M", True)
term.close()

# xterm: pixels from 1, so xterm's 11,21 is 10,20 from 0.
term = Terminal(b"XTerm(400)", 10, 20)
check_mouse(term, b"\033[<0;11;21M", "^[[<0;10;20M", True)
term.close()

# Cell size unknown (no pixels in the size, the CSI 14 t query unanswered):
# the terminal reports cells (it is not asked for pixels); cell 3,2 (from 0,
# 2,1) is at 2*16,1*32 in tmux's default cell size, which the pane was given.
term = Terminal(b"XTerm(400)", 0, 0)
check_mouse(term, b"\033[<0;3;2M", "^[[<0;32;32M", False)

term.close()

run("kill-server")
sys.exit(1 if failed else 0)
PY
