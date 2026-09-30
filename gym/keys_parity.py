"""Key parity with kitty: the bytes a program gets for each key and kitty
keyboard mode, run directly in kitty and in tmux in kitty (both typed as X
key events). Prints the differences as a markdown table and fails if any is
not a known one.

    python3 gym/keys_parity.py --tmux TMUX [--flags 0,1,...] [KEY...]

Needs xvfb-run, xdotool and kitty (gym/refs/setup-judges.sh). Releases and
modifier keys pressed alone are left out: tmux has key presses only.
"""

import argparse
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PROBE = os.path.join(HERE, 'refs', 'kitty_keys.py')

FLAGS = '0,1,2,3,4,5,8,10,12,24,31'
KEYS = ('a shift+a ctrl+a alt+a ctrl+alt+a ctrl+shift+a alt+shift+a shift+1 '
        'ctrl+1 ctrl+bracketleft Escape shift+Escape ctrl+Escape Return '
        'shift+Return ctrl+Return alt+Return Tab shift+Tab ctrl+Tab alt+Tab '
        'BackSpace ctrl+BackSpace alt+BackSpace shift+BackSpace space '
        'ctrl+space alt+space Up shift+Up ctrl+alt+Up Home End Prior Next '
        'Insert Delete F1 F2 F3 F4 F5 F12 shift+F1 ctrl+F5 shift+F3 '
        'eacute').split()

# Known differences, as (flags, key): why.
KNOWN = {}
for f in ('8', '10', '12', '24', '31'):
    KNOWN[(f, 'shift+1')] = ('kitty sends shift+1 to tmux as the text "!", '
                             'so tmux does not know the unshifted key')
for f in ('0', '4'):
    KNOWN[(f, 'Home')] = 'without disambiguate tmux sends Home from its own terminfo'
    KNOWN[(f, 'End')] = 'without disambiguate tmux sends End from its own terminfo'
for f in ('0', '4'):
    KNOWN[(f, 'shift+F3')] = 'tmux sends S-F3 from its own terminfo'
for f in ('0', '2'):
    KNOWN[(f, 'ctrl+shift+a')] = ('kitty sends C-S-a as CSI u where xterm and '
                                  'tmux send C-a')
for k in ('Escape', 'shift+Escape', 'ctrl+Escape'):
    KNOWN[('2', k)] = ('with flag 2 and not 1, kitty sends the release of '
                       'Escape as ESC; tmux has no releases')


def normal(v):
    v = re.sub(r'\\x1b\[5744[1-6];[0-9:]*u', '', v)     # modifier keys alone
    v = re.sub(r'\\x1b\[[0-9]+;[0-9]+:3[u~A-Z]', '', v)  # releases
    return v


def load(text):
    d = {}
    for line in text.splitlines():
        parts = line.split(' ', 2)
        if len(parts) >= 2:
            d[(parts[0], parts[1])] = normal(parts[2] if len(parts) > 2 else '')
    return d


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--tmux', required=True)
    ap.add_argument('--flags', default=FLAGS)
    ap.add_argument('keys', nargs='*', default=KEYS)
    a = ap.parse_args()

    def run(extra):
        return subprocess.Popen(
            ['xvfb-run', '-a', sys.executable, PROBE, '--x'] + extra +
            [a.flags] + a.keys, stdout=subprocess.PIPE, text=True)
    direct = run([])
    tmux = run(['--tmux', os.path.abspath(a.tmux)])
    k = load(direct.communicate()[0])
    t = load(tmux.communicate()[0])
    if not k or len(k) != len(t):
        sys.exit(f'probe failed: {len(k)} results from kitty, {len(t)} through tmux')

    unexpected = 0
    rows = []
    for key in k:
        if k[key] == t.get(key):
            continue
        why = KNOWN.get(key)
        if why is None:
            unexpected += 1
            why = '**unexpected**'
        rows.append(f'| {key[0]} | `{key[1]}` | `{k[key]}` | `{t.get(key)}` | {why} |')
    print(f'### Keys: kitty against tmux in kitty\n')
    print(f'{len(k) - len(rows)} of {len(k)} the same, {len(rows)} differ, '
          f'{unexpected} unexpected.\n')
    if rows:
        print('| flags | key | kitty | tmux | why |')
        print('|---|---|---|---|---|')
        print('\n'.join(rows))
    sys.exit(1 if unexpected else 0)


if __name__ == '__main__':
    main()
