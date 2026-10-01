"""Old and new tmux-scroll binaries against each other: a server started by
one, driven entirely by the other (commands t-claude uses, an attached
client over a pty, control mode, kill-server).

    python3 gym/rollout_interop.py OLD NEW
"""

import fcntl
import os
import select
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import time

OLD, NEW = os.path.abspath(sys.argv[1]), os.path.abspath(sys.argv[2])
fails = []


def check(ok, what):
    if not ok:
        fails.append(what)
        print('  FAIL', what, flush=True)


class Pair:
    def __init__(self, server, client):
        self.server, self.client = server, client
        self.dir = tempfile.mkdtemp(prefix='ro', dir='/tmp')
        self.env = dict(os.environ, TMUX_TMPDIR=self.dir, TERM='xterm-256color')
        self.env.pop('TMUX', None)

    def run(self, binary, *args, ok=True, inp=None):
        p = subprocess.run([binary, '-Lro', '-f/dev/null'] + list(args),
                           env=self.env, input=inp, timeout=20,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if ok:
            check(p.returncode == 0, '%s: rc %d %s' % (' '.join(args),
                  p.returncode, p.stderr.decode().strip()))
        return p.stdout.decode()

    def c(self, *args, **kw):
        return self.run(self.client, *args, **kw)


def wait(cond, timeout=10):
    end = time.time() + timeout
    while time.time() < end:
        if cond():
            return True
        time.sleep(0.02)
    return cond()


def attach(pair, binary, *extra):
    fd, slave = os.openpty()
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('HHHH', 24, 80, 0, 0))
    p = subprocess.Popen([binary, '-Lro', '-f/dev/null', 'attach'] + list(extra),
                         stdin=slave, stdout=slave, stderr=slave, env=pair.env,
                         start_new_session=True,
                         preexec_fn=lambda: fcntl.ioctl(0, termios.TIOCSCTTY, 0))
    os.close(slave)
    out = []

    def pump(t=0.05):
        r, _, _ = select.select([fd], [], [], t)
        if r:
            try:
                out.append(os.read(fd, 65536))
            except OSError:
                pass
    return p, fd, out, pump


def scenario(server, client, label):
    print('==', label, flush=True)
    pr = Pair(server, client)
    # The server is started by the server binary.
    pr.run(server, 'new-session', '-d', '-s', 's1', '-x', '80', '-y', '24',
           'exec cat -v')
    pid = pr.run(server, 'display', '-p', '#{pid}').strip()
    check(pid.isdigit(), 'server pid')

    # Commands t-claude uses, from the other binary.
    check(pr.c('has-session', '-t', 's1', ok=False) == '', 'has-session')
    pr.c('set-option', '-s', 'clear-on-attach', 'off')
    check(pr.c('show-options', '-sv', 'clear-on-attach').strip() == 'off',
          'show-options clear-on-attach')
    pr.c('set-option', '-g', 'status', 'off')
    pr.c('set-option', '-s', 'extended-keys', 'on')
    pr.c('set-hook', '-g', 'client-attached', 'set -g @att yes')
    check('client-attached' in pr.c('show-hooks', '-g'), 'show-hooks')
    pr.c('rename-window', '-t', 's1:0', 'w0')
    pr.c('new-window', '-d', '-t', 's1:1', '-n', 'w1', 'exec cat -v')
    pr.c('select-window', '-t', 's1:1')
    pr.c('move-window', '-s', 's1:1', '-t', 's1:5')
    lw = pr.c('list-windows', '-t', 's1', '-F', '#{window_index}:#{window_name}')
    check(lw.split() == ['0:w0', '5:w1'], 'list-windows %r' % lw)
    pr.c('select-window', '-t', 's1:0')
    pr.c('set-environment', '-g', 'RO_TEST', 'x')
    pr.c('bind-key', '-n', 'F12', 'display-message', 'f12')
    pr.c('send-keys', '-t', 's1:0', '-l', 'hello')
    check(wait(lambda: 'hello' in pr.c('capture-pane', '-p', '-t', 's1:0')),
          'send-keys reaches the pane')
    pr.c('capture-pane', '-p', '-e', '-J', '-t', 's1:0')
    pr.c('resize-window', '-t', 's1:0', '-x', '100', '-y', '30')
    check(pr.c('display', '-p', '-t', 's1:0', '#{window_width}x#{window_height}')
          .strip() == '100x30', 'resize-window')
    # resize-window pins the window's size; follow the clients again.
    pr.c('set-option', '-w', '-u', '-t', 's1:0', 'window-size')
    pr.c('new-session', '-d', '-s', 's2', 'exec cat -v')
    check(sorted(pr.c('list-sessions', '-F', '#{session_name}').split())
          == ['s1', 's2'], 'list-sessions')
    # Formats new in the new build are empty on the old one, never an error.
    pr.c('display', '-p', '#{pane_key_mode} #{mouse_pixels_flag} '
         '#{client_termtype}')

    # An attached client of the client binary.
    p, fd, out, pump = attach(pr, client, '-t', 's1')
    check(wait(lambda: (pump(), pr.c('list-clients', '-F', '#{client_pid}'))[1]
               .split() == [str(p.pid)]), 'attach')
    check(wait(lambda: pr.c('show-options', '-gv', '@att').strip() == 'yes'),
          'client-attached hook')
    os.write(fd, b'typed')
    check(wait(lambda: (pump(), 'typed' in pr.c('capture-pane', '-p',
                                                   '-t', 's1:0'))[1]),
          'typing reaches the pane')
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('HHHH', 30, 90, 0, 0))
    os.kill(p.pid, signal.SIGWINCH)
    check(wait(lambda: (pump(), pr.c('display', '-p', '-t', 's1:0',
                                     '#{window_width}x#{window_height}')
                        .strip() == '90x30')[1]), 'client resize')
    pr.c('refresh-client', '-t', pr.c('list-clients', '-F', '#{client_tty}')
         .strip())
    pr.c('switch-client', '-c', pr.c('list-clients', '-F', '#{client_tty}')
         .strip(), '-t', 's2')
    check(wait(lambda: pr.c('list-clients', '-F', '#{session_name}').strip()
               == 's2'), 'switch-client')
    pr.c('detach-client', '-s', 's2')
    end = time.time() + 10
    while p.poll() is None and time.time() < end:
        pump()
    check(p.returncode == 0, 'detach: client rc %r' % p.returncode)
    text = b''.join(out)
    check(b'[detached' in text, 'detach message')
    os.close(fd)

    # Control mode.
    cp = subprocess.Popen([client, '-Lro', '-f/dev/null', '-C', 'attach',
                           '-t', 's1'], env=pr.env, stdin=subprocess.PIPE,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        o, _ = cp.communicate(b'list-windows -F "#{window_name}"\n'
                              b'display -p ctl\ndetach\n', timeout=20)
    except subprocess.TimeoutExpired:
        cp.kill()
        o = b''
        check(False, 'control mode hung')
    check(b'w0' in o and b'ctl' in o and b'%exit' in o,
          'control mode output %r' % o[-200:])

    pr.c('kill-window', '-t', 's1:5')
    pr.c('kill-session', '-t', 's2')
    pr.c('kill-server')
    check(wait(lambda: subprocess.run(['kill', '-0', pid]).returncode != 0),
          'kill-server')


scenario(OLD, NEW, 'old server, new client')
scenario(NEW, OLD, 'new server, old client')
scenario(NEW, NEW, 'new server, new client')
print('FAILURES:', len(fails))
for f in fails:
    print(' ', f)
sys.exit(1 if fails else 0)
