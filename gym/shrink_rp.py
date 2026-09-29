"""Shrink a regress/render-parity.sh case that fails to the smallest case that
still fails, keeping which chunk each piece is written in (the pauses between
chunks decide what tmux holds back).

    python3 gym/shrink_rp.py NAME TMUX [OUTDIR]
"""

import os
import shutil
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import shrink    # noqa: E402
import validate  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
RP = os.path.join(HERE, '..', 'regress', 'render-parity.sh')


def chunks_of(case_dir):
    names = sorted((f for f in os.listdir(case_dir) if f.isdigit()), key=int)
    return [open(os.path.join(case_dir, f), 'rb').read() for f in names]


def write_case(root, name, chunks):
    d = os.path.join(root, name)
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(d)
    n = 0
    for c in chunks:
        if c:
            n += 1
            open(os.path.join(d, str(n)), 'wb').write(c)
    open(os.path.join(root, 'list'), 'w').write(name + '\n')


def fails(root, name, tmux, toks):
    chunks = {}
    for k, t in toks:
        chunks.setdefault(k, b'')
        chunks[k] += t
    write_case(root, name, [chunks[k] for k in sorted(chunks)])
    env = {k: v for k, v in os.environ.items() if k not in ('TMUX', 'TMUX_PANE')}
    env.update(RENDER_PARITY_DIR=root, TEST_TMUX=tmux)
    r = subprocess.run(['sh', RP], cwd=os.path.dirname(RP), env=env, capture_output=True,
                       text=True)
    return f'{name}: differs' in r.stderr


def main():
    name, tmux = sys.argv[1], os.path.abspath(sys.argv[2])
    out = sys.argv[3] if len(sys.argv) > 3 else None
    tmp = tempfile.mkdtemp(prefix='gym-shrink-rp.')
    validate.parity_cases(tmp)
    toks = [(k, t) for k, c in enumerate(chunks_of(os.path.join(tmp, 'cases', name)))
            for t in shrink.tokens(c)]
    root = os.path.join(tmp, 'work')
    os.makedirs(root)
    assert fails(root, name, tmux, toks), 'the case does not fail'
    small = shrink.ddmin(toks, lambda t: fails(root, name, tmux, t))
    fails(root, name, tmux, small)
    print(f'{len(toks)} pieces -> {len(small)}:')
    for k in sorted(set(k for k, _ in small)):
        print(f'  chunk {k + 1}: {b"".join(t for kk, t in small if kk == k)!r}')
    if out:
        shutil.copytree(os.path.join(root, name), out, dirs_exist_ok=True)


if __name__ == '__main__':
    main()
