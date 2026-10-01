#!/bin/sh

# Answers to kitty graphics queries wait until the terminal has said whether
# it has the protocol: all of them then go (however long it took), answers
# after them wait behind them (also when a later request is answered first),
# an OK after DA1 still counts, and a terminal that answers nothing is given
# up on when tmux stops waiting for it or the client is suspended. A program
# stands in for the terminal.

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
label = "testA%d" % os.getpid()
server = [tmux, "-L" + label, "-f/dev/null"]
tmp = tempfile.mkdtemp()
QUERY = b"\033_Gi=4294967295,"
OK = b"\033_Gi=4294967295;OK\033\\"

def run(*args, check=True):
    return subprocess.run(server + list(args), check=check,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout.decode()

def attach():
    pid, fd = os.forkpty()
    if pid == 0:
        os.environ["TERM"] = "xterm-256color"
        os.environ.pop("TMUX", None)
        os.execl(tmux, tmux, "-L" + label, "-f/dev/null", "attach-session",
            "-t", "requests")
    os.set_blocking(fd, False)
    return pid, fd

# Read what tmux sends the terminal (so it is not held up) until f() is true.
def wait(fd, f, what, timeout=20):
    end = time.time() + timeout
    data = b""
    while time.time() < end:
        if f(data):
            return data
        r, _, _ = select.select([fd], [], [], 0.01)
        if fd in r:
            try:
                data += os.read(fd, 65536)
            except (BlockingIOError, OSError):
                pass
    raise AssertionError("timed out waiting for %s" % what)

def detach(pid, fd):
    os.kill(pid, signal.SIGHUP)
    os.waitpid(pid, 0)
    os.close(fd)
    end = time.time() + 20
    while run("list-clients", "-F", "x").strip() != "":
        if time.time() > end:
            raise AssertionError("client did not go")
        time.sleep(0.01)

def attached():
    return run("display-message", "-p", "-t", "requests",
        "#{session_attached}", check=False).strip() == "1"

# Panes that send what is in $1 when go appears, then read n bytes of answers
# into their out file.
def panes(name, sends, n):
    run("kill-pane", "-a", "-t", "requests:0.0")
    for i, send in enumerate(sends):
        out = "%s/%s%d" % (tmp, name, i)
        cmd = ("stty raw -echo min 0 time 100; "
            "while [ ! -e %s/%s ]; do sleep 0.01; done; "
            "printf '%s\\033]7;%s%d\\007'; "
            "dd bs=1 count=%d 2>/dev/null | cat -v >%s.tmp; mv %s.tmp %s; "
            "exec sleep 60" % (tmp, name, send, name, i, n, out, out, out))
        if i == 0:
            run("respawn-pane", "-k", "-t", "requests:0.0", cmd)
        else:
            run("split-window", "-d", "-t", "requests:0.0", cmd)

def parsed(name, count):
    paths = run("list-panes", "-t", "requests", "-F", "#{pane_path}").split()
    return paths == ["%s%d" % (name, i) for i in range(count)]

def result(fd, name, i):
    path = "%s/%s%d" % (tmp, name, i)
    wait(fd, lambda d: os.path.exists(path), "pane %s%d" % (name, i))
    with open(path, "rb") as f:
        return f.read()

# More than a second passes: a pane asks for a colour no one answers, then
# for DSR, whose answer comes when tmux gives up on the colour (after half a
# second); twice.
def probe(fd):
    out = "%s/probe" % tmp
    cmd = ("stty raw -echo min 0 time 100; for i in 1 2; do "
        "printf '\\033]4;1;?\\033\\\\\\033[5n'; "
        "dd bs=1 count=4 2>/dev/null >>%s.tmp; done; mv %s.tmp %s; "
        "exec sleep 60" % (out, out, out))
    run("new-window", "-d", "-n", "probe", "-t", "requests", cmd)
    wait(fd, lambda d: os.path.exists(out), "a second")
    os.unlink(out)
    run("kill-window", "-t", "requests:probe")

def q(i):
    return "\\033_Ga=q,i=%d,s=1,v=1,f=24;AAAA\\033\\\\" % i

run("kill-server", check=False)
run("new-session", "-d", "-x", "80", "-y", "24", "-s", "requests", "sleep 60")
pid = None
try:
    # Two panes ask before the terminal answers, which takes longer than
    # other answers are waited for: both are answered.
    panes("a", [q(41), q(42)], 12)
    pid, fd = attach()
    wait(fd, lambda d: QUERY in d and attached(), "attach")
    open("%s/a" % tmp, "w").close()
    wait(fd, lambda d: parsed("a", 2), "queries")
    probe(fd)
    os.write(fd, OK)
    for i, want in enumerate([b"^[_Gi=41;OK^[\\", b"^[_Gi=42;OK^[\\"]):
        got = result(fd, "a", i)
        if got != want:
            raise AssertionError("pane %d: %r, not %r" % (i, got, want))
    detach(pid, fd)
    pid = None

    # An OK after DA1 still counts.
    pid, fd = attach()
    wait(fd, lambda d: QUERY in d and attached(), "attach")
    os.write(fd, b"\033[?62;22c" + OK)
    wait(fd, lambda d: "kittygraphics" in run("list-clients", "-F",
        "#{client_termfeatures}"), "kittygraphics")
    detach(pid, fd)
    pid = None

    # A request after a held answer is answered first: its answer waits
    # behind the held one, which is kept.
    panes("b", [q(45) + "\\033]4;1;?\\033\\\\"], 38)
    pid, fd = attach()
    wait(fd, lambda d: QUERY in d and attached(), "attach")
    open("%s/b" % tmp, "w").close()
    wait(fd, lambda d: b"\033]4;1;?" in d and parsed("b", 1), "colour")
    os.write(fd, b"\033]4;1;rgb:0101/0202/0303\033\\")
    probe(fd)
    os.write(fd, OK)
    got = result(fd, "b", 0)
    want = b"^[_Gi=45;OK^[\\^[]4;1;rgb:0101/0202/0303^[\\"
    if got != want:
        raise AssertionError("after a colour: %r, not %r" % (got, want))
    detach(pid, fd)
    pid = None

    # A client suspended before its terminal answers: the held answer goes
    # (as not known to have the protocol) and the answer after it.
    panes("d", [q(46) + "\\033[5n"], 4)
    pid, fd = attach()
    wait(fd, lambda d: QUERY in d and attached(), "attach")
    open("%s/d" % tmp, "w").close()
    wait(fd, lambda d: parsed("d", 1), "query")
    run("suspend-client")
    got = result(fd, "d", 0)
    if got != b"^[[0n":
        raise AssertionError("suspended: %r" % got)
    os.kill(pid, signal.SIGCONT)
    detach(pid, fd)
    pid = None

    # A terminal that answers nothing: when tmux stops waiting (after five
    # seconds), there is no answer to the query and the answer after it goes.
    panes("c", [q(43) + "\\033[5n"], 4)
    pid, fd = attach()
    wait(fd, lambda d: QUERY in d and attached(), "attach")
    open("%s/c" % tmp, "w").close()
    wait(fd, lambda d: parsed("c", 1), "query")
    got = result(fd, "c", 0)
    if got != b"^[[0n":
        raise AssertionError("no answer: %r" % got)
finally:
    if pid is not None:
        os.kill(pid, signal.SIGHUP)
    run("kill-server", check=False)
PY
