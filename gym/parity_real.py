"""render-parity with real terminals as the judge.

regress/render-parity.sh uses a tmux pane as the terminal, so a technique
that only works because the terminal is tmux (tmux's own quirks) passes there
and fails on every other terminal. Here each render-parity case runs in a pty
directly and through a tmux client (clear-on-attach off, as in
render-parity.sh), and both byte streams are replayed in Ghostty, libvterm
and Alacritty: the rows and joined lines after the case's marker must match.

    python3 gym/parity_real.py [--tmux BIN] [--only NAME] [--engines ghostty,libvterm,alacritty]
                               [--keep DIR]

Every case runs in three ways: scrollback (clear-on-attach off, the terminal
keeps its own scrollback; a whole-terminal pane is forwarded as written;
everything is compared), translate (the same with forward-output off, so tmux
draws from its grid; everything is compared) and default (clear-on-attach on:
tmux keeps to the terminal's alternate screen and never writes into its
scrollback; the visible screen is compared). --mode picks one; a tmux without
forward-output runs scrollback and default.

--keep DIR saves, per case, the two streams (direct.raw, tmux.raw) and each
engine's rows after the marker (ENGINE.direct, ENGINE.tmux) for gym/report.py.
"""
import json

import os
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import consensus  # noqa: E402
import run        # noqa: E402
import validate   # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
COLS, ROWS = 80, 24
MARK = '@@render-parity@@'

WRITER = r'''
import os, sys, time
d, ctl = sys.argv[1], sys.argv[2]
while not os.path.exists(ctl + '/go1'):
    time.sleep(0.02)
sys.stdout.write('\033[H\033[2J@@render-parity@@\r\n' + '\r\n' * 24)
sys.stdout.flush()
time.sleep(0.3)
for f in sorted((f for f in os.listdir(d) if f.isdigit()), key=int):
    sys.stdout.buffer.write(open(os.path.join(d, f), 'rb').read())
    sys.stdout.flush()
    time.sleep(0.3)
open(ctl + '/done', 'w').close()
time.sleep(100000)
'''


DEFAULT_MODE = False
FORWARD = None      # None: leave forward-output alone; 'off': turn it off


def record(case_dir, tmux, tmp):
    """(direct bytes, through-tmux bytes) for one case."""
    w = os.path.join(tmp, 'writer.py')
    open(w, 'w').write(WRITER)
    env = {k: v for k, v in os.environ.items() if k not in ('TMUX', 'TMUX_PANE')}
    sock = os.path.join(tmp, 'sock')
    base = [tmux, '-S', sock, '-f', '/dev/null']
    cb, ct = os.path.join(tmp, 'cb'), os.path.join(tmp, 'ct')
    for d in (cb, ct):
        os.makedirs(d, exist_ok=True)
        for f in os.listdir(d):
            os.unlink(os.path.join(d, f))
    subprocess.run(base + ['new', '-d', '-x', str(COLS), '-y', str(ROWS),
                           f'python3 {w} {case_dir} {ct}', ';', 'set', '-g', 'status', 'off', ';',
                           'set', '-s', 'clear-on-attach', 'on' if DEFAULT_MODE else 'off', ';',
                           ] + (['set', '-s', 'forward-output', FORWARD, ';'] if FORWARD else []) + [
                           'set', '-as', 'terminal-features',
                           ',xterm*:hyperlinks:usstyle:RGB:strikethrough:overline'],
                   env=env, check=True)
    bare = run.Side(['python3', w, case_dir, cb], COLS, ROWS)
    via = run.Side(base + ['attach'], COLS, ROWS)
    try:
        for s in (bare, via):
            s.pump(0.4)
        for d in (cb, ct):
            open(os.path.join(d, 'go1'), 'w').close()
        for _ in range(600):
            bare.pump(0.05)
            via.pump(0.05)
            if os.path.exists(os.path.join(cb, 'done')) and os.path.exists(os.path.join(ct, 'done')):
                break
        for _ in range(10):
            bare.pump(0.05)
            via.pump(0.05)
    finally:
        bare.close()
        via.close()
        subprocess.run(base + ['kill-server'], env=env, capture_output=True)
    return bytes(bare.buf), bytes(via.buf)


def after_mark(res):
    rows, joined, cur = res

    def cut(lines):
        if lines is None:
            return None
        idx = [i for i, l in enumerate(lines) if MARK in l.replace(' ', '')] if lines else []
        return tuple(lines[idx[-1] + 1:]) if idx else tuple(lines)
    return (cut(rows), cut(joined), cur)


def tmux_bin(args):
    return args[args.index('--tmux') + 1] if '--tmux' in args else 'tmux'


def main():
    args = sys.argv[1:]
    global DEFAULT_MODE, FORWARD
    has_forward = subprocess.run([tmux_bin(args), '-f/dev/null', '-L', 'gym-probe$$',
                                  'start', ';', 'show', '-s', 'forward-output'],
                                 capture_output=True).returncode == 0
    subprocess.run([tmux_bin(args), '-L', 'gym-probe$$', 'kill-server'], capture_output=True)
    modes = [args[args.index('--mode') + 1]] if '--mode' in args else \
        (['scrollback', 'translate', 'default'] if has_forward else ['scrollback', 'default'])
    tmux = args[args.index('--tmux') + 1] if '--tmux' in args else 'tmux'
    only = args[args.index('--only') + 1] if '--only' in args else None
    names = (args[args.index('--engines') + 1] if '--engines' in args
             else 'ghostty,libvterm,alacritty,kitty,wezterm').split(',')
    tmp = tempfile.mkdtemp(prefix='gym-parity-real.')
    eng = [e for e in consensus.engines(tmp) if e.name in names]
    cases = validate.parity_cases(tmp)
    casedir = os.path.join(tmp, 'cases')
    bad = {m: 0 for m in modes}
    for name, _ in cases:
        if only and name != only:
            continue
        expected = os.path.exists(os.path.join(casedir, name, 'differ'))
        cols = []
        for mode in modes:
            DEFAULT_MODE = mode == 'default'
            FORWARD = 'off' if mode == 'translate' else None
            d, t = record(os.path.join(casedir, name), tmux, tmp)
            keep = None
            if '--keep' in args:
                keep = os.path.join(args[args.index('--keep') + 1], mode, name)
                os.makedirs(keep, exist_ok=True)
                open(os.path.join(keep, 'direct.raw'), 'wb').write(d)
                open(os.path.join(keep, 'tmux.raw'), 'wb').write(t)
            wrong = []
            for e in eng:
                if DEFAULT_MODE:
                    # The visible screen, row for row.
                    a = (e.screen(d, tmp), None, None)
                    b = (e.screen(t, tmp), None, None)
                else:
                    a = after_mark(e.render(d, tmp))
                    b = after_mark(e.render(t, tmp))
                if keep:
                    for side, r in (('direct', a), ('tmux', b)):
                        open(os.path.join(keep, f'{e.name}.{side}'), 'w').write(
                            '\n'.join(r[0] or ()) + '\n')
                parts = [k for k, x, y in zip(('rows', 'joined'), a[:2], b[:2])
                         if x is not None and y is not None and x != y]
                if parts:
                    wrong.append(f'{e.name}:{"+".join(parts)}')
            if wrong and not expected:
                bad[mode] += 1
            cols.append(f'{mode}: ' + ('same' if not wrong else 'DIFFERS ' + ' '.join(wrong)))
        print(f'{name:28s} ' + ' | '.join(cols) + (' (expected)' if expected else ''))
    for m in modes:
        print(f'{m}: {bad[m]} cases differ on a real terminal')
    sys.exit(1 if any(bad.values()) else 0)


if __name__ == '__main__':
    main()
