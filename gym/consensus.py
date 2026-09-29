"""Where is tmux the odd one out? Run each stream through several independent
terminal engines and through tmux's own emulator (a tmux pane), and report the
streams where every other engine agrees and tmux alone differs, shrunk to the
smallest stream that still shows it.

Engines: tmux (a pane of TMUX_REF), ghostty (libghostty-vt, gym/ghostty/gvt),
libvterm (Neovim and Vim, gym/refs/lvt), alacritty (alacritty_terminal,
gym/refs/avt-bin). Compared: every row of scrollback and screen, the rows with
soft-wrapped lines joined, and the cursor.

    python3 gym/consensus.py [--fuzz N] [--only NAME] [--no-shrink]
"""

import os
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import validate  # noqa: E402
import fuzz      # noqa: E402
import shrink    # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
COLS, ROWS = 80, 24


def norm(lines):
    lines = [l.expandtabs(8).rstrip() for l in lines]
    while lines and not lines[-1]:
        lines.pop()
    return tuple(lines)


def parse(out):
    """rows, joined and cursor; None for a section an engine cannot give
    (VTE has no rows, xterm no joined)."""
    def section(name):
        if '@@' + name + '\n' not in out:
            return None
        body = out.split('@@' + name + '\n', 1)[1]
        # Stop at the next section header only (a row may start with @@).
        for nxt in ('\n@@rows\n', '\n@@joined\n', '\n@@cursor '):
            body = body.split(nxt, 1)[0]
        return body.split('\n')
    rows, joined = section('rows'), section('joined')
    x, y = out.split('@@cursor ', 1)[1].split()[:2]
    return (norm(rows) if rows is not None else None,
            tuple(l.replace(' ', '') for l in norm(joined)) if joined is not None else None,
            (min(int(x), COLS - 1), int(y)))


def same(a, b):
    """Equal on every part both engines give."""
    return all(x == y for x, y in zip(a, b) if x is not None and y is not None)


class Engine:
    def __init__(self, name, argv):
        self.name, self.argv = name, argv

    def render(self, data, tmp):
        f = os.path.join(tmp, self.name + '.stream')
        open(f, 'wb').write(data)
        out = subprocess.run(self.argv + [f], capture_output=True).stdout
        return parse(out.decode('utf-8', 'replace'))


class TmuxEngine:
    name = 'tmux'

    def __init__(self, tmux, tmp):
        self.ref = validate.Ref(tmux, tmp)

    def render(self, data, tmp):
        p, j, cur = self.ref.render(data, COLS, ROWS)
        x, y = cur.split()[:2]
        return (norm(p.split('\n')),
                tuple(l.replace(' ', '').replace('\t', '') for l in norm(j.split('\n'))),
                (min(int(x), COLS - 1), int(y)))

    def close(self):
        self.ref.close()


def confirming(tmp):
    """Slower engines (a real X program per stream) used only to confirm the
    shrunk cases: VTE (GNOME Terminal) and xterm itself."""
    return [Engine('vte', ['xvfb-run', '-a', 'python3', os.path.join(HERE, 'refs', 'vte.py'),
                           str(COLS), str(ROWS)]),
            Engine('xterm', ['xvfb-run', '-a', 'sh', os.path.join(HERE, 'refs', 'xterm.sh'),
                             str(COLS), str(ROWS)])]


def engines(tmp):
    return [TmuxEngine(os.environ.get('TMUX_REF', 'tmux'), tmp),
            Engine('ghostty', [os.path.join(HERE, 'ghostty', 'gvt'), str(COLS), str(ROWS), '1']),
            Engine('libvterm', [os.path.join(HERE, 'refs', 'lvt'), str(COLS), str(ROWS)]),
            Engine('alacritty', [os.path.join(HERE, 'refs', 'avt-bin'), str(COLS), str(ROWS)])]


def verdict(results):
    """'odd' when tmux alone differs and the others agree, 'same' when all
    agree, 'split' otherwise."""
    tm = results['tmux']
    others = [v for k, v in results.items() if k != 'tmux']
    if all(same(o, tm) for o in others):
        return 'same'
    if all(same(o, others[0]) for o in others) and \
            all(not same(o, tm) for o in others):
        return 'odd'
    return 'split'


def what_differs(a, b):
    kinds = []
    for i, k in enumerate(('rows', 'joined', 'cursor')):
        if a[i] != b[i]:
            kinds.append(k)
    return kinds


def main():
    args = sys.argv[1:]
    nfuzz = int(args[args.index('--fuzz') + 1]) if '--fuzz' in args else 100
    only = args[args.index('--only') + 1] if '--only' in args else None
    tmp = tempfile.mkdtemp(prefix='gym-consensus.')
    eng = engines(tmp)
    try:
        cases = validate.parity_cases(tmp) + \
            [(f'vtfuzz-{i:03d}', fuzz.stream(i)) for i in range(nfuzz)]
        odd, split = [], []
        for name, data in cases:
            if only and name != only:
                continue
            res = {e.name: e.render(data, tmp) for e in eng}
            v = verdict(res)
            if v == 'odd':
                odd.append((name, data, res))
            elif v == 'split':
                split.append((name, res))
        print(f'{len(cases) if not only else 1} streams: tmux alone differs on {len(odd)}, '
              f'engines split on {len(split)}')
        seen = set()
        findings = []
        conf = confirming(tmp) if '--no-confirm' not in args else []
        for name, data, res in odd:
            other = res['ghostty']
            kinds = what_differs(res['tmux'], other)
            if '--no-shrink' in args:
                print(f'  {name}: tmux differs in {kinds}')
                continue

            def fails(toks):
                d = b''.join(toks)
                r = {e.name: e.render(d, tmp) for e in eng}
                return verdict(r) == 'odd'
            small = b''.join(shrink.ddmin(shrink.tokens(data), fails))
            if small in seen:
                continue
            seen.add(small)
            if b'\x1b(0' in small or b'\x1b)0' in small:
                print(f'\n  {name} -> {small!r}: not a tmux bug - capture-pane '
                      f'reports DEC line drawing as its letters; tmux draws it right')
                continue
            r = {e.name: e.render(small, tmp) for e in eng + conf}
            print(f'\n  {name} -> {small!r}')
            agree = [k for k in r if k != 'tmux' and same(r[k], r['ghostty'])]
            print(f'    agree against tmux: {", ".join(agree)}; '
                  f'with tmux: {", ".join(k for k in r if k != "tmux" and same(r[k], r["tmux"])) or "none"}')
            findings.append({'case': name, 'stream': small.decode('utf-8', 'replace'),
                             'tmux': r['tmux'], 'others': r['ghostty'],
                             'engines': {k: v for k, v in r.items()}})
            t, o = r['tmux'], r['ghostty']
            for i, k in enumerate(('rows', 'joined', 'cursor')):
                if t[i] != o[i]:
                    print(f'    {k}: tmux {t[i]!r}')
                    print(f'    {" " * len(k)}  others {o[i]!r}')
        if findings and '--json' in args:
            import json
            json.dump(findings, open(args[args.index('--json') + 1], 'w'), indent=1,
                      default=list, ensure_ascii=False)
        for name, res in split:
            groups = {}
            for k, v in res.items():
                groups.setdefault(v, []).append(k)
            print(f'  split {name}: ' + ' | '.join(','.join(g) for g in groups.values()))
    finally:
        for e in eng:
            if hasattr(e, 'close'):
                e.close()


if __name__ == '__main__':
    main()
