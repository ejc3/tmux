"""Kitty graphics: what the screen shows when a program uses the protocol, run
directly in kitty and in tmux in kitty. Each scenario is a small program; the
two screenshots (of kitty's window, under Xvfb) must be the same pixels. The
cursor is left blinking at the bottom right, and that cell is not compared:
kitty (0.49.1, software rendering) draws an image only on its next redraw,
and with the cursor hidden or not blinking that does not come.

    python3 gym/refs/kitty_gfx.py --tmux TMUX [SCENARIO...]

Prints a markdown table: "same", or how many pixels differ and where, with
the reason for a known difference; fails on one not known.
Needs xvfb-run, xdotool, python3-pil and kitty ($JUDGES/kitty/bin/kitty).
"""

import argparse
import base64
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import time
import zlib

KITTY = os.environ.get('KITTY', os.path.join(
    os.environ.get('JUDGES', '/mnt/fcvm-btrfs/term-judges'), 'kitty', 'bin', 'kitty'))


def png(w, h, rgb):
    """A w x h PNG of one colour."""
    raw = b''.join(b'\0' + bytes(rgb) * w for _ in range(h))

    def chunk(t, d):
        return struct.pack('>I', len(d)) + t + d + struct.pack(
            '>I', zlib.crc32(t + d) & 0xffffffff)
    return (b'\x89PNG\r\n\x1a\n' +
            chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0)) +
            chunk(b'IDAT', zlib.compress(raw)) + chunk(b'IEND', b''))


def b64(b):
    return base64.b64encode(b).decode()


RED = b64(bytes([255, 0, 0]) * 4)          # 2x2 RGB
GREEN = b64(bytes([0, 200, 0]) * 40 * 30)  # 40x30 RGB
BLUE_PNG = b64(png(30, 45, (0, 0, 255)))


def G(keys, payload=''):
    return '\x1b_G' + keys + (';' + payload if payload else '') + '\x1b\\'


# Each scenario: what the program writes (a list: strings, or ('query', s)
# to write s and show the answer on the screen).
SCENARIOS = {
    'place-cr': ['\x1b[3;5H', G('a=T,q=2,f=24,s=2,v=2,c=4,r=2', RED), 'X'],
    'transmit-then-put': ['\x1b[2;3H', G('a=t,q=2,i=5,f=24,s=2,v=2', RED),
                          G('a=p,q=2,i=5,c=6,r=3'), 'Y'],
    'move-placement': ['\x1b[2;3H', G('a=t,q=2,i=5,f=24,s=2,v=2', RED),
                       G('a=p,q=2,i=5,p=9,c=4,r=2'), '\x1b[8;20H',
                       G('a=p,q=2,i=5,p=9,c=4,r=2'), 'Z'],
    'native-size': ['\x1b[4;10H', G('a=T,q=2,f=24,s=40,v=30', GREEN), 'N'],
    'png': ['\x1b[2;2H', G('a=T,q=2,f=100', BLUE_PNG), 'P'],
    'png-rows': ['\x1b[2;2H', G('a=T,q=2,f=100,r=5', BLUE_PNG), 'P'],
    'bottom-scrolls': ['top\x1b[23;5H', G('a=T,q=2,f=24,s=2,v=2,c=3,r=4', RED),
                       'B'],
    'cursor-stays': ['\x1b[5;5H', G('a=T,q=2,C=1,f=24,s=2,v=2,c=4,r=2', RED),
                     'C'],
    'right-edge': ['\x1b[6;76H', G('a=T,q=2,f=24,s=2,v=2,c=6,r=2', RED), 'R'],
    'delete-id': ['\x1b[3;5H', G('a=T,q=2,i=3,f=24,s=2,v=2,c=4,r=2', RED),
                  '\x1b[3;20H', G('a=T,q=2,i=4,f=24,s=2,v=2,c=4,r=2', RED),
                  G('a=d,d=i,q=2,i=3'), 'D'],
    'delete-all': ['\x1b[3;5H', G('a=T,q=2,f=24,s=2,v=2,c=4,r=2', RED),
                   G('a=d,q=2'), 'A'],
    'chunked': ['\x1b[3;5H', G('a=T,q=2,f=24,s=40,v=30,c=8,r=3,m=1',
                               GREEN[:1600]),
                G('m=1', GREEN[1600:3200]), G('m=0', GREEN[3200:]), 'K'],
    'clear-screen': ['\x1b[3;5H', G('a=T,q=2,f=24,s=2,v=2,c=4,r=2', RED),
                     '\x1b[2J', 'E'],
    'query': [('query', G('a=q,i=31,s=1,v=1,t=d,f=24', 'AAAA'))],
    'query-bad-format': [('query', G('a=q,i=31,s=1,v=1,t=d,f=7', 'AAAA'))],
    'reply-put': [G('a=t,i=6,f=24,s=2,v=2', RED), ('query', G('a=p,i=6,c=2,r=1')),
                  ('query', G('a=p,i=77'))],
    'tp-noq': ['\x1b[2;3H', G('a=t,i=5,f=24,s=2,v=2', RED), G('a=p,i=5,c=6,r=3'), 'Y'],
    'tp-nocr': ['\x1b[2;3H', G('a=t,q=2,i=5,f=24,s=2,v=2', RED), G('a=p,q=2,i=5'), 'Y'],
    'tp-T-then-p': ['\x1b[2;3H', G('a=T,q=2,i=5,f=24,s=2,v=2,c=2,r=1', RED), '\x1b[6;3H', G('a=p,q=2,i=5,c=6,r=3'), 'Y'],
    'two-T': ['\x1b[3;5H', G('a=T,q=2,i=3,f=24,s=2,v=2,c=4,r=2', RED), '\x1b[3;20H', G('a=T,q=2,i=4,f=24,s=2,v=2,c=4,r=2', RED), 'D'],
    # Text sizing, the width part (OSC 66 w=).
    'text-width': ['\x1b[3;5Ha\x1b]66;w=2;b\x07c\x1b]66;w=3;xy\x07d'],
    'emoji-width': ['\x1b[3;5H\x1b]66;w=2;\U0001F44D\U0001F3FD\x07X'],
    'cjk-narrow': ['\x1b[3;5H\x1b]66;w=1;\u4e2d\x07X'],
    'text-wrap': ['\x1b[3;79H\x1b]66;w=3;xy\x07Z'],
    'placeholders': [G('a=T,q=2,U=1,i=7,f=24,s=2,v=2,c=4,r=2', RED),
                     '\x1b[4;6H\x1b[38;5;7m',
                     '\U0010EEEE̅̅\U0010EEEE̅̍'
                     '\U0010EEEE̅̎\U0010EEEE̅̐',
                     '\x1b[5;6H',
                     '\U0010EEEE̍̅\U0010EEEE̍̍'
                     '\U0010EEEE̍̎\U0010EEEE̍̐',
                     '\x1b[39m'],
}

# Known differences: tmux shows images with Unicode placeholders, which fit an
# image to whole cells with its shape kept.
KNOWN = {
    'native-size': 'kitty draws the image at its own pixel size',
    'png': 'kitty draws the image at its own pixel size',
    'png-rows': 'kitty keeps the shape but not to whole cells',
    'tp-nocr': 'kitty draws the image at its own pixel size',
    'bottom-scrolls': 'kitty stretches the image to c and r',
    'right-edge': 'kitty stretches the image to c and r',
    'cursor-stays': 'text written over an image removes that part of it',
}

PROGRAM = r'''
import os, re, sys, time, tty
steps, ready = eval(open(sys.argv[1]).read()), sys.argv[2]
tty.setraw(0)
os.write(1, b'\x1b[H\x1b[2J')
answers = []
for s in steps:
    if isinstance(s, tuple):
        os.write(1, (s[1] + '\x1b[c').encode())
        buf = b''
        while not re.search(rb'\x1b\[\?[0-9;]*c', buf):
            buf += os.read(0, 1024)
        m = re.search(rb'\x1b_G([^\x1b]*)\x1b\\', buf)
        answers.append(m.group(1).decode() if m else 'none')
    else:
        os.write(1, s.encode())
if answers:
    os.write(1, ('\x1b[15;1H' + ' '.join(answers)).encode())
os.write(1, b'\x1b[24;80H')
open(ready, 'w').write('x')
time.sleep(1000)
'''


def shot(cmd, png_path, tmp):
    """Run cmd in an 80x24 kitty; screenshot its window once it is ready."""
    ready = os.path.join(tmp, 'ready')
    if os.path.exists(ready):
        os.unlink(ready)
    # A fresh kitty each time: kitty keeps image data in a disk cache.
    home = tempfile.mkdtemp(dir=tmp)
    env = dict(os.environ, LIBGL_ALWAYS_SOFTWARE='1',
               XDG_CONFIG_HOME=os.path.join(home, 'cfg'),
               XDG_CACHE_HOME=os.path.join(home, 'cache'), READY=ready)
    env.pop('TMUX', None)
    k = subprocess.Popen(
        [KITTY, '--config', 'NONE', '-o', 'update_check_interval=0',
         '-o', 'initial_window_width=80c', '-o', 'initial_window_height=24c',
         '-o', 'remember_window_size=no', '-o', 'window_padding_width=0',
         '-o', 'background=#000000', '-o', 'foreground=#ffffff',
         'sh', '-c', cmd],
        env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        for _ in range(300):
            if os.path.exists(ready):
                break
            time.sleep(0.05)
        else:
            return 'not ready'
        # The window, less the cursor's cell (the last): wait for it to stay
        # the same for 0.75 s.
        from PIL import ImageGrab, ImageDraw
        geo = subprocess.run(['xdotool', 'search', '--onlyvisible', '--class',
                              'kitty', 'getwindowgeometry', '--shell'],
                             capture_output=True, text=True).stdout
        g = dict(l.split('=', 1) for l in geo.split() if '=' in l)
        w, h = int(g['WIDTH']), int(g['HEIGHT'])
        x, y = int(g['X']), int(g['Y'])
        last, same = None, 0
        for _ in range(120):
            time.sleep(0.25)
            im = ImageGrab.grab(xdisplay=os.environ['DISPLAY']).crop(
                (x, y, x + w, y + h))
            ImageDraw.Draw(im).rectangle(
                (w - w // 80 - 1, h - h // 24 - 1, w, h), fill=(0, 0, 0))
            data = im.tobytes()
            same = same + 1 if data == last else 0
            last = data
            if same == 3:
                break
        else:
            return 'screen kept changing'
        im.save(png_path)
        return None
    finally:
        k.terminate()
        k.wait()


def compare(a, b):
    from PIL import Image, ImageChops
    ia, ib = Image.open(a).convert('RGB'), Image.open(b).convert('RGB')
    diff = ImageChops.difference(ia, ib)
    box = diff.getbbox()
    if box is None:
        return 'same'
    n = sum(1 for p in diff.getdata() if p != (0, 0, 0))
    return f'{n} pixels differ in {box}'


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--tmux', required=True)
    ap.add_argument('--keep', help='directory for the screenshots')
    ap.add_argument('scenarios', nargs='*')
    a = ap.parse_args()
    if 'DISPLAY' not in os.environ:
        os.execvp('xvfb-run', ['xvfb-run', '-a', '-s', '-screen 0 1024x768x24',
                               sys.executable] + sys.argv)
    tmp = tempfile.mkdtemp(prefix='gym-kgfx.', dir=os.environ.get('GYM_TMP'))
    prog = os.path.join(tmp, 'prog.py')
    open(prog, 'w').write(PROGRAM)
    conf = os.path.join(tmp, 'tmux.conf')
    open(conf, 'w').write('set -g status off\n')
    tmux = os.path.abspath(a.tmux)
    bad = same = 0
    print('### Kitty graphics: kitty against tmux in kitty (screenshots)\n')
    print('| scenario | result |')
    print('|---|---|')
    for name in a.scenarios or SCENARIOS:
        steps = os.path.join(tmp, name + '.steps')
        open(steps, 'w').write(repr(SCENARIOS[name]))
        run = f'python3 {prog} {steps} $READY'
        sock = os.path.join(tmp, name + '.sock')
        pd, pt = os.path.join(tmp, name + '.direct.png'), os.path.join(tmp, name + '.tmux.png')
        err = shot(run, pd, tmp) or shot(
            f'{tmux} -S {sock} -f {conf} new "{run}"', pt, tmp)
        subprocess.run([tmux, '-S', sock, 'kill-server'], capture_output=True)
        result = err or compare(pd, pt)
        if result == 'same':
            same += 1
        elif name in KNOWN:
            result += f' (known: {KNOWN[name]})'
        else:
            bad += 1
            result = '**unexpected** ' + result
        print(f'| {name} | {result} |', flush=True)
        if a.keep:
            os.makedirs(a.keep, exist_ok=True)
            for p in (pd, pt):
                if os.path.exists(p):
                    shutil.copy(p, a.keep)
    shutil.rmtree(tmp, ignore_errors=True)
    print(f'\n{same} the same, {bad} unexpected.')
    sys.exit(1 if bad else 0)


if __name__ == '__main__':
    main()
