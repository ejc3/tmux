"""Replay a byte stream in WezTerm (its headless mux server) and print what
it holds in the format of the other engines: "@@rows" then every row of
scrollback and screen (the last ROWS rows are the screen), "@@joined" then
the same with soft-wrapped rows joined, and "@@cursor X Y 0 0".

    python3 gym/refs/wezterm.py COLS ROWS STREAM

WEZTERM_BIN is the directory with wezterm-mux-server (default: a nightly
package unpacked in /mnt/fcvm-btrfs/term-judges/wezterm, see gym/README).
The config's startup handler spawns the program, polls for a file it
touches when the stream is written, and writes the pane's text.
"""

import os
import shutil
import subprocess
import sys
import tempfile
import time

BIN = os.environ.get('WEZTERM_BIN', '/mnt/fcvm-btrfs/term-judges/wezterm/usr/bin')

CONFIG = r'''
local wezterm = require 'wezterm'
local mux = wezterm.mux
local function dump()
  local f = io.open(%(done)s, 'r')
  if not f then wezterm.time.call_after(0.05, dump); return end
  f:close()
  local pane = mux.all_windows()[1]:tabs()[1]:panes()[1]
  local d = pane:get_dimensions()
  local o = io.open(%(tmp)s, 'w')
  o:write('@@dims ', d.cols, ' ', d.viewport_rows, ' ', d.scrollback_rows, '\n')
  o:write('@@joined\n', pane:get_logical_lines_as_text(d.scrollback_rows), '\n')
  local c = pane:get_cursor_position()
  o:write('@@cursor ', c.x, ' ', c.y, '\n')
  o:close()
  os.rename(%(tmp)s, %(out)s)
end
wezterm.on('mux-startup', function()
  mux.spawn_window { args = { 'sh', '-c', %(prog)s } }
  wezterm.time.call_after(0.05, dump)
end)
return {
  unix_domains = { { name = 'g', socket_path = %(sock)s } },
  initial_cols = %(cols)d, initial_rows = %(rows)d, scrollback_lines = 100000,
}
'''


def lua(s):
    return '"' + s.replace('\\', '\\\\').replace('"', '\\"') + '"'


def main():
    cols, rows, stream = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3]
    tmp = tempfile.mkdtemp(prefix='gym-wezterm.', dir=os.environ.get('GYM_TMP'))
    done, out = os.path.join(tmp, 'done'), os.path.join(tmp, 'out')
    prog = f"stty raw -echo; cat '{stream}'; sleep 0.2; touch '{done}'; exec sleep 1000"
    cfg = os.path.join(tmp, 'w.lua')
    open(cfg, 'w').write(CONFIG % dict(done=lua(done), tmp=lua(out + '.tmp'), out=lua(out),
                                       prog=lua(prog), sock=lua(os.path.join(tmp, 's')),
                                       cols=cols, rows=rows))
    env = dict(os.environ, WEZTERM_CONFIG_FILE=cfg, XDG_RUNTIME_DIR=tmp, HOME=tmp)
    env.pop('TMUX', None)
    m = subprocess.Popen([os.path.join(BIN, 'wezterm-mux-server')], env=env,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        for _ in range(600):
            if os.path.exists(out):
                break
            time.sleep(0.05)
        text = open(out).read()
        # get_lines_as_text leaves out blank rows in the scrollback: take
        # the rows by number from the CLI instead.
        total = int(text.split('\n', 1)[0].split()[3])
        cli = subprocess.run(
            [os.path.join(BIN, 'wezterm'), 'cli', 'get-text', '--pane-id', '0',
             '--start-line', str(rows - total), '--end-line', str(rows - 1)],
            env=dict(env, WEZTERM_UNIX_SOCKET=os.path.join(tmp, 's')),
            capture_output=True).stdout.decode('utf-8', 'replace')
    finally:
        m.kill()
        m.wait()
        shutil.rmtree(tmp, ignore_errors=True)
    head, rest = text.split("\n", 1)
    _, c, vrows, total = head.split()
    if (int(c), int(vrows)) != (cols, rows):
        sys.exit(f'wezterm is {c}x{vrows}, not {cols}x{rows}')
    total = int(total)
    body, cur = rest.rsplit('@@cursor ', 1)
    jtext = body.split('@@joined\n', 1)[1]
    rowl = cli.split('\n')
    if rowl and rowl[-1] == '':
        rowl.pop()
    if len(rowl) != total:
        sys.exit(f'wezterm gave {len(rowl)} rows, not {total}')
    x, y = (int(v) for v in cur.split()[:2])
    print('@@rows')
    for r in rowl:
        print(r.rstrip())
    print('@@joined')
    for l in jtext.rstrip('\n').split('\n'):
        print(l.rstrip())
    print(f'@@cursor {x} {y - (total - rows)} 0 0')


if __name__ == '__main__':
    main()
