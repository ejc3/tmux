#!/usr/bin/env python3
"""Random short streams of text sizing (OSC 66 w=), pointer shapes (OSC 22)
and kitty keyboard flag changes, with cursor movement, editing and wrapping
around them, played in kitty directly and in tmux in kitty. The screens (a
screenshot of the window, with the cursor hidden) and the cursor positions
must be the same.

    python3 gym/diff_kitty.py --tmux PATH [--cases N] [--seed S] [--keep DIR]

Runs under xvfb-run itself when there is no DISPLAY. KITTY is the kitty
binary (default $JUDGES/kitty/bin/kitty, as gym/refs/kitty.py).
"""

import argparse
import json
import os
import random
import re
import shutil
import subprocess
import sys
import tempfile
import time

KITTY = os.environ.get('KITTY', os.path.join(
    os.environ.get('JUDGES', '/mnt/fcvm-btrfs/term-judges'), 'kitty', 'bin',
    'kitty'))
KITTEN = os.path.join(os.path.dirname(KITTY), 'kitten')

TEXTS = ['a', 'xy', 'Q', '中', '\U0001f600', 'é', 'é', '#',
         '\U0001f44d\U0001f3fd', '中文']


def stream(r):
    out = []
    for _ in range(r.randint(3, 14)):
        k = r.random()
        if k < 0.35:
            w = r.choice([0, 1, 2, 3, 4, 5, 6, 7])
            t = r.choice(TEXTS)
            if r.random() < 0.2:
                t += r.choice(TEXTS)
            out.append('\x1b]66;w=%d;%s%s' % (w, t, r.choice(['\x07',
                                                            '\x1b\\'])))
        elif k < 0.55:
            out.append(r.choice(TEXTS) * r.randint(1, 12))
        elif k < 0.65:
            out.append('\x1b[%d;%dH' % (r.randint(1, 6),
                                        r.choice([1, 2, 40, 76, 77, 78, 79,
                                                  80])))
        elif k < 0.75:
            out.append(r.choice(['\r\n', '\r', '\b', '\t', '\x1b[K',
                                 '\x1b[1K', '\x1b[2X', '\x1b[2@', '\x1b[2P',
                                 '\x1b[A', '\x1b[3C']))
        elif k < 0.85:
            out.append('\x1b]22;%s%s\x1b\\' % (r.choice(['>', '<', '=', '']),
                                               r.choice(['wait', 'text',
                                                         'crosshair,help',
                                                         ''])))
        else:
            out.append(r.choice(['\x1b[>1u', '\x1b[>31u', '\x1b[<u',
                                 '\x1b[=5;1u', '\x1b[<9u']))
    return ''.join(out)


def run_kitty(cmd, tmp, png):
    """cmd in an 80x24 kitty; the screenshot and the cursor once ready."""
    ready = os.path.join(tmp, 'ready')
    if os.path.exists(ready):
        os.unlink(ready)
    home = tempfile.mkdtemp(dir=tmp)
    sock = os.path.join(home, 'k.sock')
    env = dict(os.environ, LIBGL_ALWAYS_SOFTWARE='1',
               XDG_CONFIG_HOME=os.path.join(home, 'cfg'),
               XDG_CACHE_HOME=os.path.join(home, 'cache'), READY=ready)
    env.pop('TMUX', None)
    k = subprocess.Popen(
        [KITTY, '--config', 'NONE', '--listen-on', 'unix:' + sock,
         '-o', 'allow_remote_control=yes', '-o', 'update_check_interval=0',
         '-o', 'initial_window_width=80c', '-o', 'initial_window_height=24c',
         '-o', 'remember_window_size=no', '-o', 'window_padding_width=0',
         '-o', 'background=#000000', '-o', 'foreground=#ffffff',
         '-o', 'cursor_blink_interval=0', 'sh', '-c', cmd],
        env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        for _ in range(300):
            if os.path.exists(ready):
                break
            time.sleep(0.05)
        else:
            return 'not ready', None
        from PIL import ImageGrab
        geo = subprocess.run(['xdotool', 'search', '--onlyvisible', '--class',
                              'kitty', 'getwindowgeometry', '--shell'],
                             capture_output=True, text=True).stdout
        g = dict(line.split('=', 1) for line in geo.split() if '=' in line)
        w, h = int(g['WIDTH']), int(g['HEIGHT'])
        x, y = int(g['X']), int(g['Y'])
        last, same = None, 0
        for _ in range(120):
            time.sleep(0.2)
            im = ImageGrab.grab(xdisplay=os.environ['DISPLAY']).crop(
                (x, y, x + w, y + h))
            data = im.tobytes()
            same = same + 1 if data == last else 0
            last = data
            if same == 3:
                break
        else:
            return 'screen kept changing', None
        im.save(png)
        t = subprocess.run([KITTEN, '@', '--to', 'unix:' + sock, 'get-text',
                            '--extent', 'screen', '--add-cursor'],
                           capture_output=True, env=env).stdout.decode(
                               'utf-8', 'replace')
        m = re.search(r'\x1b\[\?25[hl]\x1b\[(\d+);(\d+)H', t)
        cur = (int(m.group(2)) - 1, int(m.group(1)) - 1) if m else None
        return None, cur
    finally:
        k.terminate()
        k.wait()


def differ(a, b):
    from PIL import Image, ImageChops
    ia, ib = Image.open(a).convert('RGB'), Image.open(b).convert('RGB')
    if ia.size != ib.size:
        return 'sizes %s and %s' % (ia.size, ib.size)
    box = ImageChops.difference(ia, ib).getbbox()
    return None if box is None else 'pixels differ in %s' % (box,)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--tmux', required=True)
    ap.add_argument('--cases', type=int, default=40)
    ap.add_argument('--seed', type=int, default=1)
    ap.add_argument('--keep')
    a = ap.parse_args()
    if 'DISPLAY' not in os.environ:
        os.execvp('xvfb-run', ['xvfb-run', '-a', '-s',
                               '-screen 0 1024x768x24', sys.executable] +
                  sys.argv)
    tmux = os.path.abspath(a.tmux)
    tmp = tempfile.mkdtemp(prefix='diff-kitty.')
    conf = os.path.join(tmp, 'tmux.conf')
    with open(conf, 'w') as f:
        f.write('set -g status off\nset -s extended-keys on\n'
                'set -s escape-time 10\n')
    bad = 0
    try:
        for i in range(a.cases):
            seed = a.seed + i
            r = random.Random(seed)
            data = stream(r) + '\x1b[?25l'
            path = os.path.join(tmp, 'stream')
            with open(path, 'w') as f:
                f.write(data)
            run = "stty raw -echo; cat '%s'; touch \"$READY\"; exec sleep 1000" \
                % path
            pd = os.path.join(tmp, '%d.direct.png' % seed)
            pt = os.path.join(tmp, '%d.tmux.png' % seed)
            sock = os.path.join(tmp, 'tmux.sock')
            e1, c1 = run_kitty(run, tmp, pd)
            e2, c2 = run_kitty('%s -S %s -f %s new "%s"' % (
                tmux, sock, conf, run.replace('"', '\\"')), tmp, pt)
            subprocess.run([tmux, '-S', sock, 'kill-server'],
                           capture_output=True)
            why = e1 or e2 or differ(pd, pt)
            if not why and c1 != c2:
                why = 'cursor %s in kitty, %s in tmux' % (c1, c2)
            print('%-6d %s  %s' % (seed, 'same' if not why else why,
                                   json.dumps(data)[:160]))
            if why:
                bad += 1
                if a.keep:
                    os.makedirs(a.keep, exist_ok=True)
                    for p in (pd, pt):
                        if os.path.exists(p):
                            shutil.copy(p, a.keep)
                    with open(os.path.join(a.keep, '%d.stream' % seed),
                              'w') as f:
                        f.write(data)
        print('%d of %d the same' % (a.cases - bad, a.cases))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    sys.exit(1 if bad else 0)


if __name__ == '__main__':
    main()
