"""Replay a byte stream in kitty (a real kitty, under Xvfb) and print what it
holds in the format of the other engines: "@@rows" then every row of
scrollback and screen (the last ROWS rows are the screen), "@@joined" then
the same with soft-wrapped rows joined, and "@@cursor X Y 0 0".

    xvfb-run -a python3 gym/refs/kitty.py COLS ROWS STREAM

KITTY is the kitty binary (default: a release unpacked in
/mnt/fcvm-btrfs/term-judges/kitty, see gym/README).
"""

import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time

KITTY = os.environ.get('KITTY', '/mnt/fcvm-btrfs/term-judges/kitty/bin/kitty')
KITTEN = os.path.join(os.path.dirname(KITTY), 'kitten')


def main():
    cols, rows, stream = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3]
    tmp = tempfile.mkdtemp(prefix='gym-kitty.', dir=os.environ.get('GYM_TMP'))
    sock = os.path.join(tmp, 'k.sock')
    done = os.path.join(tmp, 'done')
    env = dict(os.environ, LIBGL_ALWAYS_SOFTWARE='1',
               XDG_CONFIG_HOME=os.path.join(tmp, 'cfg'),
               XDG_CACHE_HOME=os.path.join(tmp, 'cache'))
    env.pop('TMUX', None)
    k = subprocess.Popen(
        [KITTY, '--config', 'NONE', '--listen-on', 'unix:' + sock,
         '-o', 'allow_remote_control=yes', '-o', 'remember_window_size=no',
         '-o', f'initial_window_width={cols}c', '-o', f'initial_window_height={rows}c',
         '-o', 'scrollback_lines=100000', '-o', 'enable_audio_bell=no',
         '-o', 'window_padding_width=0', '-o', 'update_check_interval=0',
         'sh', '-c', f"stty raw -echo; cat '{stream}'; touch '{done}'; exec sleep 1000"],
        env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        for _ in range(400):
            if os.path.exists(done):
                break
            time.sleep(0.05)
        time.sleep(0.3)

        def rc(*a):
            return subprocess.run([KITTEN, '@', '--to', 'unix:' + sock] + list(a),
                                  capture_output=True, env=env).stdout.decode('utf-8', 'replace')
        size = json.loads(rc('ls'))[0]['tabs'][0]['windows'][0]
        if (size['columns'], size['lines']) != (cols, rows):
            sys.exit(f"kitty is {size['columns']}x{size['lines']}, not {cols}x{rows}")

        def text(extent):
            t = rc('get-text', '--extent', extent, '--add-wrap-markers', '--add-cursor')
            m = re.search(r'\x1b\[\?25[hl]\x1b\[(\d+);(\d+)H', t)
            cur = (int(m.group(2)) - 1, int(m.group(1)) - 1) if m else (0, 0)
            t = re.sub(r'\x1b\[[0-9;?]*[a-zA-Z]', '', t)
            # Each line ends with \r\n; a wrapped row ends with a bare \r
            # (the wrap marker) and the next row follows.
            lines = t.split('\r\n')
            if lines and lines[-1] == '':
                lines.pop()
            out = []
            for l in lines:
                parts = l.split('\r')
                out += [(p, True) for p in parts[:-1]] + [(parts[-1], False)]
            return out, cur

        # All of it is the scrollback and then every row of the screen.
        allrows, _ = text('all')
        _, cur = text('screen')
        if len(allrows) < rows:
            allrows += [('', False)] * (rows - len(allrows))
        print('@@rows')
        for r, _ in allrows:
            print(r.rstrip())
        print('@@joined')
        line = ''
        for r, wrapped in allrows:
            line += r if wrapped else r.rstrip()
            if not wrapped:
                print(line)
                line = ''
        if line:
            print(line)
        print(f'@@cursor {cur[0]} {cur[1]} 0 0')
    finally:
        k.kill()
        k.wait()
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == '__main__':
    main()
