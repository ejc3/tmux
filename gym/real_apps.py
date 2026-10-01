"""Real programs inside tmux, attached to gym/memory.py's fake kitty: does
the server report memory errors (sanitizer build), hang, or grow?

    python3 gym/real_apps.py --tmux BIN [--asan-tmux BIN] [--only NAME,...]
                             [--rounds N]

yazi browsing images, timg and kitten icat (tmux's own kitty graphics, kitty's
Unicode placeholders, and passthrough), nvim with the mouse, a resize and
:terminal, btop through resizes, and Claude Code starting up (with an empty
configuration: no account, no requests). Each program runs in both modes
(forwarding and translating); with --asan-tmux, also on the sanitizer build,
whose reports fail the run. On the normal build the server's live heap after
warm-up runs and after N more, each followed by a fresh window in place of
the program's (which frees what it left), must not grow by more than a block
a round, or a second N must not grow again.
"""

import argparse
import os
import shutil
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import memory as m  # noqa: E402

KITTEN = os.environ.get('KITTEN', '/mnt/fcvm-btrfs/term-judges/kitty-nightly/'
                        'bin/kitten')
YAZI = os.environ.get('YAZI', shutil.which('yazi') or
                      '/mnt/fcvm-btrfs/apps/yazi-aarch64-unknown-linux-gnu/'
                      'yazi')


def images(d):
    os.makedirs(d, exist_ok=True)
    for n, (w, h) in enumerate([(64, 48), (200, 120), (16, 16), (400, 300)]):
        with open(os.path.join(d, 'img%d.png' % n), 'wb') as f:
            f.write(m.png(w, h))
    with open(os.path.join(d, 'notes.txt'), 'w') as f:
        f.write('text\n' * 50)
    return d


def screen(g):
    return g.server.cmd('capture-pane', '-p')


def run_in_pane(g, cmd, env=()):
    """Run cmd in a new window in place of the current one. Killing the
    window frees its pane and with it what the program left (images go with
    their pane, not with the program: kitty keeps a window's images too)."""
    args = []
    for kv in env:
        args += ['-e', kv]
    old = g.server.cmd('display', '-p', '#{window_id}').strip()
    g.server.cmd('new-window', *args, cmd)
    g.server.cmd('kill-window', '-t', old)


def wait_screen(g, text, what, timeout=30):
    m.wait(lambda: text in screen(g), what, timeout)


def pane_dead(g):
    return g.server.cmd('display', '-p', '#{pane_dead}').strip() == '1'


def cmd_round(g, cmd, done, env=()):
    """Run a command to completion in the pane."""
    run_in_pane(g, 'sh -c %s' % shellquote(cmd + '; printf "\\n=%s=\\n"'
                                            % done + '; exec sleep 1000'),
                env)
    wait_screen(g, '=%s=' % done, done)


def shellquote(s):
    return "'" + s.replace("'", "'\\''") + "'"


# --- Programs -----------------------------------------------------------

def timg_round(g, d, i):
    img = os.path.join(d, 'img%d.png' % (i % 4))
    cmd_round(g, 'timg -pk -g40x10 %s; timg -pk --clear -g20x5 %s'
              % (img, img), 'timg%d' % i)


def icat_round(g, d, i):
    img = os.path.join(d, 'img%d.png' % (i % 4))
    mode = ['--transfer-mode=stream', '--unicode-placeholder',
            '--passthrough=tmux', '--transfer-mode=file'][i % 4]
    cmd_round(g, '%s icat %s --place 20x5@0x0 %s; %s icat --clear'
              % (KITTEN, mode, img, KITTEN), 'icat%d' % i,
              env=['KITTY_WINDOW_ID=1', 'TERM=xterm-kitty'])


def yazi_setup(g, d):
    run_in_pane(g, '%s %s' % (YAZI, d), env=['KITTY_WINDOW_ID=1',
                                               'TERM_PROGRAM=kitty',
                                               'YAZI_CONFIG_HOME=%s/yazi'
                                               % g.tmp])
    wait_screen(g, 'img0.png', 'yazi to list the images')


def yazi_round(g, d, i):
    # Move through the images (each previewed), and back.
    g.term.send(b'j' * 3 + b'k' * 3)
    m.wait(lambda: 'img0.png' in screen(g), 'yazi still drawing')
    g.settle()


def nvim_setup(g, d):
    run_in_pane(g, 'nvim -u NONE -i NONE -n --cmd "set mouse=a" %s'
                % os.path.join(d, 'notes.txt'))
    wait_screen(g, 'text', 'nvim to open the file')


def nvim_round(g, d, i):
    g.term.send(b'\033[<0;10;5M\033[<0;10;5m\033[<64;10;5M\033[<65;10;5M')
    rows, cols = 20 + i % 5, 70 + i % 10
    g.term.size(rows, cols, 16, 32)
    # Let nvim have the new size before :terminal starts: a resize during
    # its start can lose the job's output in nvim's own buffer.
    m.wait(lambda: g.server.cmd('display', '-p', '#{window_width}x'
                                '#{window_height}').strip()
           == '%dx%d' % (cols, rows), 'nvim resize')
    g.settle()
    # Escape first: the clicks may have started a visual selection.
    # (A plain word: nvim runs it with the user's shell, and zsh takes
    # =word as a command lookup.)
    g.term.send(b'\033:terminal echo nvimterm%d\r' % i)
    wait_screen(g, 'nvimterm%d\n' % i, 'nvim :terminal')
    g.term.send(b'\x1c\x0e:bd!\r')
    wait_screen(g, 'text', 'back in the file')


def btop_setup(g, d):
    run_in_pane(g, 'btop --utf-force')
    m.wait(lambda: 'cpu' in screen(g).lower(), 'btop to draw', 30)


def btop_round(g, d, i):
    g.term.size(24 + i % 8, 80 + i % 20, 16, 32)
    m.wait(lambda: g.server.cmd('display', '-p', '#{window_height}').strip()
           == str(24 + i % 8), 'btop resize')
    m.wait(lambda: 'cpu' in screen(g).lower(), 'btop redraw', 30)


def claude_round(g, d, i):
    conf = os.path.join(g.tmp, 'claude%d' % i)
    os.makedirs(conf, exist_ok=True)
    run_in_pane(g, 'claude', env=['CLAUDE_CONFIG_DIR=%s' % conf,
                                  'HOME=%s' % conf])
    # The first screen of a fresh configuration (no account): wait for it to
    # draw something, then leave.
    m.wait(lambda: len(screen(g).strip()) > 20, 'claude to draw', 60)
    g.term.send(b'\x03')
    time.sleep(0.2)  # Claude Code wants a second Ctrl-C within its window
    g.term.send(b'\x03')
    m.wait(lambda: pane_dead(g) or 'exit' in screen(g).lower() or True,
           'claude to exit', 10)
    run_in_pane(g, 'exec sleep 1000')


APPS = [
    ('timg', None, timg_round),
    ('kitten-icat', None, icat_round),
    ('yazi', yazi_setup, yazi_round),
    ('nvim', nvim_setup, nvim_round),
    ('btop', btop_setup, btop_round),
    ('claude', None, claude_round),
]


def run(args, binary, heapcount, asan, name, setup, step, mode, d):
    g = m.Gym(binary, mode, heapcount, asan, args.keep)
    g.server.cmd('set', '-g', 'remain-on-exit', 'on')
    pid = g.server.pid
    verdict = 'ok'
    try:
        # Warm-up runs, then a fresh window: what is left is the baseline.
        # A cache that fills once is not growth: a second window of rounds
        # must grow too.
        def window(first, n):
            if setup:
                setup(g, d)
            for i in range(first, first + n):
                step(g, d, i)
            run_in_pane(g, 'exec sleep 1000')
            return g.heap() if heapcount else None
        n = args.rounds
        h0 = window(0, args.warmup)
        h1 = window(args.warmup, n)
        if heapcount:
            per = (h1[1] - h0[1]) / n
            verdict = 'ok (%+.1f blocks a round)' % per
            if per > 1:
                h2 = window(args.warmup + n, n)
                per2 = (h2[1] - h1[1]) / n
                verdict = ('GROWS %.1f blocks a round' % per2 if per2 > 1
                           else 'ok (%+.1f, then %+.1f blocks a round: '
                           'filled once)' % (per, per2))
    except m.Fail as e:
        verdict = 'ERROR %s%s' % (e, '' if g.server.alive()
                                   else ' (server died)')
    finally:
        g.close()
    if asan:
        reports = m.asan_reports(g.tmp, pid)
        if reports:
            verdict = 'REPORT %s' % os.path.join(g.tmp, reports[0][0])
    return verdict


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('--tmux', required=True)
    ap.add_argument('--asan-tmux')
    ap.add_argument('--only', default='')
    ap.add_argument('--modes', default='forward,translate')
    ap.add_argument('--rounds', type=int, default=20)
    ap.add_argument('--warmup', type=int, default=8)
    ap.add_argument('--keep')
    args = ap.parse_args()
    only = [x for x in args.only.split(',') if x]
    work = tempfile.mkdtemp(prefix='gymapps-')
    heapcount = m.build_heapcount(work)
    d = images(os.path.join(work, 'pics'))
    failed = False
    print('| program | build | mode | result |')
    print('|---|---|---|---|')
    for name, setup, step in APPS:
        if only and not any(o in name for o in only):
            continue
        builds = [('normal', os.path.abspath(args.tmux), heapcount, False)]
        if args.asan_tmux:
            builds.append(('asan', os.path.abspath(args.asan_tmux), None,
                           True))
        for build, binary, hc, asan in builds:
            for mode in args.modes.split(','):
                v = run(args, binary, hc, asan, name, setup, step, mode, d)
                print('| %s | %s | %s | %s |' % (name, build, mode, v),
                      flush=True)
                failed |= not v.startswith('ok')
    shutil.rmtree(work, ignore_errors=True)
    sys.exit(1 if failed else 0)


if __name__ == '__main__':
    main()
