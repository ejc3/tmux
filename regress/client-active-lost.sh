#!/bin/sh

# A client lost while a key it pressed runs a job that waits, with more keys
# queued behind it: those keys are handled as the client goes, but a client
# that has gone never becomes the latest, so losing it fires no client-active
# (tmux made it latest as its keys were handled, then the live client again).

PATH=/bin:/usr/bin
TERM=screen

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)

python3 - "$TEST_TMUX" <<'PY'
import os, signal, subprocess, sys, tempfile, time

tmux = sys.argv[1]
tmp = tempfile.mkdtemp()
server = [tmux, "-Ltest%d" % os.getpid(), "-f/dev/null"]

def run(*args):
    return subprocess.run(server + list(args), stdout=subprocess.PIPE,
        stderr=subprocess.PIPE).stdout.decode()

def wait(f, what):
    end = time.time() + 20
    while time.time() < end:
        if f():
            return
        time.sleep(0.02)
    print("FAIL: timed out waiting for " + what)
    run("kill-server")
    sys.exit(1)

class Client:
    def __init__(self):
        self.pid, self.fd = os.forkpty()
        if self.pid == 0:
            os.environ["TERM"] = "screen"
            os.environ.pop("TMUX", None)
            os.execv(tmux, server + ["attach"])
        os.set_blocking(self.fd, False)
    def drain(self):
        try:
            while os.read(self.fd, 65536):
                pass
        except (BlockingIOError, OSError):
            pass
    def name(self):
        for line in run("list-clients", "-F",
                "#{client_pid} #{client_name}").splitlines():
            pid, name = line.split(" ", 1)
            if int(pid) == self.pid:
                return name
        return None

run("new-session", "-d", "-x", "40", "-y", "10", "exec cat >/dev/null")
run("set", "-g", "@active", "")
run("set-hook", "-g", "client-active", "set -gaF @active ' #{client_name}'")

# The clients made latest so far, in order.
def active():
    return run("show", "-gv", "@active").split()
go = os.path.join(tmp, "go")
done = os.path.join(tmp, "done")
run("bind", "-n", "F5", "run-shell",
    "while [ ! -e %s ]; do sleep 0.02; done; touch %s" % (go, done))

a = Client()
wait(lambda: (a.drain() or True) and a.name() is not None, "client a")
b = Client()
wait(lambda: (b.drain() or True) and b.name() is not None, "client b")
an, bn = a.name(), b.name()

# A presses F5 (its job waits) and more keys and is latest; then B types and
# is latest.
n = len(active())
os.write(a.fd, b"\033[15~xyzxyz")
wait(lambda: (a.drain() or True) and active()[n:] == [an], "a to be latest")
os.write(b.fd, b"b")
wait(lambda: (b.drain() or True) and active()[n:] == [an, bn],
    "b to be latest")
before = len(active())

os.kill(a.pid, signal.SIGKILL)
os.waitpid(a.pid, 0)
wait(lambda: (b.drain() or True) and len(run("list-clients").splitlines()) == 1,
    "a to go")
open(go, "w").close()
wait(lambda: os.path.exists(done), "the job to end")
run("display", "-p", "x")
run("display", "-p", "x")

after = active()[before:]
run("kill-server")
os.kill(b.pid, signal.SIGKILL)
# B was already the latest: losing A must not fire client-active at all
# (tmux made A latest as its keys were handled, then B again: twice).
if after:
    print("FAIL: client-active fired after a client that was not latest "
        "was lost: %s" % after)
    sys.exit(1)
sys.exit(0)
PY
