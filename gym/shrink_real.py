"""Shrink a regress/render-parity.sh case that differs on a real terminal
(gym/parity_real.py) to the smallest case that still differs, keeping which
chunk each piece is written in.

    python3 gym/shrink_real.py NAME TMUX [--mode translate] [--engine ghostty]
"""

import os
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import consensus    # noqa: E402
import parity_real  # noqa: E402
import shrink       # noqa: E402
import shrink_rp    # noqa: E402
import validate     # noqa: E402


def main():
    args = sys.argv[1:]
    name, tmux = args[0], os.path.abspath(args[1])
    mode = args[args.index('--mode') + 1] if '--mode' in args else 'translate'
    which = args[args.index('--engine') + 1] if '--engine' in args else 'ghostty'
    parity_real.DEFAULT_MODE = mode == 'default'
    parity_real.FORWARD = 'off' if mode == 'translate' else None
    tmp = tempfile.mkdtemp(prefix='gym-shrink-real.')
    validate.parity_cases(tmp)
    eng = [e for e in consensus.engines(tmp) if e.name == which][0]
    toks = [(k, t) for k, c in enumerate(shrink_rp.chunks_of(os.path.join(tmp, 'cases', name)))
            for t in shrink.tokens(c)]
    root = os.path.join(tmp, 'work')
    os.makedirs(root)

    def differs(ts):
        chunks = {}
        for k, t in ts:
            chunks[k] = chunks.get(k, b'') + t
        shrink_rp.write_case(root, name, [chunks[k] for k in sorted(chunks)])
        d, t = parity_real.record(os.path.join(root, name), tmux, tmp)
        if parity_real.DEFAULT_MODE:
            return eng.screen(d, tmp) != eng.screen(t, tmp)
        a = parity_real.after_mark(eng.render(d, tmp))
        b = parity_real.after_mark(eng.render(t, tmp))
        return a[:2] != b[:2]

    assert differs(toks), 'the case does not differ'
    small = shrink.ddmin(toks, differs)
    differs(small)
    print(f'{len(toks)} pieces -> {len(small)}:')
    for k in sorted(set(k for k, _ in small)):
        print(f'  chunk {k + 1}: {b"".join(t for kk, t in small if kk == k)!r}')


if __name__ == '__main__':
    main()
