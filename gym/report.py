"""Evidence images for the tmux issue.

    python3 gym/report.py OUTDIR PARITY_UP PARITY_BR FINDINGS.json

PARITY_UP/PARITY_BR: the RP_KEEP directories of a render-parity run on
upstream tmux and on this branch (each case has bare, tmux: what the
terminal holds after the program ran directly and through tmux).
FINDINGS.json: gym/consensus.py --json output.

Writes OUTDIR/parity-CASE.png (direct | upstream tmux | this branch, cells
that differ from the direct run outlined), OUTDIR/engines-N.png (tmux's
emulator next to the other engines for each consensus finding) and
OUTDIR/index.json describing them.
"""

import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import evidence  # noqa: E402


def rows(path):
    return open(path).read().split('\n--- joined')[0].split('\n')


def plain(path):
    return open(path).read().rstrip('\n').split('\n') if os.path.exists(path) else []


def parity(out, up, br, engine='ghostty'):
    """Directories from gym/parity_real.py --keep (ENGINE.direct/.tmux: what
    a real terminal holds) or from render-parity.sh's RP_KEEP (bare/tmux: what
    a tmux pane holds)."""
    made = []
    for case in sorted(os.listdir(up)):
        u, b = os.path.join(up, case), os.path.join(br, case)
        if os.path.exists(os.path.join(u, f'{engine}.direct')):
            direct = plain(os.path.join(u, f'{engine}.direct'))
            via_up = plain(os.path.join(u, f'{engine}.tmux'))
            via_br = plain(os.path.join(b, f'{engine}.tmux'))
            if direct == via_up:
                continue
            # Scrollback grows upward: line the panels up at the bottom row
            # (the screen), padding the shorter ones at the top.
            n = max(len(direct), len(via_up), len(via_br))
            direct, via_up, via_br = ([''] * (n - len(p)) + p
                                      for p in (direct, via_up, via_br))
            img = evidence.compare([(f'program run directly ({engine})', direct),
                                    (f'through upstream tmux ({engine})', via_up),
                                    (f'through tmux with the fixes ({engine})', via_br)], 80)
            name = f'parity-{case}.png'
            img.save(os.path.join(out, name))
            made.append({'image': name, 'case': case, 'engine': engine,
                         'fixed': via_br == direct})
            continue
        if not os.path.exists(os.path.join(u, 'bare')):
            continue
        direct, via_up = rows(os.path.join(u, 'bare')), rows(os.path.join(u, 'tmux'))
        if direct == via_up:
            continue
        via_br = rows(os.path.join(b, 'tmux')) if os.path.exists(os.path.join(b, 'tmux')) else []
        img = evidence.compare([('program run directly', direct),
                                ('through upstream tmux', via_up),
                                ('through tmux with the fixes', via_br)], 80)
        name = f'parity-{case}.png'
        img.save(os.path.join(out, name))
        made.append({'image': name, 'case': case,
                     'fixed': via_br == direct,
                     'differ': open(os.path.join(u, 'case', 'differ')).read().strip()
                     if os.path.exists(os.path.join(u, 'case', 'differ')) else None})
    return made


def engines(out, findings):
    made = []
    for n, f in enumerate(findings):
        eng = f['engines']
        panels = [('tmux (upstream)', list(eng['tmux'][0] or []))]
        for k in ('ghostty', 'libvterm', 'alacritty', 'xterm'):
            if k in eng and eng[k][0] is not None:
                panels.append((k, list(eng[k][0])))
        n_rows = max(len(p[1]) for p in panels)
        for p in panels:
            while len(p[1]) < n_rows:
                p[1].append('')
        img = evidence.compare(panels, 80, context=2)
        name = f'engines-{n:02d}.png'
        img.save(os.path.join(out, name))
        agree = [k for k, v in eng.items() if k != 'tmux' and
                 all(a == b for a, b in zip(v, eng['ghostty']) if a is not None and b is not None)]
        made.append({'image': name, 'case': f['case'], 'stream': f['stream'],
                     'agree_against_tmux': agree})
    return made


def main():
    out, up, br, fj = sys.argv[1:5]
    os.makedirs(out, exist_ok=True)
    index = {'parity': parity(out, up, br),
             'engines': engines(out, json.load(open(fj)))}
    json.dump(index, open(os.path.join(out, 'index.json'), 'w'), indent=1, ensure_ascii=False)
    print(f"{len(index['parity'])} parity images, {len(index['engines'])} engine images")


if __name__ == '__main__':
    main()
