"""Memory gym: does the tmux server leak, grow, or crash on the protocols the
fork adds, from either side, and across clients and panes coming and going?

    python3 gym/memory.py --tmux BIN [--asan-tmux BIN] [--only NAME,...]
                          [--iterations N] [--modes forward,translate]

Every scenario is one round of a feature, driven both ways: the pane writes
the sequences (through gym/memory/feeder.py, which also reads the pane's
input) and a fake terminal attached over a pty answers tmux's queries as
kitty does and sends keys, mouse reports and replies. A round ends when tmux
has handled all of it: the pane reports a marker (OSC 7), or counts the Enter
that ends the terminal's input.

Three checks:

growth   The live heap of the server (bytes and blocks, counted exactly by
         gym/memory/heapcount.c, not RSS) after warm-up rounds and after N
         more. A leak of one block per round shows as N blocks; growth must
         stay under a few blocks, or a second window of N rounds must not
         grow again (a cache filling once is not a leak).
bounds   Scenarios that push past a limit (images, placements, pending
         uploads, a terminal that reads slowly) must keep the peak heap under
         a bound.
asan     With --asan-tmux (built with -fsanitize=address,undefined), every
         scenario, including those where a client or pane goes away while
         something is outstanding, runs a few rounds; the server is then
         killed and LeakSanitizer must report nothing, and no use after free,
         overflow or undefined behaviour may be reported while it runs.

Each scenario runs with forwarding (clear-on-attach off, where a pane that
is the whole terminal is forwarded as written) and translating (the
default), as tmux runs both ways.
"""

import argparse
import base64
import fcntl
import os
import re
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import threading
import time
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
SIG = signal.SIGRTMIN + 5
ST = b'\033\\'


def build_heapcount(out):
    so = os.path.join(out, 'heapcount.so')
    subprocess.run(['cc', '-O2', '-shared', '-fPIC', '-o', so,
                    os.path.join(HERE, 'memory', 'heapcount.c')], check=True)
    return so


class Fail(Exception):
    pass


# The tmux attached clients run, if not the server's (--valgrind: a client
# under valgrind does not stop on SIGTSTP, so suspend runs a native client).
ATTACH_TMUX = None

# Waits are this many times longer (--wait-scale, for slow tmux builds such
# as one run under valgrind).
WAIT_SCALE = 1


def wait(cond, what, timeout=20):
    end = time.time() + timeout * WAIT_SCALE
    while time.time() < end:
        if cond():
            return
        time.sleep(0.005)
    if not cond():
        raise Fail('timed out waiting for %s' % what)


class Server:
    """A tmux server under test, with its own socket and environment."""

    def __init__(self, tmux, tmp, mode, heapcount=None, asan=False):
        self.tmux = tmux
        self.tmp = tmp
        self.label = 'gymmem%d' % os.getpid()
        self.conf = os.path.join(tmp, 'tmux.conf')
        self.env = dict(os.environ)
        self.env.pop('TMUX', None)
        self.env['TERM'] = 'xterm-256color'
        # Sockets apart from the logs: a socket path must be short.
        self.sockdir = tempfile.mkdtemp(prefix='gm', dir='/tmp')
        self.env['TMUX_TMPDIR'] = self.sockdir
        self.hcdir = os.path.join(tmp, 'heap')
        self.asan = asan
        if heapcount is not None:
            os.makedirs(self.hcdir, exist_ok=True)
            self.env['HEAPCOUNT_DIR'] = self.hcdir
            self.env['LD_PRELOAD'] = heapcount
        if asan:
            self.env['ASAN_OPTIONS'] = ('detect_leaks=1:log_path=%s/asan:'
                                        'halt_on_error=1' % tmp)
            self.env['UBSAN_OPTIONS'] = ('print_stacktrace=1:'
                                         'halt_on_error=1:log_path=%s/ubsan'
                                         % tmp)
            self.env['LSAN_OPTIONS'] = 'exitcode=0'
        with open(self.conf, 'w') as f:
            f.write('set -g history-limit 0\n'
                    'set -g message-limit 0\n'
                    'set -g status off\n'
                    'set -s escape-time 0\n'
                    'set -s extended-keys on\n'
                    'set -g allow-passthrough on\n'
                    'set -g mouse off\n'
                    'set -s clear-on-attach %s\n'
                    'set -as terminal-features "xterm-256color:kittykeys:'
                    'kittygraphics:notify:textsize:graphemes:mousepixels:'
                    'pointer:sync:extkeys:osc7"\n'
                    % ('off' if mode == 'forward' else 'on'))
        self.pid = None

    def cmd(self, *args, check=True, timeout=20):
        p = subprocess.run([self.tmux, '-L' + self.label, '-f' + self.conf]
                           + list(args), env=self.env,
                           timeout=timeout * WAIT_SCALE,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if check and p.returncode != 0:
            raise Fail('tmux %s: %s' % (' '.join(args),
                                         p.stderr.decode().strip()))
        return p.stdout.decode()

    def start(self, pane):
        self.cmd('new-session', '-d', '-x80', '-y24', pane)
        self.pid = int(self.cmd('display', '-p', '#{pid}'))

    def alive(self):
        try:
            os.kill(self.pid, 0)
            return True
        except ProcessLookupError:
            return False

    def heap(self):
        """(live bytes, live blocks, peak bytes since the last call)."""
        path = os.path.join(self.hcdir, str(self.pid))
        try:
            seq = int(open(path).read().split()[0])
        except FileNotFoundError:
            seq = 0
        os.kill(self.pid, SIG)
        got = []

        def fresh():
            try:
                v = open(path).read().split()
            except FileNotFoundError:
                return False
            if len(v) == 4 and int(v[0]) > seq:
                got[:] = [int(x) for x in v[1:]]
                return True
            return False
        wait(fresh, 'heap report')
        return tuple(got)

    def kill(self):
        if self.pid is None:
            return
        self.cmd('kill-server', check=False)
        try:
            wait(lambda: not self.alive(), 'server exit', timeout=30)
        except Fail:
            os.kill(self.pid, signal.SIGKILL)
        shutil.rmtree(self.sockdir, ignore_errors=True)


JOBCONTROL = '''
import os, signal, sys
pid = os.fork()
if pid == 0:
    os.setpgid(0, 0)
    signal.signal(signal.SIGTTOU, signal.SIG_IGN)
    os.tcsetpgrp(0, os.getpid())
    signal.signal(signal.SIGTTOU, signal.SIG_DFL)
    os.execv(sys.argv[1], sys.argv[1:])
while True:
    p, st = os.waitpid(pid, os.WUNTRACED)
    if os.WIFEXITED(st) or os.WIFSIGNALED(st):
        sys.exit(0)
'''


class Terminal:
    """A client attached over a pty; the master side is the terminal.

    A reader thread reads everything tmux writes and answers its queries as
    kitty would. rate limits how fast it reads (bytes a second), to be a slow
    terminal; silent stops it answering."""

    ANSWERS = [
        (re.compile(rb'\033\[c'), lambda m: b'\033[?62;22;52c'),
        (re.compile(rb'\033\[>c'), lambda m: b'\033[>1;4000;29c'),
        (re.compile(rb'\033\[>q'), lambda m: b'\033P>|kitty(0.49.1)' + ST),
        (re.compile(rb'\033\[\?u'), lambda m: b'\033[?0u'),
        (re.compile(rb'\033\[\?(\d+)\$p'),
         lambda m: b'\033[?' + m.group(1) + b';2$y'),
        (re.compile(rb'\033\](1[01]);\?'),
         lambda m: b'\033]' + m.group(1) + b';rgb:ffff/ffff/ffff' + ST),
        (re.compile(rb'\033\[14t'), lambda m: b'\033[4;768;1280t'),
        (re.compile(rb'\033\[16t'), lambda m: b'\033[6;32;16t'),
        (re.compile(rb'\033_G([^;\033]*a=q[^;\033]*)[;\033]'),
         lambda m: b'\033_Gi=' + (re.search(rb'i=(\d+)', m.group(1))
                                  or re.search(b'(31)', b'31')).group(1)
         + b';OK' + ST),
        (re.compile(rb'\033\]99;([^;\033\007]*p=(?:\?|alive)[^;\033\007]*);'),
         lambda m: b'\033]99;' + Terminal.notify_id(m.group(1))
         + (b':p=?;a=focus,report:o' if b'p=?' in m.group(1)
            else b':p=alive;') + ST),
    ]

    @staticmethod
    def notify_id(meta):
        m = re.search(rb'i=([^:;]*)', meta)
        return b'i=' + (m.group(1) if m else b'0')

    def __init__(self, server, rows=24, cols=80, xpixel=16, ypixel=32,
                 rate=None, silent=False):
        self.server = server
        self.rate = rate
        self.silent = silent
        self.lock = threading.Lock()
        self.total = 0
        self.last = time.time()
        self.tail = b''
        self.notify_ids = []
        self.closing = False
        # subprocess, not forkpty: other terminals' reader threads run. The
        # client runs as a shell would run it: its own process group in the
        # foreground, so it can be stopped (an orphaned group ignores
        # SIGTSTP).
        self.fd, slave = os.openpty()
        self.ttyname = os.ttyname(slave)
        self.pid = None
        self.size(rows, cols, xpixel, ypixel)
        self.proc = subprocess.Popen(
            [sys.executable, '-c', JOBCONTROL, ATTACH_TMUX or server.tmux,
             '-L' + server.label, '-f' + server.conf, 'attach'],
            stdin=slave, stdout=slave, stderr=slave, env=server.env,
            start_new_session=True, preexec_fn=lambda: fcntl.ioctl(
                0, termios.TIOCSCTTY, 0))
        os.close(slave)
        self.thread = threading.Thread(target=self.read, daemon=True)
        self.thread.start()
        wait(lambda: self.attached(), 'attach')
        self.pid = int(self.client('#{client_pid}'))

    def client(self, fmt):
        for line in self.server.cmd('list-clients', '-F',
                                    '#{client_tty} ' + fmt,
                                    check=False).split('\n'):
            if line.split(' ')[0] == self.ttyname:
                return line.split(' ', 1)[1]
        return None

    def attached(self):
        return self.client('x') is not None

    def tty(self):
        return self.ttyname

    def size(self, rows, cols, xpixel, ypixel):
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ,
                    struct.pack('HHHH', rows, cols, cols * xpixel,
                                rows * ypixel))
        if self.pid is not None:
            try:
                os.kill(self.pid, signal.SIGWINCH)
            except ProcessLookupError:
                pass

    def read(self):
        start = time.time()
        while not self.closing:
            want = 65536
            if self.rate:
                allowed = int((time.time() - start) * self.rate) - self.total
                if allowed <= 0:
                    time.sleep(0.01)
                    continue
                want = min(want, allowed)
            try:
                data = os.read(self.fd, want)
            except OSError:
                return
            if not data:
                return
            with self.lock:
                self.total += len(data)
                self.last = time.time()
            if not self.silent:
                self.answer(data)

    def answer(self, data):
        # Queries can be split across reads; look at the end of the last read
        # too, but answer each only once.
        buf = self.tail + data
        out = b''
        for pattern, reply in self.ANSWERS:
            for m in pattern.finditer(buf):
                if m.end() <= len(self.tail):
                    continue
                out += reply(m)
        for m in re.finditer(rb'\033\]99;([^;\033\007]*)', buf):
            if m.end() > len(self.tail):
                i = re.search(rb'i=([^:;]*)', m.group(1))
                if i and b'p=' not in m.group(1):
                    self.notify_ids.append(i.group(1))
        self.tail = buf[-256:]
        if out:
            self.send(out)

    def send(self, data):
        while data:
            try:
                n = os.write(self.fd, data)
            except OSError:
                return
            data = data[n:]

    def idle(self, quiet=0.1, timeout=60):
        def check():
            with self.lock:
                return time.time() - self.last >= quiet
        wait(check, 'terminal to go quiet', timeout)

    def close(self):
        self.closing = True
        for sig in (signal.SIGTERM, signal.SIGCONT):
            for pid in (self.pid, self.proc.pid):
                try:
                    if pid is not None:
                        os.kill(pid, sig)
                except ProcessLookupError:
                    pass
        self.proc.wait()
        try:
            os.close(self.fd)
        except OSError:
            pass


class Gym:
    """One server, one terminal and the feeder pane, for one scenario."""

    def __init__(self, tmux, mode, heapcount, asan, keep):
        self.tmp = tempfile.mkdtemp(prefix='gymmem-', dir=keep)
        self.fifo = os.path.join(self.tmp, 'fifo')
        os.mkfifo(self.fifo)
        self.server = Server(tmux, self.tmp, mode, heapcount, asan)
        self.feeder = self.feeder_for(self.fifo)
        self.server.start(self.feeder)
        self.wfd = os.open(self.fifo, os.O_RDWR)
        self.extra = {}
        self.term = Terminal(self.server)
        self.terms = [self.term]
        self.marks = 0
        self.enters = 0

    @staticmethod
    def feeder_for(fifo):
        return 'exec python3 %s %s' % (
            os.path.join(HERE, 'memory', 'feeder.py'), fifo)

    def split(self):
        # Another pane with its own feeder; returns its id.
        fifo = os.path.join(self.tmp, 'fifo%d' % len(self.extra))
        if not os.path.exists(fifo):
            os.mkfifo(fifo)
        pane = self.server.cmd('split-window', '-d', '-P', '-F',
                               '#{pane_id}', self.feeder_for(fifo)).strip()
        self.extra[pane] = os.open(fifo, os.O_RDWR)
        return pane

    def unsplit(self, pane):
        self.server.cmd('kill-pane', '-t', pane)
        os.close(self.extra.pop(pane))

    # The pane writes data; returns once tmux has parsed it.
    def pane(self, data, target=None):
        self.marks += 1
        data += b'\033]7;s%d\007' % self.marks
        fd = self.extra[target] if target else self.wfd
        for i in range(0, len(data), 65536):
            os.write(fd, data[i:i + 65536])
        want = 's%d\n' % self.marks
        t = ['-t', target] if target else []
        wait(lambda: self.server.cmd('display', '-p', *t, '#{pane_path}')
             == want, 'pane marker %s' % want.strip())

    # The terminal types data; returns once the pane has read all of it.
    def keys(self, data, term=None):
        self.enters += 1
        (term or self.term).send(data + b'\r')
        want = 'k%d\n' % self.enters
        wait(lambda: self.server.cmd('display', '-p', '#{pane_path}')
             == want, 'pane to read keys %s' % want.strip())

    def respawn(self, target=None):
        # A new feeder starts counting from zero.
        t = ['-t', target] if target else []
        self.server.cmd('respawn-pane', '-k', *t, self.feeder)
        self.enters = 0

    def settle(self):
        for term in self.terms:
            term.idle()
        self.server.cmd('display', '-p', 'x')
        for term in self.terms:
            term.idle(0.05)

    def heap(self):
        self.settle()
        best = None
        for _ in range(3):
            h = self.server.heap()
            if best is None or h[1] < best[1]:
                best = h
        return best

    def close(self):
        for term in self.terms:
            term.close()
        self.server.kill()
        os.close(self.wfd)
        for fd in self.extra.values():
            os.close(fd)


# --- Payloads ---------------------------------------------------------------

def b64(data):
    return base64.b64encode(data)


def png(w, h):
    raw = b''.join(b'\0' + b'\x80\x40\x20' * w for _ in range(h))

    def chunk(kind, body):
        return (struct.pack('>I', len(body)) + kind + body
                + struct.pack('>I', zlib.crc32(kind + body)))
    return (b'\x89PNG\r\n\x1a\n'
            + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0))
            + chunk(b'IDAT', zlib.compress(raw)) + chunk(b'IEND', b''))


def gfx(keys, payload=b''):
    return b'\033_G' + keys + (b';' + payload if payload else b'') + ST


RGB1 = b64(b'\x10\x20\x30')
RGBA2 = b64(b'\x10\x20\x30\xff' * 4)
PLACEHOLDER = '\U0010EEEE'.encode()
DIACRITICS = ['̅', '̍', '̎', '̐', '̒']


def placeholder(row, col, high=None):
    s = PLACEHOLDER + DIACRITICS[row].encode() + DIACRITICS[col].encode()
    if high is not None:
        s += DIACRITICS[high].encode()
    return s


def tmpimage(tmp, data, name):
    # t=t files must be in a temporary directory and named as such.
    path = os.path.join(tempfile.gettempdir(),
                        'gymmem-%d-%s-tty-graphics-protocol' % (os.getpid(),
                                                                name))
    with open(path, 'wb') as f:
        f.write(data)
    return path


def shmimage(data, name):
    path = '/dev/shm/gymmem-%d-%s' % (os.getpid(), name)
    with open(path, 'wb') as f:
        f.write(data)
    return path


# --- Scenarios --------------------------------------------------------------
#
# Each is (setup(g), round(g, i)); setup runs once, round many times. A round
# must leave the server as it found it, apart from state it replaces.

LEGACY_KEYS = (b'abc\x01\x1b[A\x1bOP\x1b[15~\x1b[1;5A\x1bx\x1b[200~p\x1b[201~'
               b'\x1b[I\x1b[O')
KITTY_KEYS = (b'\x1b[97;5u\x1b[57376u\x1b[13;2~\x1b[57399u\x1b[97:65;2u'
              b'\x1b[27u\x1b[127;3u\x1b[57441;2u\x1b[57441;2:3u\x1b[1;5P'
              b'\x1b[1;2Q\x1b[1;5S\x1b[57398;4u\x1b[9;5u\x1b[32;3:3u'
              b'\x1b[99;5:2u\x1b[0;;105u')


def keys_setup(g):
    g.pane(b'')


def keys_legacy(g, i):
    g.keys(LEGACY_KEYS + KITTY_KEYS)


def keys_kitty(g, i):
    flags = [1, 3, 5, 31, 8, 2, 4, 16][i % 8]
    g.pane(b'\033[>%du\033[?u\033[=%d;2u\033[>1u\033[<u' % (flags, i % 32))
    g.keys(LEGACY_KEYS + KITTY_KEYS)
    g.pane(b'\033[<u' * (i % 3) + b'\033[=0;1u')


def keys_kitty_deep(g, i):
    # Push past the stack's depth, then pop more than were pushed.
    g.pane(b''.join(b'\033[>%du' % (n % 32) for n in range(12)) + b'\033[?u')
    g.keys(KITTY_KEYS)
    g.pane(b'\033[<20u\033[?1049h\033[>5u\033[?1049l\033[<u')


def mouse(g, i):
    g.pane(b'\033[?1000h\033[?1006h\033[?1016h' if i % 2 == 0
           else b'\033[?1003h\033[?1006h')
    g.keys(b'\033[<0;%d;%dM\033[<0;%d;%dm\033[<35;400;300M'
           b'\033[<64;1;1M\033[<0;0;0M\033[<0;99999;99999M'
           % (1 + i % 1000, 1 + i % 700, 2 + i % 1000, 2 + i % 700))
    g.pane(b'\033[?1016l\033[?1006l\033[?1003l\033[?1000l')


def inband_resize(g, i):
    g.pane(b'\033[?2048h')
    if i % 3 == 2:
        g.term.size(24, 80, 16 + i % 2, 32)   # pixels only
        want = '%d' % (16 + i % 2)
        wait(lambda: g.server.cmd('display', '-p', '#{client_cell_width}')
             .strip() == want, 'pixel resize')
    else:
        rows = 24 + i % 2
        g.term.size(rows, 80, 16, 32)
        wait(lambda: g.server.cmd('display', '-p', '#{window_height}')
             .strip() == str(rows), 'resize')
    g.pane(b'\033[?2048l')


def graphemes(g, i):
    g.pane(b'\033[?2027h' if i % 2 else b'\033[?2027l')
    g.pane('\r\U0001F469‍\U0001F4BB 1️⃣ क्ष '
           '\U0001F1FA\U0001F1F8 é̂̃ 中\r\n'.encode())
    g.server.cmd('capture-pane', '-p', '-e')


def text_sizing(g, i):
    w = 1 + i % 7
    g.pane(b'\033[H\033[2J')
    g.pane(b'a\033]66;w=%d;b\007c\033]66;w=0;de\007\033]66;w=2;\xe4\xb8\xad'
           b'\007\033]66;w=3;e\xcc\x81\007\033]66;s=2;x\007'
           b'\033]66;w=2;\xf0\x9f\x91\xa9\xe2\x80\x8d\xf0\x9f\x92\xbb\007'
           b'\033]66;w=2;\xf0\007\033]66;w=2;\xc3A\007' % w
           + b'\033[1;78H\033]66;w=3;xyz\007\r\n'
           + b'\033]66;w=6;' + b'x' * 40 + b'\007')
    g.server.cmd('capture-pane', '-p', '-e', '-C')
    g.server.cmd('capture-pane', '-p', '-e', '-J')
    g.server.cmd('resize-window', '-x', str(40 + i % 2 * 40))


def pointer(g, i):
    g.pane(b'\033]22;>crosshair,wait,text' + ST + b'\033]22;?__current__'
           + ST + b'\033]22;<' + ST + b'\033[?1049h\033]22;>help' + ST
           + b''.join(b'\033]22;>p%d' % n + ST for n in range(20))
           + b'\033]22;?__current__,__grabbed__' + ST
           + b'\033[?1049l\033]22;pointer' + ST
           + (b'\033c' if i % 4 == 3 else b'\033]22;<' + ST * 2))


def notify(g, i):
    n = b'n%d' % (i % 50)
    g.pane(b'\033]99;i=' + n + b':d=0;title' + ST
           + b'\033]99;i=' + n + b':p=body:a=report:c=1;body ' + n + ST
           + b'\033]99;;anon' + ST
           + b'\033]99;a=report;anon report' + ST
           + b'\033]99;i=q:p=?;' + ST
           + b'\033]99;i=al:p=alive;' + ST
           + b'\033]99;i=x:p=title;has p=? in it' + ST
           + b'\033]9;hello\007\033]9;9;/tmp\007\033]9;4;1;50\007'
           + b'\033]777;notify;title;body\007')
    g.settle()
    # The terminal clicks and closes what it was shown, and answers for
    # panes and servers that do not exist.
    ids = g.term.notify_ids[-6:]
    del g.term.notify_ids[:]
    out = b''
    for nid in ids:
        out += b'\033]99;i=' + nid + b';' + ST
        out += b'\033]99;i=' + nid + b':p=close;' + ST
    out += (b'\033]99;i=t99_x;' + ST + b'\033]99;i=t0.0;' + ST
            + b'\033]99;i=garbage;' + ST + b'\033]99;i=t0_x:p=alive;t0_a,t1_b'
            + ST)
    g.keys(out)
    g.pane(b'\033]99;i=' + n + b':p=close;' + ST)


def notify_unanswered(g, i):
    # Notifications that ask for reports, each with a new identifier, that no
    # terminal ever reports on: tmux remembers only the last few for a pane.
    g.pane(b''.join(b'\033]99;i=u%d:a=report:c=1;waiting' % (i * 20 + n) + ST
                    for n in range(20))
           + b'\033]99;a=report:c=1;anonymous' + ST)
    g.settle()
    del g.term.notify_ids[:]


def notify_two_terminals(g, i):
    # A second terminal shows the notification too: both report, the pane is
    # told once, and the second terminal goes with reports still to come.
    t = Terminal(g.server, rows=20, cols=60)
    g.terms.append(t)
    g.pane(b'\033]99;i=two%d:a=report:c=1;on both' % (i % 7) + ST)
    g.settle()
    pane = g.server.cmd('display', '-p', '#{pane_id}').strip().lstrip('%')
    wire = b't%s_two%d' % (pane.encode(), i % 7)
    t.send(b'\033]99;i=' + wire + b';' + ST)
    g.keys(b'\033]99;i=' + wire + b';' + ST
           + b'\033]99;i=' + wire + b':p=close;' + ST)
    del g.term.notify_ids[:]
    g.terms.remove(t)
    t.close()
    wait(lambda: len(g.server.cmd('list-clients').splitlines()) == 1,
         'second client to go')


def decstr(g, i):
    g.pane(b'\033[>5u\033]22;>text' + ST + b'\033[?2048h\033[?1016h'
           b'\033[?1000h\033[4h\033[?7l\033[5;10r\033[!p\033[r\033[?7h'
           + (b'\033c' if i % 2 else b''))


def capture_setup(g):
    # Fill tmux's hyperlink table (5000 kept, oldest go) so its filling is
    # not taken for growth.
    for n in range(3):
        g.pane(b'\033]8;;http://x\007l\033]8;;\007\r\n' * 2000)


def capture(g, i):
    g.pane(b'\033[31mred\033]8;;http://x\007link\033]8;;\007\033[0m '
           b'\033]66;w=2;\\\007 \r\n')
    g.server.cmd('capture-pane', '-p', '-e', '-C')
    g.server.cmd('capture-pane', '-p', '-e', '-N', '-T')


def gfx_direct(g, i):
    iid = b'%d' % (1 + i % 5)
    g.pane(gfx(b'a=T,f=24,s=1,v=1,i=' + iid + b',q=2', RGB1)
           + gfx(b'a=t,f=32,s=2,v=2,I=7', RGBA2) + gfx(b'a=d,d=N,I=7')
           + gfx(b'a=t,f=100,i=20,q=2', b64(png(2, 2)))
           + gfx(b'a=t,f=100,i=21', b64(b'not a png'))
           + gfx(b'a=t,f=24,s=1,v=1,o=z,i=22', b64(zlib.compress(b'\1\2\3')))
           + gfx(b'a=t,f=24,s=1,v=1,o=z,i=23', b64(b'not zlib'))
           + gfx(b'a=t,f=24,s=1,v=1,i=24', b'!!!not base64!!!')
           + gfx(b'a=d,d=I,i=' + iid)
           + gfx(b'a=d,d=i,i=20') + gfx(b'a=d,d=I,i=22'))


def gfx_chunked(g, i):
    data = b64(os.urandom(3 * 64 * 64))
    chunks = [data[n:n + 4096] for n in range(0, len(data), 4096)]
    out = gfx(b'a=t,f=24,s=64,v=64,i=30,q=2,m=1', chunks[0])
    for c in chunks[1:-1]:
        out += gfx(b'm=1', c)
    out += gfx(b'm=0', chunks[-1])
    # An upload aborted by a delete, and one abandoned by a new upload.
    out += gfx(b'a=t,f=24,s=64,v=64,i=31,q=2,m=1', chunks[0])
    out += gfx(b'a=d,d=I,i=31')
    out += gfx(b'a=t,f=24,s=64,v=64,i=32,q=2,m=1', chunks[0])
    out += gfx(b'a=t,f=24,s=1,v=1,i=33,q=2', RGB1)
    out += gfx(b'a=d,d=I,i=30') + gfx(b'a=d,d=I,i=33')
    g.pane(out)


def gfx_files(g, i):
    raw = os.urandom(3 * 16 * 16)
    f = tmpimage(g.tmp, raw, 'f')
    t = tmpimage(g.tmp, raw, 't%d' % i)
    s = shmimage(raw, 's%d' % i)
    fifo = os.path.join(tempfile.gettempdir(),
                        'gymmem-%d-fifo-tty-graphics-protocol' % os.getpid())
    if not os.path.exists(fifo):
        os.mkfifo(fifo)
    link = os.path.join(tempfile.gettempdir(),
                        'gymmem-%d-link-tty-graphics-protocol' % os.getpid())
    if not os.path.lexists(link):
        os.symlink(f, link)
    g.pane(gfx(b'a=t,f=24,s=16,v=16,t=f,i=40,q=2', b64(f.encode()))
           + gfx(b'a=t,f=24,s=8,v=8,t=f,O=3,S=192,i=41,q=2', b64(f.encode()))
           + gfx(b'a=t,f=24,s=16,v=16,t=t,i=42,q=2', b64(t.encode()))
           + gfx(b'a=t,f=24,s=16,v=16,t=s,i=43,q=2',
                 b64(os.path.basename(s).encode()))
           + gfx(b'a=t,f=24,s=16,v=16,t=f,i=44', b64(fifo.encode()))
           + gfx(b'a=t,f=24,s=16,v=16,t=t,i=45', b64(link.encode()))
           + gfx(b'a=t,f=24,s=16,v=16,t=f,i=46', b64(b'/nonexistent'))
           + gfx(b'a=t,f=24,s=16,v=16,t=f,i=47', b64(b'/proc/self/mem'))
           + b''.join(gfx(b'a=d,d=I,i=%d' % n) for n in range(40, 48)))
    for p in (t, s):
        if os.path.exists(p):
            os.unlink(p)


def gfx_placements(g, i):
    out = gfx(b'a=t,f=24,s=1,v=1,i=50,q=2', RGB1)
    out += gfx(b'a=t,f=24,s=1,v=1,i=%d,q=2' % 0x1000033, RGB1)
    for p in range(1, 9):
        out += gfx(b'a=p,i=50,p=%d,U=1,c=2,r=1,q=2' % p)
    out += gfx(b'a=p,i=50,c=3,r=2,q=2') + gfx(b'a=p,i=50,U=1,q=2')
    out += gfx(b'a=p,i=%d,U=1,c=2,r=1,q=2' % 0x1000033)
    out += b'\r\033[38;5;50m' + placeholder(0, 0) + placeholder(0, 1)
    out += b'\033[38;2;0;0;51m' + placeholder(0, 0, 1) + placeholder(0, 1)
    out += b'\033[38;5;77m' + placeholder(0, 0) + b'\033[39m\r\n'
    out += b'\033[4h\033[38;5;50m' + placeholder(0, 0, 2) + b'\033[4l\r\n'
    out += b'\033[?1049h\033[38;5;50m' + placeholder(1, 1) + b'\033[?1049l'
    out += gfx(b'a=d,d=i,i=50,p=3') + gfx(b'a=d,d=I,i=50,p=4')
    out += gfx(b'a=d,d=p,x=1,y=1') + gfx(b'a=d,d=a') + gfx(b'a=d,d=A')
    out += b'\033[H\033[2J'
    g.pane(out)


def gfx_query(g, i):
    g.pane(gfx(b'a=q,i=31,s=1,v=1,f=24', b'AAAA')
           + gfx(b'a=q,i=32,s=1,v=1,f=24,t=f', b64(b'/nonexistent'))
           + b'\033[c\033]10;?\007')


def gfx_animation(g, i):
    out = gfx(b'a=t,f=32,s=2,v=2,i=60,q=2', RGBA2)
    out += gfx(b'a=f,i=60,f=32,s=2,v=2,q=2', RGBA2)
    out += gfx(b'a=f,i=60,f=100,q=2', b64(png(2, 2)))
    out += gfx(b'a=f,i=60,f=24,s=1,v=1,o=z,q=2', b64(zlib.compress(b'\1\2\3')))
    out += gfx(b'a=a,i=60,s=3,v=1,q=2') + gfx(b'a=c,i=60,r=1,c=2,q=2')
    out += gfx(b'a=a,i=60,s=1,q=2') + gfx(b'a=d,d=I,i=60')
    g.pane(out)


def gfx_evict_setup(g):
    # Fill to the image limit first; rounds then evict as they add.
    for base in range(0, 4200, 300):
        g.pane(b''.join(gfx(b'a=t,f=24,s=1,v=1,i=%d,q=2' % (1000 + n), RGB1)
                        + gfx(b'a=p,i=%d,U=1,q=2' % (1000 + n))
                        for n in range(base, base + 300)))


def gfx_evict(g, i):
    g.pane(b''.join(gfx(b'a=t,f=24,s=1,v=1,i=%d,q=2' % (6000 + (i * 10 + n)
                                                       % 9000), RGB1)
                    + gfx(b'a=p,i=%d,U=1,q=2' % (6000 + (i * 10 + n) % 9000))
                    for n in range(10)))


def lifecycle_attach(g, i):
    # A second terminal comes and goes while images and placements exist.
    g.pane(gfx(b'a=T,f=24,s=1,v=1,i=70,U=1,q=2', RGB1)
           + b'\033]22;>text' + ST + b'\033[>5u')
    t = Terminal(g.server, rows=20 + i % 5, cols=60)
    g.terms.append(t)
    g.pane(gfx(b'a=t,f=24,s=1,v=1,i=71,q=2', RGB1) + b'\033]99;;both' + ST)
    g.settle()
    g.terms.remove(t)
    t.close()
    wait(lambda: len(g.server.cmd('list-clients').splitlines()) == 1,
         'second client to go')
    g.pane(gfx(b'a=d,d=I,i=70') + gfx(b'a=d,d=I,i=71') + b'\033[<u'
           + b'\033]22;<' + ST)


def stopped(pid):
    with open('/proc/%d/stat' % pid) as f:
        return f.read().rsplit(')', 1)[1].split()[0] == 'T'


def lifecycle_suspend(g, i):
    g.pane(gfx(b'a=T,f=24,s=1,v=1,i=72,q=2', RGB1) + b'\033[?2027h')
    g.server.cmd('suspend-client', '-t', g.term.tty())
    wait(lambda: stopped(g.term.pid), 'client to stop')
    g.pane(gfx(b'a=t,f=24,s=1,v=1,i=73,q=2', RGB1))
    os.kill(g.term.pid, signal.SIGCONT)
    g.settle()
    g.pane(gfx(b'a=d,d=I,i=72') + gfx(b'a=d,d=I,i=73'))


def lifecycle_panes(g, i):
    # A pane with every kind of state is killed; answers for it come later.
    pane = g.split()
    g.pane(b'\033[>5u\033[>9u\033]22;>text,wait' + ST + b'\033[?1049h'
           + b'\033]22;>help' + ST + gfx(b'a=T,f=24,s=1,v=1,i=74,U=1,q=2',
                                         RGB1)
           + gfx(b'a=t,f=24,s=64,v=64,i=75,q=2,m=1', b'AAAA')
           + b'\033]99;i=q:p=?;' + ST + b'\033]99;i=w:a=report;w' + ST
           + gfx(b'a=q,i=31,s=1,v=1,f=24', b'AAAA') + b'\033[?2048h'
           + b'\033]66;w=2;x\007', target=pane)
    g.term.silent = True
    g.unsplit(pane)
    g.term.silent = False
    num = pane.lstrip('%')
    g.keys(b'\033]99;i=t%s_w;' % num.encode() + ST
           + b'\033]99;i=t%s_q:p=?;a=focus' % num.encode() + ST
           + b'\033_Gi=31;OK' + ST)


def lifecycle_respawn(g, i):
    g.pane(b'\033[>5u' * 10 + b'\033]22;>a,b,c' + ST + b'\033[?1049h'
           + b'\033]22;>d' + ST + gfx(b'a=T,f=24,s=1,v=1,i=76,U=1,q=2', RGB1)
           + gfx(b'a=t,f=24,s=64,v=64,i=77,q=2,m=1', b'AAAA'))
    g.respawn()
    g.pane(b'')


def lifecycle_menu_pane(g, i):
    # A menu is open for a pane that is then killed, and is drawn again.
    pane = g.split()
    g.server.cmd('display-menu', '-c', g.term.tty(), '-t', pane, '-x', '0',
                 '-y', '0', 'one', '1', '', 'two', '2', '')
    g.settle()
    g.unsplit(pane)
    g.server.cmd('refresh-client', '-t', g.term.tty())
    g.settle()
    g.term.send(b'q')              # close the menu
    g.settle()


def lifecycle_exit_resize(g, i):
    # A terminal resized while its client is stopped, then closed: the
    # client sends the resize it had pending after it has said it exits.
    t = Terminal(g.server, rows=20, cols=60)
    g.terms.append(t)
    g.settle()
    g.server.cmd('suspend-client', '-t', t.tty())
    wait(lambda: stopped(t.pid), 'client to stop')
    t.size(20 + i % 3, 61, 0, 0)
    g.terms.remove(t)
    t.close()
    wait(lambda: len(g.server.cmd('list-clients').splitlines()) == 1,
         'client to go')


def alt_stale_cursor(g, i):
    # The cursor 1049h saved, restored by 1049l after 47l, a resize and 47h
    # have changed the screen under it (it was past the grid it reflowed).
    g.server.cmd('resize-window', '-x', '80', '-y', '24')
    g.pane(b''.join(b'line %d\r\n' % n for n in range(55)))
    g.pane(b'\033[?1049h')
    g.pane(b'\033[?47l')
    g.server.cmd('resize-window', '-x', '120', '-y', '8')
    g.pane(b'\033[?47h')
    g.server.cmd('resize-window', '-x', '55', '-y', '17')
    g.pane(b'\033[?1049l')


def leak_prompt_client_lost(g, i):
    # A terminal goes while its copy mode prompt is open (t waits for the
    # character to jump to), then the pane is killed.
    pane = g.split()
    g.server.cmd('select-pane', '-t', pane)
    t = Terminal(g.server, rows=24, cols=80)
    g.terms.append(t)
    g.server.cmd('copy-mode', '-t', pane)
    t.send(b't')
    g.settle()
    g.terms.remove(t)
    t.close()
    wait(lambda: len(g.server.cmd('list-clients').splitlines()) == 1,
         'client to go')
    g.unsplit(pane)


def leak_bad_command(g, i):
    # A client sends a command that does not parse.
    for cmd in ('n {f', 'display -p {', 'set -g status "on'):
        g.server.cmd(cmd, check=False)


def leak_keys_behind_wait(g, i):
    # A key runs a job that waits; more keys queue behind it; the client
    # goes before the job ends. The keys queued must be freed, not left.
    done = os.path.join(g.tmp, 'job%d' % i)
    g.server.cmd('bind', '-n', 'F5', 'run-shell',
                 'while [ ! -e %s.go ]; do sleep 0.02; done; touch %s' %
                 (done, done))
    t = Terminal(g.server, rows=20, cols=60)
    g.terms.append(t)
    g.settle()
    t.send(b'\033[15~' + b'abcdefgh' * 4)
    g.settle()
    g.terms.remove(t)
    t.close()
    wait(lambda: len(g.server.cmd('list-clients').splitlines()) == 1,
         'client to go')
    open(done + '.go', 'w').close()
    wait(lambda: os.path.exists(done), 'job to end')


def lifecycle_truncate(g, i):
    # The file shrinks while tmux reads it.
    path = tmpimage(g.tmp, os.urandom(3 * 256 * 256), 'trunc')
    stop = threading.Event()

    def churn():
        while not stop.is_set():
            with open(path, 'r+b') as f:
                f.truncate(10)
                f.truncate(3 * 256 * 256)
    th = threading.Thread(target=churn, daemon=True)
    th.start()
    try:
        g.pane(gfx(b'a=t,f=24,s=256,v=256,t=f,i=78,q=2', b64(path.encode()))
               + gfx(b'a=d,d=I,i=78'))
    finally:
        stop.set()
        th.join()


# --- Upstream leaks ---------------------------------------------------------
#
# Leaks in tmux's own code (not the fork's protocols) found by valgrind
# (gym/valgrind): each round triggers one, so the heap grows a block or more a
# round without the fix.

def leak_term_remove_setup(g):
    # A string capability removed with @ was not freed on attach.
    g.server.cmd('set', '-as', 'terminal-overrides', ',*:setrgbf@')


def leak_term_remove(g, i):
    t = Terminal(g.server, rows=20, cols=60)
    g.terms.append(t)
    g.settle()
    g.terms.remove(t)
    t.close()
    wait(lambda: len(g.server.cmd('list-clients').splitlines()) == 1,
         'second client to go')


def leak_run_wait_killed(g, i):
    # A client killed while run -d waited was never freed: its queue was
    # not run again when the job finished.
    flag = os.path.join(g.tmp, 'ran%d' % i)
    p = subprocess.Popen(
        [g.server.tmux, '-L' + g.server.label, '-f' + g.server.conf,
         'wait-for', '-S', 'gymq%d' % i, ';', 'run', '-d', '0.05',
         'echo $$ >%s.tmp; mv %s.tmp %s' % (flag, flag, flag)],
        env=g.server.env, stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL)
    g.server.cmd('wait-for', 'gymq%d' % i)
    p.kill()
    p.wait()
    wait(lambda: os.path.exists(flag), 'delayed run %d' % i)
    pid = int(open(flag).read())

    def gone():
        try:
            os.kill(pid, 0)
            return False
        except ProcessLookupError:
            return True
    wait(gone, 'delayed run %d to exit' % i)
    os.unlink(flag)


def leak_hook_setup(g):
    g.server.cmd('set-hook', '-g', '@gym-hook', 'set -g @gym_hook 1')


def leak_hook(g, i):
    # A user hook's parsed command list was never freed.
    g.server.cmd('set-hook', '-E', '@gym-hook')


def leak_empty_pane(g, i):
    # An empty pane (-E) has an event but no fd; it was not freed.
    g.server.cmd('new-window', '-d', '-E', '-t', ':9')
    g.server.cmd('kill-window', '-t', ':9')


def leak_customize_setup(g):
    # A pane option over a window option over the global one: drawing the
    # pane's shows the window's and the global value too.
    g.server.cmd('set', '-g', 'window-style', 'fg=red')
    g.server.cmd('setw', 'window-style', 'fg=green')
    g.server.cmd('set', '-p', 'window-style', 'fg=blue')
    g.server.cmd('customize-mode', '-f', '#{==:#{option_name},window-style}')
    for key in ('j', 'j', 'Right', 'j'):
        g.server.cmd('send-keys', key)


def leak_customize(g, i):
    # Each value drawn over the last was not freed.
    g.server.cmd('send-keys', 'k')
    g.server.cmd('send-keys', 'j')


def leak_parse_error(g, i):
    # A syntax error left what the parser had built: what was on the stack,
    # an %if still open, and the commands of a file complete before a stray
    # brace.
    g.server.cmd('set', '-g', 'alert-bell[0]', 'if -x { foo "bar',
                 check=False)
    g.server.cmd('set', '-g', 'default-client-command', 'a { b ; c',
                 check=False)
    for n, text in enumerate(('%if 1\ndisplay x\n', '""\n{')):
        path = os.path.join(g.tmp, 'bad%d.conf' % n)
        with open(path, 'w') as f:
            f.write(text)
        g.server.cmd('source-file', '-q', path, check=False)



# --- The terminal's scrollback ----------------------------------------------

HISTORY = b''.join(b'line %04d of the history\r\n' % k for k in range(800))


def scrollback_setup(g):
    # Windows made from here keep a history, which the terminal's scrollback
    # is written from (clear-on-attach off, the forward mode).
    g.server.cmd('set', '-g', 'history-limit', '500')
    g.server.cmd('set', '-gw', 'scroll-replay', '300')


def scrollback_grid_setup(g):
    # The same with the pane drawn from the grid.
    scrollback_setup(g)
    g.server.cmd('set', '-s', 'forward-output', 'off')


def scrollback_window(g):
    fifo = os.path.join(g.tmp, 'sbfifo')
    if not os.path.exists(fifo):
        os.mkfifo(fifo)
    pane = g.server.cmd('new-window', '-P', '-F', '#{pane_id}',
                        g.feeder_for(fifo)).strip()
    g.extra[pane] = os.open(fifo, os.O_RDWR)
    return pane


def scrollback_close(g, pane):
    g.server.cmd('kill-window', '-t', pane)
    os.close(g.extra.pop(pane))


def scrollback_switch(g, i):
    # A window with history is switched from and to, split, zoomed, has its
    # history cleared by the program and by tmux, and is killed.
    pane = scrollback_window(g)
    g.pane(HISTORY, target=pane)
    g.server.cmd('last-window')
    g.settle()
    g.server.cmd('last-window')
    g.settle()
    other = g.split()
    g.pane(b'beside\r\n' * 30, target=other)
    g.server.cmd('resize-pane', '-Z', '-t', pane)
    g.settle()
    g.server.cmd('resize-pane', '-Z', '-t', pane)
    g.unsplit(other)
    g.settle()
    g.pane(b'\033[3J', target=pane)
    g.pane(HISTORY[:4096], target=pane)
    g.server.cmd('clear-history', '-t', pane)
    g.server.cmd('send-keys', '-R', '-t', pane)
    g.settle()
    scrollback_close(g, pane)


def scrollback_attach_setup(g):
    scrollback_setup(g)
    g.sbpane = scrollback_window(g)
    g.pane(HISTORY, target=g.sbpane)


def scrollback_attach(g, i):
    # A second terminal attaches to a window with history, is suspended and
    # resumed, sizes the window while it is the smaller, and goes.
    t = Terminal(g.server, rows=20 + i % 5, cols=60 + 20 * (i % 2))
    g.terms.append(t)
    g.settle()
    g.server.cmd('suspend-client', '-t', t.tty())
    wait(lambda: stopped(t.pid), 'client to stop')
    g.pane(HISTORY[:2048], target=g.sbpane)
    os.kill(t.pid, signal.SIGCONT)
    g.settle()
    g.terms.remove(t)
    t.close()
    wait(lambda: len(g.server.cmd('list-clients').splitlines()) == 1,
         'second client to go')
    g.settle()

SCENARIOS = [
    ('keys-legacy', keys_setup, keys_legacy),
    ('keys-kitty', keys_setup, keys_kitty),
    ('keys-kitty-deep', keys_setup, keys_kitty_deep),
    ('mouse', None, mouse),
    ('inband-resize', None, inband_resize),
    ('graphemes', None, graphemes),
    ('text-sizing', None, text_sizing),
    ('pointer', None, pointer),
    ('notify', None, notify),
    ('notify-unanswered', None, notify_unanswered),
    ('notify-two-terminals', None, notify_two_terminals),
    ('decstr', None, decstr),
    ('capture', capture_setup, capture),
    ('gfx-direct', None, gfx_direct),
    ('gfx-chunked', None, gfx_chunked),
    ('gfx-files', None, gfx_files),
    ('gfx-placements', None, gfx_placements),
    ('gfx-query', None, gfx_query),
    ('gfx-animation', None, gfx_animation),
    ('gfx-evict', gfx_evict_setup, gfx_evict),
    ('scrollback-switch', scrollback_setup, scrollback_switch),
    ('scrollback-grid', scrollback_grid_setup, scrollback_switch),
    ('scrollback-attach', scrollback_attach_setup, scrollback_attach),
    ('lifecycle-attach', None, lifecycle_attach),
    ('lifecycle-suspend', None, lifecycle_suspend),
    ('lifecycle-panes', None, lifecycle_panes),
    ('lifecycle-respawn', None, lifecycle_respawn),
    ('lifecycle-truncate', None, lifecycle_truncate),
    ('lifecycle-menu-pane', None, lifecycle_menu_pane),
    ('lifecycle-exit-resize', None, lifecycle_exit_resize),
    ('alt-stale-cursor', None, alt_stale_cursor),
    ('leak-bad-command', None, leak_bad_command),
    ('leak-prompt-client-lost', None, leak_prompt_client_lost),
    ('leak-keys-behind-wait', None, leak_keys_behind_wait),
    # Upstream leaks.
    ('leak-term-remove', leak_term_remove_setup, leak_term_remove),
    ('leak-run-wait-killed', None, leak_run_wait_killed),
    ('leak-hook', leak_hook_setup, leak_hook),
    ('leak-empty-pane', None, leak_empty_pane),
    ('leak-customize', leak_customize_setup, leak_customize),
    ('leak-parse-error', None, leak_parse_error),
]


# --- Bounds -----------------------------------------------------------------

MB = 1024 * 1024


def bound_slow_terminal(g, limit):
    """A terminal reading 1 MB/s while a pane re-sends a 4 MB image."""
    g.term.close()
    g.terms.remove(g.term)
    g.term = Terminal(g.server, rate=1 * MB)
    g.terms.append(g.term)
    path = tmpimage(g.tmp, os.urandom(4 * 512 * 512), 'big')
    g.server.heap()
    for n in range(24):
        g.pane(gfx(b'a=t,f=32,s=512,v=512,t=f,i=1,q=2', b64(path.encode())))
    return g.server.heap()[2]


def bound_pending(g, limit):
    """An upload that never finishes, in 4 KB chunks as kitty sends them,
    to 300 MB: past the 256 MB a transmission may have."""
    chunk = b64(os.urandom(3072))
    burst = gfx(b'm=1', chunk) * 256
    g.server.heap()
    g.pane(gfx(b'a=t,f=24,s=8192,v=8192,i=2,q=2,m=1', chunk))
    peak = 0
    for n in range(300):
        g.pane(burst)
        if n % 50 == 49:
            peak = max(peak, g.server.heap()[2])
    return max(peak, g.server.heap()[2])


def bound_placements(g, limit):
    """Placements without ids, far past the placement cap."""
    g.pane(gfx(b'a=t,f=24,s=1,v=1,i=3,q=2', RGB1))
    g.server.heap()
    for n in range(40):
        g.pane(gfx(b'a=p,i=3,U=1,q=2') * 1000)
    return g.server.heap()[2]


def bound_queries(g, limit):
    """Queries a silent terminal never answers."""
    g.term.silent = True
    g.server.heap()
    for n in range(200):
        g.pane(gfx(b'a=q,i=31,s=1,v=1,f=24', b'AAAA') * 10
               + b'\033]99;i=q:p=?;' + ST * 1 + b'\033[c' * 10)
    peak = g.server.heap()[2]
    g.term.silent = False
    return peak


def bound_stalled_terminal(g, limit):
    """A terminal that takes nothing while a pane writes 48 MB."""
    g.term.rate = 1
    chunk = (b'flood ' * 13 + b'\r\n') * 800
    g.server.heap()
    for n in range(750):
        g.pane(chunk)
    return g.server.heap()[2]


def bound_replay_slow(g, limit):
    """A terminal reading 64 KB/s while 5000 lines of history are written
    to its scrollback at each window switch and the pane goes on writing."""
    g.server.cmd('set', '-g', 'history-limit', '5000')
    g.server.cmd('set', '-gw', 'scroll-replay', '5000')
    pane = scrollback_window(g)
    wide = b''.join(b'%04d %s\r\n' % (k, b'x' * 70) for k in range(6000))
    g.pane(wide, target=pane)
    g.term.rate = 64 * 1024
    chunk = (b'flood ' * 13 + b'\r\n') * 800
    g.server.heap()
    for n in range(40):
        g.server.cmd('last-window')
        for m in range(8):
            g.pane(chunk, target=pane)
    return g.server.heap()[2]


BOUNDS = [
    ('bound-slow-terminal', bound_slow_terminal, 20 * MB),
    ('bound-pending', bound_pending, 400 * MB),
    ('bound-placements', bound_placements, 64 * MB),
    ('bound-queries', bound_queries, 32 * MB),
    ('bound-stalled-terminal', bound_stalled_terminal, 16 * MB),
    ('bound-replay-slow', bound_replay_slow, 32 * MB),
]


# --- Running ----------------------------------------------------------------

def run_growth(args, heapcount, name, setup, step, mode):
    g = Gym(args.tmux, mode, heapcount, False, args.keep)
    try:
        if setup:
            setup(g)
        for i in range(args.warmup):
            step(g, i)
        h0 = g.heap()
        n = args.iterations
        for i in range(args.warmup, args.warmup + n):
            step(g, i)
        h1 = g.heap()
        dbytes, dblocks = h1[0] - h0[0], h1[1] - h0[1]
        verdict = 'flat'
        if dblocks > args.blocks or dbytes > args.bytes:
            # A cache filling once is not a leak: a second window must grow
            # too.
            for i in range(args.warmup + n, args.warmup + 2 * n):
                step(g, i)
            h2 = g.heap()
            d2bytes, d2blocks = h2[0] - h1[0], h2[1] - h1[1]
            if d2blocks > args.blocks or d2bytes > args.bytes:
                verdict = ('LEAK %.1f blocks, %.0f bytes a round'
                           % (d2blocks / n, d2bytes / n))
            else:
                verdict = 'flat after filling once'
        if not g.server.alive():
            verdict = 'SERVER DIED'
        return verdict, (dbytes, dblocks)
    except Fail as e:
        alive = g.server.alive()
        return ('ERROR %s%s' % (e, '' if alive else ' (server died)'),
                (0, 0))
    finally:
        g.close()


def run_bound(args, heapcount, name, fn, limit, mode):
    g = Gym(args.tmux, mode, heapcount, False, args.keep)
    try:
        peak = fn(g, limit)
        if not g.server.alive():
            return 'SERVER DIED', peak
        if peak > limit:
            return 'OVER %d MB (limit %d MB)' % (peak // MB, limit // MB), peak
        return 'under %d MB (peak %d MB)' % (limit // MB, peak // MB), peak
    except Fail as e:
        return 'ERROR %s' % e, 0
    finally:
        g.close()


def asan_reports(tmp, pid):
    found = []
    for f in sorted(os.listdir(tmp)):
        if not (f.startswith('asan.') or f.startswith('ubsan.')):
            continue
        text = open(os.path.join(tmp, f), errors='replace').read()
        if not text.strip():
            continue
        if f.endswith('.%d' % pid) or 'runtime error' in text:
            found.append((f, text))
    return found


def run_asan(args, name, setup, step, mode):
    g = Gym(args.asan_tmux, mode, None, True, args.keep)
    pid = g.server.pid
    err = None
    try:
        if setup:
            setup(g)
        for i in range(args.asan_iterations):
            step(g, i)
    except Fail as e:
        err = str(e)
    finally:
        g.close()
    reports = asan_reports(g.tmp, pid)
    if reports:
        first = reports[0][1]
        kind = re.search(r'ERROR: (\w+Sanitizer: [^\n]*)|runtime error: '
                         r'[^\n]*', first)
        return 'REPORT %s (%s)' % (kind.group(0) if kind else 'see log',
                                   os.path.join(g.tmp, reports[0][0])), reports
    if err:
        return 'ERROR %s' % err, []
    return 'clean', []


# --- valgrind (gym/valgrind/vg-tmux as --valgrind) -------------------------
#
# Every scenario a few rounds with every tmux process under valgrind
# memcheck; the server is then killed and its log (and the clients') must
# be empty: no invalid reads or writes, no use of uninitialised values, no
# memory definitely or indirectly lost.

def run_valgrind(args, name, setup, step, mode):
    global ATTACH_TMUX
    ATTACH_TMUX = args.tmux if name == 'lifecycle-suspend' else None
    vgdir = tempfile.mkdtemp(prefix='vg-', dir=args.keep)
    os.environ['VG_LOGS'] = vgdir
    os.environ.setdefault('VG_TMUX', args.tmux)
    err = None
    try:
        g = Gym(args.valgrind, mode, None, False, args.keep)
    except Fail as e:
        return 'ERROR %s' % e
    try:
        if setup:
            setup(g)
        for i in range(args.asan_iterations):
            step(g, i)
    except Fail as e:
        err = str(e)
    finally:
        g.close()
    logs = [f for f in sorted(os.listdir(vgdir))
            if os.path.getsize(os.path.join(vgdir, f)) > 0]
    if logs:
        text = open(os.path.join(vgdir, logs[0]), errors='replace').read()
        kind = re.search(r'==\d+== (\S[^\n]*)', text)
        return 'REPORT %s (%s)' % (kind.group(1) if kind else 'see log',
                                   os.path.join(vgdir, logs[0]))
    if err:
        return 'ERROR %s' % err
    return 'clean'


def main():
    global WAIT_SCALE
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('--tmux', required=True)
    ap.add_argument('--asan-tmux')
    ap.add_argument('--only', default='')
    ap.add_argument('--modes', default='forward,translate')
    ap.add_argument('--warmup', type=int, default=20)
    ap.add_argument('--iterations', type=int, default=200)
    ap.add_argument('--asan-iterations', type=int, default=10)
    ap.add_argument('--blocks', type=int, default=8,
                    help='growth allowed over the iterations, in blocks')
    ap.add_argument('--bytes', type=int, default=8192,
                    help='growth allowed over the iterations, in bytes')
    ap.add_argument('--no-bounds', action='store_true')
    ap.add_argument('--keep', help='directory for logs (kept)')
    ap.add_argument('--valgrind', help='gym/valgrind/vg-tmux: run every '
                    'scenario under valgrind (VG_TMUX defaults to --tmux)')
    ap.add_argument('--no-growth', action='store_true')
    ap.add_argument('--wait-scale', type=float, default=1)
    args = ap.parse_args()
    WAIT_SCALE = args.wait_scale
    args.tmux = os.path.abspath(args.tmux)
    if args.asan_tmux:
        args.asan_tmux = os.path.abspath(args.asan_tmux)
    only = [x for x in args.only.split(',') if x]
    modes = args.modes.split(',')
    work = tempfile.mkdtemp(prefix='gymmem-build-')
    heapcount = build_heapcount(work)
    failed = False

    def wanted(name):
        return not only or any(o in name for o in only)

    print('| check | scenario | mode | result |')
    print('|---|---|---|---|')
    for name, setup, step in SCENARIOS:
        if not wanted(name) or args.no_growth:
            continue
        for mode in modes:
            verdict, _ = run_growth(args, heapcount, name, setup, step, mode)
            print('| growth | %s | %s | %s |' % (name, mode, verdict),
                  flush=True)
            failed |= not verdict.startswith('flat')
    if not args.no_bounds:
        for name, fn, limit in BOUNDS:
            if not wanted(name):
                continue
            for mode in modes:
                verdict, _ = run_bound(args, heapcount, name, fn, limit, mode)
                print('| bounds | %s | %s | %s |' % (name, mode, verdict),
                      flush=True)
                failed |= not verdict.startswith('under')
    if args.asan_tmux:
        for name, setup, step in SCENARIOS:
            if not wanted(name):
                continue
            for mode in modes:
                verdict, _ = run_asan(args, name, setup, step, mode)
                print('| asan | %s | %s | %s |' % (name, mode, verdict),
                      flush=True)
                failed |= verdict != 'clean'
    if args.valgrind:
        for name, setup, step in SCENARIOS:
            if not wanted(name):
                continue
            for mode in modes:
                verdict = run_valgrind(args, name, setup, step, mode)
                print('| valgrind | %s | %s | %s |' % (name, mode, verdict),
                      flush=True)
                failed |= verdict != 'clean'
    shutil.rmtree(work, ignore_errors=True)
    for p in os.listdir(tempfile.gettempdir()):
        if p.startswith('gymmem-%d-' % os.getpid()):
            try:
                os.unlink(os.path.join(tempfile.gettempdir(), p))
            except OSError:
                pass
    for p in os.listdir('/dev/shm'):
        if p.startswith('gymmem-%d-' % os.getpid()):
            os.unlink(os.path.join('/dev/shm', p))
    sys.exit(1 if failed else 0)


if __name__ == '__main__':
    main()
