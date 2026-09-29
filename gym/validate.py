"""Check vt.py (xterm quirks) against a real terminal, so a difference the gym
reports is tmux's and not the model's.

The reference is a pane of a tmux server (TMUX_REF, default the tmux on PATH):
each stream is written into a fresh pane with cat, then the pane's history and
screen (capture-pane -p), its joined lines (-J) and cursor are compared with
the model fed the same bytes. The streams are regress/render-parity.sh's cases
(written by its own cases.awk) plus random ones from fuzz.py.

    python3 gym/validate.py [--fuzz N] [--only NAME]
"""

import os
import re
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import vt      # noqa: E402
import fuzz    # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
REGRESS = os.path.join(HERE, '..', 'regress')


def parity_cases(tmp):
    src = open(os.path.join(REGRESS, 'render-parity.sh')).read()
    awk = re.search(r"cat >\$DIR/cases\.awk <<'EOF'\n(.*?)\nEOF\n", src, re.S).group(1)
    path = os.path.join(tmp, 'cases.awk')
    open(path, 'w').write(awk)
    d = os.path.join(tmp, 'cases')
    os.mkdir(d)
    subprocess.run(['awk', '-v', 'dir=' + d, '-f', path], check=True,
                   env=dict(os.environ, LC_ALL='C'))
    names = open(os.path.join(d, 'list')).read().split()
    out = []
    for n in names:
        cd = os.path.join(d, n)
        chunks = sorted((f for f in os.listdir(cd) if f.isdigit()), key=int)
        data = b''.join(open(os.path.join(cd, f), 'rb').read() for f in chunks)
        out.append((n, data))
    return out


class Ref:
    def __init__(self, tmux, tmp):
        self.tmux = tmux
        self.sock = os.path.join(tmp, 'ref.sock')
        self.tmp = tmp
        self.run('new', '-d', '-s', 'keep', '-x', '80', '-y', '24')
        self.run('set', '-g', 'history-limit', '100000')
        self.run('set', '-g', 'status', 'off')

    def run(self, *a, text=True):
        env = {k: v for k, v in os.environ.items() if k not in ('TMUX', 'TMUX_PANE')}
        return subprocess.run([self.tmux, '-S', self.sock, '-f', '/dev/null'] + list(a),
                              capture_output=True, text=text, env=env).stdout

    def render(self, data, cols=80, rows=24):
        f = os.path.join(self.tmp, 'stream')
        open(f, 'wb').write(data)
        done = f + '.done'
        if os.path.exists(done):
            os.unlink(done)
        self.run('new', '-d', '-s', 't', '-x', str(cols), '-y', str(rows),
                 f"stty raw -echo; cat '{f}'; touch '{done}'; exec sleep 100000")
        for _ in range(300):
            if os.path.exists(done):
                break
            time.sleep(0.02)
        time.sleep(0.15)
        p = self.run('capturep', '-p', '-t', 't', '-S', '-', '-E', '-')
        j = self.run('capturep', '-pJ', '-t', 't', '-S', '-', '-E', '-')
        cur = self.run('display', '-p', '-t', 't',
                       '#{cursor_x} #{cursor_y} #{alternate_on} #{history_size}')
        self.run('kill-session', '-t', 't')
        return p, j, cur

    def close(self):
        self.run('kill-server')


class GhosttyRef:
    """Ghostty's terminal (libghostty-vt) through gym/ghostty/gvt."""

    def __init__(self, tmp, pull=True):
        self.gvt = os.path.join(HERE, 'ghostty', 'gvt')
        self.tmp = tmp
        self.pull = pull

    def render(self, data, cols=80, rows=24, events=None):
        f = os.path.join(self.tmp, 'gstream')
        open(f, 'wb').write(data)
        argv = [self.gvt, str(cols), str(rows), '1' if self.pull else '0', f]
        if events:
            ev = f + '.ev'
            open(ev, 'w').write(''.join(f'{o} {op} {" ".join(map(str, a))}\n'
                                        for o, op, *a in events))
            argv.append(ev)
        out = subprocess.run(argv, capture_output=True).stdout.decode('utf-8', 'replace')
        p = out.split('@@rows\n', 1)[1].split('@@joined\n', 1)[0]
        j = out.split('@@joined\n', 1)[1].split('@@cursor ', 1)[0]
        x, y, pend, scr = out.split('@@cursor ', 1)[1].split()[:4]
        return p, j, f'{x} {y} {1 if scr != "0" else 0} 0'

    def close(self):
        pass


def model_text(t):
    """What capture-pane -p/-J would print for the model."""
    lines = t.lines()
    rows = [l for l, _ in lines]
    joined = []
    acc = None
    for text, wr in lines:
        acc = text if acc is None else acc + text
        if not wr:
            joined.append(acc)
            acc = None
    if acc is not None:
        joined.append(acc)
    return rows, joined


def expand(line, cols=80):
    """Tabs as tmux's capture-pane leaves them: to the next stop, but never
    past the last column."""
    out = ''
    for ch in line:
        if ch == '\t':
            out += ' ' * max(1, min((len(out) // 8 + 1) * 8, cols - 1) - len(out))
        else:
            out += ch
    return out


def norm(lines):
    lines = [l.rstrip() for l in lines]
    while lines and not lines[-1]:
        lines.pop()
    return lines


def compare(name, data, ref, cols=80, rows=24):
    p, j, cur = ref.render(data, cols, rows)
    t = vt.Term(cols, rows, PROFILE)
    t.feed(data)
    alt = cur.split()[2] == '1'
    if alt:
        mrows = [t.row_text(i) for i in range(rows)]
        rp = [expand(l, cols) for l in p.split('\n')][-rows - 1:]
        want, got = norm(rp), norm(mrows)
        wj, gj = [], []
    else:
        mrows, mjoined = model_text(t)
        want, got = norm([expand(l, cols) for l in p.split('\n')]), norm(mrows)
        # tmux joins with the trailing spaces of a wrapped row kept; compare
        # joined lines with spaces removed, as render-parity does.
        wj = norm([l.replace(' ', '').replace('\t', '') for l in j.split('\n')])
        gj = norm([l.replace(' ', '') for l in mjoined])
    cx, cy = (int(v) for v in cur.split()[:2])
    mx, my = t.state_of()['cursor']
    problems = []
    if want != got:
        problems.append(('rows', want, got))
    if wj != gj:
        problems.append(('joined', wj, gj))
    if (min(cx, cols - 1), cy) != (mx, my) and not alt:
        problems.append(('cursor', (cx, cy), (mx, my)))
    return problems


PROFILE = None


def show(name, problems):
    for kind, want, got in problems:
        print(f'  {name}: {kind} differs')
        if kind == 'cursor':
            print(f'    reference {want}  model {got}')
            continue
        n = max(len(want), len(got))
        shown = 0
        for i in range(n):
            a = want[i] if i < len(want) else '<none>'
            b = got[i] if i < len(got) else '<none>'
            if a != b:
                print(f'    {i:4d} ref  |{a}|')
                print(f'         model|{b}|')
                shown += 1
                if shown >= 4:
                    break


def bisect(name, data, ref):
    """The shortest prefix of data (at chunk-safe points) where the model
    and the reference first disagree, and the bytes around it."""
    lo, hi = 0, len(data)
    if not compare(name, data, ref):
        return None
    while hi - lo > 1:
        mid = (lo + hi) // 2
        if compare(name, data[:mid], ref):
            hi = mid
        else:
            lo = mid
    return hi


def main():
    args = sys.argv[1:]
    nfuzz = int(args[args.index('--fuzz') + 1]) if '--fuzz' in args else 200
    only = args[args.index('--only') + 1] if '--only' in args else None
    global PROFILE
    tmux = os.environ.get('TMUX_REF', 'tmux')
    tmp = tempfile.mkdtemp(prefix='gym-validate.')
    if '--ghostty' in args:
        ref = GhosttyRef(tmp)
        PROFILE = vt.GHOSTTY
    else:
        ref = Ref(tmux, tmp)
        PROFILE = vt.TMUXPANE
    bad = 0
    total = 0
    try:
        cases = parity_cases(tmp) + [(f'vtfuzz-{i:03d}', fuzz.stream(i)) for i in range(nfuzz)]
        for name, data in cases:
            if only and name != only:
                continue
            total += 1
            pr = compare(name, data, ref)
            if pr:
                bad += 1
                show(name, pr)
                if '--bisect' in args:
                    at = bisect(name, data, ref)
                    print(f'    first differs after {at} bytes; last bytes:',
                          repr(data[max(0, at - 60):at]))
                    show(name, compare(name, data[:at], ref))
    finally:
        ref.close()
    print(f'validate: {total - bad}/{total} streams match the reference')
    sys.exit(1 if bad else 0)


if __name__ == '__main__':
    main()
