#!/bin/sh

# How kitty graphics images reach each client's terminal: a client attached
# later, one found to take images later, one suspended while an image was
# made and one that fell behind (so tmux dropped its output) are all given
# the images; and image data queued for a slow terminal stays within a
# budget, so the server does not grow. Programs stand in for the terminals.

PATH=/bin:/usr/bin
TERM=screen

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)

python3 - "$TEST_TMUX" <<'PY'
import os
import select
import signal
import subprocess
import sys
import tempfile
import time

tmux = sys.argv[1]
tmp = tempfile.mkdtemp()
OK = b"\033_Gi=4294967295;OK\033\\"

class Server:
    def __init__(self, name, features):
        self.cmd = [tmux, "-Ltest%s%d" % (name, os.getpid()), "-f/dev/null"]
        self.run("kill-server", check=False)
        self.run("new-session", "-d", "-x", "80", "-y", "24", "-s", "d",
            "exec sleep 1000")
        self.run("set", "-g", "status", "off")
        if features:
            self.run("set", "-as", "terminal-features", ",*:kittygraphics")
        self.pid = int(self.run("display", "-p", "#{pid}").strip())

    def run(self, *args, check=True):
        return subprocess.run(self.cmd + list(args), check=check,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout.decode()

    def rss(self):
        with open("/proc/%d/status" % self.pid) as f:
            for line in f:
                if line.startswith("VmRSS:"):
                    return int(line.split()[1]) * 1024

    # Run $1 in the pane and wait until it has been parsed.
    def pane(self, terms, send, mark):
        self.run("respawn-pane", "-k", "-t", "d:0.0",
            "printf '%s\\033]7;%s\\007'; exec sleep 1000" % (send, mark))
        pump(terms, lambda: self.run("display", "-p", "-t", "d:0.0",
            "#{pane_path}").strip() == mark, "pane " + mark)

    def kill(self):
        self.run("kill-server", check=False)

# A terminal: a client in a pty. It reads what tmux sends it (all of it, or
# n bytes each time it is pumped).
class Term:
    def __init__(self, server, n=None):
        self.server = server
        self.n = n
        self.data = b""
        self.pid, self.fd = os.forkpty()
        if self.pid == 0:
            os.environ["TERM"] = "xterm-256color"
            os.environ.pop("TMUX", None)
            os.execv(tmux, server.cmd + ["attach", "-t", "d"])
        os.set_blocking(self.fd, False)
        pump([self], lambda: self.name() is not None, "attach")

    def name(self):
        for line in self.server.run("list-clients", "-F",
            "#{client_pid} #{client_name}").splitlines():
            pid, name = line.split(" ", 1)
            if int(pid) == self.pid:
                return name
        return None

    def read(self):
        try:
            while True:
                b = os.read(self.fd, self.n or 1048576)
                if not b:
                    break
                self.data += b
                if self.n is not None:
                    break
        except (BlockingIOError, OSError):
            pass

    def close(self):
        for sigs in ((signal.SIGCONT, signal.SIGHUP), (signal.SIGKILL,)):
            for sig in sigs:
                try:
                    os.kill(self.pid, sig)
                except OSError:
                    pass
            end = time.time() + 2
            while time.time() < end:
                if os.waitpid(self.pid, os.WNOHANG)[0] != 0:
                    os.close(self.fd)
                    return
                time.sleep(0.01)

# Read for terminals until f() is true.
def pump(terms, f, what, timeout=30):
    end = time.time() + timeout
    while time.time() < end:
        if f():
            return
        select.select([t.fd for t in terms], [], [], 0.01)
        for t in terms:
            t.read()
    raise AssertionError("timed out waiting for %s" % what)

def image(i, pixel):
    return "\\033_Ga=t,q=2,i=%d,f=24,s=1,v=1;%s\\033\\\\" % (i, pixel)

def has(t, pixel, since=0):
    return (b"f=24,s=1,v=1,m=0;" + pixel.encode()) in t.data[since:]

terms = []
servers = []
try:
    s = Server("P", True)
    servers.append(s)

    # A client attached after an image was made is given it.
    a = Term(s)
    terms.append(a)
    s.pane([a], image(1, "/wAA"), "a")
    pump([a], lambda: has(a, "/wAA"), "first client given image")
    b = Term(s)
    terms.append(b)
    pump([a, b], lambda: has(b, "/wAA"), "client attached later given image")

    # A client suspended while an image is made is given it when it comes
    # back.
    s.run("suspend-client", "-t", a.name())
    since = len(a.data)
    s.pane([b], image(2, "AAD/"), "c")
    pump([b], lambda: has(b, "AAD/"), "other client given image")
    os.kill(a.pid, signal.SIGCONT)
    pump([a, b], lambda: has(a, "AAD/", since), "client resumed given image")

    # A client whose output was dropped (it fell behind while a pane wrote
    # a lot) is given an image made then once it catches up.
    s.run("split-window", "-d", "-t", "d:0.0", "exec yes xxxxxxxxxxxxxxxx")
    a.n = 4096
    pump([a, b], lambda: int(s.run("display", "-p", "-c", a.name(),
        "#{client_discarded}").strip()) > 0, "dropped")
    s.pane([a, b], image(3, "//8A"), "d")
    s.run("kill-pane", "-t", "d:0.1")
    a.n = None
    pump([a, b], lambda: has(a, "//8A"), "client caught up given image")
    for t in terms:
        t.close()
    terms = []
    s.kill()

    # A client found to take images (by its answer) is given those made.
    s = Server("Q", False)
    servers.append(s)
    a = Term(s)
    terms.append(a)
    pump([a], lambda: b"\033_Gi=4294967295," in a.data, "query")
    os.write(a.fd, OK)
    pump([a], lambda: "kittygraphics" in s.run("list-clients", "-F",
        "#{client_termfeatures}"), "feature")
    s.pane([a], image(1, "AP8A"), "e")
    b = Term(s)
    terms.append(b)
    pump([a, b], lambda: b"\033_Gi=4294967295," in b.data, "query")
    os.write(b.fd, OK)
    pump([a, b], lambda: has(b, "AP8A"), "client found to take images")
    for t in terms:
        t.close()
    terms = []
    s.kill()

    # A slow terminal: twenty images of 4 MB (5.3 MB as base64) are not all
    # queued for it, but it is given the last when it has caught up.
    s = Server("R", True)
    servers.append(s)
    big = "%s/big-tty" % tmp
    with open(big, "wb") as f:
        f.write(b"\0" * (4 * 1024 * 1024))
    a = Term(s, 65536)
    terms.append(a)
    before = s.rss()
    name = subprocess.run(["base64", "-w0"], input=big.encode(),
        stdout=subprocess.PIPE).stdout.decode()
    send = ("\\033_Ga=t,q=2,i=1,f=24,s=1024,v=1024,t=f;%s\\033\\\\" % name) * 20
    s.pane([a], send, "f")
    grown = s.rss() - before
    if grown > 48 * 1024 * 1024:
        raise AssertionError("server grew %d MB for a slow terminal" %
            (grown // 1048576))
    a.n = None
    pump([a], lambda: a.data.count(b"\033_Gm=0,q=2;") >= 1, "big image")
finally:
    for s in servers:
        s.kill()
    for t in terms:
        t.close()
PY
