"""Which modern protocols a program gets, run directly in a terminal and
through tmux in that terminal.

    python3 gym/protocols.py [--tmux BIN] [--terminals kitty,wezterm,xterm]

Each probe sends what a program sends to find out whether the terminal
supports something (a query, or a sequence and then a cursor position
report), followed by a primary device attributes request (DA1), which every
terminal answers, and records what came back before the DA1 reply. Run in
each terminal directly, and through tmux in that terminal three ways:
forwarding (clear-on-attach off, forward-output on), translate
(forward-output off) and default (clear-on-attach on).
"""

import os
import re
import shutil
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
J = os.environ.get('JUDGES', '/mnt/fcvm-btrfs/term-judges')

ST = '\033\\'
PROBES = [
    # name, what the program sends, what a supporting terminal answers
    ('kitty keyboard (CSI ? u)', '\033[?u', r'\033\[\?(\d+)u'),
    ('kitty graphics (APC G a=q)', '\033_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA' + ST,
     r'\033_Gi=31;([^\033]*)'),
    ('pointer shape (OSC 22 query)', '\033]22;?__current__' + ST, r'\033\]22;([^\033\007]*)'),
    ('notifications (OSC 99 query)', '\033]99;i=1:p=?;' + ST, r'\033\]99;([^\033\007]*)'),
    ('text sizing (OSC 66, width 2)', '\r\033]66;w=2; ' + ST + '\033[6n',
     r'\033\[\d+;(\d+)R'),
    ('in-band resize (DECRQM 2048)', '\033[?2048$p', r'\033\[\?2048;(\d)\$y'),
    ('pixel mouse (DECRQM 1016)', '\033[?1016$p', r'\033\[\?1016;(\d)\$y'),
    ('grapheme clusters (DECRQM 2027)', '\033[?2027$p', r'\033\[\?2027;(\d)\$y'),
    ('synchronized output (DECRQM 2026)', '\033[?2026$p', r'\033\[\?2026;(\d)\$y'),
    ('colour scheme (CSI ? 996 n)', '\033[?996n', r'\033\[\?997;(\d)n'),
    ('XTVERSION (CSI > q)', '\033[>q', r'\033P>\|([^\033]*)'),
]

PROBER = r'''
import os, re, select, sys, termios, tty
fd = os.open('/dev/tty', os.O_RDWR)
old = termios.tcgetattr(fd)
tty.setraw(fd)
out = []
try:
    for q in QUERIES:
        os.write(fd, (q + '\033[c').encode())
        buf = b''
        while not re.search(rb'\033\[\?[\d;]*c', buf):
            r, _, _ = select.select([fd], [], [], 3)
            if not r:
                buf += b'<timeout>'
                break
            buf += os.read(fd, 4096)
        reply = re.split(rb'\033\[\?[\d;]*c', buf, maxsplit=1)[0]
        out.append(reply.hex())
        os.write(fd, b'\r\033[2K')
finally:
    termios.tcsetattr(fd, termios.TCSANOW, old)
open(sys.argv[1], 'w').write('\n'.join(out) + '\n')
'''


def prober(tmp):
    p = os.path.join(tmp, 'prober.py')
    open(p, 'w').write('QUERIES = ' + repr([q for _, q, _ in PROBES]) + '\n' + PROBER)
    return p


def inner(cmd, tmux, mode, tmp):
    """The command run in the terminal: the prober, or tmux running it."""
    if mode == 'direct':
        return cmd
    sock = os.path.join(tmp, 'tmux.sock')
    opts = ['set', '-s', 'clear-on-attach', 'on' if mode == 'default' else 'off', ';',
            'set', '-g', 'status', 'off']
    if mode == 'translate':
        opts += [';', 'set', '-s', 'forward-output', 'off']
    q = ' '.join("'" + a.replace("'", "'\\''") + "'" if a not in (';',) else r"\;"
                 for a in opts)
    return (f"unset TMUX; {tmux} -S {sock} -f /dev/null new -s p "
            f"\"{cmd}\" \\; {q}")


def run_kitty(command, tmp):
    done = os.path.join(tmp, 'done')
    env = dict(os.environ, LIBGL_ALWAYS_SOFTWARE='1', XDG_CONFIG_HOME=tmp, XDG_CACHE_HOME=tmp)
    return subprocess.Popen(
        ['xvfb-run', '-a', J + '/kitty/bin/kitty', '--config', 'NONE', '-o',
         'initial_window_width=80c', '-o', 'initial_window_height=24c', '-o',
         'remember_window_size=no', 'sh', '-c', command + f"; touch '{done}'"],
        env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL), done


def run_xterm(command, tmp):
    done = os.path.join(tmp, 'done')
    return subprocess.Popen(
        ['xvfb-run', '-a', 'xterm', '-geometry', '80x24', '-e', 'sh', '-c',
         command + f"; touch '{done}'"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL), done


def run_wezterm(command, tmp):
    done = os.path.join(tmp, 'done')
    cfg = os.path.join(tmp, 'w.lua')

    def lua(s):
        return '"' + s.replace('\\', '\\\\').replace('"', '\\"') + '"'
    open(cfg, 'w').write(
        "local wezterm = require 'wezterm'\n"
        "wezterm.on('mux-startup', function()\n"
        f"  wezterm.mux.spawn_window {{ args = {{ 'sh', '-c', {lua(command + '; touch ' + repr(done))} }} }}\n"
        "end)\n"
        f"return {{ unix_domains = {{ {{ name = 'g', socket_path = {lua(tmp + '/s')} }} }},"
        " initial_cols = 80, initial_rows = 24 }\n")
    env = dict(os.environ, WEZTERM_CONFIG_FILE=cfg, XDG_RUNTIME_DIR=tmp, HOME=tmp)
    return subprocess.Popen([J + '/wezterm/usr/bin/wezterm-mux-server'], env=env,
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL), done


TERMINALS = {'kitty': run_kitty, 'wezterm': run_wezterm, 'xterm': run_xterm}


def probe(term, tmux, mode):
    os.makedirs(os.path.join(J, 'tmp'), exist_ok=True)
    tmp = tempfile.mkdtemp(prefix='gym-proto.', dir=os.path.join(J, 'tmp'))
    try:
        res = os.path.join(tmp, 'res')
        cmd = f"python3 {prober(tmp)} {res}"
        p, done = TERMINALS[term](inner(cmd, tmux, mode, tmp), tmp)
        for _ in range(1200):
            if os.path.exists(res) or p.poll() is not None:
                break
            time.sleep(0.05)
        time.sleep(0.2)
        p.kill()
        p.wait()
        subprocess.run([tmux, '-S', os.path.join(tmp, 'tmux.sock'), 'kill-server'],
                       capture_output=True)
        if not os.path.exists(res):
            return None
        return [bytes.fromhex(l).decode('utf-8', 'replace') for l in open(res).read().split('\n')[:len(PROBES)]]
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def verdict(i, reply):
    if reply is None:
        return '?'
    if '<timeout>' in reply:
        return 'timeout'
    name, _, pat = PROBES[i]
    m = re.search(pat, reply)
    if not m:
        return '-' if not reply else 'other: ' + repr(reply)[:30]
    v = m.group(1)
    if 'DECRQM' in name:
        return {'0': '-', '1': 'set', '2': 'reset', '3': 'always', '4': 'never'}.get(v, v)
    if 'OSC 66' in name:
        return 'yes' if v == '3' else '-'
    return 'yes: ' + v[:24] if v else 'yes'


def main():
    args = sys.argv[1:]
    tmux = args[args.index('--tmux') + 1] if '--tmux' in args else 'tmux'
    terms = (args[args.index('--terminals') + 1] if '--terminals' in args
             else 'kitty,wezterm,xterm').split(',')
    modes = ['direct', 'forward', 'translate', 'default']
    cols = {}
    for t in terms:
        for m in modes:
            cols[(t, m)] = probe(t, tmux, m)
            print(f'# {t} {m}: {"ok" if cols[(t, m)] is not None else "no result"}',
                  file=sys.stderr)
    head = ['protocol'] + [f'{t} {m}' for t in terms for m in modes]
    print('| ' + ' | '.join(head) + ' |')
    print('|' + '---|' * len(head))
    for i, (name, _, _) in enumerate(PROBES):
        row = [name] + [verdict(i, None if cols[(t, m)] is None else cols[(t, m)][i])
                        for t in terms for m in modes]
        print('| ' + ' | '.join(row) + ' |')


if __name__ == '__main__':
    main()
