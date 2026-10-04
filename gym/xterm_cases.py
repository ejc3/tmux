"""The emulation fixes against xterm itself: each case is the smallest stream
that shows one fix, run in a real xterm (under Xvfb) and in a pane of two tmux
builds. Prints a markdown table of which build ends with xterm's rows and
cursor, and fails if the second build differs from xterm anywhere.

    python3 gym/xterm_cases.py UPSTREAM_TMUX TMUX [-v] [--images DIR]

--images DIR draws each case as DIR/xterm-NN.png: xterm's screen, upstream's
and the build's, one above another, the cells that differ from xterm's
outlined (gym/evidence.py).

xterm's printout has no soft-wrap marks, so the fixes to which rows are
wrapped are not here (gym/consensus.py judges those with Ghostty, libvterm
and Alacritty). Needs xterm and xvfb-run.
"""

import os
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import consensus as C  # noqa: E402

E = b'\x1b'
FILL = b''.join(b'\x1b[%d;1Hrow%02d' % (i, i) for i in range(1, 25))
CASES = [
    ('control: text', b'hello\r\nworld'),
    ('control: a cursor move', E + b'[5;5HX'),
    ('IL below the scroll region', FILL + E + b'[5;10r' + E + b'[15;1H' + E + b'[2LX'),
    ('DL below the scroll region', FILL + E + b'[5;10r' + E + b'[15;1H' + E + b'[2MX'),
    ('REP at the last column', b'a' * 79 + b'b' + E + b'[5bX'),
    ('BS after the last column is written', b'a' * 80 + b'\bX'),
    ('CUB after the last column is written', b'a' * 80 + E + b'[DX'),
    ('VPA after the last column is written', b'a' * 80 + E + b'[5dX'),
    ('LF after the last column is written', b'a' * 80 + b'\nX'),
    ('DECSC in each screen', E + b'[5;5H' + E + b'7' + E + b'[?47h' + E + b'[10;10H' + E + b'7' +
     E + b'[?47l' + E + b'[20;20H' + E + b'8X'),
    ('1048 saves and restores the cursor', E + b'[3;3H' + E + b'[?1048h' + E + b'[10;10H' +
     E + b'[?1048lX'),
    ('1049 set in the alternate screen', E + b'[?1049hhello' + E + b'[?1049hX'),
    ('a skin tone and then an emoji', '\U0001F3FB\U0001F44DX'.encode()),
    ('DECSTR resets origin mode', E + b'[5;10r' + E + b'[?6h' + E + b'[!p' + E + b'[3;3HX'),
    ('DECSTR resets the scroll region', FILL + E + b'[5;10r' + E + b'[!p' + E + b'[24;1H\nX'),
    ('DECSTR resets insert mode', b'abcdef' + E + b'[4h' + E + b'[!p' + E + b'[1;1HX'),
]


def key(r):
    return (r[0], r[2])        # rows and cursor


def draw(path, x, u, r):
    import evidence
    panels = [('xterm', list(x[0])), ('upstream tmux', list(u[0])),
              ('tmux with the fix', list(r[0]))]
    rows = max(len(p[1]) for p in panels)
    for p in panels:
        p[1].extend([''] * (rows - len(p[1])))
    evidence.compare(panels, C.COLS, context=1, max_rows=8, stack=True,
                     window=32, scale=2).save(path)


def main():
    args = [a for a in sys.argv[1:] if a != '-v']
    verbose = '-v' in sys.argv
    images = None
    if '--images' in args:
        i = args.index('--images')
        images = args[i + 1]
        del args[i:i + 2]
        os.makedirs(images, exist_ok=True)
    tmp = tempfile.mkdtemp(prefix='xtc')
    xterm = [e for e in C.confirming(tmp) if e.name == 'xterm'][0]
    got = {name: [xterm.render(data, tmp)] for name, data in CASES}
    for i, tmux in enumerate(args[:2]):
        d = os.path.join(tmp, str(i))
        os.makedirs(d)
        eng = C.TmuxEngine(tmux, d)
        for name, data in CASES:
            got[name].append(eng.render(data, tmp))
        eng.close()
    print('| case | upstream as xterm | this build as xterm |')
    print('|---|---|---|')
    bad = 0
    for n, (name, _) in enumerate(CASES):
        x, u, r = got[name]
        if images and not name.startswith('control'):
            draw(os.path.join(images, 'xterm-%02d.png' % n), x, u, r)
        print('| %s | %s | %s |' % (name, 'yes' if key(u) == key(x) else 'no',
                                    'yes' if key(r) == key(x) else 'no'))
        if key(r) != key(x):
            bad += 1
        if verbose or key(r) != key(x):
            for label, v in (('xterm', x), ('upstream', u), ('build', r)):
                print('    %-8s cursor %s, last rows %s' % (
                    label, v[2], [row for row in v[0] if row][-3:]))
    sys.exit(1 if bad else 0)


if __name__ == '__main__':
    main()
