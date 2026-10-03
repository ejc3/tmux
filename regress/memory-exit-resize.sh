#!/bin/sh

# A terminal resized while its client is suspended, and the client then
# ended: it wakes, says it is exiting and then sends the resize it had
# pending. The server must not use the terminal it has already closed for
# that client.
#
# The client runs as a shell would run it, as the foreground job of a pty,
# so it can be stopped and is the one told of the resize.

. ./memory-common.inc

server 'exec sleep 100000'
python3 - $TMUX <<'EOF' || { $TMUX ls >/dev/null 2>&1 && exit 1; finish; }
import fcntl, os, pty, signal, struct, subprocess, sys, termios, time

tmux = sys.argv[1:]

def run(*args):
    return subprocess.run(tmux + list(args), stdout=subprocess.PIPE,
        stderr=subprocess.PIPE).stdout.decode()

def wait(f, what):
    end = time.time() + 20
    while time.time() < end:
        if f():
            return
        time.sleep(0.02)
    print("timed out waiting for " + what)
    sys.exit(1)

def size(fd, rows, cols, xpixel, ypixel):
    fcntl.ioctl(fd, termios.TIOCSWINSZ,
        struct.pack("HHHH", rows, cols, cols * xpixel, rows * ypixel))

def stopped(pid):
    out = subprocess.run(["ps", "-o", "stat=", "-p", str(pid)],
        stdout=subprocess.PIPE).stdout.decode()
    return "T" in out

for i in range(3):
    master, slave = pty.openpty()
    size(slave, 20, 60, 8, 16)
    shell = os.fork()
    if shell == 0:
        os.setsid()
        fcntl.ioctl(slave, termios.TIOCSCTTY, 0)
        for fd in (0, 1, 2):
            os.dup2(slave, fd)
        os.close(master)
        client = os.fork()
        if client == 0:
            os.setpgid(0, 0)
            signal.signal(signal.SIGTTOU, signal.SIG_IGN)
            os.tcsetpgrp(0, os.getpid())
            signal.signal(signal.SIGTTOU, signal.SIG_DFL)
            os.environ["TERM"] = "xterm"
            os.execvp(tmux[0], tmux + ["attach"])
        while True:
            p, st = os.waitpid(client, os.WUNTRACED)
            if os.WIFEXITED(st) or os.WIFSIGNALED(st):
                os._exit(0)
    os.close(slave)
    os.set_blocking(master, False)

    def drain():
        try:
            while os.read(master, 65536):
                pass
        except (BlockingIOError, OSError):
            pass
        return True

    wait(lambda: drain() and run("lsc") != "", "the client to attach")
    pid = int(run("lsc", "-F", "#{client_pid}"))
    run("suspend-client")
    wait(lambda: drain() and stopped(pid), "the client to stop")
    # No size in pixels now: the server would ask the terminal for it.
    size(master, 21 + i, 61, 0, 0)
    os.kill(pid, signal.SIGWINCH)
    os.kill(pid, signal.SIGTERM)
    os.kill(pid, signal.SIGCONT)
    os.waitpid(shell, 0)
    os.close(master)
    wait(lambda: run("lsc") == "", "the client to go")
EOF
finish
