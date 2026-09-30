"""What a real kitty sends a program for each key, under each kitty keyboard
mode (progressive enhancement flags), to compare tmux's encoding against.

    xvfb-run -a python3 gym/refs/kitty_keys.py [--x] [--tmux TMUX] FLAGS KEY...

For each FLAGS (a comma-separated list, e.g. 0,1,8,31) the program in the
window pushes the flags (CSI > FLAGS u), then each KEY (kitty's names, e.g.
ctrl+a, shift+f1, escape) is sent with "kitten @ send-key" and the bytes the
program reads are printed, one line per key: "FLAGS KEY BYTES" with BYTES
written as Python escapes. Keys go as press then release events, so with
flag 2 the release shows too.

With --x, keys are X key events typed with xdotool (xdotool's names, e.g.
ctrl+a, shift+F1, Escape, KP_1) instead: send-key makes up key events with
no text for shifted keys (shift+a is "a"), where a real keyboard gives "A".

With --tmux, the program runs in a tmux pane inside kitty instead (on its
own socket, with extended-keys on, which tmux needs to take part), so the
output is what the program gets through tmux.

KITTY is the kitty binary (default: $JUDGES/kitty/bin/kitty).
"""

import json
import os
import shlex
import subprocess
import sys
import tempfile
import time

KITTY = os.environ.get('KITTY', os.path.join(
    os.environ.get('JUDGES', '/mnt/fcvm-btrfs/term-judges'), 'kitty', 'bin', 'kitty'))
KITTEN = os.path.join(os.path.dirname(KITTY), 'kitten')

# The program: raw mode, push the flags, tell the test it is ready, then
# append everything read to the output file.
PROBE = r'''
import os, sys, termios, tty
flags, out, ready = sys.argv[1], sys.argv[2], sys.argv[3]
tty.setraw(0)
os.write(1, b'\x1b[>' + flags.encode() + b'u')
os.write(1, b'\x1b[?u')
f = os.open(out, os.O_WRONLY | os.O_CREAT | os.O_APPEND)
seen = b''
while True:
    b = os.read(0, 4096)
    if not b:
        break
    if ready:
        # The first read is the answer to the query: flags are in effect.
        seen += b
        if seen.endswith(b'u'):
            open(ready, 'w').write(seen.decode('latin1'))
            ready = None
        continue
    os.write(f, b)
'''


def wait(cond, what, tries=400):
    for _ in range(tries):
        if cond():
            return
        time.sleep(0.02)
    sys.exit(f'timed out waiting for {what}')


def main():
    args = sys.argv[1:]
    tmux = None
    xkeys = False
    if args[:1] == ['--x']:
        xkeys, args = True, args[1:]
    if args[:1] == ['--tmux']:
        tmux, args = args[1], args[2:]
    flag_sets, keys = args[0].split(','), args[1:]
    tmp = tempfile.mkdtemp(prefix='gym-kkeys.', dir=os.environ.get('GYM_TMP'))
    sock = os.path.join(tmp, 'k.sock')
    probe = os.path.join(tmp, 'probe.py')
    open(probe, 'w').write(PROBE)
    env = dict(os.environ, LIBGL_ALWAYS_SOFTWARE='1',
               XDG_CONFIG_HOME=os.path.join(tmp, 'cfg'),
               XDG_CACHE_HOME=os.path.join(tmp, 'cache'))
    env.pop('TMUX', None)
    env.pop('TMUX_PANE', None)
    k = subprocess.Popen(
        [KITTY, '--config', 'NONE', '--listen-on', 'unix:' + sock,
         '-o', 'allow_remote_control=yes', '-o', 'enable_audio_bell=no',
         '-o', 'update_check_interval=0', '-o', 'clear_all_shortcuts=yes',
         'sh', '-c', 'exec sleep 100000'],
        env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def rc(*a):
        return subprocess.run([KITTEN, '@', '--to', 'unix:' + sock] + list(a),
                              capture_output=True, env=env)

    try:
        wait(lambda: rc('ls').returncode == 0, 'kitty')
        for flags in flag_sets:
            out = os.path.join(tmp, f'out.{flags}')
            ready = os.path.join(tmp, f'ready.{flags}')
            cmd = f'python3 {shlex.quote(probe)} {flags} {out} {ready}'
            if tmux:
                tsock = os.path.join(tmp, f't.{flags}')
                conf = os.path.join(tmp, 'tmux.conf')
                open(conf, 'w').write('set -s extended-keys on\n'
                                      'set -g status off\n')
                cmd = (f'exec {shlex.quote(tmux)} -S {tsock} -f {conf} '
                       f'new {shlex.quote(cmd)}')
            r = rc('launch', '--type', 'tab', '--title', f'f{flags}',
                   'sh', '-c', cmd)
            wid = r.stdout.decode().strip()
            wait(lambda: os.path.exists(ready), f'the probe (flags {flags})')
            open(out, 'ab').close()
            if xkeys:
                xid = subprocess.run(['xdotool', 'search', '--sync', '--class', 'kitty'],
                                     capture_output=True).stdout.split()[0]
                subprocess.run(['xdotool', 'windowfocus', '--sync', xid],
                               capture_output=True)
            for key in keys:
                before = os.path.getsize(out)
                if xkeys:
                    subprocess.run(['xdotool', 'key', key], capture_output=True)
                else:
                    rc('send-key', '--match', f'id:{wid}', key)
                # Wait for bytes, then until no more come for 0.3 s (a key
                # can come as several events). A key kitty sends nothing for
                # (not in this mode) times out at 1 s and prints as empty.
                n = 0
                while os.path.getsize(out) == before and n < 50:
                    time.sleep(0.02)
                    n += 1
                last = -1
                while os.path.getsize(out) != last:
                    last = os.path.getsize(out)
                    time.sleep(0.3)
                with open(out, 'rb') as f:
                    f.seek(before)
                    got = f.read()
                print(flags, key, repr(got)[2:-1], flush=True)
            if tmux:
                subprocess.run([tmux, '-S', os.path.join(tmp, f't.{flags}'),
                                'kill-server'], capture_output=True)
            rc('close-window', '--match', f'id:{wid}')
    finally:
        k.terminate()
        k.wait()


if __name__ == '__main__':
    main()
