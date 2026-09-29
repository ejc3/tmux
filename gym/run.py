"""Run a program directly and inside tmux, in real ptys, with the same steps
and terminal events, and replay both byte streams on terminal profiles: the
terminal should end the same either way.

    python3 gym/run.py [--tmux BIN] [--only SCENARIO] [--profiles xterm,prompt]

A scenario is a program (gym/apps/*.py) and a list of steps:
  ('step',)              the program does its next step (it waits for a file)
  ('wait', seconds)
  ('resize', cols, rows) both ptys are resized; the terminal model is resized
                         at the same point of each stream
  ('hidden', k)          the terminal grows k rows and shrinks back without
                         telling anyone (a phone keyboard): only the model
                         sees it, at the same point of each stream
The tmux side uses what t-claude sets: clear-on-attach off, status off,
mouse off.

Verdicts per terminal profile: "same" (direct and through tmux end the same);
"tmux better" (they differ, but tmux leaves what the program meant - its
direct output on an xterm - where the direct run does not, as on a terminal
with a quirk tmux works around); "DIFFERS" otherwise.
"""

import fcntl
import os
import pty
import select
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import vt  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
PROFILES = {'xterm': vt.XTERM, 'iterm': vt.ITERM, 'prompt': vt.PROMPT, 'ghostty': vt.GHOSTTY}

SCENARIOS = {
    # Claude Code's input box: a conversation, then a box redrawn in place as
    # text is typed; the keyboard comes up (a hidden 3-row shift) mid-way.
    'keyboard-shift': ('inkbox.py', 51, 29, [('wait', 1.0), ('hidden', 3),
                                              ('step',), ('step',), ('step',)]),
    # Rows that fill the width exactly, then the cursor jumps elsewhere.
    'full-rows': ('fullrows.py', 51, 29, [('wait', 1.0), ('step',)]),
    # The keyboard goes up and down for real: resizes the program sees.
    'keyboard-resize': ('inkbox.py', 51, 29, [('wait', 1.0), ('resize', 51, 26), ('step',),
                                               ('resize', 51, 29), ('step',)]),
    # A rotation: the width changes while output streams.
    'rotate': ('stream.py', 51, 29, [('wait', 1.0), ('resize', 90, 20), ('step',),
                                     ('resize', 51, 29), ('step',)]),
}


def setsz(fd, cols, rows):
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('HHHH', rows, cols, 0, 0))


class Side:
    """One pty: the program itself, or a tmux client showing it."""

    def __init__(self, argv, cols, rows, env=None):
        self.buf = bytearray()
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            os.environ.update(env or {})
            os.environ.pop('TMUX', None)
            os.environ['TERM'] = 'xterm-256color'
            os.execvp(argv[0], argv)
        setsz(self.fd, cols, rows)

    def pump(self, t):
        end = time.time() + t
        while time.time() < end:
            r, _, _ = select.select([self.fd], [], [], 0.02)
            if r:
                try:
                    self.buf.extend(os.read(self.fd, 65536))
                except OSError:
                    return

    def resize(self, cols, rows):
        setsz(self.fd, cols, rows)
        os.kill(self.pid, signal.SIGWINCH)

    def close(self):
        try:
            os.kill(self.pid, signal.SIGKILL)
            os.waitpid(self.pid, 0)
        except OSError:
            pass


def run(name, tmux, out=None):
    app, cols, rows, steps = SCENARIOS[name]
    tmp = tempfile.mkdtemp(prefix='gym-run.')
    appv = ['python3', os.path.join(HERE, 'apps', app)]
    sock = os.path.join(tmp, 'sock')
    env = {k: v for k, v in os.environ.items() if k not in ('TMUX', 'TMUX_PANE')}
    base = [tmux, '-S', sock, '-f', '/dev/null']
    tdir = os.path.join(tmp, 't')
    os.mkdir(tdir)
    subprocess.run(base + ['new', '-d', '-x', str(cols), '-y', str(rows),
                           ' '.join(appv + [tdir])] + [';', 'set', '-g', 'status', 'off', ';',
                           'set', '-s', 'clear-on-attach', 'off', ';', 'set', '-g', 'mouse', 'off'],
                   env=env, check=True)
    bdir = os.path.join(tmp, 'b')
    os.mkdir(bdir)
    bare = Side(appv + [bdir], cols, rows)
    via = Side(base + ['attach'], cols, rows, env={})
    events = {'bare': [], 'tmux': []}
    n = 0
    try:
        for s in [('wait', 0.5)] + steps + [('wait', 1.0)]:
            if s[0] == 'wait':
                bare.pump(s[1] / 2); via.pump(s[1] / 2)
                bare.pump(s[1] / 2); via.pump(s[1] / 2)
            elif s[0] == 'step':
                n += 1
                for d in (bdir, tdir):
                    open(os.path.join(d, f'go{n}'), 'w').close()
                for _ in range(8):
                    bare.pump(0.05); via.pump(0.05)
            elif s[0] == 'resize':
                for side, key in ((bare, 'bare'), (via, 'tmux')):
                    events[key].append((len(side.buf), 'resize', s[1], s[2]))
                bare.resize(s[1], s[2]); via.resize(s[1], s[2])
                for _ in range(8):
                    bare.pump(0.05); via.pump(0.05)
            elif s[0] == 'hidden':
                for side, key in ((bare, 'bare'), (via, 'tmux')):
                    events[key].append((len(side.buf), 'hidden', s[1]))
        pane = subprocess.run(base + ['capturep', '-p'], capture_output=True, text=True,
                              env=env).stdout
    finally:
        bare.close(); via.close()
        subprocess.run(base + ['kill-server'], env=env, capture_output=True)
    if out:
        for k, b in (('bare', bare.buf), ('tmux', via.buf)):
            open(os.path.join(out, f'{name}.{k}.raw'), 'wb').write(bytes(b))
            open(os.path.join(out, f'{name}.{k}.ev'), 'w').write(
                ''.join(' '.join(map(str, e)) + '\n' for e in events[k]))
    return (cols, rows, bytes(bare.buf), bytes(via.buf), events, pane)


def replay(data, events, cols, rows, q):
    t = vt.Term(cols, rows, q)
    at = 0
    for ev in events:
        off = ev[0]
        t.feed(data[at:off])
        at = off
        if ev[1] == 'resize':
            t.resize(ev[2], ev[3])
        elif ev[1] == 'hidden':
            t.hidden_shift(ev[2])
    t.feed(data[at:])
    return t


def screen(t):
    return [t.row_text(i) for i in range(t.r)]


def main():
    args = sys.argv[1:]
    tmux = args[args.index('--tmux') + 1] if '--tmux' in args else 'tmux'
    only = args[args.index('--only') + 1] if '--only' in args else None
    profs = (args[args.index('--profiles') + 1] if '--profiles' in args
             else 'xterm,iterm,prompt,ghostty').split(',')
    out = args[args.index('--out') + 1] if '--out' in args else None
    bad = 0
    for name in SCENARIOS:
        if only and name != only:
            continue
        cols, rows, b, t, ev, pane = run(name, tmux, out)
        for p in profs:
            q = PROFILES[p]
            tb = replay(b, ev['bare'], cols, rows, q)
            tt = replay(t, ev['tmux'], cols, rows, q)
            sb, st = screen(tb), screen(tt)
            # What the program meant: its direct output on an xterm.
            si = screen(replay(b, ev['bare'], cols, rows, vt.XTERM))
            if sb == st:
                verdict = 'same'
            elif st == si:
                verdict = 'tmux better (the direct run is wrong on this terminal)'
            else:
                verdict = 'DIFFERS'
            ok = verdict != 'DIFFERS'
            bad += not ok
            print(f'{name:18s} {p:8s} {verdict}')
            if not ok and '--show' in args:
                for i in range(len(sb)):
                    print(f'   {i:2d} {" " if sb[i] == st[i] else "X"} direct|{sb[i]:{cols}s}| tmux|{st[i]}|')
    sys.exit(1 if bad else 0)


if __name__ == '__main__':
    main()
