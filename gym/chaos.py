"""Chaos soak: one tmux server, many panes and terminals, every feature the
fork adds at once, on a random schedule for hours.

    python3 gym/chaos.py --tmux BIN [--asan | --heapcount] [--seed N]
                         [--hours H] [--out DIR]
    python3 gym/chaos.py --tmux BIN --replay DIR/actions.jsonl [--asan]

About twenty panes over several sessions and windows (split, zoomed,
swapped, moved, broken out, joined, killed and respawned) each run
gym/memory/feeder.py, which writes what the soak gives it. Four terminals
attach over ptys (gym/memory.py's Terminal: kitty's answers, job control):
one fast, one slow (100 KB/s), one that stops reading for seconds at a time
and one that never answers. Actions are drawn from a seeded schedule:
protocol output from panes (kitty keyboard, graphics of every kind, OSC 66,
22, 99, 9, 777, modes 1016, 2048, 2027, DECSTR, RIS, the alternate screen),
input from terminals (keys, mouse, notification replies), resizes (pixels
only too), suspends, detaches, kills, copy mode, captures and options
changed live.

Every few seconds the soak checks that the server answers within five
seconds and, on an --asan build (-fsanitize=address,undefined), that no
sanitizer has reported. With --heapcount (gym/memory/heapcount.c preloaded)
it samples the server's live heap every 30 seconds; at the end it fits a
line to the samples after warm-up and reports the slope.

Each action and its parameters go to actions.jsonl as they are done; a
failure saves the server's report and the actions before it, and the soak
starts a new server and goes on. --replay runs a saved list of actions.
"""

import argparse
import base64
import errno
import json
import os
import random
import re
import select
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import memory  # noqa: E402
from memory import (ST, Fail, Server, Terminal, b64, gfx, png,  # noqa: E402
                    placeholder, wait)

KB = 1024
MB = 1024 * KB


class ChaosTerminal(Terminal):
    """A Terminal whose reads can stall and whose writes never block: a
    stopped client stops reading its pty, and the soak must not stop."""

    def __init__(self, server, kind, **kw):
        self.kind = kind
        self.stall_until = 0
        rate = 100 * KB if kind == 'slow' else None
        super().__init__(server, rate=rate, silent=(kind == 'silent'), **kw)

    def read(self):
        start = time.time()
        while not self.closing:
            if time.time() < self.stall_until:
                time.sleep(0.05)
                continue
            want = 65536
            if self.rate:
                allowed = int((time.time() - start) * self.rate) - self.total
                if allowed <= 0:
                    time.sleep(0.01)
                    continue
                want = min(want, allowed)
            try:
                r, _, _ = select.select([self.fd], [], [], 0.2)
            except (OSError, ValueError):
                return
            if not r:
                continue
            try:
                data = os.read(self.fd, want)
            except BlockingIOError:
                continue
            except OSError:
                return
            if not data:
                return
            with self.lock:
                self.total += len(data)
                self.last = time.time()
            if not self.silent:
                self.answer(data)
                del self.notify_ids[:-32]

    def send(self, data):
        end = time.time() + 1
        while data and time.time() < end:
            try:
                _, w, _ = select.select([], [self.fd], [], 0.1)
            except (OSError, ValueError):
                return
            if not w:
                continue
            try:
                n = os.write(self.fd, data[:4096])
            except BlockingIOError:
                continue
            except OSError:
                return
            data = data[n:]

    def alive(self):
        return self.proc.poll() is None


# --- What panes write -------------------------------------------------------

RGB1 = memory.RGB1
RGBA2 = memory.RGBA2


def out_keys_flags(r):
    n = r.choice([1, 3, 5, 8, 15, 31])
    return [b'\033[>%du' % n, b'\033[<%du' % r.randint(1, 3),
            b'\033[=%d;%du' % (n, r.randint(1, 3)), b'\033[?u'][r.randint(0, 3)]


def out_gfx(r, tmp):
    iid = r.randint(1, 40)
    kind = r.randint(0, 11)
    if kind == 0:
        return gfx(b'a=T,f=24,s=1,v=1,i=%d,q=2' % iid, RGB1)
    if kind == 1:
        return gfx(b'a=T,f=32,s=2,v=2,i=%d,U=1,q=2' % iid, RGBA2)
    if kind == 2:
        data = b64(os.urandom(3 * 32 * 32))
        chunks = [data[n:n + 4096] for n in range(0, len(data), 4096)]
        s = gfx(b'a=t,f=24,s=32,v=32,i=%d,q=2,m=1' % iid, chunks[0])
        for c in chunks[1:-1]:
            s += gfx(b'm=1', c)
        if r.random() < 0.2:
            return s    # never finished
        return s + gfx(b'm=0', chunks[-1])
    if kind == 3:
        path = memory.tmpimage(tmp, os.urandom(3 * 16 * 16), 'f%d' % iid)
        return gfx(b'a=t,f=24,s=16,v=16,t=f,i=%d,q=2' % iid,
                   b64(path.encode()))
    if kind == 4:
        path = memory.tmpimage(tmp, os.urandom(3 * 16 * 16),
                               't%d' % r.randint(0, 1 << 30))
        return gfx(b'a=t,f=24,s=16,v=16,t=t,i=%d,q=2' % iid,
                   b64(path.encode()))
    if kind == 5:
        path = memory.shmimage(os.urandom(3 * 16 * 16),
                               's%d' % r.randint(0, 1 << 30))
        return gfx(b'a=t,f=24,s=16,v=16,t=s,i=%d,q=2' % iid,
                   b64(os.path.basename(path).encode()))
    if kind == 6:
        return gfx(b'a=p,i=%d,p=%d,U=1,c=%d,r=%d,q=2'
                   % (iid, r.randint(1, 9), r.randint(1, 4), r.randint(1, 3)))
    if kind == 7:
        return (b'\033[38;5;%dm' % iid
                + placeholder(r.randint(0, 2), r.randint(0, 2),
                              r.choice([None, None, 1, 2]))
                + placeholder(0, 1) + b'\033[39m')
    if kind == 8:
        return r.choice([gfx(b'a=d,d=I,i=%d' % iid), gfx(b'a=d,d=i,i=%d' % iid),
                         gfx(b'a=d,d=a'), gfx(b'a=d,d=A'),
                         gfx(b'a=d,d=p,x=1,y=1'),
                         gfx(b'a=d,d=I,i=%d,p=%d' % (iid, r.randint(1, 9)))])
    if kind == 9:
        return (gfx(b'a=f,i=%d,f=32,s=2,v=2,q=2' % iid, RGBA2)
                + gfx(b'a=a,i=%d,s=3,v=1,q=2' % iid)
                + gfx(b'a=c,i=%d,r=1,c=2,q=2' % iid))
    if kind == 10:
        return gfx(b'a=q,i=%d,s=1,v=1,f=24' % iid, b'AAAA')
    return gfx(b'a=t,f=100,i=%d,q=2' % iid, b64(png(2, 2)))


def out_text(r):
    return r.choice([
        b'\033]66;w=%d;x\007' % r.randint(0, 7),
        b'\033]66;w=2;\xe4\xb8\xad\007\033]66;w=3;e\xcc\x81\007',
        b'\033]66;w=2;\xf0\007', b'\033]66;s=2;x\007',
        '\U0001F469‍\U0001F4BB 1️⃣ é̂'.encode(),
        b'line of text\r\n' * r.randint(1, 30),
        b'\033[%d;%dH' % (r.randint(1, 40), r.randint(1, 120)),
        b'\033]8;;http://x/%d\007link\033]8;;\007' % r.randint(0, 99),
    ])


def out_pointer(r):
    return r.choice([b'\033]22;>crosshair,wait' + ST, b'\033]22;<' + ST,
                     b'\033]22;?__current__' + ST, b'\033]22;text' + ST,
                     b''.join(b'\033]22;>p%d' % n + ST for n in range(20))])


def out_notify(r):
    n = b'n%d' % r.randint(0, 20)
    return r.choice([
        b'\033]99;i=' + n + b':d=0;title' + ST
        + b'\033]99;i=' + n + b':p=body:a=report:c=1;body' + ST,
        b'\033]99;;anon' + ST, b'\033]99;i=q:p=?;' + ST,
        b'\033]99;i=al:p=alive;' + ST, b'\033]99;i=' + n + b':p=close;' + ST,
        b'\033]9;hello\007', b'\033]9;9;/tmp\007', b'\033]9;4;1;50\007',
        b'\033]777;notify;t;b\007'])


def out_modes(r):
    m = r.choice([b'1016', b'2048', b'2027', b'1000', b'1003', b'1006',
                  b'1049', b'2026', b'7', b'1004'])
    return b'\033[?' + m + r.choice([b'h', b'l'])


# Insert mode (IRM) with OSC 66 wider than two cells near the right edge
# overruns the line (grid_view_insert_cells), and a pane killed while a
# mouse menu shows it is read after it is freed (menu_reapply_styles):
# --skip-known leaves out insert mode and the mouse option.
INSERT = True


def out_reset(r):
    return r.choice([b'\033[!p', b'\033c', b'\033[5;10r', b'\033[r',
                     b'\033[4h' if INSERT else b'\033[4l', b'\033[4l',
                     b'\033(0', b'\033(B'])


PANE_OUTPUT = [
    (6, 'keys-flags', lambda r, t: out_keys_flags(r)),
    (14, 'gfx', out_gfx),
    (10, 'text', lambda r, t: out_text(r)),
    (4, 'pointer', lambda r, t: out_pointer(r)),
    (5, 'notify', lambda r, t: out_notify(r)),
    (6, 'modes', lambda r, t: out_modes(r)),
    (2, 'reset', lambda r, t: out_reset(r)),
]

# --- What terminals send ------------------------------------------------------


def in_bytes(r, term):
    kind = r.randint(0, 5)
    if kind == 0:
        return memory.LEGACY_KEYS
    if kind == 1:
        return memory.KITTY_KEYS
    if kind == 2:
        return b'\033[<%d;%d;%d%s' % (r.choice([0, 1, 2, 32, 35, 64, 65]),
                                      r.randint(0, 3000), r.randint(0, 2000),
                                      r.choice([b'M', b'm']))
    if kind == 3:
        ids = list(term.notify_ids[-4:]) or [b't0_x']
        nid = r.choice(ids)
        return r.choice([b'\033]99;i=' + nid + b';' + ST,
                         b'\033]99;i=' + nid + b':p=close;' + ST,
                         b'\033]99;i=t%d_x:p=alive;t0_a,t1_b' % r.randint(0, 30)
                         + ST])
    if kind == 4:
        return r.choice([b'\033[I', b'\033[O', b'\033_Gi=31;OK' + ST,
                         b'\033[?2027;2$y', b'\033[?997;1n'])
    return bytes(r.randint(32, 126) for _ in range(r.randint(1, 40)))


# --- The soak ---------------------------------------------------------------

class Chaos:
    KINDS = ['fast', 'slow', 'stall', 'silent']

    def __init__(self, args, out, run):
        self.args = args
        self.out = out
        self.run = run
        self.dir = os.path.join(out, 'run%d' % run)
        os.makedirs(self.dir)
        self.server = Server(args.tmux, self.dir, 'forward', args.heapcount_so,
                             args.asan)
        if not args.asan:
            # Why a server without sanitizers went: chaos_lib/crashtrace.c.
            env = self.server.env
            env['LD_PRELOAD'] = ':'.join(
                x for x in (env.get('LD_PRELOAD'), args.crashtrace_so) if x)
            env['CRASHTRACE_DIR'] = self.dir
        self.anchor = None
        self.panes = {}     # pane id -> (fifo, fd)
        self.terms = []
        self.suspended = {}  # terminal -> time to resume
        self.nfifo = 0
        self.actions = 0
        # A size without pixels makes tty_resize query the terminal: with
        # a client exiting, that read freed memory (upstream; see
        # --zero-pixels).
        self.pixels = [8, 16, 17] + ([0] if args.zero_pixels else [])

    def fifo(self):
        self.nfifo += 1
        path = os.path.join(self.dir, 'f%d' % self.nfifo)
        os.mkfifo(path)
        return path

    def feeder(self, fifo):
        return memory.Gym.feeder_for(fifo)

    def open_fifo(self, fifo):
        return os.open(fifo, os.O_RDWR | os.O_NONBLOCK)

    def start(self):
        # An anchor session nothing kills, so the server always has one.
        self.server.start('exec sleep 100000')
        # Only the server is traced: clients exit 1 when a command fails.
        env = self.server.env
        env.pop('CRASHTRACE_DIR', None)
        if env.get('LD_PRELOAD'):
            env['LD_PRELOAD'] = ':'.join(
                x for x in env['LD_PRELOAD'].split(':')
                if 'crashtrace' not in x)
            if not env['LD_PRELOAD']:
                del env['LD_PRELOAD']
        self.server.cmd('rename-session', 'anchor')
        # Kills can leave no session at all: the server must stay.
        self.server.cmd('set', '-s', 'exit-empty', 'off')
        self.server.cmd('set', '-g', 'history-limit',
                        str(self.args.history))
        self.server.cmd('set', '-g', 'remain-on-exit', 'off')
        for n in range(4):
            self.new_session()
        for kind in self.KINDS:
            self.attach(kind)

    def add_pane(self, pane, fifo):
        self.panes[pane] = (fifo, self.open_fifo(fifo))

    def new_session(self):
        fifo = self.fifo()
        pane = self.server.cmd('new-session', '-d', '-P', '-F', '#{pane_id}',
                               '-x', '80', '-y', '24',
                               self.feeder(fifo)).strip()
        self.add_pane(pane, fifo)

    def attach(self, kind):
        t = ChaosTerminal(self.server, kind, rows=random.randint(10, 50),
                          cols=random.randint(20, 200))
        self.terms.append(t)

    def live_panes(self):
        out = self.server.cmd('list-panes', '-a', '-F', '#{pane_id}',
                              check=False, timeout=10)
        live = set(out.split())
        for pane in list(self.panes):
            if pane not in live:
                fifo, fd = self.panes.pop(pane)
                os.close(fd)
        return [p for p in self.panes if p in live]

    # Each action is (name, params): params are drawn here and logged, so a
    # replay does not need the random generator.
    def draw(self, r):
        panes = sorted(self.panes)
        terms = list(range(len(self.terms)))
        choices = []
        if panes:
            for weight, name, fn in PANE_OUTPUT:
                choices.append((weight, 'write',
                                lambda name=name, fn=fn: {
                                    'pane': r.choice(panes),
                                    'what': name,
                                    'data': base64.b64encode(
                                        fn(r, self.dir)).decode()}))
            choices += [
                (2, 'split', lambda: {'pane': r.choice(panes),
                                      'h': r.random() < 0.5}),
                (1, 'new-window', lambda: {'pane': r.choice(panes)}),
                (1, 'kill-pane', lambda: {'pane': r.choice(panes)}),
                (1, 'respawn', lambda: {'pane': r.choice(panes)}),
                (1, 'zoom', lambda: {'pane': r.choice(panes)}),
                (1, 'swap', lambda: {'a': r.choice(panes),
                                     'b': r.choice(panes)}),
                (1, 'break', lambda: {'pane': r.choice(panes)}),
                (1, 'join', lambda: {'a': r.choice(panes),
                                     'b': r.choice(panes)}),
                (1, 'kill-window', lambda: {'pane': r.choice(panes)}),
                (1, 'copy-mode', lambda: {'pane': r.choice(panes),
                                          'keys': r.sample(
                                              ['cursor-up', 'page-up',
                                               'begin-selection',
                                               'history-top',
                                               'copy-selection-no-clear',
                                               'cancel', 'search-backward'],
                                              3)}),
                (2, 'capture', lambda: {'pane': r.choice(panes)}),
                (1, 'clear-history', lambda: {'pane': r.choice(panes)}),
                (1, 'resize-window', lambda: {'pane': r.choice(panes),
                                              'x': r.randint(10, 200),
                                              'y': r.randint(5, 60)}),
            ]
        choices += [
            (1, 'new-session', lambda: {}),
            (1, 'kill-session', lambda: {}),
            (1, 'option', lambda: r.choice([
                {'args': ['set', '-s', 'clear-on-attach',
                          r.choice(['on', 'off'])]},
                {'args': ['set', '-s', 'forward-output',
                          r.choice(['on', 'off'])]},
                {'args': ['set', '-s', 'extended-keys',
                          r.choice(['on', 'off', 'always'])]},
                {'args': ['set', '-g', 'window-size',
                          r.choice(['latest', 'largest', 'smallest'])]},
                {'args': ['set', '-g', 'status', r.choice(['on', 'off'])]},
                {'args': ['set', '-g', 'mouse',
                          r.choice(['on', 'off']) if INSERT else 'off']}])),
        ]
        if terms:
            choices += [
                (12, 'type', lambda: {
                    't': r.choice(terms),
                    'data': base64.b64encode(
                        in_bytes(r, self.terms[r.choice(terms)])).decode()}),
                (3, 'resize', lambda: {'t': r.choice(terms),
                                       'rows': r.randint(5, 60),
                                       'cols': r.randint(10, 220),
                                       'xp': r.choice(self.pixels),
                                       'yp': r.choice(self.pixels) * 2}),
                (1, 'stall', lambda: {'t': r.choice(terms),
                                      'secs': r.uniform(0.5, 8)}),
                (1, 'suspend', lambda: {'t': r.choice(terms),
                                        'secs': r.uniform(0.1, 3)}),
                (1, 'detach', lambda: {'t': r.choice(terms)}),
                (2, 'switch', lambda: {'t': r.choice(terms)}),
            ]
        total = sum(c[0] for c in choices)
        pick = r.uniform(0, total)
        for weight, name, params in choices:
            pick -= weight
            if pick <= 0:
                return name, params()
        return choices[-1][1], choices[-1][2]()

    def term(self, i):
        if i < len(self.terms):
            return self.terms[i]
        return None

    def do(self, name, p):
        cmd = self.server.cmd
        if name == 'write':
            if p['pane'] in self.panes:
                try:
                    os.write(self.panes[p['pane']][1],
                             base64.b64decode(p['data']))
                except OSError as e:
                    if e.errno != errno.EAGAIN:
                        raise
        elif name == 'split':
            fifo = self.fifo()
            pane = cmd('split-window', '-d', '-h' if p['h'] else '-v', '-P',
                       '-F', '#{pane_id}', '-t', p['pane'], self.feeder(fifo),
                       check=False).strip()
            if pane.startswith('%'):
                self.add_pane(pane, fifo)
        elif name == 'new-window':
            fifo = self.fifo()
            pane = cmd('new-window', '-d', '-P', '-F', '#{pane_id}', '-t',
                       p['pane'], self.feeder(fifo), check=False).strip()
            if pane.startswith('%'):
                self.add_pane(pane, fifo)
        elif name == 'kill-pane':
            cmd('kill-pane', '-t', p['pane'], check=False)
        elif name == 'respawn':
            if p['pane'] in self.panes:
                cmd('respawn-pane', '-k', '-t', p['pane'],
                    self.feeder(self.panes[p['pane']][0]), check=False)
        elif name == 'zoom':
            cmd('resize-pane', '-Z', '-t', p['pane'], check=False)
        elif name == 'swap':
            cmd('swap-pane', '-d', '-s', p['a'], '-t', p['b'], check=False)
        elif name == 'break':
            cmd('break-pane', '-d', '-s', p['pane'], check=False)
        elif name == 'join':
            cmd('join-pane', '-d', '-s', p['a'], '-t', p['b'], check=False)
        elif name == 'kill-window':
            cmd('kill-window', '-t', p['pane'], check=False)
        elif name == 'copy-mode':
            cmd('copy-mode', '-t', p['pane'], check=False)
            for k in p['keys']:
                cmd('send-keys', '-t', p['pane'], '-X', k, check=False)
        elif name == 'capture':
            cmd('capture-pane', '-p', '-e', '-C', '-t', p['pane'],
                check=False)
        elif name == 'clear-history':
            cmd('clear-history', '-t', p['pane'], check=False)
        elif name == 'resize-window':
            cmd('resize-window', '-t', p['pane'], '-x', str(p['x']), '-y',
                str(p['y']), check=False)
        elif name == 'new-session':
            if len(self.panes) < 30:
                self.new_session()
        elif name == 'kill-session':
            sessions = [s for s in cmd('list-sessions', '-F',
                                       '#{session_name}',
                                       check=False).split()
                        if s != 'anchor']
            if len(sessions) > 2:
                cmd('kill-session', '-t', sorted(sessions)[0], check=False)
        elif name == 'option':
            cmd(*p['args'], check=False)
        elif name == 'type':
            t = self.term(p['t'])
            if t:
                t.send(base64.b64decode(p['data']))
        elif name == 'resize':
            t = self.term(p['t'])
            if t:
                t.size(p['rows'], p['cols'], p['xp'], p['yp'])
        elif name == 'stall':
            t = self.term(p['t'])
            if t:
                t.stall_until = time.time() + p['secs']
        elif name == 'suspend':
            t = self.term(p['t'])
            if t and t not in self.suspended:
                cmd('suspend-client', '-t', t.tty(), check=False)
                self.suspended[t] = time.time() + p['secs']
        elif name == 'detach':
            t = self.term(p['t'])
            if t:
                cmd('detach-client', '-t', t.tty(), check=False)
        elif name == 'switch':
            t = self.term(p['t'])
            if t:
                sessions = cmd('list-sessions', '-F', '#{session_name}',
                               check=False).split()
                if sessions:
                    cmd('switch-client', '-c', t.tty(), '-t',
                        sessions[self.actions % len(sessions)], check=False)

    def upkeep(self):
        now = time.time()
        for t, when in list(self.suspended.items()):
            if now >= when:
                for pid in (t.pid,):
                    try:
                        os.kill(pid, signal.SIGCONT)
                    except (ProcessLookupError, TypeError):
                        pass
                del self.suspended[t]
        # Terminals that went (detached, their session killed) come back.
        for i, t in enumerate(self.terms):
            if not t.alive():
                self.suspended.pop(t, None)
                t.close()
                self.terms[i] = ChaosTerminal(self.server, t.kind,
                                              rows=random.randint(10, 50),
                                              cols=random.randint(20, 200))
        while len(self.panes) < 8:
            self.new_session()

    def asan_reports(self):
        found = []
        for f in os.listdir(self.dir):
            if f.startswith('asan.') or f.startswith('ubsan.'):
                text = open(os.path.join(self.dir, f),
                            errors='replace').read()
                if f.endswith('.%d' % self.server.pid) or \
                        'runtime error' in text:
                    found.append((f, text))
        return found

    def crash_trace(self):
        path = os.path.join(self.dir, 'crash.%d' % self.server.pid)
        if not os.path.exists(path):
            return ''
        text = open(path, errors='replace').read()
        maps = []
        for line in text.split('\n'):
            m = re.match(r'([0-9a-f]+)-([0-9a-f]+) (\S+) ([0-9a-f]+) \S+ \S+ +'
                         r'(/\S+)', line)
            if m and 'x' in m.group(3):
                maps.append((int(m.group(1), 16), int(m.group(2), 16),
                             int(m.group(4), 16), m.group(5)))
        out = [text.split('\n')[0]]
        for a in re.findall(r'frame 0x([0-9a-f]+)', text):
            addr = int(a, 16)
            for lo, hi, off, path in maps:
                if lo <= addr < hi:
                    name = subprocess.run(
                        ['addr2line', '-f', '-C', '-i', '-e', path,
                         hex(addr - lo + off - 1)], capture_output=True,
                        text=True).stdout.split('\n')
                    out.append('  %s %s (%s)' % (name[0], name[1] if
                                                  len(name) > 1 else '',
                                                  os.path.basename(path)))
                    break
            else:
                out.append('  0x%x' % addr)
        return '\n'.join(out) + '\n'

    def responsive(self):
        try:
            out = self.server.cmd('display', '-p', 'ok', timeout=5,
                                  check=False)
            return out.strip() == 'ok'
        except subprocess.TimeoutExpired:
            return False

    def backtrace(self):
        try:
            return subprocess.run(
                ['sudo', '-n', 'gdb', '-p', str(self.server.pid), '-batch',
                 '-ex', 'thread apply all bt'], capture_output=True,
                text=True, timeout=60).stdout
        except Exception as e:     # noqa: BLE001
            return 'no backtrace: %s' % e

    def close(self):
        for t in self.terms:
            try:
                t.close()
            except Exception:  # noqa: BLE001
                pass
        for fifo, fd in self.panes.values():
            try:
                os.close(fd)
            except OSError:
                pass
        try:
            self.server.kill()
        except Exception:  # noqa: BLE001
            pass


def record_failure(out, chaos, kind, detail, recent):
    path = os.path.join(out, 'failure-%d-%s' % (chaos.run, kind))
    os.makedirs(path, exist_ok=True)
    with open(os.path.join(path, 'detail.txt'), 'w') as f:
        f.write(detail)
    with open(os.path.join(path, 'actions.jsonl'), 'w') as f:
        for a in recent:
            f.write(json.dumps(a) + '\n')
    print('%s FAILURE %s in run %d after %d actions: %s' % (
        time.strftime('%H:%M:%S'), kind, chaos.run, chaos.actions,
        detail.strip().split('\n')[0][:200]), flush=True)


def slope(samples):
    # Least squares of live bytes on minutes.
    n = len(samples)
    if n < 3:
        return 0.0
    xs = [s[0] / 60 for s in samples]
    ys = [s[1] for s in samples]
    mx, my = sum(xs) / n, sum(ys) / n
    den = sum((x - mx) ** 2 for x in xs)
    return sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / den if den \
        else 0.0


def fails(args, actions, work):
    # Run actions as a replay in a new process; whether it fails as wanted.
    path = os.path.join(work, 'try.jsonl')
    with open(path, 'w') as f:
        for a in actions:
            f.write(json.dumps(a) + '\n')
    out = tempfile.mkdtemp(prefix='try-', dir=work)
    cmd = [sys.executable, os.path.abspath(__file__), '--tmux', args.tmux,
           '--replay', path, '--out', out, '--rate', str(args.rate)]
    if args.asan:
        cmd.append('--asan')
    subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                   timeout=600)
    for d in os.listdir(out):
        if d.startswith('failure-'):
            text = open(os.path.join(out, d, 'detail.txt'),
                        errors='replace').read()
            if re.search(args.signature, text):
                shutil.rmtree(out, ignore_errors=True)
                return True
    shutil.rmtree(out, ignore_errors=True)
    return False


def shrink(args):
    # Remove chunks of actions while the failure stays (ddmin, greedy).
    actions = [json.loads(line) for line in open(args.shrink)]
    work = tempfile.mkdtemp(prefix='shrink-', dir='/mnt/fcvm-btrfs')
    if not fails(args, actions, work):
        print('shrink: the list does not fail as given')
        return 1
    n = 2
    while len(actions) >= 2:
        size = max(1, len(actions) // n)
        removed = False
        for start in range(0, len(actions), size):
            trial = actions[:start] + actions[start + size:]
            if trial and fails(args, trial, work):
                actions = trial
                print('shrink: %d actions' % len(actions), flush=True)
                n = max(n - 1, 2)
                removed = True
                break
        if not removed:
            if size == 1:
                break
            n = min(n * 2, len(actions))
    path = args.shrink.replace('.jsonl', '') + '-shrunk.jsonl'
    with open(path, 'w') as f:
        for a in actions:
            f.write(json.dumps(a) + '\n')
    print('shrink: %d actions in %s' % (len(actions), path))
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--tmux', required=True)
    ap.add_argument('--asan', action='store_true')
    ap.add_argument('--heapcount', action='store_true')
    ap.add_argument('--seed', type=int, default=1)
    ap.add_argument('--hours', type=float, default=2)
    ap.add_argument('--rate', type=float, default=40,
                    help='actions a second')
    ap.add_argument('--heap-bound', type=int, default=1024,
                    help='MB of live heap allowed')
    ap.add_argument('--warmup', type=float, default=15,
                    help='minutes before heap samples count for the trend')
    ap.add_argument('--out', default=None)
    ap.add_argument('--replay')
    ap.add_argument('--skip-known', action='store_true',
                    help='leave out what triggers crashes already found')
    ap.add_argument('--history', type=int, default=100,
                    help='history-limit for panes')
    ap.add_argument('--zero-pixels', action='store_true',
                    help='resize terminals to sizes without pixels too')
    ap.add_argument('--shrink', help='an actions.jsonl that fails: find a '
                    'smaller list that still fails with --signature')
    ap.add_argument('--signature', default='ERROR: AddressSanitizer',
                    help='regular expression the failure must match')
    args = ap.parse_args()
    args.tmux = os.path.abspath(args.tmux)
    if args.shrink:
        sys.exit(shrink(args))
    if args.skip_known:
        global INSERT
        INSERT = False
    out = args.out or tempfile.mkdtemp(prefix='chaos-', dir='/mnt/fcvm-btrfs')
    os.makedirs(out, exist_ok=True)
    args.heapcount_so = (memory.build_heapcount(out) if args.heapcount
                         else None)
    args.crashtrace_so = os.path.join(out, 'crashtrace.so')
    subprocess.run(['cc', '-O2', '-shared', '-fPIC', '-o', args.crashtrace_so,
                    os.path.join(HERE, 'chaos_lib', 'crashtrace.c'), '-ldl'],
                   check=True, stderr=subprocess.DEVNULL)
    r = random.Random(args.seed)
    random.seed(args.seed)
    log = open(os.path.join(out, 'actions.jsonl'), 'a')
    replay = None
    if args.replay:
        replay = [json.loads(line) for line in open(args.replay)]
    print('chaos: seed %d, %s, out %s' % (args.seed, args.tmux, out),
          flush=True)

    start = time.time()
    end = start + args.hours * 3600
    run = 0
    failures = 0
    total_actions = 0
    samples = []        # (seconds since start, live bytes) after warm-up
    peak = 0
    while time.time() < end:
        run += 1
        chaos = Chaos(args, out, run)
        recent = []
        try:
            chaos.start()
        except Exception as e:  # noqa: BLE001
            record_failure(out, chaos, 'start', repr(e), recent)
            failures += 1
            chaos.close()
            if replay:
                break
            continue
        last_check = last_heap = last_live = time.time()
        step = 0
        broken = False
        while time.time() < end:
            if replay is not None:
                if step >= len(replay):
                    break
                name, params = replay[step]['name'], replay[step]['params']
            else:
                name, params = chaos.draw(r)
            step += 1
            entry = {'run': run, 'n': chaos.actions, 't': round(
                time.time() - start, 3), 'name': name, 'params': params}
            log.write(json.dumps(entry) + '\n')
            recent.append(entry)
            del recent[:-400]
            try:
                chaos.do(name, params)
            except (Fail, subprocess.TimeoutExpired) as e:
                entry['error'] = repr(e)
            except OSError as e:
                entry['error'] = repr(e)
            chaos.actions += 1
            total_actions += 1
            time.sleep(1 / args.rate)
            now = time.time()
            if now - last_live > 2:
                last_live = now
                try:
                    chaos.live_panes()
                    chaos.upkeep()
                except (Fail, subprocess.TimeoutExpired) as e:
                    entry['error'] = repr(e)
            if now - last_check > 3:
                last_check = now
                if not chaos.server.alive():
                    detail = 'server died\n' + chaos.crash_trace()
                    for f, text in chaos.asan_reports():
                        detail += '\n== %s\n%s' % (f, text)
                    record_failure(out, chaos, 'died', detail, recent)
                    broken = True
                elif chaos.asan_reports():
                    detail = ''.join('\n== %s\n%s' % (f, t)
                                     for f, t in chaos.asan_reports())
                    record_failure(out, chaos, 'sanitizer', detail, recent)
                    broken = True
                elif not chaos.responsive() and not chaos.responsive():
                    record_failure(out, chaos, 'hang', chaos.backtrace(),
                                   recent)
                    broken = True
            if (args.heapcount and not broken and now - last_heap > 30):
                last_heap = now
                try:
                    live, blocks, pk = chaos.server.heap()
                    peak = max(peak, pk)
                    elapsed = now - start
                    with open(os.path.join(out, 'heap.tsv'), 'a') as f:
                        f.write('%d\t%d\t%d\t%d\t%d\n' % (
                            elapsed, run, live, blocks, pk))
                    if elapsed > args.warmup * 60 and run == 1:
                        samples.append((elapsed, live))
                    if live > args.heap_bound * MB:
                        record_failure(out, chaos, 'heap',
                                       'live heap %d MB over %d MB' % (
                                           live // MB, args.heap_bound),
                                       recent)
                        broken = True
                except Fail as e:
                    entry['error'] = repr(e)
                except ProcessLookupError:
                    pass    # the server went: the next check records it
            if broken:
                failures += 1
                break
        pid = chaos.server.pid
        chaos.close()
        if args.asan and not broken:
            # LeakSanitizer reports as the server exits.
            leaks = [(f, t) for f, t in chaos.asan_reports()
                     if f.endswith('.%d' % pid)]
            if leaks:
                record_failure(out, chaos, 'leak', ''.join(
                    '\n== %s\n%s' % (f, t) for f, t in leaks), recent)
                failures += 1
        if replay is not None:
            break
        if not broken:
            break

    hours = (time.time() - start) / 3600
    print('chaos: %.2f hours, %d actions, %d servers, %d failures' % (
        hours, total_actions, run, failures), flush=True)
    if args.heapcount:
        s = slope(samples)
        print('heap: peak %d MB; slope after warm-up %.0f bytes/minute over '
              '%d samples' % (peak // MB, s, len(samples)), flush=True)
        # Hour by hour.
        if samples:
            t0 = samples[0][0]
            hour = 0
            while True:
                w = [x for x in samples
                     if t0 + hour * 3600 <= x[0] < t0 + (hour + 1) * 3600]
                if not w:
                    break
                print('heap: window %d: %.0f bytes/minute, %d..%d KB' % (
                    hour, slope(w), min(x[1] for x in w) // KB,
                    max(x[1] for x in w) // KB), flush=True)
                hour += 1
    for p in os.listdir(tempfile.gettempdir()):
        if p.startswith('gymmem-%d-' % os.getpid()):
            try:
                os.unlink(os.path.join(tempfile.gettempdir(), p))
            except OSError:
                pass
    for p in os.listdir('/dev/shm'):
        if p.startswith('gymmem-%d-' % os.getpid()):
            try:
                os.unlink(os.path.join('/dev/shm', p))
            except OSError:
                pass
    sys.exit(1 if failures else 0)


if __name__ == '__main__':
    main()
